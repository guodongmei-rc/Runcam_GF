# S7 + S8:Dart ParamsModel 状态层 + smoke 验收 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `ios/Sources/ParamsModel.h/.m` 的全量参数搬成 Dart `ParamsModel`(ChangeNotifier),每个 setter 完成「clamp→立即推引擎→200ms 合并防抖→recomputeBlocking→回填只读输出」,并用 example 临时按钮在两端真机跑通 smoke。

**Architecture:** `ParamsModel` 仅依赖抽象 `EngineBridge`(参数写子集 + recompute);真实跑由 `EngineBridgeImpl` 包生成的 `EngineApi`(`lib/src/bridge/engine_api.g.dart`),单测由手写 `FakeEngineBridge` 替身。参数值/默认/clamp 以 **`ParamsModel.m` 为权威**(其默认值数处与 `.h` 注释不一致)。

**Tech Stack:** Flutter / Dart(纯 Dart 状态层,无第三方状态库)、Pigeon 生成桥、`flutter_test`(用真实 `Future.delayed` 推进防抖,不引入 `fake_async`)、example 用 `image_picker` 选样片(dev-only)。

---

## 前置说明

- **项目当前不是 git 仓库**。若要按计划逐步 commit,先在项目根 `git init`;否则把每个「Commit」步当作**检查点**:运行 `flutter analyze` + 相关测试,绿了再继续。本计划的 commit 步给出 message 供 `git init` 后使用。
- **权威源**:setter 的 FFI 调用与默认值**镜像 `ios/Sources/ParamsModel.m`**;clamp 区间取 `ParamsModel.h` 注释。两者冲突时(默认值)以 `.m` 为准。
- **不动**:`engine_api.g.dart`(生成物)、`gyroflow_ffi.h`、`GyroflowNative.kt`、所有原生 UI、旧 `open()`。

## 文件结构

| 文件 | 职责 |
|---|---|
| `lib/src/state/engine_bridge.dart` | abstract `EngineBridge`:ParamsModel 唯一依赖的引擎接口(写子集 + recompute);复用 `engine_api.g.dart` 的 `VideoInfo`/`StabInfo` |
| `lib/src/state/engine_bridge_impl.dart` | `EngineBridgeImpl implements EngineBridge`:每方法 1:1 转发到生成的 `EngineApi` |
| `lib/src/state/defaults.dart` | `kParamsDefaults`:每参数默认值常量(取自 `.m`) |
| `lib/src/state/clamp.dart` | clamp 工具 + 每参数区间常量(取自 `.h`) |
| `lib/src/state/params_model.dart` | 主类:字段、防抖/回填核心、`dispose`、`pushAllDefaultsAndRecompute`、内部推送 helper |
| `lib/src/state/params_model_stabilize.dart` | extension:稳定组 setter(smoothing/horizon/plain3d/fixed/高级) |
| `lib/src/state/params_model_zoom.dart` | extension:缩放组 setter(maxZoom/adaptiveZoom/croppingMode/fov/lens/rs/readout/addRotation/videoSpeed) |
| `lib/src/state/params_model_advanced.dart` | extension:高级组 setter(outputSize/bg/safeArea/detected/of/previewRes)+ 同步组 + 导出组(只存值) |
| `lib/runcam_gf.dart` | 导出 `EngineBridge`/`EngineBridgeImpl`/`ParamsModel`(公共 API) |
| `test/params_model_test.dart` | FakeEngineBridge + 真实延时验证 |
| `example/lib/main.dart` | 加临时「Run Engine Smoke」按钮 |
| `example/pubspec.yaml` | 加 `image_picker`(dev smoke 选样片) |

---

## ⚠️ 代码组织约定(part + extension)—— 覆盖各 Task 的旧结构细节

> **背景**:原计划「getter 在主类、同名 setter 在 extension」**在 Dart 编译不过**——类的实例 getter 会屏蔽扩展的同名 setter(`assignment_to_final_no_setter`)。本节是权威约定,**凡 Task 7/8/9 里出现的 `getXxxField()/setXxxField()` 存取器、`@protected`、以及 `import 'package:runcam_gf/src/state/params_model_*.dart'` 行,一律以本节为准替换/删除**。每参数的「clamp 用哪个、推哪个 bridge 方法、是否 recompute、如何聚合」仍以各 Task 正文的语义为准。

**核心:`lib/src/state/` 的 5 个 state 文件组成同一个 library(用 `part`)**,因此 extension 能**直接读写**类的私有字段 `_x`,无需任何存取器。

`params_model.dart`(library 根)结构:
```dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'defaults.dart';
import 'clamp.dart';
import 'engine_bridge.dart';

part 'params_model_stabilize.dart';
part 'params_model_zoom.dart';
part 'params_model_advanced.dart';

class ParamsModel extends ChangeNotifier {
  ParamsModel(this.bridge);
  final EngineBridge bridge;            // 不加 @protected(库内成员,part extension 要用)
  // ... debounce / _recomputeTimer / _disposed ...
  // ... 全部组的私有字段 _x(声明在这里)...
  // ... 只读输出 getter(maxAngle*/minFov)...
  // ... 聚合 helper:pushHorizonLock / pushAdaptiveZoom / pushVideoSpeed / pushBackgroundColor(不加 @protected)...
  // ... send / armRecompute / _runRecompute / dispose / pushAllDefaultsAndRecompute ...

  /// part extension 调它来通知(notifyListeners 是 @protected,扩展非子类不能直接调)。
  void notify() => notifyListeners();
}
```

各组文件(如 `params_model_stabilize.dart`)结构:
```dart
part of 'params_model.dart';

extension ParamsModelStabilize on ParamsModel {
  // 每个参数:public getter 直读 _x + public setter 直写 _x
  ...
}
```

**setter 四种模板**(直接操作 `_x`,用 `notify()` 不用 `notifyListeners()`):
```dart
// ① 带去重的数值/枚举 setter
int get smoothingMethod => _smoothingMethod;
set smoothingMethod(int v) {
  final c = ParamsRange.smoothingMethod(v);
  if (c == _smoothingMethod) return;
  _smoothingMethod = c;
  send(() => bridge.setSmoothingMethod(c));
  armRecompute();
  notify();
}

// ② bool setter(带去重)
bool get perAxis => _perAxis;
set perAxis(bool v) {
  if (v == _perAxis) return;
  _perAxis = v;
  send(() => bridge.setSmoothingParam('per_axis', v ? 1.0 : 0.0));
  armRecompute();
  notify();
}

// ③ 只存值 setter(不接 FFI、不 recompute)
int get exportBitrateMbps => _exportBitrateMbps;
set exportBitrateMbps(int v) {
  final c = v < 0 ? 0 : v;
  if (c == _exportBitrateMbps) return;
  _exportBitrateMbps = c;
  notify();
}

// ④ 聚合 setter(多个字段共推一个 bridge 方法,helper 在主类)
double get horizonLockRoll => _horizonLockRoll;
set horizonLockRoll(double v) {
  _horizonLockRoll = ParamsRange.horizonLockRoll(v);
  if (_horizonLock) { pushHorizonLock(); armRecompute(); }
  notify();
}
```

