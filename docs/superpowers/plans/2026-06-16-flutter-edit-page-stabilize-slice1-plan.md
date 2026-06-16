# 阶段3 切片1 实施计划:Flutter 编辑页 + 可切换预览 + Stabilize 面板

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development(推荐)或 superpowers:executing-plans 逐任务实现。步骤用 `- [ ]` 勾选跟踪。
> 配套设计:同目录 `阶段3-切片1-编辑页+Stabilize-设计.md`(原件 `docs/superpowers/specs/2026-06-16-flutter-edit-page-stabilize-slice1-design.md`)。

**Goal:** 在现有「预览 Texture spike (dev)」页上,搭出"上预览 + 下 Stabilize 面板"的 Flutter 编辑页,跑通"调参→引擎→预览实时反映"闭环,且预览后端 Texture⇄PlatformView 可一键切换。

**Architecture:** 三层解耦——`PreviewView`(只显示)/ `StabilizePanel`(只调 `ParamsModel`)/ `EditController`(`ChangeNotifier`,持引擎生命周期 + `ParamsModel` + 当前后端)。两预览后端共享同一 engine stabilizer,参数经引擎 recompute 自动反映。

**Tech Stack:** Flutter(Dart),`runcam_gf` 插件(`EngineBridge`/`ParamsModel`/`PreviewApi`),iOS `PreviewController`(Texture)/ `PreviewPlatformView`(UiKitView)。

---

## 文件结构

| 文件 | 责任 |
|---|---|
| `example/lib/edit/preview_backend.dart`(新) | `enum PreviewBackend { texture, platformView }` |
| `example/lib/edit/edit_controller.dart`(新) | `EditController extends ChangeNotifier`:选视频+引擎初始化(一次)、`ParamsModel` 持有、当前后端 + 切换、play/pause、dispose |
| `example/lib/edit/preview_view.dart`(新) | `PreviewView`:按 `controller.backend` 渲 `Texture` 或 `UiKitView`;**不碰参数** |
| `example/lib/edit/panels/stabilize_panel.dart`(新) | `StabilizePanel`:Stabilize 控件 → `ParamsModel` setter;**不碰预览后端** |
| `example/lib/preview_page.dart`(改) | 扩成编辑页:持 `EditController` + ticker;Scaffold = AppBar(后端开关)+ PreviewView + 控制条 + StabilizePanel |
| `example/test/stabilize_panel_test.dart`(新) | widget 测:拖控件 → 对应 `ParamsModel` setter 生效 |

**ParamsModel 已确认的公开 API(本切片用到,勿臆造):**
- 平滑:`smoothness`、`perAxis`、`smoothnessPitch/Yaw/Roll`
- 地平线:`horizonLock`、`horizonLockAmount`、`horizonLockRoll`
- 缩放:`maxZoomPercent`、`croppingMode`(int 0/1/2)、`lensCorrection`
- 只读回填:`maxAnglePitch/Yaw/Roll`、`minFov`

---

## Task 1: PreviewBackend enum

**Files:** Create `example/lib/edit/preview_backend.dart`

- [ ] **Step 1: 写 enum**

```dart
/// 预览渲染后端。Texture=经 Flutter 合成器;PlatformView=嵌原生 MTKView 直出。
/// 二者共享同一 engine stabilizer,可一键切换,参数面板不感知。
enum PreviewBackend { texture, platformView }

extension PreviewBackendX on PreviewBackend {
  String get label => this == PreviewBackend.texture ? 'Texture' : 'PlatformView';
  PreviewBackend get other =>
      this == PreviewBackend.texture ? PreviewBackend.platformView : PreviewBackend.texture;
}
```

- [ ] **Step 2: analyze**

Run: `flutter analyze example/lib/edit/preview_backend.dart`
Expected: No issues found!

- [ ] **Step 3: Commit**

```bash
git add example/lib/edit/preview_backend.dart
git commit -m "feat(edit): PreviewBackend enum (texture/platformView)"
```

---

## Task 2: EditController(引擎生命周期 + 后端切换)

**Files:** Create `example/lib/edit/edit_controller.dart`

> 把现有 `preview_page.dart` / `preview_platformview_page.dart` 里的引擎初始化、play/pause、后端起停**收拢到这里**。引擎初始化只做一次,两后端共用同一 stabilizer。

