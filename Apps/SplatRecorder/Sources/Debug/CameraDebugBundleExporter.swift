import Foundation
import simd

struct CameraDebugBundleSnapshot: Codable, Equatable, Sendable {
    let pose: CameraPoseSnapshot
    let probe: CameraDebugProbe?
    let lastEvent: CameraDebugEvent?
    let lastInput: CameraDebugInput
    let targetDelta: SIMD3<Float>
    let logPath: String?
}

enum CameraDebugBundleExporter {
    static func export(
        snapshot: CameraDebugBundleSnapshot,
        logFileURL: URL?,
        outputRoot: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        date: Date = Date()
    ) throws -> URL {
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let bundleURL = outputRoot.appendingPathComponent(
            "splatrecorder-debug-bundle-\(processID)-\(formatter.string(from: date))",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            try FileManager.default.removeItem(at: bundleURL)
        }
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let logOutput = bundleURL.appendingPathComponent("camera-debug.jsonl")
        if let logFileURL, FileManager.default.fileExists(atPath: logFileURL.path) {
            try FileManager.default.copyItem(at: logFileURL, to: logOutput)
        } else {
            FileManager.default.createFile(atPath: logOutput.path, contents: nil)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let snapshotData = try encoder.encode(snapshot)
        try snapshotData.write(to: bundleURL.appendingPathComponent("latest-snapshot.json"), options: .atomic)

        let readme = """
        SplatRecorder Camera Debug Bundle

        Files:
        - camera-debug.jsonl: structured interaction log. Check orbit_drag rows for targetDelta and before/after camera pose.
        - latest-snapshot.json: latest camera pose, probe metrics, event, input, and log path.

        Useful fields:
        - pose.target: current orbit center.
        - pose.eye: current camera position.
        - probe.targetToSplatCenterDistance: distance from orbit center to robust splat center.
        - probe.nearestPointToCenterRayDistance: nearest sampled splat distance to the screen-center ray.
        - targetDelta: target movement between before/after camera poses. orbit_drag should normally be near zero.
        """
        try readme.write(to: bundleURL.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        return bundleURL
    }
}
