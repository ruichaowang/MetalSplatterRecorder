import simd

struct CameraRay: Equatable, Sendable {
    let origin: SIMD3<Float>
    let direction: SIMD3<Float>

    init(origin: SIMD3<Float>, direction: SIMD3<Float>) {
        self.origin = origin
        let length = simd_length(direction)
        self.direction = length > 1e-6 ? direction / length : SIMD3<Float>(0, 0, -1)
    }

    init(camera: OrbitCameraState) {
        let cameraWorld = camera.cameraWorldMatrix
        let eye4 = cameraWorld * SIMD4<Float>(0, 0, 0, 1)
        let forward4 = cameraWorld * SIMD4<Float>(0, 0, -1, 0)
        self.init(
            origin: SIMD3<Float>(eye4.x, eye4.y, eye4.z),
            direction: SIMD3<Float>(forward4.x, forward4.y, forward4.z)
        )
    }

    func projectedDepth(to point: SIMD3<Float>) -> Float {
        simd_dot(point - origin, direction)
    }

    func point(at depth: Float) -> SIMD3<Float> {
        origin + direction * depth
    }

    func distance(to point: SIMD3<Float>) -> Float {
        let depth = max(0, projectedDepth(to: point))
        return simd_distance(point, self.point(at: depth))
    }
}
