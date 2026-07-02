# RuncamGF — iOS/Android 共用一套 Flutter UI 迁移步骤文档

> 范围:执行 **步骤 1 / 3 / 4**,**跳过步骤 2**(不做 `dart:ffi` 统一引擎桥)。
> 因此引擎调用统一走一条 **Pigeon channel**(轻量桥,方案 B),由各端转发到**现有**的
> iOS C FFI(`gyroflow_ffi.h` 里的 `gyroflow_*`)/ Android JNI(`GyroflowNative` 的 `nativeXxx`)。
> **不改动** Rust 核心、`gyroflow_ffi.h`、`GyroflowNative` 的语义,只在其外面包一层薄壳。

## 目标态

```
Flutter (Dart, iOS/Android 共享一套)
├─ UI:    panels / tabs / sliders / theme / timeline / orientation / HUD   ← 步骤1
├─ State: ParamsModel(默认值 / clamp / 200ms 防抖 → recompute)+ 流程编排    ← 步骤1
├─ Bridge: Pigeon EngineApi(参数/查询) + Pigeon PreviewApi(解码/播放/导出)  ← 步骤1/3/4 前置
└─ Preview: Texture(textureId) + 叠加 Flutter HUD/控件                       ← 步骤3
        │ (外接纹理)
        ▼
原生(各端薄壳,只剩四件事)
  iOS:     MDK 解码 + Metal 渲染(process_frame_metal_bgra8)+ AVAssetWriter 导出 + DocumentPicker/书签
  Android: MediaCodec 解码 + wgpu→SurfaceTexture 渲染(nativeProcessFrame)+ MediaCodec 导出 + SAF
```

迁移后**原生只保留**:视频解码、预览 GPU 渲染、导出编码、文件选择/权限。其余全部 Dart。

---

## 步骤 0(前置)— 引擎桥 channel

> 步骤 1 的 Dart 参数模型必须能调引擎,所以先定义桥。既然跳过 `dart:ffi` 统一,
> 这里用 **Pigeon** 生成类型安全的 channel,两端各写一遍 forwarding(薄)。

### 0.1 引入 Pigeon

`pubspec.yaml` 加 dev 依赖:

```yaml
dev_dependencies:
  pigeon: ^22.0.0
```

新建 `pigeons/runcam_gf_api.dart`,定义两组接口:

- **`EngineApi`** — 离散的参数 setter/getter、recompute、timeline、autosync、lens(对照 `gyroflow_ffi.h` / `GyroflowNative`)。
- **`PreviewApi`** — 解码/播放/seek/导出控制(步骤 3/4 用)。
- **`EngineEvents`**(FlutterApi,native→Dart)— recompute 完成、autosync 进度、导出进度回调。

