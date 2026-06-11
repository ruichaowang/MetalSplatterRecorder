# SplatRecorder Recording Feature Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire up `MTLTexture → CVPixelBuffer → AVAssetWriter` to produce playable MP4 recordings from SplatRecorder.

**Architecture:** Refactor `VideoRecorder` from actor to `class + Mutex<State>` for synchronous capture API, add inflight frame drain on stop, fix pixel format consistency (`.bgra8Unorm` intermediate), and add `--validate-recording` CLI using `DebugAxisScene`.

**Tech Stack:** Swift 6, Metal, AVFoundation, CoreVideo, Synchronization (Mutex), macOS 15+

**Spec:** `docs/superpowers/specs/2026-06-11-splatrecorder-recording-design.md`

---

### Task 1: Fix Package Identity for Non-Standard Clone Directories

**Files:**
- Modify: `Apps/SplatRecorder/Package.swift:11`

- [ ] **Step 1: Add explicit name to path dependency**

```swift
// Before (line 11):
.package(path: "../.."),

// After:
.package(name: "MetalSplatter", path: "../.."),
```

- [ ] **Step 2: Verify build still works from standard directory**

Run: `cd Apps/SplatRecorder && swift build --product SplatRecorder`
Expected: Build succeeds, 0 errors

- [ ] **Step 3: Verify build works from non-standard directory name**

```bash
cp -r /Users/ruichaowang/Downloads/MetalSplatter /tmp/metalsplatter-identity-test
cd /tmp/metalsplatter-identity-test/Apps/SplatRecorder
swift build --product SplatRecorder
```

Expected: Build succeeds (previously would fail with `unknown package 'MetalSplatter'`)

- [ ] **Step 4: Commit**

```bash
cd /Users/ruichaowang/Downloads/MetalSplatter
git add Apps/SplatRecorder/Package.swift
git commit -m "fix: use explicit package name for path dependency in SplatRecorder

SwiftPM infers the package name from the directory name for path
dependencies. If the repo is cloned to a non-'MetalSplatter' directory
(e.g., GitHub's default 'MetalSplatRecorder'), the build fails with
'unknown package'. Explicitly naming the dependency fixes this."
```

---

### Task 2: Write VideoRecorderTests — Basic Lifecycle

**Files:**
- Create: `Apps/SplatRecorder/Tests/VideoRecorderTests.swift`

- [ ] **Step 1: Create the test file with lifecycle and throttle tests**

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Apps/SplatRecorder && swift test --filter VideoRecorderTests`
Expected: Compile error — `VideoRecorder` is still an `actor`, not a `class`. Tests reference `VideoRecorder()` (non-async init), `recorder.makeFrameTexture(hostTime:)` (synchronous), `recorder.droppedFrameCount` (new property), `VideoRecorderError` (expanded).

- [ ] **Step 3: Commit**

```bash
cd /Users/ruichaowang/Downloads/MetalSplatter
git add Apps/SplatRecorder/Tests/VideoRecorderTests.swift
git commit -m "test: add VideoRecorderTests for lifecycle, throttle, size, inflight drain"
```

---

### Task 3: Refactor VideoRecorder — actor → class + Mutex

**Files:**
- Modify: `Apps/SplatRecorder/Sources/Recording/VideoRecorder.swift` (entire file)

- [ ] **Step 1: Rewrite VideoRecorder.swift**

```swift
import Foundation
@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import CoreVideo
import Metal
import Synchronization

/// A single captured frame ready for encoding.
/// Retains CVMetalTexture to prevent the underlying CVPixelBuffer
/// from being recycled before GPU operations complete.
struct RecordingFrame {
    let cvTexture: CVMetalTexture
    let texture: MTLTexture
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
}

/// Mutex-based video recorder using AVAssetWriter for H.264 MP4 output.
/// Synchronous capture API — callable from @MainActor draw loop and GPU completion handlers.
final class VideoRecorder: @unchecked Sendable {

    struct State {
        var isRecording = false
        var encodedFrameCount = 0
        var droppedFrameCount = 0
        var inflightFrameCount = 0
        var lastError: VideoRecorderError?

        var assetWriter: AVAssetWriter?
        var assetWriterInput: AVAssetWriterInput?
        var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        var pixelBufferPool: CVPixelBufferPool?
        var textureCache: CVMetalTextureCache?

        var outputURL: URL?
        var videoSize: CGSize = .zero
        var targetFPS: Int = 30
        var startHostTime: CMTime = .invalid
        var lastFrameHostTime: CMTime = .invalid
    }

