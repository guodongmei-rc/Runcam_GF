part of 'params_model.dart';

/// 缩放组参数(maxZoom / adaptiveZoom / croppingMode 映射 / fov / lens /
/// rs+readout 聚合 / addRotation 聚合 / videoSpeed 聚合)。
/// 同库 part:extension 直接读写主类私有字段 _x,用 notify() 通知。
extension ParamsModelZoom on ParamsModel {
  double get maxZoomPercent => _maxZoomPercent;
  int get maxZoomIterations => _maxZoomIterations;
  double get adaptiveZoomSec => _adaptiveZoomSec;
  double get lensCorrection => _lensCorrection;
  double get fov => _fov;
  int get croppingMode => _croppingMode;
  int get zoomingMethod => _zoomingMethod;
  bool get rsCorrection => _rsCorrection;
  double get frameReadoutMs => _frameReadoutMs;
  int get frameReadoutDirection => _frameReadoutDirection;
  double get addPitch => _addPitch;
  double get addYaw => _addYaw;
  double get addRoll => _addRoll;
  double get videoSpeed => _videoSpeed;
  bool get videoSpeedAffectsSmoothing => _videoSpeedAffectsSmoothing;
  bool get videoSpeedAffectsZooming => _videoSpeedAffectsZooming;
  bool get videoSpeedAffectsZoomingLimit => _videoSpeedAffectsZoomingLimit;

  // maxZoomPercent/Iterations 共推 setMaxZoom(percent, iterations)。
  set maxZoomPercent(double v) {
    final c = ParamsRange.maxZoomPercent(v);
    if (c == _maxZoomPercent) return;
    _maxZoomPercent = c;
    send(() => bridge.setMaxZoom(c, _maxZoomIterations));
    armRecompute();
    notify();
  }

  set maxZoomIterations(int v) {
    final c = ParamsRange.maxZoomIterations(v);
    if (c == _maxZoomIterations) return;
    _maxZoomIterations = c;
    send(() => bridge.setMaxZoom(_maxZoomPercent, c));
    armRecompute();
    notify();
  }

  // adaptiveZoomSec:仅 croppingMode==1 时推 setAdaptiveZoom,但任何时候都 recompute。
  set adaptiveZoomSec(double v) {
    final c = ParamsRange.adaptiveZoomSec(v);
    if (c == _adaptiveZoomSec) return;
    _adaptiveZoomSec = c;
    if (_croppingMode == 1) {
      send(() => bridge.setAdaptiveZoom(c)); // 仅动态缩放模式生效
    }
    armRecompute();
    notify();
  }

  // croppingMode:调聚合 helper pushAdaptiveZoom 推映射后的 adaptive_zoom。
  set croppingMode(int v) {
    final c = ParamsRange.croppingMode(v);
    if (c == _croppingMode) return;
    _croppingMode = c;
    pushAdaptiveZoom();
    armRecompute();
    notify();
  }

  set lensCorrection(double v) {
    final c = ParamsRange.lensCorrection(v);
    if (c == _lensCorrection) return;
    _lensCorrection = c;
    send(() => bridge.setLensCorrection(c));
    armRecompute();
    notify();
  }

  set fov(double v) {
    final c = ParamsRange.fov(v);
    if (c == _fov) return;
    _fov = c;
    send(() => bridge.setFov(c));
    armRecompute();
    notify();
  }

  set zoomingMethod(int v) {
    final c = ParamsRange.zoomingMethod(v);
    if (c == _zoomingMethod) return;
    _zoomingMethod = c;
    send(() => bridge.setZoomingMethod(c));
    armRecompute();
    notify();
  }

  // rsCorrection / frameReadoutMs 共推 setFrameReadoutTime(rs ? ms : 0.0)。
  set rsCorrection(bool v) {
    if (v == _rsCorrection) return;
    _rsCorrection = v;
    send(() => bridge.setFrameReadoutTime(v ? _frameReadoutMs : 0.0));
    armRecompute();
    notify();
  }

  set frameReadoutMs(double v) {
    final c = ParamsRange.frameReadoutMs(v);
    if (c == _frameReadoutMs) return;
    _frameReadoutMs = c;
    if (_rsCorrection) {
      send(() => bridge.setFrameReadoutTime(c)); // 仅 RS 校正开启时生效
    }
    armRecompute();
    notify();
  }

  set frameReadoutDirection(int v) {
    final c = ParamsRange.frameReadoutDirection(v);
    if (c == _frameReadoutDirection) return;
    _frameReadoutDirection = c;
    send(() => bridge.setFrameReadoutDirection(c));
    armRecompute();
    notify();
  }

  // addPitch/Yaw/Roll 共推 setAdditionalRotation(pitch, yaw, roll)。镜像 .m:无去重。
  set addPitch(double v) =>
      _setAddRotation(() => _addPitch = ParamsRange.addRotationDeg(v));
  set addYaw(double v) =>
      _setAddRotation(() => _addYaw = ParamsRange.addRotationDeg(v));
  set addRoll(double v) =>
      _setAddRotation(() => _addRoll = ParamsRange.addRotationDeg(v));

  void _setAddRotation(void Function() apply) {
    apply();
    send(() => bridge.setAdditionalRotation(_addPitch, _addYaw, _addRoll));
    armRecompute();
    notify();
  }

  // videoSpeed + 3 联动开关共推 pushVideoSpeed。videoSpeed clamp 下限 0.0001。
  set videoSpeed(double v) {
    final c = ParamsRange.videoSpeed(v);
    if (c == _videoSpeed) return;
    _videoSpeed = c;
    pushVideoSpeed();
    armRecompute();
    notify();
  }

  // 联动开关镜像 .m:无去重。
  set videoSpeedAffectsSmoothing(bool v) =>
      _setVideoSpeedFlag(() => _videoSpeedAffectsSmoothing = v);
  set videoSpeedAffectsZooming(bool v) =>
      _setVideoSpeedFlag(() => _videoSpeedAffectsZooming = v);
  set videoSpeedAffectsZoomingLimit(bool v) =>
      _setVideoSpeedFlag(() => _videoSpeedAffectsZoomingLimit = v);

  void _setVideoSpeedFlag(void Function() apply) {
    apply();
    pushVideoSpeed();
    armRecompute();
    notify();
  }
}
