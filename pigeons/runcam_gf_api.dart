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
  // 媒体信息:gyroflow FFI 不透出音/视频流编码,由原生从 AVAsset(iOS)/
  // MediaExtractor(Android)读取填入,供「视频信息」面板显示(对齐桌面)。
  String? videoCodec; // 如 "H.264" / "HEVC"
  String? pixelFormat; // 如 "YUV420P 8 bit"(取不到=空)
  String? audioCodec; // 如 "AAC"(无音频轨=空)
  int? audioSampleRate; // 如 48000(Hz;无音频轨=空)
  int? rotationDeg; // 0/90/180/270
  int? videoBitrate; // 源视频码率(bit/s);默认导出比特率 = 此值/1024/1024(对齐官方)。取不到=空
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

/// 导出请求(对齐旧原生 runExportFromURL 入参):源视频 + 输出位置 + 编码参数 + 输出尺寸。
class ExportRequest {
  String? srcUri; // 源视频 uri/path(当前打开的视频)
  String? outputUri; // 输出目录 uri/path(已授权);空=由原生兜底临时目录
  String? fileName; // 输出文件名(含扩展名)
  int? codecIndex; // 0=H.264 1=HEVC 2=ProRes(对齐 GFExportUtils codecForIndex)
  int? bitrateMbps; // 0=自动
  bool? exportAudio;
  int? width; // 输出宽(偶数)
  int? height; // 输出高(偶数)
  int? trimStartUs; // 裁剪起点(µs,从视频开头算);0/缺省=从头导出
  int? trimEndUs; // 裁剪终点(µs);0/缺省=导到结尾
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
  void setImuMedian(int samples); // 中值滤波采样数;0=关
  void setImuRotation(double pitchDeg, double rollDeg, double yawDeg); // IMU 旋转;全 0=不旋转
  void setImuBias(double x, double y, double z); // 陀螺 bias(°/s);全 0=无偏置
  void setImuOrientation(String orientation); // 如 "ZyX"
  void setIntegrationMethod(int index); // 0=None 1=Comp 2=VQF 3=Madgwick ...
  void setFrameOffset(int frames); // 整帧粒度对齐(可负)

  // ---- 镜头 ----
  String lensSearch(String query); // 返回 JSON [{"name","id"}]
  String loadLens(String uriOrIdOrJson); // 文件/内置id/JSON
  String getLensInfoFull(); // 完整镜头档案 JSON

  /// 按当前已识别相机身份(camera_id)从内置库自动加载镜头档案。用于「相机身份在外挂
  /// .gcsv 里、视频本身无 telemetry」的机型(如 RunCam6):加载 gcsv 后调用。
  /// 返回 gyroflow_autoload_lens_for_camera 的 rc:0=已加载;-2=无可匹配/已有档案;-1=错。
  /// (安卓 nativeLoadGyro 已在加载时内部自动配镜头,该方法在安卓为 no-op。)
  int autoloadLensForCamera();
  String loadGyro(String uriOrPath, bool loadAllMetadata);
  void folderAccessGranted(String folderUrl); // 沙盒/SAF 目录白名单

  // ---- 查询 / 重算 ----
  /// 阻塞重算(放后台队列执行)+ 返回 max angles / min fov。
  /// 完成后另经 EngineEvents.onRecomputeFinished 通知一次,便于 UI 统一刷新。
  @async
  StabInfo recomputeBlocking();

  String getVideoMetadata(); // 视频内嵌元数据 JSON

  /// 运动数据当前状态 JSON(供「输入」面板回显):
  /// {"imu_orientation":"ZyX","has_quaternions":bool,"integration_method":int,
  ///  "lpf":double,"median":int,"rotation":[p,r,y],"bias":[x,y,z]}
  /// 安卓 nativeGetGyroInfo 全字段;iOS 用 get_imu_orientation + has_quaternions 拼核心字段。
  String getGyroInfo();

  List<double> gyroTimeline(int count); // 交错 [x,y,z,...] °/s;空=无原始角速度
  List<double> quaternionTimeline(int count); // 交错 [x,y,z,w,...];gyroTimeline 空时退回
  List<double> quatsAtTimestamp(int timestampUs); // double[8]:原始 wijk + 平滑 wijk
  double getFovAtTimestamp(int timestampUs); // HUD zoom% = 100/fov

  // ---- 自动同步(autosync)----
  // 编排在原生(start→取区间→解灰度帧 feed_frame→finish 逐点写偏移),逐帧喂帧不过桥。
  // 进度/结束经 EngineEvents.onAutosyncProgress / onAutosyncFinished 回 Dart。
  // 参数 1:1 对齐 gyroflow_autosync_start;前置:已加载镜头档案 + 有运动数据。
  void autosyncStart(
    String uriOrPath,
    double initialOffsetMs,
    double searchSizeSec,
    int maxSyncPoints,
    int everyNthFrame,
    double timePerSyncpointSec,
    int ofMethod, // 光流:2=OpenCV DIS(官方默认)
    int poseMethod, // 位姿:0=findEssentialMat(官方默认)
    int offsetMethod, // 偏移:2=rs-sync(官方默认)
    bool calcInitialFast,
    bool checkNegativeInitialOffset,
    bool autoSyncPoints,
  );
  void autosyncCancel();
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

  /// 暂停态按需重渲当前帧:参数改动后 recompute 完,主动刷新一次预览
  /// (播放时渲染循环已连续刷新,无需调用)。
  void renderOnce();

  /// 取并清零"自上次调用以来 copyPixelBuffer 被调次数"= Flutter 实际合成/上屏该
  /// 纹理的帧数。每秒调一次即得真实合成 FPS(Dart 的 addTimingsCallback 只统计框架帧、
  /// 看不到外部纹理合成,故须在原生侧计数)。
  int takeCompositedFrameCount();

  /// 导出模式:开启后逐帧只渲输出供回读、不上屏(对齐 nativeSetExportMode)。
  void setExportMode(bool on);

  /// 开始导出(对齐旧原生 runExportFromURL):复用共享 stabilizer 逐帧
  /// 解码→process_frame→编码写文件,进度经 EngineEvents.onExportProgress 回报。
  /// 返回空串=成功;非空=错误信息(取消时返回「已取消」)。
  @async
  String startExport(ExportRequest req);

  /// 取消进行中的导出(置标志,导出循环下一帧自停)。
  void cancelExport();
}
