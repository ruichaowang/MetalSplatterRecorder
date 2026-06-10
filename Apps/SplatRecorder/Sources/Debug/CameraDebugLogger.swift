import Foundation

final class CameraDebugLogger: @unchecked Sendable {
    let fileURL: URL

    private let encoder: JSONEncoder
    private let queue = DispatchQueue(label: "splatrecorder.camera-debug-logger")
    private var lastDragLogDate: Date?
    private let dragInterval: TimeInterval = 0.05

    private init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
    }

    static func create(
        directory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        date: Date = Date()
    ) throws -> CameraDebugLogger {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "splatrecorder-camera-debug-\(processID)-\(formatter.string(from: date)).jsonl"
        let url = directory.appendingPathComponent(filename)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return CameraDebugLogger(fileURL: url)
    }

    func log(
        event: CameraDebugEvent,
        input: CameraDebugInput,
        before: CameraPoseSnapshot?,
        after: CameraPoseSnapshot?,
        probe: CameraDebugProbe?,
        force: Bool = false,
        now: Date = Date()
    ) throws {
        if !force, event.isDragEvent {
            if let lastDragLogDate, now.timeIntervalSince(lastDragLogDate) < dragInterval {
                return
            }
            lastDragLogDate = now
        }

        let targetDelta: SIMD3Codable?
        if let before, let after {
            targetDelta = SIMD3Codable(after.target - before.target)
        } else {
            targetDelta = nil
        }

        let entry = CameraDebugLogEntry(
            timestamp: now,
            event: event,
            input: input,
            before: before,
            after: after,
            targetDelta: targetDelta,
            probe: probe
        )
        let data = try encoder.encode(entry)
        try queue.sync {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
            try handle.close()
        }
    }
}

private extension CameraDebugEvent {
    var isDragEvent: Bool {
        switch self {
        case .orbitDrag, .panDrag, .zoomDrag:
            true
        case .debugEnabled, .fileLoaded, .mouseDown, .mouseUp, .keySnapshot:
            false
        }
    }
}

private struct CameraDebugLogEntry: Codable {
    let timestamp: Date
    let event: CameraDebugEvent
    let input: CameraDebugInput
    let before: CameraPoseSnapshot?
    let after: CameraPoseSnapshot?
    let targetDelta: SIMD3Codable?
    let probe: CameraDebugProbe?
}

private struct SIMD3Codable: Codable {
    let x: Float
    let y: Float
    let z: Float

    init(_ value: SIMD3<Float>) {
        x = value.x
        y = value.y
        z = value.z
    }
}
