import Foundation
import simd

struct CameraPoseSnapshot: Codable, Equatable, Sendable {
    let target: SIMD3<Float>
    let eye: SIMD3<Float>
    let forward: SIMD3<Float>
    let right: SIMD3<Float>
    let up: SIMD3<Float>
    let yaw: Float
    let pitch: Float
    let distance: Float
    let fovRadians: Float

    init(camera: OrbitCameraState) {
        let cameraWorld = camera.cameraWorldMatrix
        let eye4 = cameraWorld * SIMD4<Float>(0, 0, 0, 1)
        let forward4 = cameraWorld * SIMD4<Float>(0, 0, -1, 0)

        target = camera.target
        eye = SIMD3<Float>(eye4.x, eye4.y, eye4.z)
        forward = simd_normalize(SIMD3<Float>(forward4.x, forward4.y, forward4.z))
        right = simd_normalize(SIMD3<Float>(
            cameraWorld.columns.0.x,
            cameraWorld.columns.0.y,
            cameraWorld.columns.0.z
        ))
        up = simd_normalize(SIMD3<Float>(
            cameraWorld.columns.1.x,
            cameraWorld.columns.1.y,
            cameraWorld.columns.1.z
        ))
        yaw = camera.yaw
        pitch = camera.pitch
        distance = camera.distance
        fovRadians = camera.fovRadians
    }
}

struct CameraDebugProbe: Codable, Equatable, Sendable {
    let targetScreenPixel: SIMD2<Float>?
    let splatCenterScreenPixel: SIMD2<Float>?
    let targetToSplatCenterDistance: Float
    let nearestPointToTargetDistance: Float?
    let nearestPointToTarget: SIMD3<Float>?
    let nearestPointToCenterRayDistance: Float?
    let nearestPointToCenterRay: SIMD3<Float>?
    let nearestPointToCenterRayScreenPixel: SIMD2<Float>?
    let sampledPointCount: Int

    static func evaluate(
        camera: OrbitCameraState,
        splatCenter: SIMD3<Float>,
        sampledPositions: [SIMD3<Float>],
        viewportSize: SIMD2<Int>
    ) -> CameraDebugProbe {
        let pose = CameraPoseSnapshot(camera: camera)
        let aspect = viewportSize.y > 0 ? Float(viewportSize.x) / Float(viewportSize.y) : 1
        let centerRay = CameraRay(origin: pose.eye, direction: pose.forward)

        var nearestTargetPoint: SIMD3<Float>?
        var nearestTargetDistance: Float?
        var nearestRayPoint: SIMD3<Float>?
        var nearestRayDistance: Float?

        for position in sampledPositions {
            let targetDistance = simd_distance(position, pose.target)
            if nearestTargetDistance == nil || targetDistance < nearestTargetDistance! {
                nearestTargetDistance = targetDistance
                nearestTargetPoint = position
            }

            let rayDistance = centerRay.distance(to: position)
            if nearestRayDistance == nil || rayDistance < nearestRayDistance! {
                nearestRayDistance = rayDistance
                nearestRayPoint = position
            }
        }

        return CameraDebugProbe(
            targetScreenPixel: projectToPixel(pose.target, camera: camera, aspect: aspect, viewportSize: viewportSize),
            splatCenterScreenPixel: projectToPixel(splatCenter, camera: camera, aspect: aspect, viewportSize: viewportSize),
            targetToSplatCenterDistance: simd_distance(pose.target, splatCenter),
            nearestPointToTargetDistance: nearestTargetDistance,
            nearestPointToTarget: nearestTargetPoint,
            nearestPointToCenterRayDistance: nearestRayDistance,
            nearestPointToCenterRay: nearestRayPoint,
            nearestPointToCenterRayScreenPixel: nearestRayPoint.flatMap {
                projectToPixel($0, camera: camera, aspect: aspect, viewportSize: viewportSize)
            },
            sampledPointCount: sampledPositions.count
        )
    }

    private static func projectToPixel(
        _ point: SIMD3<Float>,
        camera: OrbitCameraState,
        aspect: Float,
        viewportSize: SIMD2<Int>
    ) -> SIMD2<Float>? {
        guard viewportSize.x > 0, viewportSize.y > 0 else { return nil }
        let clip = camera.projectionMatrix(aspect: aspect) * camera.viewMatrix * SIMD4<Float>(point.x, point.y, point.z, 1)
        guard abs(clip.w) > 1e-6 else { return nil }
        let ndc = SIMD3<Float>(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w)
        guard ndc.x.isFinite, ndc.y.isFinite else { return nil }
        return SIMD2<Float>(
            (ndc.x + 1) * 0.5 * Float(viewportSize.x),
            (1 - ndc.y) * 0.5 * Float(viewportSize.y)
        )
    }
}

enum CameraDebugEvent: String, Codable, Sendable {
    case debugEnabled = "debug_enabled"
    case fileLoaded = "file_loaded"
    case mouseDown = "mouse_down"
    case orbitDrag = "orbit_drag"
    case panDrag = "pan_drag"
    case zoomDrag = "zoom_drag"
    case mouseUp = "mouse_up"
    case keySnapshot = "key_snapshot"
}

struct CameraDebugInput: Codable, Equatable, Sendable {
    let button: Int?
    let key: String?
    let dx: Float?
    let dy: Float?

    static let empty = CameraDebugInput(button: nil, key: nil, dx: nil, dy: nil)

    enum CodingKeys: String, CodingKey {
        case button
        case key
        case dx
        case dy
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encode(button, forKey: .button, in: &container)
        try encode(key, forKey: .key, in: &container)
        try encode(dx, forKey: .dx, in: &container)
        try encode(dy, forKey: .dy, in: &container)
    }

    private func encode<T: Encodable>(
        _ value: T?,
        forKey key: CodingKeys,
        in container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}

struct CameraDebugDragTrace: Codable, Equatable, Sendable {
    let event: CameraDebugEvent
    let button: Int
    let dx: Float
    let dy: Float
    let before: CameraPoseSnapshot
    let after: CameraPoseSnapshot
    let probe: CameraDebugProbe?

    var targetDelta: SIMD3<Float> {
        after.target - before.target
    }
}
