import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:runcam_gf/src/state/defaults.dart';
import 'package:runcam_gf/src/state/params_model.dart';
import '../../l10n/l10n.dart';
import '../../toast.dart';
import '../gyro_widgets.dart';
import '../gyroflow_theme.dart';

/// Stabilize 面板:结构/样式对齐原生 `GyroflowStabilizePanel`(深色 + 橙)。
/// 只通过 [model] 调参,不引用任何预览后端。平滑度/锁定量以 0–100% 显示、内部 0–1。
class StabilizePanel extends StatefulWidget {
  const StabilizePanel(
      {super.key,
      required this.model,
      this.trailing,
      this.footer,
      this.loadedValues});
  final ParamsModel model;
  /// 置于稳定参数「之上」(同一滚动内),用于放同步模块(对齐官方 同步→稳定 顺序)。
  final Widget? trailing;
  /// 追加到面板「末尾」(同一滚动内),用于在稳定模块下方放导出模块。
  final Widget? footer;
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
        builder: (context, _) {
          final l10n = context.l10n;
          final method = m.smoothingMethod; // 0=无平滑 1=默认 2=纯3D 3=固定摄像头
          return ListView(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
          children: [
            // 同步模块:置于「平滑方式」之上(对齐官方右栏顺序 同步→稳定)。
            if (widget.trailing != null) widget.trailing!,
            // 稳定模块标题(与「同步」标题同款)。
            Text(l10n.stabSection,
                style: const TextStyle(
                    color: GfColors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            GyroDropdown(
              label: l10n.stabSmoothingMethod,
              options: [l10n.stabNone, l10n.stabDefault, l10n.stabPlain3D, l10n.stabFixedCamera],
              value: m.smoothingMethod.clamp(0, 3),
              onChanged: (v) => m.smoothingMethod = v,
              onTitleDoubleTap:
                  _reset('smoothingMethod', (v) => m.smoothingMethod = v.round()),
            ),
            // ── 主平滑控件随平滑方式切换(对齐官方)──
            // 无平滑(0):不显示任何平滑控件。
            // 默认(1):平滑度(按轴关→总;开→三轴,对齐原生互斥)。
            if (method == 1)
              if (!m.perAxis)
                GyroSlider(
                  key: const Key('stab_smoothness'),
                  label: l10n.stabSmoothness, unit: '%', min: 0, max: 100,
                  value: m.smoothness * 100,
                  onChanged: (v) => m.smoothness = v / 100,
                  onTitleDoubleTap: _reset('smoothness', (v) => m.smoothness = v),
                )
              else ...[
                GyroSlider(
                  key: const Key('stab_smoothness_pitch'),
                  label: l10n.stabSmoothnessPitch, unit: '%', min: 0, max: 100,
                  value: m.smoothnessPitch * 100,
                  onChanged: (v) => m.smoothnessPitch = v / 100,
                  onTitleDoubleTap:
                      _reset('smoothnessPitch', (v) => m.smoothnessPitch = v),
                ),
                GyroSlider(
                  label: l10n.stabSmoothnessYaw, unit: '%', min: 0, max: 100,
                  value: m.smoothnessYaw * 100,
                  onChanged: (v) => m.smoothnessYaw = v / 100,
                  onTitleDoubleTap:
                      _reset('smoothnessYaw', (v) => m.smoothnessYaw = v),
                ),
                GyroSlider(
                  label: l10n.stabSmoothnessRoll, unit: '%', min: 0, max: 100,
                  value: m.smoothnessRoll * 100,
                  onChanged: (v) => m.smoothnessRoll = v / 100,
                  onTitleDoubleTap:
                      _reset('smoothnessRoll', (v) => m.smoothnessRoll = v),
                ),
              ],
            // 纯3D(2):平滑度改为时间常数,单位秒(0.01–10.00),对齐官方。
            if (method == 2)
              GyroSlider(
                key: const Key('stab_plain3d_time'),
                label: l10n.stabSmoothness, unit: l10n.stabUnitSec,
                min: 0.01, max: 10, precision: 2,
                value: m.plain3dTimeConstant,
                onChanged: (v) => m.plain3dTimeConstant = v,
                onTitleDoubleTap: _resetDefault(
                    ParamsDefaults.plain3dTimeConstant, (v) => m.plain3dTimeConstant = v),
              ),
            // 固定摄像头(3):用角度替代平滑度,顺序 Roll/Pitch/Yaw,双击标题回默认值。
            if (method == 3) ...[
              GyroSlider(
                key: const Key('stab_fixed_roll'),
                label: l10n.stabFixedRoll, unit: '°', min: -180, max: 180, precision: 2,
                value: m.fixedRoll,
                onChanged: (v) => m.fixedRoll = v,
                onTitleDoubleTap:
                    _resetDefault(ParamsDefaults.fixedRoll, (v) => m.fixedRoll = v),
              ),
              GyroSlider(
                key: const Key('stab_fixed_pitch'),
                label: l10n.stabFixedPitch, unit: '°', min: -90, max: 90, precision: 2,
                value: m.fixedPitch,
                onChanged: (v) => m.fixedPitch = v,
                onTitleDoubleTap:
                    _resetDefault(ParamsDefaults.fixedPitch, (v) => m.fixedPitch = v),
              ),
              GyroSlider(
                label: l10n.stabFixedYaw, unit: '°', min: -180, max: 180, precision: 2,
                value: m.fixedYaw,
                onChanged: (v) => m.fixedYaw = v,
                onTitleDoubleTap:
                    _resetDefault(ParamsDefaults.fixedYaw, (v) => m.fixedYaw = v),
              ),
            ],
            // ── 高级选项随平滑方式联动 ──
            // 无平滑(0)/固定(3):不显示高级区;默认(1):全部;纯3D(2):仅「仅修剪范围」。
            if (method == 1 || method == 2) ...[
              GyroAdvToggle(
                label: l10n.stabAdvanced,
                expanded: _advExpanded,
                onTap: () => setState(() => _advExpanded = !_advExpanded),
              ),
              if (_advExpanded) ...[
                if (method == 1)
                  GyroCheck(
                    key: const Key('stab_per_axis'),
                    label: l10n.stabPerAxis,
                    value: m.perAxis,
                    onChanged: (v) => m.perAxis = v,
                  ),
                GyroCheck(
                  label: l10n.stabOnlyTrimRange,
                  value: m.trimRangeOnly,
                  onChanged: (v) => m.trimRangeOnly = v,
                ),
                if (method == 1)
                  GyroSlider(
                    label: l10n.stabMaxSmoothness, unit: l10n.stabUnitSec, min: 0.1, max: 5, precision: 2,
                    value: m.maxSmoothnessSec,
                    onChanged: (v) => m.maxSmoothnessSec = v,
                    onTitleDoubleTap:
                        _reset('maxSmoothnessSec', (v) => m.maxSmoothnessSec = v),
                  ),
                if (method == 1)
                  GyroSlider(
                    label: l10n.stabMaxSmoothnessHighVel, unit: l10n.stabUnitSec, min: 0.01, max: 1, precision: 2,
                    value: m.alphaHighVelSec,
                    onChanged: (v) => m.alphaHighVelSec = v,
                    onTitleDoubleTap:
                        _reset('alphaHighVelSec', (v) => m.alphaHighVelSec = v),
                  ),
              ],
            ],
            const Divider(),
            GyroCheck(
              key: const Key('stab_horizon'),
              label: l10n.stabLockHorizon,
              value: m.horizonLock,
              onChanged: (v) => m.horizonLock = v,
            ),
            if (m.horizonLock) ...[
              GyroSlider(
                label: l10n.stabLockAmount, unit: '%', min: 0, max: 100, precision: 0,
                value: m.horizonLockAmount, // 已是 0–100 百分比(默认 100)
                onChanged: (v) => m.horizonLockAmount = v,
                onTitleDoubleTap:
                    _reset('horizonLockAmount', (v) => m.horizonLockAmount = v),
              ),
              GyroSlider(
                label: l10n.stabRollAngleCorrection, unit: '°', min: -180, max: 180,
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
                l10n.stabMaxRotationZoom(
                  m.maxAnglePitch.toStringAsFixed(1),
                  m.maxAngleYaw.toStringAsFixed(1),
                  m.maxAngleRoll.toStringAsFixed(1),
                  (m.minFov > 0 ? 100 / m.minFov : 0).toStringAsFixed(1),
                ),
                style: const TextStyle(
                    color: GfColors.textMuted, fontSize: 12, height: 1.5),
              ),
            ),
            // 缩放方式(对齐官方 zooming:No zooming/Dynamic zooming/Static zoom →
            // 官方 zh_CN 措辞「无缩放/动态缩放/静态缩放」)。去掉前置标题,整行下拉。
            GyroDropdown(
              label: '',
              options: [l10n.stabNoZooming, l10n.stabDynamicZooming, l10n.stabStaticZoom],
              value: m.croppingMode.clamp(0, 2),
              onChanged: (v) => m.croppingMode = v,
            ),
            // 缩放限额:非无平滑/固定摄像头时显示(含无缩放,对齐需求)。
            if (method != 0 && method != 3)
              GyroSlider(
                label: l10n.stabZoomLimit, unit: '%', min: 100, max: 300, precision: 0,
                value: m.maxZoomPercent,
                onChanged: (v) => m.maxZoomPercent = v,
                onTitleDoubleTap:
                    _reset('maxZoomPercent', (v) => m.maxZoomPercent = v),
              ),
            // 缩放速度:仅动态缩放(croppingMode==1)显示。
            if (m.croppingMode == 1)
              GyroSlider(
                label: l10n.stabZoomingSpeed, unit: l10n.stabUnitSec, min: 0.1, max: 15, precision: 2,
                value: m.adaptiveZoomSec,
                onChanged: (v) => m.adaptiveZoomSec = v,
                onTitleDoubleTap:
                    _reset('adaptiveZoomSec', (v) => m.adaptiveZoomSec = v),
              ),
            GyroSlider(
              label: l10n.stabLensCorrection, unit: '%', min: 0, max: 100, precision: 0,
              value: m.lensCorrection * 100,
              onChanged: (v) => m.lensCorrection = v / 100,
              onTitleDoubleTap:
                  _reset('lensCorrection', (v) => m.lensCorrection = v),
            ),
            // ===== 第二个高级选项区(缩放/卷帘/视频速度/附加3D旋转)=====
            GyroAdvToggle(
              label: l10n.stabAdvanced,
              expanded: _adv2,
              onTap: () => setState(() => _adv2 = !_adv2),
            ),
            if (_adv2) ...[
              GyroSlider(
                label: l10n.stabFov, min: 0.3, max: 3, precision: 2,
                value: m.fov,
                onChanged: (v) => m.fov = v,
                onTitleDoubleTap: _reset('fov', (v) => m.fov = v),
              ),
              GyroCheck(
                label: l10n.stabRollingShutter,
                value: m.rsCorrection,
                onChanged: (v) => m.rsCorrection = v,
              ),
              if (m.rsCorrection)
                GyroSlider(
                  label: l10n.stabFrameReadoutTime, unit: l10n.stabUnitMs, min: 0, max: 50, precision: 2,
                  value: m.frameReadoutMs,
                  onChanged: (v) => m.frameReadoutMs = v,
                  trailing: _readoutDirInline(), // 行尾:读出方向按钮
                  onTitleDoubleTap:
                      _reset('frameReadoutMs', (v) => m.frameReadoutMs = v),
                ),
              GyroSlider(
                label: l10n.stabVideoSpeed, unit: '%', min: 10, max: 1000, precision: 0,
                value: m.videoSpeed * 100,
                onChanged: (v) => m.videoSpeed = v / 100,
                trailing: _linkChecksInline(), // 行尾:三个链接复选框
                onTitleDoubleTap: _reset('videoSpeed', (v) => m.videoSpeed = v),
              ),
              if (m.croppingMode == 1)
                GyroDropdown(
                  label: l10n.stabZoomingMethod,
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
              if (m.croppingMode != 0 && method != 0 && method != 3)
                GyroSlider(
                  label: l10n.stabZoomLimitIterations, min: 1, max: 15, precision: 0,
                  value: m.maxZoomIterations.toDouble(),
                  onChanged: (v) => m.maxZoomIterations = v.round(),
                  onTitleDoubleTap: _reset(
                      'maxZoomIterations', (v) => m.maxZoomIterations = v.round()),
                ),
            ],
            // 末尾:导出模块(在稳定模块下方,同一滚动内)。
            if (widget.footer != null) widget.footer!,
          ],
        );
        },
      ),
    );
  }

