# SplatRecorder

A macOS viewer and recorder for 3D Gaussian Splat files, built on the [MetalSplatter](../../README.md) rendering library.

## Requirements

- macOS 15+ (Sequoia)
- Apple Silicon (Intel is not supported)
- Clone the repo as `MetalSplatter/` (SwiftPM derives the package identity from the directory name)

## Running

### GUI mode

Launch the app and open a file interactively:

```bash
swift run SplatRecorder
```

Or auto-load a file at startup:

```bash
swift run SplatRecorder path/to/scene.ply
```

Supported formats: `.ply`, `.splat`, `.spz`

### Validation mode (headless)

Render test frames from a splat file and save them as PNGs:

```bash
swift run SplatRecorder --validate <input.ply|splat|spz> <output-dir>
```

This renders three views (default focus, orbit, zoom) and writes PNG images plus diagnostic metadata to stdout. Exits with code 0 on success, 1 on failure.

### Debug axis mode (headless)

Render axis-aligned debug scenes for verifying coordinate system correctness:

```bash
swift run SplatRecorder --debug-axis <output-dir>
```

Produces PNG images and an `axis-report.json` with pixel-level measurements for each camera mode and coordinate space.

## Controls

### Mouse

| Input | Action |
|-------|--------|
| Left-drag | Orbit camera around focal point |
| Scroll wheel | Zoom in/out |
| Middle-drag | Pan (translate focal point) |

### Keyboard

| Key | Action |
|-----|--------|
| W | Move forward |
| S | Move backward |
| A | Move left |
| D | Move right |
| Q | Move down |
| E | Move up |
| Shift (hold) | 10x speed boost |
| Option/Alt (hold) | 0.1x precision mode |
| Esc | Stop recording |

### View presets

Click a circle on the ViewCube (bottom-right corner) to snap to a preset view:

- **X** (red, filled) -- Right view
- **X** (red, outline) -- Left view
- **Y** (green, filled) -- Top view
- **Y** (green, outline) -- Bottom view
- **Z** (blue, filled) -- Front view
- **Z** (blue, outline) -- Back view

## Toolbar

| Button | Description |
|--------|-------------|
| Open | File picker for `.ply`, `.splat`, `.spz` files |
| Reset | Return camera to default viewpoint |
| Debug | Toggle camera debug HUD overlay |
| Bundle | (visible in debug mode) Export a debug bundle to `/tmp` and copy path to clipboard |
| Record | Start video recording (opens save dialog) |

## Recording

> **⚠ Work in progress:** The recording pipeline is not yet functional.
> The UI and controls are in place, but frame capture is not wired up.
> Contributions welcome — see `RecordingMTKView.tryCaptureFrame()`.

1. Load a splat file.
2. Click **Record** in the toolbar.
3. Choose an output location (MP4 format, H.264).
4. Move the camera. The window is locked to its current size during recording.
5. Press **Esc** to stop.

Recording captures at 30 fps at the current window resolution.

## Debug features

### Camera debug HUD

Toggled via the **Debug** toolbar button. Displays:
- Camera target, eye position, yaw/pitch/distance
- Screen-space projection of target and splat center
- Distance metrics (target-to-center, nearest-point-to-ray)
- Last interaction event and input deltas

### Debug overlay

When debug mode is active, a semi-transparent overlay shows:
- Center crosshair
- Target marker (red)
- Splat center marker (green)
- Nearest ray point marker (blue)

### Debug bundle export

Click **Bundle** (appears in debug mode) to export a snapshot to `/tmp/splatrecorder-debug-bundle-<pid>-<timestamp>/`. Contents:
- `camera-debug.jsonl` -- structured interaction log
- `latest-snapshot.json` -- current camera pose and probe metrics
- `README.txt` -- field descriptions

The bundle path is copied to the clipboard automatically.

## Project structure

```
Apps/SplatRecorder/
  Package.swift              -- Swift Package Manager manifest
  Sources/
    App/
      SplatRecorderApp.swift         -- Entry point, CLI arg parsing
      SplatRecorderContentView.swift -- Main SwiftUI view
    Camera/
      OrbitCameraState.swift         -- Spherical orbit camera model
      CameraOrbitPivotPicker.swift   -- Depth-aware pivot selection
      CameraRay.swift                -- Ray construction utilities
      MatrixMathUtil.swift           -- Projection matrix helpers
      ViewPreset.swift               -- Six axis-aligned view presets
    Debug/
      CameraDebugState.swift         -- Debug state management
      CameraDebugTypes.swift         -- Codable debug data types
      CameraDebugLogger.swift        -- JSONL event logger
      CameraDebugBundleExporter.swift -- Bundle export to /tmp
      DebugPathClipboard.swift       -- Clipboard helper
    Input/
      KeyboardMovementInput.swift    -- WASD+QE key mapping
    Recording/
      VideoRecorder.swift            -- AVAssetWriter H.264 recorder
    Renderer/
      SplatMetalRenderer.swift       -- Bridges MetalSplatter to MTKView
      SplatMetalView.swift           -- NSViewRepresentable Metal view
      RecordingMTKView.swift         -- MTKView subclass with recording support
    State/
      SplatDocumentState.swift       -- File loading and splat lifecycle
      SplatDisplayBounds.swift       -- Robust bounding box computation
      SplatDisplayTransform.swift    -- Coordinate system transforms
    UI/
      CameraDebugHUD.swift           -- Debug text overlay and markers
      ViewCube.swift                 -- Orientation gizmo
    Validation/
      SplatRecorderValidation.swift  -- Headless splat validation
      SplatRecorderAxisValidation.swift -- Headless axis debug
      DebugAxisScene.swift           -- Synthetic axis scene generator
  Tests/
    ...                              -- Unit tests
```

## Dependencies

- [MetalSplatter](../../README.md) -- Core 3D Gaussian Splat renderer (local package)
- Apple Metal framework
- AVFoundation (video recording)