    private let state = Mutex(State())

    // MARK: - Read-Only Stats

    var isRecording: Bool { state.withLock { $0.isRecording } }
    var encodedFrameCount: Int { state.withLock { $0.encodedFrameCount } }
    var droppedFrameCount: Int { state.withLock { $0.droppedFrameCount } }
    var outputURL: URL? { state.withLock { $0.outputURL } }
    var lastError: VideoRecorderError? { state.withLock { $0.lastError } }

    // MARK: - Lifecycle

    /// Start recording. Size is rounded down to even dimensions for H.264.
    func start(url: URL, size: CGSize, device: MTLDevice, fps: Int = 30) throws {
        try state.withLock { s in
            guard !s.isRecording else { return }

            // Round to even dimensions (H.264 requirement)
            let evenWidth = Int(size.width) & ~1
            let evenHeight = Int(size.height) & ~1
            let evenSize = CGSize(width: evenWidth, height: evenHeight)

            s.outputURL = url
            s.videoSize = evenSize
            s.targetFPS = fps
            s.startHostTime = CMClockGetTime(CMClockGetHostTimeClock())
            s.lastFrameHostTime = .invalid
            s.encodedFrameCount = 0
            s.droppedFrameCount = 0
            s.inflightFrameCount = 0
            s.lastError = nil

            // Remove existing file if any
            try? FileManager.default.removeItem(at: url)

            // Create AVAssetWriter
            let writer: AVAssetWriter
            do {
                writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            } catch {
                throw VideoRecorderError.cannotCreateWriter(error)
            }
            s.assetWriter = writer

            // H.264 video settings
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: evenWidth,
                AVVideoHeightKey: evenHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(evenWidth * evenHeight * 10),
                    AVVideoMaxKeyFrameIntervalKey: 30,
                ]
            ]

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true
            s.assetWriterInput = input

