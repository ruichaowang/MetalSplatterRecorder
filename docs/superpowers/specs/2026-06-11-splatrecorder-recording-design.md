# SplatRecorder 录像功能设计

日期: 2026-06-11

## Summary

第一版实现"手动操作视角时录制纯 splat 画面"：MP4/H.264、30fps、当前窗口像素尺寸，不录 toolbar/HUD/ViewCube，不录音频。

核心任务是接通 `MTLTexture → CVPixelBuffer → AVAssetWriter` 链路——当前 `RecordingMTKView.tryCaptureFrame(...)` 始终返回 `nil`，其余 UI 和 AVAssetWriter 管线已就位。

## Architecture Overview

```
SplatRecorderContentView (SwiftUI)
  - startRecording() / stopRecording()
  - 锁窗口大小 / 恢复 UI / 错误展示
         │
RecordingMTKView (MTKView)
  draw(in:):
    if isRecording:
      frame = recorder.makeFrameTexture(hostTime)
      if frame != nil:
        render → intermediateTexture
        blit intermediate → drawable (显示)
        blit intermediate → frame.texture (录制)
        cmdBuffer completed → finishFrame(frame)
    else:
      renderNormally()
         │
VideoRecorder (class + Mutex<State>)
  - start(url:size:device:fps:)
  - makeFrameTexture(hostTime:) → RecordingFrame?
  - finishFrame(_:)
  - stop() throws
  State: AVAssetWriter, CVPixelBufferPool,
         CVMetalTextureCache, counters, errors
```

## Concurrency Model

**`VideoRecorder` 从 `actor` 重构为 `class + Mutex<State>`**（`import Synchronization`）。

理由：
- 项目已使用 `Mutex`（`SplatRenderer`、`SplatSorter`），保持一致性
- `makeFrameTexture` 暴露为同步方法，`@MainActor draw(in:)` 和 GPU completion handler 均可直接调用，无需 `await`
- `Mutex` 的 `~Copyable` 类型系统保证正确使用

```swift
import Synchronization

final class VideoRecorder: @unchecked Sendable {
    struct State {
        var isRecording = false
        var encodedFrameCount = 0
        var droppedFrameCount = 0
        var inflightFrameCount = 0   // GPU 未完成的 frame 数
        var lastError: VideoRecorderError?
        var assetWriter: AVAssetWriter?
        var assetWriterInput: AVAssetWriterInput?
        var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        var pixelBufferPool: CVPixelBufferPool?
        var textureCache: CVMetalTextureCache?
        var outputURL: URL?
        var videoSize: CGSize = .zero
        var targetFPS: Int = 30
        var startHostTime: CMTime = .invalid
        var lastFrameHostTime: CMTime = .invalid
    }

    private let state = Mutex(State())

    // 只读统计（同步，任何线程安全）
    var isRecording: Bool { state.withLock { $0.isRecording } }
    var encodedFrameCount: Int { state.withLock { $0.encodedFrameCount } }
    var droppedFrameCount: Int { state.withLock { $0.droppedFrameCount } }
    var outputURL: URL? { state.withLock { $0.outputURL } }
    var lastError: VideoRecorderError? { state.withLock { $0.lastError } }
}
```

## API Design

```swift
final class VideoRecorder: @unchecked Sendable {

    // MARK: - Lifecycle

    func start(url: URL, size: CGSize, device: MTLDevice, fps: Int = 30) throws
    func stop() throws                        // 同步等待 finishWriting
    func cancel()                             // 丢弃录制

    // MARK: - Per-Frame Capture

    /// 创建 pixel-buffer-backed Metal texture，内部做 fps 节流。
    /// 返回 nil = 该帧不应捕获（节流、pool 耗尽等）。
    func makeFrameTexture(hostTime: CMTime) -> RecordingFrame?

    /// GPU 完成 blit 后调用，将 pixel buffer 送入 AVAssetWriter。
    /// 非隔离方法，GPU completion handler 中直接调用。
    func finishFrame(_ frame: RecordingFrame)
}
```

