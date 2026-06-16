import 'package:flutter/material.dart';

/// 设计令牌,1:1 对齐原生 `GyroflowTheme.kt`(深色 + 橙强调)。
class GfColors {
  static const accent = Color(0xFFFF8000); // 主题色(橙)
  static const text = Colors.white;
  static const textSecondary = Color(0xFF999999);
  static const textMuted = Color(0xFFBFBFBF);
  static const bg = Colors.black; // 根背景 / 预览
  static const bgBar = Color(0xFF111111); // 顶栏 / 按钮条
  static const bgTab = Color(0xFF1A1A1A);
  static const bgPanel = Color(0xFF151515); // 面板容器
  static const inputBg = Color(0xFF2C2C2E);
  static const boxBg = Color(0xFF1C1C1E);
  static const border = Color(0xFF444444);
}

/// 编辑页用的深色 ThemeData(对齐原生)。
ThemeData gyroflowTheme() {
  const accent = GfColors.accent;
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: GfColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: accent,
      secondary: accent,
      surface: GfColors.bgPanel,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: GfColors.bgBar,
      foregroundColor: GfColors.text,
      elevation: 0,
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: accent,
      thumbColor: accent,
      inactiveTrackColor: GfColors.border,
      overlayColor: Color(0x33FF8000),
    ),
    dividerTheme: const DividerThemeData(color: GfColors.border, thickness: 0.5),
    textTheme: const TextTheme(bodyMedium: TextStyle(color: GfColors.text)),
  );
}