**测试**:`test/params_model_test.dart` 只需 `import 'package:runcam_gf/src/state/params_model.dart';`(及按需 `defaults.dart`)。part 里的 extension 随 library 自动可见,**不要**再 import `params_model_stabilize/zoom/advanced.dart`。

**Task 5 的 smoothness 现状**:getter+setter 都在主类、用 `notifyListeners()` 直调——合法(类内调 protected 没问题),保留不动。其余各组按本约定放进 part extension。

**Task 7 落地时,需对 Task 5 已建的 `params_model.dart` 做这些改造**:① 加 3 行 `part` 指令;② 给 `bridge`/`send`/`armRecompute`/`pushHorizonLock` 去掉 `@protected`;③ 加 `void notify() => notifyListeners();`;④ **删除**所有 `getXxxField()/setXxxField()` 存取器(改为 extension 直接读写 `_x`)。

---

## Task 1: EngineBridge 抽象接口

**Files:**
- Create: `lib/src/state/engine_bridge.dart`

- [ ] **Step 1: 写接口**

```dart
import '../bridge/engine_api.g.dart' show VideoInfo, StabInfo;

export '../bridge/engine_api.g.dart' show VideoInfo, StabInfo;

/// ParamsModel 唯一依赖的引擎接口。只收录 S7 用到的写方法 + recompute。
/// 真实实现 [EngineBridgeImpl] 转发到生成的 EngineApi;单测用 FakeEngineBridge。
abstract class EngineBridge {
  Future<void> createStabilizer();
  Future<void> freeStabilizer();
  Future<VideoInfo> openVideo(String uriOrPath);

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
```

- [ ] **Step 2: 验证编译**

Run: `cd /Users/gdm/Desktop/RuncamGF && flutter analyze lib/src/state/engine_bridge.dart`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add lib/src/state/engine_bridge.dart
git commit -m "feat(s7): EngineBridge abstract interface"
```

---

## Task 2: EngineBridgeImpl(转发到生成的 EngineApi)

**Files:**
- Create: `lib/src/state/engine_bridge_impl.dart`

- [ ] **Step 1: 写实现**

```dart
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
```

- [ ] **Step 2: 验证编译**

Run: `cd /Users/gdm/Desktop/RuncamGF && flutter analyze lib/src/state/`
Expected: No issues found.（若报缺 EngineApi 类,确认 `engine_api.g.dart` 存在)

- [ ] **Step 3: Commit**

```bash
git add lib/src/state/engine_bridge_impl.dart
git commit -m "feat(s7): EngineBridgeImpl forwards to EngineApi"
```

---

## Task 3: defaults.dart(默认值,取自 ParamsModel.m)

**Files:**
- Create: `lib/src/state/defaults.dart`

- [ ] **Step 1: 写默认值常量**

> 值逐条取自 `ParamsModel.m` 的 `init`(权威,数处与 `.h` 注释不同已修正)。

```dart
/// ParamsModel 各参数默认值。权威来源:ios/Sources/ParamsModel.m init()。
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
```

- [ ] **Step 2: 验证编译**

Run: `cd /Users/gdm/Desktop/RuncamGF && flutter analyze lib/src/state/defaults.dart`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add lib/src/state/defaults.dart
git commit -m "feat(s7): param defaults from ParamsModel.m"
```

---

## Task 4: clamp.dart(区间 + clamp 工具,取自 ParamsModel.h)

**Files:**
- Create: `lib/src/state/clamp.dart`

- [ ] **Step 1: 写 clamp 工具**

> 区间取自 `.h` 注释。无显式区间的(turn*/fixed*/plain3d 等)按物理含义给非负或不限。整数枚举按合法索引夹取。

```dart
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
```

- [ ] **Step 2: 验证编译**

Run: `cd /Users/gdm/Desktop/RuncamGF && flutter analyze lib/src/state/clamp.dart`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add lib/src/state/clamp.dart
git commit -m "feat(s7): param clamp ranges from ParamsModel.h"
```

---

## Task 5: ParamsModel 主类 + 首条 setter(smoothness)的防抖/回填测试(TDD)

**Files:**
- Create: `test/params_model_test.dart`
- Create: `lib/src/state/params_model.dart`

- [ ] **Step 1: 写失败测试(FakeEngineBridge + smoothness 防抖/回填)**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:runcam_gf/src/state/engine_bridge.dart';
import 'package:runcam_gf/src/state/params_model.dart';

/// 计数 + 可控返回的假桥。记录每个方法的调用。
class FakeEngineBridge implements EngineBridge {
  int recomputeCalls = 0;
  final List<List<Object?>> smoothingParamCalls = [];
  final List<List<Object?>> horizonLockCalls = [];
  final List<List<Object?>> adaptiveZoomCalls = [];
  bool recomputeShouldThrow = false;
  double minFovToReturn = 1.25;

  @override
  Future<StabInfo> recomputeBlocking() async {
    recomputeCalls++;
    if (recomputeShouldThrow) {
      throw StateError('boom');
    }
    return StabInfo(
        maxAnglePitch: 1.0, maxAngleYaw: 2.0, maxAngleRoll: 3.0, minFov: minFovToReturn);
  }

  @override
  Future<void> setSmoothingParam(String name, double value) async {
    smoothingParamCalls.add([name, value]);
  }

  @override
  Future<void> setHorizonLock(double a, double b, bool c, double d, bool e,
      double f, double g, double h, double i) async {
    horizonLockCalls.add([a, b, c, d, e, f, g, h, i]);
  }

  @override
  Future<void> setAdaptiveZoom(double windowSeconds) async {
    adaptiveZoomCalls.add([windowSeconds]);
  }

  // 其余方法本测试不校验,空实现即可。
  @override
  Future<void> createStabilizer() async {}
  @override
  Future<void> freeStabilizer() async {}
  @override
  Future<VideoInfo> openVideo(String uriOrPath) async => VideoInfo();
  @override
  Future<void> setImuLpf(double hz) async {}
  @override
  Future<void> setSmoothingMethod(int index) async {}
  @override
  Future<void> setMaxZoom(double percent, int iterations) async {}
  @override
  Future<void> setLensCorrection(double amount) async {}
  @override
  Future<void> setFov(double fov) async {}
  @override
  Future<void> setZoomingMethod(int index) async {}
  @override
  Future<void> setFrameReadoutTime(double ms) async {}
  @override
  Future<void> setFrameReadoutDirection(int dir) async {}
  @override
  Future<void> setAdditionalRotation(double p, double y, double r) async {}
  @override
  Future<void> setVideoSpeed(double s, bool a, bool b, bool c) async {}
  @override
  Future<void> setOutputSizeExact(int width, int height) async {}
  @override
  Future<void> setBackgroundColor(double r, double g, double b, double a) async {}
  @override
  Future<void> setBackgroundMode(int mode) async {}
  @override
  Future<void> setShowSafeArea(bool show) async {}
  @override
  Future<void> setShowDetectedFeatures(bool show) async {}
  @override
  Future<void> setShowOpticalFlow(bool show) async {}
}

void main() {
  // 防抖窗口 200ms;用略大于它的真实延时推进。
  const settle = Duration(milliseconds: 280);
  const within = Duration(milliseconds: 100);

  test('改 smoothness:200ms 内不 recompute,之后恰好 1 次并回填 minFov', () async {
    final fake = FakeEngineBridge()..minFovToReturn = 1.5;
    final model = ParamsModel(fake);

    model.smoothness = 0.7; // 不能用默认值 0.5,否则去重早返回、引擎不被调
    expect(fake.smoothingParamCalls, [
      ['smoothness', 0.7]
    ]);

    await Future<void>.delayed(within);
    expect(fake.recomputeCalls, 0, reason: '200ms 内不应 recompute');

    await Future<void>.delayed(settle);
    expect(fake.recomputeCalls, 1, reason: '防抖后恰好一次');
    expect(model.minFov, 1.5, reason: '回填 minFov');
    expect(model.maxAnglePitch, 1.0);

    model.dispose();
  });
}
```

