import Foundation

/// Camera alignment presets matching SuperSplat's camera.align events.
/// Maps to orthographic views along the six world-space axes.
enum ViewPreset: String, CaseIterable, Sendable {
    /// +Z axis: facing forward (front view)
    case front
    /// -Z axis: facing backward (back view)
    case back
    /// -X axis: facing left
    case left
    /// +X axis: facing right
    case right
    /// +Y axis: looking down from above
    case top
    /// -Y axis: looking up from below
    case bottom

    /// Target yaw angle in radians for this preset (0 = +Z direction).
    var yaw: Float {
        switch self {
        case .front:  return 0
        case .back:   return .pi
        case .left:   return -.pi / 2
        case .right:  return .pi / 2
        case .top:    return 0
        case .bottom: return 0
        }
    }

    /// Target pitch angle in radians for this preset.
    var pitch: Float {
        switch self {
        case .front:  return 0
        case .back:   return 0
        case .left:   return 0
        case .right:  return 0
        case .top:    return .pi / 2
        case .bottom: return -.pi / 2
        }
    }

    /// Human-readable label for UI display.
    var label: String {
        switch self {
        case .front:  return "Front"
        case .back:   return "Back"
        case .left:   return "Left"
        case .right:  return "Right"
        case .top:    return "Top"
        case .bottom: return "Bottom"
        }
    }
}
