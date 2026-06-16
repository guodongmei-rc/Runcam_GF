package com.runcam.runcam

import android.content.Context
import android.view.Gravity
import android.view.View
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

/**
 * 导出面板(对齐官方 Export)。与「输入」「参数」同级的 Tab 页内容。
 * 含: 编解码器 / 输出大小(宽 🔒 高 ⚙ 预设) / 比特率 / 导出音频 / 导出到相册(按钮 + 进度)。
 * 安卓硬件无 ProRes, 仅 H.264 / H.265(对齐 iOS 前两项)。
 */
class GyroflowExportPanel(
    private val ctx: Context,
    // 分组预设(对齐 iOS 比例组): 比例名(16:9…) → 该比例下的预设列表 (标签, 宽, 高)。
    private val sizePresets: () -> List<Pair<String, List<Triple<String, Int, Int>>>>,
    private val onSizeChanged: (Int, Int) -> Unit, // 输出尺寸变更 → 宿主同步预览尺寸框
    private val onPickExportDir: () -> Unit,       // 「…」选导出存储目录(对齐官方 OutputPathField)
    private val onFileNameEdited: () -> Unit,      // 文件名提交 → 宿主查重(同名自增 _X 回写)
    private val onExport: () -> Unit,
) {
    val root: LinearLayout

    private var codecIndex = 1          // 0=H.264/AVC 1=H.265/HEVC(默认, 对齐 iOS)
    private var exportAudio = true
    private var aspectLocked = true     // 锁定宽高比(对齐 iOS 默认锁定)
    private var aspect = 16.0 / 9.0     // 当前锁定的宽高比
    private var exporting = false
    private var resolutionOk = true     // 输出大小校验结果(对齐官方 canExport, Export.qml:117)
    private val nameField: EditText     // 输出路径: 输出文件名(可编辑, 用于相册条目名)
    private val dirLabel: TextView      // 输出路径: 同行显示当前导出目标目录
    private val wField: EditText
    private val hField: EditText
    private val lockButton: TextView
    private val resolutionWarning: TextView
    private val bitrateField: EditText
    private val exportButton: TextView
    private val progressBar: ProgressBar
    private val statusLabel: TextView

    // 各编码器最大分辨率(对齐官方 Export.qml:26-27 max_size): H.264→4096², H.265→8192²
    private val maxSizes = listOf(intArrayOf(4096, 4096), intArrayOf(8192, 8192))

    init {
        root = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(ctx.dp(16), ctx.dp(16), ctx.dp(16), ctx.dp(16))
        }
        root.addView(title("导出"))

        // 输出路径(对齐官方导出页顶部 OutputPathField): 文件名可编辑, 实际用于
        // 相册条目名; 默认值由宿主每次加载视频时设为「视频名_stabilized.mp4」
        // (对齐官方 VideoArea.qml:437-438)。
        // 「输出路径:」标签 + 同一行显示当前导出目标目录(尾部截断, 未授权→「未选择」)
        dirLabel = TextView(ctx).apply {
            text = "未选择"
            setTextColor(GyroflowTheme.TEXT); textSize = 13f
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
        }
        root.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(rowLabel("输出路径:"))
            addView(dirLabel, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { leftMargin = ctx.dp(6) })
        })
        nameField = ctx.gyroTextField("") { onFileNameEdited() }
        // 对齐官方 OutputPathField.qml:31: 实时剥掉路径前缀(只留最后一段文件名,
        // 禁止含路径分隔符); 改完刷新「导出」按钮可用态(长度>3)。
        nameField.addTextChangedListener(object : android.text.TextWatcher {
            private var editing = false
            override fun afterTextChanged(s: android.text.Editable?) {
                if (editing || s == null) return
                val t = s.toString()
                val idx = t.lastIndexOf('/')
                if (idx >= 0) {
                    editing = true
                    s.replace(0, s.length, t.substring(idx + 1))
                    editing = false
                }
                updateExportEnabled()
            }
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
        })
        root.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(nameField, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            // 「…」选导出存储目录(对齐官方): 选定后成品写入该目录, 未选默认存相册
            addView(squareButton("…") { onPickExportDir() })
        })

        // 导出按钮(位置对齐官方截图: 输出路径下方、编解码器上方)
        exportButton = TextView(ctx).apply {
            text = "导出"
            setTextColor(android.graphics.Color.WHITE)
            textSize = 15f
            gravity = Gravity.CENTER
            setPadding(0, ctx.dp(12), 0, ctx.dp(12))
            background = android.graphics.drawable.GradientDrawable().apply {
                setColor(GyroflowTheme.ACCENT); cornerRadius = ctx.dp(8).toFloat()
            }
            isClickable = true
            setOnClickListener { onExport() }
        }
        root.addView(exportButton, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = ctx.dp(10) })

        // 编解码器(对齐 iOS, 安卓去掉 ProRes)
        root.addView(rowLabel("编解码器"))
        root.addView(ctx.gyroSpinner(listOf("H.264/AVC", "H.265/HEVC"), codecIndex) { idx ->
            codecIndex = idx
            updateResolutionWarning()   // 编码器上限不同(4096²/8192²), 切换后重校验
        })

        // 输出大小: [输出大小] [宽] 🔒 [高] ⚙(预设菜单)。锁定时改宽自动按比例改高, 反之亦然。
        wField = ctx.gyroNumberField("", 0) { txt -> onWidthCommitted(txt) }
        hField = ctx.gyroNumberField("", 0) { txt -> onHeightCommitted(txt) }
        lockButton = squareButton(if (aspectLocked) "🔒" else "🔓") {
            aspectLocked = !aspectLocked
            lockButton.text = if (aspectLocked) "🔒" else "🔓"
            if (aspectLocked) recomputeAspect()
        }
        val gearButton = squareButton("⚙") { showSizeMenu(it) }
        root.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(0, ctx.dp(8), 0, ctx.dp(4))
            addView(TextView(ctx).apply { text = "输出大小"; setTextColor(GyroflowTheme.TEXT); textSize = 13f },
                LinearLayout.LayoutParams(ctx.dp(64), LinearLayout.LayoutParams.WRAP_CONTENT))
            addView(wField, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(lockButton)
            addView(hField, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { leftMargin = ctx.dp(4) })
            addView(gearButton)
        })

        // 输出大小校验红色提示框(对齐官方 Export.qml:453-466 Error InfoMessageSmall):
        // 红底白字、文字居中。
        resolutionWarning = TextView(ctx).apply {
            setTextColor(android.graphics.Color.WHITE)
            textSize = 12f
            gravity = Gravity.CENTER
            visibility = View.GONE
            setPadding(ctx.dp(10), ctx.dp(8), ctx.dp(10), ctx.dp(8))
            background = android.graphics.drawable.GradientDrawable().apply {
                setColor(0xFFE53935.toInt())
                cornerRadius = ctx.dp(6).toFloat()
            }
        }
        root.addView(resolutionWarning, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = ctx.dp(4) })

        // 比特率(title + 输入框 + 单位 同一行; 默认 63 Mbps 对齐 iOS)
        bitrateField = ctx.gyroNumberField("63", 0) {}
        root.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(0, ctx.dp(8), 0, ctx.dp(4))
            addView(TextView(ctx).apply { text = "比特率"; setTextColor(GyroflowTheme.TEXT); textSize = 13f },
                LinearLayout.LayoutParams(ctx.dp(64), LinearLayout.LayoutParams.WRAP_CONTENT))
            addView(bitrateField, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(TextView(ctx).apply { text = "Mbps"; setTextColor(GyroflowTheme.TEXT_SECONDARY); setPadding(ctx.dp(6), 0, 0, 0) })
        })

        // 导出音频(默认开)
        root.addView(ctx.gyroCheckBox("导出音频", exportAudio) { on -> exportAudio = on })

        // 进度条 + 状态
        progressBar = ProgressBar(ctx, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 1000; progress = 0; visibility = View.GONE
            progressTintList = android.content.res.ColorStateList.valueOf(GyroflowTheme.ACCENT)
        }
        root.addView(progressBar, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, ctx.dp(6)).apply { topMargin = ctx.dp(10) })
        statusLabel = TextView(ctx).apply {
            setTextColor(GyroflowTheme.TEXT_SECONDARY); textSize = 12f
            setPadding(0, ctx.dp(6), 0, 0)
        }
        root.addView(statusLabel)
    }

    // ── 输出大小: 锁定比例联动 ──
    // 联动算出的另一边取整到偶数(就近): 避免联动自己引入「必须可被 2 整除」报错;
    // 用户手输的那一边保留原值, 由校验红框提示。
    private fun roundToEven(v: Double): Int = (Math.round(v / 2.0) * 2).toInt()

    private fun onWidthCommitted(txt: String) {
        val w = txt.trim().toIntOrNull() ?: return
        if (aspectLocked && aspect > 0) {
            hField.setText(roundToEven(w / aspect).toString())
        } else {
            val h = hField.text.toString().trim().toIntOrNull()
            if (h != null && h > 0) aspect = w.toDouble() / h
        }
        notifySize()
    }

    private fun onHeightCommitted(txt: String) {
        val h = txt.trim().toIntOrNull() ?: return
        if (aspectLocked && aspect > 0) {
            wField.setText(roundToEven(h * aspect).toString())
        } else {
            val w = wField.text.toString().trim().toIntOrNull()
            if (w != null && w > 0) aspect = w.toDouble() / h
        }
        notifySize()
    }

    /** 两个尺寸框都有有效值时, 通知宿主同步预览尺寸框。 */
    private fun notifySize() {
        updateResolutionWarning()
        val w = wField.text.toString().trim().toIntOrNull() ?: return
        val h = hField.text.toString().trim().toIntOrNull() ?: return
        if (w > 0 && h > 0) onSizeChanged(w, h)
    }

    /**
     * 输出大小范围校验(对齐官方 Export.qml:117/453-466): ①超所选编码器最大分辨率;
     * ②分辨率必须可被 2 整除。违规 → 红色提示框(文案对齐官方 zh_CN 翻译, 两条可同时
     * 显示) + 禁用导出按钮(canExport)。
     */
    private fun updateResolutionWarning() {
        val w = wField.text.toString().trim().toIntOrNull() ?: 0
        val h = hField.text.toString().trim().toIntOrNull() ?: 0
        val max = maxSizes[codecIndex]
        val messages = ArrayList<String>()
        if (w > 0 && h > 0) {   // 空/未填 = 原始尺寸, 不校验
            if (w > max[0] || h > max[1]) {
                messages.add("选择的编码解码器不支持此分辨率。\n支持的最大分辨率是 ${max[0]}x${max[1]}。")
            }
            if (w % 2 != 0 || h % 2 != 0) {
                messages.add("分辨率必须可以被 2 整除。")
            }
        }
        resolutionWarning.text = messages.joinToString("\n")
        resolutionWarning.visibility = if (messages.isNotEmpty()) View.VISIBLE else View.GONE
        resolutionOk = messages.isEmpty()
        updateExportEnabled()
    }

    private fun updateExportEnabled() {
        // 对齐官方 canExport: 输出大小合法 + 未在导出中 + 文件名长度 > 3(App.qml:253)
        val nameOk = nameField.text.toString().trim().length > 3
        val enabled = resolutionOk && !exporting && nameOk
        exportButton.isClickable = enabled
        exportButton.alpha = if (enabled) 1f else 0.5f
    }

    private fun recomputeAspect() {
        val w = wField.text.toString().trim().toIntOrNull()
        val h = hField.text.toString().trim().toIntOrNull()
        if (w != null && h != null && h > 0) aspect = w.toDouble() / h
    }

    // ⚙ 预设弹窗(对齐官方 UI): 顶部横排比例 Tab(选中高亮) + 下方预设竖列表。字号 32px。
    private fun showSizeMenu(anchor: View) {
        val groups = sizePresets()
        if (groups.isEmpty()) { setStatus("请先选择视频"); return }
        val font = 32f // px

        val content = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(ctx.dp(8), ctx.dp(8), ctx.dp(8), ctx.dp(8))
            background = android.graphics.drawable.GradientDrawable().apply {
                setColor(GyroflowTheme.BG_PANEL); cornerRadius = ctx.dp(10).toFloat()
                setStroke(ctx.dp(1), GyroflowTheme.BORDER)
            }
        }
        val popup = android.widget.PopupWindow(content, ctx.dp(320), LinearLayout.LayoutParams.WRAP_CONTENT, true)
        popup.elevation = ctx.dp(8).toFloat()

        val tabRow = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL }
        val list = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }

        fun showGroup(gi: Int) {
            for (i in 0 until tabRow.childCount) {
                (tabRow.getChildAt(i) as TextView).setTextColor(if (i == gi) GyroflowTheme.ACCENT else GyroflowTheme.TEXT_SECONDARY)
            }
            list.removeAllViews()
            groups[gi].second.forEach { p ->
                list.addView(TextView(ctx).apply {
                    text = p.first
                    setTextColor(GyroflowTheme.TEXT)
                    setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, font)
                    setPadding(ctx.dp(8), ctx.dp(10), ctx.dp(8), ctx.dp(10))
                    isClickable = true
                    setOnClickListener {
                        wField.setText(p.second.toString())
                        hField.setText(p.third.toString())
                        if (p.third > 0) aspect = p.second.toDouble() / p.third
                        notifySize()
                        popup.dismiss()
                    }
                })
            }
        }

        groups.forEachIndexed { gi, g ->
            tabRow.addView(TextView(ctx).apply {
                text = g.first
                setTextColor(GyroflowTheme.TEXT_SECONDARY)
                setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, font)
                setPadding(ctx.dp(8), ctx.dp(4), ctx.dp(8), ctx.dp(6))
                isClickable = true
                setOnClickListener { showGroup(gi) }
            })
        }
        // 比例 Tab 横向可滚动(字号大时一行放不下)
        content.addView(android.widget.HorizontalScrollView(ctx).apply {
            isHorizontalScrollBarEnabled = false
            addView(tabRow)
        })
        content.addView(View(ctx).apply {
            setBackgroundColor(GyroflowTheme.BORDER)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, ctx.dp(1)).apply { topMargin = ctx.dp(6); bottomMargin = ctx.dp(4) }
        })
        // 预设列表竖向可滚动(避免超出屏幕)
        content.addView(android.widget.ScrollView(ctx).apply {
            isVerticalScrollBarEnabled = false
            addView(list)
        }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

        showGroup(0)
        // 弹到设置按钮上方: 测内容高度, 用负偏移上移(并封顶, 过高则内部滚动)
        content.measure(
            View.MeasureSpec.makeMeasureSpec(ctx.dp(320), View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
        )
        val popupH = minOf(content.measuredHeight, ctx.dp(360))
        popup.height = popupH
        popup.showAsDropDown(anchor, 0, -(anchor.height + popupH))
    }

    /** 重置输出文件名(导入新视频时调用, 对齐官方 VideoArea.qml:437-438 每次加载重置)。 */
    fun setDefaultFileName(name: String) {
        nameField.setText(name)
    }

    /** 默认填输出文件名(仅当输入框为空, 不覆盖用户已填; 同视频重载场景用)。 */
    fun setDefaultFileNameIfEmpty(name: String) {
        if (nameField.text.isNullOrBlank()) {
            setDefaultFileName(name)
        }
    }

    /** 重置输出尺寸为给定值(导入新视频时调用, 对齐官方每次加载按视频信息重置)。 */
    fun setDefaultSize(w: Int, h: Int) {
        if (w <= 0 || h <= 0) return
        wField.setText(w.toString())
        hField.setText(h.toString())
        aspect = w.toDouble() / h
        notifySize()
    }

    /** 默认填输出尺寸(仅当输入框为空, 不覆盖用户已填; 同视频重载场景用)。 */
    fun setDefaultSizeIfEmpty(w: Int, h: Int) {
        if (wField.text.isNullOrBlank() && hField.text.isNullOrBlank()) {
            setDefaultSize(w, h)
        }
    }

    /** 读当前设置; outW/outH=0 表示原始(由宿主按源尺寸算)。 */
    fun currentSettings(): GyroflowExporter.Settings = GyroflowExporter.Settings(
        codecIndex = codecIndex,
        outW = wField.text.toString().trim().toIntOrNull() ?: 0,
        outH = hField.text.toString().trim().toIntOrNull() ?: 0,
        bitrateMbps = bitrateField.text.toString().trim().toIntOrNull() ?: 63,
        exportAudio = exportAudio,
        fileName = nameField.text.toString().trim(),
    )

    fun setExporting(on: Boolean) {
        exporting = on
        updateExportEnabled()
        progressBar.visibility = if (on) View.VISIBLE else View.GONE
        if (on) progressBar.progress = 0
    }

    fun setProgress(p: Float) { progressBar.progress = (p.coerceIn(0f, 1f) * 1000).toInt() }
    fun setStatus(s: String) { statusLabel.text = s }

    /** 「输出路径:」同行显示当前导出目标目录。
     *  null=未授权→「未选择」; 空串=已授权但选的是存储根目录→「根目录」; 否则显示路径。 */
    fun setExportDir(path: String?) {
        dirLabel.text = when {
            path == null -> "未选择"
            path.isBlank() -> "根目录"
            else -> path
        }
    }

    // ── 控件助手 ──
    private fun title(t: String): TextView = TextView(ctx).apply {
        text = t; setTextColor(GyroflowTheme.TEXT); textSize = 16f
        setPadding(0, 0, 0, ctx.dp(8))
    }
    private fun rowLabel(t: String): TextView = TextView(ctx).apply {
        text = t; setTextColor(GyroflowTheme.TEXT); textSize = 13f
        setPadding(0, ctx.dp(8), 0, ctx.dp(2))
    }
    private fun squareButton(label: String, onClick: (View) -> Unit): TextView = TextView(ctx).apply {
        text = label; textSize = 16f; gravity = Gravity.CENTER
        setTextColor(GyroflowTheme.TEXT)
        setPadding(ctx.dp(8), ctx.dp(6), ctx.dp(8), ctx.dp(6))
        isClickable = true
        setOnClickListener { onClick(this) }
    }
}
