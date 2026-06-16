import 'package:flutter/material.dart';
import 'package:runcam_gf/runcam_gf.dart';
import '../gyro_widgets.dart';
import '../gyroflow_theme.dart';

/// Stabilize 面板:结构/样式对齐原生 `GyroflowStabilizePanel`(深色 + 橙)。
/// 只通过 [model] 调参,不引用任何预览后端。平滑度/锁定量以 0–100% 显示、内部 0–1。
class StabilizePanel extends StatefulWidget {
  const StabilizePanel({super.key, required this.model});
  final ParamsModel model;
  @override
  State<StabilizePanel> createState() => _StabilizePanelState();
}

class _StabilizePanelState extends State<StabilizePanel> {
  bool _advExpanded = false;
  ParamsModel get m => widget.model;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: GfColors.bgPanel,
      child: AnimatedBuilder(
        animation: m,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
          children: [
            GyroDropdown(
              label: '平滑方式',
              options: const ['无平滑', '默认', '纯3D', '固定摄像头'],
              value: m.smoothingMethod.clamp(0, 3),
              onChanged: (v) => m.smoothingMethod = v,
            ),
            // 按轴关→显示总平滑度;开→显示三轴(对齐原生互斥)。
            if (!m.perAxis)
              GyroSlider(
                key: const Key('stab_smoothness'),
                label: '平滑度', unit: '%', min: 0, max: 100,
                value: m.smoothness * 100,
                onChanged: (v) => m.smoothness = v / 100,
              )
            else ...[
              GyroSlider(
                key: const Key('stab_smoothness_pitch'),
                label: 'Pitch 平滑度', unit: '%', min: 0, max: 100,
                value: m.smoothnessPitch * 100,
                onChanged: (v) => m.smoothnessPitch = v / 100,
              ),
              GyroSlider(
                label: 'Yaw 平滑度', unit: '%', min: 0, max: 100,
                value: m.smoothnessYaw * 100,
                onChanged: (v) => m.smoothnessYaw = v / 100,
              ),
              GyroSlider(
                label: 'Roll 平滑度', unit: '%', min: 0, max: 100,
                value: m.smoothnessRoll * 100,
                onChanged: (v) => m.smoothnessRoll = v / 100,
              ),
            ],
            GyroAdvToggle(
              label: '高级选项',
              expanded: _advExpanded,
              onTap: () => setState(() => _advExpanded = !_advExpanded),
            ),
            if (_advExpanded) ...[
              GyroCheck(
                key: const Key('stab_per_axis'),
                label: '按轴',
                value: m.perAxis,
                onChanged: (v) => m.perAxis = v,
              ),
              GyroCheck(
                label: '仅限修剪范围内',
                value: m.trimRangeOnly,
                onChanged: (v) => m.trimRangeOnly = v,
              ),
              GyroSlider(
                label: '最大平滑度', unit: '秒', min: 0, max: 3, precision: 2,
                value: m.maxSmoothnessSec,
                onChanged: (v) => m.maxSmoothnessSec = v,
              ),
              GyroSlider(
                label: '高速最大平滑度', unit: '秒', min: 0, max: 1, precision: 2,
                value: m.alphaHighVelSec,
                onChanged: (v) => m.alphaHighVelSec = v,
              ),
            ],
            const Divider(),
            GyroCheck(
              key: const Key('stab_horizon'),
              label: '锁定地平线',
              value: m.horizonLock,
              onChanged: (v) => m.horizonLock = v,
            ),
            if (m.horizonLock) ...[
              GyroSlider(
                label: '锁定量', unit: '%', min: 0, max: 100, precision: 0,
                value: m.horizonLockAmount * 100,
                onChanged: (v) => m.horizonLockAmount = v / 100,
              ),
              GyroSlider(
                label: 'Roll 角度校正', unit: '°', min: -180, max: 180,
                value: m.horizonLockRoll,
                onChanged: (v) => m.horizonLockRoll = v,
              ),
            ],
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '最大旋转: Pitch ${m.maxAnglePitch.toStringAsFixed(1)}°, '
                'Yaw ${m.maxAngleYaw.toStringAsFixed(1)}°, '
                'Roll ${m.maxAngleRoll.toStringAsFixed(1)}°\n'
                '最大缩放: ${(m.minFov > 0 ? 100 / m.minFov : 0).toStringAsFixed(1)}%',
                style: const TextStyle(
                    color: GfColors.textMuted, fontSize: 12, height: 1.5),
              ),
            ),
            GyroDropdown(
              label: '裁切',
              options: const ['不缩放', '动态缩放', '静态裁剪'],
              value: m.croppingMode.clamp(0, 2),
              onChanged: (v) => m.croppingMode = v,
            ),
            GyroSlider(
              label: '最大缩放', unit: '%', min: 100, max: 300, precision: 0,
              value: m.maxZoomPercent,
              onChanged: (v) => m.maxZoomPercent = v,
            ),
            GyroSlider(
              label: '镜头校正', min: 0, max: 1, precision: 2,
              value: m.lensCorrection,
              onChanged: (v) => m.lensCorrection = v,
            ),
          ],
        ),
      ),
    );
  }
}
