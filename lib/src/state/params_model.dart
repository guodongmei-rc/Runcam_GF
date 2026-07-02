import 'dart:async';
import 'package:flutter/foundation.dart';

import 'defaults.dart';
import 'clamp.dart';
import 'engine_bridge.dart';

part 'params_model_stabilize.dart';
part 'params_model_zoom.dart';
part 'params_model_advanced.dart';

/// 参数面板的全量状态。每个 setter:clamp → 立即推引擎 → 200ms 合并防抖
/// → recomputeBlocking → 回填只读输出。逻辑誊写自原生 ParamsModel.m(已随原生 UI
/// 删除,历史版本:git show 3b3c53e^:ios/Sources/ParamsModel.m);本文件即当前事实源。
class ParamsModel extends ChangeNotifier {
  ParamsModel(this.bridge);

  final EngineBridge bridge;

  static const Duration debounce = Duration(milliseconds: 200);
  Timer? _recomputeTimer;
  bool _disposed = false;

  // ---- 只读输出(只由回填写入)----
  double _maxAnglePitch = 0.0;
  double _maxAngleYaw = 0.0;
  double _maxAngleRoll = 0.0;
  double _minFov = 0.0;
  double get maxAnglePitch => _maxAnglePitch;
  double get maxAngleYaw => _maxAngleYaw;
  double get maxAngleRoll => _maxAngleRoll;
  double get minFov => _minFov;

  // ---- 稳定组字段(本 Task 仅 smoothness;其余 Task 7 起补)----
  double _smoothness = ParamsDefaults.smoothness;
  double get smoothness => _smoothness;
  set smoothness(double v) {
    final c = ParamsRange.smoothness(v);
    if (c == _smoothness) return;
    _smoothness = c;
    send(() => bridge.setSmoothingParam('smoothness', c));
    armRecompute();
    notifyListeners();
  }

  int _smoothingMethod = ParamsDefaults.smoothingMethod;
  bool _perAxis = ParamsDefaults.perAxis;
  double _smoothnessPitch = ParamsDefaults.smoothnessPitch;
  double _smoothnessYaw = ParamsDefaults.smoothnessYaw;
  double _smoothnessRoll = ParamsDefaults.smoothnessRoll;
  bool _horizonLock = ParamsDefaults.horizonLock;
  double _horizonLockAmount = ParamsDefaults.horizonLockAmount;
  double _horizonLockRoll = ParamsDefaults.horizonLockRoll;
  bool _horizonLockPitchEnabled = ParamsDefaults.horizonLockPitchEnabled;
  double _horizonLockPitch = ParamsDefaults.horizonLockPitch;
  bool _automaticHorizonLock = ParamsDefaults.automaticHorizonLock;
  double _turnThreshold = ParamsDefaults.turnThreshold;
  double _turnSmoothingMs = ParamsDefaults.turnSmoothingMs;
  double _turnMultiplier = ParamsDefaults.turnMultiplier;
  double _tiltAccelLimit = ParamsDefaults.tiltAccelLimit;
  double _plain3dTimeConstant = ParamsDefaults.plain3dTimeConstant;
  double _fixedPitch = ParamsDefaults.fixedPitch;
  double _fixedYaw = ParamsDefaults.fixedYaw;
  double _fixedRoll = ParamsDefaults.fixedRoll;
  bool _trimRangeOnly = ParamsDefaults.trimRangeOnly;
  double _maxSmoothnessSec = ParamsDefaults.maxSmoothnessSec;
  double _alphaHighVelSec = ParamsDefaults.alphaHighVelSec;

  // ---- 缩放组字段(getter/setter 在 params_model_zoom.dart extension)----
  double _maxZoomPercent = ParamsDefaults.maxZoomPercent;
  int _maxZoomIterations = ParamsDefaults.maxZoomIterations;
  double _adaptiveZoomSec = ParamsDefaults.adaptiveZoomSec;
  double _lensCorrection = ParamsDefaults.lensCorrection;
  double _fov = ParamsDefaults.fov;
  int _croppingMode = ParamsDefaults.croppingMode;
  int _zoomingMethod = ParamsDefaults.zoomingMethod;
  bool _rsCorrection = ParamsDefaults.rsCorrection;
  double _frameReadoutMs = ParamsDefaults.frameReadoutMs;
  int _frameReadoutDirection = ParamsDefaults.frameReadoutDirection;
  double _addPitch = ParamsDefaults.addPitch;
  double _addYaw = ParamsDefaults.addYaw;
  double _addRoll = ParamsDefaults.addRoll;
  double _videoSpeed = ParamsDefaults.videoSpeed;
  bool _videoSpeedAffectsSmoothing = ParamsDefaults.videoSpeedAffectsSmoothing;
  bool _videoSpeedAffectsZooming = ParamsDefaults.videoSpeedAffectsZooming;
  bool _videoSpeedAffectsZoomingLimit = ParamsDefaults.videoSpeedAffectsZoomingLimit;

