import Foundation
import Metal
import MetalSplatter
import simd

/// Thin wrapper that connects OrbitCameraState to SplatRenderer.
/// Builds ViewportDescriptors and drives the render call each frame.
@MainActor
final class SplatMetalRenderer {
    private let renderer: SplatRenderer
    private let camera: OrbitCameraState
    private var drawableSize: SIMD2<Int> = .zero

    init(renderer: SplatRenderer, camera: OrbitCameraState) {
        self.renderer = renderer
        self.camera = camera
    }

    /// Update the stored drawable size (called from mtkView:drawableSizeWillChange:).
    func setDrawableSize(_ size: CGSize) {
        drawableSize = SIMD2(x: Int(size.width), y: Int(size.height))
    }

    /// Whether the renderer is ready to accept render calls.
    var isReadyToRender: Bool {
        renderer.isReadyToRender
    }

    /// Render the current frame to the given texture.
    /// - Parameters:
    ///   - texture: The Metal texture to render color output to.
    ///   - depthTexture: Optional depth texture.
    ///   - commandBuffer: The command buffer to encode into.
    /// - Returns: `true` if rendering was performed.
    @discardableResult
    func render(
        to texture: MTLTexture,
        depthTexture: MTLTexture?,
        commandBuffer: MTLCommandBuffer
    ) throws -> Bool {
        // Guard against rendering before drawableSize is set
        guard drawableSize.x > 0, drawableSize.y > 0 else { return false }
        let aspect = Float(drawableSize.x) / Float(drawableSize.y)
        let projection = camera.projectionMatrix(aspect: aspect)
        let view = camera.viewMatrix

        let viewport = MTLViewport(
            originX: 0, originY: 0,
            width: Double(drawableSize.x), height: Double(drawableSize.y),
            znear: 0, zfar: 1
        )

        let descriptor = SplatRenderer.ViewportDescriptor(
            viewport: viewport,
            projectionMatrix: projection,
            viewMatrix: view,
            screenSize: drawableSize
        )

        return try renderer.render(
            viewports: [descriptor],
            colorTexture: texture,
            colorStoreAction: .store,
            depthTexture: depthTexture,
            rasterizationRateMap: nil,
            renderTargetArrayLength: 0,
            to: commandBuffer
        )
    }
}
