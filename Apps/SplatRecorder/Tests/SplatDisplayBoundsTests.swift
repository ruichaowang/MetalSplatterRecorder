import XCTest
import simd
@testable import SplatRecorder

final class SplatDisplayBoundsTests: XCTestCase {
    func testRobustBoundsIgnoreSeparatedFarShellForInitialView() {
        var positions: [SIMD3<Float>] = []
        for x in 0..<10 {
            for y in 0..<10 {
                positions.append(SIMD3<Float>(Float(x) * 0.1, Float(y) * 0.1, 0))
            }
        }
        positions.append(contentsOf: [
            SIMD3<Float>(240, 0, 0),
            SIMD3<Float>(-240, 0, 0),
            SIMD3<Float>(0, 240, 0),
        ])

        let rawBounds = SplatDisplayBounds.rawBounds(for: positions)
        let robustBounds = SplatDisplayBounds.robustBounds(for: positions)
        let visibleIndices = SplatDisplayBounds.robustVisibleIndices(for: positions)

        XCTAssertGreaterThan(rawBounds.diagonal, 300)
        XCTAssertLessThan(robustBounds.diagonal, 2)
        XCTAssertEqual(robustBounds.center.x, 0.45, accuracy: 0.001)
        XCTAssertEqual(robustBounds.center.y, 0.45, accuracy: 0.001)
        XCTAssertEqual(visibleIndices.count, 100)
        XCTAssertFalse(visibleIndices.contains(100))
        XCTAssertFalse(visibleIndices.contains(101))
        XCTAssertFalse(visibleIndices.contains(102))
    }

    func testRobustBoundsKeepRawBoundsWhenThereIsNoSeparatedShell() {
        let positions = [
            SIMD3<Float>(-1, -1, -1),
            SIMD3<Float>(1, -1, -1),
            SIMD3<Float>(-1, 1, -1),
            SIMD3<Float>(1, 1, -1),
            SIMD3<Float>(-1, -1, 1),
            SIMD3<Float>(1, -1, 1),
            SIMD3<Float>(-1, 1, 1),
            SIMD3<Float>(1, 1, 1),
        ]

        let rawBounds = SplatDisplayBounds.rawBounds(for: positions)
        let robustBounds = SplatDisplayBounds.robustBounds(for: positions)
        let visibleIndices = SplatDisplayBounds.robustVisibleIndices(for: positions)

        XCTAssertEqual(robustBounds.center.x, rawBounds.center.x, accuracy: 0.001)
        XCTAssertEqual(robustBounds.center.y, rawBounds.center.y, accuracy: 0.001)
        XCTAssertEqual(robustBounds.center.z, rawBounds.center.z, accuracy: 0.001)
        XCTAssertEqual(robustBounds.diagonal, rawBounds.diagonal, accuracy: 0.001)
        XCTAssertEqual(visibleIndices, Array(positions.indices))
    }
}
