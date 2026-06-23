import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'gyroflow_theme.dart';

/// 数字输入格式化器:逐字符校验,非法内容直接拒绝(保留旧值)。
/// [decimal] 允许一个小数点;[negative] 允许前导负号。
class NumInputFormatter extends TextInputFormatter {
  const NumInputFormatter({this.decimal = true, this.negative = false});
  final bool decimal;
  final bool negative;

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final t = newValue.text;
    if (t.isEmpty) return newValue; // 允许清空
    final sign = negative ? '-?' : '';
    final dot = decimal ? r'\.?' : '';
    final pattern = RegExp('^$sign\\d*$dot\\d*\$');
    return pattern.hasMatch(t) ? newValue : oldValue; // 不合规 → 不允许输入
  }
}

/// 便捷:按类型取格式化器列表。
List<TextInputFormatter> numFormatters(
        {bool decimal = true, bool negative = false}) =>
    [NumInputFormatter(decimal: decimal, negative: negative)];

/// 强制 GyroSlider 两行布局(标题一行、滑条一行,左对齐)的作用域。
/// 放在某个子树外层(如手机横屏参数区),其内所有 GyroSlider 强制两行;
/// 不设则按可用宽度自动判定(< 300 两行)。
class SliderLayout extends InheritedWidget {
  const SliderLayout({super.key, required this.twoRow, required super.child});
  final bool twoRow;
  static bool? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SliderLayout>()?.twoRow;
  @override
  bool updateShouldNotify(SliderLayout old) => old.twoRow != twoRow;
}

/// 标记子树内的交互控件「禁用」:无视频时参数模块仍显示、可滚动,但控件不可操作。
/// 各 Gyro 控件读取它后把回调置空 / 输入框只读(不拦截指针,故滚动照常)。
class DisableControls extends InheritedWidget {
  const DisableControls(
      {super.key, required this.disabled, required super.child});
  final bool disabled;
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DisableControls>()
          ?.disabled ??
      false;
  @override
  bool updateShouldNotify(DisableControls old) => old.disabled != disabled;
}

/// 原生同款滑杆行:标签(灰)+ 橙色滑条 + **可编辑数值输入框**(+ 单位)。
/// 数值以**显示单位**给(如平滑度 0–100%),调用方自行换算到模型单位。
class GyroSlider extends StatefulWidget {
  const GyroSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.unit = '',
    this.precision = 1,
    this.trailing,
    this.onTitleDoubleTap,
  });

  final String label;
  final String unit;
  final double value, min, max;
  final int precision;
  final ValueChanged<double> onChanged;
  final Widget? trailing; // 行尾内联控件(如帧读出方向按钮 / 视频速度链接框)
  final VoidCallback? onTitleDoubleTap; // 双击标题:恢复到加载时的值

  @override
  State<GyroSlider> createState() => _GyroSliderState();
}

class _GyroSliderState extends State<GyroSlider> {
  late final TextEditingController _ctrl =
      TextEditingController(text: _fmt(widget.value));
  final FocusNode _focus = FocusNode();