- [ ] **Step 2: 运行测试,确认失败**

Run: `cd /Users/gdm/Desktop/RuncamGF && flutter test test/params_model_test.dart`
Expected: FAIL,报 `ParamsModel` 未定义 / 缺 `smoothness` setter。

- [ ] **Step 3: 写 ParamsModel 主类(核心 + smoothness)**

```dart
import 'dart:async';
import 'package:flutter/foundation.dart';

import 'defaults.dart';
import 'clamp.dart';
import 'engine_bridge.dart';

/// 参数面板的全量状态。每个 setter:clamp → 立即推引擎 → 200ms 合并防抖
/// → recomputeBlocking → 回填只读输出。权威逻辑镜像 ios/Sources/ParamsModel.m。
class ParamsModel extends ChangeNotifier {
  ParamsModel(this.bridge);

  @protected
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

  // ---- 内部 helper(供本类与各 extension 复用)----

  /// 立即推一次引擎调用,吞掉错误(阶段0+2 桥可能在未 createStabilizer 时被调)。
  @protected
  void send(Future<void> Function() op) {
    op().catchError((Object e) {
      debugPrint('[ParamsModel] engine push failed: $e');
    });
  }

  /// 复位共享防抖定时器;到点跑一次 recomputeBlocking 并回填。
  @protected
  void armRecompute() {
    _recomputeTimer?.cancel();
    _recomputeTimer = Timer(debounce, _runRecompute);
  }

  Future<void> _runRecompute() async {
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

  @override
  void dispose() {
    _disposed = true;
    _recomputeTimer?.cancel();
    super.dispose();
  }
}
```

- [ ] **Step 4: 运行测试,确认通过**

Run: `cd /Users/gdm/Desktop/RuncamGF && flutter test test/params_model_test.dart`
Expected: PASS(1 个测试)。

- [ ] **Step 5: Commit**

```bash
git add lib/src/state/params_model.dart test/params_model_test.dart
git commit -m "feat(s7): ParamsModel core (debounce+recompute) with smoothness"
```

---

## Task 6: 防抖合并 + clamp 测试

**Files:**
- Modify: `test/params_model_test.dart`(在 `main()` 内追加 test)

- [ ] **Step 1: 追加测试**

```dart
  test('连续改 3 次(间隔<200ms)只 recompute 一次', () async {
    final fake = FakeEngineBridge();
    final model = ParamsModel(fake);

    model.smoothness = 0.4;
    await Future<void>.delayed(within);
    model.smoothness = 0.5;
    await Future<void>.delayed(within);
    model.smoothness = 0.6;
    await Future<void>.delayed(settle);

    expect(fake.recomputeCalls, 1, reason: '防抖合并为一次');
    model.dispose();
  });

  test('clamp:smoothness 越界被夹', () {
    final model = ParamsModel(FakeEngineBridge());
    model.smoothness = 5.0;
    expect(model.smoothness, 1.0);
    model.smoothness = 0.0;
    expect(model.smoothness, 0.001);
    model.dispose();
  });
```

- [ ] **Step 2: 运行测试,确认通过**

Run: `cd /Users/gdm/Desktop/RuncamGF && flutter test test/params_model_test.dart`
Expected: PASS(3 个测试)。

- [ ] **Step 3: Commit**

```bash
git add test/params_model_test.dart
git commit -m "test(s7): debounce coalescing + clamp"
```

---

## Task 7: 稳定组 extension(smoothing 系列 + 地平线 9 参聚合 + plain3d/fixed/高级)

**Files:**
- Create: `lib/src/state/params_model_stabilize.dart`
- Modify: `lib/src/state/params_model.dart`(把稳定组字段从主类挪到此处不现实——改为:主类声明全部字段,extension 只放 setter。本 Task 在主类补稳定组其余字段,extension 放其 setter)

> **字段归属约定**:所有字段声明在 `params_model.dart` 主类(extension 不能加实例字段);各 extension 只放 setter 与私有推送 helper。Task 5 已建主类,以下字段**追加到主类**,setter 放 extension。

- [ ] **Step 1: 主类追加稳定组字段(加到 ParamsModel 类体内,smoothness 之后)**

```dart
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

  /// 地平线锁定 9 参一次性推送(镜像 ParamsModel.m applyHorizonLockToFFI)。
  /// horizonLock=OFF 时 amount 强制 0;pitch 未启用时 pitch 传 0。
  @protected
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
```

- [ ] **Step 2: 写 extension(setter)**

> 映射镜像 `ParamsModel.m`:smoothing 子参用 `setSmoothingParam(key, v)`;bool 转 1.0/0.0;地平线高级项仅 `horizonLock` ON 时才推+recompute。

