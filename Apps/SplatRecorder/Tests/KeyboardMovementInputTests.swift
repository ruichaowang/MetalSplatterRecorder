import XCTest
import simd
@testable import SplatRecorder

final class KeyboardMovementInputTests: XCTestCase {

    // MARK: - Single Key Mapping

    func testWKeyMapsToForward() {
        var input = KeyboardMovementInput()
        input.keyDown(KeyboardMovementInput.keyCodeW)
        let m = input.movement
        XCTAssertEqual(m.direction.x, 0, accuracy: 1e-6)
        XCTAssertEqual(m.direction.y, 0, accuracy: 1e-6)
        XCTAssertEqual(m.direction.z, -1, accuracy: 1e-6)
    }

    func testSKeyMapsToBackward() {
        var input = KeyboardMovementInput()
        input.keyDown(KeyboardMovementInput.keyCodeS)
        let m = input.movement
        XCTAssertEqual(m.direction.x, 0, accuracy: 1e-6)
        XCTAssertEqual(m.direction.y, 0, accuracy: 1e-6)
        XCTAssertEqual(m.direction.z, 1, accuracy: 1e-6)
    }

    func testAKeyMapsToLeft() {
        var input = KeyboardMovementInput()
        input.keyDown(KeyboardMovementInput.keyCodeA)
        let m = input.movement
        XCTAssertEqual(m.direction.x, -1, accuracy: 1e-6)
        XCTAssertEqual(m.direction.y, 0, accuracy: 1e-6)
        XCTAssertEqual(m.direction.z, 0, accuracy: 1e-6)
    }

    func testDKeyMapsToRight() {
        var input = KeyboardMovementInput()
        input.keyDown(KeyboardMovementInput.keyCodeD)
        let m = input.movement
        XCTAssertEqual(m.direction.x, 1, accuracy: 1e-6)
        XCTAssertEqual(m.direction.y, 0, accuracy: 1e-6)
        XCTAssertEqual(m.direction.z, 0, accuracy: 1e-6)
    }

    func testQKeyMapsToDown() {
        var input = KeyboardMovementInput()
        input.keyDown(KeyboardMovementInput.keyCodeQ)
        let m = input.movement
        XCTAssertEqual(m.direction.x, 0, accuracy: 1e-6)
        XCTAssertEqual(m.direction.y, -1, accuracy: 1e-6)
        XCTAssertEqual(m.direction.z, 0, accuracy: 1e-6)
    }

    func testEKeyMapsToUp() {
        var input = KeyboardMovementInput()
        input.keyDown(KeyboardMovementInput.keyCodeE)
        let m = input.movement
        XCTAssertEqual(m.direction.x, 0, accuracy: 1e-6)
        XCTAssertEqual(m.direction.y, 1, accuracy: 1e-6)
        XCTAssertEqual(m.direction.z, 0, accuracy: 1e-6)
    }

    // MARK: - Opposing Keys Cancel

    func testOpposingKeysCancelForwardBackward() {
        var input = KeyboardMovementInput()
        input.keyDown(KeyboardMovementInput.keyCodeW)
        input.keyDown(KeyboardMovementInput.keyCodeS)
        let m = input.movement
        XCTAssertEqual(m.direction.x, 0)
        XCTAssertEqual(m.direction.y, 0)
        XCTAssertEqual(m.direction.z, 0)
    }

    func testOpposingKeysCancelLeftRight() {
        var input = KeyboardMovementInput()
        input.keyDown(KeyboardMovementInput.keyCodeA)
        input.keyDown(KeyboardMovementInput.keyCodeD)
        let m = input.movement
        XCTAssertEqual(m.direction.x, 0)
        XCTAssertEqual(m.direction.y, 0)
        XCTAssertEqual(m.direction.z, 0)
    }

    func testOpposingKeysCancelUpDown() {
        var input = KeyboardMovementInput()
        input.keyDown(KeyboardMovementInput.keyCodeQ)
        input.keyDown(KeyboardMovementInput.keyCodeE)
        let m = input.movement
        XCTAssertEqual(m.direction.x, 0)
        XCTAssertEqual(m.direction.y, 0)
        XCTAssertEqual(m.direction.z, 0)
    }

    // MARK: - Diagonal Normalization

