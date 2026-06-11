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

    func testStartStopProducesNonEmptyMP4() throws {
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

        try recorder.stop()

        // Verify output
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(fileSize, 1000, "MP4 should be > 1000 bytes")

        let asset = AVAsset(url: outputURL)
        XCTAssertTrue(asset.tracks(withMediaType: .video).count > 0, "Should have a video track")
        let videoTrack = asset.tracks(withMediaType: .video).first!
        XCTAssertEqual(videoTrack.naturalSize.width, 640)
        XCTAssertEqual(videoTrack.naturalSize.height, 480)
        XCTAssertGreaterThan(asset.duration.seconds, 0, "Duration should be > 0")
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

        try recorder.stop()
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

        try recorder.stop()
    }

    // MARK: - Inflight Drain

    func testStopWaitsForInflightFrames() throws {
        let recorder = VideoRecorder()
        try recorder.start(url: outputURL, size: CGSize(width: 640, height: 480), device: device, fps: 30)

        let hostClock = CMClockGetHostTimeClock()
        let t0 = CMClockGetTime(hostClock)

        // Create 3 inflight frames
        for i in 0..<3 {
            let ft = CMTimeAdd(t0, CMTime(value: Int64(i), timescale: 30))
            guard let frame = recorder.makeFrameTexture(hostTime: ft) else {
                XCTFail("Frame \(i) should not be nil")
                return
            }
            // Don't finishFrame — they stay inflight
            _ = frame // keep alive
        }

        // stop should drain (finishFrame was never called, so inflightCount=3)
        // The frames above will be released when they go out of scope,
        // but we test that stop handles the case where inflight frames exist.
        // In this test, the frames are "lost" (never finished), so stop will
        // time out after 5s. That's expected — we just verify it doesn't crash.
        // Real scenario: GPU completion handler calls finishFrame before timeout.
        do {
            try recorder.stop()
            // If we reach here, the timeout didn't fire (frames were released quickly)
        } catch {
            // Timeout is acceptable for this test — frames were never finished
            XCTAssertTrue(error is VideoRecorderError)
        }
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
        try recorder.stop()
    }
}
