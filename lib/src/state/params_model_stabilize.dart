part of 'params_model.dart';

/// 稳定组参数(smoothing 系列 + 地平线 9 参聚合 + plain3d/fixed/高级)。
/// 同库 part:extension 直接读写主类私有字段 _x,用 notify() 通知。
extension ParamsModelStabilize on ParamsModel {
  int get smoothingMethod => _smoothingMethod;
  bool get perAxis => _perAxis;
  double get smoothnessPitch => _smoothnessPitch;
  double get smoothnessYaw => _smoothnessYaw;
  double get smoothnessRoll => _smoothnessRoll;
  bool get horizonLock => _horizonLock;
  double get horizonLockAmount => _horizonLockAmount;
  double get horizonLockRoll => _horizonLockRoll;
  bool get horizonLockPitchEnabled => _horizonLockPitchEnabled;
  double get horizonLockPitch => _horizonLockPitch;
  bool get automaticHorizonLock => _automaticHorizonLock;
  double get turnThreshold => _turnThreshold;
  double get turnSmoothingMs => _turnSmoothingMs;
  double get turnMultiplier => _turnMultiplier;
  double get tiltAccelLimit => _tiltAccelLimit;
  double get plain3dTimeConstant => _plain3dTimeConstant;
  double get fixedPitch => _fixedPitch;
  double get fixedYaw => _fixedYaw;
  double get fixedRoll => _fixedRoll;
  bool get trimRangeOnly => _trimRangeOnly;
  double get maxSmoothnessSec => _maxSmoothnessSec;
  double get alphaHighVelSec => _alphaHighVelSec;

  set smoothingMethod(int v) {
    final c = ParamsRange.smoothingMethod(v);
    if (c == _smoothingMethod) return;
    _smoothingMethod = c;
    send(() => bridge.setSmoothingMethod(c));
    armRecompute();
    notify();
  }

  set perAxis(bool v) {
    if (v == _perAxis) return;
    _perAxis = v;
    send(() => bridge.setSmoothingParam('per_axis', v ? 1.0 : 0.0));
    armRecompute();
    notify();
  }

  set smoothnessPitch(double v) => _setSmoothingDouble(
      v, ParamsRange.smoothness, 'smoothness_pitch', (c) => _smoothnessPitch = c);
  set smoothnessYaw(double v) => _setSmoothingDouble(
      v, ParamsRange.smoothness, 'smoothness_yaw', (c) => _smoothnessYaw = c);
  set smoothnessRoll(double v) => _setSmoothingDouble(
      v, ParamsRange.smoothness, 'smoothness_roll', (c) => _smoothnessRoll = c);
  set plain3dTimeConstant(double v) => _setSmoothingDouble(v,
      ParamsRange.plain3dTimeConstant, 'time_constant', (c) => _plain3dTimeConstant = c);
  set fixedPitch(double v) =>
      _setSmoothingDouble(v, (x) => x, 'pitch', (c) => _fixedPitch = c);
  set fixedYaw(double v) =>
      _setSmoothingDouble(v, (x) => x, 'yaw', (c) => _fixedYaw = c);
  set fixedRoll(double v) =>
      _setSmoothingDouble(v, (x) => x, 'roll', (c) => _fixedRoll = c);
  set maxSmoothnessSec(double v) => _setSmoothingDouble(
      v, ParamsRange.maxSmoothnessSec, 'max_smoothness', (c) => _maxSmoothnessSec = c);
  set alphaHighVelSec(double v) => _setSmoothingDouble(
      v, ParamsRange.alphaHighVelSec, 'alpha_0_1s', (c) => _alphaHighVelSec = c);

  set trimRangeOnly(bool v) {
    if (v == _trimRangeOnly) return;
    _trimRangeOnly = v;
    send(() => bridge.setSmoothingParam('trim_range_only', v ? 1.0 : 0.0));
    armRecompute();
    notify();
  }

  void _setSmoothingDouble(double v, double Function(double) clamp, String key,
      void Function(double) setField) {
    final c = clamp(v);
    setField(c);
    send(() => bridge.setSmoothingParam(key, c));
    armRecompute();
    notify();
  }

  // 地平线主开关 + amount + roll + 7 高级项:都走 pushHorizonLock。
  // 高级项仅 horizonLock ON 时推 FFI + recompute(镜像 .m _pushHorizonAdvanced)。
  set horizonLock(bool v) {
    if (v == _horizonLock) return;
    _horizonLock = v;
    pushHorizonLock();
    armRecompute();
    notify();
  }

  set horizonLockAmount(double v) =>
      _setHorizonAdvanced(() => _horizonLockAmount = ParamsRange.horizonLockAmount(v));
  set horizonLockRoll(double v) =>
      _setHorizonAdvanced(() => _horizonLockRoll = ParamsRange.horizonLockRoll(v));
  set horizonLockPitchEnabled(bool v) =>
      _setHorizonAdvanced(() => _horizonLockPitchEnabled = v);
  set horizonLockPitch(double v) =>
      _setHorizonAdvanced(() => _horizonLockPitch = ParamsRange.horizonLockPitch(v));
  set automaticHorizonLock(bool v) =>
      _setHorizonAdvanced(() => _automaticHorizonLock = v);
  set turnThreshold(double v) =>
      _setHorizonAdvanced(() => _turnThreshold = ParamsRange.turnThreshold(v));
  set turnSmoothingMs(double v) =>
      _setHorizonAdvanced(() => _turnSmoothingMs = ParamsRange.turnSmoothingMs(v));
  set turnMultiplier(double v) =>
      _setHorizonAdvanced(() => _turnMultiplier = ParamsRange.turnMultiplier(v));
  set tiltAccelLimit(double v) =>
      _setHorizonAdvanced(() => _tiltAccelLimit = ParamsRange.tiltAccelLimit(v));

  void _setHorizonAdvanced(void Function() apply) {
    apply();
    if (_horizonLock) {
      pushHorizonLock();
      armRecompute();
    }
    notify();
  }
}
