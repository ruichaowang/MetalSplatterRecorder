import XCTest
import simd
@testable import SplatRecorder

final class OrbitCameraStateTests: XCTestCase {
    func testDefaultCameraAxisDirections() {
        let camera = OrbitCameraState()
        camera.yaw = 0
        camera.pitch = 0
        camera.target = .zero
        camera.distance = 5

        let center = project(SIMD3<Float>(0, 0, 0), camera: camera)
        let positiveX = project(SIMD3<Float>(1, 0, 0), camera: camera)
        let positiveY = project(SIMD3<Float>(0, 1, 0), camera: camera)

        XCTAssertGreaterThan(positiveX.x, center.x, "Without calibration, raw PLY +X maps to screen-right from the +Z view.")
        XCTAssertGreaterThan(positiveY.y, center.y, "Without calibration, raw PLY +Y maps to screen-up from the +Z view.")
    }

    func testNonOriginTargetProjectsToScreenCenterAfterPlyCalibration() {
        let camera = OrbitCameraState()
        camera.target = SIMD3<Float>(39.415474, 1.939796, -11.736671)
        camera.distance = 89

        let projectedTarget = project(camera.target, camera: camera)

        XCTAssertEqual(projectedTarget.x, 0, accuracy: 0.0001)
        XCTAssertEqual(projectedTarget.y, 0, accuracy: 0.0001)
    }

    func testSuperSplatDefaultViewUsesInitialAnglesAndDistanceFormula() {
        let camera = OrbitCameraState()
        let center = SIMD3<Float>(39.415474, 1.939796, -11.736671)
        let diagonal: Float = 109.402374

        camera.applySuperSplatDefaultView(center: center, diagonal: diagonal)

        XCTAssertEqual(camera.yaw, -45 * .pi / 180, accuracy: 0.0001)
        XCTAssertEqual(camera.pitch, 10 * .pi / 180, accuracy: 0.0001)
        XCTAssertEqual(camera.distance, (diagonal * 0.5) / sin(camera.fovRadians * 0.5), accuracy: 0.0001)
        let projectedTarget = project(center, camera: camera)
        XCTAssertEqual(projectedTarget.x, 0, accuracy: 0.0001)
        XCTAssertEqual(projectedTarget.y, 0, accuracy: 0.0001)
    }

    func testFocusPreservesCurrentOrientationAndUsesSuperSplatDistanceFormula() {
        let camera = OrbitCameraState()
        camera.yaw = 0.35
        camera.pitch = -0.2
        let center = SIMD3<Float>(5, -2, 9)
        let diagonal: Float = 12

        camera.focusOnBoundingBox(center: center, diagonal: diagonal)

        XCTAssertEqual(camera.yaw, 0.35, accuracy: 0.0001)
        XCTAssertEqual(camera.pitch, -0.2, accuracy: 0.0001)
        XCTAssertEqual(camera.distance, (diagonal * 0.5) / sin(camera.fovRadians * 0.5), accuracy: 0.0001)
    }

    // MARK: - moveView Tests

    func testMoveViewForwardMovesTargetInCameraForwardDirection() {
        let camera = OrbitCameraState()
        camera.yaw = 0
        camera.pitch = 0
        camera.target = .zero
        camera.distance = 5

        let direction = SIMD3<Float>(0, 0, -1) // W key: forward
        camera.moveView(direction: direction, deltaTime: 1.0 / 60.0, speedMultiplier: 1.0)

        // With yaw=0, pitch=0, visual forward is the camera-local -Z direction.
        // W should move the focal target forward, not backward.
        XCTAssertLessThan(camera.target.z, 0, "Forward (W) should move target in the visual forward direction (-Z when yaw=0).")
        XCTAssertEqual(camera.target.x, 0, accuracy: 1e-4)
        XCTAssertEqual(camera.target.y, 0, accuracy: 1e-4)
    }

