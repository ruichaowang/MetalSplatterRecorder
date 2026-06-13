import XCTest
import AVFoundation
import CoreMedia
import Metal
@testable import SplatRecorder

final class VideoRecorderTests: XCTestCase {
    var device: MTLDevice!
    var outputURL: URL!

    override func setUp() {
        super.setUp()
        guard let d = MTLCreateSystemDefaultDevice() else {
            XCTFail("No Metal device")
            return
        }
        device = d
        outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("videorecorder-test-\(UUID().uuidString).mp4")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: outputURL)
        super.tearDown()
    }

    // MARK: - Lifecycle

    func testStartStopProducesNonEmptyMP4() async throws {
        let recorder = VideoRecorder()
        let size = CGSize(width: 640, height: 480)
        try recorder.start(url: outputURL, size: size, device: device, fps: 30)

        // Write a few frames
        let hostClock = CMClockGetHostTimeClock()
        let startTime = CMClockGetTime(hostClock)
        for i in 0..<5 {
            let frameTime = CMTimeAdd(startTime, CMTime(value: Int64(i), timescale: 30))
            guard let frame = recorder.makeFrameTexture(hostTime: frameTime) else {
                XCTFail("makeFrameTexture returned nil for frame \(i)")
                return
            }
            recorder.finishFrame(frame)
        }

        let summary = try recorder.stop()
        XCTAssertNotNil(summary, "Should return a summary for active recording")
        XCTAssertEqual(summary?.encodedFrameCount, 5)

        // Verify output
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(fileSize, 1000, "MP4 should be > 1000 bytes")

        let asset = AVURLAsset(url: outputURL)
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        let naturalSize = try await videoTrack?.load(.naturalSize) ?? .zero
        let duration = try await asset.load(.duration).seconds
        XCTAssertNotNil(videoTrack, "Should have a video track")
        XCTAssertEqual(naturalSize.width, 640)
        XCTAssertEqual(naturalSize.height, 480)
        XCTAssertGreaterThan(duration, 0, "Duration should be > 0")
    }

    // MARK: - Throttle

    func testMakeFrameTextureThrottlesWithinInterval() throws {
        let recorder = VideoRecorder()
        try recorder.start(url: outputURL, size: CGSize(width: 640, height: 480), device: device, fps: 30)

        let hostClock = CMClockGetHostTimeClock()
        let t0 = CMClockGetTime(hostClock)

        // First frame should succeed
        let frame1 = recorder.makeFrameTexture(hostTime: t0)
        XCTAssertNotNil(frame1, "First frame should return a RecordingFrame")
        if let f = frame1 { recorder.finishFrame(f) }

        // Immediately after (same time) should be throttled
        let frame2 = recorder.makeFrameTexture(hostTime: t0)
        XCTAssertNil(frame2, "Frame at same time should be throttled")

        // 0.01s later should also be throttled (need >= 1/30s ≈ 0.033s)
        let tClose = CMTimeAdd(t0, CMTime(value: 1, timescale: 100))
        let frame3 = recorder.makeFrameTexture(hostTime: tClose)
        XCTAssertNil(frame3, "Frame 0.01s later should be throttled")

        // After 1/30s should succeed
        let tNext = CMTimeAdd(t0, CMTime(value: 1, timescale: 30))
        let frame4 = recorder.makeFrameTexture(hostTime: tNext)
        XCTAssertNotNil(frame4, "Frame at 1/30s should succeed")
        if let f = frame4 { recorder.finishFrame(f) }

        // Verify dropped count
        XCTAssertEqual(recorder.droppedFrameCount, 2, "Should have 2 dropped frames from throttle")

        _ = try recorder.stop()
    }

    // MARK: - Size Even Rounding

    func testStartRoundsSizeToEven() throws {
        let recorder = VideoRecorder()
        // Odd dimensions
        try recorder.start(url: outputURL, size: CGSize(width: 639, height: 481), device: device, fps: 30)

        let hostClock = CMClockGetHostTimeClock()
        let t0 = CMClockGetTime(hostClock)
        let frame = recorder.makeFrameTexture(hostTime: t0)
        XCTAssertNotNil(frame, "Should get frame even with odd input size")

        // The texture should have even dimensions
        if let f = frame {
            XCTAssertEqual(Int(f.texture.width) % 2, 0, "Texture width should be even")
            XCTAssertEqual(Int(f.texture.height) % 2, 0, "Texture height should be even")
            recorder.finishFrame(f)
        }

        _ = try recorder.stop()
    }

    // MARK: - Inflight Drain

    func testStopWaitsForInflightFrames() throws {
        let recorder = VideoRecorder()
        try recorder.start(url: outputURL, size: CGSize(width: 640, height: 480), device: device, fps: 30)

        let hostClock = CMClockGetHostTimeClock()
        let t0 = CMClockGetTime(hostClock)

        // Create 3 inflight frames, then finish them from another thread
        let frames: [RecordingFrame] = (0..<3).compactMap { i in
            let ft = CMTimeAdd(t0, CMTime(value: Int64(i), timescale: 30))
            return recorder.makeFrameTexture(hostTime: ft)
        }
        XCTAssertEqual(frames.count, 3, "All 3 frames should be created")

        // Finish frames from a background queue while stop() is called
        let expectation = self.expectation(description: "All frames finished")
        let queue = DispatchQueue(label: "test-finish-queue", attributes: .concurrent)
        queue.async {
            // Small delay to simulate GPU completion timing
            Thread.sleep(forTimeInterval: 0.1)
            for frame in frames {
                recorder.finishFrame(frame)
            }
            expectation.fulfill()
        }

        // stop() should wait for inflight frames to be drained
        let summary = try recorder.stop()
        XCTAssertNotNil(summary, "Should return summary")
        XCTAssertEqual(summary?.encodedFrameCount, 3, "All 3 frames should be encoded")

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - RecordingFrame retains CVMetalTexture

    func testRecordingFrameRetainsCVMetalTexture() throws {
        let recorder = VideoRecorder()
        try recorder.start(url: outputURL, size: CGSize(width: 640, height: 480), device: device, fps: 30)

        let hostClock = CMClockGetHostTimeClock()
        let t0 = CMClockGetTime(hostClock)
        guard let frame = recorder.makeFrameTexture(hostTime: t0) else {
            XCTFail("Should get a frame")
            return
        }

        // cvTexture should be non-nil (retained)
        // CVMetalTexture is a reference type, we check it's retained
        let cvTex = frame.cvTexture
        // Access the underlying objects — if cvTexture was released, these would crash
        let tex = CVMetalTextureGetTexture(cvTex)
        XCTAssertNotNil(tex, "MTLTexture from CVMetalTexture should be valid")
        XCTAssertEqual(tex?.width, 640)
        XCTAssertEqual(tex?.height, 480)

        recorder.finishFrame(frame)
        _ = try recorder.stop()
    }

    // MARK: - Stop Idle / Idempotent

    func testStopReturnsImmediatelyWhenIdle() throws {
        let recorder = VideoRecorder()

        let start = DispatchTime.now()
        let summary = try recorder.stop()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

        XCTAssertNil(summary, "Should return nil when no recording was started")
        XCTAssertLessThan(elapsed, 1_000_000_000, "Should return in < 1 second") // 1s in ns
    }

    func testStopReturnsImmediatelyWhenAlreadyStopped() throws {
        let recorder = VideoRecorder()
        try recorder.start(url: outputURL, size: CGSize(width: 640, height: 480), device: device, fps: 30)

        let hostClock = CMClockGetHostTimeClock()
        let t0 = CMClockGetTime(hostClock)
        guard let frame = recorder.makeFrameTexture(hostTime: t0) else {
            XCTFail("Should get a frame")
            return
        }
        recorder.finishFrame(frame)

        // First stop — should succeed with summary
        let summary1 = try recorder.stop()
        XCTAssertNotNil(summary1, "First stop should return summary")

        // Second stop — should return nil immediately (idempotent)
        let start = DispatchTime.now()
        let summary2 = try recorder.stop()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

        XCTAssertNil(summary2, "Second stop should return nil")
        XCTAssertLessThan(elapsed, 1_000_000_000, "Second stop should return in < 1 second")
    }

    // MARK: - Discard Frame

    func testDiscardFrameReleasesInflightSoStopDoesNotTimeout() throws {
        let recorder = VideoRecorder()
        try recorder.start(url: outputURL, size: CGSize(width: 640, height: 480), device: device, fps: 30)

        let hostClock = CMClockGetHostTimeClock()
        let t0 = CMClockGetTime(hostClock)

        // Create 3 frames but discard them all (simulating render failures)
        for i in 0..<3 {
            let ft = CMTimeAdd(t0, CMTime(value: Int64(i), timescale: 30))
            guard let frame = recorder.makeFrameTexture(hostTime: ft) else {
                XCTFail("Frame \(i) should not be nil")
                return
            }
            recorder.discardFrame(frame)
        }

        // stop() should complete quickly since all inflight frames were discarded
        let start = DispatchTime.now()
        let summary = try recorder.stop()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

        XCTAssertNotNil(summary, "Should return summary")
        XCTAssertEqual(summary?.encodedFrameCount, 0, "No frames should be encoded")
        XCTAssertEqual(summary?.droppedFrameCount, 3, "All 3 frames should be dropped")
        XCTAssertLessThan(elapsed, 3_000_000_000, "Should complete in < 3 seconds") // 3s in ns
    }
}