```dart
import 'clamp.dart';
import 'params_model.dart';

extension ParamsModelStabilize on ParamsModel {
  set smoothingMethod(int v) {
    final c = ParamsRange.smoothingMethod(v);
    if (c == smoothingMethod) return;
    setSmoothingMethodField(c);
    send(() => bridge.setSmoothingMethod(c));
    armRecompute();
    notifyListeners();
  }

  set perAxis(bool v) {
    if (v == perAxis) return;
    setPerAxisField(v);
    send(() => bridge.setSmoothingParam('per_axis', v ? 1.0 : 0.0));
    armRecompute();
    notifyListeners();
  }

  set smoothnessPitch(double v) => _setSmoothingDouble(
      v, ParamsRange.smoothness, 'smoothness_pitch', setSmoothnessPitchField);
  set smoothnessYaw(double v) => _setSmoothingDouble(
      v, ParamsRange.smoothness, 'smoothness_yaw', setSmoothnessYawField);
  set smoothnessRoll(double v) => _setSmoothingDouble(
      v, ParamsRange.smoothness, 'smoothness_roll', setSmoothnessRollField);
  set plain3dTimeConstant(double v) => _setSmoothingDouble(
      v, ParamsRange.plain3dTimeConstant, 'time_constant', setPlain3dTimeConstantField);
  set fixedPitch(double v) =>
      _setSmoothingDouble(v, (x) => x, 'pitch', setFixedPitchField);
  set fixedYaw(double v) =>
      _setSmoothingDouble(v, (x) => x, 'yaw', setFixedYawField);
  set fixedRoll(double v) =>
      _setSmoothingDouble(v, (x) => x, 'roll', setFixedRollField);
  set maxSmoothnessSec(double v) => _setSmoothingDouble(
      v, ParamsRange.maxSmoothnessSec, 'max_smoothness', setMaxSmoothnessSecField);
  set alphaHighVelSec(double v) => _setSmoothingDouble(
      v, ParamsRange.alphaHighVelSec, 'alpha_0_1s', setAlphaHighVelSecField);

  set trimRangeOnly(bool v) {
    if (v == trimRangeOnly) return;
    setTrimRangeOnlyField(v);
    send(() => bridge.setSmoothingParam('trim_range_only', v ? 1.0 : 0.0));
    armRecompute();
    notifyListeners();
  }

  void _setSmoothingDouble(double v, double Function(double) clamp, String key,
      void Function(double) setField) {
    final c = clamp(v);
    setField(c);
    send(() => bridge.setSmoothingParam(key, c));
    armRecompute();
    notifyListeners();
  }

  // 地平线主开关 + amount + roll + 7 高级项:都走 pushHorizonLock。
  // 高级项仅 horizonLock ON 时推 FFI + recompute(镜像 .m _pushHorizonAdvanced)。
  set horizonLock(bool v) {
    if (v == horizonLock) return;
    setHorizonLockField(v);
    pushHorizonLock();
    armRecompute();
    notifyListeners();
  }

  set horizonLockAmount(double v) =>
      _setHorizonAdvanced(() => setHorizonLockAmountField(ParamsRange.horizonLockAmount(v)));
  set horizonLockRoll(double v) =>
      _setHorizonAdvanced(() => setHorizonLockRollField(ParamsRange.horizonLockRoll(v)));
  set horizonLockPitchEnabled(bool v) =>
      _setHorizonAdvanced(() => setHorizonLockPitchEnabledField(v));
  set horizonLockPitch(double v) =>
      _setHorizonAdvanced(() => setHorizonLockPitchField(ParamsRange.horizonLockPitch(v)));
  set automaticHorizonLock(bool v) =>
      _setHorizonAdvanced(() => setAutomaticHorizonLockField(v));
  set turnThreshold(double v) =>
      _setHorizonAdvanced(() => setTurnThresholdField(ParamsRange.turnThreshold(v)));
  set turnSmoothingMs(double v) =>
      _setHorizonAdvanced(() => setTurnSmoothingMsField(ParamsRange.turnSmoothingMs(v)));
  set turnMultiplier(double v) =>
      _setHorizonAdvanced(() => setTurnMultiplierField(ParamsRange.turnMultiplier(v)));
  set tiltAccelLimit(double v) =>
      _setHorizonAdvanced(() => setTiltAccelLimitField(ParamsRange.tiltAccelLimit(v)));

  void _setHorizonAdvanced(void Function() apply) {
    apply();
    if (horizonLock) {
      pushHorizonLock();
      armRecompute();
    }
    notifyListeners();
  }
}
```

- [ ] **Step 3: 主类补字段写入方法(extension 不能直接写私有字段,加 setter 方法到主类)**

> extension 无法访问其它库的私有字段;为让 extension 能改字段,在主类加包内可见的字段写入方法(命名 `setXxxField`)。追加到 `params_model.dart` 主类:

```dart
  // 供 extension 写字段(extension 不能访问私有 ivar)。
  void setSmoothingMethodField(int v) => _smoothingMethod = v;
  void setPerAxisField(bool v) => _perAxis = v;
  void setSmoothnessPitchField(double v) => _smoothnessPitch = v;
  void setSmoothnessYawField(double v) => _smoothnessYaw = v;
  void setSmoothnessRollField(double v) => _smoothnessRoll = v;
  void setHorizonLockField(bool v) => _horizonLock = v;
  void setHorizonLockAmountField(double v) => _horizonLockAmount = v;
  void setHorizonLockRollField(double v) => _horizonLockRoll = v;
  void setHorizonLockPitchEnabledField(bool v) => _horizonLockPitchEnabled = v;
  void setHorizonLockPitchField(double v) => _horizonLockPitch = v;
  void setAutomaticHorizonLockField(bool v) => _automaticHorizonLock = v;
  void setTurnThresholdField(double v) => _turnThreshold = v;
  void setTurnSmoothingMsField(double v) => _turnSmoothingMs = v;
  void setTurnMultiplierField(double v) => _turnMultiplier = v;
  void setTiltAccelLimitField(double v) => _tiltAccelLimit = v;
  void setPlain3dTimeConstantField(double v) => _plain3dTimeConstant = v;
  void setFixedPitchField(double v) => _fixedPitch = v;
  void setFixedYawField(double v) => _fixedYaw = v;
  void setFixedRollField(double v) => _fixedRoll = v;
  void setTrimRangeOnlyField(bool v) => _trimRangeOnly = v;
  void setMaxSmoothnessSecField(double v) => _maxSmoothnessSec = v;
  void setAlphaHighVelSecField(double v) => _alphaHighVelSec = v;
```

- [ ] **Step 4: 追加地平线 9 参聚合测试到 `test/params_model_test.dart`**

```dart
  test('地平线:改 roll(ON)推一次 9 参,amount 用当前值', () async {
    final fake = FakeEngineBridge();
    final model = ParamsModel(fake);
    model.horizonLock = true; // ON 后 amount=100
    fake.horizonLockCalls.clear();

    model.horizonLockRoll = 30.0;
    expect(fake.horizonLockCalls.length, 1);
    final call = fake.horizonLockCalls.single;
    expect(call[0], 100.0, reason: 'amount=horizonLockAmount(默认100)');
    expect(call[1], 30.0, reason: 'roll');
    expect(call.length, 9);
    await Future<void>.delayed(settle);
    model.dispose();
  });

  test('地平线:OFF 时改高级项不推 FFI', () {
    final fake = FakeEngineBridge();
    final model = ParamsModel(fake);
    fake.horizonLockCalls.clear();
    model.turnThreshold = 5.0; // OFF
    expect(fake.horizonLockCalls, isEmpty);
    expect(model.turnThreshold, 5.0, reason: '值仍存');
    model.dispose();
  });
```

需要在 `test/params_model_test.dart` 顶部加 `import 'package:runcam_gf/src/state/params_model_stabilize.dart';`。

- [ ] **Step 5: 运行测试,确认通过**

Run: `cd /Users/gdm/Desktop/RuncamGF && flutter test test/params_model_test.dart`
Expected: PASS(5 个测试)。

- [ ] **Step 6: Commit**

```bash
git add lib/src/state/params_model.dart lib/src/state/params_model_stabilize.dart test/params_model_test.dart
git commit -m "feat(s7): stabilize group setters + horizon lock aggregation"
```

---

## Task 8: 缩放组 extension(maxZoom/adaptiveZoom/croppingMode 映射/fov/lens/rs/readout/addRotation/videoSpeed)

**Files:**
- Create: `lib/src/state/params_model_zoom.dart`
- Modify: `lib/src/state/params_model.dart`(追加缩放组字段 + 字段写入方法 + 两个聚合 helper)

- [ ] **Step 1: 主类追加缩放组字段、getter、字段写入方法、聚合 helper**