- [ ] **Step 1: 写 EditController 全文**

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:runcam_gf/runcam_gf.dart';
import 'preview_backend.dart';

/// 编辑页控制器:持引擎生命周期 + ParamsModel + 当前预览后端。
/// 面板只通过 [params] 调参;预览只读 [backend]/[textureId]/[uri]。
class EditController extends ChangeNotifier {
  EditController() {
    params = ParamsModel(_bridge);
  }

  static const MethodChannel _picker = MethodChannel('runcam_gf_example/picker');
  final EngineBridge _bridge = EngineBridgeImpl();
  final PreviewApi _previewApi = PreviewApi();
  late final ParamsModel params;

  String? uri;
  PreviewBackend backend = PreviewBackend.texture;
  bool playing = false;
  bool busy = false;
  String status = '点「选视频」开始';

  // Texture 后端
  int? textureId;
  double aspect = 16 / 9;
  // PlatformView 后端
  MethodChannel? _pvChannel;

  /// 选视频 → 引擎初始化(一次)→ 起当前后端。
  Future<void> openAndStart() async {
    final picked = await _picker.invokeMethod<String>('pickVideo');
    if (picked == null) return;
    _setBusy(true);
    try {
      await _bridge.createStabilizer();
      final info = await _bridge.openVideo(picked);
      await _bridge.setStabEnabled(true);
      await _bridge.setGyroOffset(48.0); // raw-IMU 机型默认补偿(阶段4 autosync 替)
      await params.pushAllDefaultsAndRecompute();
      uri = picked;
      final ow = info.outputWidth ?? 16, oh = info.outputHeight ?? 9;
      aspect = oh > 0 ? ow / oh : 16 / 9;
      await _startBackend();
      playing = true;
      status = '后端:${backend.label}';
    } catch (e) {
      status = '失败:$e';
    } finally {
      _setBusy(false);
    }
  }

  /// 一键切后端:拆当前 + 起另一个(会重新解码),参数状态不动。
  Future<void> switchBackend() async {
    if (uri == null || busy) return;
    _setBusy(true);
    try {
      await _stopBackend();
      backend = backend.other;
      await _startBackend();
      playing = true;
      status = '后端:${backend.label}';
    } finally {
      _setBusy(false);
    }
  }

  Future<void> togglePlay() async {
    playing = !playing;
    if (backend == PreviewBackend.texture) {
      await (playing ? _previewApi.play() : _previewApi.pause());
    } else {
      await _pvChannel?.invokeMethod(playing ? 'play' : 'pause');
    }
    notifyListeners();
  }

  /// PlatformView 创建回调:拿到 per-view 控制通道。
  void onPlatformViewCreated(int id) {
    _pvChannel = MethodChannel('runcam_gf/preview_pv_$id');
  }

  Future<void> _startBackend() async {
    if (backend == PreviewBackend.texture) {
      final pi = await _previewApi.createPreviewTexture(uri!);
      textureId = pi.textureId;
      final w = pi.width ?? 16, h = pi.height ?? 9;
      aspect = h > 0 ? w / h : aspect;
      await _bridge.recomputeBlocking(); // GPU 重绑后再同步一次(沿用现有修复)
      await _previewApi.play();
    }
    // PlatformView 后端:UiKitView 在页面构建时创建,原生 init 自动播放。
  }

  Future<void> _stopBackend() async {
    if (backend == PreviewBackend.texture) {
      final t = textureId;
      textureId = null;
      if (t != null) await _previewApi.disposePreviewTexture(t);
    } else {
      await _pvChannel?.invokeMethod('dispose');
      _pvChannel = null;
    }
  }

  void _setBusy(bool b) {
    busy = b;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopBackend();
    _bridge.freeStabilizer();
    super.dispose();
  }
}
```

- [ ] **Step 2: analyze**

Run: `flutter analyze example/lib/edit/edit_controller.dart`
Expected: No issues found!(若报 `PreviewApi`/`VideoInfo` 字段名不符,对照 `lib/runcam_gf.dart` 导出修正)

- [ ] **Step 3: Commit**

```bash
git add example/lib/edit/edit_controller.dart
git commit -m "feat(edit): EditController — engine lifecycle + backend switch"
```

---

## Task 3: PreviewView(只显示,后端无关参数)

**Files:** Create `example/lib/edit/preview_view.dart`

- [ ] **Step 1: 写 PreviewView**

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'edit_controller.dart';
import 'preview_backend.dart';

/// 只负责"显示共享 stabilizer 的输出"。不引用 ParamsModel / 任何参数。
class PreviewView extends StatelessWidget {
  const PreviewView({super.key, required this.controller});
  final EditController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c.uri == null) {
      return const Center(child: Text('未选视频'));
    }
    if (c.backend == PreviewBackend.texture) {
      if (c.textureId == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: AspectRatio(
          aspectRatio: c.aspect,
          child: Texture(textureId: c.textureId!),
        ),
      );
    }
    // PlatformView 后端
    return UiKitView(
      viewType: 'runcam_gf/preview_platformview',
      creationParams: {'uri': c.uri},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: c.onPlatformViewCreated,
    );
  }
}
```

