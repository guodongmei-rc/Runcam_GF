import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:runcam_gf/runcam_gf.dart';
import '../gyro_widgets.dart';
import '../gyroflow_theme.dart';

/// Stabilize 面板:结构/样式对齐原生 `GyroflowStabilizePanel`(深色 + 橙)。
/// 只通过 [model] 调参,不引用任何预览后端。平滑度/锁定量以 0–100% 显示、内部 0–1。
class StabilizePanel extends StatefulWidget {
  const StabilizePanel(
      {super.key, required this.model, this.trailing, this.loadedValues});
  final ParamsModel model;
  /// 追加到面板末尾(同一滚动内),用于在「参数」下方放同步模块。
  final Widget? trailing;
  /// 「加载镜头(及覆盖)后的参数值」快照(原始模型单位):双击行标题恢复到这些值。
  final Map<String, double>? loadedValues;
  @override
  State<StabilizePanel> createState() => _StabilizePanelState();
}

class _StabilizePanelState extends State<StabilizePanel> {
  bool _advExpanded = false; // 平滑方式高级
  bool _adv2 = false; // 缩放/附加 高级(第二个高级选项区)
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
            // 同步模块:置于「平滑方式」之上(对齐官方右栏顺序 同步→稳定)。
            if (widget.trailing != null) widget.trailing!,
            // 稳定模块标题(与「同步」标题同款)。
            const Text('稳定',
                style: TextStyle(
                    color: GfColors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            GyroDropdown(
              label: '平滑方式',
              options: const ['无平滑', '默认', '纯3D', '固定摄像头'],
              value: m.smoothingMethod.clamp(0, 3),
              onChanged: (v) => m.smoothingMethod = v,
              onTitleDoubleTap:
                  _reset('smoothingMethod', (v) => m.smoothingMethod = v.round()),
            ),
            // 按轴关→显示总平滑度;开→显示三轴(对齐原生互斥)。
            if (!m.perAxis)
              GyroSlider(
                key: const Key('stab_smoothness'),
                label: '平滑度', unit: '%', min: 0, max: 100,
                value: m.smoothness * 100,
                onChanged: (v) => m.smoothness = v / 100,
                onTitleDoubleTap: _reset('smoothness', (v) => m.smoothness = v),
              )
            else ...[
              GyroSlider(
                key: const Key('stab_smoothness_pitch'),
                label: 'Pitch 平滑度', unit: '%', min: 0, max: 100,
                value: m.smoothnessPitch * 100,
                onChanged: (v) => m.smoothnessPitch = v / 100,
                onTitleDoubleTap:
                    _reset('smoothnessPitch', (v) => m.smoothnessPitch = v),
              ),
              GyroSlider(
                label: 'Yaw 平滑度', unit: '%', min: 0, max: 100,
                value: m.smoothnessYaw * 100,
                onChanged: (v) => m.smoothnessYaw = v / 100,
                onTitleDoubleTap:
                    _reset('smoothnessYaw', (v) => m.smoothnessYaw = v),
              ),
              GyroSlider(
                label: 'Roll 平滑度', unit: '%', min: 0, max: 100,
                value: m.smoothnessRoll * 100,
                onChanged: (v) => m.smoothnessRoll = v / 100,
                onTitleDoubleTap:
                    _reset('smoothnessRoll', (v) => m.smoothnessRoll = v),
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
                label: '最大平滑度', unit: '秒', min: 0.1, max: 5, precision: 2,
                value: m.maxSmoothnessSec,
                onChanged: (v) => m.maxSmoothnessSec = v,
                onTitleDoubleTap:
                    _reset('maxSmoothnessSec', (v) => m.maxSmoothnessSec = v),
              ),
              GyroSlider(
                label: '高速最大平滑度', unit: '秒', min: 0.01, max: 1, precision: 2,
                value: m.alphaHighVelSec,
                onChanged: (v) => m.alphaHighVelSec = v,
                onTitleDoubleTap:
                    _reset('alphaHighVelSec', (v) => m.alphaHighVelSec = v),
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
                value: m.horizonLockAmount, // 已是 0–100 百分比(默认 100)
                onChanged: (v) => m.horizonLockAmount = v,
                onTitleDoubleTap:
                    _reset('horizonLockAmount', (v) => m.horizonLockAmount = v),
              ),
              GyroSlider(
                label: 'Roll 角度校正', unit: '°', min: -180, max: 180,
                value: m.horizonLockRoll,
                onChanged: (v) => m.horizonLockRoll = v,
                onTitleDoubleTap:
                    _reset('horizonLockRoll', (v) => m.horizonLockRoll = v),
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
            // 缩放方式(对齐官方 zooming:No zooming/Dynamic zooming/Static zoom →
            // 官方 zh_CN 措辞「无缩放/动态缩放/静态缩放」)。去掉前置标题,整行下拉。
            GyroDropdown(
              label: '',
              options: const ['无缩放', '动态缩放', '静态缩放'],
              value: m.croppingMode.clamp(0, 2),
              onChanged: (v) => m.croppingMode = v,
            ),
            // 缩放限制:仅动态/静态缩放(method 1/2)显示。
            if (m.croppingMode != 0)
              GyroSlider(
                label: '缩放限制', unit: '%', min: 100, max: 300, precision: 0,
                value: m.maxZoomPercent,
                onChanged: (v) => m.maxZoomPercent = v,
                onTitleDoubleTap:
                    _reset('maxZoomPercent', (v) => m.maxZoomPercent = v),
              ),
            // 缩放速度:仅动态缩放(croppingMode==1)显示。
            if (m.croppingMode == 1)
              GyroSlider(
                label: '缩放速度', unit: '秒', min: 0.1, max: 15, precision: 2,
                value: m.adaptiveZoomSec,
                onChanged: (v) => m.adaptiveZoomSec = v,
                onTitleDoubleTap:
                    _reset('adaptiveZoomSec', (v) => m.adaptiveZoomSec = v),
              ),
            GyroSlider(
              label: '镜头校正', unit: '%', min: 0, max: 100, precision: 0,
              value: m.lensCorrection * 100,
              onChanged: (v) => m.lensCorrection = v / 100,
              onTitleDoubleTap:
                  _reset('lensCorrection', (v) => m.lensCorrection = v),
            ),
            // ===== 第二个高级选项区(缩放/卷帘/视频速度/附加3D旋转)=====
            GyroAdvToggle(
              label: '高级选项',
              expanded: _adv2,
              onTap: () => setState(() => _adv2 = !_adv2),
            ),
            if (_adv2) ...[
              GyroSlider(
                label: '视场角', min: 0.3, max: 3, precision: 2,
                value: m.fov,
                onChanged: (v) => m.fov = v,
                onTitleDoubleTap: _reset('fov', (v) => m.fov = v),
              ),
              GyroCheck(
                label: '卷帘快门校正',
                value: m.rsCorrection,
                onChanged: (v) => m.rsCorrection = v,
              ),
              if (m.rsCorrection)
                GyroSlider(
                  label: '帧读出时间', unit: '毫秒', min: 0, max: 50, precision: 2,
                  value: m.frameReadoutMs,
                  onChanged: (v) => m.frameReadoutMs = v,
                  trailing: _readoutDirInline(), // 行尾:读出方向按钮
                  onTitleDoubleTap:
                      _reset('frameReadoutMs', (v) => m.frameReadoutMs = v),
                ),
              GyroSlider(
                label: '视频速度', unit: '%', min: 10, max: 1000, precision: 0,
                value: m.videoSpeed * 100,
                onChanged: (v) => m.videoSpeed = v / 100,
                trailing: _linkChecksInline(), // 行尾:三个链接复选框
                onTitleDoubleTap: _reset('videoSpeed', (v) => m.videoSpeed = v),
              ),
              if (m.croppingMode == 1)
                GyroDropdown(
                  label: '缩放方式',
                  options: const ['Gaussian filter', 'Envelope follower'],
                  value: m.zoomingMethod.clamp(0, 1),
                  onChanged: (v) => m.zoomingMethod = v,
                  onTitleDoubleTap:
                      _reset('zoomingMethod', (v) => m.zoomingMethod = v.round()),
                ),
              GyroSlider(
                label: 'Pitch', unit: '°', min: -180, max: 180, precision: 2,
                value: m.addPitch,
                onChanged: (v) => m.addPitch = v,
                onTitleDoubleTap: _reset('addPitch', (v) => m.addPitch = v),
              ),
              GyroSlider(
                label: 'Yaw', unit: '°', min: -180, max: 180, precision: 2,
                value: m.addYaw,
                onChanged: (v) => m.addYaw = v,
                onTitleDoubleTap: _reset('addYaw', (v) => m.addYaw = v),
              ),
              GyroSlider(
                label: 'Roll', unit: '°', min: -180, max: 180, precision: 2,
                value: m.addRoll,
                onChanged: (v) => m.addRoll = v,
                onTitleDoubleTap: _reset('addRoll', (v) => m.addRoll = v),
              ),
              if (m.croppingMode != 0)
                GyroSlider(
                  label: '缩放限额迭代次数', min: 1, max: 15, precision: 0,
                  value: m.maxZoomIterations.toDouble(),
                  onChanged: (v) => m.maxZoomIterations = v.round(),
                  onTitleDoubleTap: _reset(
                      'maxZoomIterations', (v) => m.maxZoomIterations = v.round()),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // 双击标题:恢复到「加载值」快照。无快照(未加载/无此键)则不可双击(返回 null)。
  VoidCallback? _reset(String key, void Function(double) setRaw) {
    final lv = widget.loadedValues;
    if (lv == null || !lv.containsKey(key)) return null;
    return () {
      setRaw(lv[key]!);
      _toast('已恢复加载值');
    };
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars() // 清掉当前/排队的,不堆积
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
      ));
  }

  // 帧读出方向:行尾小方按钮,箭头随方向旋转([0,180,-90,90]°),点击循环 + toast。
  Widget _readoutDirInline() {
    const names = ['上→下', '下→上', '左→右', '右→左'];
    const anglesDeg = [0.0, 180.0, -90.0, 90.0];
    final dir = m.frameReadoutDirection.clamp(0, 3);
    return GestureDetector(
      onTap: () {
        final next = (m.frameReadoutDirection + 1) % 4;
        m.frameReadoutDirection = next;
        _toast('帧读出方向:${names[next]}');
      },
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: GfColors.accent),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Transform.rotate(
          angle: anglesDeg[dir] * math.pi / 180.0,
          child: const Icon(Icons.arrow_downward, size: 14, color: GfColors.accent),
        ),
      ),
    );
  }

  // 视频速度链接:行尾三个小复选框(无标签,对齐官方),切换 + toast。
  Widget _linkChecksInline() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _miniCheck('链接平滑', m.videoSpeedAffectsSmoothing,
              (v) => m.videoSpeedAffectsSmoothing = v),
          const SizedBox(width: 4),
          _miniCheck('链接缩放速度', m.videoSpeedAffectsZooming,
              (v) => m.videoSpeedAffectsZooming = v),
          const SizedBox(width: 4),
          _miniCheck('链接缩放限制', m.videoSpeedAffectsZoomingLimit,
              (v) => m.videoSpeedAffectsZoomingLimit = v),
        ],
      );

  Widget _miniCheck(String label, bool value, ValueChanged<bool> onChanged) =>
      GestureDetector(
        onTap: () {
          onChanged(!value);
          _toast('$label:${!value ? "已开启" : "已关闭"}');
        },
        child: Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(
                color: value ? GfColors.accent : GfColors.textSecondary,
                width: 2),
            borderRadius: BorderRadius.circular(3),
          ),
          child: value
              ? const Text('✓',
                  style: TextStyle(
                      color: GfColors.accent, fontSize: 10, height: 1))
              : null,
        ),
      );
}
