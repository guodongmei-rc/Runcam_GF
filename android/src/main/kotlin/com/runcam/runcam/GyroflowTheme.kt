package com.runcam.runcam

import android.graphics.Color

/**
 * Gyroflow 界面统一配色(对齐 iOS 的 Style 单例)。
 * 全项目共用一处, 改这里即全局生效; 不要在各处再写死 #RRGGBB。
 */
object GyroflowTheme {
    val ACCENT = Color.parseColor("#FF8000")          // 主题色(橙), 对齐 iOS styleAccentColor
    val TEXT = Color.WHITE                              // 主文字
    val TEXT_SECONDARY = Color.parseColor("#999999")   // 次要文字 / 标签 / 复选框未选描边
    val TEXT_TERTIARY = Color.parseColor("#888888")    // 弱提示
    val TEXT_HINT = Color.parseColor("#8C8C8C")        // 输入框 hint / 虚线占位描边
    val TEXT_MUTED = Color.parseColor("#BFBFBF")       // 高级小标题 / 虚线占位文字
    val TEXT_RESULT = Color.parseColor("#DDDDDD")      // 搜索结果行

    val BG = Color.BLACK                                // 根背景 / 预览
    val BG_BAR = Color.parseColor("#111111")           // 顶栏 / 按钮条
    val BG_TAB = Color.parseColor("#1A1A1A")           // Tab 栏
    val BG_PANEL = Color.parseColor("#151515")         // 面板容器
    val INPUT_BG = Color.parseColor("#2C2C2E")         // 搜索 / 文本输入框
    val BOX_BG = Color.parseColor("#1C1C1E")           // 数值框填充

    val BORDER = Color.parseColor("#444444")           // 数值框描边
    val OVERLAY = Color.argb(140, 0, 0, 0)             // 预览文字黑底
}
