// RuncamGF — 阶段2:统一 Dart↔native 引擎桥(Pigeon 强类型契约)。
//
// 这一份接口取代「两端各写一遍 UI→引擎接线」。Dart 调用一次,
// iOS / 安卓各自的 EngineApiImpl 转发到已有的引擎:
//   iOS  : ios/Libs/gyroflow_ffi.h 里的 gyroflow_*  (C FFI)
//   安卓 : android/.../GyroflowNative.kt 的 nativeXxx (JNI)
//
// 改本文件后重新生成:
//   dart run pigeon --input pigeons/runcam_gf_api.dart
//
// 对照核对表见 ~/Desktop/迁移步骤/阶段0+2-执行步骤.md 的 S1。
// 本阶段(0+2)不删任何原生 UI,old `open()` 全屏页照常可跑。

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/src/bridge/engine_api.g.dart',
  dartOptions: DartOptions(),
  swiftOut: 'ios/Classes/EngineApi.g.swift',
  swiftOptions: SwiftOptions(),
  kotlinOut:
      'android/src/main/kotlin/com/runcam/runcam_gf/EngineApi.g.kt',
  kotlinOptions: KotlinOptions(package: 'com.runcam.runcam_gf'),
  dartPackageName: 'runcam_gf',
))

// ============================================================================
// 数据类
// ============================================================================

/// 视频/项目基础信息。对应 gyroflow_ffi.h 的 GyroflowVideoInfo。
class VideoInfo {
  int? width;
  int? height;
  int? outputWidth;
  int? outputHeight;
  double? fps;
  double? durationS;
  int? frameCount;
}

/// recompute 后的只读输出(供 UI 显示最大修正角 / zoom% = 100/minFov)。
class StabInfo {
  double? maxAnglePitch;
  double? maxAngleYaw;
  double? maxAngleRoll;
  double? minFov;
}

/// 预览纹理信息(阶段1)。创建预览纹理后返回 textureId 与画面尺寸。
class PreviewInfo {
  int? textureId;
  int? width;
  int? height;
}

// ============================================================================
// EngineApi — Dart → 原生。离散的参数 setter/getter + 查询。
// 逐帧 process / autosync 喂帧「不」走这里(高频,留原生内部)。
// ============================================================================

@HostApi()
abstract class EngineApi {
  // ---- 生命周期 ----
  void createStabilizer(); // gyroflow_stabilizer_new
  void freeStabilizer(); // gyroflow_stabilizer_free

  @async
  VideoInfo openVideo(String uriOrPath); // load_video_file / nativeOpenVideo

  // ---- 稳定 ----
  void setStabEnabled(bool enabled);
  void setSmoothingMethod(int index); // 0=None 1=Default 2=Plain3D 3=Fixed
  void setSmoothingParam(String name, double value); // "smoothness"/"smoothness_pitch"/...

  /// 对齐 gyroflow_set_horizon_lock 全 9 参。
  /// (安卓 nativeSetHorizonLock 目前 2 参,impl 内补齐其余默认。)
  void setHorizonLock(
    double lockPercent,
    double rollDeg,
    bool lockPitch,
    double pitchDeg,
    bool automaticLock,
    double turnThreshold,
    double turnSmoothingMs,
    double turnMultiplier,
    double tiltAccelLimit,
  );

  // ---- 缩放 ----
  void setAdaptiveZoom(double windowSeconds);
  void setMaxZoom(double percent, int iterations);
  void setZoomingMethod(int index);
  void setLensCorrection(double amount);
  void setFov(double fov);

  // ---- 卷帘 / 速度 / 旋转 / 背景 / 安全区 / 预览分辨率 / 输出尺寸 ----
  void setFrameReadoutTime(double ms);
  void setFrameReadoutDirection(int dir); // 0=上→下 1=下→上 2=左→右 3=右→左
  void setVideoSpeed(
    double speed,
    bool affectsSmoothing,
    bool affectsZooming,
    bool affectsZoomingLimit,
  );
  void setAdditionalRotation(double pitchDeg, double yawDeg, double rollDeg);
  void setBackgroundColor(double r, double g, double b, double a);
  void setBackgroundMode(int mode); // 0=纯色 1=边缘拉伸 2=边缘镜像 3=羽化留边
  void setShowSafeArea(bool show);
  void setShowDetectedFeatures(bool show);
  void setShowOpticalFlow(bool show);
  void setPreviewResolution(int targetHeight); // 0/-1=原生,否则 1080/720/480
  void setOutputSize(int width, int height); // 当长宽比 scale 铺满
  void setOutputSizeExact(int width, int height); // 精确像素,可低于 input(预览降采样)

