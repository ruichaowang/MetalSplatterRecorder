import XCTest
import simd
@testable import SplatRecorder

final class CameraDebugProbeTests: XCTestCase {
    func testPoseSnapshotExportsCameraBasis() {
        let camera = OrbitCameraState()
        camera.yaw = 0
        camera.pitch = 0
        camera.distance = 6
        camera.target = SIMD3<Float>(1, 2, 3)

        let snapshot = CameraPoseSnapshot(camera: camera)

        XCTAssertEqual(snapshot.target.x, 1, accuracy: 1e-5)
        XCTAssertEqual(snapshot.target.y, 2, accuracy: 1e-5)
        XCTAssertEqual(snapshot.target.z, 3, accuracy: 1e-5)
        XCTAssertEqual(snapshot.eye.x, 1, accuracy: 1e-5)
        XCTAssertEqual(snapshot.eye.y, 2, accuracy: 1e-5)
        XCTAssertEqual(snapshot.eye.z, 9, accuracy: 1e-5)
        XCTAssertEqual(snapshot.forward.x, 0, accuracy: 1e-5)
        XCTAssertEqual(snapshot.forward.y, 0, accuracy: 1e-5)
        XCTAssertEqual(snapshot.forward.z, -1, accuracy: 1e-5)
        XCTAssertEqual(snapshot.right.x, 1, accuracy: 1e-5)
        XCTAssertEqual(snapshot.up.y, 1, accuracy: 1e-5)
    }

    func testProbeFindsNearestPointToTargetAndCenterRay() {
        let camera = OrbitCameraState()
        camera.yaw = 0
        camera.pitch = 0
        camera.distance = 6
        camera.target = .zero

        let positions: [SIMD3<Float>] = [
            SIMD3<Float>(5, 0, 0),
            SIMD3<Float>(0.25, 0, -2),
            SIMD3<Float>(3, 0, -2),
        ]

        let probe = CameraDebugProbe.evaluate(
            camera: camera,
            splatCenter: SIMD3<Float>(2, 0, -2),
            sampledPositions: positions,
            viewportSize: SIMD2<Int>(x: 800, y: 600)
        )

        XCTAssertEqual(probe.sampledPointCount, 3)
        XCTAssertEqual(probe.targetScreenPixel?.x ?? -1, 400, accuracy: 1e-3)
        XCTAssertEqual(probe.targetScreenPixel?.y ?? -1, 300, accuracy: 1e-3)
        XCTAssertEqual(probe.nearestPointToTargetDistance ?? -1, 2.015564, accuracy: 1e-4)
        XCTAssertEqual(probe.nearestPointToCenterRayDistance ?? -1, 0.25, accuracy: 1e-4)
        XCTAssertEqual(probe.nearestPointToCenterRay?.x ?? -1, 0.25, accuracy: 1e-4)
    }

    func testOrbitTraceKeepsTargetFixedButMovesEye() {
        let camera = OrbitCameraState()
        camera.yaw = 0
        camera.pitch = 0
        camera.distance = 6
        camera.target = SIMD3<Float>(1, 0, -1)

        let before = CameraPoseSnapshot(camera: camera)
        camera.orbit(dx: 20, dy: 0)
        let after = CameraPoseSnapshot(camera: camera)
        let trace = CameraDebugDragTrace(
            event: .orbitDrag,
            button: 0,
            dx: 20,
            dy: 0,
            before: before,
            after: after,
            probe: nil
        )

        XCTAssertSIMD3Equal(trace.targetDelta, .zero, accuracy: 1e-5)
        XCTAssertGreaterThan(simd_distance(before.eye, after.eye), 0.01)
        XCTAssertEqual(before.distance, after.distance, accuracy: 1e-5)
    }

    func testPanTraceMovesTarget() {
        let camera = OrbitCameraState()
        camera.yaw = 0
        camera.pitch = 0
        camera.distance = 6

        let before = CameraPoseSnapshot(camera: camera)
        camera.pan(worldOffset: SIMD3<Float>(1, 0, 0))
        let after = CameraPoseSnapshot(camera: camera)
        let trace = CameraDebugDragTrace(
            event: .panDrag,
            button: 2,
            dx: 10,
            dy: 0,
            before: before,
            after: after,
            probe: nil
        )

        XCTAssertGreaterThan(simd_length(trace.targetDelta), 0.99)
        XCTAssertEqual(trace.targetDelta.x, 1, accuracy: 1e-5)
    }
}

private extension XCTestCase {
    func XCTAssertSIMD3Equal(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>, accuracy: Float, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.z, rhs.z, accuracy: accuracy, file: file, line: line)
    }
}
