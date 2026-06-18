import 'dart:async';

import '../bridge/engine_api.g.dart';
import 'engine_bridge.dart';

/// 真实引擎桥:每方法 1:1 转发到 Pigeon 生成的 EngineApi。
/// 同时实现 EngineEvents(原生→Dart 回调),把 autosync 进度/结束转成 Dart 流。
class EngineBridgeImpl implements EngineBridge, EngineEvents {
  EngineBridgeImpl([EngineApi? api]) : _api = api ?? EngineApi() {
    EngineEvents.setUp(this); // 注册事件接收端(多实例时后者覆盖前者,单编辑器场景 OK)
  }
  final EngineApi _api;

  final _autosyncProgressCtrl =
      StreamController<(double, int, int)>.broadcast();
  final _autosyncFinishedCtrl =
      StreamController<(double, List<double>, bool)>.broadcast();
  final _exportProgressCtrl =
      StreamController<(double, int, int)>.broadcast();

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

  @override
  Future<String> getVideoMetadata() => _api.getVideoMetadata();

  @override
  Future<void> setImuOrientation(String orientation) =>
      _api.setImuOrientation(orientation);

  @override
  Future<void> setIntegrationMethod(int index) =>
      _api.setIntegrationMethod(index);

  @override
  Future<String> lensSearch(String query) => _api.lensSearch(query);
  @override
  Future<String> loadLens(String uriOrIdOrJson) => _api.loadLens(uriOrIdOrJson);
  @override
  Future<String> getLensInfoFull() => _api.getLensInfoFull();

  @override
  Future<List<double>> quatsAtTimestamp(int timestampUs) =>
      _api.quatsAtTimestamp(timestampUs);

  @override
  Future<double> getFovAtTimestamp(int timestampUs) =>
      _api.getFovAtTimestamp(timestampUs);

  @override
  Future<String> loadGyro(String uriOrPath, bool loadAllMetadata) =>
      _api.loadGyro(uriOrPath, loadAllMetadata);

  @override
  Future<void> setFrameOffset(int frames) => _api.setFrameOffset(frames);

  @override
  Future<String> getGyroInfo() => _api.getGyroInfo();

  @override
  Future<void> setImuMedian(int samples) => _api.setImuMedian(samples);
  @override
  Future<void> setImuRotation(double pitchDeg, double rollDeg, double yawDeg) =>
      _api.setImuRotation(pitchDeg, rollDeg, yawDeg);
  @override
  Future<void> setImuBias(double x, double y, double z) =>
      _api.setImuBias(x, y, z);

  // ---- 自动同步 ----
  @override
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
  ) =>
      _api.autosyncStart(
        uriOrPath,
        initialOffsetMs,
        searchSizeSec,
        maxSyncPoints,
        everyNthFrame,
        timePerSyncpointSec,
        ofMethod,
        poseMethod,
        offsetMethod,
        calcInitialFast,
        checkNegativeInitialOffset,
        autoSyncPoints,
      );

  @override
  Future<void> autosyncCancel() => _api.autosyncCancel();

  @override
  Future<void> folderAccessGranted(String folderUrl) =>
      _api.folderAccessGranted(folderUrl);

  @override
  Future<int> autoloadLensForCamera() => _api.autoloadLensForCamera();

  @override
  Future<List<double>> gyroTimeline(int count) => _api.gyroTimeline(count);

  @override
  Future<List<double>> quaternionTimeline(int count) =>
      _api.quaternionTimeline(count);

  @override
  Stream<(double, int, int)> get autosyncProgress =>
      _autosyncProgressCtrl.stream;

  @override
  Stream<(double, List<double>, bool)> get autosyncFinished =>
      _autosyncFinishedCtrl.stream;

  @override
  Stream<(double, int, int)> get exportProgress => _exportProgressCtrl.stream;

  // ---- EngineEvents(原生→Dart)----
  @override
  void onAutosyncProgress(double progress, int ready, int total) {
    if (!_autosyncProgressCtrl.isClosed) {
      _autosyncProgressCtrl.add((progress, ready, total));
    }
  }

  @override
  void onAutosyncFinished(
      double medianOffsetMs, List<double> syncPoints, bool ok) {
    if (!_autosyncFinishedCtrl.isClosed) {
      _autosyncFinishedCtrl.add((medianOffsetMs, syncPoints, ok));
    }
  }

  @override
  void onRecomputeFinished(StabInfo info) {/* 暂未用:recompute 走 recomputeBlocking 返回值 */}

  @override
  void onExportProgress(double progress, int frame, int total) {
    if (!_exportProgressCtrl.isClosed) {
      _exportProgressCtrl.add((progress, frame, total));
    }
  }

  @override
  void onPlaybackTick(int timestampUs, double fov) {/* HUD 走 getFovAtTimestamp 轮询 */}
}