  // ---- 高级组字段(getter/setter 在 params_model_advanced.dart extension)----
  int _outputWidth = ParamsDefaults.outputWidth;
  int _outputHeight = ParamsDefaults.outputHeight;
  double _bgR = ParamsDefaults.bgR;
  double _bgG = ParamsDefaults.bgG;
  double _bgB = ParamsDefaults.bgB;
  double _bgA = ParamsDefaults.bgA;
  int _backgroundMode = ParamsDefaults.backgroundMode;
  bool _showSafeArea = ParamsDefaults.showSafeArea;
  bool _showDetectedFeatures = ParamsDefaults.showDetectedFeatures;
  bool _showOpticalFlow = ParamsDefaults.showOpticalFlow;
  int _previewResolutionHeight = ParamsDefaults.previewResolutionHeight;
  double _imuLpfHz = ParamsDefaults.imuLpfHz;

  // ---- 同步组字段(仅 imuLpfHz 接 FFI;其余只存值)----
  bool _autosyncEnabled = ParamsDefaults.autosyncEnabled;
  double _gyroOffsetMs = ParamsDefaults.gyroOffsetMs;
  double _syncSearchSizeSec = ParamsDefaults.syncSearchSizeSec;
  int _maxSyncPoints = ParamsDefaults.maxSyncPoints;
  int _everyNthFrame = ParamsDefaults.everyNthFrame;
  double _timePerSyncpointSec = ParamsDefaults.timePerSyncpointSec;
  int _syncProcessingHeight = ParamsDefaults.syncProcessingHeight;
  int _ofMethod = ParamsDefaults.ofMethod;
  int _poseMethod = ParamsDefaults.poseMethod;
  int _offsetMethod = ParamsDefaults.offsetMethod;
  bool _checkNegativeInitialOffset = ParamsDefaults.checkNegativeInitialOffset;
  bool _calcInitialFast = ParamsDefaults.calcInitialFast;
  bool _autoSyncPointsExperimental = ParamsDefaults.autoSyncPointsExperimental;

  // ---- 导出组字段(不接 FFI)----
  int _exportCodecIndex = ParamsDefaults.exportCodecIndex;
  int _exportBitrateMbps = ParamsDefaults.exportBitrateMbps;
  bool _useGpuEncoding = ParamsDefaults.useGpuEncoding;
  bool _exportAudio = ParamsDefaults.exportAudio;

  /// 背景色 4 通道一次性推送(镜像 ParamsModel.m setBg*)。
  void pushBackgroundColor() {
    send(() => bridge.setBackgroundColor(_bgR, _bgG, _bgB, _bgA));
  }

  /// 地平线锁定 9 参一次性推送(镜像 ParamsModel.m applyHorizonLockToFFI)。
  /// horizonLock=OFF 时 amount 强制 0;pitch 未启用时 pitch 传 0。
  void pushHorizonLock() {
    final amount = _horizonLock ? _horizonLockAmount : 0.0;
    send(() => bridge.setHorizonLock(
          amount,
          _horizonLockRoll,
          _horizonLockPitchEnabled,
          _horizonLockPitchEnabled ? _horizonLockPitch : 0.0,
          _automaticHorizonLock,
          _turnThreshold,
          _turnSmoothingMs,
          _turnMultiplier,
          _tiltAccelLimit,
        ));
  }

  /// croppingMode→adaptive_zoom 映射(镜像 ParamsModel.m):0→0.0 / 1→adaptiveZoomSec / 2→-1.0。
  void pushAdaptiveZoom() {
    final double azv;
    switch (_croppingMode) {
      case 0:
        azv = 0.0;
        break;
      case 2:
        azv = -1.0;
        break;
      default:
        azv = _adaptiveZoomSec;
    }
    send(() => bridge.setAdaptiveZoom(azv));
  }

  /// videoSpeed + 3 联动开关一次性推送(镜像 ParamsModel.m pushVideoSpeed)。
  void pushVideoSpeed() {
    send(() => bridge.setVideoSpeed(
          _videoSpeed,
          _videoSpeedAffectsSmoothing,
          _videoSpeedAffectsZooming,
          _videoSpeedAffectsZoomingLimit,
        ));
  }

  /// part extension 调它来通知(notifyListeners 是 @protected,扩展非子类不能直接调)。
  void notify() => notifyListeners();

  // ---- 内部 helper(供本类与各 extension 复用)----

  /// 立即推一次引擎调用,吞掉错误(阶段0+2 桥可能在未 createStabilizer 时被调)。
  void send(Future<void> Function() op) {
    op().catchError((Object e) {
      debugPrint('[ParamsModel] engine push failed: $e');
    });
  }

