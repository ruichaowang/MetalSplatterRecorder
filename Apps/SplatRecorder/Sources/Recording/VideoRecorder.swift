import Foundation
@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import CoreVideo
import Metal

/// A single captured frame ready for encoding.
struct RecordingFrame: @unchecked Sendable {
    let texture: MTLTexture
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
}

/// Actor-based video recorder using AVAssetWriter for H.264 MP4 output.
/// Uses Scheme B: renders once to a recording texture, then blits to drawable.
actor VideoRecorder: @unchecked Sendable {
    private(set) var isRecording = false

    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pixelBufferPool: CVPixelBufferPool?
    private var textureCache: CVMetalTextureCache?

    private var outputURL: URL?
    private var videoSize: CGSize = .zero
    private var targetFPS: Int = 30
    private var lastCaptureTime: CMTime = .invalid

    // MARK: - Public API

    func start(url: URL, size: CGSize, device: MTLDevice, fps: Int = 30) throws {
        guard !isRecording else { return }

        self.outputURL = url
        self.videoSize = size
        self.targetFPS = fps
        self.lastCaptureTime = .invalid

        // Remove existing file if any
        try? FileManager.default.removeItem(at: url)

        // Create AVAssetWriter
        assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // H.264 video settings
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(size.width * size.height * 10),
                AVVideoMaxKeyFrameIntervalKey: 30,
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        assetWriterInput = input

        // Pixel buffer adaptor attributes
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
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
        pixelBufferPool = pool

        // Create Metal texture cache
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache

        guard let writer = assetWriter, writer.canAdd(input) else {
            throw VideoRecorderError.cannotAddInput
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        isRecording = true
    }

    /// Creates a pixel-buffer-backed Metal texture for recording a frame.
    /// Returns nil if: not recording, frame interval too short, or pool exhausted.
    /// Note: This is the actor-isolated version. Task 12 will add a @MainActor synchronous version.
    func makeFrameTexture(
        commandBuffer: MTLCommandBuffer,
        presentationTime: CMTime
    ) -> RecordingFrame? {
        guard isRecording, let pool = pixelBufferPool, let cache = textureCache else {
            return nil
        }

        // Frame rate throttling
        if lastCaptureTime.isValid {
            let targetInterval = CMTime(value: 1, timescale: Int32(targetFPS))
            if CMTimeSubtract(presentationTime, lastCaptureTime) < targetInterval {
                return nil
            }
        }

        // Get pixel buffer from pool
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else {
            return nil
        }

        // Create Metal texture from pixel buffer
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pb, nil, .bgra8Unorm,
            Int(videoSize.width), Int(videoSize.height), 0, &cvTexture
        )
        guard let cvTex = cvTexture, let texture = CVMetalTextureGetTexture(cvTex) else {
            return nil
        }

        lastCaptureTime = presentationTime
        return RecordingFrame(texture: texture, pixelBuffer: pb, presentationTime: presentationTime)
    }

    /// Submit a captured frame for encoding.
    nonisolated func finishFrame(_ frame: RecordingFrame) {
        let captured = self
        Task { await captured._finishFrame(frame) }
    }

    private func _finishFrame(_ frame: RecordingFrame) {
        guard isRecording else { return }
        guard let input = assetWriterInput, input.isReadyForMoreMediaData else { return }
        guard let adaptor = pixelBufferAdaptor else { return }
        adaptor.append(frame.pixelBuffer, withPresentationTime: frame.presentationTime)
    }

    /// Normal stop: finalize the MP4 file.
    func stop() async {
        guard isRecording else { return }
        isRecording = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            assetWriterInput?.markAsFinished()
            assetWriter?.finishWriting {
                continuation.resume()
            }
        }

        teardown()
    }

    /// Cancel: discard the recording.
    func cancel() async {
        guard isRecording else { return }
        isRecording = false

        assetWriter?.cancelWriting()
        // Clean up partial file
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }

        teardown()
    }

    // MARK: - Private

    private func teardown() {
        assetWriter = nil
        assetWriterInput = nil
        pixelBufferAdaptor = nil
        pixelBufferPool = nil
        textureCache = nil
        outputURL = nil
        lastCaptureTime = .invalid
    }
}

enum VideoRecorderError: Error {
    case cannotAddInput
}