- [ ] **Step 2: analyze**

Run: `flutter analyze example/lib/edit/preview_view.dart`
Expected: No issues found!

- [ ] **Step 3: Commit**

```bash
git add example/lib/edit/preview_view.dart
git commit -m "feat(edit): PreviewView — swappable Texture/PlatformView display"
```

---

## Task 4: StabilizePanel + widget 测(TDD)

**Files:** Create `example/lib/edit/panels/stabilize_panel.dart`、`example/test/stabilize_panel_test.dart`

- [ ] **Step 1: 先写失败的 widget 测**

```dart
// example/test/stabilize_panel_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runcam_gf/runcam_gf.dart';
import 'package:runcam_gf_example/edit/panels/stabilize_panel.dart';

/// 不接真引擎:空实现桥,只让 ParamsModel 能跑。
class _NoopBridge implements EngineBridge {
  @override
  Future<StabInfo> recomputeBlocking() async =>
      StabInfo(maxAnglePitch: 0, maxAngleYaw: 0, maxAngleRoll: 0, minFov: 1);
  @override
  noSuchMethod(Invocation i) async => null; // 其余写方法吞掉
}

void main() {
  testWidgets('拖平滑度滑块 → ParamsModel.smoothness 改变', (tester) async {
    final model = ParamsModel(_NoopBridge());
    final before = model.smoothness; // 默认 0.5
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: StabilizePanel(model: model)),
    ));
    final slider = find.byKey(const Key('stab_smoothness'));
    expect(slider, findsOneWidget);
    await tester.drag(slider, const Offset(200, 0)); // 往右拖
    await tester.pump();
    expect(model.smoothness, isNot(before));
  });

  testWidgets('每轴开关默认关,打开后露出 P/Y/R 滑块', (tester) async {
    final model = ParamsModel(_NoopBridge());
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: StabilizePanel(model: model)),
    ));
    expect(find.byKey(const Key('stab_smoothness_pitch')), findsNothing);
    await tester.tap(find.byKey(const Key('stab_per_axis')));
    await tester.pump();
    expect(find.byKey(const Key('stab_smoothness_pitch')), findsOneWidget);
  });
}
```

- [ ] **Step 2: 跑测,确认失败**

Run: `flutter test example/test/stabilize_panel_test.dart`
Expected: FAIL —— `stabilize_panel.dart` / `StabilizePanel` 不存在(编译失败)。

> `_NoopBridge` 用 `noSuchMethod` 吞掉 `EngineBridge` 的写方法(setter→引擎调用),只显式实现 `recomputeBlocking`。`ParamsModel` setter 会即时改值并 notify(去重:别用等于默认值的目标)。

- [ ] **Step 3: 写 StabilizePanel(让测通过)**

