import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Metal

struct SplatRecorderContentView: View {
    @State private var splatDocument: SplatDocumentState
    @State private var cameraState = OrbitCameraState()
    @State private var splatRenderer: SplatMetalRenderer
    @State private var videoRecorder = VideoRecorder()
    @State private var cameraDebugState = CameraDebugState()
    @State private var isPickingFile = false
    @State private var isRecording = false
    @State private var recordingElapsed: TimeInterval = 0
    @State private var recordingTimer: Timer?
    @State private var recordingView: RecordingMTKView?

    private let metalDevice: MTLDevice
    private let autoOpenURL: URL?

    init(autoOpenURL: URL? = nil) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("MetalSplatter requires Apple Silicon")
        }
        self.metalDevice = device
        self.autoOpenURL = autoOpenURL
        let camera = OrbitCameraState()
        let doc = SplatDocumentState(device: device, camera: camera)
        self._cameraState = State(initialValue: camera)
        self._splatDocument = State(initialValue: doc)
        self._splatRenderer = State(initialValue: SplatMetalRenderer(renderer: doc.renderer, camera: camera))
    }

    var body: some View {
        ZStack {
            // Layer 1: MTKView
            SplatMetalView(
                splatRenderer: splatRenderer,
                cameraState: cameraState,
                videoRecorder: videoRecorder,
                splatDocument: splatDocument,
                cameraDebugState: cameraDebugState,
                onStopRecording: { stopRecording() },
                onViewCreated: { view in recordingView = view }
            )
            .ignoresSafeArea()

            if cameraDebugState.enabled {
                CameraDebugOverlay(debugState: cameraDebugState)
                    .ignoresSafeArea()
            }

            // Layer 2: ViewCube + Status
            VStack {
                Spacer()
                HStack {
                    // Status info
                    if splatDocument.loadState == .loaded {
                        Text(splatStatusText)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .cornerRadius(6)
                    }
                    Spacer()
                    // ViewCube
                    ViewCube(
                        cameraMatrix: cameraState.cameraWorldMatrix,
                        isDimmed: isRecording,
                        onSelectPreset: { preset in
                            cameraState.alignToAxis(preset)
                            refreshDebugProbe()
                        }
                    )
                    .frame(width: 100, height: 100)
                }
                .padding(.leading, 16)
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }

            if cameraDebugState.enabled {
                VStack {
                    HStack {
                        CameraDebugHUD(debugState: cameraDebugState)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.top, 56)
                .padding(.leading, 16)
            }

            // Layer 3: Overlay toolbar / recording indicator
            VStack {
                if !isRecording {
                    HStack(spacing: 12) {
                        Button(action: { isPickingFile = true }) {
                            Label("Open", systemImage: "folder")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial)
                        .cornerRadius(6)

                        Divider().frame(height: 16)

                        Button(action: {
                            splatDocument.resetCameraToDefaultView()
                            refreshDebugProbe()
                        }) {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial)
                        .cornerRadius(6)

                        Divider().frame(height: 16)

                        Button(action: toggleDebug) {
                            Label("Debug", systemImage: "scope")
                                .font(.system(size: 12))
                                .foregroundColor(cameraDebugState.enabled ? .yellow : .primary)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial)
                        .cornerRadius(6)

                        if cameraDebugState.enabled {
                            Button(action: exportDebugBundle) {
                                Label("Bundle", systemImage: "shippingbox")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial)
                            .cornerRadius(6)
                        }

                        Divider().frame(height: 16)

                        Button(action: { startRecording() }) {
                            Label("Record", systemImage: "record.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial)
                        .cornerRadius(6)
                        .disabled(splatDocument.loadState != .loaded)
                    }
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .padding(.top, 12)
                } else {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(.red)
                            .frame(width: 9, height: 9)
                        Text(formatTime(recordingElapsed))
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                        Text("Esc to stop")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.red.opacity(0.3), lineWidth: 1)
                    )
                    .padding(.top, 12)
                }
                Spacer()
            }

            // Empty state
            if splatDocument.loadState == .idle {
                VStack(spacing: 16) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                        .padding(24)
                        .background(Circle().stroke(.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [6, 4])))

                    Text("Open Splat")
                        .font(.system(size: 15, weight: .medium))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .onTapGesture { isPickingFile = true }

                    Text("Supports .ply / .splat / .spz")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            // Loading
            if splatDocument.loadState == .loading {
                ProgressView("Loading...")
                    .padding(20)
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
            }

            // Error
            if case .error(let message) = splatDocument.loadState {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("Failed to load file")
                        .font(.headline)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Dismiss") {
                        Task { await splatDocument.closeFile() }
                    }
                    .padding(.top, 4)
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .cornerRadius(12)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [
                UTType(filenameExtension: "ply")!,
                UTType(filenameExtension: "splat")!,
                UTType(filenameExtension: "spz")!,
            ]
        ) { result in
            switch result {
            case .success(let url):
                let accessing = url.startAccessingSecurityScopedResource()
                Task {
                    await openFile(url)
                    try? await Task.sleep(for: .seconds(10))
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
            case .failure:
                break
            }
        }
        .task {
            // Auto-load file if provided via command-line argument
            if let url = autoOpenURL {
                await openFile(url)
            }
        }
    }

    private func openFile(_ url: URL) async {
        await splatDocument.openFile(url)
        cameraDebugState.recordFileLoaded(
            camera: cameraState,
            splatCenter: splatDocument.splatCenter,
            sampledPositions: splatDocument.debugSampledPositions
        )
    }

    private func toggleDebug() {
        cameraDebugState.setEnabled(
            !cameraDebugState.enabled,
            camera: cameraState,
            splatCenter: splatDocument.splatCenter,
            sampledPositions: splatDocument.debugSampledPositions
        )
    }

    private func refreshDebugProbe() {
        guard cameraDebugState.enabled else { return }
        cameraDebugState.updateProbe(
            camera: cameraState,
            splatCenter: splatDocument.splatCenter,
            sampledPositions: splatDocument.debugSampledPositions
        )
    }

    private func exportDebugBundle() {
        guard let bundleURL = cameraDebugState.exportBundle(
            camera: cameraState,
            splatCenter: splatDocument.splatCenter,
            sampledPositions: splatDocument.debugSampledPositions
        ) else { return }

        DebugPathClipboard.copy(bundleURL.path)
    }

    // MARK: - Recording

    private func startRecording() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: "mp4")!]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        savePanel.nameFieldStringValue = "splatrecorder-\(formatter.string(from: Date())).mp4"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            Task { @MainActor in
                do {
                    let size = recordingView?.drawableSize ?? CGSize(width: 1920, height: 1080)
                    try await videoRecorder.start(url: url, size: size, device: metalDevice)

                    // Lock window size
                    NSApp.mainWindow?.styleMask.remove(.resizable)

                    // Sync recording state to MTKView
                    recordingView?.setRecording(true)

                    isRecording = true
                    recordingElapsed = 0

                    recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                        Task { @MainActor in
                            recordingElapsed += 0.1
                        }
                    }
                } catch {
                    print("Failed to start recording: \(error)")
                }
            }
        }
    }

    private func stopRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil

        recordingView?.setRecording(false)

        Task {
            await videoRecorder.stop()

            await MainActor.run {
                isRecording = false
                NSApp.mainWindow?.styleMask.insert(.resizable)
            }
        }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var splatStatusText: String {
        if splatDocument.visibleSplatCount > 0 && splatDocument.visibleSplatCount != splatDocument.splatCount {
            return "\(splatDocument.visibleSplatCount.formatted()) / \(splatDocument.splatCount.formatted()) splats"
        }
        return "\(splatDocument.splatCount.formatted()) splats"
    }
}