```dart
// pigeons/runcam_gf_api.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/src/bridge/engine_api.g.dart',
  swiftOut: 'ios/Classes/EngineApi.g.swift',
  kotlinOut: 'android/src/main/kotlin/com/runcam/runcam_gf/EngineApi.g.kt',
  kotlinOptions: KotlinOptions(package: 'com.runcam.runcam_gf'),
))

class VideoInfo {
  int? width; int? height; int? outputWidth; int? outputHeight;
  double? fps; double? durationS; int? frameCount;
}

class StabInfo { // recompute 后的只读输出
  double? maxAnglePitch; double? maxAngleYaw; double? maxAngleRoll; double? minFov;
}

@HostApi()
abstract class EngineApi {
  // —— 生命周期 ——
  void createStabilizer();
  void freeStabilizer();
  VideoInfo openVideo(String uriOrPath);     // iOS: load_video_file / Android: nativeOpenVideo

  // —— 稳定 ——
  void setStabEnabled(bool enabled);
  void setSmoothingMethod(int index);
  void setSmoothingParam(String name, double value);   // "smoothness"/"smoothness_pitch"/...
  void setHorizonLock(double lockPercent, double rollDeg, bool lockPitch, double pitchDeg,
                      bool automaticLock, double turnThreshold, double turnSmoothingMs,
                      double turnMultiplier, double tiltAccelLimit);
  // —— 缩放 ——
  void setAdaptiveZoom(double windowSeconds);
  void setMaxZoom(double percent, int iterations);
  void setZoomingMethod(int index);
  void setLensCorrection(double amount);
  void setFov(double fov);
  // —— 卷帘/速度/旋转/背景/安全区/预览分辨率/输出尺寸 ——
  void setFrameReadoutTime(double ms);
  void setFrameReadoutDirection(int dir);
  void setVideoSpeed(double speed, bool affSmooth, bool affZoom, bool affZoomLimit);
  void setAdditionalRotation(double pitch, double yaw, double roll);
  void setBackgroundColor(double r, double g, double b, double a);
  void setBackgroundMode(int mode);
  void setShowSafeArea(bool show);
  void setShowDetectedFeatures(bool show);
  void setShowOpticalFlow(bool show);
  void setPreviewResolution(int targetHeight);
  void setOutputSize(int w, int h);
  void setOutputSizeExact(int w, int h);
  // —— IMU / 运动数据 ——
  void setGyroOffset(double offsetMs);
  void setImuLpf(double hz);
  void setImuOrientation(String orientation);
  void setIntegrationMethod(int index);
  void setFrameOffset(int frames);
  // —— 镜头 ——
  String lensSearch(String query);          // 返回 JSON [{name,id}]
  String loadLens(String uriOrIdOrJson);
  String getLensInfoFull();                  // JSON
  String loadGyro(String uriOrPath, bool loadAllMetadata);
  void folderAccessGranted(String folderUrl);
  // —— 查询 ——
  StabInfo recomputeBlocking();              // 阻塞重算 + 返回 max angles / min fov
  String getVideoMetadata();                 // JSON
  List<double> gyroTimeline(int count);      // 交错 xyz(°/s);空=无
  List<double> quaternionTimeline(int count);// 交错 xyzw;空=无
  List<double> quatsAtTimestamp(int timestampUs); // double[8]
  double getFovAtTimestamp(int timestampUs);
}

@HostApi()
abstract class PreviewApi { /* 见步骤 3/4 */ }

@FlutterApi()
abstract class EngineEvents {
  void onRecomputeFinished(StabInfo info);
  void onAutosyncProgress(double progress, int ready, int total);
  void onAutosyncFinished(double medianOffsetMs, List<double> syncPoints, bool ok);
  void onExportProgress(double progress, int frame, int total);
  void onPlaybackTick(int timestampUs, double fov); // 步骤3 HUD 用
}
```

生成代码:

```bash
dart run pigeon --input pigeons/runcam_gf_api.dart
```

### 0.2 各端实现(薄 forwarding)

- **iOS**(`ios/Classes/EngineApiImpl.swift`):实现 `EngineApi`,每个方法转发到 `gyroflow_ffi.h` 对应的 `gyroflow_*`。句柄 `GyroflowStabilizer*` 持有在该类。`recomputeBlocking` 放后台串行队列,完回主线程 + 回调 `EngineEvents.onRecomputeFinished`。这部分逻辑就是把现有 `ParamsModel.m` setter 里"调 FFI"那一半搬过来。
- **Android**(`android/.../EngineApiImpl.kt`):实现 `EngineApi`,转发到 `GyroflowNative.nativeXxx`。`recomputeBlocking` 现在隐含在各 setter 后,这里改成显式调一次(Android 现有 `nativeGetStabInfo()` 取 max angles)。

> 注意命名对齐:iOS 的 FFI 是 `gyroflow_set_smoothing_param(handle,name,value)`,Android 是
> `nativeSetSmoothingParam(name,value)`;Pigeon 把它们统一成 `setSmoothingParam(name,value)`。
> autosync 的 finish:iOS 返回 `out_offset_ms`+points,Android 返回 JSON `{median,points}`,
> 在各端 impl 里归一成 `EngineEvents.onAutosyncFinished`。

### 0.3 验收
- Dart 调 `EngineApi.createStabilizer()` → `openVideo()` → `setSmoothingParam("smoothness",0.5)` → `recomputeBlocking()` 能拿到非零 `minFov`,两端一致。

---

## 步骤 1 — 抽离 UI + ParamsModel + 主题 + 时间轴(纯 Dart)

> 收益最大、风险最低:不碰原生引擎与预览,只把两套重复 UI 收敛成一套 Dart。
> 规格直接用 `ios/Sources/ParamsModel.h`(里面每个参数的默认值/clamp/FFI-key 都有注释)。

### 1.1 目录结构

