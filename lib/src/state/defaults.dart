/// ParamsModel 各参数默认值。誊写自原生 ParamsModel.m init()(已随原生 UI 删除,
/// 历史版本:git show 3b3c53e^:ios/Sources/ParamsModel.m);本文件即当前事实源。
class ParamsDefaults {
  ParamsDefaults._();

  // 同步组(autosync 算法参数 + 仅 imuLpf 接 FFI)
  static const bool autosyncEnabled = false;
  static const double gyroOffsetMs = 0.0;
  static const double syncSearchSizeSec = 5.0;
  static const int maxSyncPoints = 3;
  static const int everyNthFrame = 1;
  static const double timePerSyncpointSec = 1.5;
  static const int syncProcessingHeight = 720;
  static const int ofMethod = 2;
  static const int poseMethod = 0;
  static const int offsetMethod = 2;
  static const double imuLpfHz = 0.0;
  static const bool showDetectedFeatures = false;
  static const bool showOpticalFlow = false;
  static const bool checkNegativeInitialOffset = false;
  static const bool calcInitialFast = false;
  static const bool autoSyncPointsExperimental = false; // .m=NO(.h 注释写 YES,以 .m 为准)

  // 稳定组
  static const int smoothingMethod = 1;
  static const double smoothness = 0.5;
  static const bool perAxis = false;
  static const double smoothnessPitch = 0.5;
  static const double smoothnessYaw = 0.5;
  static const double smoothnessRoll = 0.5;
  static const bool horizonLock = false;
  static const double horizonLockAmount = 100.0;
  static const double horizonLockRoll = 0.0;
  static const bool horizonLockPitchEnabled = false;
  static const double horizonLockPitch = 0.0;
  static const bool automaticHorizonLock = false;
  static const double turnThreshold = 0.0;
  static const double turnSmoothingMs = 0.0;
  static const double turnMultiplier = 1.0;
  static const double tiltAccelLimit = 0.0;
  static const double plain3dTimeConstant = 0.25; // .m=0.25(.h 注释写 0.5,以 .m 为准)
  static const double fixedPitch = 0.0;
  static const double fixedYaw = 0.0;
  static const double fixedRoll = 0.0;
  static const bool trimRangeOnly = true;
  static const double maxSmoothnessSec = 1.0;
  static const double alphaHighVelSec = 0.1;

  // 缩放组
  static const double maxZoomPercent = 130.0;
  static const int maxZoomIterations = 5;
  static const double adaptiveZoomSec = 4.0;
  static const double lensCorrection = 1.0;
  static const double fov = 1.0;
  static const int croppingMode = 1;
  static const int zoomingMethod = 1;
  static const bool rsCorrection = true;
  static const double frameReadoutMs = 11.11;
  static const int frameReadoutDirection = 0;
  static const double addPitch = 0.0;
  static const double addYaw = 0.0;
  static const double addRoll = 0.0;
  static const double videoSpeed = 1.0;
  static const bool videoSpeedAffectsSmoothing = true;
  static const bool videoSpeedAffectsZooming = true;
  static const bool videoSpeedAffectsZoomingLimit = true;

  // 高级组
  static const int outputWidth = 0; // CGSizeZero → 不主动推 FFI
  static const int outputHeight = 0;
  static const double bgR = 17.0 / 255.0; // #111111(.m;.h 注释写 0,以 .m 为准)
  static const double bgG = 17.0 / 255.0;
  static const double bgB = 17.0 / 255.0;
  static const double bgA = 1.0;
  static const int backgroundMode = 0;
  static const bool showSafeArea = false;
  static const int previewResolutionHeight = 0;

  // 导出组(不接 FFI)
  static const int exportCodecIndex = 1;
  static const int exportBitrateMbps = 63; // .m=63(.h 注释写 0,以 .m 为准)
  static const bool useGpuEncoding = true;
  static const bool exportAudio = true;
}