```dart
  // 缩放组字段
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

  void setMaxZoomPercentField(double v) => _maxZoomPercent = v;
  void setMaxZoomIterationsField(int v) => _maxZoomIterations = v;
  void setAdaptiveZoomSecField(double v) => _adaptiveZoomSec = v;
  void setLensCorrectionField(double v) => _lensCorrection = v;
  void setFovField(double v) => _fov = v;
  void setCroppingModeField(int v) => _croppingMode = v;
  void setZoomingMethodField(int v) => _zoomingMethod = v;
  void setRsCorrectionField(bool v) => _rsCorrection = v;
  void setFrameReadoutMsField(double v) => _frameReadoutMs = v;
  void setFrameReadoutDirectionField(int v) => _frameReadoutDirection = v;
  void setAddPitchField(double v) => _addPitch = v;
  void setAddYawField(double v) => _addYaw = v;
  void setAddRollField(double v) => _addRoll = v;
  void setVideoSpeedField(double v) => _videoSpeed = v;
  void setVideoSpeedAffectsSmoothingField(bool v) => _videoSpeedAffectsSmoothing = v;
  void setVideoSpeedAffectsZoomingField(bool v) => _videoSpeedAffectsZooming = v;
  void setVideoSpeedAffectsZoomingLimitField(bool v) => _videoSpeedAffectsZoomingLimit = v;

  /// croppingMode→adaptive_zoom 映射(镜像 .m):0→0.0 / 1→adaptiveZoomSec / 2→-1.0。
  @protected
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

  /// videoSpeed + 3 联动开关一次性推送(镜像 .m pushVideoSpeed)。
  @protected
  void pushVideoSpeed() {
    send(() => bridge.setVideoSpeed(
          _videoSpeed,
          _videoSpeedAffectsSmoothing,
          _videoSpeedAffectsZooming,
          _videoSpeedAffectsZoomingLimit,
        ));
  }
```

- [ ] **Step 2: 写缩放组 extension**

> 镜像 `.m`:`maxZoomPercent/Iterations` 共用 `setMaxZoom`;`adaptiveZoomSec` 仅 croppingMode==1 时推(否则只存值,仍 recompute);`rsCorrection`/`frameReadoutMs` 共用 `setFrameReadoutTime(rs? ms:0)`;`add*` 共用 `setAdditionalRotation`。

```dart
import 'clamp.dart';
import 'params_model.dart';

extension ParamsModelZoom on ParamsModel {
  set maxZoomPercent(double v) {
    final c = ParamsRange.maxZoomPercent(v);
    if (c == maxZoomPercent) return;
    setMaxZoomPercentField(c);
    send(() => bridge.setMaxZoom(c, maxZoomIterations));
    armRecompute();
    notifyListeners();
  }

  set maxZoomIterations(int v) {
    final c = ParamsRange.maxZoomIterations(v);
    if (c == maxZoomIterations) return;
    setMaxZoomIterationsField(c);
    send(() => bridge.setMaxZoom(maxZoomPercent, c));
    armRecompute();
    notifyListeners();
  }

  set adaptiveZoomSec(double v) {
    final c = ParamsRange.adaptiveZoomSec(v);
    if (c == adaptiveZoomSec) return;
    setAdaptiveZoomSecField(c);
    if (croppingMode == 1) {
      send(() => bridge.setAdaptiveZoom(c)); // 仅动态缩放模式生效
    }
    armRecompute();
    notifyListeners();
  }

  set croppingMode(int v) {
    final c = ParamsRange.croppingMode(v);
    if (c == croppingMode) return;
    setCroppingModeField(c);
    pushAdaptiveZoom(); // 按新模式推映射后的 adaptive_zoom
    armRecompute();
    notifyListeners();
  }

  set lensCorrection(double v) {
    final c = ParamsRange.lensCorrection(v);
    if (c == lensCorrection) return;
    setLensCorrectionField(c);
    send(() => bridge.setLensCorrection(c));
    armRecompute();
    notifyListeners();
  }

  set fov(double v) {
    final c = ParamsRange.fov(v);
    if (c == fov) return;
    setFovField(c);
    send(() => bridge.setFov(c));
    armRecompute();
    notifyListeners();
  }

  set zoomingMethod(int v) {
    final c = ParamsRange.zoomingMethod(v);
    if (c == zoomingMethod) return;
    setZoomingMethodField(c);
    send(() => bridge.setZoomingMethod(c));
    armRecompute();
    notifyListeners();
  }

  set rsCorrection(bool v) {
    if (v == rsCorrection) return;
    setRsCorrectionField(v);
    send(() => bridge.setFrameReadoutTime(v ? frameReadoutMs : 0.0));
    armRecompute();
    notifyListeners();
  }

  set frameReadoutMs(double v) {
    final c = ParamsRange.frameReadoutMs(v);
    if (c == frameReadoutMs) return;
    setFrameReadoutMsField(c);
    if (rsCorrection) {
      send(() => bridge.setFrameReadoutTime(c));
    }
    armRecompute();
    notifyListeners();
  }

  set frameReadoutDirection(int v) {
    final c = ParamsRange.frameReadoutDirection(v);
    if (c == frameReadoutDirection) return;
    setFrameReadoutDirectionField(c);
    send(() => bridge.setFrameReadoutDirection(c));
    armRecompute();
    notifyListeners();
  }

  set addPitch(double v) => _setAddRotation(
      () => setAddPitchField(ParamsRange.addRotationDeg(v)));
  set addYaw(double v) => _setAddRotation(
      () => setAddYawField(ParamsRange.addRotationDeg(v)));
  set addRoll(double v) => _setAddRotation(
      () => setAddRollField(ParamsRange.addRotationDeg(v)));

  void _setAddRotation(void Function() apply) {
    apply();
    send(() => bridge.setAdditionalRotation(addPitch, addYaw, addRoll));
    armRecompute();
    notifyListeners();
  }

  set videoSpeed(double v) {
    final c = ParamsRange.videoSpeed(v);
    if (c == videoSpeed) return;
    setVideoSpeedField(c);
    pushVideoSpeed();
    armRecompute();
    notifyListeners();
  }

  set videoSpeedAffectsSmoothing(bool v) =>
      _setVideoSpeedFlag(() => setVideoSpeedAffectsSmoothingField(v));
  set videoSpeedAffectsZooming(bool v) =>
      _setVideoSpeedFlag(() => setVideoSpeedAffectsZoomingField(v));
  set videoSpeedAffectsZoomingLimit(bool v) =>
      _setVideoSpeedFlag(() => setVideoSpeedAffectsZoomingLimitField(v));

  void _setVideoSpeedFlag(void Function() apply) {
    apply();
    pushVideoSpeed();
    armRecompute();
    notifyListeners();
  }
}
```

- [ ] **Step 3: 追加 croppingMode 映射 + videoSpeed 聚合测试**

```dart
  test('croppingMode 映射 adaptive_zoom:0→0.0,1→sec,2→-1.0', () {
    final fake = FakeEngineBridge();
    final model = ParamsModel(fake); // 默认 croppingMode=1
    fake.adaptiveZoomCalls.clear();
    model.croppingMode = 0;
    model.croppingMode = 2;
    model.croppingMode = 1;
    expect(fake.adaptiveZoomCalls.map((c) => c.single).toList(),
        [0.0, -1.0, ParamsDefaults.adaptiveZoomSec]);
    model.dispose();
  });
```

需在测试顶部加 `import 'package:runcam_gf/src/state/params_model_zoom.dart';` 与 `import 'package:runcam_gf/src/state/defaults.dart';`。

