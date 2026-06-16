# 阶段1 设计:iOS 预览 Texture spike(go/no-go)

> 日期:2026-06-15
> 阶段:GF 功能 Flutter 化 — 阶段 1(预览 Texture,go/no-go 关口)
> 项目:`/Users/gdm/Desktop/RuncamGF`
> 依据:桌面 `GF功能Flutter化方案.md` 第 4/5/7 节(Texture 路线);`进度与续接.md`(阶段 0+2 已完成)

## 目标与判据

把原生 GPU 渲出的稳定预览画面,零拷贝塞进 Flutter `Texture(textureId)`,在 **iOS 先行**做一个**完整预览页**(解码+稳定+显示+播放控制),用来决策 Texture 终态是否可行。

**go/no-go 合格线(严格)**:用 4K@60 样片,预览能持住 4K@60、屏上 FPS 贴 60、单帧 < ~16ms,且 **Instruments 证明零拷贝**(无整帧 blit / CPU memcpy)。持不住或有整帧拷贝 → no-go,退回 PlatformView/三明治。

**总原则**:不动老 `open()` 全屏原生页(随时可回退);spike 是独立新增的最小渲染路径。本轮**只做 iOS**,Android 等 iOS 拿到 go 信号后另起。

## 方案选择

iOS 上把引擎 GPU 输出送进 Flutter 的零拷贝路径基本唯一:
**CVPixelBuffer(IOSurface 背书)+ CVMetalTextureCache + `FlutterTexture.copyPixelBuffer`**。
- 引擎渲到 IOSurface 背书的 CVPixelBuffer,Flutter 合成器直接采样该 IOSurface → 零拷贝。
- 备选 PlatformView(嵌 MTKView)是 spike 失败时的退路,不在本设计。
- "直接把 MTLTexture 交给 Flutter":iOS 无稳定公开 API,必须经 CVPixelBuffer/IOSurface。

## 架构与组件

```
Flutter 预览页(example,新增 dev 路由)
  Texture(textureId) + 播放控制(play/pause/seek) + 屏上 FPS/帧耗时
        │  Pigeon PreviewApi(实现 S1 预留的占位契约)
        ▼
iOS PreviewController(插件内新增,不动老 ViewController)
  ├─ MDK Player        : renderVideo() 解码当前帧 → mdkInputTexture(视频原生尺寸)
  ├─ 共享 stabilizer    : 复用 EngineApiImpl 的句柄(ParamsModel 改参数→预览实时反映)
  ├─ process_frame_metal_bgra8(input=mdkInputTexture, output=CVPB 纹理, command_queue)
  ├─ CVPixelBuffer 池   : 3 张 IOSurface 背书、BGRA、Metal-compatible
  ├─ CVMetalTextureCache: 把 CVPixelBuffer 当 MTLTexture 渲染目标
  ├─ FlutterTexture     : copyPixelBuffer 返回最新一张 CVPixelBuffer
  └─ CADisplayLink(60Hz): 驱动循环 + textureFrameAvailable 通知 Flutter
```

**要点:**
- **零拷贝靠 IOSurface**:CVPixelBuffer 用 `kCVPixelBufferIOSurfacePropertiesKey` + `kCVPixelBufferMetalCompatibilityKey`;`copyPixelBuffer` 把它 retain 后交给 Flutter,合成器直接采样 IOSurface,无整帧 blit。
- **共享 stabilizer**:预览与 ParamsModel/smoke 用同一引擎句柄(终态架构)。
- **不动老 `open()`**:PreviewController 自起 MDK + 自己的 CVPB 输出,独立最小路径;老全屏页原样可回退。
- **纹理注册**:用插件 registrar 的 `textures()` 注册,拿 textureId(与 example 用 implicit engine 无关)。

## PreviewApi 契约(扩展 S1 占位)

S1 已在 `pigeons/runcam_gf_api.dart` 占位:`int createPreviewTexture()`、`disposePreviewTexture(int)`、`play()`、`pause()`、`seekTo(int)`、`setExportMode(bool)`(阶段4 用)。本轮按需**扩展并重新生成**:

- `PreviewInfo createPreviewTexture(String uriOrPath)`:给现有占位**加 uri 参数**、返回值由 `int` 改为新数据类 `PreviewInfo{int textureId, int width, int height}`(预览页要 AspectRatio 与纹理 id)。建 MDK + CVPB 池 + 注册纹理。
- `disposePreviewTexture(int textureId)`:停 DisplayLink、注销纹理、释放 MDK/CVPB 池/texture cache(沿用占位签名)。
- `play()` / `pause()`:启停 CADisplayLink 驱动(沿用)。
- `seekTo(int timestampUs)`:MDK seek(沿用)。
- `setExportMode(bool)`:本轮**不实现**(阶段4),保留占位。

