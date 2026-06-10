import XCTest
import simd
import SplatIO
@testable import SplatRecorder

final class SplatDisplayTransformTests: XCTestCase {
    func testSuperSplatPLYTransformFlipsPositionAroundZ() {
        let point = makePoint(position: SIMD3<Float>(1, 2, 3))

        let transformed = SplatDisplayTransform.applySuperSplatPLY(to: point)

        XCTAssertEqual(transformed.position.x, -1, accuracy: 1e-6)
        XCTAssertEqual(transformed.position.y, -2, accuracy: 1e-6)
        XCTAssertEqual(transformed.position.z, 3, accuracy: 1e-6)
    }

    func testSuperSplatPLYTransformComposesRotationBeforeGaussianRotation() {
        let rawRotation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let point = makePoint(rotation: rawRotation)

        let transformed = SplatDisplayTransform.applySuperSplatPLY(to: point)
        let expected = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1)) * rawRotation

        XCTAssertTrue(transformed.rotation.normalized.act(SIMD3<Float>(0, 1, 0)).isClose(
            to: expected.normalized.act(SIMD3<Float>(0, 1, 0)),
            tolerance: 1e-5
        ))
        XCTAssertTrue(transformed.rotation.normalized.act(SIMD3<Float>(0, 0, 1)).isClose(
            to: expected.normalized.act(SIMD3<Float>(0, 0, 1)),
            tolerance: 1e-5
        ))
    }

    func testSuperSplatPLYTransformRotatesHigherOrderSHSigns() throws {
        let coefficients = (0..<16).map { i in
            SIMD3<Float>(Float(i), Float(i) + 0.25, Float(i) + 0.5)
        }
        let point = makePoint(color: .sphericalHarmonicFloat(coefficients))

        let transformed = SplatDisplayTransform.applySuperSplatPLY(to: point)
        let transformedCoefficients = transformed.color.asSphericalHarmonicFloat

        let expectedSigns: [Float] = [
            1,
            -1, 1, -1,
            1, -1, 1, -1, 1,
            -1, 1, -1, 1, -1, 1, -1,
        ]
        XCTAssertEqual(transformedCoefficients.count, coefficients.count)
        for i in coefficients.indices {
            XCTAssertTrue(transformedCoefficients[i].isClose(to: coefficients[i] * expectedSigns[i], tolerance: 1e-6),
                          "Unexpected SH coefficient at index \(i)")
        }
    }

    func testDisplayTransformAppliesToSupportedSplatFormats() {
        let point = makePoint(position: SIMD3<Float>(1, 2, 3))

        for path in ["scene.ply", "scene.splat", "scene.spz"] {
            let transformed = SplatDisplayTransform.applyIfNeeded(to: [point], sourceURL: URL(fileURLWithPath: path))
            let transformedPoint = try! XCTUnwrap(transformed.first)
            XCTAssertEqual(transformedPoint.position.x, -1, accuracy: 1e-6, "Expected transform for \(path)")
            XCTAssertEqual(transformedPoint.position.y, -2, accuracy: 1e-6, "Expected transform for \(path)")
            XCTAssertEqual(transformedPoint.position.z, 3, accuracy: 1e-6, "Expected transform for \(path)")
        }
    }

    private func makePoint(
        position: SIMD3<Float> = .zero,
        color: SplatPoint.Color = .sphericalHarmonicFloat([SIMD3<Float>(0.5, 0.5, 0.5)]),
        rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    ) -> SplatPoint {
        SplatPoint(
            position: position,
            color: color,
            opacity: .linearFloat(1),
            scale: .linearFloat(SIMD3<Float>(repeating: 1)),
            rotation: rotation
        )
    }
}

private extension SIMD3 where Scalar == Float {
    func isClose(to other: SIMD3<Float>, tolerance: Float) -> Bool {
        abs(x - other.x) <= tolerance &&
        abs(y - other.y) <= tolerance &&
        abs(z - other.z) <= tolerance
    }
}