## RecordingFrame

```swift
struct RecordingFrame {
    let cvTexture: CVMetalTexture    // 持有引用，防止底层 CVPixelBuffer 在 GPU 操作期间被回收
    let texture: MTLTexture          // CVMetalTextureGetTexture(cvTexture)
    let pixelBuffer: CVPixelBuffer   // 同一块内存
    let presentationTime: CMTime     // 录制开始后的相对时间
}
```

**关键**：`cvTexture` 必须保留——`CVMetalTextureGetTexture()` 返回的 `MTLTexture` 不 retain `CVMetalTexture`。如果 `CVMetalTexture` 被 ARC 释放，底层 `CVPixelBuffer` 的 retain count 下降，pixel buffer pool 可能将其回收给下一帧，而此时 GPU 可能还在使用。

## Timestamp Strategy

使用**录制开始后的相对时间**（host time delta）：

```
start() 时记录: startHostTime = CMClockGetTime(CMClockGetHostTimeClock())
每帧: presentationTime = currentHostTime - startHostTime
```

不使用 frame index × interval 方案，因为 host time delta 如实反映真实时间流逝（包括卡顿），更诚实。

## Frame Throttle

`makeFrameTexture` 内部做 30fps 节流：

```swift
func makeFrameTexture(hostTime: CMTime) -> RecordingFrame? {
    state.withLock { s in
        guard s.isRecording else { return nil }

        // 节流：距上一帧不足 1/fps 秒则跳过
        if s.lastFrameHostTime.isValid {
            let interval = CMTime(value: 1, timescale: Int32(s.targetFPS))
            if CMTimeSubtract(hostTime, s.lastFrameHostTime) < interval {
                s.droppedFrameCount += 1
                return nil
            }
        }

        // 从 pool 取 pixel buffer
        // ... CVPixelBufferPoolCreatePixelBuffer ...

        // 创建 CVMetalTexture
        // ... CVMetalTextureCacheCreateTextureFromImage ...

        s.lastFrameHostTime = hostTime
        return RecordingFrame(...)
    }
}
```

`RecordingMTKView` 中删除本地 `shouldCaptureFrame` / `lastCaptureTime` 逻辑，统一由 `VideoRecorder` 控制。

## Recording Size

- 从 `recordingView.drawableSize` 取像素尺寸
- 宽高向下规整为偶数（`rawWidth & ~1`），满足 H.264 编码要求
- 录制期间锁窗口大小（`styleMask.remove(.resizable)`）
- 如果 backing size 变化 → 致命错误，立即停止录制

## Error Handling

分级处理：

| 级别 | 场景 | 行为 |
|------|------|------|
| info | pool 耗尽、input not ready、帧间隔太短 | drop frame + `droppedFrameCount++` + 继续 |
| fatal | drawableSize 变化、writer error、stop 超时（5s 内 inflight frame 未排空） | 立即停止 + `lastError` 记录 + UI 恢复 |

录制失败恢复 UI：
1. 停止 timer
2. `recordingView.setRecording(false)`
3. 恢复 window resizable（`styleMask.insert(.resizable)`）
4. 记录 `lastError`，stop 后可读取展示

## Stop/Finalize: Inflight Frame Drain

**问题**：`stop()` 是同步调用（内部用 semaphore 等待 `finishWriting`），但 `finishFrame` 在 GPU command buffer 的 `addCompletedHandler` 回调中执行。如果用户按 Esc 时还有 command buffer 未完成：

```
Frame N-1: cmdBuffer → completed → finishFrame → append ✓
Frame N:   cmdBuffer → GPU 还在执行...
[用户按 Esc]
stop() → markAsFinished → finishWriting → 写文件
[Frame N 的 GPU 完成] → finishFrame → append → 💥 writer 已 finish
```

会导致尾帧丢失或 writer 状态错误。

**方案**：在 `State` 中增加 `inflightFrameCount: Int` 计数器。