```
lib/
├─ runcam_gf.dart                 # 对外 API(保留 open(),新增 openEditor())
└─ src/
   ├─ bridge/
   │  ├─ engine_api.g.dart        # Pigeon 生成
   │  └─ engine_events.dart       # FlutterApi 实现,转 Stream 给 state
   ├─ state/
   │  ├─ params_model.dart        # ← 对应 ParamsModel.h(核心)
   │  ├─ defaults.dart            # 默认值表
   │  └─ clamp.dart               # 各参数 clamp 区间
   ├─ theme/
   │  └─ gf_theme.dart            # ← GFTheme / GyroflowTheme.kt
   ├─ widgets/                    # 复用控件 ← GFViewKit / GyroflowViews
   │  ├─ gf_slider.dart           # label + 滑块 + 数值 + 单位
   │  ├─ gf_switch_row.dart
   │  ├─ gf_segmented_tabs.dart   # ← GFSegmentedTabs
   │  └─ gf_section.dart          # 折叠分组(普通/高级)
   ├─ panels/                     # tab 页 ← iOS Views/* + Android *Panel.kt
   │  ├─ input_tab.dart           # ← InputTabView
   │  ├─ stabilize_tab.dart       # ← StabilizeSectionView + StabilizeAdvancedView + HorizonLockGroupView
   │  ├─ sync_tab.dart            # ← SyncSectionView + SyncAdvancedView
   │  ├─ zoom_tab.dart            # ← ZoomSectionView + ZoomGroupView
   │  ├─ advanced_tab.dart        # ← AdvancedSectionView(背景/安全区/预览分辨率)
   │  └─ export_tab.dart          # ← ExportSectionView
   ├─ charts/
   │  ├─ gyro_timeline.dart       # ← GyroTimelineView/Model(CustomPaint)
   │  └─ orientation_indicator.dart # ← OrientationIndicatorView(CustomPaint)
   └─ editor_page.dart            # 整页:预览区(步骤3)+ 底部 Tab + HUD
```

### 1.2 ParamsModel → Dart 状态层(核心)

把 `ParamsModel.h` 的全部参数搬成一个 `ChangeNotifier`(或 Riverpod/Bloc)。**机制照搬现状**:
每个 setter = ①clamp → ②立即推 FFI(经 `EngineApi`)→ ③启动 200ms 防抖 timer → ④触发
`recomputeBlocking`,完成后 `EngineEvents.onRecomputeFinished` 回填只读输出。

```dart
// lib/src/state/params_model.dart  (节选,完整字段照 ParamsModel.h 抄)
class ParamsModel extends ChangeNotifier {
  final EngineApi _engine;
  Timer? _debounce;
  ParamsModel(this._engine);

  // ---- 稳定 ----
  int _smoothingMethod = 1;          // 默认 1
  double _smoothness = 0.5;          // 0.001..1.0
  bool _horizonLock = false;
  double _horizonLockAmount = 100;   // 0..100,horizonLock=false 时强制 0
  // ... (per-axis / plain3d / fixed / advanced #1 ... 全部照 .h)

  // 只读输出(recompute 后回填)
  double maxAnglePitch = 0, maxAngleYaw = 0, maxAngleRoll = 0, minFov = 0;

  set smoothness(double v) {
    v = v.clamp(0.001, 1.0);
    if (v == _smoothness) return;
    _smoothness = v;
    _engine.setSmoothingParam('smoothness', v); // 立即推
    _scheduleRecompute();                        // 200ms 防抖
    notifyListeners();
  }

  void _scheduleRecompute() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () async {
      final info = await _engine.recomputeBlocking();
      maxAnglePitch = info.maxAnglePitch ?? 0;
      maxAngleYaw   = info.maxAngleYaw ?? 0;
      maxAngleRoll  = info.maxAngleRoll ?? 0;
      minFov        = info.minFov ?? 0;          // UI 显示 zoom% = 100/minFov
      notifyListeners();
    });
  }

  /// Controller 在 stabilizer 建好后调一次:重置默认 + 全量推 FFI + 一次 recompute。
  Future<void> loadDefaults() async { /* 把 defaults.dart 全量推一遍 + recompute */ }
}
```

**搬运清单(逐组对照 `ParamsModel.h`):**
- 同步组(14 项):`autosyncEnabled / gyroOffsetMs / syncSearchSizeSec / maxSyncPoints / everyNthFrame / timePerSyncpointSec / syncProcessingHeight / ofMethod / poseMethod / offsetMethod / imuLpfHz / showDetectedFeatures / showOpticalFlow` + 3 个官方开关。
- 稳定组:`smoothingMethod / smoothness / perAxis / smoothness{Pitch,Yaw,Roll} / horizonLock* (9 参) / plain3dTimeConstant / fixed{Pitch,Yaw,Roll} / trimRangeOnly / maxSmoothnessSec / alphaHighVelSec`。
- 缩放组:`maxZoomPercent / maxZoomIterations / adaptiveZoomSec / lensCorrection / fov / croppingMode / zoomingMethod / rsCorrection / frameReadout{Ms,Direction} / add{Pitch,Yaw,Roll} / videoSpeed + 3 联动`。
- 高级组:`outputSize / bg{R,G,B,A} / backgroundMode / showSafeArea / previewResolutionHeight`。
- 导出组(不接 FFI,仅导出时读):`exportCodecIndex / exportBitrateMbps / useGpuEncoding / exportAudio`。
- 只读输出:`maxAngle{Pitch,Yaw,Roll} / minFov`。

