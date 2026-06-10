import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalSplatter
import SplatIO
import UniformTypeIdentifiers
import simd

enum SplatRecorderAxisValidation {
    private static let width = 768
    private static let height = 768

    static func run(outputDirectory: URL) async throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw AxisValidationError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw AxisValidationError.noCommandQueue
        }

        var modeReports: [AxisModeReport] = []
        for coordinateSpace in DebugAxisScene.CoordinateSpace.allCases {
            let renderer = try await makeRenderer(for: coordinateSpace, device: device)

            for mode in DebugAxisScene.CameraMode.allCases {
                let camera = DebugAxisScene.makeCamera(mode: mode)
                let outputURL = outputDirectory.appendingPathComponent(outputFilename(for: coordinateSpace, mode: mode))
                let report = try await render(
                    coordinateSpace: coordinateSpace,
                    mode: mode,
                    camera: camera,
                    renderer: renderer,
                    queue: queue,
                    device: device,
                    outputURL: outputURL
                )
                modeReports.append(report)
            }
        }

        let report = AxisDebugReport(
            imageSize: [width, height],
            axisPoints: DebugAxisScene.axisPoints.map(AxisPointReport.init(point:)),
            modes: modeReports
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: outputDirectory.appendingPathComponent("axis-report.json"))

        print("outputDirectory=\(outputDirectory.path)")
        for modeReport in modeReports {
            print(modeReport.summaryLine)
        }
        print("report=\(outputDirectory.appendingPathComponent("axis-report.json").path)")
    }

    private static func makeRenderer(for coordinateSpace: DebugAxisScene.CoordinateSpace, device: MTLDevice) async throws -> SplatRenderer {
        let points = DebugAxisScene.makeSplatPoints(coordinateSpace: coordinateSpace)
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
                renderer.afterNextSort {
                    continuation.resume()
                }
            }
        }
        await renderer.addChunk(chunk, sortByLocality: true, enabled: true)
        await sorted.value
        return renderer
    }

    private static func outputFilename(
        for coordinateSpace: DebugAxisScene.CoordinateSpace,
        mode: DebugAxisScene.CameraMode
    ) -> String {
        switch coordinateSpace {
        case .rawPLY:
            "\(mode.rawValue).png"
        case .superSplatPLY:
            "\(coordinateSpace.rawValue)-\(mode.rawValue).png"
        }
    }

    private static func render(
        coordinateSpace: DebugAxisScene.CoordinateSpace,
        mode: DebugAxisScene.CameraMode,
        camera: OrbitCameraState,
        renderer: SplatRenderer,
        queue: MTLCommandQueue,
        device: MTLDevice,
        outputURL: URL
    ) async throws -> AxisModeReport {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private
        guard let colorTexture = device.makeTexture(descriptor: colorDesc) else {
            throw AxisValidationError.cannotCreateTexture
        }

        let bytesPerRow = width * 4
        guard let readback = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared) else {
            throw AxisValidationError.cannotCreateReadbackBuffer
        }

        let viewport = MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1)
        let descriptor = SplatRenderer.ViewportDescriptor(
            viewport: viewport,
            projectionMatrix: camera.projectionMatrix(aspect: 1),
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
        guard didRender else { throw AxisValidationError.rendererSkippedFrame }

        let measurements = measureAxisPixels(buffer: readback, bytesPerRow: bytesPerRow)
        guard !measurements.isEmpty else {
            throw AxisValidationError.noAxisPixelsMeasured(mode.rawValue)
        }
        try writePNG(from: readback, bytesPerRow: bytesPerRow, url: outputURL)

        let pointReports = DebugAxisScene.axisPoints.map { point in
            let renderedPosition = DebugAxisScene.transform(point.position, to: coordinateSpace)
            let ndc = DebugAxisScene.projectToNDC(renderedPosition, camera: camera, aspect: 1)
            let expected = DebugAxisScene.expectedTopLeftPixel(for: ndc, width: width, height: height)
            return AxisModePointReport(
                name: point.name,
                sourceWorld: point.position.array,
                renderedWorld: renderedPosition.array,
                cpuNDC: ndc.array,
                expectedTopLeftPixel: expected.array,
                measuredPixelCenter: measurements[point.name]?.centerArray,
                measuredPixelCount: measurements[point.name]?.count ?? 0
            )
        }

        return AxisModeReport(
            coordinateSpace: coordinateSpace.rawValue,
            mode: mode.rawValue,
            output: outputURL.path,
            camera: CameraReport(camera: camera),
            points: pointReports
        )
    }

    private static func measureAxisPixels(buffer: MTLBuffer, bytesPerRow: Int) -> [String: PixelAccumulator.Result] {
        let targets = DebugAxisScene.axisPoints.map { point in
            ColorTarget(name: point.name, color: SIMD3<Float>(point.color))
        }
        let pointer = buffer.contents().assumingMemoryBound(to: UInt8.self)
        var accumulators = Dictionary(uniqueKeysWithValues: targets.map { ($0.name, PixelAccumulator()) })

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let b = Float(pointer[offset])
                let g = Float(pointer[offset + 1])
                let r = Float(pointer[offset + 2])
                let intensity = r + g + b
                guard intensity > 24 else { continue }

                let chroma = SIMD3<Float>(r, g, b) / intensity
                guard let nearest = targets.min(by: {
                    simd_length(chroma - $0.chroma) < simd_length(chroma - $1.chroma)
                }) else { continue }
                let distance = simd_length(chroma - nearest.chroma)
                guard distance < 0.16 else { continue }

                accumulators[nearest.name]?.add(x: Float(x), y: Float(y), weight: intensity)
            }
        }

        return accumulators.compactMapValues(\.result)
    }

    private static func writePNG(from buffer: MTLBuffer, bytesPerRow: Int, url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let provider = CGDataProvider(dataInfo: nil, data: buffer.contents(), size: bytesPerRow * height, releaseData: { _, _, _ in }) else {
            throw AxisValidationError.cannotCreateImage
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
            throw AxisValidationError.cannotCreateImage
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AxisValidationError.cannotCreateImageDestination
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            throw AxisValidationError.cannotWriteImage
        }
    }
}

