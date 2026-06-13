import AppKit
import Metal
import MetalKit
import CoreMedia

/// MTKView subclass that handles:
/// 1. Mouse/keyboard interaction (SuperSplat orbit model)
/// 2. Per-frame draw() with recording frame capture (Scheme B: single render + dual blit)
@MainActor
final class RecordingMTKView: MTKView, MTKViewDelegate {
    // MARK: - Dependencies

    var splatRenderer: SplatMetalRenderer?
    var videoRecorder: VideoRecorder?
    var cameraState: OrbitCameraState?
    var splatDocument: SplatDocumentState?
    var cameraDebugState: CameraDebugState?

    /// Called when recording should stop (Esc key).
    var onStopRecording: (() -> Void)?

    // MARK: - Mouse State

    private var pressedButton: Int = -1
    private var mouseX: CGFloat = 0
    private var mouseY: CGFloat = 0
    private var mmbStartX: CGFloat = 0
    private var mmbStartY: CGFloat = 0
    private var mmbDragged = false
    private let clickDragThreshold: CGFloat = 4

    // MARK: - Keyboard State

    private var keyboardInput = KeyboardMovementInput()
    private var lastFrameTime: CFTimeInterval = 0

    // MARK: - Render State

    private var commandQueue: MTLCommandQueue?
    private var renderSize: SIMD2<Int> = SIMD2(x: 1920, y: 1080)

    private var debugSplatCenter: SIMD3<Float> {
        splatDocument?.splatCenter ?? .zero
    }

    private var debugSampledPositions: [SIMD3<Float>] {
        splatDocument?.debugSampledPositions ?? []
    }

    // MARK: - Recording State (Scheme B)

    /// Set by the UI layer when recording starts/stops.
    @MainActor var isRecording = false
    @MainActor private var intermediateTexture: MTLTexture?

    // MARK: - Init

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        commonInit()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        guard let device = self.device ?? MTLCreateSystemDefaultDevice() else {
            assertionFailure("No Metal device available")
            return
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()

        colorPixelFormat = .bgra8Unorm_srgb
        depthStencilPixelFormat = .depth32Float
        sampleCount = 1
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        framebufferOnly = false  // Needed for blit operations during recording

        self.delegate = self

        // Enable mouse moved events
        let options: NSTrackingArea.Options = [.activeAlways, .mouseMoved, .enabledDuringMouseDrag, .inVisibleRect]
        let trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
    }

    // MARK: - NSResponder Overrides

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressedButton = event.buttonNumber
        let loc = convert(event.locationInWindow, from: nil)
        mouseX = loc.x
        mouseY = loc.y

        if pressedButton == 0, let camera = cameraState {
            _ = camera.applyCenterRayOrbitPivot(sampledPositions: debugSampledPositions)
        }

        if let camera = cameraState {
            cameraDebugState?.recordMouseDown(
                button: pressedButton,
                camera: camera,
                splatCenter: debugSplatCenter,
                sampledPositions: debugSampledPositions
            )
        }

