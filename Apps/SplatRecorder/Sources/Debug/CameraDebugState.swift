import Foundation
import simd

@MainActor
@Observable
final class CameraDebugState {
    var enabled = false
    var logFileURL: URL?
    var lastEvent: CameraDebugEvent?
    var lastInput: CameraDebugInput = .empty
    var lastBefore: CameraPoseSnapshot?
    var lastAfter: CameraPoseSnapshot?
    var lastProbe: CameraDebugProbe?
    var lastTargetDelta: SIMD3<Float> = .zero
    var viewportSize: SIMD2<Int> = .zero
    var lastError: String?
    var lastBundleURL: URL?

    private var logger: CameraDebugLogger?

    func setEnabled(
        _ isEnabled: Bool,
        camera: OrbitCameraState,
        splatCenter: SIMD3<Float>,
        sampledPositions: [SIMD3<Float>]
    ) {
        guard isEnabled != enabled else { return }
        enabled = isEnabled

        if isEnabled {
            do {
                let logger = try CameraDebugLogger.create()
                self.logger = logger
                logFileURL = logger.fileURL
                lastError = nil
                let current = poseAndProbe(camera: camera, splatCenter: splatCenter, sampledPositions: sampledPositions)
                record(
                    event: .debugEnabled,
                    input: .empty,
                    before: nil,
                    after: current.pose,
                    probe: current.probe,
                    force: true
                )
            } catch {
                lastError = error.localizedDescription
                enabled = false
                logger = nil
                logFileURL = nil
            }
        } else {
            logger = nil
        }
    }

    func recordFileLoaded(
        camera: OrbitCameraState,
        splatCenter: SIMD3<Float>,
        sampledPositions: [SIMD3<Float>]
    ) {
        guard enabled else { return }
        let current = poseAndProbe(camera: camera, splatCenter: splatCenter, sampledPositions: sampledPositions)
        record(event: .fileLoaded, input: .empty, before: nil, after: current.pose, probe: current.probe, force: true)
    }

    func recordMouseDown(
        button: Int,
        camera: OrbitCameraState,
        splatCenter: SIMD3<Float>,
        sampledPositions: [SIMD3<Float>]
    ) {
        guard enabled else { return }
        let current = poseAndProbe(camera: camera, splatCenter: splatCenter, sampledPositions: sampledPositions)
        record(
            event: .mouseDown,
            input: CameraDebugInput(button: button, key: nil, dx: nil, dy: nil),
            before: current.pose,
            after: current.pose,
            probe: current.probe,
            force: true
        )
    }

    func recordDrag(
        event: CameraDebugEvent,
        button: Int,
        dx: Float,
        dy: Float,
        before: CameraPoseSnapshot,
        after: CameraPoseSnapshot,
        camera: OrbitCameraState,
        splatCenter: SIMD3<Float>,
        sampledPositions: [SIMD3<Float>]
    ) {
        guard enabled else { return }
        let input = CameraDebugInput(button: button, key: nil, dx: dx, dy: dy)
        let probe = updateProbe(camera: camera, splatCenter: splatCenter, sampledPositions: sampledPositions)
        record(event: event, input: input, before: before, after: after, probe: probe, force: false)
    }

    func recordMouseUp(
        button: Int,
        camera: OrbitCameraState,
        splatCenter: SIMD3<Float>,
        sampledPositions: [SIMD3<Float>]
    ) {
        guard enabled else { return }
        let current = poseAndProbe(camera: camera, splatCenter: splatCenter, sampledPositions: sampledPositions)
        record(
            event: .mouseUp,
            input: CameraDebugInput(button: button, key: nil, dx: nil, dy: nil),
            before: lastBefore,
            after: current.pose,
            probe: current.probe,
            force: true
        )
    }

    func recordKeySnapshot(
        key: String,
        camera: OrbitCameraState,
        splatCenter: SIMD3<Float>,
        sampledPositions: [SIMD3<Float>]
    ) {
        let current = poseAndProbe(camera: camera, splatCenter: splatCenter, sampledPositions: sampledPositions)
        let input = CameraDebugInput(button: nil, key: key, dx: nil, dy: nil)

        if enabled {
            record(event: .keySnapshot, input: input, before: nil, after: current.pose, probe: current.probe, force: true)
        }

        do {
            let snapshot = CameraDebugConsoleSnapshot(
                pose: current.pose,
                probe: current.probe,
                logPath: logFileURL?.path
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            if let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        } catch {
            print("Camera debug snapshot encode failed: \(error)")
        }
    }

    @discardableResult
    func exportBundle(
        camera: OrbitCameraState,
        splatCenter: SIMD3<Float>,
        sampledPositions: [SIMD3<Float>]
    ) -> URL? {
        let current = poseAndProbe(camera: camera, splatCenter: splatCenter, sampledPositions: sampledPositions)
        let snapshot = CameraDebugBundleSnapshot(
            pose: current.pose,
            probe: current.probe,
            lastEvent: lastEvent,
            lastInput: lastInput,
            targetDelta: lastTargetDelta,
            logPath: logFileURL?.path
        )

        do {
            let bundleURL = try CameraDebugBundleExporter.export(snapshot: snapshot, logFileURL: logFileURL)
            lastBundleURL = bundleURL
            lastError = nil
            print("Camera debug bundle: \(bundleURL.path)")
            return bundleURL
        } catch {
            lastError = error.localizedDescription
            print("Camera debug bundle export failed: \(error)")
            return nil
        }
    }

    @discardableResult
    func updateProbe(
        camera: OrbitCameraState,
        splatCenter: SIMD3<Float>,
        sampledPositions: [SIMD3<Float>]
    ) -> CameraDebugProbe {
        let size = viewportSize.x > 0 && viewportSize.y > 0 ? viewportSize : SIMD2<Int>(x: 1, y: 1)
        let probe = CameraDebugProbe.evaluate(
            camera: camera,
            splatCenter: splatCenter,
            sampledPositions: sampledPositions,
            viewportSize: size
        )
        lastProbe = probe
        return probe
    }

    private func poseAndProbe(
        camera: OrbitCameraState,
        splatCenter: SIMD3<Float>,
        sampledPositions: [SIMD3<Float>]
    ) -> (pose: CameraPoseSnapshot, probe: CameraDebugProbe) {
        (
            CameraPoseSnapshot(camera: camera),
            updateProbe(camera: camera, splatCenter: splatCenter, sampledPositions: sampledPositions)
        )
    }

    private func record(
        event: CameraDebugEvent,
        input: CameraDebugInput,
        before: CameraPoseSnapshot?,
        after: CameraPoseSnapshot?,
        probe: CameraDebugProbe?,
        force: Bool
    ) {
        lastEvent = event
        lastInput = input
        lastBefore = before
        lastAfter = after
        if let before, let after {
            lastTargetDelta = after.target - before.target
        } else {
            lastTargetDelta = .zero
        }
        lastProbe = probe

        do {
            try logger?.log(event: event, input: input, before: before, after: after, probe: probe, force: force)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

private struct CameraDebugConsoleSnapshot: Codable {
    let pose: CameraPoseSnapshot
    let probe: CameraDebugProbe?
    let logPath: String?
}
