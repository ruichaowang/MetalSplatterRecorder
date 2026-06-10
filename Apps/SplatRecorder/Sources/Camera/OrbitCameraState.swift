import Foundation
import simd
import CoreGraphics

/// Spherical-coordinate orbit camera, aligned with SuperSplat's Camera class.
/// `@Observable` so SwiftUI views react to camera changes (ViewCube position updates).
@Observable
final class OrbitCameraState: @unchecked Sendable {
    // MARK: - Stored Properties

    /// Horizontal rotation angle (radians). 0 = facing +Z.
    var yaw: Float = -45 * .pi / 180

    /// Vertical rotation angle (radians). Clamped to prevent gimbal flip.
    var pitch: Float = 10 * .pi / 180

    /// Distance from focal point.
    var distance: Float = 5.0

    /// World-space point the camera orbits around.
    var target: SIMD3<Float> = .zero

    /// Vertical field of view in radians. Default 75 degrees.
    var fovRadians: Float = 75 * .pi / 180

    // MARK: - Constants

    /// Orbit sensitivity (radians per pixel of mouse drag).
    static let orbitSensitivity: Float = 0.3 * .pi / 180
    /// Zoom sensitivity (dimensionless per pixel of middle drag).
    static let zoomSensitivity: Float = 0.005
    /// Wheel zoom sensitivity (per scroll tick).
    static let wheelSensitivity: Float = 0.001
    static let superSplatInitialYaw: Float = -45 * .pi / 180
    static let superSplatInitialPitch: Float = 10 * .pi / 180

    private let pitchLimit: Float = 89 * .pi / 180
    private let distanceMin: Float = 0.05
    private let distanceMax: Float = 10_000.0

    // MARK: - Computed

