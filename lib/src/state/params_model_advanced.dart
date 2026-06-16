part of 'params_model.dart';

/// 高级组 + 同步组 + 导出组参数。同库 part:extension 直接读写主类私有字段
/// _x,用 notify() 通知。权威分类镜像 ios/Sources/ParamsModel.m:
/// - bg 4 通道 → pushBackgroundColor + recompute
/// - backgroundMode / showSafeArea / imuLpfHz → 接 FFI + recompute
/// - showDetectedFeatures / showOpticalFlow → 接 FFI 但不 recompute(绘制标志)
/// - outputSize → 无 Controller 回调,走 setOutputSizeExact 兜底(仅 w,h>0)+ recompute
/// - previewResolutionHeight / gyroOffsetMs / 同步算法参数 / 导出参数 → 只存值 + notify
extension ParamsModelAdvanced on ParamsModel {
  // ---- getter(直读 _x)----
  int get outputWidth => _outputWidth;
  int get outputHeight => _outputHeight;
  double get bgR => _bgR;
  double get bgG => _bgG;
  double get bgB => _bgB;
  double get bgA => _bgA;
  int get backgroundMode => _backgroundMode;
  bool get showSafeArea => _showSafeArea;
  bool get showDetectedFeatures => _showDetectedFeatures;
  bool get showOpticalFlow => _showOpticalFlow;
  int get previewResolutionHeight => _previewResolutionHeight;
  double get imuLpfHz => _imuLpfHz;
  bool get autosyncEnabled => _autosyncEnabled;
  double get gyroOffsetMs => _gyroOffsetMs;
  double get syncSearchSizeSec => _syncSearchSizeSec;
  int get maxSyncPoints => _maxSyncPoints;
  int get everyNthFrame => _everyNthFrame;
  double get timePerSyncpointSec => _timePerSyncpointSec;
  int get syncProcessingHeight => _syncProcessingHeight;
  int get ofMethod => _ofMethod;
  int get poseMethod => _poseMethod;
  int get offsetMethod => _offsetMethod;
  bool get checkNegativeInitialOffset => _checkNegativeInitialOffset;
  bool get calcInitialFast => _calcInitialFast;
  bool get autoSyncPointsExperimental => _autoSyncPointsExperimental;
  int get exportCodecIndex => _exportCodecIndex;
  int get exportBitrateMbps => _exportBitrateMbps;
  bool get useGpuEncoding => _useGpuEncoding;
  bool get exportAudio => _exportAudio;

  // ---- 接 FFI 的高级项 ----
  // bg 4 通道:各自 clamp(colorChannel)→ 共推 pushBackgroundColor + recompute(无去重,镜像 .m)。
  set bgR(double v) => _setBg(() => _bgR = ParamsRange.colorChannel(v));
  set bgG(double v) => _setBg(() => _bgG = ParamsRange.colorChannel(v));
  set bgB(double v) => _setBg(() => _bgB = ParamsRange.colorChannel(v));
  set bgA(double v) => _setBg(() => _bgA = ParamsRange.colorChannel(v));

  void _setBg(void Function() apply) {
    apply();
    pushBackgroundColor();
    armRecompute();
    notify();
  }

  set backgroundMode(int v) {
    final c = ParamsRange.backgroundMode(v);
    if (c == _backgroundMode) return;
    _backgroundMode = c;
    send(() => bridge.setBackgroundMode(c));
    armRecompute();
    notify();
  }

  set showSafeArea(bool v) {
    if (v == _showSafeArea) return;
    _showSafeArea = v;
    send(() => bridge.setShowSafeArea(v));
    armRecompute();
    notify();
  }

  // 绘制标志:推 FFI 但不 recompute(镜像 .m setShowDetectedFeatures/setShowOpticalFlow)。
  set showDetectedFeatures(bool v) {
    if (v == _showDetectedFeatures) return;
    _showDetectedFeatures = v;
    send(() => bridge.setShowDetectedFeatures(v));
    notify();
  }

  set showOpticalFlow(bool v) {
    if (v == _showOpticalFlow) return;
    _showOpticalFlow = v;
    send(() => bridge.setShowOpticalFlow(v));
    notify();
  }