- [ ] **Step 4: 运行测试,确认通过**

Run: `cd /Users/gdm/Desktop/RuncamGF && flutter test test/params_model_test.dart`
Expected: PASS(6 个测试)。

- [ ] **Step 5: Commit**

```bash
git add lib/src/state/params_model.dart lib/src/state/params_model_zoom.dart test/params_model_test.dart
git commit -m "feat(s7): zoom group setters + croppingMode/videoSpeed aggregation"
```

---

## Task 9: 高级组 + 同步组 + 导出组 extension(含「不接 FFI 只存值」)

**Files:**
- Create: `lib/src/state/params_model_advanced.dart`
- Modify: `lib/src/state/params_model.dart`(追加这些组字段 + getter + 字段写入方法 + pushBackgroundColor helper)

- [ ] **Step 1: 主类追加字段、getter、写入方法、bg 聚合 helper**

```dart
  // 高级组字段
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

  // 同步组字段(仅 imuLpfHz 接 FFI;其余只存值)
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
  double _imuLpfHz = ParamsDefaults.imuLpfHz;
  bool _checkNegativeInitialOffset = ParamsDefaults.checkNegativeInitialOffset;
  bool _calcInitialFast = ParamsDefaults.calcInitialFast;
  bool _autoSyncPointsExperimental = ParamsDefaults.autoSyncPointsExperimental;

  // 导出组字段(不接 FFI)
  int _exportCodecIndex = ParamsDefaults.exportCodecIndex;
  int _exportBitrateMbps = ParamsDefaults.exportBitrateMbps;
  bool _useGpuEncoding = ParamsDefaults.useGpuEncoding;
  bool _exportAudio = ParamsDefaults.exportAudio;

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
  double get imuLpfHz => _imuLpfHz;
  bool get checkNegativeInitialOffset => _checkNegativeInitialOffset;
  bool get calcInitialFast => _calcInitialFast;
  bool get autoSyncPointsExperimental => _autoSyncPointsExperimental;
  int get exportCodecIndex => _exportCodecIndex;
  int get exportBitrateMbps => _exportBitrateMbps;
  bool get useGpuEncoding => _useGpuEncoding;
  bool get exportAudio => _exportAudio;

  void setOutputWidthField(int v) => _outputWidth = v;
  void setOutputHeightField(int v) => _outputHeight = v;
  void setBgRField(double v) => _bgR = v;
  void setBgGField(double v) => _bgG = v;
  void setBgBField(double v) => _bgB = v;
  void setBgAField(double v) => _bgA = v;
  void setBackgroundModeField(int v) => _backgroundMode = v;
  void setShowSafeAreaField(bool v) => _showSafeArea = v;
  void setShowDetectedFeaturesField(bool v) => _showDetectedFeatures = v;
  void setShowOpticalFlowField(bool v) => _showOpticalFlow = v;
  void setPreviewResolutionHeightField(int v) => _previewResolutionHeight = v;
  void setAutosyncEnabledField(bool v) => _autosyncEnabled = v;
  void setGyroOffsetMsField(double v) => _gyroOffsetMs = v;
  void setSyncSearchSizeSecField(double v) => _syncSearchSizeSec = v;
  void setMaxSyncPointsField(int v) => _maxSyncPoints = v;
  void setEveryNthFrameField(int v) => _everyNthFrame = v;
  void setTimePerSyncpointSecField(double v) => _timePerSyncpointSec = v;
  void setSyncProcessingHeightField(int v) => _syncProcessingHeight = v;
  void setOfMethodField(int v) => _ofMethod = v;
  void setPoseMethodField(int v) => _poseMethod = v;
  void setOffsetMethodField(int v) => _offsetMethod = v;
  void setImuLpfHzField(double v) => _imuLpfHz = v;
  void setCheckNegativeInitialOffsetField(bool v) => _checkNegativeInitialOffset = v;
  void setCalcInitialFastField(bool v) => _calcInitialFast = v;
  void setAutoSyncPointsExperimentalField(bool v) => _autoSyncPointsExperimental = v;
  void setExportCodecIndexField(int v) => _exportCodecIndex = v;
  void setExportBitrateMbpsField(int v) => _exportBitrateMbps = v;
  void setUseGpuEncodingField(bool v) => _useGpuEncoding = v;
  void setExportAudioField(bool v) => _exportAudio = v;

  /// 背景色 4 通道一次性推送(镜像 .m setBg*)。
  @protected
  void pushBackgroundColor() {
    send(() => bridge.setBackgroundColor(_bgR, _bgG, _bgB, _bgA));
  }
```

- [ ] **Step 2: 写 extension**

> 镜像 `.m`:bg 4 通道走 `pushBackgroundColor`+recompute;`showDetectedFeatures`/`showOpticalFlow` 推 FFI 但**不 recompute**;`outputSize`(无 Controller 回调)走 `setOutputSizeExact`+recompute 兜底,仅 w,h>0;`previewResolutionHeight`/`gyroOffsetMs`/所有同步算法参数/导出参数**只存值 + notify**。

