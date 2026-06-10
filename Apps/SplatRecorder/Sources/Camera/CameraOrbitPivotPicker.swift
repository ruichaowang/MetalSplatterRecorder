import simd

struct CameraOrbitPivot: Equatable, Sendable {
    let target: SIMD3<Float>
    let sourcePoint: SIMD3<Float>
    let depth: Float
    let rayDistance: Float
}

enum CameraOrbitPivotPicker {
    static func centerRayPivot(
        camera: OrbitCameraState,
        sampledPositions: [SIMD3<Float>],
        maxRayDistance: Float? = nil
    ) -> CameraOrbitPivot? {
        guard !sampledPositions.isEmpty else { return nil }

        let ray = CameraRay(camera: camera)
        let maxDistance = maxRayDistance ?? defaultMaxRayDistance(camera: camera)
        var best: CameraOrbitPivot?

        for point in sampledPositions {
            let depth = ray.projectedDepth(to: point)
            guard depth > 0.05 else { continue }

            let target = ray.point(at: depth)
            let rayDistance = simd_distance(point, target)
            guard rayDistance <= maxDistance else { continue }

            if best == nil || depth < best!.depth {
                best = CameraOrbitPivot(
                    target: target,
                    sourcePoint: point,
                    depth: depth,
                    rayDistance: rayDistance
                )
            }
        }

        return best
    }

    private static func defaultMaxRayDistance(camera: OrbitCameraState) -> Float {
        max(0.1, min(camera.distance * 0.02, 2.0))
    }
}
