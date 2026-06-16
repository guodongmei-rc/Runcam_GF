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
