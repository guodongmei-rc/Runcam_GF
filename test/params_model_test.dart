import 'package:flutter_test/flutter_test.dart';
import 'package:runcam_gf/src/state/defaults.dart';
import 'package:runcam_gf/src/state/engine_bridge.dart';
import 'package:runcam_gf/src/state/params_model.dart';

/// 计数 + 可控返回的假桥。记录每个方法的调用。
class FakeEngineBridge implements EngineBridge {
  int recomputeCalls = 0;
  final List<List<Object?>> smoothingParamCalls = [];
  final List<List<Object?>> horizonLockCalls = [];
  final List<List<Object?>> adaptiveZoomCalls = [];
  final List<bool> showDetectedCalls = [];
  final List<bool> showOpticalCalls = [];
  final List<double> imuLpfCalls = [];
  final List<List<Object?>> videoSpeedCalls = [];
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
  Future<void> setStabEnabled(bool enabled) async {}
  @override
  Future<void> setImuLpf(double hz) async {
    imuLpfCalls.add(hz);
  }
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
  Future<void> setVideoSpeed(double s, bool a, bool b, bool c) async {
    videoSpeedCalls.add([s, a, b, c]);
  }
  @override
  Future<void> setOutputSizeExact(int width, int height) async {}
  @override
  Future<void> setBackgroundColor(double r, double g, double b, double a) async {}
  @override
  Future<void> setBackgroundMode(int mode) async {}
  @override
  Future<void> setShowSafeArea(bool show) async {}
  @override
  Future<void> setShowDetectedFeatures(bool show) async {
    showDetectedCalls.add(show);
  }
  @override
  Future<void> setShowOpticalFlow(bool show) async {
    showOpticalCalls.add(show);
  }
}

void main() {
  // 防抖窗口 200ms;用略大于它的真实延时推进。
  const settle = Duration(milliseconds: 280);
  const within = Duration(milliseconds: 100);

  test('改 smoothness:200ms 内不 recompute,之后恰好 1 次并回填 minFov', () async {
    final fake = FakeEngineBridge()..minFovToReturn = 1.5;
    final model = ParamsModel(fake);

    model.smoothness = 0.7; // 不同于默认 0.5,确保触发变更(默认值见 ParamsDefaults.smoothness)
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

  test('导出参数 exportBitrateMbps:零引擎调用,值已存', () async {
    final fake = FakeEngineBridge();
    final model = ParamsModel(fake);
    model.exportBitrateMbps = 80; // 默认 63,80≠63 触发变更
    await Future<void>.delayed(settle);
    expect(fake.recomputeCalls, 0, reason: '不接 FFI,不触发 recompute');
    expect(model.exportBitrateMbps, 80);
    model.dispose();
  });

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

  test('showDetectedFeatures:推 FFI 但不 recompute(绘制标志)', () async {
    final fake = FakeEngineBridge();
    final model = ParamsModel(fake);

    model.showDetectedFeatures = true; // 默认 false
    expect(fake.showDetectedCalls, [true]);

    await Future<void>.delayed(settle);
    expect(fake.recomputeCalls, 0, reason: '绘制标志不触发 recompute');
    model.dispose();
  });

  test('showOpticalFlow:推 FFI 但不 recompute(绘制标志)', () async {
    final fake = FakeEngineBridge();
    final model = ParamsModel(fake);

    model.showOpticalFlow = true; // 默认 false
    expect(fake.showOpticalCalls, [true]);

    await Future<void>.delayed(settle);
    expect(fake.recomputeCalls, 0, reason: '绘制标志不触发 recompute');
    model.dispose();
  });

  test('imuLpfHz:接 FFI + recompute 一次', () async {
    final fake = FakeEngineBridge();
    final model = ParamsModel(fake);

    model.imuLpfHz = 10.0; // 默认 0
    expect(fake.imuLpfCalls, [10.0]);

    await Future<void>.delayed(settle);
    expect(fake.recomputeCalls, 1, reason: '同步组里唯一接 FFI 且 recompute 的');
    model.dispose();
  });

  test('gyroOffsetMs:只存值,不接 FFI 不 recompute', () async {
    final fake = FakeEngineBridge();
    final model = ParamsModel(fake);

    model.gyroOffsetMs = 100.0; // 默认 0
    await Future<void>.delayed(settle);

    expect(fake.recomputeCalls, 0, reason: '不触发 recompute');
    expect(fake.imuLpfCalls, isEmpty, reason: '不应误推 setImuLpf');
    expect(model.gyroOffsetMs, 100.0, reason: '值已存');
    model.dispose();
  });

  test('videoSpeed:下限 clamp 到 0.0001', () async {
    final fake = FakeEngineBridge();
    final model = ParamsModel(fake);

    model.videoSpeed = 0.0; // 默认 1.0,clamp 下限 0.0001
    expect(model.videoSpeed, 0.0001);
    expect(fake.videoSpeedCalls.single[0], 0.0001, reason: '推 FFI 用 clamp 后的值');

    await Future<void>.delayed(settle);
    model.dispose();
  });
}