    func testDiagonalDirectionIsNormalized() {
        var input = KeyboardMovementInput()
        input.keyDown(KeyboardMovementInput.keyCodeW)
        input.keyDown(KeyboardMovementInput.keyCodeD)
        let m = input.movement
        let length = simd_length(m.direction)
        XCTAssertEqual(length, 1.0, accuracy: 1e-6)
    }

    func testThreeKeyDiagonalIsNormalized() {
        var input = KeyboardMovementInput()
        input.keyDown(KeyboardMovementInput.keyCodeW)
        input.keyDown(KeyboardMovementInput.keyCodeD)
        input.keyDown(KeyboardMovementInput.keyCodeE)
        let m = input.movement
        let length = simd_length(m.direction)
        XCTAssertEqual(length, 1.0, accuracy: 1e-6)
    }

    // MARK: - Speed Multiplier

    func testShiftGivesSpeedMultiplier10() {
        var input = KeyboardMovementInput()
        input.shiftHeld = true
        input.keyDown(KeyboardMovementInput.keyCodeW)
        let m = input.movement
        XCTAssertEqual(m.speedMultiplier, 10.0)
    }

    func testOptionGivesSpeedMultiplier01() {
        var input = KeyboardMovementInput()
        input.optionHeld = true
        input.keyDown(KeyboardMovementInput.keyCodeW)
        let m = input.movement
        XCTAssertEqual(m.speedMultiplier, 0.1, accuracy: 1e-6)
    }

    func testNoModifiersGivesSpeedMultiplier1() {
        var input = KeyboardMovementInput()
        input.keyDown(KeyboardMovementInput.keyCodeW)
        let m = input.movement
        XCTAssertEqual(m.speedMultiplier, 1.0)
    }

    func testShiftPlusOptionGivesSpeedMultiplier1() {
        var input = KeyboardMovementInput()
        input.shiftHeld = true
        input.optionHeld = true
        input.keyDown(KeyboardMovementInput.keyCodeW)
        let m = input.movement
        XCTAssertEqual(m.speedMultiplier, 1.0)
    }

    // MARK: - No Keys Held

    func testNoKeysGivesZeroDirection() {
        let input = KeyboardMovementInput()
        let m = input.movement
        XCTAssertEqual(m.direction.x, 0)
        XCTAssertEqual(m.direction.y, 0)
        XCTAssertEqual(m.direction.z, 0)
        XCTAssertEqual(m.speedMultiplier, 1.0)
    }

    // MARK: - Reset

    func testResetAllKeysClearsDirection() {
        var input = KeyboardMovementInput()
        input.keyDown(KeyboardMovementInput.keyCodeW)
        input.keyDown(KeyboardMovementInput.keyCodeD)
        input.keyDown(KeyboardMovementInput.keyCodeE)
        input.resetAllKeys()
        let m = input.movement
        XCTAssertEqual(m.direction.x, 0)
        XCTAssertEqual(m.direction.y, 0)
        XCTAssertEqual(m.direction.z, 0)
    }

    func testResetAllKeysClearsPressedKeys() {
        var input = KeyboardMovementInput()
        input.keyDown(KeyboardMovementInput.keyCodeW)
        input.keyDown(KeyboardMovementInput.keyCodeD)
        input.resetAllKeys()
        XCTAssertTrue(input.pressedKeys.isEmpty)
    }

    // MARK: - Non-Movement Keys Ignored

    func testNonMovementKeyIsIgnored() {
        var input = KeyboardMovementInput()
        input.keyDown(99) // arbitrary non-movement key code
        let m = input.movement
        XCTAssertEqual(m.direction.x, 0)
        XCTAssertEqual(m.direction.y, 0)
        XCTAssertEqual(m.direction.z, 0)
    }

    // MARK: - Key Up

    func testKeyUpRemovesKey() {
        var input = KeyboardMovementInput()
        input.keyDown(KeyboardMovementInput.keyCodeW)
        input.keyDown(KeyboardMovementInput.keyCodeD)
        input.keyUp(KeyboardMovementInput.keyCodeW)
        let m = input.movement
        XCTAssertEqual(m.direction.x, 1, accuracy: 1e-6)
        XCTAssertEqual(m.direction.y, 0, accuracy: 1e-6)
        XCTAssertEqual(m.direction.z, 0, accuracy: 1e-6)
    }
}