```dart
import 'clamp.dart';
import 'params_model.dart';

extension ParamsModelAdvanced on ParamsModel {
  // ---- 接 FFI 的高级项 ----
  set bgR(double v) => _setBg(() => setBgRField(ParamsRange.colorChannel(v)));
  set bgG(double v) => _setBg(() => setBgGField(ParamsRange.colorChannel(v)));
  set bgB(double v) => _setBg(() => setBgBField(ParamsRange.colorChannel(v)));
  set bgA(double v) => _setBg(() => setBgAField(ParamsRange.colorChannel(v)));

  void _setBg(void Function() apply) {
    apply();
    pushBackgroundColor();
    armRecompute();
    notifyListeners();
  }

  set backgroundMode(int v) {
    final c = ParamsRange.backgroundMode(v);
    if (c == backgroundMode) return;
    setBackgroundModeField(c);
    send(() => bridge.setBackgroundMode(c));
    armRecompute();
    notifyListeners();
  }

  set showSafeArea(bool v) {
    if (v == showSafeArea) return;
    setShowSafeAreaField(v);
    send(() => bridge.setShowSafeArea(v));
    armRecompute();
    notifyListeners();
  }

  // 绘制标志:推 FFI 但不 recompute(镜像 .m)。
  set showDetectedFeatures(bool v) {
    if (v == showDetectedFeatures) return;
    setShowDetectedFeaturesField(v);
    send(() => bridge.setShowDetectedFeatures(v));
    notifyListeners();
  }

  set showOpticalFlow(bool v) {
    if (v == showOpticalFlow) return;
    setShowOpticalFlowField(v);
    send(() => bridge.setShowOpticalFlow(v));
    notifyListeners();
  }

  set imuLpfHz(double v) {
    final c = ParamsRange.imuLpfHz(v);
    if (c == imuLpfHz) return;
    setImuLpfHzField(c);
    send(() => bridge.setImuLpf(c));
    armRecompute();
    notifyListeners();
  }

  /// 输出尺寸(导出/逻辑尺寸)。S7 无 Controller 回调,走 setOutputSizeExact 兜底,仅 w,h>0。
  void setOutputSize(int width, int height) {
    if (width == outputWidth && height == outputHeight) return;
    setOutputWidthField(width);
    setOutputHeightField(height);
    if (width > 0 && height > 0) {
      send(() => bridge.setOutputSizeExact(width, height));
      armRecompute();
    }
    notifyListeners();
  }

  // ---- 不接 FFI:只存值 + notify ----
  set previewResolutionHeight(int v) {
    final c = ParamsRange.previewResolutionHeight(v);
    if (c == previewResolutionHeight) return;
    setPreviewResolutionHeightField(c);
    notifyListeners();
  }

  set gyroOffsetMs(double v) {
    final c = ParamsRange.gyroOffsetMs(v);
    if (c == gyroOffsetMs) return;
    setGyroOffsetMsField(c);
    notifyListeners();
  }

  set autosyncEnabled(bool v) => _storeOnlyBool(v, autosyncEnabled, setAutosyncEnabledField);
  set checkNegativeInitialOffset(bool v) =>
      _storeOnlyBool(v, checkNegativeInitialOffset, setCheckNegativeInitialOffsetField);
  set calcInitialFast(bool v) => _storeOnlyBool(v, calcInitialFast, setCalcInitialFastField);
  set autoSyncPointsExperimental(bool v) =>
      _storeOnlyBool(v, autoSyncPointsExperimental, setAutoSyncPointsExperimentalField);
  set useGpuEncoding(bool v) => _storeOnlyBool(v, useGpuEncoding, setUseGpuEncodingField);
  set exportAudio(bool v) => _storeOnlyBool(v, exportAudio, setExportAudioField);

  set syncSearchSizeSec(double v) => _storeOnlyDouble(
      ParamsRange.syncSearchSizeSec(v), syncSearchSizeSec, setSyncSearchSizeSecField);
  set timePerSyncpointSec(double v) => _storeOnlyDouble(
      ParamsRange.timePerSyncpointSec(v), timePerSyncpointSec, setTimePerSyncpointSecField);

  set maxSyncPoints(int v) =>
      _storeOnlyInt(ParamsRange.maxSyncPoints(v), maxSyncPoints, setMaxSyncPointsField);
  set everyNthFrame(int v) =>
      _storeOnlyInt(ParamsRange.everyNthFrame(v), everyNthFrame, setEveryNthFrameField);
  set syncProcessingHeight(int v) =>
      _storeOnlyInt(v, syncProcessingHeight, setSyncProcessingHeightField);
  set ofMethod(int v) => _storeOnlyInt(ParamsRange.ofMethod(v), ofMethod, setOfMethodField);
  set poseMethod(int v) =>
      _storeOnlyInt(ParamsRange.poseMethod(v), poseMethod, setPoseMethodField);
  set offsetMethod(int v) =>
      _storeOnlyInt(ParamsRange.offsetMethod(v), offsetMethod, setOffsetMethodField);
  set exportCodecIndex(int v) =>
      _storeOnlyInt(v, exportCodecIndex, setExportCodecIndexField);
  set exportBitrateMbps(int v) =>
      _storeOnlyInt(v < 0 ? 0 : v, exportBitrateMbps, setExportBitrateMbpsField);

  void _storeOnlyBool(bool v, bool cur, void Function(bool) setField) {
    if (v == cur) return;
    setField(v);
    notifyListeners();
  }

  void _storeOnlyDouble(double v, double cur, void Function(double) setField) {
    if (v == cur) return;
    setField(v);
    notifyListeners();
  }

  void _storeOnlyInt(int v, int cur, void Function(int) setField) {
    if (v == cur) return;
    setField(v);
    notifyListeners();
  }
}
```

- [ ] **Step 3: 追加「不接 FFI 项」测试**

```dart
  test('导出参数 exportBitrateMbps:零引擎调用,值已存', () async {
    final fake = FakeEngineBridge();
    final model = ParamsModel(fake);
    model.exportBitrateMbps = 80;
    await Future<void>.delayed(settle);
    expect(fake.recomputeCalls, 0, reason: '不接 FFI,不触发 recompute');
    expect(model.exportBitrateMbps, 80);
    model.dispose();
  });
```

需在测试顶部加 `import 'package:runcam_gf/src/state/params_model_advanced.dart';`。

- [ ] **Step 4: 运行测试,确认通过**

Run: `cd /Users/gdm/Desktop/RuncamGF && flutter test test/params_model_test.dart`
Expected: PASS(7 个测试)。

- [ ] **Step 5: Commit**

```bash
git add lib/src/state/params_model.dart lib/src/state/params_model_advanced.dart test/params_model_test.dart
git commit -m "feat(s7): advanced+sync+export groups (FFI + store-only)"
```

---

## Task 10: pushAllDefaultsAndRecompute + recompute 错误处理测试

**Files:**
- Modify: `lib/src/state/params_model.dart`(加 `pushAllDefaultsAndRecompute`)
- Modify: `test/params_model_test.dart`(加错误处理 + 初始化测试)

- [ ] **Step 1: 主类加 pushAllDefaultsAndRecompute**

> 镜像 `.m applyAllToStabilizer`:把所有接 FFI 的当前值推一遍 → 一次 recompute → 回填。**不推** gyroOffset/同步算法参数/导出参数/previewResolution;outputSize 仅 w,h>0 才推。加到 `params_model.dart` 主类(在 `_runRecompute` 之后):

```dart
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
```

> 注意:`pushHorizonLock`/`pushAdaptiveZoom`/`pushVideoSpeed`/`pushBackgroundColor` 已在前面 Task 标 `@protected` 定义于主类,本方法在同类内可直接调。

- [ ] **Step 2: 追加测试(初始化推送 + recompute 错误不崩)**

```dart
  test('pushAllDefaultsAndRecompute:推一组 FFI + recompute 一次 + 回填', () async {
    final fake = FakeEngineBridge()..minFovToReturn = 1.3;
    final model = ParamsModel(fake);
    await model.pushAllDefaultsAndRecompute();
    expect(fake.recomputeCalls, 1);
    expect(model.minFov, 1.3);
    // smoothness 默认值应在推送列表里
    expect(fake.smoothingParamCalls.any((c) => c[0] == 'smoothness'), isTrue);
    model.dispose();
  });

  test('recompute 抛错:model 不抛,旧只读值保留', () async {
    final fake = FakeEngineBridge()..recomputeShouldThrow = true;
    final model = ParamsModel(fake);
    model.smoothness = 0.7; // 非默认值,确保真正触发防抖 recompute(它会抛错)
    await Future<void>.delayed(settle);
    expect(model.minFov, 0.0, reason: '回填失败,保留初始 0');
    // 不应抛异常(到这里即说明没崩)
    model.dispose();
  });
```

- [ ] **Step 3: 运行测试,确认通过**

Run: `cd /Users/gdm/Desktop/RuncamGF && flutter test test/params_model_test.dart`
Expected: PASS(9 个测试)。

- [ ] **Step 4: Commit**

```bash
git add lib/src/state/params_model.dart test/params_model_test.dart
git commit -m "feat(s7): pushAllDefaultsAndRecompute + error handling"
```

---

## Task 11: 公共导出 + 全量 analyze

**Files:**
- Modify: `lib/runcam_gf.dart`

