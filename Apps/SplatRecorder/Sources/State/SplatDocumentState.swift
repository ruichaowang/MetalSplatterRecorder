import Foundation
import Metal
import MetalSplatter
import SplatIO
import simd

/// File load state for the UI to observe.
enum LoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case error(String)
}

/// Manages the current splat file: loading, lifecycle, and associated state.
@MainActor
@Observable
final class SplatDocumentState {
    var fileURL: URL?
    var loadState: LoadState = .idle
    var splatCount: Int = 0
    var visibleSplatCount: Int = 0
    var splatCenter: SIMD3<Float> = .zero
    var splatDiagonal: Float = 1.0
    var debugSampledPositions: [SIMD3<Float>] = []

    let renderer: SplatRenderer
    let camera: OrbitCameraState

    private var chunkID: ChunkID?
    private var chunkAdded = false

    init(device: MTLDevice, camera: OrbitCameraState) {
        self.camera = camera

        do {
            self.renderer = try SplatRenderer(
                device: device,
                colorFormat: .bgra8Unorm_srgb,
                depthFormat: .depth32Float,
                sampleCount: 1,
                maxViewCount: 1,
                maxSimultaneousRenders: 3
            )
        } catch {
            fatalError("Failed to create SplatRenderer: \(error)")
        }
    }

    func openFile(_ url: URL) async {
        loadState = .loading
        fileURL = url

        do {
            // Close previous file if any
            if chunkAdded, let id = chunkID {
                await renderer.removeChunk(id)
                chunkID = nil
                chunkAdded = false
            }

            let reader = try AutodetectSceneReader(url)
            let points = try await reader.readAll()
            splatCount = points.count
            let displayPoints = SplatDisplayTransform.applyIfNeeded(to: points, sourceURL: url)

            let positions = displayPoints.map(\.position)
            let visibleIndices = SplatDisplayBounds.robustVisibleIndices(for: positions)
            let visiblePoints = visibleIndices.count == displayPoints.count ? displayPoints : visibleIndices.map { displayPoints[$0] }
            visibleSplatCount = visiblePoints.count

            let displayBounds = SplatDisplayBounds.rawBounds(for: visiblePoints.map(\.position))
            splatCenter = displayBounds.center
            splatDiagonal = displayBounds.diagonal
            debugSampledPositions = Self.debugSamplePositions(visiblePoints.map(\.position))
            let chunk = try SplatChunk(device: renderer.device, from: visiblePoints)

            // Enable immediately like SampleApp — no sort delay needed for first load
            let id = await renderer.addChunk(chunk, enabled: true)
            chunkID = id
            chunkAdded = true
            loadState = .loaded

            // Focus camera on the loaded splat using SuperSplat's initial view.
            camera.applySuperSplatDefaultView(center: splatCenter, diagonal: splatDiagonal)

        } catch {
            loadState = .error(error.localizedDescription)
        }
    }

    func closeFile() async {
        if chunkAdded, let id = chunkID {
            await renderer.removeChunk(id)
            chunkID = nil
            chunkAdded = false
        }
        fileURL = nil
        loadState = .idle
        splatCount = 0
        visibleSplatCount = 0
        splatCenter = .zero
        splatDiagonal = 1.0
        debugSampledPositions = []
    }

    func resetCameraToDefaultView() {
        camera.applySuperSplatDefaultView(center: splatCenter, diagonal: splatDiagonal)
    }

    static func debugSamplePositions(_ positions: [SIMD3<Float>], limit: Int = 20_000) -> [SIMD3<Float>] {
        guard limit > 0, positions.count > limit else { return positions }
        let step = max(1, Int(ceil(Double(positions.count) / Double(limit))))
        var sampled: [SIMD3<Float>] = []
        sampled.reserveCapacity(limit)
        var index = 0
        while index < positions.count && sampled.count < limit {
            sampled.append(positions[index])
            index += step
        }
        return sampled
    }
}