  String _fmt(double v) => v.toStringAsFixed(widget.precision);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit(); // 失焦即提交
    });
  }

  @override
  void didUpdateWidget(GyroSlider old) {
    super.didUpdateWidget(old);
    // 滑条拖动/外部改值 → 回填输入框(编辑中不打断)。
    if (!_focus.hasFocus && widget.value != old.value) {
      _ctrl.text = _fmt(widget.value);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final raw = double.tryParse(_ctrl.text.trim());
    final v = (raw ?? widget.value).clamp(widget.min, widget.max).toDouble();
    widget.onChanged(v);
    _ctrl.text = _fmt(v); // 回填 clamp 后值
  }

  @override
  Widget build(BuildContext context) {
    final disabled = DisableControls.of(context); // 无视频:可滚动但不可操作
    final title = GestureDetector(
      onDoubleTap: disabled ? null : widget.onTitleDoubleTap, // 双击恢复加载值
      behavior: HitTestBehavior.opaque,
      child: Text(widget.label,
          style: const TextStyle(color: GfColors.textSecondary, fontSize: 13)),
    );
    // 右侧:trailing(如读出方向/链接框)在上,数值输入框在下(对齐官方布局)。
    final valueBox = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (widget.trailing != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: widget.trailing!,
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 数值输入框:填充圆角样式(同「粗略大致偏移」),占位同原数值文字宽。
            SizedBox(
              width: 58,
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                enabled: !disabled, // 无视频:数值框只读
                keyboardType: TextInputType.numberWithOptions(
                    decimal: widget.precision > 0, signed: widget.min < 0),
                inputFormatters: numFormatters(
                    decimal: widget.precision > 0, negative: widget.min < 0),
                textAlign: TextAlign.end,
                textInputAction: TextInputAction.done,
                style: const TextStyle(color: GfColors.text, fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: GfColors.inputBg,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide.none),
                ),
                onSubmitted: (_) => _focus.unfocus(),
                onTapOutside: (_) => _focus.unfocus(),
              ),
            ),
            if (widget.unit.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Text(widget.unit,
                    style: const TextStyle(
                        color: GfColors.textSecondary, fontSize: 12)),
              ),
          ],
        ),
      ],
    );
    Widget buildSlider(EdgeInsetsGeometry? padding) => Slider(
          value: widget.value.clamp(widget.min, widget.max),
          min: widget.min,
          max: widget.max,
          onChanged: disabled ? null : widget.onChanged, // 无视频:滑条禁用
          padding: padding,
        );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: LayoutBuilder(builder: (context, cons) {
        // 两行布局触发:外层 SliderLayout 强制(如手机横屏参数区),或可用宽 < 300(窄右栏)。
        // 第一行 标题 + 数值/trailing,第二行 滑条占满、左缘(padding 水平 0)与标题左缘对齐。
        final twoRow = SliderLayout.of(context) ?? (cons.maxWidth < 300);
        if (twoRow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [Expanded(child: title), valueBox]),
              buildSlider(const EdgeInsets.symmetric(vertical: 6)),
            ],
          );
        }
        return Row(children: [
          SizedBox(width: 104, child: title),
          Expanded(child: buildSlider(null)),
          valueBox,
        ]);
      }),
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
    final disabled = DisableControls.of(context);
    return InkWell(
      onTap: disabled ? null : () => onChanged(!value),
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
    this.onTitleDoubleTap,
  });

  final String label;
  final List<String> options;
  final int value;
  final ValueChanged<int> onChanged;
  final VoidCallback? onTitleDoubleTap; // 双击标题:恢复到加载时的值

  @override
  Widget build(BuildContext context) {
    final disabled = DisableControls.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        if (label.isNotEmpty)
          SizedBox(
            width: 104,
            child: GestureDetector(
              onDoubleTap: disabled ? null : onTitleDoubleTap, // 双击恢复加载值
              behavior: HitTestBehavior.opaque,
              child: Text(label,
                  style: const TextStyle(
                      color: GfColors.textSecondary, fontSize: 13)),
            ),
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
              onChanged: disabled
                  ? null
                  : (v) {
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
      {super.key,
      required this.index,
      required this.onChanged,
      required this.tabs,
      this.compact = false});
  final int index;
  final ValueChanged<int> onChanged;
  final List<({IconData icon, String label})> tabs;
  final bool compact; // 紧凑模式(手机横屏):高度约减半

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
                  padding: EdgeInsets.symmetric(vertical: compact ? 4 : 10),
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
                          size: compact ? 15 : 20,
                          color: i == index ? GfColors.accent : GfColors.textSecondary),
                      SizedBox(height: compact ? 1 : 3),
                      Text(tabs[i].label,
                          style: TextStyle(
                              fontSize: compact ? 10 : 12,
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
    final disabled = DisableControls.of(context);
    return InkWell(
      onTap: disabled ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center, // 居中
          children: [
            Text(label,
                style: const TextStyle(
                    color: GfColors.accent, // 主题色
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            Icon(expanded ? Icons.expand_less : Icons.expand_more,
                color: GfColors.accent, size: 18),
          ],
        ),
      ),
    );
  }
}
