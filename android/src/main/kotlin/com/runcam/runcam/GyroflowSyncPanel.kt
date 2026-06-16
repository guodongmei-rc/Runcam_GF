package com.runcam.runcam

import android.content.Context
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.Spinner
import android.widget.TextView

/**
 * 同步面板(参数 Tab 第一节, 对齐官方 Synchronization.qml)。独立模块, 仅 UI + 收集参数。
 *
 * 自动同步的实际运行(解码喂帧 + 应用 offset)由宿主用 [GyroflowAutosync] 驱动:
 * 用户点「自动同步」→ [onAutosyncToggle](true) 启动 / 运行中点 → (false) 取消;
 * 宿主回调 [setRunning]/[setProgress]/[setResult] 回写状态。
 *
 * 说明: 安卓已链接 OpenCV(.so 含 OpenCV 4.11)。光流方式默认 OpenCV DIS(稠密光流) ——
 * 偏移方式 rs-sync 吃光流对应点, 稀疏 AKAZE 易退化(rs_sync bast_param None), 故默认用 DIS。
 */
class GyroflowSyncPanel(
    private val ctx: Context,
    private val onAutosyncToggle: (start: Boolean) -> Unit,
) {
    val root: LinearLayout = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }

    private val autosyncButton: TextView
    private val progressLabel: TextView
    private var running = false

    private val initialOffsetField: EditText      // 秒
    private val searchSizeField: EditText          // 秒
    private val maxPointsField: EditText           // 整数
    private val everyNthField: EditText            // 整数
    private val timePerSyncField: EditText         // 秒
    private val calcFirstToggle: GyroToggle        // 先粗后细(随偏移方式显隐、随尺寸>10s 自动勾, 对齐官方)
    private val lpfField: EditText                  // 同步低通滤波器 Hz
    private val resolutionSpinner: Spinner
    private val ofMethodSpinner: Spinner
    private val poseMethodSpinner: Spinner
    private val offsetMethodSpinner: Spinner

    private var negInvOn = false       // 双向搜索(initial_offset_inv)
    private var calcFirstOn = false    // 先粗后细(calc_initial_fast)
    private var autoPointsOn = false   // 自动挑同步点(auto_sync_points)
    private var lpfOn = false          // 同步低通滤波器开关
    private var showFeaturesOn = true  // 显示检测到的特征点(对齐官方默认 true)
    private var showOfOn = true        // 显示光流(对齐官方默认 true)

    private val advancedBody: LinearLayout
    private val advancedHeader: TextView
    private var advancedExpanded = false

    // 处理分辨率索引 → 目标高度(0=完整)
    private val resHeights = intArrayOf(0, 2160, 1080, 720, 480)

    // 「使用已同步运动数据」提示(对齐官方 Synchronization.qml usesQuats InfoMessage):
    // 精确时间戳 / 直接用四元数的视频, 提示无需额外同步, 强行同步可能更糟。
    private val quatsWarning: TextView = TextView(ctx).apply {
        text = "此文件使用已同步的运动数据，无需额外同步点，强行同步可能会使输出结果变得更糟。"
        setTextColor(android.graphics.Color.BLACK)
        textSize = 12f
        gravity = Gravity.CENTER   // 文字居中
        setPadding(ctx.dp(10), ctx.dp(8), ctx.dp(10), ctx.dp(8))
        background = GradientDrawable().apply {
            setColor(android.graphics.Color.parseColor("#F2C200"))
            cornerRadius = ctx.dp(6).toFloat()
        }
        visibility = View.GONE
    }

    init {
        root.addView(sectionTitle("同步"))
        root.addView(quatsWarning, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = ctx.dp(6) })

        // 自动同步按钮(对齐官方: 深灰圆角 pill + 主题色 spinner 图标 + 白字)
        autosyncButton = TextView(ctx).apply {
            text = "自动同步"
            setTextColor(GyroflowTheme.TEXT)
            textSize = 14f
            gravity = Gravity.CENTER
            setPadding(ctx.dp(16), ctx.dp(10), ctx.dp(18), ctx.dp(10))
            compoundDrawablePadding = ctx.dp(6)
            background = GradientDrawable().apply {
                setColor(GyroflowTheme.BOX_BG)
                cornerRadius = ctx.dp(20).toFloat()
            }
            val icon = ctx.getDrawable(R.drawable.ic_gf_spinner)?.mutate()?.apply {
                setTint(GyroflowTheme.TEXT) // 图标与文字同色(白)
                setBounds(0, 0, ctx.dp(16), ctx.dp(16))
            }
            setCompoundDrawablesRelative(icon, null, null, null)
            setOnClickListener { toggleAutosync() }
        }
        progressLabel = TextView(ctx).apply {
            setTextColor(GyroflowTheme.ACCENT)
            textSize = 11f
            text = ""
            gravity = Gravity.CENTER
        }
        // 自动同步按钮 + 自动选点复选框(无文字, 仅方框), 整体居中
        val syncBtnRow = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, ctx.dp(6), 0, ctx.dp(2))
            addView(autosyncButton)
            addView(ctx.gyroCheckBox("", false) { on -> autoPointsOn = on }.apply {
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { marginStart = ctx.dp(10) }
            })
        }
        root.addView(syncBtnRow, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        root.addView(progressLabel, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = ctx.dp(4) })

        // 陀螺大致偏移 + 双向搜索(默认对齐官方 Synchronization.qml)
        initialOffsetField = ctx.gyroNumberField("0.0", 1) {}
        root.addView(fieldRowWithCheck("陀螺大致偏移", initialOffsetField, "秒", false) { on -> negInvOn = on })
        // 同步搜索尺寸 + 先粗后细(官方默认 5.0s; 复选框随偏移方式显隐、随尺寸>10s 自动勾, 见下方 offsetMethodSpinner)
        calcFirstToggle = GyroToggle(ctx, "", false) { on -> calcFirstOn = on }
        searchSizeField = ctx.gyroNumberField("5.0", 1) { onSearchSizeChanged() }
        root.addView(fieldRowWithToggle("同步搜索尺寸", searchSizeField, "秒", calcFirstToggle.view))
        // 最大同步点数(官方默认 3)
        maxPointsField = ctx.gyroNumberField("3", 0) {}
        root.addView(labeledRow("最大同步点数", maxPointsField))

        // 高级选项(可展开)
        advancedHeader = TextView(ctx).apply {
            text = "高级选项 ▾"
            setTextColor(GyroflowTheme.ACCENT)
            textSize = 13f
            gravity = Gravity.CENTER
            setPadding(0, ctx.dp(10), 0, ctx.dp(6))
            setOnClickListener { toggleAdvanced() }
        }
        root.addView(advancedHeader, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

        advancedBody = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
        }
        everyNthField = ctx.gyroNumberField("1", 0) {}
        advancedBody.addView(labeledRow("每 N 帧执行分析", everyNthField))
        timePerSyncField = ctx.gyroNumberField("1.5", 2) {} // 官方默认 1.5s
        advancedBody.addView(fieldRowWithUnit("每个同步点分析时长", timePerSyncField, "秒"))

        resolutionSpinner = ctx.gyroSpinner(listOf("完整", "4k", "1080p", "720p", "480p"), 3) {}
        advancedBody.addView(labeledRow("处理分辨率", resolutionSpinner))
        // 光流方式(安卓默认 AKAZE)
        ofMethodSpinner = ctx.gyroSpinner(listOf("AKAZE", "OpenCV (PyrLK)", "OpenCV (DIS)"), 2) {}
        advancedBody.addView(labeledRow("光流方式", ofMethodSpinner))
        // 姿态方式: 已链 OpenCV, 默认 findEssentialMat(0) —— 对齐官方/iOS
        poseMethodSpinner = ctx.gyroSpinner(listOf("findEssentialMat", "Almeida", "EightPoint", "findHomography"), 0) {}
        advancedBody.addView(labeledRow("姿态方式", poseMethodSpinner))
        // 偏移方式(默认 rs-sync 卷帘快门同步)。官方: 「先粗后细」仅在偏移方式 != 本质矩阵(index>0)时显示。
        offsetMethodSpinner = ctx.gyroSpinner(listOf("本质矩阵", "视觉特征", "卷帘快门同步"), 2) { idx ->
            calcFirstToggle.view.visibility = if (idx > 0) View.VISIBLE else View.GONE
        }
        advancedBody.addView(labeledRow("偏移方式", offsetMethodSpinner))
        // 初始可见性(gyroSpinner 跳过初始化回调, 故按默认选项显式设一次)
        calcFirstToggle.view.visibility = if (offsetMethodSpinner.selectedItemPosition > 0) View.VISIBLE else View.GONE

        // 低通滤波器(对齐官方 Synchronization.qml CheckBoxWithContent): 复选框+文字在上,
        // 勾选才在其下方显示 Hz 框(框行左边比复选框左多 6px), 默认 50。
        lpfField = ctx.gyroNumberField("50", 2) {}
        val lpfFieldRow = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            visibility = android.view.View.GONE
            addView(lpfField, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(unitLabel("Hz"))
        }
        val lpfCheck = ctx.gyroCheckBox("低通滤波器", false) { on ->
            lpfOn = on
            lpfFieldRow.visibility = if (on) android.view.View.VISIBLE else android.view.View.GONE
        }
        advancedBody.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            addView(lpfCheck)
            addView(
                lpfFieldRow,
                LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                    .apply { leftMargin = ctx.dp(28) },  // 与「低通滤波器」文字左对齐(复选框框 dp(20) + 文字左内边距 dp(8))
            )
        })
        advancedBody.addView(ctx.gyroCheckBox("显示检测到的特性", true) { on ->
            showFeaturesOn = on
            GyroflowNative.nativeSetShowDetectedFeatures(on)
        })
        advancedBody.addView(ctx.gyroCheckBox("显示光学流量", true) { on ->
            showOfOn = on
            GyroflowNative.nativeSetShowOpticalFlow(on)
        })
        root.addView(advancedBody)
    }

    /**
     * 用镜头档案的 sync_settings 覆盖默认值(对齐官方 LensProfile→Synchronization.loadGyroflow)。
     * 单位与官方一致(秒)。光流/姿态不从档案覆盖, 保持下拉默认(光流=OpenCV DIS)。
     */
    fun applySyncSettings(json: String?) {
        val o = try {
            org.json.JSONObject(json ?: "{}")
        } catch (_: Throwable) {
            return
        }
        if (o.has("search_size")) searchSizeField.setText(fmtNum(o.optDouble("search_size")))
        if (o.has("time_per_syncpoint")) timePerSyncField.setText(fmtNum(o.optDouble("time_per_syncpoint")))
        if (o.has("max_sync_points")) maxPointsField.setText(o.optInt("max_sync_points").toString())
        if (o.has("initial_offset")) initialOffsetField.setText(fmtNum(o.optDouble("initial_offset")))
        if (o.has("every_nth_frame")) everyNthField.setText(o.optInt("every_nth_frame").toString())
        negInvOn = o.optBoolean("initial_offset_inv", negInvOn)
        calcFirstOn = o.optBoolean("calc_initial_fast", calcFirstOn)
    }

    private fun fmtNum(d: Double): String =
        if (d == Math.floor(d) && !d.isInfinite()) d.toLong().toString() else d.toString()

    // ── 对外: 参数 / 状态 ──
    fun currentParams(): GyroflowAutosync.SyncParams = GyroflowAutosync.SyncParams(
        initialOffsetMs = num(initialOffsetField) * 1000.0,  // 秒 → 毫秒
        searchSizeSec = num(searchSizeField),
        maxSyncPoints = num(maxPointsField).toInt().coerceIn(1, 500),
        everyNthFrame = num(everyNthField).toInt().coerceAtLeast(1),
        timePerSyncpointSec = num(timePerSyncField),
        ofMethod = ofMethodSpinner.selectedItemPosition,
        poseMethod = poseMethodSpinner.selectedItemPosition,
        offsetMethod = offsetMethodSpinner.selectedItemPosition,
        calcInitialFast = calcFirstOn,
        initialOffsetInv = negInvOn,
        autoSyncPoints = autoPointsOn,
        syncLpfHz = if (lpfOn) num(lpfField) else 0.0,   // 关时传 0(对齐官方 set_sync_lpf(checked? v : 0))
    )

    fun currentProcHeight(): Int = resHeights.getOrElse(resolutionSpinner.selectedItemPosition) { 720 }

    // 对齐官方 Synchronization.qml:212 —— show: usesQuats && offsets_model.rowCount() > 0
    private var usesQuatsState = false
    private var hasSyncPointsState = false

    /** 视频使用已同步运动数据(精确时间戳/直接用四元数, 对齐官方 usesQuats)。 */
    fun setUsesQuats(usesQuats: Boolean) {
        usesQuatsState = usesQuats
        refreshQuatsWarning()
    }

    /** 当前是否已有同步点(对齐官方 offsets_model.rowCount() > 0)。 */
    fun setHasSyncPoints(has: Boolean) {
        hasSyncPointsState = has
        refreshQuatsWarning()
    }

    // 官方: 仅当「用已同步数据」且「已有同步点」才弹(同步后才提示, 而非一加载就弹)。
    private fun refreshQuatsWarning() {
        quatsWarning.visibility = if (usesQuatsState && hasSyncPointsState) View.VISIBLE else View.GONE
    }

    fun setRunning(isRunning: Boolean) {
        running = isRunning
        autosyncButton.text = if (isRunning) "取消同步" else "自动同步"
        if (!isRunning) {
            progressLabel.text = ""
        }
    }

    fun setProgress(p: Double) {
        progressLabel.text = "${(p * 100).toInt()}%"
    }

    fun setResult(medianMs: Double?, points: List<Pair<Double, Double>>) {
        // 不再显示「✓ 偏移 X ms」黄色结果字
        progressLabel.text = ""
    }

    /** 把「显示特征/光流」当前勾选状态应用到原生(autosync 完成后调, 让默认 true 生效)。 */
    fun applyShowFlags() {
        GyroflowNative.nativeSetShowDetectedFeatures(showFeaturesOn)
        GyroflowNative.nativeSetShowOpticalFlow(showOfOn)
    }

    private fun toggleAutosync() {
        onAutosyncToggle(!running)
    }

    private fun toggleAdvanced() {
        advancedExpanded = !advancedExpanded
        advancedBody.visibility = if (advancedExpanded) View.VISIBLE else View.GONE
        advancedHeader.text = if (advancedExpanded) "高级选项 ▴" else "高级选项 ▾"
    }

    // ── 小组件 ──
    private fun num(f: EditText): Double = f.text.toString().trim().toDoubleOrNull() ?: 0.0

    private fun sectionTitle(t: String): TextView = TextView(ctx).apply {
        text = t
        setTextColor(GyroflowTheme.TEXT)
        textSize = 15f
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        setPadding(0, ctx.dp(14), 0, ctx.dp(8))
    }

    private fun rowLabel(text: String): TextView = TextView(ctx).apply {
        this.text = text
        setTextColor(GyroflowTheme.TEXT_SECONDARY)
        textSize = 13f
        layoutParams = LinearLayout.LayoutParams(ctx.dp(120), LinearLayout.LayoutParams.WRAP_CONTENT)
    }

    // 标签 + 控件(控件占满剩余)
    private fun labeledRow(label: String, control: View): View = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(0, ctx.dp(4), 0, ctx.dp(4))
        addView(rowLabel(label))
        addView(control, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
    }

    // 标签 + 字段 + 单位
    private fun fieldRowWithUnit(label: String, field: EditText, unit: String): View = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(0, ctx.dp(4), 0, ctx.dp(4))
        addView(rowLabel(label))
        addView(field, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        addView(unitLabel(unit))
    }

    // 官方: 搜索尺寸 onValueChanged → 若「先粗后细」可见, 自动设为 (尺寸 > 10)。
    private fun onSearchSizeChanged() {
        if (calcFirstToggle.view.visibility == View.VISIBLE) {
            calcFirstToggle.setChecked(num(searchSizeField) > 10.0)
        }
    }

    // 标签 + 字段 + 单位 + 右侧已建好的可控复选框(先粗后细)
    private fun fieldRowWithToggle(label: String, field: EditText, unit: String, checkView: View): View =
        LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, ctx.dp(4), 0, ctx.dp(4))
            addView(rowLabel(label))
            addView(field, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(unitLabel(unit))
            addView(checkView.apply {
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { marginStart = ctx.dp(8) }
            })
        }

    // 标签 + 字段 + 单位 + 右侧复选框(双向搜索 / 先粗后细)
    private fun fieldRowWithCheck(label: String, field: EditText, unit: String, checked: Boolean, onToggle: (Boolean) -> Unit): View =
        LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, ctx.dp(4), 0, ctx.dp(4))
            addView(rowLabel(label))
            addView(field, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(unitLabel(unit))
            addView(ctx.gyroCheckBox("", checked) { on -> onToggle(on) }.apply {
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { marginStart = ctx.dp(8) }
            })
        }

    private fun unitLabel(unit: String): TextView = TextView(ctx).apply {
        text = unit
        setTextColor(GyroflowTheme.TEXT_SECONDARY)
        textSize = 12f
        setPadding(ctx.dp(6), 0, ctx.dp(2), 0)
    }
}
