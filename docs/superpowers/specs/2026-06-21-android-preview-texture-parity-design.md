# 设计:安卓预览 Texture + 导出,对齐 iOS

> 日期:2026-06-21
> 阶段:GF 功能 Flutter 化 — 阶段1 安卓补齐(iOS 已 go)
> 依据:`docs/superpowers/specs/2026-06-15-ios-preview-texture-spike-design.md`(iOS 终态)
> 范围决策:**只做 Texture 后端 + 导出**;不做 Flutter 内嵌 PlatformView 对照后端
> (原生全屏 `GyroflowActivity` 的 SurfaceView 预览已是现成的 A/B 参照)。

## 目标

把 iOS 已验收(go)的预览 Texture + 导出路在安卓侧补齐,使 example 的
「预览 Texture spike (dev)」页 / 编辑页在安卓真机上:打开视频→零拷贝显示防抖预览→
play/pause/seek/暂停态参数实时重渲→导出到相册/所选目录,行为与 iOS 一致。

**不改**:`GyroflowNative.kt`、Rust core、`gyroflow_ffi.h`、已完成的 S7 状态层、iOS 侧、
旧 `open()` 全屏页。

## 关键认知:安卓与 iOS 的零拷贝路径不同(更简单)

iOS 的 Flutter 纹理 API 是**拉取式**(`FlutterTexture.copyPixelBuffer`,合成器来要哪张),
所以 iOS 必须自建 3 张 IOSurface 背书的 `CVPixelBuffer` 轮转池 + `CVMetalTextureCache`,
并用 GPU 完成回调标 frame-available —— `PreviewController.mm` 那 493 行大半是这套缓冲管理。

安卓的 Flutter 纹理 API(`TextureRegistry.SurfaceProducer`,Flutter 3.22+;本仓 3.41.3)
是**推送式**:它直接给出一个 `android.view.Surface`,谁往里渲、Flutter 合成器就采样谁。
而安卓引擎侧**已有** `GyroflowNative.nativePreviewSurfaceCreated(surface, w, h)` —— wgpu
建设备并把「去畸变+稳定」结果直接渲进传入的任意 Surface(旧全屏页给的是 SurfaceView 的
`holder.surface`)。

⟹ 安卓零拷贝预览 = **把 SurfaceProducer 的 Surface 交给 `nativePreviewSurfaceCreated`**,
无需任何缓冲池、无新 Rust/GPU 代码。解码→喂帧循环也现成(`VideoDecoder` →
`nativeProcessFrame`,旧 `GyroflowActivity` 在用)。所以本轮基本是 **Kotlin 胶水**。

另一处差异:**引擎是 `.so` 单例**,无显式句柄。iOS `PreviewApiImpl` 要把
`stabilizerHandle` 闭包共享给预览;安卓所有 `nativeXxx` 都作用于同一单例,预览控制器
直接调 `GyroflowNative.*` 即与 `EngineApiImpl`/`ParamsModel` 共享同一引擎,**无句柄可传**。

## 架构与组件

```
Flutter 预览页(example,已有,跨端)
  Texture(textureId) + 播放控制 + HUD     ← 已实现,不改(仅隐藏安卓上的 PlatformView 切换按钮)
        │ Pigeon PreviewApi(已生成 EngineApi.g.kt 接口)
        ▼
Android PreviewApiImpl.kt(新)
  ├─ 持有 PreviewController + GyroflowExporter
  ├─ createPreviewTexture / dispose / play / pause / seekTo / renderOnce / takeCompositedFrameCount
  └─ startExport / cancelExport  → 复用 GyroflowExporter,进度经 EngineEvents.onExportProgress
        │
        ▼
Android PreviewController.kt(新)
  ├─ TextureRegistry.SurfaceProducer  : 建/设尺寸/取 Surface/release;textureId = producer.id()
  ├─ nativePreviewSurfaceCreated(surface, outW, outH) : wgpu 渲进该 Surface(零拷贝)
  ├─ VideoDecoder(MediaCodec)         : 解码 YUV 帧 → onFrame
  ├─ onFrame → nativeProcessFrame(y,u,v,…) : 去畸变+稳定+渲进 Surface(共享单例引擎)
  ├─ SurfaceProducer.Callback         : 前后台/surface 重建时重绑 + 重渲(避免黑屏)
  └─ play/pause/seek 转发 VideoDecoder;renderOnce → VideoDecoder.rerender()
```

## PreviewApi 契约(已生成,安卓实现)

`EngineApi.g.kt` 已有 `interface PreviewApi`(同 iOS 契约),安卓需实现:

| 方法 | 安卓实现 |
|---|---|
| `createPreviewTexture(uri): PreviewInfo` | 读 `nativeGetOutputSize()` 得 outW/outH(此刻引擎已 openVideo+设好输出尺寸);建 SurfaceProducer、setSize、`nativePreviewSurfaceCreated`;建并 start `VideoDecoder`(默认暂停);返回 `PreviewInfo(producer.id(), outW, outH)`。**在平台线程同步执行**(SurfaceProducer/TextureRegistry 须主线程)。 |
| `disposePreviewTexture(id)` | 停 `VideoDecoder`、`nativePreviewSurfaceDestroyed()`、`producer.release()`。 |
| `play()` / `pause()` | `decoder.play()` / `decoder.pause()`。 |
| `seekTo(us)` | `decoder.seekTo(us/durationUs)`(VideoDecoder 用进度 0..1)。 |
| `renderOnce()` | 暂停态参数 recompute 后重渲当前帧:`decoder.rerender()`(对齐旧 `GyroflowActivity` 的 `seekTo(lastProgress)`)。 |
| `takeCompositedFrameCount()` | 推送式无「合成被拉取」计数;以**产出帧数**(onFrame 实际喂帧次数)为代理,返回 `produce*1000 + produce`(dev FPS HUD 用,近似即可,日志注明)。 |
| `setExportMode(on)` | 透传 `nativeSetExportMode(on)`(导出走 startExport,这里基本不单独用)。 |
| `startExport(req, cb)` | 见下。 |
| `cancelExport()` | `exporter?.cancel()`。 |

