import SwiftUI
import MetalKit

/// NSViewRepresentable wrapper for RecordingMTKView.
struct SplatMetalView: NSViewRepresentable {
    let splatRenderer: SplatMetalRenderer
    let cameraState: OrbitCameraState
    let videoRecorder: VideoRecorder
    let splatDocument: SplatDocumentState
    let cameraDebugState: CameraDebugState
    let onStopRecording: () -> Void
    var onViewCreated: ((RecordingMTKView) -> Void)?

    func makeNSView(context: Context) -> RecordingMTKView {
        let mtkView = RecordingMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        mtkView.splatRenderer = splatRenderer
        mtkView.cameraState = cameraState
        mtkView.videoRecorder = videoRecorder
        mtkView.splatDocument = splatDocument
        mtkView.cameraDebugState = cameraDebugState
        mtkView.onStopRecording = onStopRecording
        DispatchQueue.main.async {
            onViewCreated?(mtkView)
            mtkView.window?.makeFirstResponder(mtkView)
        }
        return mtkView
    }

    func updateNSView(_ nsView: RecordingMTKView, context: Context) {
        nsView.cameraDebugState = cameraDebugState
    }
}