  set imuLpfHz(double v) {
    final c = ParamsRange.imuLpfHz(v);
    if (c == _imuLpfHz) return;
    _imuLpfHz = c;
    send(() => bridge.setImuLpf(c));
    armRecompute();
    notify();
  }

  /// 输出尺寸(导出/逻辑尺寸)。S7 无 Controller 回调,走 setOutputSizeExact 兜底,
  /// 仅 w,h>0 时推 FFI + recompute;值总是写入并 notify。
  void setOutputSize(int width, int height) {
    _outputWidth = width;
    _outputHeight = height;
    if (width > 0 && height > 0) {
      send(() => bridge.setOutputSizeExact(width, height));
      armRecompute();
    }
    notify();
  }

  // ---- 不接 FFI、不 recompute:只存值 + notify ----
  set previewResolutionHeight(int v) => _storeOnlyInt(
      ParamsRange.previewResolutionHeight(v), _previewResolutionHeight,
      (c) => _previewResolutionHeight = c);

  set gyroOffsetMs(double v) => _storeOnlyDouble(
      ParamsRange.gyroOffsetMs(v), _gyroOffsetMs, (c) => _gyroOffsetMs = c);

  set autosyncEnabled(bool v) =>
      _storeOnlyBool(v, _autosyncEnabled, (c) => _autosyncEnabled = c);
  set checkNegativeInitialOffset(bool v) => _storeOnlyBool(
      v, _checkNegativeInitialOffset, (c) => _checkNegativeInitialOffset = c);
  set calcInitialFast(bool v) =>
      _storeOnlyBool(v, _calcInitialFast, (c) => _calcInitialFast = c);
  set autoSyncPointsExperimental(bool v) => _storeOnlyBool(
      v, _autoSyncPointsExperimental, (c) => _autoSyncPointsExperimental = c);
  set useGpuEncoding(bool v) =>
      _storeOnlyBool(v, _useGpuEncoding, (c) => _useGpuEncoding = c);
  set exportAudio(bool v) =>
      _storeOnlyBool(v, _exportAudio, (c) => _exportAudio = c);

  set syncSearchSizeSec(double v) => _storeOnlyDouble(
      ParamsRange.syncSearchSizeSec(v), _syncSearchSizeSec,
      (c) => _syncSearchSizeSec = c);
  set timePerSyncpointSec(double v) => _storeOnlyDouble(
      ParamsRange.timePerSyncpointSec(v), _timePerSyncpointSec,
      (c) => _timePerSyncpointSec = c);

  set maxSyncPoints(int v) => _storeOnlyInt(
      ParamsRange.maxSyncPoints(v), _maxSyncPoints, (c) => _maxSyncPoints = c);
  set everyNthFrame(int v) => _storeOnlyInt(
      ParamsRange.everyNthFrame(v), _everyNthFrame, (c) => _everyNthFrame = c);
  // syncProcessingHeight 无对应区间,不 clamp。
  set syncProcessingHeight(int v) => _storeOnlyInt(
      v, _syncProcessingHeight, (c) => _syncProcessingHeight = c);
  set ofMethod(int v) =>
      _storeOnlyInt(ParamsRange.ofMethod(v), _ofMethod, (c) => _ofMethod = c);
  set poseMethod(int v) => _storeOnlyInt(
      ParamsRange.poseMethod(v), _poseMethod, (c) => _poseMethod = c);
  set offsetMethod(int v) => _storeOnlyInt(
      ParamsRange.offsetMethod(v), _offsetMethod, (c) => _offsetMethod = c);
  set exportCodecIndex(int v) => _storeOnlyInt(
      v, _exportCodecIndex, (c) => _exportCodecIndex = c);
  set exportBitrateMbps(int v) => _storeOnlyInt(
      v < 0 ? 0 : v, _exportBitrateMbps, (c) => _exportBitrateMbps = c);

  void _storeOnlyBool(bool v, bool cur, void Function(bool) setField) {
    if (v == cur) return;
    setField(v);
    notify();
  }

  void _storeOnlyDouble(double v, double cur, void Function(double) setField) {
    if (v == cur) return;
    setField(v);
    notify();
  }

  void _storeOnlyInt(int v, int cur, void Function(int) setField) {
    if (v == cur) return;
    setField(v);
    notify();
  }
}
