import XCTest
import simd
@testable import SplatRecorder

final class DebugAxisSceneTests: XCTestCase {
    func testFrontCameraProjectsRawAxesToExpectedNDC() throws {
        let camera = DebugAxisScene.makeCamera(mode: .front)
        let origin = try axisPoint(named: "origin")
        let plusX = try axisPoint(named: "+X")
        let minusX = try axisPoint(named: "-X")
        let plusY = try axisPoint(named: "+Y")
        let minusY = try axisPoint(named: "-Y")

        let originNDC = DebugAxisScene.projectToNDC(origin.position, camera: camera, aspect: 1)
        let plusXNDC = DebugAxisScene.projectToNDC(plusX.position, camera: camera, aspect: 1)
        let minusXNDC = DebugAxisScene.projectToNDC(minusX.position, camera: camera, aspect: 1)
        let plusYNDC = DebugAxisScene.projectToNDC(plusY.position, camera: camera, aspect: 1)
        let minusYNDC = DebugAxisScene.projectToNDC(minusY.position, camera: camera, aspect: 1)

        XCTAssertGreaterThan(plusXNDC.x, originNDC.x)
        XCTAssertLessThan(minusXNDC.x, originNDC.x)
        XCTAssertGreaterThan(plusYNDC.y, originNDC.y)
        XCTAssertLessThan(minusYNDC.y, originNDC.y)
    }

    func testAxisSceneContainsDistinctDebugColors() {
        let names = DebugAxisScene.axisPoints.map(\.name)
        XCTAssertEqual(names, ["origin", "+X", "-X", "+Y", "-Y", "+Z", "-Z"])

        let uniqueColors = Set(DebugAxisScene.axisPoints.map { "\($0.color.x),\($0.color.y),\($0.color.z)" })
        XCTAssertEqual(uniqueColors.count, DebugAxisScene.axisPoints.count)
    }

    func testSuperSplatPLYSpaceRotatesRawAxesAroundZ() throws {
        let plusX = try axisPoint(named: "+X")
        let plusY = try axisPoint(named: "+Y")
        let plusZ = try axisPoint(named: "+Z")

        XCTAssertEqual(DebugAxisScene.transform(plusX.position, to: .superSplatPLY).x, -plusX.position.x, accuracy: 1e-6)
        XCTAssertEqual(DebugAxisScene.transform(plusX.position, to: .superSplatPLY).y, plusX.position.y, accuracy: 1e-6)
        XCTAssertEqual(DebugAxisScene.transform(plusY.position, to: .superSplatPLY).x, plusY.position.x, accuracy: 1e-6)
        XCTAssertEqual(DebugAxisScene.transform(plusY.position, to: .superSplatPLY).y, -plusY.position.y, accuracy: 1e-6)
        XCTAssertEqual(DebugAxisScene.transform(plusZ.position, to: .superSplatPLY).z, plusZ.position.z, accuracy: 1e-6)
    }

    func testSuperSplatPLYSpaceMapsArbitraryPointByRotateZAround180Degrees() {
        let point = SIMD3<Float>(2.5, -4.0, 7.25)
        let transformed = DebugAxisScene.transform(point, to: .superSplatPLY)

        XCTAssertEqual(transformed.x, -2.5, accuracy: 1e-6)
        XCTAssertEqual(transformed.y, 4.0, accuracy: 1e-6)
        XCTAssertEqual(transformed.z, 7.25, accuracy: 1e-6)
    }

    func testFrontCameraShowsSuperSplatPLYPositiveYBelowOrigin() throws {
        let camera = DebugAxisScene.makeCamera(mode: .front)
        let origin = DebugAxisScene.transform(try axisPoint(named: "origin").position, to: .superSplatPLY)
        let plusY = DebugAxisScene.transform(try axisPoint(named: "+Y").position, to: .superSplatPLY)

        let originNDC = DebugAxisScene.projectToNDC(origin, camera: camera, aspect: 1)
        let plusYNDC = DebugAxisScene.projectToNDC(plusY, camera: camera, aspect: 1)

        XCTAssertLessThan(plusYNDC.y, originNDC.y)
    }

    private func axisPoint(named name: String) throws -> DebugAxisScene.AxisPoint {
        let point = DebugAxisScene.axisPoints.first { $0.name == name }
        return try XCTUnwrap(point)
    }
}
