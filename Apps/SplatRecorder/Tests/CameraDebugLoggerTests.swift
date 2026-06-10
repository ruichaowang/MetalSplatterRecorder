import XCTest
import Foundation
import simd
@testable import SplatRecorder

final class CameraDebugLoggerTests: XCTestCase {
    func testLoggerWritesJSONLWithPoseAndProbe() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("splatrecorder-logger-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let logger = try CameraDebugLogger.create(directory: directory, processID: 123, date: Date(timeIntervalSince1970: 1_700_000_000))
        let camera = OrbitCameraState()
        camera.target = SIMD3<Float>(1, 2, 3)
        camera.distance = 5
        let pose = CameraPoseSnapshot(camera: camera)
        let probe = CameraDebugProbe.evaluate(
            camera: camera,
            splatCenter: .zero,
            sampledPositions: [SIMD3<Float>(1, 2, 3)],
            viewportSize: SIMD2<Int>(x: 640, y: 480)
        )

        try logger.log(
            event: .debugEnabled,
            input: CameraDebugInput(button: nil, key: nil, dx: nil, dy: nil),
            before: nil,
            after: pose,
            probe: probe,
            force: true
        )

        let contents = try String(contentsOf: logger.fileURL, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 1)

        let data = try XCTUnwrap(lines.first?.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["event"] as? String, "debug_enabled")
        XCTAssertNotNil(object?["after"])
        XCTAssertNotNil(object?["probe"])
        XCTAssertEqual((object?["input"] as? [String: Any])?["button"] as? NSNull, NSNull())
        XCTAssertTrue(logger.fileURL.path.contains("splatrecorder-camera-debug-123-"))
    }

    func testLoggerThrottlesDragEventsButKeepsForcedEvents() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("splatrecorder-logger-throttle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let logger = try CameraDebugLogger.create(directory: directory, processID: 456, date: Date(timeIntervalSince1970: 1_700_000_000))
        let pose = CameraPoseSnapshot(camera: OrbitCameraState())

        try logger.log(event: .orbitDrag, input: .empty, before: pose, after: pose, probe: nil, force: false, now: Date(timeIntervalSince1970: 10))
        try logger.log(event: .orbitDrag, input: .empty, before: pose, after: pose, probe: nil, force: false, now: Date(timeIntervalSince1970: 10.01))
        try logger.log(event: .mouseUp, input: .empty, before: pose, after: pose, probe: nil, force: true, now: Date(timeIntervalSince1970: 10.02))

        let lines = try String(contentsOf: logger.fileURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"orbit_drag\""))
        XCTAssertTrue(lines[1].contains("\"mouse_up\""))
    }

    func testDebugBundleExporterCopiesLogAndWritesSnapshotAndReadme() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("splatrecorder-bundle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceLog = directory.appendingPathComponent("source.jsonl")
        try #"{"event":"orbit_drag"}"#.write(to: sourceLog, atomically: true, encoding: .utf8)

        let camera = OrbitCameraState()
        camera.target = SIMD3<Float>(1, 2, 3)
        let snapshot = CameraDebugBundleSnapshot(
            pose: CameraPoseSnapshot(camera: camera),
            probe: CameraDebugProbe.evaluate(
                camera: camera,
                splatCenter: .zero,
                sampledPositions: [SIMD3<Float>(1, 2, 3)],
                viewportSize: SIMD2<Int>(x: 640, y: 480)
            ),
            lastEvent: .orbitDrag,
            lastInput: CameraDebugInput(button: 0, key: nil, dx: 10, dy: 4),
            targetDelta: SIMD3<Float>(0, 0, 0),
            logPath: sourceLog.path
        )

        let bundleURL = try CameraDebugBundleExporter.export(
            snapshot: snapshot,
            logFileURL: sourceLog,
            outputRoot: directory,
            processID: 789,
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("camera-debug.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("latest-snapshot.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("README.txt").path))

        let copiedLog = try String(contentsOf: bundleURL.appendingPathComponent("camera-debug.jsonl"), encoding: .utf8)
        XCTAssertTrue(copiedLog.contains("orbit_drag"))

        let snapshotData = try Data(contentsOf: bundleURL.appendingPathComponent("latest-snapshot.json"))
        let snapshotObject = try JSONSerialization.jsonObject(with: snapshotData) as? [String: Any]
        XCTAssertEqual(snapshotObject?["lastEvent"] as? String, "orbit_drag")
        XCTAssertNotNil(snapshotObject?["pose"])
        XCTAssertNotNil(snapshotObject?["probe"])

        let readme = try String(contentsOf: bundleURL.appendingPathComponent("README.txt"), encoding: .utf8)
        XCTAssertTrue(readme.contains("camera-debug.jsonl"))
        XCTAssertTrue(readme.contains("latest-snapshot.json"))
    }
}
