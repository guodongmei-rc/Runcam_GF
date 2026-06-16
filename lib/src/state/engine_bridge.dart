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
}
