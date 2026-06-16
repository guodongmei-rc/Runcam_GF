# S7 + S8 设计:Dart 状态层 ParamsModel + smoke 验收

> 日期:2026-06-15
> 阶段:GF 功能 Flutter 化 — 阶段 0+2 收尾(S7 状态层 + S8 smoke)
> 项目:`/Users/gdm/Desktop/RuncamGF`
> 依据:`~/Desktop/迁移步骤/阶段0+2-执行步骤.md`(S7/S8)、`ios/Sources/ParamsModel.h`(参数规格)、
> `lib/src/bridge/engine_api.g.dart`(已生成的 Pigeon 桥)

## 目标

把 `ios/Sources/ParamsModel.h` 的 ~80 个参数全量搬成 Dart 状态层(`ParamsModel`,`ChangeNotifier`),
每个 setter 完成「clamp → 立即推引擎 → 200ms 防抖 → recompute → 回填只读输出」。
这是**第一次真正驱动 S3/S4 的桥**;S8 用 example 临时入口在两端真机验证链路通(`minFov` 非零)。

**总原则(承接阶段 0+2)**:不删任何现有原生 UI,旧 `open()` 全屏原生页全程可跑、零改动。
本轮全部为纯新增 Dart + example 一个临时 dev 按钮。可见 UI 变化要到阶段 3。

## 范围

- **覆盖参数**:全量 ~80 项(`ParamsModel.h` 的全部,含同步/稳定/缩放/高级/导出/只读输出各组)。
- **不在本轮**:lens / timeline / metadata 等读类方法(阶段 3/4 再用);`EngineEvents.onRecomputeFinished`
  旁路(阶段 3 UI 用);预览 Texture(阶段 1);autosync/export 实际执行(阶段 4)。

## 架构与分层

```
lib/src/state/
  engine_bridge.dart        // abstract EngineBridge —— ParamsModel 唯一依赖的引擎接口
  engine_bridge_impl.dart   // 真实实现:转发到生成的 EngineApi(engine_api.g.dart)
  params_model.dart         // 主类:字段 + 防抖/回填核心 + clamp 入口 + dispose
  params_model_sync.dart        // extension:同步组 setter
  params_model_stabilize.dart   // extension:稳定组 setter
  params_model_zoom.dart        // extension:缩放组 setter
  params_model_advanced.dart    // extension:高级组 + 导出组 setter
  defaults.dart             // 每参数默认值(抄 .h 注释)
  clamp.dart                // 每参数 clamp 区间 + clamp 函数(抄 .h 注释)
test/
  params_model_test.dart    // 用 FakeEngineBridge 验防抖/回填/clamp/聚合/错误
example/lib/                // 临时 dev smoke 按钮(不动 open)
```

**依赖方向**:`ParamsModel` → `EngineBridge`(抽象)。真实跑由 `EngineBridgeImpl` 包生成的 `EngineApi`;
测试由手写 `FakeEngineBridge` 替身。`ParamsModel` 完全不认识 Pigeon / channel。

**EngineBridge 只收录本轮要用的写子集**(约 30 个方法):按生成的 `EngineApi` 真实签名定义
(不是每参一个方法),即 `createStabilizer / freeStabilizer / openVideo` + 各参数 setter
(`setSmoothingParam` / `setHorizonLock`(9参) / `setVideoSpeed`(4参) / `setBackgroundColor`(4参)/ …)
+ `recomputeBlocking`。lens/timeline/metadata 等不纳入,阶段 3/4 再扩。

## setter 数据流

单个 setter(以 `smoothness` 为例):
```
model.smoothness = 0.5
  → clamp 到 [0.001, 1.0]                         (clamp.dart)
  → 若值未变则 return
  → 写入 _smoothness 字段
  → 立即推: bridge.setSmoothingParam("smoothness", 0.5)   (try/catch 吞错)
  → _armRecompute()                               (复位共享 200ms 防抖定时器)
  → notifyListeners()
```

防抖与回填(共享一个 Timer,合并 recompute):
```
_armRecompute(): 取消旧 Timer,起 200ms Timer
200ms 到点(期间无新改动):
  → try { final info = await bridge.recomputeBlocking() }
  → 回填 _minFov / _maxAnglePitch / _maxAngleYaw / _maxAngleRoll = info.*
  → notifyListeners()
  → catch: 保留旧只读值,debugPrint 记录,不 rethrow
```
连续改动只触发**一次** recompute(对齐 ObjC `ParamsModel.m`)。回填**只认 `recomputeBlocking()` 返回值**,
不依赖 `EngineEvents.onRecomputeFinished`。

