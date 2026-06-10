import Foundation
import SplatIO
import simd

enum SplatDisplayTransform {
    private static let superSplatPLYRotation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1))
    private static let superSplatPLYSHSigns: [Float] = [
        1,
        -1, 1, -1,
        1, -1, 1, -1, 1,
        -1, 1, -1, 1, -1, 1, -1,
    ]

    static func applyIfNeeded(to points: [SplatPoint], sourceURL: URL) -> [SplatPoint] {
        guard SplatFileFormat(for: sourceURL) != nil else {
            return points
        }
        return points.map(applySuperSplatPLY(to:))
    }

    static func applySuperSplatPLY(to point: SplatPoint) -> SplatPoint {
        SplatPoint(
            position: SIMD3<Float>(-point.position.x, -point.position.y, point.position.z),
            color: applySuperSplatPLY(to: point.color),
            opacity: point.opacity,
            scale: point.scale,
            rotation: (superSplatPLYRotation * point.rotation).normalized
        )
    }

    private static func applySuperSplatPLY(to color: SplatPoint.Color) -> SplatPoint.Color {
        guard case var .sphericalHarmonicFloat(coefficients) = color else {
            return color
        }

        for i in 0..<min(coefficients.count, superSplatPLYSHSigns.count) {
            coefficients[i] *= superSplatPLYSHSigns[i]
        }
        return .sphericalHarmonicFloat(coefficients)
    }
}
