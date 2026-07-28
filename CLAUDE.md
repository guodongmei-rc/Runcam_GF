k i# CLAUDE.md

本文件为 Claude Code(claude.ai/code)在本仓库工作时提供指引。

## 这是什么

`runcam_gf` 是一个把 Gyroflow 视频防抖引擎封装给 iOS 与 Android 的 Flutter **插件**。仓库正处于迁移中期(见 `docs/flutter-ui-migration.md`):目标是把编辑器 UI + 参数状态从两套原生代码(iOS Obj-C/Swift、Android Kotlin)迁到**一层共享的 Dart**,原生只保留它必须做的四件事——视频解码、GPU 预览渲染、导出编码、文件选择/权限。Rust core、`ios/Libs/gyroflow_ffi.h`、`android/.../GyroflowNative.kt` **不得修改**——只在它们外面写薄薄的转发壳。

绝大多数代码注释与文档为中文;编辑既有文件时保持一致。

## 命令

设备构建一律在 `example/` 下跑;插件自身的测试在仓库根目录跑。

```bash
# 插件单元测试(纯 Dart,无需设备)
flutter test                              # 仓库根目录 — 跑 test/params_model_test.dart
flutter test test/params_model_test.dart --plain-name "smoothness"   # 按名字跑单条测试

# 示例 App 单元/Widget 测试
cd example && flutter test                # 跑 example/test/stabilize_panel_test.dart

# 运行示例 App(仅限真机 — 见下)
cd example && flutter run                 # 选一台已连接的 iOS/Android 设备

# 静态分析(flutter_lints,见 analysis_options.yaml)
flutter analyze

# 改完 pigeons/runcam_gf_api.dart 后重新生成 Pigeon 桥
dart run pigeon --input pigeons/runcam_gf_api.dart
```

**仅限真机:** 原生引擎以 arm64 静态库(iOS)/ `.so`(Android)发布,无模拟器切片。iOS 模拟器会抛 `SIMULATOR_UNSUPPORTED`。任何引擎/预览/导出相关的改动都必须在真机上验证;只有 Dart 的 `ParamsModel`/Widget 测试能在宿主机跑。

## 架构

自顶向下三层:

1. **Dart UI + 状态**(共享,迁移目标)。示例编辑器在 `example/lib/edit/`:`EditController`(一个 `ChangeNotifier`)持有引擎生命周期、`ParamsModel` 与当前预览后端;`edit/panels/` 下的面板只读写 `ParamsModel`,绝不直接碰 channel。

2. **Pigeon 桥** —— 唯一事实源是 `pigeons/runcam_gf_api.dart`。它生成 `lib/src/bridge/engine_api.g.dart`(Dart)、`ios/Classes/EngineApi.g.swift`、`android/.../EngineApi.g.kt`。**绝不手改 `.g.*` 文件。** 三个接口:
   - `EngineApi`(HostApi,Dart→原生):离散的参数 setter/getter、`recomputeBlocking`、镜头、时间线。
   - `PreviewApi`(HostApi):创建/销毁预览纹理、play/pause/seek/renderOnce、`startExport`/`cancelExport`。
   - `EngineEvents`(FlutterApi,原生→Dart):recompute 完成、autosync/导出进度、播放推进。
   高频的逐帧 `process`/autosync 喂帧**不走**桥——留在原生内部。

3. **原生薄壳**把 Pigeon 调用转发到既有引擎:
   - iOS `EngineApiImpl.swift` / `PreviewApiImpl.swift`(+ `PreviewController.mm`)→ `gyroflow_*` C FFI(`ios/Libs/gyroflow_ffi.h`);MDK 解码 + Metal 渲染 + AVAssetWriter 导出。
   - Android `EngineApiImpl.kt` / `PreviewApiImpl.kt`(+ `PreviewController.kt`)→ `GyroflowNative.kt` JNI;MediaCodec 解码(`VideoDecoder.kt`)+ wgpu 渲染 + MediaCodec 导出(`GyroflowExporter.kt`,被新的预览壳原样复用)。
   旧的原生全屏编辑器(`GyroflowActivity`、`GyroflowLauncher`、`RuncamGF.open()` 与 `com.runcam/gyroflow` channel)已在本分支**整体移除**(commit 3b3c53e);编辑器唯一入口是 Dart 的 `PreviewPage`。Android 引擎是 **`.so` 单例**(无 per-stabilizer 句柄),所以预览壳通过调同样的 `GyroflowNative.*` 自动与 `EngineApiImpl` 共享状态;iOS 则是把 `stabilizerHandle` 闭包传进 `PreviewApiImpl`。