    func testMoveViewBackwardMovesOppositeCameraForwardDirection() {
        let camera = OrbitCameraState()
        camera.yaw = 0
        camera.pitch = 0
        camera.target = .zero
        camera.distance = 5

        let direction = SIMD3<Float>(0, 0, 1) // S key: backward
        camera.moveView(direction: direction, deltaTime: 1.0 / 60.0, speedMultiplier: 1.0)

        XCTAssertGreaterThan(camera.target.z, 0, "Backward (S) should move target opposite the visual forward direction (+Z when yaw=0).")
        XCTAssertEqual(camera.target.x, 0, accuracy: 1e-4)
        XCTAssertEqual(camera.target.y, 0, accuracy: 1e-4)
    }

    func testMoveViewRightMovesTargetInCameraRightDirection() {
        let camera = OrbitCameraState()
        camera.yaw = 0
        camera.pitch = 0
        camera.target = .zero
        camera.distance = 5

        let direction = SIMD3<Float>(1, 0, 0) // D key: right
        camera.moveView(direction: direction, deltaTime: 1.0 / 60.0, speedMultiplier: 1.0)

        // With yaw=0, camera right is +X.
        XCTAssertGreaterThan(camera.target.x, 0, "Right (D) should move target in camera's right direction (+X when yaw=0).")
        XCTAssertEqual(camera.target.z, 0, accuracy: 1e-4)
        XCTAssertEqual(camera.target.y, 0, accuracy: 1e-4)
    }

    func testPanByScreenDragUsesCameraRightAndUpScaling() {
        let camera = OrbitCameraState()
        camera.yaw = 0
        camera.pitch = 0
        camera.target = .zero
        camera.distance = 10

        camera.panByScreenDrag(dx: 100, dy: 50)

        XCTAssertEqual(camera.target.x, -1, accuracy: 1e-5)
        XCTAssertEqual(camera.target.y, 0.5, accuracy: 1e-5)
        XCTAssertEqual(camera.target.z, 0, accuracy: 1e-5)
    }

    func testMoveViewUpMovesTargetInWorldUpDirection() {
        let camera = OrbitCameraState()
        camera.yaw = 0
        camera.pitch = 0
        camera.target = .zero
        camera.distance = 5

        let direction = SIMD3<Float>(0, 1, 0) // E key: up
        camera.moveView(direction: direction, deltaTime: 1.0 / 60.0, speedMultiplier: 1.0)

        XCTAssertGreaterThan(camera.target.y, 0, "Up (E) should move target in world-up direction (+Y).")
        XCTAssertEqual(camera.target.x, 0, accuracy: 1e-4)
        XCTAssertEqual(camera.target.z, 0, accuracy: 1e-4)
    }

    func testOrbitPositiveDxMatchesSuperSplatHorizontalDirection() {
        let camera = OrbitCameraState()
        camera.yaw = 0
        camera.pitch = 0

        camera.orbit(dx: 10, dy: 0)

        XCTAssertLessThan(camera.yaw, 0, "Dragging right should decrease yaw, matching SuperSplat orbit azimuth.")
        XCTAssertEqual(camera.pitch, 0, accuracy: 1e-6)
    }

    func testOrbitPositiveDyUsesAppKitUpwardMouseDirection() {
        let camera = OrbitCameraState()
        camera.yaw = 0
        camera.pitch = 0

        camera.orbit(dx: 0, dy: 10)

        XCTAssertLessThan(camera.pitch, 0, "In AppKit, positive dy means dragging upward; upward orbit should decrease pitch.")
        XCTAssertEqual(camera.yaw, 0, accuracy: 1e-6)
    }

    func testMoveViewZeroDirectionDoesNotChangeTarget() {
        let camera = OrbitCameraState()
        camera.yaw = 0.5
        camera.pitch = 0.3
        camera.target = SIMD3<Float>(1, 2, 3)
        camera.distance = 10

        let originalTarget = camera.target
        camera.moveView(direction: .zero, deltaTime: 1.0 / 60.0, speedMultiplier: 1.0)

        XCTAssertEqual(camera.target.x, originalTarget.x, accuracy: 1e-6)
        XCTAssertEqual(camera.target.y, originalTarget.y, accuracy: 1e-6)
        XCTAssertEqual(camera.target.z, originalTarget.z, accuracy: 1e-6)
    }