```dart
// example/lib/edit/panels/stabilize_panel.dart
import 'package:flutter/material.dart';
import 'package:runcam_gf/runcam_gf.dart';

/// Stabilize 面板:只通过 [model] 调参(clamp→推引擎→200ms 防抖→recompute→回填)。
/// 不引用任何预览后端。
class StabilizePanel extends StatelessWidget {
  const StabilizePanel({super.key, required this.model});
  final ParamsModel model;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _slider('平滑度', const Key('stab_smoothness'),
              model.smoothness, 0, 1, (v) => model.smoothness = v),
          SwitchListTile(
            key: const Key('stab_per_axis'),
            title: const Text('每轴平滑'),
            value: model.perAxis,
            onChanged: (v) => model.perAxis = v,
          ),
          if (model.perAxis) ...[
            _slider('Pitch', const Key('stab_smoothness_pitch'),
                model.smoothnessPitch, 0, 1, (v) => model.smoothnessPitch = v),
            _slider('Yaw', const Key('stab_smoothness_yaw'),
                model.smoothnessYaw, 0, 1, (v) => model.smoothnessYaw = v),
            _slider('Roll', const Key('stab_smoothness_roll'),
                model.smoothnessRoll, 0, 1, (v) => model.smoothnessRoll = v),
          ],
          const Divider(),
          SwitchListTile(
            key: const Key('stab_horizon'),
            title: const Text('地平线锁定'),
            value: model.horizonLock,
            onChanged: (v) => model.horizonLock = v,
          ),
          if (model.horizonLock) ...[
            _slider('锁定量', const Key('stab_horizon_amount'),
                model.horizonLockAmount, 0, 1, (v) => model.horizonLockAmount = v),
            _slider('Roll', const Key('stab_horizon_roll'),
                model.horizonLockRoll, -180, 180, (v) => model.horizonLockRoll = v),
          ],
          const Divider(),
          _slider('最大缩放 %', const Key('stab_max_zoom'),
              model.maxZoomPercent, 100, 300, (v) => model.maxZoomPercent = v),
          ListTile(
            title: const Text('裁切模式'),
            trailing: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('无')),
                ButtonSegment(value: 1, label: Text('自适应')),
                ButtonSegment(value: 2, label: Text('静态')),
              ],
              selected: {model.croppingMode},
              onSelectionChanged: (s) => model.croppingMode = s.first,
            ),
          ),
          _slider('镜头校正', const Key('stab_lens'),
              model.lensCorrection, 0, 1, (v) => model.lensCorrection = v),
          const Divider(),
          Text('maxAngle P/Y/R = '
              '${model.maxAnglePitch.toStringAsFixed(1)}/'
              '${model.maxAngleYaw.toStringAsFixed(1)}/'
              '${model.maxAngleRoll.toStringAsFixed(1)}°   '
              'minFov=${model.minFov.toStringAsFixed(3)}'),
        ],
      ),
    );
  }

  Widget _slider(String label, Key key, double value, double min, double max,
      ValueChanged<double> onChanged) {
    return Row(children: [
      SizedBox(width: 90, child: Text(label)),
      Expanded(
        child: Slider(
          key: key,
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ),
      SizedBox(width: 56, child: Text(value.toStringAsFixed(2), textAlign: TextAlign.end)),
    ]);
  }
}
```

- [ ] **Step 4: 跑测,确认通过**

Run: `flutter test example/test/stabilize_panel_test.dart`
Expected: PASS(2 测全绿)

- [ ] **Step 5: analyze**

Run: `flutter analyze example/lib/edit/panels/stabilize_panel.dart example/test/stabilize_panel_test.dart`
Expected: No issues found!

- [ ] **Step 6: Commit**

```bash
git add example/lib/edit/panels/stabilize_panel.dart example/test/stabilize_panel_test.dart
git commit -m "feat(edit): StabilizePanel + widget test (param closed-loop)"
```

---

## Task 5: 把编辑页接起来(扩 preview_page.dart)

**Files:** Modify `example/lib/preview_page.dart`(整文件替换为下面)

> 现有 Texture 初始化/play-pause/seek 逻辑已迁进 `EditController`,这里只剩页面装配 + ticker(Texture 后端需 Dart ticker 驱动 60Hz 合成)。

- [ ] **Step 1: 整文件替换**