**多参合一由 model 内部聚合**:改 `horizonLockAmount` / `horizonLockRoll` / 任一地平线高级项,
都调同一私有 `_pushHorizonLock()` 把当前 9 个相关字段一次性 `bridge.setHorizonLock(...)`。
同理 `_pushVideoSpeed()`(4 参)、`_pushBackgroundColor()`(4 参)。
`croppingMode`→`adaptive_zoom` 映射(0→0.0 / 1→adaptiveZoomSec / 2→-1.0)藏在 `_pushAdaptiveZoom()`。

**只读输出**(`maxAnglePitch/Yaw/Roll`、`minFov`)只有 getter,只由回填写入。

**不接 FFI 的参数**(同步组 8 项 auto-sync 参数、导出组 4 项)在 model 里**只存值 + notify**,
不调 bridge、不触发 recompute(对齐 .h 的 "Phase α 锁灰 / 仅导出时读取")。

## 初始化与错误处理

- `Future<void> pushAllDefaultsAndRecompute()`:把所有接 FFI 的默认值经 bridge 全推一遍 →
  触发一次 `recomputeBlocking` → 回填。供 Controller 在 `createStabilizer` 后调一次
  (对齐 .h 的 `loadDefaultsFromStabilizer`)。
- 字段初值取 `defaults.dart`,新建 `ParamsModel` 即默认态。
- setter 的"立即推"与 `recomputeBlocking` 均 `try/catch` 吞错 + `debugPrint`,不崩 UI
  (阶段 0+2 桥可能在未 createStabilizer / 未开视频时被调,会抛 `PlatformException`)。
- `dispose()` 取消防抖 Timer,防止销毁后回调 `notifyListeners`。

## S8 smoke 入口

`example/lib/` 现有 `HomePage` 加临时按钮「Run Engine Smoke」(dev-only,不动 `open()`):
```
bridge.createStabilizer()
→ bridge.openVideo(<用户选的样片 uri/path>)   // 复用 example 已有选视频入口拿 uri,避免硬编码
→ model.smoothness = 0.5                       // 触发立即推 + 200ms 后 recompute
→ 等回填 → SnackBar 显示 minFov / maxAngle*
```

## 测试清单(`test/params_model_test.dart`,FakeEngineBridge + fakeAsync)

1. 改 `smoothness=0.5`:200ms 内未 recompute;推进 200ms 后 `recomputeBlocking` 恰好 1 次,`minFov` 回填非零。
2. 连续改 3 次(间隔 <200ms):最后只 recompute 1 次(防抖合并)。
3. clamp:`smoothness=5.0`→存 `1.0`;`=0`→存 `0.001`。
4. 多参聚合:改 `horizonLockRoll` → bridge 收到一次 9 参 `setHorizonLock`,其余 8 参为当前字段值。
5. 不接 FFI 项:改 `exportBitrateMbps` → bridge 零调用,但 notify 触发、值已存。
6. `croppingMode=1`→`setAdaptiveZoom(adaptiveZoomSec)`;`=0`→`0.0`;`=2`→`-1.0`。
7. 错误:fake 让 `recomputeBlocking` throw → model 不抛、旧只读值保留。

`flutter analyze` 须绿。

## 验收(S7+S8 go 条件)

1. 两端真机:smoke 按钮跑通,`minFov` 非零且两端趋势一致(安卓 `minFov=100/zoom%` 换算,非逐位相等)。
2. 旧 `open()` 全屏原生页回归无变化。
3. `flutter analyze` + 上述 Dart 单测全绿。

## 产物

**新增**:`lib/src/state/{engine_bridge,engine_bridge_impl,params_model,params_model_sync,
params_model_stabilize,params_model_zoom,params_model_advanced,defaults,clamp}.dart`、
`test/params_model_test.dart`、example 临时 smoke 按钮。

**改动**:`example/lib/main.dart`(加 dev 按钮)。

**不动**:`gyroflow_ffi.h`、`GyroflowNative.kt`、`engine_api.g.dart`(生成物)、所有原生 UI、旧 `open()`。

## 风险与回滚

- 全程纯新增 Dart + example 一个临时按钮,弃之无副作用,旧 `open()` 零改动。
- 两端 API 不对称(见 `进度与续接.md` §S3/S4):UI/model 不假设两端逐位一致;smoke 只验"非零 + 趋势一致"。
- 80 参数易抄错默认值/clamp:`defaults.dart` / `clamp.dart` 逐条对照 `.h` 注释,单测 case 3/6 抽查兜底。
