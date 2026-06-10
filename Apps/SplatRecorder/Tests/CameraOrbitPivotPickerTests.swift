import XCTest
import simd
@testable import SplatRecorder

final class CameraOrbitPivotPickerTests: XCTestCase {
    func testCenterRayPivotUsesNearestVisibleDepthAndPreservesEye() throws {
        let camera = OrbitCameraState()
        camera.yaw = 0
        camera.pitch = 0
        camera.distance = 90
        camera.target = SIMD3<Float>(0, 0, -90)

        let before = CameraPoseSnapshot(camera: camera)
        let samples: [SIMD3<Float>] = [
            SIMD3<Float>(0.15, 0, -4),
            SIMD3<Float>(0.01, 0, -12),
            SIMD3<Float>(4, 0, -2)
        ]

        let pivot = try XCTUnwrap(CameraOrbitPivotPicker.centerRayPivot(
            camera: camera,
            sampledPositions: samples,
            maxRayDistance: 0.25
        ))

        XCTAssertEqual(pivot.sourcePoint.x, 0.15, accuracy: 1e-5)
        XCTAssertEqual(pivot.target.x, 0, accuracy: 1e-5)
        XCTAssertEqual(pivot.target.y, 0, accuracy: 1e-5)
        XCTAssertEqual(pivot.target.z, -4, accuracy: 1e-5)
        XCTAssertEqual(pivot.depth, 4, accuracy: 1e-5)

        XCTAssertTrue(camera.applyCenterRayOrbitPivot(sampledPositions: samples, maxRayDistance: 0.25))
        let after = CameraPoseSnapshot(camera: camera)

        XCTAssertSIMD3Equal(after.eye, before.eye, accuracy: 1e-5)
        XCTAssertSIMD3Equal(after.forward, before.forward, accuracy: 1e-5)
        XCTAssertEqual(camera.distance, 4, accuracy: 1e-5)
        XCTAssertSIMD3Equal(camera.target, SIMD3<Float>(0, 0, -4), accuracy: 1e-5)
    }

    func testCenterRayPivotDoesNothingWhenNoSampleIsCloseToRay() {
        let camera = OrbitCameraState()
        camera.yaw = 0
        camera.pitch = 0
        camera.distance = 10
        camera.target = SIMD3<Float>(0, 0, -10)

        let before = CameraPoseSnapshot(camera: camera)
        let samples = [
            SIMD3<Float>(5, 0, -3),
            SIMD3<Float>(-6, 0, -8)
        ]

        XCTAssertFalse(camera.applyCenterRayOrbitPivot(sampledPositions: samples, maxRayDistance: 0.25))
        let after = CameraPoseSnapshot(camera: camera)

        XCTAssertSIMD3Equal(after.target, before.target, accuracy: 1e-5)
        XCTAssertSIMD3Equal(after.eye, before.eye, accuracy: 1e-5)
        XCTAssertEqual(after.distance, before.distance, accuracy: 1e-5)
    }
}

private extension XCTestCase {
    func XCTAssertSIMD3Equal(
        _ lhs: SIMD3<Float>,
        _ rhs: SIMD3<Float>,
        accuracy: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.z, rhs.z, accuracy: accuracy, file: file, line: line)
    }
}