```dart
import 'package:flutter/material.dart';
import 'edit/edit_controller.dart';
import 'edit/preview_view.dart';
import 'edit/panels/stabilize_panel.dart';

/// 阶段3 切片1:Flutter 编辑页(上预览 + 下 Stabilize 面板,预览后端可一键切)。
class PreviewPage extends StatefulWidget {
  const PreviewPage({super.key});
  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage>
    with SingleTickerProviderStateMixin {
  final EditController _c = EditController();
  late final AnimationController _ticker = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  @override
  void initState() {
    super.initState();
    // Texture 后端需持续帧驱动 Flutter 合成到 60Hz(textureFrameAvailable 单独不足)。
    _ticker.repeat();
    _c.addListener(_onChange);
  }

  void _onChange() => setState(() {});

  @override
  void dispose() {
    _c.removeListener(_onChange);
    _ticker.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑页 (dev)'),
        actions: [
          TextButton(
            onPressed: _c.uri == null || _c.busy ? null : _c.switchBackend,
            child: Text('切到 ${_c.backend.other.label}',
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(6),
            child: Text(_c.status, textAlign: TextAlign.center),
          ),
          // 预览区:用 AnimatedBuilder(_ticker) 包一层,Texture 后端才会被持续重绘到 60Hz。
          Expanded(
            flex: 3,
            child: AnimatedBuilder(
              animation: _ticker,
              builder: (_, __) => PreviewView(controller: _c),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(onPressed: _c.openAndStart, child: const Text('选视频')),
              ElevatedButton(
                onPressed: _c.uri == null ? null : _c.togglePlay,
                child: Text(_c.playing ? '暂停' : '播放'),
              ),
            ],
          ),
          // 参数区:Stabilize 面板。
          Expanded(
            flex: 4,
            child: _c.uri == null
                ? const Center(child: Text('选视频后可调参'))
                : StabilizePanel(model: _c.params),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: analyze 全 example**

Run: `flutter analyze example/lib`
Expected: No issues found!

- [ ] **Step 3: Commit**

```bash
git add example/lib/preview_page.dart
git commit -m "feat(edit): wire edit page (preview + stabilize panel + backend toggle)"
```

---

## Task 6: 真机闭环验收(手动)

> 纯 Dart 改动 → 热重启即可;若之前改过原生(PlatformView)未编进,先 `flutter run --profile` 完整重编。

- [ ] **Step 1: 跑**

Run: `cd /Users/gdm/Desktop/GFRuncam/example && flutter run --profile -d <设备>`
进主界面 →「预览 Texture spike (dev)」(现已是编辑页)。

- [ ] **Step 2: 闭环验收**

1. 选视频 → 预览出画。
2. 拖**平滑度** → 预览防抖强度实时变;`maxAngle/minFov` 文本跟着回填。
3. 开**每轴平滑** → 露出 P/Y/R,分别拖有效。
4. 开**地平线锁定** + 拖锁定量 → 预览地平线响应。
5. 拖**最大缩放** / 切**裁切模式** / 拖**镜头校正** → 预览取景实时变。

- [ ] **Step 3: 解耦验收(关键)**

AppBar 点「切到 PlatformView」→ 预览黑一下重解码后用原生直出显示;**同一个 Stabilize 面板继续拖,效果一致**;再点「切到 Texture」切回。

- [ ] **Step 4: 生命周期**

进出页多次、切后台/回前台、切后端多次 → 不崩、内存不持续涨(Xcode)。

- [ ] **Step 5: 记录结果**

把"闭环 OK / 切后端 OK / 是否崩"回报。崩或编译错把报错发出来(大概率是 `PreviewApi`/`VideoInfo` 字段名,或 PlatformView 未重编)。

---

## Self-Review(对照设计自查)

- **Spec 覆盖**:三层解耦(PreviewView/StabilizePanel/EditController)→ Task 1-5;闭环 → Task 4 测 + Task 6;一键切后端 → EditController.switchBackend(Task 2)+ Task 6 Step 3;Stabilize 主控件 → Task 4 面板;只读回填显示 → Task 4 面板底部。✅
- **占位扫描**:无 TBD;每个写代码步均含完整代码。✅
- **类型一致**:`PreviewBackend.other/.label`(Task1)在 Task2/5 使用一致;`EditController` 字段(uri/backend/textureId/aspect/busy/playing/status/openAndStart/switchBackend/togglePlay/onPlatformViewCreated)在 Task3/5 引用一致;`StabilizePanel({required model})` 在 Task4/5 一致;`ParamsModel` getter/setter 名均来自实测 API。✅
- **已知风险**:`PreviewApi`/`VideoInfo` 字段(`createPreviewTexture`/`textureId`/`width`/`height`/`outputWidth`/`outputHeight`)若与生成绑定不符 → Task2 analyze 步会暴露,按 `lib/runcam_gf.dart` 修正。

---

## 执行交接

计划已存 `~/Desktop/迁移步骤/阶段3-切片1-编辑页+Stabilize-实施计划.md`(原件另存 `docs/superpowers/plans/`)。两种执行方式:

1. **Subagent-Driven(推荐)**:每个 Task 派新 subagent,Task 间评审,迭代快。
2. **Inline 执行**:本会话内按 executing-plans 批量跑,带检查点。

选哪个?
