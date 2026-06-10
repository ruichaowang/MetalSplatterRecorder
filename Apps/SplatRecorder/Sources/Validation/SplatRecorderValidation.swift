import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalSplatter
import SplatIO
import UniformTypeIdentifiers
import simd

enum SplatRecorderValidation {
    private static let width = 1280
    private static let height = 720

    static func run(inputURL: URL, outputDirectory: URL) async throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ValidationError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw ValidationError.noCommandQueue
        }

        let readStart = Date()
        let reader = try AutodetectSceneReader(inputURL)
        let points = try await reader.readAll()
        let readSeconds = -readStart.timeIntervalSinceNow
        guard !points.isEmpty else { throw ValidationError.emptyScene }
        let displayPoints = SplatDisplayTransform.applyIfNeeded(to: points, sourceURL: inputURL)

        let rawBounds = SplatDisplayBounds.rawBounds(for: points.map(\.position))
        let positions = displayPoints.map(\.position)
        let visibleIndices = SplatDisplayBounds.robustVisibleIndices(for: positions)
        let visiblePoints = visibleIndices.count == displayPoints.count ? displayPoints : visibleIndices.map { displayPoints[$0] }
        let displayBounds = SplatDisplayBounds.rawBounds(for: visiblePoints.map(\.position))
        let center = displayBounds.center
        let diagonal = displayBounds.diagonal

        let chunkStart = Date()
        let chunk = try SplatChunk(device: device, from: visiblePoints)
        let chunkSeconds = -chunkStart.timeIntervalSinceNow

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
                renderer.afterNextSort {
                    continuation.resume()
                }
            }
        }
        await renderer.addChunk(chunk, sortByLocality: true, enabled: true)
        await sorted.value

        print("input=\(inputURL.path)")
        print("points=\(points.count)")
        print("visiblePoints=\(visiblePoints.count)")
        print("readSeconds=\(String(format: "%.3f", readSeconds))")
        print("chunkSeconds=\(String(format: "%.3f", chunkSeconds))")
        print("rawBoundsMin=\(rawBounds.min)")
        print("rawBoundsMax=\(rawBounds.max)")
        print("displayBoundsMin=\(displayBounds.min)")
        print("displayBoundsMax=\(displayBounds.max)")
        print("displayCenter=\(center)")
        print("displayDiagonal=\(diagonal)")

        var summaries: [String] = []
        for mode in ValidationMode.allCases {
            let camera = OrbitCameraState()
            camera.applySuperSplatDefaultView(center: center, diagonal: diagonal)
            mode.apply(to: camera)

            let outputURL = outputDirectory.appendingPathComponent("\(mode.rawValue).png")
            let summary = try await render(
                mode: mode,
                camera: camera,
                renderer: renderer,
                queue: queue,
                device: device,
                outputURL: outputURL
            )
            summaries.append(summary)
        }

        for summary in summaries {
            print(summary)
        }
    }

    private static func render(
        mode: ValidationMode,
        camera: OrbitCameraState,
        renderer: SplatRenderer,
        queue: MTLCommandQueue,
        device: MTLDevice,
        outputURL: URL
    ) async throws -> String {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private
        guard let colorTexture = device.makeTexture(descriptor: colorDesc) else {
            throw ValidationError.cannotCreateTexture
        }

        let bytesPerRow = width * 4
        guard let readback = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared) else {
            throw ValidationError.cannotCreateReadbackBuffer
        }

        let viewport = MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1)
        let descriptor = SplatRenderer.ViewportDescriptor(
            viewport: viewport,
            projectionMatrix: camera.projectionMatrix(aspect: Float(width) / Float(height)),
            viewMatrix: camera.viewMatrix,
            screenSize: SIMD2(x: width, y: height)
        )

        var didRender = false
        for _ in 0..<5 {
            guard let commandBuffer = queue.makeCommandBuffer() else { continue }
            didRender = try renderer.render(
                viewports: [descriptor],
                colorTexture: colorTexture,
                colorStoreAction: .store,
                depthTexture: nil,
                rasterizationRateMap: nil,
                renderTargetArrayLength: 0,
                accessTimeout: 1,
                sortTimeout: 1,
                to: commandBuffer
            )
            if didRender, let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(
                    from: colorTexture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: width, height: height, depth: 1),
                    to: readback,
                    destinationOffset: 0,
                    destinationBytesPerRow: bytesPerRow,
                    destinationBytesPerImage: bytesPerRow * height
                )
                blit.endEncoding()
            }
            commandBuffer.commit()
            await commandBuffer.completed()
            if didRender { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard didRender else { throw ValidationError.rendererSkippedFrame }

        let nonBlack = nonBlackPixelCount(buffer: readback, bytesPerRow: bytesPerRow)
        guard nonBlack > 0 else { throw ValidationError.blackFrame(mode.rawValue) }

        try writePNG(from: readback, bytesPerRow: bytesPerRow, url: outputURL)

        return [
            "mode=\(mode.rawValue)",
            "distance=\(String(format: "%.3f", camera.distance))",
            "yaw=\(String(format: "%.3f", camera.yaw))",
            "pitch=\(String(format: "%.3f", camera.pitch))",
            "nonBlackPixels=\(nonBlack)/\(width * height)",
            "output=\(outputURL.path)",
        ].joined(separator: " ")
    }

    private static func nonBlackPixelCount(buffer: MTLBuffer, bytesPerRow: Int) -> Int {
        let pointer = buffer.contents().assumingMemoryBound(to: UInt8.self)
        var nonBlack = 0
        for i in stride(from: 0, to: bytesPerRow * height, by: 4) {
            if pointer[i] != 0 || pointer[i + 1] != 0 || pointer[i + 2] != 0 {
                nonBlack += 1
            }
        }
        return nonBlack
    }

    private static func writePNG(from buffer: MTLBuffer, bytesPerRow: Int, url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let provider = CGDataProvider(dataInfo: nil, data: buffer.contents(), size: bytesPerRow * height, releaseData: { _, _, _ in }) else {
            throw ValidationError.cannotCreateImage
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw ValidationError.cannotCreateImage
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ValidationError.cannotCreateImageDestination
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            throw ValidationError.cannotWriteImage
        }
    }
}

