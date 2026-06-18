import '../bridge/engine_api.g.dart' show VideoInfo, StabInfo;

export '../bridge/engine_api.g.dart' show VideoInfo, StabInfo;

/// ParamsModel 唯一依赖的引擎接口。只收录 S7 用到的写方法 + recompute。
/// 真实实现 [EngineBridgeImpl] 转发到生成的 EngineApi;单测用 FakeEngineBridge。
abstract class EngineBridge {
  Future<void> createStabilizer();
  Future<void> freeStabilizer();
  Future<VideoInfo> openVideo(String uriOrPath);

  /// 防抖总开关。ParamsModel 不管它(非面板参数),由 Controller/smoke 在加载视频后
  /// 显式打开(对齐 ViewController.mm 的 gyroflow_set_stab_enabled(s, 1))。
  Future<void> setStabEnabled(bool enabled);

  /// 陀螺时间偏移(ms)。raw-IMU 机型(GoPro Hero5/6/7 等,has_accurate_timestamps=false)
  /// 陀螺数据流与视频帧有固有错位(Hero6 实测约 +48ms);不补偿会用错时刻姿态做校正、
  /// 反向叠加抖动("开防抖比不开还抖")。production 应走 autosync(阶段4)精确求;
  /// 预览 spike 期间按机型默认值补。offset_ms>0 = 陀螺超前视频,0 = 清除。
  Future<void> setGyroOffset(double offsetMs);