### ParamsModel —— Dart 状态层的核心

`lib/src/state/params_model.dart`(+ `part` 文件 `params_model_{stabilize,zoom,advanced}.dart`)誊写自原生 `ios/Sources/ParamsModel.m`(该文件已随原生 UI 移除;历史版本:`git show 3b3c53e^:ios/Sources/ParamsModel.m`)。**Dart 侧现在就是事实源**。每个参数 setter 都遵循同一契约:

**clamp → 立即 push 给引擎 → 启动一个共享的 200ms 防抖 → `recomputeBlocking` → 写回只读输出(`maxAngle{Pitch,Yaw,Roll}`、`minFov`)→ `notifyListeners`。**

已固化的关键约定(不核对 `.m` 别去“修”它们):
- `defaults.dart` 与 `clamp.dart` 是从已删除的 `ParamsModel.m` 誊写的,当年 `.h` 注释与 `.m` 不一致处均已按 `.m` 固化并就地标注;现在 Dart 里的值即事实源,别按猜测去"修"它们,历史对照走 git(见上)。
- 部分参数需经专用方法做多字段原子 push:`pushHorizonLock`(9 个参数;锁关闭时 amount 强制为 0)、`pushVideoSpeed`、`pushBackgroundColor`、`pushAdaptiveZoom`(croppingMode→adaptive_zoom 映射 0→0.0 / 1→sec / 2→-1.0)。
- `pushAllDefaultsAndRecompute()` 由控制器在 `createStabilizer` 后调用一次,push 每个 FFI 支撑的值后直接重算(绕过防抖)。
- `ParamsModel` 只依赖抽象接口 `EngineBridge`(`lib/src/state/engine_bridge.dart`),故测试可注入 `FakeEngineBridge`。真实的 `EngineBridgeImpl` 1:1 转发到生成的 `EngineApi`。

### 打开视频时的生命周期(`EditController.openAndStart`)

`pickVideo`(原生选择器 channel)→ `createStabilizer` → `openVideo` → `setStabEnabled(true)`(防抖开关**不是**面板参数;控制器必须显式开启,对齐已移除的原生 `ViewController`)→ `_autoMatchLensIfNeeded`(视频自带镜头档案缺失时,按检测到的相机 + 视频 WxH 匹配内置镜头档案)→ `setOutputSizeExact` 把预览降采样到 ≤1080p → `pushAllDefaultsAndRecompute` → 拉取录制参数/镜头/陀螺元数据 + 时间线 → 启动预览后端 → 按条件跑 autosync。控制器**不 push `gyro_offset`**(对齐原生 ParamsModel 的行为:从不写 stabilizer 的偏移);raw-IMU + 有镜头档案的视频由 autosync 求得逐点偏移,在 `autosync_finish` 内部应用。

### 预览后端

`texture`(Flutter `Texture(textureId)`,迁移终态)在**两端**都已实现;`platformView`(经 `UiKitView` 内嵌原生 `MTKView`)是 **iOS 专属**的 go/no-go 对照后端——Android 上隐藏该切换按钮,Texture 是唯一后端。切换后端会重新解码,但参数状态不变。

两端走到零拷贝 Texture 的方式不同:iOS 的纹理 API 是**拉取式**(`FlutterTexture.copyPixelBuffer`),所以 `PreviewController.mm` 维护一个 3 张、IOSurface 背书的 `CVPixelBuffer` 池。Android 的 `TextureRegistry.SurfaceProducer` 是**推送式**——`nativePreviewSurfaceCreated(surface,…)` 让 wgpu 把稳定输出直接渲进该 producer 的 `Surface`,故无缓冲池、无新 GPU 代码(只是 `PreviewController.kt` 里的 Kotlin 胶水)。

## 迁移状态与参考

`docs/flutter-ui-migration.md` 是总规划(步骤 0/1/3/4;步骤 2 —— 一个 `dart:ffi` 统一引擎 —— 有意跳过)。各切片的设计 + 计划文档在 `docs/superpowers/{specs,plans}/`。实现某切片前先读它的设计文档;里面列出了被移植的确切原生文件,以及对照 `ParamsModel.h`(已删,历史见 git)/`GyroflowNative.kt` 的逐字段核对表。原生 UI 及其源文件已整体移除,文档中「仍在/保留」的描述以当前代码树为准。