        if pressedButton == 1 {  // Middle button
            mmbStartX = mouseX
            mmbStartY = mouseY
            mmbDragged = false
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let camera = cameraState else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let x = loc.x
        let y = loc.y
        let dx = Float(x - mouseX)
        let dy = Float(y - mouseY)
        mouseX = x
        mouseY = y

        switch pressedButton {
        case 0:  // Left → Orbit
            let before = CameraPoseSnapshot(camera: camera)
            camera.orbit(dx: dx, dy: dy)
            recordDrag(.orbitDrag, dx: dx, dy: dy, before: before, camera: camera)
        case 1:  // Middle → Zoom
            let before = CameraPoseSnapshot(camera: camera)
            camera.zoom(amount: dy)
            mmbDragged = true
            recordDrag(.zoomDrag, dx: dx, dy: dy, before: before, camera: camera)
        case 2:  // Right → Pan
            let before = CameraPoseSnapshot(camera: camera)
            camera.panByScreenDrag(dx: dx, dy: dy)
            recordDrag(.panDrag, dx: dx, dy: dy, before: before, camera: camera)
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let releasedButton = pressedButton
        if pressedButton == 1 && !mmbDragged {
            // Middle click (no significant drag) → Focus
            let dx = abs(mouseX - mmbStartX)
            let dy = abs(mouseY - mmbStartY)
            if dx < clickDragThreshold && dy < clickDragThreshold {
                let diagonal = splatDocument?.splatDiagonal ?? 1.0
                let target = cameraState?.target ?? .zero
                cameraState?.focusOnBoundingBox(center: target, diagonal: diagonal)
            }
        }
        if releasedButton >= 0, let camera = cameraState {
            cameraDebugState?.recordMouseUp(
                button: releasedButton,
                camera: camera,
                splatCenter: debugSplatCenter,
                sampledPositions: debugSampledPositions
            )
        }
        pressedButton = -1
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = Float(event.scrollingDeltaY) * 0.1
        cameraState?.zoom(wheelDelta: delta)
    }

    override func keyDown(with event: NSEvent) {
        // Command key passthrough — let Cmd+C, Cmd+V, Cmd+Q etc. work normally.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 4:   // H key — toggled by SwiftUI command path when focused here
            if let camera = cameraState {
                cameraDebugState?.setEnabled(
                    !(cameraDebugState?.enabled ?? false),
                    camera: camera,
                    splatCenter: debugSplatCenter,
                    sampledPositions: debugSampledPositions
                )
            }
        case 35:  // P key — print current debug snapshot
            if let camera = cameraState {
                cameraDebugState?.recordKeySnapshot(
                    key: "P",
                    camera: camera,
                    splatCenter: debugSplatCenter,
                    sampledPositions: debugSampledPositions
                )
            }
        case 3:   // F key — focus on bounding box center
            let center = splatDocument?.splatCenter ?? cameraState?.target ?? .zero
            let diagonal = splatDocument?.splatDiagonal ?? 1.0
            if event.modifierFlags.contains(.shift) {
                splatDocument?.resetCameraToDefaultView()  // Shift+F → full reset (angles + focus)
            } else {
                cameraState?.focusOnBoundingBox(center: center, diagonal: diagonal)
            }
        case 53:  // Esc
            onStopRecording?()
        default:
            if KeyboardMovementInput.movementKeyCodes.contains(event.keyCode) {
                // Filter auto-repeat for movement keys
                if event.isARepeat { return }
                keyboardInput.keyDown(event.keyCode)
                keyboardInput.shiftHeld = event.modifierFlags.contains(.shift)
                keyboardInput.optionHeld = event.modifierFlags.contains(.option)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        keyboardInput.keyUp(event.keyCode)
    }

    /// Update modifier flags when Shift/Option are pressed or released independently
    /// of movement keys. Without this, pressing Shift while already holding W would
    /// not switch to 10x speed until W is released and re-pressed.
    override func flagsChanged(with event: NSEvent) {
        keyboardInput.shiftHeld = event.modifierFlags.contains(.shift)
        keyboardInput.optionHeld = event.modifierFlags.contains(.option)
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        keyboardInput.resetAllKeys()
        keyboardInput.shiftHeld = false
        keyboardInput.optionHeld = false
        return super.resignFirstResponder()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderSize = SIMD2(x: Int(size.width), y: Int(size.height))
        cameraDebugState?.viewportSize = renderSize
        splatRenderer?.setDrawableSize(size)

        // Invalidate intermediate texture on resize
        intermediateTexture = nil
    }

    func draw(in view: MTKView) {
        if cameraDebugState?.enabled == true {
            cameraDebugState?.viewportSize = renderSize
        }

        // Apply keyboard camera movement
        let currentTime = CACurrentMediaTime()
        let deltaTime = lastFrameTime > 0 ? Float(currentTime - lastFrameTime) : 0
        lastFrameTime = currentTime
        if deltaTime > 0 {
            let movement = keyboardInput.movement
            if simd_length(movement.direction) > 0 {
                cameraState?.moveView(direction: movement.direction,
                                      deltaTime: deltaTime,
                                      speedMultiplier: movement.speedMultiplier)
                if let camera = cameraState, cameraDebugState?.enabled == true {
                    cameraDebugState?.updateProbe(
                        camera: camera,
                        splatCenter: debugSplatCenter,
                        sampledPositions: debugSampledPositions
                    )
                }
            }
        }

        guard let renderer = splatRenderer, renderer.isReadyToRender else { return }
        guard let drawable = currentDrawable else { return }
        guard let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
        guard let device = view.device else { return }

        let now = CMClockGetTime(CMClockGetHostTimeClock())

        if isRecording {
            // === RECORDING FRAME PATH (Scheme B) ===
            guard let frame = tryCaptureFrame(presentationTime: now) else {
                // Throttled or pool exhausted — render normally this frame
                renderNormally(renderer: renderer, to: drawable.texture,
                               commandBuffer: commandBuffer, drawable: drawable)
                return
            }

            // Ensure intermediate texture exists and matches size
            let targetSize = MTLSize(width: Int(renderSize.x), height: Int(renderSize.y), depth: 1)
            if intermediateTexture == nil ||
                intermediateTexture!.width != targetSize.width ||
                intermediateTexture!.height != targetSize.height {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: colorPixelFormat,
                    width: targetSize.width,
                    height: targetSize.height,
                    mipmapped: false
                )
                desc.usage = [.renderTarget, .shaderRead]
                desc.storageMode = .private
                intermediateTexture = device.makeTexture(descriptor: desc)
            }

            guard let midTex = intermediateTexture else {
                // Intermediate texture creation failed — abandon this frame
                videoRecorder?.discardFrame(frame)
                renderNormally(renderer: renderer, to: drawable.texture,
                               commandBuffer: commandBuffer, drawable: drawable)
                return
            }

            // Step 1: Render to intermediate texture
            let didRender: Bool
            do {
                didRender = try renderer.render(
                    to: midTex,
                    depthTexture: depthStencilTexture,
                    commandBuffer: commandBuffer
                )
            } catch {
                print("Recording render error: \(error)")
                videoRecorder?.discardFrame(frame)
                commandBuffer.commit()
                return
            }

            guard didRender else {
                // Render skipped — abandon this frame
                videoRecorder?.discardFrame(frame)
                commandBuffer.commit()
                return
            }

            // Step 2: Blit intermediate → drawable (display)
            if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                blitEncoder.copy(
                    from: midTex, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: targetSize,
                    to: drawable.texture, destinationSlice: 0,
                    destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blitEncoder.endEncoding()
            }

            // Step 3: Blit intermediate → frame texture (recording)
            var recordingBlitSucceeded = false
            if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                let frameTargetSize = MTLSize(width: frame.texture.width, height: frame.texture.height, depth: 1)
                blitEncoder.copy(
                    from: midTex, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(
                        width: min(targetSize.width, frameTargetSize.width),
                        height: min(targetSize.height, frameTargetSize.height),
                        depth: 1
                    ),
                    to: frame.texture, destinationSlice: 0,
                    destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blitEncoder.endEncoding()
                recordingBlitSucceeded = true
            }

            if recordingBlitSucceeded {
                // Submit frame for encoding after GPU completes
                // Capture recorder outside the closure to avoid @MainActor access from GPU callback.
                let recorder = videoRecorder
                commandBuffer.addCompletedHandler { _ in
                    // finishFrame is nonisolated — safe from completion handler
                    recorder?.finishFrame(frame)
                }
            } else {
                // Recording blit failed — abandon this frame
                videoRecorder?.discardFrame(frame)
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        } else {
            // === NORMAL FRAME PATH ===
            renderNormally(renderer: renderer, to: drawable.texture,
                           commandBuffer: commandBuffer, drawable: drawable)
        }
    }

    // MARK: - Private Helpers

    private func recordDrag(
        _ event: CameraDebugEvent,
        dx: Float,
        dy: Float,
        before: CameraPoseSnapshot,
        camera: OrbitCameraState
    ) {
        cameraDebugState?.recordDrag(
            event: event,
            button: pressedButton,
            dx: dx,
            dy: dy,
            before: before,
            after: CameraPoseSnapshot(camera: camera),
            camera: camera,
            splatCenter: debugSplatCenter,
            sampledPositions: debugSampledPositions
        )
    }

    @MainActor
    private func renderNormally(renderer: SplatMetalRenderer,
                                 to texture: MTLTexture,
                                 commandBuffer: MTLCommandBuffer,
                                 drawable: MTLDrawable) {
        do {
            let didRender = try renderer.render(
                to: texture,
                depthTexture: depthStencilTexture,
                commandBuffer: commandBuffer
            )
            if didRender {
                commandBuffer.present(drawable)
            }
        } catch {
            print("Render error: \(error)")
        }
        commandBuffer.commit()
    }

    @MainActor
    private func tryCaptureFrame(presentationTime: CMTime) -> RecordingFrame? {
        return videoRecorder?.makeFrameTexture(hostTime: presentationTime)
    }

    /// Update recording state from the VideoRecorder.
    @MainActor
    func setRecording(_ recording: Bool) {
        isRecording = recording
        if recording {
            intermediateTexture = nil
        }
    }
}
