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

/// 原生同款大号橙色按钮(暂停 / 开启防抖 那种,全宽、半透明白字)。
class GyroBigButton extends StatelessWidget {
  const GyroBigButton(
      {super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return SizedBox(
      height: 52,
      child: Material(
        color: enabled ? GfColors.accent : GfColors.accent.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onPressed,
          child: Center(
            child: Text(label,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: enabled ? 0.95 : 0.55),
                    fontSize: 17,
                    fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    );
  }
}

/// 原生同款底部 Tab(输入 / 参数 / 导出),选中=橙色 + 下划线。
class GyroTabBar extends StatelessWidget {
  const GyroTabBar(
      {super.key, required this.index, required this.onChanged, required this.tabs});
  final int index;
  final ValueChanged<int> onChanged;
  final List<({IconData icon, String label})> tabs;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: GfColors.bgTab,
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            Expanded(
              child: InkWell(
                onTap: () => onChanged(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: i == index ? GfColors.accent : Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(tabs[i].icon,
                          size: 20,
                          color: i == index ? GfColors.accent : GfColors.textSecondary),
                      const SizedBox(height: 3),
                      Text(tabs[i].label,
                          style: TextStyle(
                              fontSize: 12,
                              color: i == index
                                  ? GfColors.accent
                                  : GfColors.textSecondary)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
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
