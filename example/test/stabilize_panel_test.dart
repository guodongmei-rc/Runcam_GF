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
    expect(model.smoothness, isNot(before)); // setter 即时改值=闭环第一步
    // 改值会排一个 200ms recompute 防抖定时器;让它触发完,避免 pending timer。
    await tester.pump(const Duration(milliseconds: 250));
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
    // perAxis setter 也排了 200ms recompute 定时器,触发完避免 pending timer。
    await tester.pump(const Duration(milliseconds: 250));
  });
}