改契约后须 `dart run pigeon --input pigeons/runcam_gf_api.dart` 重新生成三端绑定。引擎参数仍走既有 `EngineApi`/`ParamsModel`(与本契约共享同一 stabilizer)。

## 增量(逐个真机验收,因原生 GPU 代码只能盲写)

| # | 内容 | 真机验收点 |
|---|---|---|
| A. 纹理桥通路 | 注册 FlutterTexture;`copyPixelBuffer` 返回填死纯色/测试图案的 CVPixelBuffer;Flutter `Texture` 显示 | 屏幕出现纯色/图案 → 外部纹理链路通 |
| B. 60Hz 驱动 + FPS | CADisplayLink 每帧改图案(滚动条);屏上显示实测 FPS/帧耗时 | 稳定 60fps、画面动 → 合成节奏 OK |
| C. 接真解码+稳定 | MDK 解码 → mdkInputTexture → `process_frame_metal_bgra8` → CVPB 纹理;play/pause | 出现真实防抖后视频、能播停 |
| D. seek+生命周期+4K@60+零拷贝 | seekTo;进出/前后台/dispose 不崩;4K@60 样片量 FPS;Instruments 抓 GPU 帧确认无整帧 blit | 4K@60 持住 + Instruments 证零拷贝 → **go** |

A/B 把"纹理路径本身"和"真实解码稳定"解耦,go/no-go 风险(性能)最早暴露在 A/B/D,不必等 MDK 全接完。

## 缓冲与同步(零拷贝命门)

- **CVPixelBuffer 池**:3 张,IOSurface 背书 + Metal-compatible + BGRA,尺寸 = 视频 output_size。
- **写读轮转**:引擎渲到 `buffers[next]`;command buffer `addCompletedHandler` 里在锁内 `latest = buffers[next]`、`next = (next+1)%3`,调 `textureFrameAvailable`。
- **`copyPixelBuffer`**(Flutter 光栅线程):锁内 `CVPixelBufferRetain(latest)` 返回。3 张保证 Flutter 正读那张不被覆写。
- **完成时机**:用 command buffer completed handler 才标 frame available,避免撕裂。

## 4K@60 零拷贝验收(D)

1. **屏上 FPS/帧耗时**:4K@60 样片下 FPS 贴 60、单帧 < ~16ms。
2. **零拷贝证明**:Xcode Instruments(Metal System Trace / GPU 抓帧)确认无整帧 `blit`/`MTLBlitCommandEncoder` copy、无 CPU memcpy;`copyPixelBuffer` 仅传 IOSurface 句柄。(实施计划给 Instruments 具体步骤。)
3. **对照**:同片子与老 `open()` 页目测流畅度相当(无明显多帧延迟/掉帧)。

不达标 → no-go,按总方案退 PlatformView/三明治;达标 → Texture 终态可行,进阶段 3。

## 产物

**新增/改动**:
- `pigeons/runcam_gf_api.dart`:扩展 `PreviewApi`(createPreviewTexture 加 uri 参、返回 `PreviewInfo`)→ 重新生成 `*.g.*`。
- iOS:`ios/Classes/PreviewController.swift`(+ 在 `RuncamGfPlugin.swift` 注册 PreviewApi)。
- example:预览 dev 页(`Texture` + 控制 + FPS 显示)。

**改动(非删除)**:`RuncamGfPlugin.swift`(注册 PreviewApi)、example 路由入口加预览页。

**不动**:老 `ViewController.mm` / `open()` / 安卓侧 / 已完成的 S7 状态层。

## 风险与回滚

- **最大风险=性能**:4K@60 经 Flutter 合成多一道,可能掉帧/多延迟;增量 A/B/D 提前量化,no-go 即退 PlatformView/三明治。
- **盲写原生**:Metal/CVPixelBuffer/FlutterTexture 代码无法在本机编译验证,靠真机逐增量回归;每增量独立可弃。
- **生命周期崩**:页面进出/前后台/改预览分辨率时纹理与 CVPB 池注册/销毁/重建,D 专门验。
- **回退**:全程独立新增,老 `open()` 不动;spike 失败整体弃,不影响阶段 0+2 成果。

## 明确不在本轮范围(YAGNI)

Android 预览;导出;autosync;把老页迁成 Flutter(阶段 3);S5/S6 完整解耦(spike 只取所需最小解码/渲染,不重构老页)。
