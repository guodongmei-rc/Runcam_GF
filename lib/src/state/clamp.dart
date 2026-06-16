/// 数值参数 clamp 工具 + 各参数区间。区间来源:ios/Sources/ParamsModel.h 注释。
double clampD(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);
int clampI(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

class ParamsRange {
  ParamsRange._();

  // 同步组
  static double gyroOffsetMs(double v) => clampD(v, -60000.0, 60000.0); // ±60s
  static double syncSearchSizeSec(double v) => clampD(v, 0.1, 60.0);
  static int maxSyncPoints(int v) => clampI(v, 1, 30);
  static int everyNthFrame(int v) => clampI(v, 1, 100);
  static double timePerSyncpointSec(double v) => clampD(v, 0.01, 10.0);
  static int ofMethod(int v) => clampI(v, 0, 2);
  static int poseMethod(int v) => clampI(v, 0, 3);
  static int offsetMethod(int v) => clampI(v, 0, 2);
  static double imuLpfHz(double v) => clampD(v, 0.0, 500.0);

  // 稳定组
  static int smoothingMethod(int v) => clampI(v, 0, 3);
  static double smoothness(double v) => clampD(v, 0.001, 1.0);
  static double horizonLockAmount(double v) => clampD(v, 0.0, 100.0);
  static double horizonLockRoll(double v) => clampD(v, -180.0, 180.0);
  static double horizonLockPitch(double v) => clampD(v, -90.0, 90.0);
  static double turnThreshold(double v) => v < 0 ? 0.0 : v;
  static double turnSmoothingMs(double v) => v < 0 ? 0.0 : v;
  static double turnMultiplier(double v) => v < 0 ? 0.0 : v;
  static double tiltAccelLimit(double v) => v < 0 ? 0.0 : v;
  static double plain3dTimeConstant(double v) => v < 0 ? 0.0 : v;
  static double maxSmoothnessSec(double v) => clampD(v, 0.1, 5.0);
  static double alphaHighVelSec(double v) => clampD(v, 0.01, 1.0);

  // 缩放组
  static double maxZoomPercent(double v) => clampD(v, 100.0, 300.0);
  static int maxZoomIterations(int v) => clampI(v, 1, 15);
  static double adaptiveZoomSec(double v) => clampD(v, 0.0, 10.0);
  static double lensCorrection(double v) => clampD(v, 0.0, 1.0);
  static double fov(double v) => clampD(v, 0.3, 3.0);
  static int croppingMode(int v) => clampI(v, 0, 2);
  static int zoomingMethod(int v) => clampI(v, 0, 1);
  static double frameReadoutMs(double v) => clampD(v, 0.0, 50.0);
  static int frameReadoutDirection(int v) => clampI(v, 0, 3);
  static double addRotationDeg(double v) => clampD(v, -180.0, 180.0); // addPitch/Yaw/Roll 共用
  static double videoSpeed(double v) => v < 0.0001 ? 0.0001 : v; // .m 下限 0.0001

  // 高级组
  static double colorChannel(double v) => clampD(v, 0.0, 1.0); // bgR/G/B/A 共用
  static int backgroundMode(int v) => clampI(v, 0, 3);
  static int previewResolutionHeight(int v) => v < 0 ? 0 : v;
}
