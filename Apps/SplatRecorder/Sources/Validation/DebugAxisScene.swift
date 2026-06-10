import Foundation
import SplatIO
import simd

enum DebugAxisScene {
    struct AxisPoint: Sendable {
        let name: String
        let position: SIMD3<Float>
        let color: SIMD3<UInt8>
    }

    enum CameraMode: String, CaseIterable, Sendable {
        case front
        case defaultView = "default"
        case top
    }

    enum CoordinateSpace: String, CaseIterable, Sendable {
        case rawPLY = "raw-ply"
        case superSplatPLY = "supersplat-ply"
    }

    static let axisPoints: [AxisPoint] = [
        AxisPoint(name: "origin", position: SIMD3<Float>(0, 0, 0), color: SIMD3<UInt8>(255, 255, 255)),
        AxisPoint(name: "+X", position: SIMD3<Float>(1.5, 0, 0), color: SIMD3<UInt8>(255, 0, 0)),
        AxisPoint(name: "-X", position: SIMD3<Float>(-1.5, 0, 0), color: SIMD3<UInt8>(255, 255, 0)),
        AxisPoint(name: "+Y", position: SIMD3<Float>(0, 1.5, 0), color: SIMD3<UInt8>(0, 255, 0)),
        AxisPoint(name: "-Y", position: SIMD3<Float>(0, -1.5, 0), color: SIMD3<UInt8>(0, 255, 255)),
        AxisPoint(name: "+Z", position: SIMD3<Float>(0, 0, 1.5), color: SIMD3<UInt8>(0, 0, 255)),
        AxisPoint(name: "-Z", position: SIMD3<Float>(0, 0, -1.5), color: SIMD3<UInt8>(255, 0, 255)),
    ]

    static func transform(_ position: SIMD3<Float>, to coordinateSpace: CoordinateSpace) -> SIMD3<Float> {
        switch coordinateSpace {
        case .rawPLY:
            position
        case .superSplatPLY:
            SplatDisplayTransform.applySuperSplatPLY(to: makeSplatPoint(position: position)).position
        }
    }

    static func makeSplatPoints(coordinateSpace: CoordinateSpace = .rawPLY, scale: Float = 0.16) -> [SplatPoint] {
        axisPoints.map { point in
            let splatPoint = SplatPoint(
                position: transform(point.position, to: coordinateSpace),
                color: .sRGBUInt8(point.color),
                opacity: .linearFloat(1),
                scale: .linearFloat(SIMD3<Float>(repeating: scale)),
                rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            )
            switch coordinateSpace {
            case .rawPLY:
                return splatPoint
            case .superSplatPLY:
                return SplatDisplayTransform.applySuperSplatPLY(to: makeSplatPoint(
                    position: point.position,
                    color: .sRGBUInt8(point.color),
                    scale: SIMD3<Float>(repeating: scale)
                ))
            }
        }
    }

    private static func makeSplatPoint(
        position: SIMD3<Float>,
        color: SplatPoint.Color = .sRGBUInt8(SIMD3<UInt8>(255, 255, 255)),
        scale: SIMD3<Float> = SIMD3<Float>(repeating: 0.16)
    ) -> SplatPoint {
        SplatPoint(
            position: position,
            color: color,
            opacity: .linearFloat(1),
            scale: .linearFloat(scale),
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        )
    }

    static func makeCamera(mode: CameraMode) -> OrbitCameraState {
        let camera = OrbitCameraState()
        camera.target = .zero
        camera.distance = 6
        camera.fovRadians = 75 * .pi / 180

        switch mode {
        case .front:
            camera.yaw = 0
            camera.pitch = 0
        case .defaultView:
            camera.yaw = OrbitCameraState.superSplatInitialYaw
            camera.pitch = OrbitCameraState.superSplatInitialPitch
        case .top:
            camera.yaw = 0
            // Avoid the exact +/-90 degree singularity in OrbitCameraState.viewMatrix.
            camera.pitch = 80 * .pi / 180
        }

        return camera
    }

    static func projectToNDC(_ point: SIMD3<Float>, camera: OrbitCameraState, aspect: Float) -> SIMD3<Float> {
        let clip = camera.projectionMatrix(aspect: aspect) * camera.viewMatrix * SIMD4<Float>(point.x, point.y, point.z, 1)
        return SIMD3<Float>(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w)
    }

    static func expectedTopLeftPixel(for ndc: SIMD3<Float>, width: Int, height: Int) -> SIMD2<Float> {
        SIMD2<Float>(
            (ndc.x + 1) * 0.5 * Float(width),
            (1 - ndc.y) * 0.5 * Float(height)
        )
    }
}