private enum ValidationMode: String, CaseIterable {
    case focus
    case orbit
    case zoom

    func apply(to camera: OrbitCameraState) {
        switch self {
        case .focus:
            break
        case .orbit:
            camera.orbit(dx: -35 / OrbitCameraState.orbitSensitivity * .pi / 180, dy: -20 / OrbitCameraState.orbitSensitivity * .pi / 180)
        case .zoom:
            camera.distance *= 0.65
        }
    }
}

private enum ValidationError: LocalizedError {
    case noMetalDevice
    case noCommandQueue
    case emptyScene
    case cannotCreateTexture
    case cannotCreateReadbackBuffer
    case rendererSkippedFrame
    case blackFrame(String)
    case cannotCreateImage
    case cannotCreateImageDestination
    case cannotWriteImage

    var errorDescription: String? {
        switch self {
        case .noMetalDevice: "No Metal device is available"
        case .noCommandQueue: "Unable to create Metal command queue"
        case .emptyScene: "The scene contains no splats"
        case .cannotCreateTexture: "Unable to create render texture"
        case .cannotCreateReadbackBuffer: "Unable to create readback buffer"
        case .rendererSkippedFrame: "Renderer skipped all validation frames"
        case .blackFrame(let mode): "Validation frame for \(mode) was black"
        case .cannotCreateImage: "Unable to create validation image"
        case .cannotCreateImageDestination: "Unable to create validation image destination"
        case .cannotWriteImage: "Unable to write validation image"
        }
    }
}
