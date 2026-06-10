import simd

/// Pure-logic helper that maps currently-held keyboard keys and modifier flags
/// to a camera-space movement direction vector and speed multiplier.
///
/// This struct has no AppKit dependencies — it operates on raw key codes (`UInt16`)
/// and boolean modifier flags so it can be used and tested without any UI framework.
struct KeyboardMovementInput {
    // MARK: - Key Codes

    /// macOS virtual key codes for the six movement keys.
    static let keyCodeA: UInt16 = 0
    static let keyCodeS: UInt16 = 1
    static let keyCodeD: UInt16 = 2
    static let keyCodeQ: UInt16 = 12
    static let keyCodeW: UInt16 = 13
    static let keyCodeE: UInt16 = 14

    /// The set of key codes recognised as movement keys.
    static let movementKeyCodes: Set<UInt16> = [
        keyCodeW, keyCodeA, keyCodeS, keyCodeD, keyCodeQ, keyCodeE
    ]

    // MARK: - State

    /// Movement keys currently held down.
    private(set) var pressedKeys: Set<UInt16> = []

    /// Whether the Shift modifier is active.
    var shiftHeld: Bool = false

    /// Whether the Option/Alt modifier is active.
    var optionHeld: Bool = false

    // MARK: - Input Updates

    /// Register a key-down event. Only recognised movement keys are tracked.
    mutating func keyDown(_ keyCode: UInt16) {
        if Self.movementKeyCodes.contains(keyCode) {
            pressedKeys.insert(keyCode)
        }
    }

    /// Register a key-up event.
    mutating func keyUp(_ keyCode: UInt16) {
        pressedKeys.remove(keyCode)
    }

    /// Remove all tracked key state (e.g. when the view loses focus).
    mutating func resetAllKeys() {
        pressedKeys.removeAll()
    }

    // MARK: - Output

    /// Compute the current movement direction and speed multiplier from the
    /// held keys and modifier state.
    ///
    /// Direction is in camera-local space:
    /// - W → −Z (forward), S → +Z (backward)
    /// - A → −X (left),    D → +X (right)
    /// - Q → −Y (down),    E → +Y (up)
    ///
    /// When multiple direction keys are held the resulting vector is normalised
    /// so that diagonal movement is no faster than axis-aligned movement.
    /// Returns zero direction when no movement keys are held.
    var movement: (direction: SIMD3<Float>, speedMultiplier: Float) {
        var dir = SIMD3<Float>(repeating: 0)

        if pressedKeys.contains(Self.keyCodeW) { dir.z -= 1 }
        if pressedKeys.contains(Self.keyCodeS) { dir.z += 1 }
        if pressedKeys.contains(Self.keyCodeA) { dir.x -= 1 }
        if pressedKeys.contains(Self.keyCodeD) { dir.x += 1 }
        if pressedKeys.contains(Self.keyCodeQ) { dir.y -= 1 }
        if pressedKeys.contains(Self.keyCodeE) { dir.y += 1 }

        let length = simd_length(dir)
        if length > 0 {
            dir /= length
        }

        return (direction: dir, speedMultiplier: speedMultiplier)
    }

    // MARK: - Private

    /// Speed multiplier derived from modifier keys.
    ///
    /// - Shift only → 10x
    /// - Option only → 0.1x
    /// - Neither or both → 1.0x
    private var speedMultiplier: Float {
        switch (shiftHeld, optionHeld) {
        case (true, false):  return 10.0
        case (false, true):  return 0.1
        default:             return 1.0
        }
    }
}