  // 导出期间为 true:禁止防抖 recompute(导出在另一线程独占 stabilizer,并发 recompute 会崩)。
  bool exportInProgress = false;
  Future<void>? _inFlightRecompute; // 当前在飞的 recompute,flush 时等它跑完

  /// 复位共享防抖定时器;到点跑一次 recomputeBlocking 并回填。导出期间不再 arm。
  void armRecompute() {
    if (exportInProgress) return;
    _recomputeTimer?.cancel();
    _recomputeTimer = Timer(debounce, _runRecompute);
  }

  Future<void> _runRecompute() async {
    final fut = _doRecompute();
    _inFlightRecompute = fut;
    await fut;
    if (identical(_inFlightRecompute, fut)) _inFlightRecompute = null;
  }

  Future<void> _doRecompute() async {
    try {
      final info = await bridge.recomputeBlocking();
      if (_disposed) return;
      _maxAnglePitch = info.maxAnglePitch ?? _maxAnglePitch;
      _maxAngleYaw = info.maxAngleYaw ?? _maxAngleYaw;
      _maxAngleRoll = info.maxAngleRoll ?? _maxAngleRoll;
      _minFov = info.minFov ?? _minFov;
      notifyListeners();
    } catch (e) {
      debugPrint('[ParamsModel] recompute failed: $e'); // 保留旧只读值
    }
  }

  /// 导出前调用:取消挂起的防抖定时器并跑完它,再等任何在飞的 recompute 结束。
  /// 返回后引擎 recompute 已空闲,导出独占 stabilizer 不会并发。
  Future<void> flushPendingRecompute() async {
    if (_recomputeTimer?.isActive ?? false) {
      _recomputeTimer!.cancel();
      await _runRecompute();
    }
    final f = _inFlightRecompute;
    if (f != null) await f;
  }

  /// 对齐 .m loadDefaultsFromStabilizer:把所有接 FFI 的当前值推到引擎,
  /// 然后**直接** recompute 一次并回填(不经防抖)。Controller 在 createStabilizer 后调一次。
  Future<void> pushAllDefaultsAndRecompute() async {
    send(() => bridge.setImuLpf(_imuLpfHz));
    send(() => bridge.setSmoothingMethod(_smoothingMethod));
    send(() => bridge.setSmoothingParam('smoothness', _smoothness));
    send(() => bridge.setSmoothingParam('smoothness_pitch', _smoothnessPitch));
    send(() => bridge.setSmoothingParam('smoothness_yaw', _smoothnessYaw));
    send(() => bridge.setSmoothingParam('smoothness_roll', _smoothnessRoll));
    send(() => bridge.setSmoothingParam('per_axis', _perAxis ? 1.0 : 0.0));
    send(() => bridge.setSmoothingParam('trim_range_only', _trimRangeOnly ? 1.0 : 0.0));
    send(() => bridge.setSmoothingParam('max_smoothness', _maxSmoothnessSec));
    send(() => bridge.setSmoothingParam('alpha_0_1s', _alphaHighVelSec));
    send(() => bridge.setSmoothingParam('time_constant', _plain3dTimeConstant));
    send(() => bridge.setSmoothingParam('pitch', _fixedPitch));
    send(() => bridge.setSmoothingParam('yaw', _fixedYaw));
    send(() => bridge.setSmoothingParam('roll', _fixedRoll));
    pushHorizonLock();
    send(() => bridge.setMaxZoom(_maxZoomPercent, _maxZoomIterations));
    pushAdaptiveZoom();
    send(() => bridge.setLensCorrection(_lensCorrection));
    send(() => bridge.setFov(_fov));
    send(() => bridge.setZoomingMethod(_zoomingMethod));
    send(() => bridge.setFrameReadoutTime(_rsCorrection ? _frameReadoutMs : 0.0));
    send(() => bridge.setFrameReadoutDirection(_frameReadoutDirection));
    send(() => bridge.setAdditionalRotation(_addPitch, _addYaw, _addRoll));
    pushVideoSpeed();
    if (_outputWidth > 0 && _outputHeight > 0) {
      send(() => bridge.setOutputSizeExact(_outputWidth, _outputHeight));
    }
    pushBackgroundColor();
    send(() => bridge.setBackgroundMode(_backgroundMode));
    send(() => bridge.setShowSafeArea(_showSafeArea));
    send(() => bridge.setShowDetectedFeatures(_showDetectedFeatures));
    send(() => bridge.setShowOpticalFlow(_showOpticalFlow));
    await _runRecompute();
  }

  @override
  void dispose() {
    _disposed = true;
    _recomputeTimer?.cancel();
    super.dispose();
  }
}