> `defaults.dart` / `clamp.dart` 直接抄 `.h` 注释里的"默认 X""UI clamp A–B"。
> `croppingMode`→`adaptive_zoom` 的映射逻辑(0→0.0 / 1→adaptiveZoomSec / 2→-1.0)放在 model 里,
> 不暴露给 UI。

### 1.3 主题
`gf_theme.dart`:把 `GFTheme.m` / `GyroflowTheme.kt` 的颜色、间距、圆角整理成 `ThemeData` +
一组常量;`res/drawable/ic_gf_*.xml` 转成 Flutter assets(SVG 用 `flutter_svg`,或导出 PNG)。

### 1.4 Widget 拆分(tab ↔ 原生文件对照)

| Dart 文件 | iOS 来源 | Android 来源 |
|---|---|---|
| `panels/input_tab.dart` | `InputTabView` | `GyroflowActivity` 输入页 + `GyroflowMotionPanel` |
| `panels/stabilize_tab.dart` | `StabilizeSectionView` + `StabilizeAdvancedView` + `HorizonLockGroupView` | `GyroflowStabilizePanel` |
| `panels/sync_tab.dart` | `SyncSectionView` + `SyncAdvancedView` | `GyroflowSyncPanel` |
| `panels/zoom_tab.dart` | `ZoomSectionView` + `ZoomGroupView` | (Stabilize/Advanced 内) |
| `panels/advanced_tab.dart` | `AdvancedSectionView` | `GyroflowAdvancedPanel` |
| `panels/export_tab.dart` | `ExportSectionView` | `GyroflowExportPanel` |
| `widgets/gf_segmented_tabs.dart` | `GFSegmentedTabs` | (Activity 内 tab) |
| `widgets/gf_slider.dart` 等 | `GFViewKit` | `GyroflowViews` |
| `charts/gyro_timeline.dart` | `GyroTimelineView/Model` | `GyroTimelineView.kt` |
| `charts/orientation_indicator.dart` | (ViewController 内) | `OrientationIndicatorView.kt` |

每个 panel 只读写 `ParamsModel`,不直接碰 channel。

### 1.5 时间轴 / 方向指示器
- `gyro_timeline.dart`:`EngineApi.gyroTimeline(N)` 拿 `[x0,y0,z0,...]`;返回空时退回
  `quaternionTimeline(N)`(对齐 `gyroflow_get_quaternion_timeline`,DJI/Xtra 无原始角速度)。`CustomPaint` 画三轴曲线 + 播放头。
- `orientation_indicator.dart`:`quatsAtTimestamp(ts)` 拿 `double[8]`(原始+平滑姿态),`CustomPaint` 画指示器。

### 1.6 验收
- 用一段已知视频:Dart UI 改 smoothness/horizonLock/zoom,`minFov`、max angles label 实时刷新;
  时间轴/方向指示器随播放头更新;两端表现一致。
- 此时**预览仍是原生**(还没做步骤 3),可先用 PlatformView 临时嵌现有 MTKView/SurfaceView 验证参数链路。

---

## 步骤 3 — 预览改外接 Texture

> 把"原生产出的预览帧"喂给 Flutter 的外接纹理,Flutter 用 `Texture(textureId)` 合成,
> HUD/时间轴/控件用 Flutter 叠在上面。

### 3.1 PreviewApi(Pigeon 补全)

```dart
@HostApi()
abstract class PreviewApi {
  int createPreviewTexture();          // 返回 textureId
  void disposePreviewTexture(int id);
  void play();
  void pause();
  void seekTo(int timestampUs);
  void setExportMode(bool on);         // 导出时只渲不上屏(对齐 nativeSetExportMode)
}
```