```
makeFrameTexture 返回非 nil → inflightFrameCount += 1
finishFrame 调用完毕        → inflightFrameCount -= 1
stop() 轮询等待             → inflightFrameCount == 0，然后 markAsFinished + finishWriting
cancel() 不等待             → 直接 cancelWriting + 清理
```

`stop()` 伪代码：

```swift
func stop() throws {
    // 1. 标记停止，阻止新 frame
    state.withLock { $0.isRecording = false }

    // 2. 等待所有 inflight frame 完成（带超时，避免死锁）
    let deadline = DispatchTime.now() + .seconds(5)
    while state.withLock({ $0.inflightFrameCount > 0 }) {
        if DispatchTime.now() > deadline {
            throw VideoRecorderError.stopTimeout
        }
        Thread.sleep(forTimeInterval: 0.01)
    }

    // 3. Finalize
    var writeError: Error?
    let semaphore = DispatchSemaphore(value: 0)
    state.withLock { s in
        s.assetWriterInput?.markAsFinished()
        s.assetWriter?.finishWriting { writeError = $0; semaphore.signal() }
    }
    semaphore.wait()
    if let error = writeError { throw error }
}
```

## Pixel Format Consistency

**问题**：当前 display/intermediate 使用 MTKView 的 `colorPixelFormat` = `.bgra8Unorm_srgb`（sRGB 色彩空间），而 `CVMetalTextureCacheCreateTextureFromImage` 使用的 pixel format 是 `.bgra8Unorm`（线性色彩空间）。Blit 时如果源和目标 pixel format 不兼容，Metal validation layer 会报错。

**方案**：

- **Intermediate texture**：使用 `.bgra8Unorm`（非 sRGB），作为渲染目标时 renderer 输出线性值
- **Recording texture**（pixel-buffer-backed）：使用 `.bgra8Unorm`，与 intermediate 一致，blit 直通无需转换
- **Drawable texture**：MTKView 自带 `.bgra8Unorm_srgb`，Metal blit encoder 自动处理 `.bgra8Unorm → .bgra8Unorm_srgb` 的隐式色彩空间转换

```
render → intermediateTexture (.bgra8Unorm)
  ├─ blit → drawable.texture (.bgra8Unorm_srgb)  ← Metal 自动转换
  └─ blit → frame.texture (.bgra8Unorm)          ← 直通，无转换
```

这样录制输出的 MP4 使用线性色彩空间，显示端自动转为 sRGB，颜色正确。

## Package Identity Fix

**问题**：`Apps/SplatRecorder/Package.swift` 中 dependency 写的是 `.package(path: "../..")`，SwiftPM 根据目录名推断包名。如果用户 clone 仓库到非 `MetalSplatter` 目录（如 GitHub 默认的 `MetalSplatterRecorder`），会报 `unknown package 'MetalSplatter'`。

**修复**：在 path dependency 中显式指定 name：

```swift
// 修改前
.package(path: "../.."),

// 修改后
.package(name: "MetalSplatter", path: "../.."),
```

同理，target dependency 中的 `.product(name: "MetalSplatter", package: "MetalSplatter")` 保持不变即可。

这个修复独立于录像功能，可以在实施前先行提交。

## Render Pipeline: Single Render + Dual Blit

```
1. makeFrameTexture(hostTime) → RecordingFrame (含 pixel-buffer-backed texture)
   → inflightFrameCount += 1
2. render to intermediateTexture (.bgra8Unorm, offscreen)
3. blit intermediateTexture → drawable.texture (.bgra8Unorm_srgb, Metal 自动转换)
4. blit intermediateTexture → frame.texture (.bgra8Unorm, 直通)
5. commandBuffer.addCompletedHandler {
     recorder.finishFrame(frame)
     → inflightFrameCount -= 1
   }
6. commandBuffer.present(drawable)
7. commandBuffer.commit()
```

## Validation CLI

新增 `--validate-recording <output-dir>`：