private struct ColorTarget {
    let name: String
    let chroma: SIMD3<Float>

    init(name: String, color: SIMD3<Float>) {
        self.name = name
        self.chroma = color / max(color.x + color.y + color.z, 1)
    }
}

private struct PixelAccumulator {
    struct Result {
        let center: SIMD2<Float>
        let count: Int

        var centerArray: [Float] {
            [center.x, center.y]
        }
    }

    private var weightedX: Float = 0
    private var weightedY: Float = 0
    private var totalWeight: Float = 0
    private var pixelCount: Int = 0

    mutating func add(x: Float, y: Float, weight: Float) {
        weightedX += x * weight
        weightedY += y * weight
        totalWeight += weight
        pixelCount += 1
    }

    var result: Result? {
        guard totalWeight > 0 else { return nil }
        return Result(center: SIMD2(weightedX / totalWeight, weightedY / totalWeight), count: pixelCount)
    }
}

private struct AxisDebugReport: Codable {
    let imageSize: [Int]
    let axisPoints: [AxisPointReport]
    let modes: [AxisModeReport]
}

private struct AxisPointReport: Codable {
    let name: String
    let world: [Float]
    let colorRGB: [UInt8]

    init(point: DebugAxisScene.AxisPoint) {
        name = point.name
        world = point.position.array
        colorRGB = [point.color.x, point.color.y, point.color.z]
    }
}

private struct AxisModeReport: Codable {
    let coordinateSpace: String
    let mode: String
    let output: String
    let camera: CameraReport
    let points: [AxisModePointReport]

    var summaryLine: String {
        let measured = points.filter { $0.measuredPixelCenter != nil }.count
        return "space=\(coordinateSpace) mode=\(mode) measured=\(measured)/\(points.count) output=\(output)"
    }
}

private struct CameraReport: Codable {
    let target: [Float]
    let eye: [Float]
    let yaw: Float
    let pitch: Float
    let distance: Float
    let fovDegrees: Float
    let forward: [Float]
    let right: [Float]
    let up: [Float]

    init(camera: OrbitCameraState) {
        let cameraWorld = camera.cameraWorldMatrix
        let eye4 = cameraWorld * SIMD4<Float>(0, 0, 0, 1)
        let forward4 = cameraWorld * SIMD4<Float>(0, 0, -1, 0)
        let right = SIMD3<Float>(cameraWorld.columns.0.x, cameraWorld.columns.0.y, cameraWorld.columns.0.z)
        let up = SIMD3<Float>(cameraWorld.columns.1.x, cameraWorld.columns.1.y, cameraWorld.columns.1.z)

        target = camera.target.array
        eye = SIMD3<Float>(eye4.x, eye4.y, eye4.z).array
        yaw = camera.yaw
        pitch = camera.pitch
        distance = camera.distance
        fovDegrees = camera.fovRadians * 180 / .pi
        forward = SIMD3<Float>(forward4.x, forward4.y, forward4.z).array
        self.right = right.array
        self.up = up.array
    }
}

private struct AxisModePointReport: Codable {
    let name: String
    let sourceWorld: [Float]
    let renderedWorld: [Float]
    let cpuNDC: [Float]
    let expectedTopLeftPixel: [Float]
    let measuredPixelCenter: [Float]?
    let measuredPixelCount: Int
}

private enum AxisValidationError: LocalizedError {
    case noMetalDevice
    case noCommandQueue
    case cannotCreateTexture
    case cannotCreateReadbackBuffer
    case rendererSkippedFrame
    case noAxisPixelsMeasured(String)
    case cannotCreateImage
    case cannotCreateImageDestination
    case cannotWriteImage

    var errorDescription: String? {
        switch self {
        case .noMetalDevice: "No Metal device is available"
        case .noCommandQueue: "Unable to create Metal command queue"
        case .cannotCreateTexture: "Unable to create render texture"
        case .cannotCreateReadbackBuffer: "Unable to create readback buffer"
        case .rendererSkippedFrame: "Renderer skipped all axis debug frames"
        case .noAxisPixelsMeasured(let mode): "Axis debug frame for \(mode) had no measurable axis pixels"
        case .cannotCreateImage: "Unable to create axis debug image"
        case .cannotCreateImageDestination: "Unable to create axis debug image destination"
        case .cannotWriteImage: "Unable to write axis debug image"
        }
    }
}

private extension SIMD2 where Scalar == Float {
    var array: [Float] {
        [x, y]
    }
}

private extension SIMD3 where Scalar == Float {
    var array: [Float] {
        [x, y, z]
    }
}
