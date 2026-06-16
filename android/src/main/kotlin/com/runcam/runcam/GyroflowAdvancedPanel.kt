package com.runcam.runcam

import android.content.Context
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView

/**
 * 高级面板(对齐官方 Advanced）。与「同步」「稳定」同级的独立模块, 不折叠。
 * 含: 预览分辨率 / 渲染背景(Hex) / 背景模式(纯色·边缘拉伸·边缘镜像·羽化留边) / 安全区域指示。
 * 每个控件变更 → onApply { GyroflowNative.nativeSetXxx(...) } 由宿主在后台线程跑 + 重渲。
 */
class GyroflowAdvancedPanel(
    private val ctx: Context,
    private val onApply: (() -> Unit) -> Unit,
) {
    val root: LinearLayout

    private var bgMode = 0               // 0纯色 1边缘拉伸 2边缘镜像 3羽化留边
    private val bgColorRow: View         // 渲染背景 Hex 行(仅纯色模式显示)
    private val marginSub: LinearLayout  // 留边/羽化(仅羽化留边模式显示)

    init {
        root = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, ctx.dp(8), 0, 0)
        }

        root.addView(title("高级"))

        // 预览分辨率(原始/4K/1080p/720p/480p → -1/2160/1080/720/480)
        root.addView(rowLabel("预览分辨率"))
        root.addView(ctx.gyroSpinner(listOf("原始", "4K", "1080p", "720p", "480p"), 0) { idx ->
            val h = when (idx) { 1 -> 2160; 2 -> 1080; 3 -> 720; 4 -> 480; else -> -1 }
            onApply { GyroflowNative.nativeSetPreviewResolution(h) }
        })

        // 背景模式(纯色显示颜色框, 羽化留边显示 margin/feather, 对齐桌面)
        root.addView(rowLabel("背景模式"))
        root.addView(ctx.gyroSpinner(listOf("纯色", "边缘拉伸", "边缘镜像", "羽化留边"), 0) { idx ->
            bgMode = idx
            bgColorRow.visibility = if (idx == 0) View.VISIBLE else View.GONE
            marginSub.visibility = if (idx == 3) View.VISIBLE else View.GONE
            onApply { GyroflowNative.nativeSetBackgroundMode(idx) }
        })

        // 渲染背景(Hex 6 位, 仅纯色模式显示; 默认 #111111 对齐桌面)
        bgColorRow = labeled("渲染背景", ctx.gyroTextField("#111111") { text -> applyBgColor(text) })
        root.addView(bgColorRow)

        // 羽化留边参数(留边/羽化, %→占比, 仅羽化留边模式显示)
        marginSub = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL; visibility = View.GONE }
        marginSub.addView(ctx.gyroSlider("留边", "%", 0.0, 50.0, 20.0, 0) { v -> onApply { GyroflowNative.nativeSetBackgroundMargin(v / 100.0) } })
        marginSub.addView(ctx.gyroSlider("羽化", "%", 0.0, 50.0, 5.0, 0) { v -> onApply { GyroflowNative.nativeSetBackgroundMarginFeather(v / 100.0) } })
        root.addView(marginSub)

        // 安全区域指示
        root.addView(ctx.gyroCheckBox("安全区域指示", false) { on -> onApply { GyroflowNative.nativeSetShowSafeArea(on) } })
    }

    // 渲染背景 Hex(#RRGGBB / RRGGBB)→ RGBA(0–1), 解析失败则忽略。
    private fun applyBgColor(text: String) {
        val hex = text.trim().removePrefix("#")
        if (hex.length < 6) return
        val r = hex.substring(0, 2).toIntOrNull(16) ?: return
        val g = hex.substring(2, 4).toIntOrNull(16) ?: return
        val b = hex.substring(4, 6).toIntOrNull(16) ?: return
        onApply { GyroflowNative.nativeSetBackgroundColor(r / 255.0, g / 255.0, b / 255.0, 1.0) }
    }

    // ──────────────── 控件助手 ────────────────
    private fun title(t: String): TextView = TextView(ctx).apply {
        text = t; setTextColor(GyroflowTheme.TEXT); textSize = 16f
        setPadding(0, 0, 0, ctx.dp(8))
    }
    private fun rowLabel(t: String): TextView = TextView(ctx).apply {
        text = t; setTextColor(GyroflowTheme.TEXT); textSize = 13f
        setPadding(0, ctx.dp(6), 0, ctx.dp(2))
    }
    private fun labeled(label: String, control: View): View = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
        setPadding(0, ctx.dp(4), 0, ctx.dp(4))
        addView(TextView(ctx).apply { text = label; setTextColor(GyroflowTheme.TEXT); textSize = 13f },
            LinearLayout.LayoutParams(ctx.dp(96), LinearLayout.LayoutParams.WRAP_CONTENT))
        addView(control, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
    }
}