### 3.2 Android:SurfaceView → SurfaceTexture(TextureRegistry)
- 现状:`nativePreviewSurfaceCreated(Surface, w, h)` 把 wgpu 渲到 `SurfaceView` 的 `Surface`。
- 改:从 Flutter `TextureRegistry.createSurfaceProducer()`(或 `SurfaceTextureEntry`)拿到一个
  `Surface`,把它传给 **同一个** `nativePreviewSurfaceCreated`。wgpu 渲染目标从 SurfaceView 的
  Surface 换成这个 Surface,**渲染代码不动**。
- `createPreviewTexture()` 返回 `entry.id()`。解码 `VideoDecoder` → `nativeProcessFrame` 链路不变。

### 3.3 iOS:MTKView → FlutterTexture(CVPixelBuffer)
- 现状:`process_frame_metal_bgra8` 的 output_texture = MTKView 的 `currentDrawable.texture`。
- 改:实现 `FlutterTexture`(`copyPixelBuffer` 返回 `CVPixelBuffer`)。预览渲染目标改成一个
  `CVPixelBuffer` 后端的 `MTLTexture`(用 `CVMetalTextureCache` 包一层),作为 `output_texture`
  传给 `process_frame_metal_bgra8`;渲完 `registry.textureFrameAvailable(textureId)`。
- `createPreviewTexture()` 调 `registrar.textures.register(...)` 返回 id。MDK 解码链路不变。

### 3.4 Dart 合成

```dart
// editor_page.dart
Stack(children: [
  if (_textureId != null) Texture(textureId: _textureId!),  // 预览
  PreviewHud(...),            // ← PreviewHUDView:时间码/帧/zoom%
  Align(alignment: Alignment.bottomCenter, child: PlaybackControlRow(...)), // ← PlaybackControlRowView
  if (_syncing) SyncProgressOverlay(...),  // ← SyncProgressOverlayView
]);
```

HUD 数据来自 `EngineEvents.onPlaybackTick(ts, fov)`(zoom% = 100/fov,对齐 `get_fov_at_timestamp`)。

### 3.5 验收
- 预览在 Flutter `Texture` 里正常播放/暂停/seek;Flutter HUD/控件叠加正确;
- 改参数后预览实时变化;iOS 真机 + Android 真机都跑通(注意 iOS 模拟器仍不支持)。

---

## 步骤 4 — autosync / export 搬到 Dart

> 编排(参数、进度 UI、状态机)进 Dart;真正"喂帧/编码"留原生(要解码)。

### 4.1 Autosync
流程对照 `gyroflow_autosync_*`(iOS)/ `nativeAutosync*`(Android):

1. Dart `SyncTab` 收集参数(`maxSyncPoints / searchSizeSec / ofMethod / ...`,全在 `ParamsModel` 同步组)。
2. Dart 调 `PreviewApi.autosyncStart(params)` → 原生 `autosync_start`,拿到待解码时间范围。
3. **原生**按范围解码灰度帧 → `autosync_feed_frame`(iOS `AutosyncRunner` / Android Activity 解码循环,**保留**)。
4. 原生周期性回调 `EngineEvents.onAutosyncProgress(progress, ready, total)` → Dart 进度条
   (`SyncProgressOverlay`)。
5. 原生 `autosync_finish` 应用 offsets + recompute → 回调 `onAutosyncFinished(median, points, ok)`
   → Dart 收尾、刷新时间轴上的同步点。
6. 取消:Dart `autosyncCancel()` → 原生 `autosync_cancel`。

PreviewApi 增补:`autosyncStart / autosyncCancel`。喂帧不过 channel(高频),纯原生内部。

### 4.2 Export
两端现状不同,统一编排、各自编码:

- Dart `ExportTab` 用 `ParamsModel` 导出组(`exportCodecIndex / exportBitrateMbps / useGpuEncoding / exportAudio`)+ 选输出目录(文件选择走原生,见下)。
- Dart 调 `PreviewApi.startExport(outputDir, filename, codec, bitrate, useGpu, audio)`。
- **原生**执行:
  - iOS:`setExportMode(true)` → 逐帧 MDK 解码 → `process_frame` → AVAssetWriter/VideoToolbox 编码(保留 `GFExportUtils`)。
  - Android:`nativeSetExportMode(true)` → MediaCodec 解码 → `nativeRenderFrameI420` 回读 → MediaCodec 编码(保留 `GyroflowExporter`)。
- 原生回调 `EngineEvents.onExportProgress(progress, frame, total)` → Dart 进度。
- 完成/失败回调收尾,`setExportMode(false)` 恢复预览。