  Future<void> setImuLpf(double hz);
  Future<void> setSmoothingMethod(int index);
  Future<void> setSmoothingParam(String name, double value);
  Future<void> setHorizonLock(
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
  Future<void> setMaxZoom(double percent, int iterations);
  Future<void> setAdaptiveZoom(double windowSeconds);
  Future<void> setLensCorrection(double amount);
  Future<void> setFov(double fov);
  Future<void> setZoomingMethod(int index);
  Future<void> setFrameReadoutTime(double ms);
  Future<void> setFrameReadoutDirection(int dir);
  Future<void> setAdditionalRotation(double pitchDeg, double yawDeg, double rollDeg);
  Future<void> setVideoSpeed(
      double speed, bool affectsSmoothing, bool affectsZooming, bool affectsZoomingLimit);
  Future<void> setOutputSizeExact(int width, int height);
  Future<void> setBackgroundColor(double r, double g, double b, double a);
  Future<void> setBackgroundMode(int mode);
  Future<void> setShowSafeArea(bool show);
  Future<void> setShowDetectedFeatures(bool show);
  Future<void> setShowOpticalFlow(bool show);

  Future<StabInfo> recomputeBlocking();

  /// 视频内嵌元数据 JSON(录制参数:ISO/快门/光圈/Gamma 等,在
  /// `additional_data.recording_settings` 下)。供「输入」面板显示。
  Future<String> getVideoMetadata();

  /// 运动数据设置(「输入」面板用)。改完需调用方 recompute。
  Future<void> setImuOrientation(String orientation); // 如 "XYZ" / "ZyX"
  Future<void> setIntegrationMethod(int index); // 0=None 1=Comp 2=VQF 3=Madgwick

  /// 中值滤波采样数(0=关)。
  Future<void> setImuMedian(int samples);

  /// IMU 旋转(度):pitch/roll/yaw(全 0=不旋转)。
  Future<void> setImuRotation(double pitchDeg, double rollDeg, double yawDeg);

  /// 陀螺 bias(°/s):x/y/z(全 0=无偏置)。
  Future<void> setImuBias(double x, double y, double z);

  /// 运动数据当前状态 JSON(回显用):imu_orientation / has_quaternions /
  /// integration_method 等。安卓全字段;iOS 仅 imu_orientation + has_quaternions。
  Future<String> getGyroInfo();

  /// 镜头配置文件(「输入」面板用)。
  Future<String> lensSearch(String query); // 返回 JSON [{"name","id"}]
  Future<String> loadLens(String uriOrIdOrJson); // 内置 id / 文件路径 / JSON
  Future<String> getLensInfoFull(); // 当前镜头档案完整 JSON

  /// 手动加载陀螺/IMU sidecar 数据(.gcsv/.csv/.bbl…)。loadAllMetadata=false 只取
  /// 陀螺/四元数流;true 按主视频完整解析(带入内嵌镜头/fps/卷帘)。返回状态 JSON。
  Future<String> loadGyro(String uriOrPath, bool loadAllMetadata);

  /// 整帧粒度对齐(可负;「帧偏移」关闭时传 0)。改完需调用方 recompute。
  Future<void> setFrameOffset(int frames);

  /// 指定时间戳处的姿态四元数(供「方向指示器」逐帧绘制)。返回 double[8]:
  /// [0..4]=原始姿态 (w,i,j,k),[4..8]=平滑姿态 (w,i,j,k);scalar first。
  /// 内部已扣掉 gyro/video 同步偏移。无数据时返回空。
  Future<List<double>> quatsAtTimestamp(int timestampUs);

  /// 指定时间戳处的 fov(供预览 HUD 显示「缩放%」= 100/fov,对齐桌面 Gyroflow)。
  /// 不写纹理、不动 stabilizer 状态。失败/无数据时返回 0。
  Future<double> getFovAtTimestamp(int timestampUs);

  // ---- 自动同步(autosync)----
  /// 启动 autosync(参数 1:1 对齐 gyroflow_autosync_start)。编排在原生,逐帧喂帧不过桥;
  /// 前置:已加载镜头档案 + 有运动数据。进度/结束经 [autosyncProgress]/[autosyncFinished] 回。
  Future<void> autosyncStart(
    String uriOrPath,
    double initialOffsetMs,
    double searchSizeSec,
    int maxSyncPoints,
    int everyNthFrame,
    double timePerSyncpointSec,
    int ofMethod,
    int poseMethod,
    int offsetMethod,
    bool calcInitialFast,
    bool checkNegativeInitialOffset,
    bool autoSyncPoints,
  );

  /// 取消进行中的 autosync。
  Future<void> autosyncCancel();

  /// 把已授权目录注册进 gyroflow 文件白名单(ALLOWED_FOLDERS),否则同目录 sidecar
  /// 自动加载/loadGyro/loadLens 读不到文件。传 file:// URL(iOS)或 SAF tree uri(安卓)。
  Future<void> folderAccessGranted(String folderUrl);

  /// 按相机身份从内置库自动加载镜头(用于相机身份随 .gcsv 才确定的机型,如 RunCam6)。
  /// 返回 rc:0=已加载,-2=无可匹配/已有档案,-1=错。安卓为 no-op(load_gyro 内部已配)。
  Future<int> autoloadLensForCamera();

  /// 原始角速度时间线(交错 [x,y,z,...] °/s,count 个采样点)。供陀螺波形绘制。空=无原始角速度。
  Future<List<double>> gyroTimeline(int count);

  /// 四元数时间线(交错 [x,y,z,w,...]);gyroTimeline 为空(仅四元数视频)时退回用它绘制。
  Future<List<double>> quaternionTimeline(int count);

  /// autosync 进度流:(progress 0..1, ready 帧数, total 帧数)。
  Stream<(double, int, int)> get autosyncProgress;

  /// autosync 结束流:(medianOffsetMs 仅显示, syncPoints 交错[mid,off,...], ok)。
  /// 偏移已由 FFI autosync_finish 逐点写入 gyro 并 recompute,Dart 侧只需刷新只读输出。
  Stream<(double, List<double>, bool)> get autosyncFinished;

  /// 导出进度流:(progress 0..1, frame 已导出帧, total 总帧)。导出渲染接入后由原生回报。
  Stream<(double, int, int)> get exportProgress;
}
