import 'package:flutter/material.dart';
import 'gyroflow_theme.dart';

/// 原生同款滑杆行:标签(灰)+ 橙色滑条 + 数值单位。
/// 数值以**显示单位**给(如平滑度 0–100%),调用方自行换算到模型单位。
class GyroSlider extends StatelessWidget {
  const GyroSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.unit = '',
    this.precision = 1,
  });

  final String label;
  final String unit;
  final double value, min, max;
  final int precision;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        SizedBox(
          width: 104,
          child: Text(label,
              style: const TextStyle(color: GfColors.textSecondary, fontSize: 13)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 62,
          child: Text('${value.toStringAsFixed(precision)}$unit',
              textAlign: TextAlign.end,
              style: const TextStyle(color: GfColors.text, fontSize: 13)),
        ),
      ]),
    );
  }
}

/// 原生同款复选框:橙色 ✓ 方框 + 标签。
class GyroCheck extends StatelessWidget {
  const GyroCheck({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(
                  color: value ? GfColors.accent : GfColors.textSecondary, width: 2),
              borderRadius: BorderRadius.circular(4),
            ),
            child: value
                ? const Text('✓',
                    style: TextStyle(
                        color: GfColors.accent, fontSize: 13, height: 1))
                : null,
          ),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(color: GfColors.text, fontSize: 14)),
        ]),
      ),
    );
  }
}

/// 原生同款下拉(平滑方式 / 裁切模式):标签 + DropdownButton。
class GyroDropdown extends StatelessWidget {
  const GyroDropdown({
    super.key,
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final List<String> options;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        SizedBox(
          width: 104,
          child: Text(label,
              style: const TextStyle(color: GfColors.textSecondary, fontSize: 13)),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: GfColors.inputBg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: DropdownButton<int>(
              isExpanded: true,
              underline: const SizedBox.shrink(),
              dropdownColor: GfColors.bgPanel,
              value: value,
              style: const TextStyle(color: GfColors.text, fontSize: 14),
              items: [
                for (var i = 0; i < options.length; i++)
                  DropdownMenuItem(value: i, child: Text(options[i])),
              ],
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ),
      ]),
    );
  }
}

/// 高级选项展开行(灰字 + 展开箭头)。
class GyroAdvToggle extends StatelessWidget {
  const GyroAdvToggle(
      {super.key, required this.label, required this.expanded, required this.onTap});
  final String label;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          Icon(expanded ? Icons.expand_less : Icons.expand_more,
              color: GfColors.textMuted, size: 18),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(color: GfColors.textMuted, fontSize: 13)),
        ]),
      ),
    );
  }
}