`PreviewInfo`/`ExportRequest` 数据类已生成,字段齐备,无需改 pigeon,**不重新生成**。

## 导出(复用现成 GyroflowExporter)

安卓**已有** `GyroflowExporter`(解码→`nativeRenderFrameI420` 去畸变+稳定回读→MediaCodec
编码→MediaMuxer→相册/SAF 目录),旧全屏页在用。`startExport` 仅做编排:

1. `decoder?.pause()` 停预览喂帧 —— 预览(`nativeProcessFrame`)与导出(`nativeRenderFrameI420`)
   都动同一单例引擎,**不可并发**;对齐旧 `GyroflowActivity.startExport` 的 `decoder?.pause()`。
2. `ExportRequest` → `GyroflowExporter.Settings`(codecIndex/outW/outH/bitrate/audio/fileName/
   exportDirUri = req.outputUri 非空时)。outW/oh ≤0 时按源宽×16:9 兜底(对齐旧页)。
3. `GyroflowExporter(context, srcUri).run(settings, onProgress, onDone)`:
   - `onProgress(p)` → 主线程 `events.onExportProgress(p.percent, p.frame, p.total)`。
   - `onDone(uri, err)` → 主线程 `callback(Result.success(err==null ? "" : (cancelled?"已取消":err)))`。
     `GyroflowExporter` 取消时抛 `"已取消"`,据此归一。
   - exporter 内部 `run{}` 已 `nativeSetExportMode(true/false)` + `nativeSetExportTarget` 收尾。
4. 预览输出尺寸的恢复(导出把 output_size 改成全分辨率)由 **Dart 侧** `_restorePreviewAfterExport`
   负责(`setOutputSizeExact(预览尺寸)`+recompute+renderOnce),与 iOS 同;安卓 onDone 不再重复。

`events` 与 `EngineApiImpl` 共用同一实例(插件持有引用,见下),保证 Dart `exportProgress` 流收得到。

## 改动清单

**新增**
- `android/src/main/kotlin/com/runcam/runcam_gf/PreviewController.kt`
- `android/src/main/kotlin/com/runcam/runcam_gf/PreviewApiImpl.kt`

**改动(非删除)**
- `android/.../runcam_gf/RuncamGfPlugin.kt`:`onAttachedToEngine` 注册 `PreviewApi.setUp(...)`,
  传 `binding.textureRegistry` 与共享 `events`;`onDetachedFromEngine` 注销 + 释放控制器。
- `android/.../runcam/VideoDecoder.kt`:加 `@Volatile lastRenderedPtsUs` + `fun rerender()`
  (additive,旧全屏页不受影响)。
- `example/lib/preview_page.dart`:安卓上隐藏「切到 PlatformView」按钮(`defaultTargetPlatform`
  判定);Texture 为安卓唯一后端,避免误触发 iOS-only `UiKitView`。

**不动**:`GyroflowNative.kt`、Rust、`gyroflow_ffi.h`、`EngineApiImpl.kt`、iOS、pigeon、
`*.g.*`、`GyroflowExporter.kt`(原样复用)、旧 `open()`/`GyroflowActivity`。

## 真机增量(只能真机验收;原生盲写)

| # | 内容 | 验收点 |
|---|---|---|
| A. 纹理桥通路 | 注册 PreviewApi;createPreviewTexture 建 SurfaceProducer + `nativePreviewSurfaceCreated`,VideoDecoder 渲首帧暂停 | Texture 页打开视频出现**防抖后首帧**(非黑) |
| B. 播放控制 | play/pause/seek;暂停态改参数 renderOnce 实时反映 | 能播停、拖动 seek、改平滑度画面随动 |
| C. 生命周期 | 进出页/前后台(SurfaceProducer.Callback 重绑)/切视频/dispose 不崩不黑 | 反复进出 + 切后台回来画面正常 |
| D. 导出 | startExport→相册/所选目录;进度浮层;cancel | 导出文件可播 + 进度/取消正常 + 导出后预览恢复 |

## 风险

- **SurfaceProducer.Callback API 名**:Flutter 3.41 用 `onSurfaceAvailable()/onSurfaceCleanup()`
  (旧名 `onSurfaceCreated/onSurfaceDestroyed` 已弃用)。盲写按新名;真机若编译/行为不符,
  按引擎版本回退旧名(增量 C 验)。
- **并发引擎访问**:导出前必须 `decoder.pause()`;预览循环与导出都动单例,未停会崩(对齐旧页)。
- **首帧黑屏**:VideoDecoder 暂停态已渲首帧(`firstShown` 分支);若高码率 prepare 竞态黑屏,
  增量 A 用 `rerender()`/seek(0) 兜底(对齐 iOS primeFirstFrame 思路)。
- **盲写**:Kotlin/wgpu/SurfaceProducer 本机不可编译验证,逐增量真机回归;每增量独立可弃。
- **回退**:全程独立新增,旧 `open()` 与 iOS 不动;失败整体弃不影响既有成果。
```