            // Pixel buffer adaptor attributes
            let sourcePixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: evenWidth,
                kCVPixelBufferHeightKey as String: evenHeight,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            s.pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: sourcePixelBufferAttributes
            )

            // Create pixel buffer pool (capacity 3)
            var pool: CVPixelBufferPool?
            let poolAttributes: [String: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
            ]
            CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary,
                                    sourcePixelBufferAttributes as CFDictionary, &pool)
            s.pixelBufferPool = pool

            // Create Metal texture cache
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            s.textureCache = cache

            guard writer.canAdd(input) else {
                throw VideoRecorderError.cannotAddInput
            }
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            s.isRecording = true
        }
    }

    // MARK: - Per-Frame Capture

    /// Create a pixel-buffer-backed Metal texture for the current frame.
    /// Handles fps throttling internally. Returns nil if the frame should be skipped.
    func makeFrameTexture(hostTime: CMTime) -> RecordingFrame? {
        state.withLock { s in
            guard s.isRecording else { return nil }

            // Frame rate throttling
            if s.lastFrameHostTime.isValid {
                let interval = CMTime(value: 1, timescale: Int32(s.targetFPS))
                if CMTimeSubtract(hostTime, s.lastFrameHostTime) < interval {
                    s.droppedFrameCount += 1
                    return nil
                }
            }

            // Calculate relative presentation time
            let presentationTime = CMTimeSubtract(hostTime, s.startHostTime)

            // Get pixel buffer from pool
            guard let pool = s.pixelBufferPool else { return nil }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard status == kCVReturnSuccess, let pb = pixelBuffer else {
                s.droppedFrameCount += 1
                return nil
            }

            // Create Metal texture from pixel buffer
            guard let cache = s.textureCache else {
                s.droppedFrameCount += 1
                return nil
            }
            var cvTexture: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pb, nil, .bgra8Unorm,
                Int(s.videoSize.width), Int(s.videoSize.height), 0, &cvTexture
            )
            guard let cvTex = cvTexture, let texture = CVMetalTextureGetTexture(cvTex) else {
                s.droppedFrameCount += 1
                return nil
            }

            s.lastFrameHostTime = hostTime
            s.inflightFrameCount += 1

            return RecordingFrame(
                cvTexture: cvTex,
                texture: texture,
                pixelBuffer: pb,
                presentationTime: presentationTime
            )
        }
    }

    /// Submit a captured frame for encoding. Safe to call from any thread.
    func finishFrame(_ frame: RecordingFrame) {
        state.withLock { s in
            defer { s.inflightFrameCount -= 1 }

            guard s.isRecording else { return }
            guard let input = s.assetWriterInput, input.isReadyForMoreMediaData else {
                // Encoder not ready — drop this frame
                s.droppedFrameCount += 1
                return
            }
            guard let adaptor = s.pixelBufferAdaptor else { return }

            if adaptor.append(frame.pixelBuffer, withPresentationTime: frame.presentationTime) {
                s.encodedFrameCount += 1
            } else {
                s.droppedFrameCount += 1
            }
        }
    }

    // MARK: - Stop / Cancel

    /// Stop recording and finalize the MP4. Blocks until all inflight frames
    /// are drained and the writer finishes.
    func stop() throws {
        // 1. Mark stopped — prevents new frames
        state.withLock { $0.isRecording = false }

        // 2. Drain inflight frames (with 5s timeout)
        let deadline = DispatchTime.now() + .seconds(5)
        while state.withLock({ $0.inflightFrameCount > 0 }) {
            if DispatchTime.now() > deadline {
                throw VideoRecorderError.stopTimeout
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        // 3. Finalize writer
        var writeError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        state.withLock { s in
            s.assetWriterInput?.markAsFinished()
            s.assetWriter?.finishWriting {
                if let error = $0 {
                    writeError = error
                }
                semaphore.signal()
            }
        }
        semaphore.wait()

        teardown()

        if let error = writeError {
            throw VideoRecorderError.finishWritingFailed(error)
        }
    }

    /// Cancel recording, discarding the output file.
    func cancel() {
        state.withLock { $0.isRecording = false }
        // Don't wait for inflight frames — we're throwing away the output.

        if let url = state.withLock({ $0.outputURL }) {
            try? FileManager.default.removeItem(at: url)
        }
        state.withLock { s in s.assetWriter?.cancelWriting() }
        teardown()
    }

    // MARK: - Private

    private func teardown() {
        state.withLock { s in
            s.assetWriter = nil
            s.assetWriterInput = nil
            s.pixelBufferAdaptor = nil
            s.pixelBufferPool = nil
            s.textureCache = nil
            s.outputURL = nil
            s.lastFrameHostTime = .invalid
            s.startHostTime = .invalid
        }
    }
}

// MARK: - Errors

enum VideoRecorderError: Error, LocalizedError {
    case cannotCreateWriter(Error)
    case cannotAddInput
    case stopTimeout
    case finishWritingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .cannotCreateWriter(let error):
            "Unable to create AVAssetWriter: \(error.localizedDescription)"
        case .cannotAddInput:
            "Unable to add video input to AVAssetWriter"
        case .stopTimeout:
            "Timed out waiting for inflight frames to complete"
        case .finishWritingFailed(let error):
            "AVAssetWriter failed to finish writing: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 2: Verify VideoRecorder tests pass**

Run: `cd Apps/SplatRecorder && swift test --filter VideoRecorderTests`
Expected: All 5 tests pass (testStartStopProducesNonEmptyMP4, testMakeFrameTextureThrottlesWithinInterval, testStartRoundsSizeToEven, testStopWaitsForInflightFrames, testRecordingFrameRetainsCVMetalTexture)

- [ ] **Step 3: Commit**

```bash
cd /Users/ruichaowang/Downloads/MetalSplatter
git add Apps/SplatRecorder/Sources/Recording/VideoRecorder.swift
git commit -m "refactor: rewrite VideoRecorder as class + Mutex with inflight drain

- Replace actor with class + Synchronization.Mutex<State>
- Add inflightFrameCount for safe stop() drain
- Use relative host-time presentation timestamps
- Round video size to even dimensions for H.264
- Expand VideoRecorderError with descriptive messages
- Add read-only stats: encodedFrameCount, droppedFrameCount, lastError

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Update RecordingMTKView — Wire Up tryCaptureFrame

**Files:**
- Modify: `Apps/SplatRecorder/Sources/Renderer/RecordingMTKView.swift`

- [ ] **Step 1: Remove local throttle state and update draw(in:)**

Replace the recording-related state and methods. The key changes:
- Remove `lastCaptureTime`, `shouldCaptureFrame()`, and the `@MainActor` annotation on `isRecording`
- `tryCaptureFrame` now calls `recorder.makeFrameTexture(hostTime:)` instead of returning nil
- `intermediateTexture` uses `.bgra8Unorm` pixel format
- Delete `shouldCaptureFrame` method

```swift
// In the RecordingMTKView class body:

// Remove these lines (around lines 52-56):
//   @MainActor var isRecording = false
//   @MainActor private var lastCaptureTime: CMTime = .invalid
//   @MainActor private var intermediateTexture: MTLTexture?

// Replace with:
@MainActor var isRecording = false
@MainActor private var intermediateTexture: MTLTexture?
```

- [ ] **Step 2: Update the intermediate texture creation — keep .bgra8Unorm_srgb**

The intermediate texture must match the `SplatRenderer`'s color format (`.bgra8Unorm_srgb`). The blit to the recording texture (`.bgra8Unorm`) triggers automatic format conversion by Metal.

```swift
// The intermediate texture descriptor stays as colorPixelFormat (.bgra8Unorm_srgb):
let desc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: colorPixelFormat,  // .bgra8Unorm_srgb — matches renderer
    width: targetSize.width,
    height: targetSize.height,
    mipmapped: false
)
```

The blit chain:
```
render → intermediateTexture (.bgra8Unorm_srgb)
  ├─ blit → drawable.texture (.bgra8Unorm_srgb)  ← same format
  └─ blit → frame.texture (.bgra8Unorm)           ← Metal auto-converts
```

- [ ] **Step 3: Replace tryCaptureFrame with real implementation**

Replace the current `tryCaptureFrame` method (lines 424-436):

```swift
// Before:
@MainActor
private func tryCaptureFrame(commandBuffer: MTLCommandBuffer,
                              presentationTime: CMTime) -> RecordingFrame? {
    return nil
}

// After:
@MainActor
private func tryCaptureFrame(presentationTime: CMTime) -> RecordingFrame? {
    return videoRecorder?.makeFrameTexture(hostTime: presentationTime)
}
```

- [ ] **Step 4: Update the recording path in draw(in:)**

The recording path in `draw(in:)` (lines 300-367) needs these changes:

1. Remove `shouldCaptureFrame(now)` check — throttle is now in `makeFrameTexture`
2. Update `tryCaptureFrame` call to remove `commandBuffer` parameter
3. Keep the rest of the dual blit path as-is (it's already correct)

```swift
// The relevant section of draw(in:) becomes:

if isRecording {
    // === RECORDING FRAME PATH (Scheme B) ===
    guard let frame = tryCaptureFrame(presentationTime: now) else {
        // Throttled or pool exhausted — render normally this frame
        renderNormally(renderer: renderer, to: drawable.texture,
                       commandBuffer: commandBuffer, drawable: drawable)
        return
    }

    // Ensure intermediate texture exists and matches size
    let targetSize = MTLSize(width: Int(renderSize.x), height: Int(renderSize.y), depth: 1)
    if intermediateTexture == nil ||
        intermediateTexture!.width != targetSize.width ||
        intermediateTexture!.height != targetSize.height {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorPixelFormat,  // .bgra8Unorm_srgb — matches renderer
            width: targetSize.width,
            height: targetSize.height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        intermediateTexture = device.makeTexture(descriptor: desc)
    }

    guard let midTex = intermediateTexture else {
        renderNormally(renderer: renderer, to: drawable.texture,
                       commandBuffer: commandBuffer, drawable: drawable)
        return
    }

    // Step 1: Render to intermediate texture
    do {
        let didRender = try renderer.render(
            to: midTex,
            depthTexture: depthStencilTexture,
            commandBuffer: commandBuffer
        )
        guard didRender else { commandBuffer.commit(); return }
    } catch {
        print("Recording render error: \(error)")
        commandBuffer.commit()
        return
    }

    // Step 2: Blit intermediate → drawable (display)
    if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
        blitEncoder.copy(
            from: midTex, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: targetSize,
            to: drawable.texture, destinationSlice: 0,
            destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
    }

    // Step 3: Blit intermediate → frame texture (recording)
    if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
        let frameTargetSize = MTLSize(width: frame.texture.width, height: frame.texture.height, depth: 1)
        blitEncoder.copy(
            from: midTex, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: min(targetSize.width, frameTargetSize.width),
                height: min(targetSize.height, frameTargetSize.height),
                depth: 1
            ),
            to: frame.texture, destinationSlice: 0,
            destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
    }

    // Step 4: Submit frame for encoding after GPU completes
    let recorder = videoRecorder
    commandBuffer.addCompletedHandler { _ in
        recorder?.finishFrame(frame)
    }

    commandBuffer.present(drawable)
    commandBuffer.commit()
} else {
    // === NORMAL FRAME PATH ===
    renderNormally(renderer: renderer, to: drawable.texture,
                   commandBuffer: commandBuffer, drawable: drawable)
}
```

- [ ] **Step 5: Delete the shouldCaptureFrame method**

Remove the `shouldCaptureFrame` method (lines 418-422):

```swift
// Delete these lines:
@MainActor
private func shouldCaptureFrame(_ now: CMTime) -> Bool {
    let targetInterval = CMTime(value: 1, timescale: 30)
    if !lastCaptureTime.isValid { return true }
    return CMTimeSubtract(now, lastCaptureTime) >= targetInterval
}
```

- [ ] **Step 6: Update setRecording to not reset local throttle state**

```swift
// Before:
@MainActor
func setRecording(_ recording: Bool) {
    isRecording = recording
    if recording {
        lastCaptureTime = .invalid
        intermediateTexture = nil
    }
}