> 可选简化:若想两端都用 FFI 的 `gyroflow_render_to_file`(内部 FFmpeg 一把梭,带 `progress_cb`),
> 导出就不依赖 AVAssetWriter/MediaCodec,Dart 只调一个方法 + 收进度。**但** 该路径用 FFmpeg 而非
> 系统硬件编码器,画质/性能/体积需先实测对比再决定是否替换现有路径。本步骤默认**保留各端原生编码**。

### 4.3 文件选择 / 权限(保留原生,Dart 触发)
- 选视频/镜头/陀螺/导出目录:用 `file_picker` 插件或自写 PlatformChannel。
- iOS:`UIDocumentPicker` + security-scoped bookmark(书签持久化已并入插件 `VideoPickerChannel`,
  `GFBookmarkStore` 已随原生 UI 移除),拿到 URL 后调 `EngineApi.folderAccessGranted(url)`。
- Android:SAF(`ACTION_OPEN_DOCUMENT` / `OPEN_DOCUMENT_TREE`),tree URI 授权后调
  `folderAccessGranted(treeUri)`。
- 这两套差异大,**不强行统一**,只把"选完返回的 uri/path"交给 Dart 编排。

### 4.4 验收
- Dart 触发 autosync:进度条走动、可取消、完成后时间轴出现同步点、offset 生效(防抖后画面更稳)。
- Dart 触发 export:进度走动、产出文件可播放、音频/码率/编码符合所选;导出中预览不动、导出后恢复。

---

## 附录 A — 原生文件去留总表

**删除/退役(逻辑迁到 Dart):**
- iOS:`Views/*`(全部 15 个)、`ParamsModel.*`、`GyroTimelineModel.*`、`GFTheme.*`、`GFViewKit.*`、`ViewController` 的 UI 编排部分。
- Android:`Gyroflow{Stabilize,Sync,Export,Motion,Advanced}Panel.kt`、`GyroflowViews.kt`、`GyroTimelineView.kt`、`OrientationIndicatorView.kt`、`GyroflowTheme.kt`、`GyroflowActivity` 的 UI 部分。

**保留(原生薄壳):**
- iOS:MDK 集成、Metal 渲染、`GFExportUtils`(导出)、解码 + `process_frame_metal_bgra8` 调用。
  (`GFBookmarkStore` 原计划保留,后其书签持久化并入插件 `VideoPickerChannel`,文件已随原生 UI 删除。)
- Android:`VideoDecoder.kt`、`YuvPacker.kt`、`GyroflowExporter.kt`、`GyroflowAutosync.kt`(喂帧)、wgpu 渲染、SAF。
- 两端:`gyroflow_ffi.h` / `GyroflowNative.kt`(**完全不动**)+ 新增 `EngineApiImpl` / `PreviewApiImpl` forwarding 薄壳。

**新增:**
- `EngineApiImpl`(iOS Swift / Android Kotlin):转发到现有 FFI/JNI。
- `PreviewApiImpl`:接管 createTexture / play / seek / export / autosync 编排入口。
- 预览纹理对接:iOS `FlutterTexture`、Android `SurfaceProducer`。

## 附录 B — 风险与回滚

| 风险 | 说明 | 缓解 |
|---|---|---|
| 桥 forwarding 易漏 | EngineApi 方法多,两端手写转发可能漏/错 | 用 `ParamsModel.h` + `GyroflowNative.kt` 当 checklist 逐条核对;先写一个 smoke 测试串(open→setParam→recompute→读 minFov) |
| 预览纹理格式/朝向 | CVPixelBuffer/SurfaceTexture 的色彩、上下翻转、stride 对齐 | 单独搭一个最小纹理 demo 先验通,再接全链路 |
| 高频调用过桥 | 逐帧 process/feed 走 channel 会卡 | 逐帧渲染、autosync 喂帧**不过桥**,留原生内部;只有离散参数/查询过桥 |
| recompute 线程 | 阻塞重算不能压主线程 | native 放后台队列,经 `onRecomputeFinished` 回 Dart |
| iOS 模拟器 | 静态库仅真机 arm64 | 保持现状,只真机验证 |

**分步可回滚:** 步骤 1 完成即可单独验证(预览临时用 PlatformView 嵌原生);步骤 3、4 各自独立,
任一步出问题不影响已完成步骤。建议每步一个分支 / PR。

## 推进顺序回顾
1. 步骤 0(引擎桥 Pigeon)→ 2. 步骤 1(UI/参数/主题/时间轴)→ 3. 步骤 3(预览 Texture)→ 4. 步骤 4(autosync/export)。
每步末尾按对应"验收"项确认后再进下一步。
