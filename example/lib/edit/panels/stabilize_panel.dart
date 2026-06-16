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