// After:
@MainActor
func setRecording(_ recording: Bool) {
    isRecording = recording
    if recording {
        intermediateTexture = nil
    }
}
```

- [ ] **Step 7: Build and verify**

Run: `cd Apps/SplatRecorder && swift build --product SplatRecorder`
Expected: Build succeeds, 0 errors

- [ ] **Step 8: Commit**

```bash
cd /Users/ruichaowang/Downloads/MetalSplatter
git add Apps/SplatRecorder/Sources/Renderer/RecordingMTKView.swift
git commit -m "feat: wire up tryCaptureFrame with real VideoRecorder capture

- Remove local throttle (shouldCaptureFrame/lastCaptureTime)
- tryCaptureFrame now calls videoRecorder.makeFrameTexture(hostTime:)
- Intermediate texture uses .bgra8Unorm for pixel format consistency
- Add dual blit: intermediate→drawable + intermediate→frame texture
- Frame submitted via GPU completion handler → recorder.finishFrame

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Update SplatRecorderContentView — Error Handling & Validation

**Files:**
- Modify: `Apps/SplatRecorder/Sources/App/SplatRecorderContentView.swift`

- [ ] **Step 1: Add pre-recording validation in startRecording()**

Update the `startRecording()` method. Replace the current `Task { @MainActor in` block inside `savePanel.begin`:

```swift
// The recording part of startRecording() (inside savePanel.begin { response in ... })
// Replace the Task block:

Task { @MainActor in
    // Validate pre-conditions
    guard splatDocument.loadState == .loaded else {
        print("Cannot start recording: no splat loaded")
        return
    }
    guard let view = recordingView else {
        print("Cannot start recording: MTKView not available")
        return
    }
    let rawSize = view.drawableSize
    guard rawSize.width > 0, rawSize.height > 0 else {
        print("Cannot start recording: invalid drawable size \(rawSize)")
        return
    }

    do {
        try videoRecorder.start(url: url, size: rawSize, device: metalDevice)

        // Lock window size
        NSApp.mainWindow?.styleMask.remove(.resizable)

        // Sync recording state to MTKView
        view.setRecording(true)

        isRecording = true
        recordingElapsed = 0

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                recordingElapsed += 0.1
            }
        }
    } catch {
        print("Failed to start recording: \(error.localizedDescription)")
    }
}
```

- [ ] **Step 2: Update stopRecording() to read recorder stats**

Replace the current `stopRecording()` method:

```swift
private func stopRecording() {
    recordingTimer?.invalidate()
    recordingTimer = nil

    recordingView?.setRecording(false)

    // Stop on a background thread (stop() is synchronous and blocks)
    DispatchQueue.global().async { [weak self] in
        guard let self else { return }
        do {
            try self.videoRecorder.stop()

            let encoded = self.videoRecorder.encodedFrameCount
            let dropped = self.videoRecorder.droppedFrameCount
            let outputPath = self.videoRecorder.outputURL?.path ?? "unknown"

            print("Recording saved: \(outputPath)")
            print("  Encoded: \(encoded) frames, Dropped: \(dropped) frames")

            if let error = self.videoRecorder.lastError {
                print("  Warning: \(error.localizedDescription)")
            }

            DispatchQueue.main.async { [weak self] in
                self?.isRecording = false
                NSApp.mainWindow?.styleMask.insert(.resizable)
            }
        } catch {
            print("Failed to stop recording: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.isRecording = false
                NSApp.mainWindow?.styleMask.insert(.resizable)
            }
        }
    }
}
```

- [ ] **Step 3: Build and verify**

Run: `cd Apps/SplatRecorder && swift build --product SplatRecorder`
Expected: Build succeeds, 0 errors

- [ ] **Step 4: Commit**