  // 双击标题:恢复到「加载值」快照。无快照(未加载/无此键)则不可双击(返回 null)。
  VoidCallback? _reset(String key, void Function(double) setRaw) {
    final lv = widget.loadedValues;
    if (lv == null || !lv.containsKey(key)) return null;
    return () {
      setRaw(lv[key]!);
      _toast(context.l10n.stabRestoredLoadedValues);
    };
  }

  // 双击标题:恢复到「默认值」(用于无「加载值」语义的参数,如固定摄像头角度)。
  VoidCallback _resetDefault(double def, void Function(double) setRaw) => () {
        setRaw(def);
        _toast(context.l10n.stabRestoredLoadedValues);
      };

  void _toast(String msg) => showAppToast(msg);

  // 帧读出方向:行尾小方按钮,箭头随方向旋转([0,180,-90,90]°),点击循环 + toast。
  Widget _readoutDirInline() {
    final l10n = context.l10n;
    final names = [
      l10n.stabReadoutDirTopBottom,
      l10n.stabReadoutDirBottomTop,
      l10n.stabReadoutDirLeftRight,
      l10n.stabReadoutDirRightLeft,
    ];
    const anglesDeg = [0.0, 180.0, -90.0, 90.0];
    final dir = m.frameReadoutDirection.clamp(0, 3);
    return GestureDetector(
      onTap: () {
        final next = (m.frameReadoutDirection + 1) % 4;
        m.frameReadoutDirection = next;
        _toast(l10n.stabFrameReadoutDirToast(names[next]));
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
  Widget _linkChecksInline() {
    final l10n = context.l10n;
    return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _miniCheck(l10n.stabLinkSmoothing, m.videoSpeedAffectsSmoothing,
              (v) => m.videoSpeedAffectsSmoothing = v),
          const SizedBox(width: 4),
          _miniCheck(l10n.stabLinkZoomingSpeed, m.videoSpeedAffectsZooming,
              (v) => m.videoSpeedAffectsZooming = v),
          const SizedBox(width: 4),
          _miniCheck(l10n.stabLinkZoomingLimit, m.videoSpeedAffectsZoomingLimit,
              (v) => m.videoSpeedAffectsZoomingLimit = v),
        ],
      );
  }

  Widget _miniCheck(String label, bool value, ValueChanged<bool> onChanged) =>
      GestureDetector(
        onTap: () {
          onChanged(!value);
          _toast(context.l10n.stabLinkToggleToast(
              label, !value ? context.l10n.stabEnabled : context.l10n.stabDisabled));
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
