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
    // 第一个 Slider = 平滑度(平滑方式是下拉,不是 Slider)。
    await tester.drag(find.byType(Slider).first, const Offset(200, 0));
    await tester.pump();
    expect(model.smoothness, isNot(before)); // setter 即时改值=闭环第一步
    // 改值会排一个 200ms recompute 防抖定时器;让它触发完,避免 pending timer。
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('展开高级→勾按轴 → 露出 Pitch、隐藏总平滑度', (tester) async {
    final model = ParamsModel(_NoopBridge());
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: StabilizePanel(model: model)),
    ));
    expect(find.byKey(const Key('stab_smoothness_pitch')), findsNothing);
    expect(find.byKey(const Key('stab_smoothness')), findsOneWidget);
    // 展开高级选项 → 勾「按轴」。
    await tester.tap(find.text('高级选项'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('stab_per_axis')));
    await tester.pump();
    expect(find.byKey(const Key('stab_smoothness_pitch')), findsOneWidget);
    expect(find.byKey(const Key('stab_smoothness')), findsNothing);
    // perAxis setter 也排了 200ms recompute 定时器,触发完避免 pending timer。
    await tester.pump(const Duration(milliseconds: 250));
  });
}