    func testMoveViewDeltaTimeZeroDoesNotChangeTarget() {
        let camera = OrbitCameraState()
        camera.yaw = 0
        camera.pitch = 0
        camera.target = SIMD3<Float>(1, 2, 3)
        camera.distance = 5

        let originalTarget = camera.target
        camera.moveView(direction: SIMD3<Float>(1, 0, -1), deltaTime: 0, speedMultiplier: 1.0)

        XCTAssertEqual(camera.target.x, originalTarget.x, accuracy: 1e-6)
        XCTAssertEqual(camera.target.y, originalTarget.y, accuracy: 1e-6)
        XCTAssertEqual(camera.target.z, originalTarget.z, accuracy: 1e-6)
    }

    func testMoveViewDeltaTimeClampedAt01() {
        let cameraA = OrbitCameraState()
        cameraA.yaw = 0
        cameraA.pitch = 0
        cameraA.target = .zero
        cameraA.distance = 5

        let cameraB = OrbitCameraState()
        cameraB.yaw = 0
        cameraB.pitch = 0
        cameraB.target = .zero
        cameraB.distance = 5

        let direction = SIMD3<Float>(0, 0, -1)
        cameraA.moveView(direction: direction, deltaTime: 0.1, speedMultiplier: 1.0)
        cameraB.moveView(direction: direction, deltaTime: 100.0, speedMultiplier: 1.0)

        XCTAssertEqual(cameraA.target.x, cameraB.target.x, accuracy: 1e-6,
                       "deltaTime=100 should be clamped to 0.1, producing same result as deltaTime=0.1.")
        XCTAssertEqual(cameraA.target.y, cameraB.target.y, accuracy: 1e-6)
        XCTAssertEqual(cameraA.target.z, cameraB.target.z, accuracy: 1e-6)
    }

    func testMoveViewSpeedScalesWithDistance() {
        let nearCamera = OrbitCameraState()
        nearCamera.yaw = 0
        nearCamera.pitch = 0
        nearCamera.target = .zero
        nearCamera.distance = 1

        let farCamera = OrbitCameraState()
        farCamera.yaw = 0
        farCamera.pitch = 0
        farCamera.target = .zero
        farCamera.distance = 10

        let direction = SIMD3<Float>(0, 0, -1)
        let dt: Float = 1.0 / 60.0
        nearCamera.moveView(direction: direction, deltaTime: dt, speedMultiplier: 1.0)
        farCamera.moveView(direction: direction, deltaTime: dt, speedMultiplier: 1.0)

        let nearDisplacement = simd_length(nearCamera.target)
        let farDisplacement = simd_length(farCamera.target)

        XCTAssertGreaterThan(farDisplacement, nearDisplacement,
                             "Camera at distance=10 should move faster than at distance=1 for the same deltaTime.")
    }

    func testMoveViewDiagonalIsNotFasterThanSingleAxis() {
        // Single-axis: W only
        let singleCamera = OrbitCameraState()
        singleCamera.yaw = 0
        singleCamera.pitch = 0
        singleCamera.target = .zero
        singleCamera.distance = 5

        // Diagonal: W+D
        let diagonalCamera = OrbitCameraState()
        diagonalCamera.yaw = 0
        diagonalCamera.pitch = 0
        diagonalCamera.target = .zero
        diagonalCamera.distance = 5

        let dt: Float = 1.0 / 60.0
        singleCamera.moveView(direction: SIMD3<Float>(0, 0, -1), deltaTime: dt, speedMultiplier: 1.0)
        diagonalCamera.moveView(direction: simd_normalize(SIMD3<Float>(1, 0, -1)), deltaTime: dt, speedMultiplier: 1.0)

        let singleDisp = simd_length(singleCamera.target)
        let diagonalDisp = simd_length(diagonalCamera.target)

        XCTAssertEqual(singleDisp, diagonalDisp, accuracy: 1e-4,
                       "Diagonal movement (normalized) should produce the same displacement magnitude as single-axis movement.")
    }

    private func project(_ point: SIMD3<Float>, camera: OrbitCameraState) -> SIMD3<Float> {
        let clip = camera.projectionMatrix(aspect: 1) * camera.viewMatrix * SIMD4<Float>(point.x, point.y, point.z, 1)
        return SIMD3<Float>(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w)
    }
}