  // ---- IMU / 运动数据 ----
  void setGyroOffset(double offsetMs);
  void setImuLpf(double hz);
  void setImuOrientation(String orientation); // 如 "ZyX"
  void setIntegrationMethod(int index); // 0=None 1=Comp 2=VQF 3=Madgwick ...
  void setFrameOffset(int frames); // 整帧粒度对齐(可负)

  // ---- 镜头 ----
  String lensSearch(String query); // 返回 JSON [{"name","id"}]
  String loadLens(String uriOrIdOrJson); // 文件/内置id/JSON
  String getLensInfoFull(); // 完整镜头档案 JSON
  String loadGyro(String uriOrPath, bool loadAllMetadata);
  void folderAccessGranted(String folderUrl); // 沙盒/SAF 目录白名单

  // ---- 查询 / 重算 ----
  /// 阻塞重算(放后台队列执行)+ 返回 max angles / min fov。
  /// 完成后另经 EngineEvents.onRecomputeFinished 通知一次,便于 UI 统一刷新。
  @async
  StabInfo recomputeBlocking();

  String getVideoMetadata(); // 视频内嵌元数据 JSON
  List<double> gyroTimeline(int count); // 交错 [x,y,z,...] °/s;空=无原始角速度
  List<double> quaternionTimeline(int count); // 交错 [x,y,z,w,...];gyroTimeline 空时退回
  List<double> quatsAtTimestamp(int timestampUs); // double[8]:原始 wijk + 平滑 wijk
  double getFovAtTimestamp(int timestampUs); // HUD zoom% = 100/fov
}

// ============================================================================
// EngineEvents — 原生 → Dart。回调通知。
// ============================================================================

@FlutterApi()
abstract class EngineEvents {
  /// recompute_blocking 在后台完成后,回主线程通知(刷 max angles / minFov)。
  void onRecomputeFinished(StabInfo info);

  /// autosync 进度(ready/total 对齐官方 on_progress)。
  void onAutosyncProgress(double progress, int ready, int total);

  /// autosync 结束。medianOffsetMs 仅显示用;syncPoints 交错 [mid_ms, off_ms, ...]。
  /// iOS 出参 / 安卓 JSON 在各端 impl 内归一成本回调。
  void onAutosyncFinished(double medianOffsetMs, List<double> syncPoints, bool ok);

  /// 导出进度(渲染线程回调,impl 内切回主线程再发)。
  void onExportProgress(double progress, int frame, int total);

  /// 播放推进:供 Flutter HUD 显示时间码 / zoom%(阶段 3 用)。
  void onPlaybackTick(int timestampUs, double fov);
}

// ============================================================================
// PreviewApi — 预览/解码/导出控制。
// 本阶段(0+2)仅占位定义签名;实现留到阶段1(Texture)/阶段4(autosync/export)。
// ============================================================================

@HostApi()
abstract class PreviewApi {
  /// 创建外接预览纹理。建解码器+CVPB 池+注册纹理,返回 textureId 与画面尺寸
  /// (阶段1:iOS FlutterTexture / 安卓 SurfaceProducer)。
  PreviewInfo createPreviewTexture(String uriOrPath);
  void disposePreviewTexture(int textureId);

  void play();
  void pause();
  void seekTo(int timestampUs);

  /// 取并清零"自上次调用以来 copyPixelBuffer 被调次数"= Flutter 实际合成/上屏该
  /// 纹理的帧数。每秒调一次即得真实合成 FPS(Dart 的 addTimingsCallback 只统计框架帧、
  /// 看不到外部纹理合成,故须在原生侧计数)。
  int takeCompositedFrameCount();

  /// 导出模式:开启后逐帧只渲输出供回读、不上屏(对齐 nativeSetExportMode)。
  void setExportMode(bool on);
}