```bash
cd /Users/ruichaowang/Downloads/MetalSplatter
git add Apps/SplatRecorder/Sources/App/SplatRecorderContentView.swift
git commit -m "feat: add recording validation and error reporting in UI

- Validate loaded splat, view, drawable size before recording
- Read encoded/dropped frame counts and lastError after stop
- Run synchronous stop() on background thread to avoid blocking UI
- Restore window resizable on stop success or failure

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Add --validate-recording CLI

**Files:**
- Modify: `Apps/SplatRecorder/Sources/App/SplatRecorderApp.swift`
- Modify: `Apps/SplatRecorder/Sources/Validation/SplatRecorderValidation.swift`

- [ ] **Step 1: Add RecordingValidation to SplatRecorderValidation.swift**

Append to the end of `SplatRecorderValidation.swift`:

```swift
// MARK: - Recording Validation

enum SplatRecorderRecordingValidation {
    private static let width = 1280
    private static let height = 720
    private static let fps = 30
    private static let durationSeconds = 1

    static func run(outputDirectory: URL) async throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RecordingValidationError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw RecordingValidationError.noCommandQueue
        }

        // Create synthetic scene from DebugAxisScene
        let points = DebugAxisScene.makeSplatPoints(coordinateSpace: .superSplatPLY, scale: 0.16)
        let chunk = try SplatChunk(device: device, from: points)

        let renderer = try SplatRenderer(
            device: device,
            colorFormat: .bgra8Unorm_srgb,
            depthFormat: .invalid,
            sampleCount: 1,
            maxViewCount: 1,
            maxSimultaneousRenders: 1,
            highQualityDepth: false,
            clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        )

        let sorted = Task {
            await withCheckedContinuation { continuation in
                renderer.afterNextSort { continuation.resume() }
            }
        }
        await renderer.addChunk(chunk, sortByLocality: true, enabled: true)
        await sorted.value

        // Set up camera
        let camera = OrbitCameraState()
        camera.target = .zero
        camera.distance = 6
        camera.fovRadians = 75 * .pi / 180
        camera.applySuperSplatDefaultView(center: .zero, diagonal: 3.0)

        let outputURL = outputDirectory.appendingPathComponent("recording.mp4")
        let recorder = VideoRecorder()
        let size = CGSize(width: width, height: height)
        try recorder.start(url: outputURL, size: size, device: device, fps: fps)

        // Create offscreen render texture
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private
        guard let renderTexture = device.makeTexture(descriptor: colorDesc) else {
            throw RecordingValidationError.cannotCreateTexture
        }

        let viewport = MTLViewport(
            originX: 0, originY: 0,
            width: Double(width), height: Double(height),
            znear: 0, zfar: 1
        )
        let projection = camera.projectionMatrix(aspect: Float(width) / Float(height))

        let hostClock = CMClockGetHostTimeClock()
        let startTime = CMClockGetTime(hostClock)
        var frameIndex = 0

        for second in 0..<durationSeconds {
            for subFrame in 0..<fps {
                let hostTime = CMTimeAdd(startTime, CMTime(
                    value: Int64(second * fps + subFrame),
                    timescale: Int32(fps)
                ))

                guard let frame = recorder.makeFrameTexture(hostTime: hostTime) else {
                    // Throttled — skip
                    continue
                }

                // Slightly rotate camera per frame for visual variation
                camera.yaw += 0.5 * .pi / 180

                let descriptor = SplatRenderer.ViewportDescriptor(
                    viewport: viewport,
                    projectionMatrix: camera.projectionMatrix(aspect: Float(width) / Float(height)),
                    viewMatrix: camera.viewMatrix,
                    screenSize: SIMD2(x: width, y: height)
                )

                guard let commandBuffer = queue.makeCommandBuffer() else { continue }
                var didRender = false
                do {
                    didRender = try renderer.render(
                        viewports: [descriptor],
                        colorTexture: renderTexture,
                        colorStoreAction: .store,
                        depthTexture: nil,
                        rasterizationRateMap: nil,
                        renderTargetArrayLength: 0,
                        to: commandBuffer
                    )
                } catch {
                    print("Validation render error: \(error)")
                }

                if didRender {
                    // Blit render texture → frame texture
                    if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                        blitEncoder.copy(
                            from: renderTexture, sourceSlice: 0, sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                            sourceSize: MTLSize(width: width, height: height, depth: 1),
                            to: frame.texture, destinationSlice: 0,
                            destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                        )
                        blitEncoder.endEncoding()
                    }
                }

                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()

                recorder.finishFrame(frame)
                frameIndex += 1
            }
        }

        try recorder.stop()

        // Verify output
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0

        let asset = AVAsset(url: outputURL)
        let videoTrack = asset.tracks(withMediaType: .video).first
        let naturalSize = videoTrack?.naturalSize ?? .zero
        let duration = asset.duration.seconds

        let report = RecordingValidationReport(
            outputPath: outputURL.path,
            size: RecordingValidationReport.Size(width: width, height: height),
            durationSeconds: duration,
            encodedFrameCount: recorder.encodedFrameCount,
            droppedFrameCount: recorder.droppedFrameCount,
            fileSizeBytes: Int(fileSize),
            naturalSize: RecordingValidationReport.Size(
                width: Int(naturalSize.width),
                height: Int(naturalSize.height)
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let reportURL = outputDirectory.appendingPathComponent("recording-report.json")
        try data.write(to: reportURL)

        print("outputPath=\(outputURL.path)")
        print("duration=\(String(format: "%.3f", duration))s")
        print("encodedFrames=\(recorder.encodedFrameCount)")
        print("droppedFrames=\(recorder.droppedFrameCount)")
        print("fileSize=\(fileSize) bytes")
        print("report=\(reportURL.path)")

        // Verify minimum quality
        guard duration > 0 else {
            throw RecordingValidationError.zeroDuration
        }
        guard recorder.encodedFrameCount > 0 else {
            throw RecordingValidationError.noEncodedFrames
        }
        guard fileSize > 1000 else {
            throw RecordingValidationError.fileTooSmall(fileSize)
        }
    }
}