    /// The view matrix for this camera pose (world-to-camera).
    var viewMatrix: simd_float4x4 {
        let cosPitch = cos(pitch)
        let x = target.x + distance * cosPitch * sin(yaw)
        let y = target.y + distance * sin(pitch)
        let z = target.z + distance * cosPitch * cos(yaw)

        let eye = SIMD3<Float>(x, y, z)
        let up = SIMD3<Float>(0, 1, 0)
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, up))
        let correctedUp = simd_cross(right, forward)

        // Right-handed lookAt: z-axis is NEGATIVE forward (camera looks along -Z).
        let nf = -forward
        return simd_float4x4(
            SIMD4<Float>(right.x, correctedUp.x, nf.x, 0),
            SIMD4<Float>(right.y, correctedUp.y, nf.y, 0),
            SIMD4<Float>(right.z, correctedUp.z, nf.z, 0),
            SIMD4<Float>(-simd_dot(right, eye), -simd_dot(correctedUp, eye), -simd_dot(nf, eye), 1)
        )
    }

    /// The inverse view matrix (camera-to-world). Used by ViewCube to extract axis vectors.
    var cameraWorldMatrix: simd_float4x4 {
        viewMatrix.inverse
    }

    private var rightDirection: SIMD3<Float> {
        let column = cameraWorldMatrix.columns.0
        return SIMD3<Float>(column.x, column.y, column.z)
    }

    private var upDirection: SIMD3<Float> {
        let column = cameraWorldMatrix.columns.1
        return SIMD3<Float>(column.x, column.y, column.z)
    }

    private var forwardDirection: SIMD3<Float> {
        let column = cameraWorldMatrix.columns.2
        return -SIMD3<Float>(column.x, column.y, column.z)
    }

    /// Perspective projection matrix for the given aspect ratio.
    func projectionMatrix(aspect: Float) -> simd_float4x4 {
        let farZ = max(distance * 4, 1_000)
        return matrix_perspective_right_hand(fovyRadians: fovRadians, aspect: aspect, nearZ: 0.1, farZ: farZ)
    }

    // MARK: - Interaction Methods

    /// Orbit: rotate camera around focal point. Values in screen pixels.
    func orbit(dx: Float, dy: Float) {
        yaw = (yaw - dx * Self.orbitSensitivity).truncatingRemainder(dividingBy: 2 * .pi)
        pitch = max(-pitchLimit, min(pitchLimit, pitch - dy * Self.orbitSensitivity))
    }

    /// Zoom: change distance by a relative amount. Positive = zoom out.
    func zoom(amount: Float) {
        distance = max(distanceMin, min(distanceMax, distance * (1 + amount * Self.zoomSensitivity)))
    }

    /// Wheel zoom: absolute delta from scroll event.
    func zoom(wheelDelta: Float) {
        distance = max(distanceMin, min(distanceMax, distance * (1 + wheelDelta * Self.wheelSensitivity)))
    }

    /// Pan: translate the focal point in world-space.
    func pan(worldOffset: SIMD3<Float>) {
        target += worldOffset
    }

    /// Pan from a screen-space drag, matching the existing "grab the image" behavior.
    func panByScreenDrag(dx: Float, dy: Float) {
        let scale = 0.001 * distance
        pan(worldOffset: rightDirection * (-dx * scale) + upDirection * (dy * scale))
    }

    /// Move the camera's target point based on a camera-local direction vector.
    ///
    /// Converts the camera-local direction into world-space movement:
    /// - X axis (right/left) uses the camera's right direction.
    /// - Y axis (up/down) uses world up `(0, 1, 0)` directly.
    /// - Z axis (forward/backward) projects the camera's forward direction onto the
    ///   horizontal plane (zeroes out Y, then normalizes) so movement stays level.
    ///
    /// - Parameters:
    ///   - direction: Camera-local direction vector (e.g. from keyboard input).
    ///   - deltaTime: Elapsed time since last frame (seconds), clamped to 0.1s max.
    ///   - speedMultiplier: Additional speed scaling factor.
    func moveView(direction: SIMD3<Float>, deltaTime: Float, speedMultiplier: Float) {
        let clampedDelta = min(deltaTime, 0.1)
        let baseSpeed = max(distance * 0.25, 0.25)

        // Project forward onto the horizontal plane for ground-level movement.
        var groundForward = SIMD3<Float>(forwardDirection.x, 0, forwardDirection.z)
        let groundForwardLen = simd_length(groundForward)
        if groundForwardLen > 1e-6 {
            groundForward /= groundForwardLen
        } else {
            groundForward = SIMD3<Float>(0, 0, 1)
        }

        let worldUp = SIMD3<Float>(0, 1, 0)

        let worldOffset = (rightDirection * direction.x
                         + worldUp * direction.y
                         - groundForward * direction.z)
                        * baseSpeed * speedMultiplier * clampedDelta

        pan(worldOffset: worldOffset)
    }

    // MARK: - Convenience

    /// Align to an orthographic preset view.
    func alignToAxis(_ preset: ViewPreset) {
        yaw = preset.yaw
        pitch = preset.pitch
    }

    /// Reset to default viewpoint.
    func reset() {
        yaw = Self.superSplatInitialYaw
        pitch = Self.superSplatInitialPitch
        distance = 5.0
        target = .zero
    }

    /// Focus on a bounding box: set target to center and choose a distance that fits the diagonal.
    func focusOnBoundingBox(center: SIMD3<Float>, diagonal: Float) {
        target = center
        distance = fitDistance(forDiagonal: diagonal)
    }

    /// Match SuperSplat's first view: azimuth -45°, elevation -10° in PlayCanvas
    /// coordinates, mapped to this camera as yaw -45° and pitch +10°.
    func applySuperSplatDefaultView(center: SIMD3<Float>, diagonal: Float) {
        yaw = Self.superSplatInitialYaw
        pitch = Self.superSplatInitialPitch
        focusOnBoundingBox(center: center, diagonal: diagonal)
    }

    /// Move the orbit pivot to the first visible sampled depth on the current center ray.
    /// Keeps yaw/pitch stable and updates distance so the view does not jump.
    @discardableResult
    func applyCenterRayOrbitPivot(sampledPositions: [SIMD3<Float>], maxRayDistance: Float? = nil) -> Bool {
        guard let pivot = CameraOrbitPivotPicker.centerRayPivot(
            camera: self,
            sampledPositions: sampledPositions,
            maxRayDistance: maxRayDistance
        ) else {
            return false
        }

        target = pivot.target
        distance = max(distanceMin, min(distanceMax, pivot.depth))
        return true
    }

    private func fitDistance(forDiagonal diagonal: Float) -> Float {
        let radius = max(diagonal * 0.5, distanceMin)
        let fitDistance = radius / sin(fovRadians * 0.5)
        return max(distanceMin, min(distanceMax, fitDistance))
    }
}
