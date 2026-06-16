package com.runcam.runcam

import android.content.Context
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.Spinner
import android.widget.TextView

/**
 * 运动数据面板(对齐 iOS MotionData.qml)。独立模块, 仅 UI + 调 [GyroflowNative]。
 *
 * 功能对齐官方:
 *   - 检测格式信息
 *   - 低通滤波(Hz) / 中值滤波(采样)
 *   - IMU 旋转(Pitch/Roll/Yaw) / 陀螺零偏(X/Y/Z)
 *   - IMU 朝向(XYZ 轴向映射)
 *   - 积分方法(None/Complementary/VQF/Simple/Simple+accel/Mahony/Madgwick)
 *
 * 文件选择交给宿主([onOpenFile]); 载入完成后宿主调 [refresh] 从 native 回填状态。
 */
class GyroflowMotionPanel(
    private val ctx: Context,
    private val onOpenFile: () -> Unit,
    private val onIntegrationChanged: () -> Unit = {}, // 积分方法变化 → 宿主重算 usesQuats(对齐官方)
    private val onReloadExternalFile: (Boolean) -> Unit = {}, // 「加载全部元数据」切换 → 宿主重载当前外挂文件(对齐官方 MotionData.qml:215-222)
    private val onAuthorizeDir: () -> Unit = {} // 「授权视频所在目录」→ 宿主弹 SAF 目录选择器(对齐官方 MotionData.qml:163-177)
) {
    /** 整个「运动数据」区(标题 + 控件), 由宿主加入输入页。 */
    val root: LinearLayout = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }

    private val statusLabel: TextView
    private val authorizeDirHint: TextView         // 「授权视频所在目录」提示(无运动数据且 content:// 时显示)
    private val body: LinearLayout                 // 动态控件容器, refresh() 时重建
    private val ui = Handler(Looper.getMainLooper())

    // 各滤波/旋转的启用状态(对齐 iOS CheckBoxWithContent: 关时传 0)
    private var lpfOn = false
    private var mfOn = false
    private var rotOn = false
    private var biasOn = false
    private var hasQuaternions = false

    // 外挂运动数据文件专属状态(对齐官方 MotionData.qml:213/227: 两控件仅外挂文件场景显示)
    private var externalGyroLoaded = false
    private var allMetadataOn = false
    private var frameOffsetOn = false
    private var frameOffsetValue = 0
    private var frameOffsetField: EditText? = null

    // 方向指示器
    private var orientationOn = false
    private var orientationView: OrientationIndicatorView? = null
    private var lastTsUs = 0L

    // 文件名(检测/手动加载的运动数据文件)
    private var fileName = "---"
    private var fileNameValue: TextView? = null

    private lateinit var lpfField: EditText
    private lateinit var mfField: EditText
    private lateinit var pField: EditText
    private lateinit var rField: EditText
    private lateinit var yField: EditText
    private lateinit var bxField: EditText
    private lateinit var byField: EditText
    private lateinit var bzField: EditText

    private val openFileButton: TextView

    init {
        root.addView(sectionTitle("运动数据"))
        // 未载入视频前禁用(对齐官方 MotionData.qml:36 无视频拒绝加载运动数据)
        openFileButton = ctx.gyroPrimaryButton("打开文件") { onOpenFile() }.apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                .apply { topMargin = ctx.dp(6) }
            isEnabled = false
            alpha = 0.4f
        }
        root.addView(openFileButton)
        statusLabel = TextView(ctx).apply {
            text = "未加载运动数据"
            setTextColor(GyroflowTheme.TEXT_SECONDARY)
            textSize = 13f
            setPadding(0, ctx.dp(6), 0, 0)
        }
        root.addView(statusLabel)
        // 「授权视频所在目录」提示 —— content:// 单文件视频无法列父目录, 授权后
        // 同名 sidecar(gcsv/bbl/bfl/csv)自动检测才能生效(对齐官方 MotionData.qml:163-177)
        authorizeDirHint = TextView(ctx).apply {
            text = "未检测到运动数据?点此授权视频所在目录, 自动查找同名陀螺文件"
            setTextColor(GyroflowTheme.ACCENT)
            textSize = 12f
            setPadding(0, ctx.dp(6), 0, 0)
            visibility = View.GONE
            setOnClickListener { onAuthorizeDir() }
        }
        root.addView(authorizeDirHint)
        body = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
        root.addView(body)
        // 默认(未选视频)也展示整套控件布局(对齐官方/iOS), 加载后只填值。
        populate(org.json.JSONObject())
    }

    /** 文件名(由宿主在加载视频/运动数据文件时传入)。 */
    fun setFileName(name: String) {
        fileName = name.ifBlank { "---" }
        fileNameValue?.text = fileName
    }

    /** 「打开文件」启用开关: 视频载入完成后宿主传 true; 选择新视频期间禁用(对齐官方: 无视频拒绝加载)。 */
    fun setOpenFileEnabled(enabled: Boolean) {
        openFileButton.isEnabled = enabled
        openFileButton.alpha = if (enabled) 1f else 0.4f
    }

    /** 「授权视频所在目录」提示显隐: 视频载入完成、无运动数据且视频来源为 content:// 时显示。 */
    fun setAuthorizeDirVisible(visible: Boolean) {
        authorizeDirHint.visibility = if (visible) View.VISIBLE else View.GONE
    }

    /** 「加载全部元数据」当前勾选值(宿主调 nativeLoadGyro 时传入, 对齐官方 root.allMetadata)。 */
    fun loadAllMetadataChecked(): Boolean = allMetadataOn

    /** 外挂运动数据加载成功后由宿主置 true; 选择新视频时置 false 并复位两控件状态。 */
    fun setExternalGyroLoaded(loaded: Boolean) {
        externalGyroLoaded = loaded
        if (!loaded) {
            allMetadataOn = false
            frameOffsetOn = false
            frameOffsetValue = 0
        }
    }

    /** 未匹配/未加载时: 控件保持默认布局可见, 仅更新状态提示。 */
    fun showEmpty(text: String) {
        populate(org.json.JSONObject())
        statusLabel.text = text
    }

    /** 从 native 读取运动数据信息并回填控件(后台线程读, 主线程建 UI)。 */
    fun refresh() {
        Thread {
            val json = GyroflowNative.nativeGetGyroInfo() ?: "{}"
            val o = try {
                org.json.JSONObject(json)
            } catch (_: Throwable) {
                org.json.JSONObject()
            }
            ui.post { populate(o) }
        }.start()
    }

    // 始终构建整套控件(无数据时用默认值, 对齐官方默认布局)。
    private fun populate(o: org.json.JSONObject) {
        body.removeAllViews()
        val hasMotion = o.optBoolean("has_motion", false)
        val format = o.optString("format").trim()
        statusLabel.text = when {
            !hasMotion -> "未加载, 可手动打开运动数据文件"
            format.isNotEmpty() -> "已载入: $format"
            else -> "已载入运动数据"
        }
        hasQuaternions = o.optBoolean("has_quaternions", false)

        // 检测格式 + 文件名(对齐 iOS 检测到的格式 / 文件名称)
        body.addView(infoRow("检测格式", if (format.isNotEmpty()) format else "---"))
        fileNameValue = infoRowValue("文件名称", fileName).also { body.addView(it.first) }.second

        // —— 外挂文件专属控件(对齐官方: 仅运动数据来自外挂文件时显示) ——
        if (externalGyroLoaded) {
            body.addView(ctx.gyroCheckBox("加载全部元数据", allMetadataOn) { on ->
                allMetadataOn = on
                onReloadExternalFile(on) // 对齐官方: 切换后重新加载该文件
            })
            // —— 帧偏移(帧, 整数可负; 渲染前把视频时间戳整帧平移后再查陀螺) ——
            val fo = ctx.gyroNumberField(frameOffsetValue.toString(), 0) { applyFrameOffset() }
            frameOffsetField = fo
            checkboxBlock("帧偏移", frameOffsetOn, unitRow(fo, "帧")) { on -> frameOffsetOn = on; applyFrameOffset() }
        }

        // —— 低通滤波(Hz, precision 2, 默认 50) ——
        val lpf = o.optDouble("lpf", 0.0)
        lpfOn = lpf > 0
        lpfField = ctx.gyroNumberField(fmt(if (lpf > 0) lpf else 50.0), 2) { applyLpf() }
        checkboxBlock("低通滤波", lpfOn, unitRow(lpfField, "Hz")) { on -> lpfOn = on; applyLpf() }

        // —— 中值滤波(采样数, precision 0, 默认 5) ——
        val mf = o.optInt("median", 0)
        mfOn = mf > 0
        mfField = ctx.gyroNumberField((if (mf > 0) mf else 5).toString(), 0) { applyMedian() }
        checkboxBlock("中值滤波", mfOn, unitRow(mfField, "采样")) { on -> mfOn = on; applyMedian() }

        // —— IMU 旋转(Pitch/Roll/Yaw, °, precision 1) ——
        val rot = o.optJSONArray("rotation")
        val rp = rot?.optDouble(0, 0.0) ?: 0.0
        val rr = rot?.optDouble(1, 0.0) ?: 0.0
        val ry = rot?.optDouble(2, 0.0) ?: 0.0
        rotOn = rp != 0.0 || rr != 0.0 || ry != 0.0
        pField = ctx.gyroNumberField(fmt(rp), 1) { applyRotation() }
        rField = ctx.gyroNumberField(fmt(rr), 1) { applyRotation() }
        yField = ctx.gyroNumberField(fmt(ry), 1) { applyRotation() }
        checkboxBlock("旋转", rotOn, tripleRow("Pitch", pField, "Roll", rField, "Yaw", yField)) { on -> rotOn = on; applyRotation() }

        // —— 陀螺零偏(X/Y/Z, °/s, precision 2) ——
        val bias = o.optJSONArray("bias")
        val bx = bias?.optDouble(0, 0.0) ?: 0.0
        val by = bias?.optDouble(1, 0.0) ?: 0.0
        val bz = bias?.optDouble(2, 0.0) ?: 0.0
        biasOn = bx != 0.0 || by != 0.0 || bz != 0.0
        bxField = ctx.gyroNumberField(fmt(bx), 2) { applyBias() }
        byField = ctx.gyroNumberField(fmt(by), 2) { applyBias() }
        bzField = ctx.gyroNumberField(fmt(bz), 2) { applyBias() }
        checkboxBlock("陀螺零偏", biasOn, tripleRow("X", bxField, "Y", byField, "Z", bzField)) { on -> biasOn = on; applyBias() }

        // —— IMU 朝向(XYZ 轴向映射) ——
        body.addView(advLabel("IMU 朝向"))
        val orient = o.optString("imu_orientation").ifEmpty { "XYZ" }
        body.addView(ctx.gyroTextField(orient) { text ->
            if (text.length == 3 && text.all { it in "XYZxyz" }) {
                bg { GyroflowNative.nativeSetImuOrientation(text) }
            }
        })

        // —— 积分方法 ——
        body.addView(advLabel("积分方法"))
        body.addView(buildIntegrationSpinner(o.optInt("integration_method", 1)))

        // —— 方向指示器(对齐 iOS orientationIndicator) ——
        val indicator = OrientationIndicatorView(ctx).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, ctx.dp(100))
        }
        orientationView = indicator
        orientationOn = false
        checkboxBlock("方向指示器", false, indicator) { on ->
            orientationOn = on
            if (on) {
                bg {
                    val q = GyroflowNative.nativeQuatsAtTimestamp(lastTsUs) ?: return@bg
                    ui.post { orientationView?.setQuats(q) }
                }
            }
        }
    }

    /** 宿主在每帧处理后调用(解码线程), 驱动方向指示器随播放更新。 */
    fun updateOrientation(tsUs: Long) {
        lastTsUs = tsUs
        if (!orientationOn) {
            return
        }
        val v = orientationView ?: return
        val q = GyroflowNative.nativeQuatsAtTimestamp(tsUs) ?: return
        ui.post { v.setQuats(q) }
    }

    // ── 应用各设置(对齐 iOS: 关闭时传 0) ──
    private fun applyLpf() {
        val v = if (lpfOn) fieldVal(lpfField) else 0.0
        bg { GyroflowNative.nativeSetImuLpf(v) }
    }

    private fun applyMedian() {
        val v = if (mfOn) fieldVal(mfField).toInt() else 0
        bg { GyroflowNative.nativeSetImuMedian(v) }
    }

    private fun applyRotation() {
        val p = if (rotOn) fieldVal(pField) else 0.0
        val r = if (rotOn) fieldVal(rField) else 0.0
        val y = if (rotOn) fieldVal(yField) else 0.0
        bg { GyroflowNative.nativeSetImuRotation(p, r, y) }
    }

    private fun applyBias() {
        val x = if (biasOn) fieldVal(bxField) else 0.0
        val y = if (biasOn) fieldVal(byField) else 0.0
        val z = if (biasOn) fieldVal(bzField) else 0.0
        bg { GyroflowNative.nativeSetImuBias(x, y, z) }
    }

    private fun applyFrameOffset() {
        frameOffsetValue = frameOffsetField?.let { fieldVal(it).toInt() } ?: 0
        val v = if (frameOffsetOn) frameOffsetValue else 0
        bg { GyroflowNative.nativeSetFrameOffset(v) }
    }

    // ── 积分方法下拉(模型随是否含四元数, 对齐 iOS integrator) ──
    private fun buildIntegrationSpinner(currentMethod: Int): Spinner {
        val withQuat = listOf("None", "Complementary", "VQF", "Simple gyro", "Simple gyro + accel", "Mahony", "Madgwick")
        val noQuat = listOf("Complementary", "VQF", "Simple gyro", "Simple gyro + accel", "Mahony", "Madgwick")
        val items = if (hasQuaternions) withQuat else noQuat
        val selected = (if (hasQuaternions) currentMethod else currentMethod - 1).coerceIn(0, items.size - 1)

        val sp = Spinner(ctx)
        sp.background = GradientDrawable().apply {
            setColor(GyroflowTheme.BOX_BG)             // 底色与输入框一致
            setStroke(ctx.dp(1), GyroflowTheme.BORDER)
            cornerRadius = ctx.dp(6).toFloat()
        }
        sp.setPadding(ctx.dp(10), ctx.dp(8), ctx.dp(10), ctx.dp(8))
        val adapter = object : ArrayAdapter<String>(ctx, android.R.layout.simple_spinner_item, items) {
            override fun getView(position: Int, convertView: View?, parent: ViewGroup): View =
                (super.getView(position, convertView, parent) as TextView).apply {
                    setTextColor(GyroflowTheme.TEXT)
                    textSize = 13f
                }
            override fun getDropDownView(position: Int, convertView: View?, parent: ViewGroup): View =
                (super.getDropDownView(position, convertView, parent) as TextView).apply {
                    setTextColor(GyroflowTheme.TEXT)
                    setBackgroundColor(GyroflowTheme.BG_PANEL)
                    setPadding(ctx.dp(10), ctx.dp(10), ctx.dp(10), ctx.dp(10))
                }
        }
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        sp.adapter = adapter
        sp.setSelection(selected, false)
        sp.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            private var first = true
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                if (first) { first = false; return } // 跳过初始化选中
                val method = if (hasQuaternions) position else position + 1
                bg {
                    GyroflowNative.nativeSetIntegrationMethod(method)
                    ui.post { onIntegrationChanged() } // 重算 usesQuats(积分=None 且有四元数 → 已同步)
                }
            }
            override fun onNothingSelected(parent: AdapterView<*>?) {}
        }
        return sp
    }

    // ── 复用小组件 ──
    private fun checkboxBlock(label: String, initiallyOn: Boolean, content: View, onToggle: (Boolean) -> Unit) {
        body.addView(ctx.gyroCheckBox(label, initiallyOn) { on ->
            content.visibility = if (on) View.VISIBLE else View.GONE
            onToggle(on)
        })
        content.visibility = if (initiallyOn) View.VISIBLE else View.GONE
        body.addView(content)
    }

    // 单字段 + 单位(对齐 iOS NumberField unit)
    private fun unitRow(field: EditText, unit: String): View = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(0, 0, 0, ctx.dp(4))
        addView(field, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        addView(TextView(ctx).apply {
            text = unit
            setTextColor(GyroflowTheme.TEXT_SECONDARY)
            textSize = 12f
            setPadding(ctx.dp(8), 0, 0, 0)
        })
    }

    // 三个带标签的字段一行(Pitch/Roll/Yaw 或 X/Y/Z)
    private fun tripleRow(l1: String, f1: EditText, l2: String, f2: EditText, l3: String, f3: EditText): View =
        LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 0, 0, ctx.dp(4))
            addView(labeled(l1, f1), LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(labeled(l2, f2), LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = ctx.dp(6) })
            addView(labeled(l3, f3), LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = ctx.dp(6) })
        }

    private fun labeled(label: String, field: EditText): View = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        addView(TextView(ctx).apply {
            text = label
            setTextColor(GyroflowTheme.TEXT_SECONDARY)
            textSize = 11f
            setPadding(0, 0, 0, ctx.dp(2))
        })
        addView(field, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
    }

    private fun infoRow(label: String, value: String): View = infoRowValue(label, value).first

    // 返回 (整行, 值标签), 方便后续更新值(如文件名)。
    private fun infoRowValue(label: String, value: String): Pair<View, TextView> {
        val valueLabel = TextView(ctx).apply {
            text = value
            setTextColor(GyroflowTheme.TEXT)
            textSize = 13f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val row = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, ctx.dp(3), 0, ctx.dp(3))
            addView(TextView(ctx).apply {
                text = "$label:"
                setTextColor(GyroflowTheme.TEXT_SECONDARY)
                textSize = 13f
                gravity = Gravity.END
                setPadding(0, 0, ctx.dp(8), 0)
                layoutParams = LinearLayout.LayoutParams(ctx.dp(82), LinearLayout.LayoutParams.WRAP_CONTENT)
            })
            addView(valueLabel)
        }
        return Pair(row, valueLabel)
    }

    private fun sectionTitle(t: String): TextView = TextView(ctx).apply {
        text = t
        setTextColor(GyroflowTheme.TEXT)
        textSize = 15f
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        setPadding(0, ctx.dp(14), 0, ctx.dp(8))
    }

    private fun advLabel(t: String): TextView = TextView(ctx).apply {
        text = t
        setTextColor(GyroflowTheme.TEXT_MUTED)
        textSize = 12f
        setPadding(0, ctx.dp(8), 0, ctx.dp(4))
    }

    private fun fieldVal(f: EditText): Double = f.text.toString().trim().toDoubleOrNull() ?: 0.0

    private fun fmt(d: Double): String = if (d == Math.floor(d) && !d.isInfinite()) d.toLong().toString() else d.toString()

    private fun bg(block: () -> Unit) {
        Thread { block() }.start()
    }
}