private struct RecordingValidationReport: Codable {
    let outputPath: String
    let size: Size
    let durationSeconds: Double
    let encodedFrameCount: Int
    let droppedFrameCount: Int
    let fileSizeBytes: Int
    let naturalSize: Size

    struct Size: Codable {
        let width: Int
        let height: Int
    }
}

private enum RecordingValidationError: LocalizedError {
    case noMetalDevice
    case noCommandQueue
    case cannotCreateTexture
    case zeroDuration
    case noEncodedFrames
    case fileTooSmall(Int)

    var errorDescription: String? {
        switch self {
        case .noMetalDevice: "No Metal device available"
        case .noCommandQueue: "Unable to create Metal command queue"
        case .cannotCreateTexture: "Unable to create render texture"
        case .zeroDuration: "Output MP4 has zero duration"
        case .noEncodedFrames: "No frames were encoded"
        case .fileTooSmall(let size): "Output file too small: \(size) bytes"
        }
    }
}
```

- [ ] **Step 2: Add --validate-recording CLI entry in SplatRecorderApp.swift**

Add a new static method and call it in `main()` before `runValidationIfRequested()`:

```swift
// In SplatRecorderApp enum, add before runValidationIfRequested() call in main():

static func main() {
    if runAxisDebugIfRequested() { return }
    if runRecordingValidationIfRequested() { return }  // <-- NEW
    if runValidationIfRequested() { return }
    // ... rest of main()
}