- 复用 `DebugAxisScene` 生成 7 个彩色轴点的 synthetic scene
- 固定 1280×720，30fps，1 秒（30 帧）
- 走完整 splat 渲染 → VideoRecorder 链路
- 输出 `recording-report.json`：

```json
{
  "outputPath": "/tmp/.../recording.mp4",
  "size": { "width": 1280, "height": 720 },
  "durationSeconds": 1.0,
  "encodedFrameCount": 30,
  "droppedFrameCount": 0,
  "fileSizeBytes": 123456
}
```

## Files Changed

| 文件 | 变更 |
|------|------|
| `Apps/SplatRecorder/Package.swift` | 显式指定 path dependency name（`package(name: "MetalSplatter", path: "../..")`），修复非标准目录名构建 |
| `Apps/SplatRecorder/Sources/Recording/VideoRecorder.swift` | actor → class + Mutex，新增 State（含 inflightFrameCount）、统计字段、错误分类、时间戳重构、stop 排空 inflight frames |
| `Apps/SplatRecorder/Sources/Renderer/RecordingMTKView.swift` | 补全 `tryCaptureFrame()`，删除本地 throttle 逻辑，intermediate texture 改用 `.bgra8Unorm` |
| `Apps/SplatRecorder/Sources/App/SplatRecorderContentView.swift` | 录制前校验、stop 后读取 recorder 状态/错误 |
| `Apps/SplatRecorder/Sources/App/SplatRecorderApp.swift` | 新增 `--validate-recording` CLI 分支 |
| `Apps/SplatRecorder/Sources/Validation/SplatRecorderValidation.swift` | 新增 `RecordingValidation` enum |
| `Apps/SplatRecorder/Tests/VideoRecorderTests.swift` | **新建**，覆盖 start/stop、throttle、尺寸规整、生命周期、inflight drain |
| `Apps/SplatRecorder/README.md` | 移除 recording WIP 警告，更新使用说明（含目录命名要求） |

## Verification Plan

### Unit Tests (`VideoRecorderTests`)

- `start/stop` 能生成非空 MP4
- `makeFrameTexture` 第一帧返回 texture，短于 1/30s 的下一帧被节流返回 nil
- 录制尺寸规整为偶数
- `RecordingFrame` 保留 `CVMetalTexture`，GPU completion 后 append 不崩溃

### Integration Tests

- 用 `MTLCommandQueue` 写入 3-5 个纯色/渐变 frame，stop 后用 `AVAsset` 验证：
  - 有 video track
  - size 等于请求尺寸
  - duration > 0
  - 文件大小 > 最小阈值

### CLI Verification

```bash
# Root tests
swift test

# SplatRecorder tests
cd Apps/SplatRecorder && swift test

# Build check
cd Apps/SplatRecorder && swift build --product SplatRecorder

# Recording validation (synthetic scene, no user PLY needed)
cd Apps/SplatRecorder && swift run SplatRecorder --validate-recording /tmp/splatrecorder-recording-check

# Existing render validation (user PLY)
cd Apps/SplatRecorder && swift run SplatRecorder --validate /Users/ruichaowang/Downloads/朝阳区.ply /tmp/splatrecorder-render-check
```

### Manual Acceptance

```bash
cd Apps/SplatRecorder && swift run SplatRecorder /Users/ruichaowang/Downloads/朝阳区.ply
```

1. 点击 Record 保存 MP4
2. 录制 5-10 秒，同时左键 orbit、滚轮 zoom、WASD 移动
3. 按 Esc 停止
4. QuickTime 打开 MP4，确认：画面非黑、视角变化被录下、无 toolbar/HUD/ViewCube、时长正确、窗口恢复可调整大小

## Assumptions

- 第一版只支持 MP4/H.264、30fps、当前窗口尺寸
- 第一版不支持录 UI overlay、不支持音频、不支持后台自动 orbit、不支持分辨率/fps 设置面板
- 如果 encoder 跟不上，允许丢帧，但 UI 交互不能明显卡住
- 要求 macOS 15+（项目已设），使用 `Synchronization.Mutex`
