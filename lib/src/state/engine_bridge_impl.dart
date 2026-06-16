import '../bridge/engine_api.g.dart';
import 'engine_bridge.dart';

/// 真实引擎桥:每方法 1:1 转发到 Pigeon 生成的 EngineApi。
class EngineBridgeImpl implements EngineBridge {
  EngineBridgeImpl([EngineApi? api]) : _api = api ?? EngineApi();
  final EngineApi _api;

  @override
  Future<void> createStabilizer() => _api.createStabilizer();
  @override
  Future<void> freeStabilizer() => _api.freeStabilizer();
  @override
  Future<VideoInfo> openVideo(String uriOrPath) => _api.openVideo(uriOrPath);

  @override
  Future<void> setStabEnabled(bool enabled) => _api.setStabEnabled(enabled);

  @override
  Future<void> setGyroOffset(double offsetMs) => _api.setGyroOffset(offsetMs);

  @override
  Future<void> setImuLpf(double hz) => _api.setImuLpf(hz);
  @override
  Future<void> setSmoothingMethod(int index) => _api.setSmoothingMethod(index);
  @override
  Future<void> setSmoothingParam(String name, double value) =>
      _api.setSmoothingParam(name, value);
  @override
  Future<void> setHorizonLock(double lockPercent, double rollDeg, bool lockPitch,
          double pitchDeg, bool automaticLock, double turnThreshold,
          double turnSmoothingMs, double turnMultiplier, double tiltAccelLimit) =>
      _api.setHorizonLock(lockPercent, rollDeg, lockPitch, pitchDeg,
          automaticLock, turnThreshold, turnSmoothingMs, turnMultiplier, tiltAccelLimit);
  @override
  Future<void> setMaxZoom(double percent, int iterations) =>
      _api.setMaxZoom(percent, iterations);
  @override
  Future<void> setAdaptiveZoom(double windowSeconds) =>
      _api.setAdaptiveZoom(windowSeconds);
  @override
  Future<void> setLensCorrection(double amount) => _api.setLensCorrection(amount);
  @override
  Future<void> setFov(double fov) => _api.setFov(fov);
  @override
  Future<void> setZoomingMethod(int index) => _api.setZoomingMethod(index);
  @override
  Future<void> setFrameReadoutTime(double ms) => _api.setFrameReadoutTime(ms);
  @override
  Future<void> setFrameReadoutDirection(int dir) =>
      _api.setFrameReadoutDirection(dir);
  @override
  Future<void> setAdditionalRotation(double pitchDeg, double yawDeg, double rollDeg) =>
      _api.setAdditionalRotation(pitchDeg, yawDeg, rollDeg);
  @override
  Future<void> setVideoSpeed(double speed, bool affectsSmoothing,
          bool affectsZooming, bool affectsZoomingLimit) =>
      _api.setVideoSpeed(speed, affectsSmoothing, affectsZooming, affectsZoomingLimit);
  @override
  Future<void> setOutputSizeExact(int width, int height) =>
      _api.setOutputSizeExact(width, height);
  @override
  Future<void> setBackgroundColor(double r, double g, double b, double a) =>
      _api.setBackgroundColor(r, g, b, a);
  @override
  Future<void> setBackgroundMode(int mode) => _api.setBackgroundMode(mode);
  @override
  Future<void> setShowSafeArea(bool show) => _api.setShowSafeArea(show);
  @override
  Future<void> setShowDetectedFeatures(bool show) =>
      _api.setShowDetectedFeatures(show);
  @override
  Future<void> setShowOpticalFlow(bool show) => _api.setShowOpticalFlow(show);

  @override
  Future<StabInfo> recomputeBlocking() => _api.recomputeBlocking();
}