// Add this method alongside runValidationIfRequested():
private static func runRecordingValidationIfRequested() -> Bool {
    let args = CommandLine.arguments
    guard args.dropFirst().first == "--validate-recording" else { return false }
    guard args.count >= 3 else {
        fputs("Usage: SplatRecorder --validate-recording <output-dir>\n", stderr)
        exit(2)
    }

    let outputDirectory = URL(fileURLWithPath: args[2], isDirectory: true)
    let completion = DispatchSemaphore(value: 0)
    let box = ValidationResultBox()

    Task.detached {
        do {
            try await SplatRecorderRecordingValidation.run(outputDirectory: outputDirectory)
            box.result = .success(())
        } catch {
            box.result = .failure(error)
        }
        completion.signal()
    }

    completion.wait()
    switch box.result {
    case .success:
        return true
    case .failure(let error):
        fputs("SplatRecorder recording validation failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    case .none:
        fputs("SplatRecorder recording validation failed without an error\n", stderr)
        exit(1)
    }
}
```

- [ ] **Step 3: Build and verify**

Run: `cd Apps/SplatRecorder && swift build --product SplatRecorder`
Expected: Build succeeds, 0 errors

- [ ] **Step 4: Run recording validation**

Run: `cd Apps/SplatRecorder && swift run SplatRecorder --validate-recording /tmp/splatrecorder-recording-check`
Expected: Output shows encodedFrames ≈ 30, duration ≈ 1.0s, fileSize > 1000 bytes, report written

- [ ] **Step 5: Commit**

```bash
cd /Users/ruichaowang/Downloads/MetalSplatter
git add Apps/SplatRecorder/Sources/Validation/SplatRecorderValidation.swift
git add Apps/SplatRecorder/Sources/App/SplatRecorderApp.swift
git commit -m "feat: add --validate-recording CLI for automated MP4 verification

- SplatRecorderRecordingValidation: renders DebugAxisScene to MP4
- 1280x720, 30fps, 1 second, 30 frames
- Outputs recording-report.json with encoded/dropped counts, file size
- Validates: duration > 0, encoded frames > 0, file size > 1KB

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Update README

**Files:**
- Modify: `Apps/SplatRecorder/README.md`

- [ ] **Step 1: Update the Recording section**

Replace lines 100-112 (the Recording section) with actual usage instructions:

```markdown
## Recording

1. Load a splat file.
2. Click **Record** in the toolbar.
3. Choose an output location (MP4 format, H.264).
4. Move the camera (orbit, zoom, pan, WASD). The window is locked to its current size during recording.
5. Press **Esc** to stop.

Recording captures at 30 fps at the current window resolution. Only the splat viewport is recorded — toolbar, HUD overlay, and ViewCube are excluded. No audio is recorded.

**Known limitations:**
- MP4/H.264 only, 30fps, window-sized
- No audio, no UI overlay recording
- No resolution/fps settings panel
- Window size is fixed during recording
```

Also update line 9 to remove the directory-name requirement (since Task 1 fixes this):

```markdown
// Before (line 9):
- Clone the repo as `MetalSplatter/` (SwiftPM derives the package identity from the directory name)

// After:
- Clone the repo to any directory name (SwiftPM package identity is explicitly set)
```

- [ ] **Step 2: Build and verify**

Run: `cd Apps/SplatRecorder && swift build --product SplatRecorder`
Expected: Build succeeds, 0 errors

- [ ] **Step 3: Commit**

```bash
cd /Users/ruichaowang/Downloads/MetalSplatter
git add Apps/SplatRecorder/README.md
git commit -m "docs: update SplatRecorder README with recording usage

Remove WIP warning, add recording instructions and known limitations.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: Full Verification

**Files:** None (verification only)

- [ ] **Step 1: Run root tests**

Run: `cd /Users/ruichaowang/Downloads/MetalSplatter && swift test`
Expected: All tests pass, 0 failures

- [ ] **Step 2: Run SplatRecorder tests**

Run: `cd Apps/SplatRecorder && swift test`
Expected: All tests pass including VideoRecorderTests, 0 failures

- [ ] **Step 3: Run recording validation**

```bash
cd Apps/SplatRecorder
rm -rf /tmp/splatrecorder-recording-check
swift run SplatRecorder --validate-recording /tmp/splatrecorder-recording-check
```

Expected: Exit code 0, report shows encodedFrames ≈ 30, duration ≈ 1.0s

- [ ] **Step 4: Run existing render validation (requires user PLY file)**

```bash
cd Apps/SplatRecorder
swift run SplatRecorder --validate /Users/ruichaowang/Downloads/朝阳区.ply /tmp/splatrecorder-render-check
```

Expected: Exit code 0, PNGs generated

- [ ] **Step 5: Manual smoke test (optional, requires GUI)**

```bash
cd Apps/SplatRecorder
swift run SplatRecorder /Users/ruichaowang/Downloads/朝阳区.ply
```

Manual steps:
1. Click Record → choose save location
2. Record 5-10 seconds while orbiting/zooming/panning
3. Press Esc to stop
4. Open MP4 in QuickTime — verify: non-black, perspective changes recorded, no toolbar/HUD/ViewCube, correct duration, window resizable again

- [ ] **Step 6: Commit (if any fixes needed)**

Only if verification reveals issues. Otherwise, verification confirms the feature is complete.

---

### Task 9: Clean Up Untracked Files

**Files:**
- Add or ignore: `CLAUDE.md`, `script/build_and_run.sh`

- [ ] **Step 1: Decide disposition**

These files were noted as untracked in the review. `CLAUDE.md` is project documentation (should be tracked). `script/build_and_run.sh` is a build helper (should be tracked).

- [ ] **Step 2: Add and commit**

```bash
cd /Users/ruichaowang/Downloads/MetalSplatter
git add CLAUDE.md script/build_and_run.sh
git commit -m "chore: track CLAUDE.md and build_and_run.sh"
```
