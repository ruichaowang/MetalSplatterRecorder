import Foundation
@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import CoreVideo
import Metal
import Synchronization

/// A single captured frame ready for encoding.
/// Retains CVMetalTexture to prevent the underlying CVPixelBuffer
/// from being recycled before GPU operations complete.
struct RecordingFrame: @unchecked Sendable {
    let cvTexture: CVMetalTexture
    let texture: MTLTexture
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
}

/// Summary returned by stop() for stable post-stop reporting.
struct RecordingSummary {
    let outputURL: URL?
    let encodedFrameCount: Int
    let droppedFrameCount: Int
    let lastError: VideoRecorderError?
}

/// Mutex-based video recorder using AVAssetWriter for H.264 MP4 output.
/// Synchronous capture API — callable from @MainActor draw loop and GPU completion handlers.
final class VideoRecorder: @unchecked Sendable {

    struct State {
        var isRecording = false
        var isStopping = false
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
            s.isStopping = false
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
    /// Handles fps throttling internally. Returns nil if the frame should be skipped
    /// or if recording is stopping.
    func makeFrameTexture(hostTime: CMTime) -> RecordingFrame? {
        state.withLock { s in
            guard s.isRecording, !s.isStopping else { return nil }

            // Frame rate throttling (with epsilon for CMTime precision)
            if s.lastFrameHostTime.isValid {
                let diffSeconds = CMTimeGetSeconds(CMTimeSubtract(hostTime, s.lastFrameHostTime))
                let intervalSeconds = 1.0 / Double(s.targetFPS)
                if diffSeconds < intervalSeconds - 0.0001 {
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
    /// After stop() sets isStopping, this still allows already-captured tail frames
    /// to be appended as long as the writer/adaptor are still alive.
    func finishFrame(_ frame: RecordingFrame) {
        // Extract adaptor ref under lock, then call append outside lock
        // to avoid task-isolation conflict with @MainActor-isolated API.
        let adaptor: AVAssetWriterInputPixelBufferAdaptor?
        adaptor = state.withLock { s -> AVAssetWriterInputPixelBufferAdaptor? in
            guard let inp = s.assetWriterInput, inp.isReadyForMoreMediaData else {
                s.droppedFrameCount += 1
                s.inflightFrameCount -= 1
                return nil
            }
            return s.pixelBufferAdaptor
        }

        guard let adaptor else { return }

        let success = adaptor.append(frame.pixelBuffer, withPresentationTime: frame.presentationTime)
        state.withLock { s in
            if success {
                s.encodedFrameCount += 1
            } else {
                s.droppedFrameCount += 1
            }
            s.inflightFrameCount -= 1
        }
    }

    /// Release an inflight frame that was never rendered or whose render failed.
    /// Must be called for every RecordingFrame that was created but won't be
    /// submitted via finishFrame, to avoid stop() hanging waiting for inflight count.
    func discardFrame(_ frame: RecordingFrame) {
        state.withLock { s in
            s.droppedFrameCount += 1
            s.inflightFrameCount -= 1
        }
        // frame (and its retained resources) released when out of scope
        _ = frame
    }

    // MARK: - Stop / Cancel

    /// Stop recording and finalize the MP4. Blocks until all inflight frames
    /// are drained and the writer finishes.
    ///
    /// - Returns: A `RecordingSummary` with stable post-stop stats, or `nil`
    ///   if there was no active recording to stop (idle/idempotent).
    func stop() throws -> RecordingSummary? {
        // Check if there's an active writer to stop
        let hasWriter: Bool = state.withLock { s in
            s.assetWriter != nil && s.isRecording
        }
        guard hasWriter else {
            // Idle or already stopped — return nil immediately
            return nil
        }

        // 1. Mark stopping — prevents new frames from being created
        state.withLock { s in
            s.isStopping = true
            s.isRecording = false
        }

        // 2. Drain inflight frames (with 5s timeout)
        let deadline = DispatchTime.now() + .seconds(5)
        while state.withLock({ $0.inflightFrameCount > 0 }) {
            if DispatchTime.now() > deadline {
                throw VideoRecorderError.stopTimeout
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        // 3. Finalize writer (extract refs from lock first)
        let (writer, input) = state.withLock { s -> (AVAssetWriter?, AVAssetWriterInput?) in
            return (s.assetWriter, s.assetWriterInput)
        }

        let semaphore = DispatchSemaphore(value: 0)
        input?.markAsFinished()
        writer?.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        // 4. Build summary BEFORE teardown clears state
        let summary = state.withLock { s in
            RecordingSummary(
                outputURL: s.outputURL,
                encodedFrameCount: s.encodedFrameCount,
                droppedFrameCount: s.droppedFrameCount,
                lastError: s.lastError
            )
        }

        teardown()

        if let error = writer?.error {
            throw VideoRecorderError.finishWritingFailed(error)
        }

        return summary
    }

    /// Cancel recording, discarding the output file.
    func cancel() {
        state.withLock { s in
            s.isRecording = false
            s.isStopping = true
        }
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
            s.isStopping = false
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