- [ ] **Step 1: 追加导出**

在 `lib/runcam_gf.dart` 的 **import 之后、`RuncamGF` 类声明之前**加(Dart 要求所有 directive 在任何声明之前,放文件末尾会报 `directive_after_declaration`):

```dart
export 'src/state/engine_bridge.dart' show EngineBridge, VideoInfo, StabInfo;
export 'src/state/engine_bridge_impl.dart' show EngineBridgeImpl;
export 'src/state/params_model.dart'
    show ParamsModel, ParamsModelStabilize, ParamsModelZoom, ParamsModelAdvanced;
```

> part 架构下,`params_model_stabilize/zoom/advanced.dart` 是 part,**不要**单独 export(单独 export part 文件会报错)。但具名 extension 是 library 的独立顶层名字:`show ParamsModel` 会把它们过滤掉,导致 `model.maxZoomPercent` 等对包外不可见。故必须在 `show` 列表里**显式列出 3 个 extension 名**。今后新增 `ParamsModel` 的具名 extension,务必同步加进此 `show` 列表。

- [ ] **Step 2: 全量 analyze + 全量测试**

Run: `cd /Users/gdm/Desktop/RuncamGF && flutter analyze && flutter test`
Expected: `No issues found.` + 全部测试 PASS。

- [ ] **Step 3: Commit**

```bash
git add lib/runcam_gf.dart
git commit -m "feat(s7): export state layer public API"
```

---

## Task 12: S8 smoke 入口(example 临时按钮)

**Files:**
- Modify: `example/pubspec.yaml`(加 `image_picker`)
- Modify: `example/lib/main.dart`(加「Run Engine Smoke」按钮,不动 open)

> **已知风险(真机验收时核对)**:`image_picker` 在安卓返回缓存文件路径、iOS 返回文件路径。`openVideo` 安卓侧原解析 `content://`(见 `进度与续接.md` §S3/S4);若安卓 `openVideo` 对文件路径失败,改用返回 `content://` 的选择器(如 `file_picker`)或在 native 端兼容。iOS 文件路径应可用。

- [ ] **Step 1: 加依赖**

在 `example/pubspec.yaml` 的 `dependencies:` 下加(与现有缩进对齐):

```yaml
  image_picker: ^1.1.2
```

Run: `cd /Users/gdm/Desktop/RuncamGF/example && flutter pub get`
Expected: 成功。

- [ ] **Step 2: 改 example/lib/main.dart 加 smoke 按钮**

把 `HomePage` 替换为(保留原 open 按钮,新增 smoke 按钮):

```dart
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final EngineBridge _bridge = EngineBridgeImpl();
  late final ParamsModel _model = ParamsModel(_bridge);
  String _status = '';

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  Future<void> _runSmoke() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picker = ImagePicker();
      final picked = await picker.pickVideo(source: ImageSource.gallery);
      if (picked == null) return;
      await _bridge.createStabilizer();
      final info = await _bridge.openVideo(picked.path);
      // 先把所有默认值推到引擎并 recompute 一次(等价 Controller 初始化),保证有回填。
      await _model.pushAllDefaultsAndRecompute();
      _model.smoothness = 0.6; // 非默认值(默认 0.5),触发 setter→立即推→200ms 防抖 recompute
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      final msg = 'output=${info.outputWidth}x${info.outputHeight} '
          'minFov=${_model.minFov.toStringAsFixed(4)} '
          'maxAngle P/Y/R=${_model.maxAnglePitch.toStringAsFixed(2)}/'
          '${_model.maxAngleYaw.toStringAsFixed(2)}/'
          '${_model.maxAngleRoll.toStringAsFixed(2)}';
      setState(() => _status = msg);
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    } on PlatformException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('smoke 失败: ${e.code} ${e.message}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('smoke 失败: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RuncamGF example')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await RuncamGF.open();
                } on PlatformException catch (e) {
                  messenger.showSnackBar(
                    SnackBar(content: Text('打开失败: ${e.code} ${e.message}')),
                  );
                }
              },
              child: const Text('打开 Gyroflow 防抖'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _runSmoke,
              child: const Text('Run Engine Smoke (dev)'),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_status, textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}
```

文件顶部 import 区追加:

```dart
import 'package:image_picker/image_picker.dart';
```

(`runcam_gf.dart` 已导出 `EngineBridge`/`EngineBridgeImpl`/`ParamsModel`,无需额外 import。)

- [ ] **Step 3: 验证 example 编译(analyze)**

Run: `cd /Users/gdm/Desktop/RuncamGF/example && flutter analyze`
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add example/pubspec.yaml example/lib/main.dart
git commit -m "feat(s8): example dev smoke entry (createStabilizer→openVideo→smoothness→recompute)"
```

---

## Task 13: 两端真机验收(S8 go 条件)

**Files:** 无(纯验收)

- [ ] **Step 1: iOS 真机**

```bash
cd /Users/gdm/Desktop/RuncamGF/example/ios && pod install
cd /Users/gdm/Desktop/RuncamGF/example && flutter run -d <iOS设备id> --release
```
操作:点「Run Engine Smoke」→ 选一段已知样片。
Expected:SnackBar 显示 `minFov` **非零**、`maxAngle` 有值;旧「打开 Gyroflow 防抖」仍正常。

- [ ] **Step 2: Android 真机**

```bash
cd /Users/gdm/Desktop/RuncamGF/example && flutter run -d <Android设备id>
```
操作:同上选样片。
Expected:`minFov` 非零(安卓 `minFov=100/zoom%` 换算,与 iOS **趋势一致、非逐位相等**)。若 `openVideo` 在安卓报错,见 Task 12 已知风险,改用 content:// 选择器。

- [ ] **Step 3: 回归旧 open()**

两端各点一次「打开 Gyroflow 防抖」,确认原生页开视频/调参数/预览/导出全程与之前一致。

- [ ] **Step 4: 记录验收结果**

把结果(两端 minFov 值、是否回归通过)补记到 `~/Desktop/迁移步骤/进度与续接.md` 的「已完成」表,S7/S8 标 ✅。

---

## 自检结论(写计划时已核对)

- **Spec 覆盖**:分层(Task 1-2)、defaults/clamp(3-4)、防抖/回填/clamp(5-6)、稳定组+地平线聚合(7)、缩放组+croppingMode/videoSpeed(8)、高级+同步+导出+不接FFI(9)、初始化+错误处理(10)、导出+全量验证(11)、S8 smoke(12)、两端验收(13)。spec 7 条单测全部落到 Task 5/6/7/8/9/10。
- **占位扫描**:无 TBD/TODO;所有代码步给出完整代码。
- **类型一致**:`EngineBridge` 方法签名在 Task 1 定义,FakeEngineBridge(Task 5)与 EngineBridgeImpl(Task 2)实现一致;`StabInfo.minFov` 可空,回填用 `?? 旧值`。
- **代码组织(修订)**:Task 7/8/9 一律遵循上文「代码组织约定(part + extension)」——state 文件同库 part、extension 直接读写 `_x`、用 `notify()`;不再用 `getXxxField/setXxxField` 存取器,测试不单独 import part 文件。
- **已知风险显式标注**:安卓 `openVideo` 文件路径 vs content:// 在 Task 12 注明,不静默。
