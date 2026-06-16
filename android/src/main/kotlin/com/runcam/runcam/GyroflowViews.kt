package com.runcam.runcam

import android.content.Context
import android.graphics.drawable.GradientDrawable
import android.text.InputFilter
import android.text.InputType
import android.text.Spanned
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.Spinner
import android.widget.TextView

/**
 * Gyroflow 共用 UI 组件(对齐 iOS 的 CheckBox.qml / NumberField.qml / Button.qml)。
 * 全项目复用, 同一组件只此一份实现; 配色统一取 [GyroflowTheme]。
 * 以 Context 扩展函数提供, Activity / View 内可直接调用。
 */

/** dp → px。全项目统一换算, 不要各处重复写。 */
fun Context.dp(v: Int): Int =
    TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

/** 主题主按钮(橙底圆角, 对齐 iOS primary Button)。 */
fun Context.gyroPrimaryButton(label: String, onClick: () -> Unit): TextView = TextView(this).apply {
    text = label
    setTextColor(GyroflowTheme.TEXT)
    textSize = 15f
    gravity = Gravity.CENTER
    setPadding(dp(10), dp(12), dp(10), dp(12))
    background = GradientDrawable().apply {
        setColor(GyroflowTheme.ACCENT)
        cornerRadius = dp(8).toFloat()
    }
    setOnClickListener { if (isEnabled) onClick() }
}

/**
 * iOS 风格复选框(对齐 CheckBox.qml): 20dp 圆角方块, 空心填充。
 * 未选灰色描边; 选中主题色描边 + 主题色 ✓(空心对勾)。
 */
fun Context.gyroCheckBox(label: String, checked: Boolean, onChange: (Boolean) -> Unit): View {
    var state = checked
    val box = TextView(this).apply {
        textSize = 13f
        gravity = Gravity.CENTER
        setTextColor(GyroflowTheme.ACCENT) // 对勾用主题色
    }
    fun applyStyle() {
        box.text = if (state) "✓" else ""
        box.background = GradientDrawable().apply {
            cornerRadius = dp(5).toFloat()
            setColor(android.graphics.Color.TRANSPARENT) // 空心(始终透明填充)
            setStroke(dp(2), if (state) GyroflowTheme.ACCENT else GyroflowTheme.TEXT_SECONDARY)
        }
    }
    applyStyle()
    val ctx = this
    return LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(0, dp(5), 0, dp(5))
        isClickable = true
        setOnClickListener {
            state = !state
            applyStyle()
            onChange(state)
        }
        addView(box, LinearLayout.LayoutParams(dp(20), dp(20)))
        addView(TextView(ctx).apply {
            text = label
            setTextColor(GyroflowTheme.TEXT)
            textSize = 13f
            setPadding(dp(8), 0, 0, 0)
        })
    }
}

/**
 * 可程序化控制的复选框(渲染同 [gyroCheckBox], 额外暴露 [setChecked] 与 [view] 句柄)。
 * 用于官方有联动逻辑的场景: 如「先粗后细」随「同步搜索尺寸」>10s 自动勾选、随「偏移方式」显隐。
 */
class GyroToggle(
    private val context: Context,
    label: String,
    checked: Boolean,
    private val onChange: (Boolean) -> Unit,
) {
    var isChecked = checked
        private set

    private val box = TextView(context).apply {
        textSize = 13f
        gravity = Gravity.CENTER
        setTextColor(GyroflowTheme.ACCENT)
    }

    val view: LinearLayout

    init {
        applyStyle()
        view = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, context.dp(5), 0, context.dp(5))
            isClickable = true
            setOnClickListener { setChecked(!isChecked) }
            addView(box, LinearLayout.LayoutParams(context.dp(20), context.dp(20)))
            if (label.isNotEmpty()) {
                addView(TextView(context).apply {
                    text = label
                    setTextColor(GyroflowTheme.TEXT)
                    textSize = 13f
                    setPadding(context.dp(8), 0, 0, 0)
                })
            }
        }
    }

    private fun applyStyle() {
        box.text = if (isChecked) "✓" else ""
        box.background = GradientDrawable().apply {
            cornerRadius = context.dp(5).toFloat()
            setColor(android.graphics.Color.TRANSPARENT)
            setStroke(context.dp(2), if (isChecked) GyroflowTheme.ACCENT else GyroflowTheme.TEXT_SECONDARY)
        }
    }

    /** 程序化设置勾选; 状态变化时触发 [onChange](对齐官方 checked = expr 绑定语义)。 */
    fun setChecked(c: Boolean) {
        if (isChecked == c) {
            return
        }
        isChecked = c
        applyStyle()
        onChange(c)
    }
}

/**
 * 键盘「完成」: 收起键盘 + 清除焦点(清焦点会触发各自的失焦提交/钳制逻辑), 结束本次输入交互。
 * 所有输入框统一调用, 保证「完成」后真正退出编辑。
 */
internal fun EditText.finishInputOnDone() {
    setOnEditorActionListener { _, actionId, _ ->
        if (actionId == android.view.inputmethod.EditorInfo.IME_ACTION_DONE) {
            clearFocus()
            (context.getSystemService(Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager)
                .hideSoftInputFromWindow(windowToken, 0)
            true
        } else {
            false
        }
    }
}

/**
 * 可编辑数值框(对齐 NumberField.qml): 数字 + 小数 + 负号, 小数位限制为 [precision]。
 * 「完成」或失焦时回调 [onCommit] 提交。
 */
fun Context.gyroNumberField(value: String, precision: Int, onCommit: (String) -> Unit): EditText = EditText(this).apply {
    setText(value)
    setTextColor(GyroflowTheme.TEXT)
    textSize = 12f
    isSingleLine = true
    imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_DONE // 键盘右下角显示「完成」而非「下一步」
    setPadding(dp(10), dp(8), dp(10), dp(8))
    inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL or InputType.TYPE_NUMBER_FLAG_SIGNED
    filters = arrayOf(DecimalDigitsFilter(precision)) // 对齐 iOS DoubleValidator(decimals=precision)
    background = GradientDrawable().apply {
        setColor(GyroflowTheme.BOX_BG)
        setStroke(dp(1), GyroflowTheme.BORDER)
        cornerRadius = dp(6).toFloat()
    }
    finishInputOnDone()
    setOnFocusChangeListener { _, hasFocus -> if (!hasFocus) onCommit(text.toString()) }
}

/**
 * 文本输入框(样式同 [gyroNumberField], 但接受文本; 用于 IMU 朝向等)。
 * 「完成」或失焦时回调 [onCommit]。
 */
fun Context.gyroTextField(value: String, onCommit: (String) -> Unit): EditText = EditText(this).apply {
    setText(value)
    setTextColor(GyroflowTheme.TEXT)
    textSize = 12f
    isSingleLine = true
    imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_DONE // 键盘右下角显示「完成」而非「下一步」
    setPadding(dp(10), dp(8), dp(10), dp(8))
    inputType = InputType.TYPE_CLASS_TEXT
    background = GradientDrawable().apply {
        setColor(GyroflowTheme.BOX_BG)
        setStroke(dp(1), GyroflowTheme.BORDER)
        cornerRadius = dp(6).toFloat()
    }
    finishInputOnDone()
    setOnFocusChangeListener { _, hasFocus -> if (!hasFocus) onCommit(text.toString()) }
}

/**
 * 下拉框(深色底, 与输入框一致)。[onSelected] 在用户真正改变选择时回调(跳过初始化)。
 */
fun Context.gyroSpinner(items: List<String>, selectedIndex: Int, onSelected: (Int) -> Unit): Spinner {
    val sp = Spinner(this)
    sp.background = GradientDrawable().apply {
        setColor(GyroflowTheme.BOX_BG)
        setStroke(dp(1), GyroflowTheme.BORDER)
        cornerRadius = dp(6).toFloat()
    }
    sp.setPadding(dp(10), dp(8), dp(10), dp(8))
    val adapter = object : ArrayAdapter<String>(this, android.R.layout.simple_spinner_item, items) {
        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View =
            (super.getView(position, convertView, parent) as TextView).apply {
                setTextColor(GyroflowTheme.TEXT)
                textSize = 13f
            }
        override fun getDropDownView(position: Int, convertView: View?, parent: ViewGroup): View =
            (super.getDropDownView(position, convertView, parent) as TextView).apply {
                setTextColor(GyroflowTheme.TEXT)
                setBackgroundColor(GyroflowTheme.BG_PANEL)
                setPadding(dp(10), dp(10), dp(10), dp(10))
            }
    }
    adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
    sp.adapter = adapter
    val initial = selectedIndex.coerceIn(0, (items.size - 1).coerceAtLeast(0))
    sp.setSelection(initial, false)
    sp.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
        // 跳过初始化不能用"吞第一次回调"实现: setSelection(pos, false) 同步生效且
        // 不触发回调(监听器还没挂上), 初始化回调有些系统版本根本不会来, "第一次"
        // 吞掉的就是用户第一次真实切换(实测: 切编解码器后分辨率上限没刷新)。
        // 改成与上次位置比较: 重复位置(含可能出现的初始化回调)跳过, 真实切换必达。
        private var lastPosition = initial
        override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
            if (position == lastPosition) return
            lastPosition = position
            onSelected(position)
        }
        override fun onNothingSelected(parent: AdapterView<*>?) {}
    }
    return sp
}

/** 限制小数位数(对齐 iOS DoubleValidator.decimals)。 */
private class DecimalDigitsFilter(private val decimals: Int) : InputFilter {
    override fun filter(source: CharSequence, start: Int, end: Int, dest: Spanned, dstart: Int, dend: Int): CharSequence? {
        val builder = StringBuilder(dest)
        builder.replace(dstart, dend, source.subSequence(start, end).toString())
        val dot = builder.indexOf(".")
        if (dot >= 0 && builder.length - dot - 1 > decimals) {
            return ""
        }
        return null
    }
}

/** 数值格式化: precision<=0 取整, 否则保留 [p] 位小数。 */
fun gyroFmt(v: Double, p: Int): String =
    if (p <= 0) v.toLong().toString() else String.format("%.${p}f", v)

/**
 * 滑杆行(对齐 SliderWithField.qml): [标签] [SeekBar] [数值框 单位]。
 * SeekBar 内部 0..1000 映射 [min]..[max]。拖动中只刷新数值框(轻), 松手才回调 [onChange]
 * (含 native recompute, 重; 避免拖动时高频触发卡顿)。数值框失焦同样提交。
 * 全项目复用, 同一实现仅此一份。
 */
fun Context.gyroSlider(
    label: String, unit: String, min: Double, max: Double, default: Double, precision: Int,
    onChange: (Double) -> Unit,
): View {
    val ctx = this
    val valueField = EditText(ctx).apply {
        setText(gyroFmt(default, precision))
        setTextColor(GyroflowTheme.TEXT); textSize = 12f
        inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL or InputType.TYPE_NUMBER_FLAG_SIGNED
        setBackgroundColor(GyroflowTheme.BG_BAR)
        setPadding(dp(6), dp(4), dp(6), dp(4))
        gravity = Gravity.CENTER
        isSingleLine = true
        imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_DONE // 键盘右下角显示「完成」而非「下一步」
    }
    val bar = SeekBar(ctx).apply {
        this.max = 1000
        progress = (((default - min) / (max - min)) * 1000.0).toInt().coerceIn(0, 1000)
        // 长条(轨道)厚 6dp: 自定义 progressDrawable(底+进度), 圆角
        val trackBar = { color: Int ->
            GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(3).toFloat()
                setColor(color)
                setSize(0, dp(6))
            }
        }
        val prog = android.graphics.drawable.ClipDrawable(
            trackBar(GyroflowTheme.ACCENT), Gravity.LEFT,
            android.graphics.drawable.ClipDrawable.HORIZONTAL,
        )
        progressDrawable = android.graphics.drawable.LayerDrawable(
            arrayOf<android.graphics.drawable.Drawable>(trackBar(android.graphics.Color.parseColor("#555555")), prog)
        ).apply {
            setId(0, android.R.id.background)
            setId(1, android.R.id.progress)
            // 否则子层会被拉伸填满 SeekBar 高度; 锁定 6dp 且垂直居中
            setLayerGravity(0, Gravity.CENTER_VERTICAL)
            setLayerGravity(1, Gravity.CENTER_VERTICAL)
            setLayerHeight(0, dp(6))
            setLayerHeight(1, dp(6))
        }
        // 圆形拖动钮
        thumb = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(GyroflowTheme.ACCENT)
            setSize(dp(14), dp(14))
        }
        // 必须在 setThumb 之后: 否则默认偏移=半个 thumb 宽, 两端会挂出去半个被裁。
        thumbOffset = 0
    }
    bar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
        override fun onProgressChanged(sb: SeekBar?, p: Int, fromUser: Boolean) {
            if (!fromUser) return
            val v = min + (p / 1000.0) * (max - min)
            valueField.setText(gyroFmt(v, precision))
        }
        override fun onStartTrackingTouch(sb: SeekBar?) {}
        override fun onStopTrackingTouch(sb: SeekBar?) {
            val v = min + ((sb?.progress ?: 0) / 1000.0) * (max - min)
            onChange(v)
        }
    })
    valueField.finishInputOnDone()
    valueField.setOnFocusChangeListener { _, has ->
        if (!has) {
            val raw = valueField.text.toString().trim().toDoubleOrNull()
            val cur = min + (bar.progress / 1000.0) * (max - min) // 当前滑杆值, 作非法输入的回退
            val v = (raw ?: cur).coerceIn(min, max)               // 按 [min,max] 钳制
            valueField.setText(gyroFmt(v, precision))             // 文本回写为钳制后的值
            bar.progress = (((v - min) / (max - min)) * 1000.0).toInt().coerceIn(0, 1000)
            if (raw != null) onChange(v)                          // 仅当真输入了数字才应用
        }
    }
    return LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
        // 带滑杆的行整体高度 +6px(上/下各 +3px)
        setPadding(0, dp(4) + 3, 0, dp(4) + 3)
        addView(TextView(ctx).apply { text = label; setTextColor(GyroflowTheme.TEXT); textSize = 13f },
            LinearLayout.LayoutParams(dp(96), LinearLayout.LayoutParams.WRAP_CONTENT))
        addView(bar, LinearLayout.LayoutParams(0, dp(16), 1f))
        addView(valueField, LinearLayout.LayoutParams(dp(56), LinearLayout.LayoutParams.WRAP_CONTENT).apply { leftMargin = dp(6) })
        if (unit.isNotEmpty()) addView(TextView(ctx).apply { text = unit; setTextColor(GyroflowTheme.TEXT_SECONDARY); textSize = 11f; setPadding(dp(4), 0, 0, 0) })
        // 不留尾白: 右边与下拉(选择组件)右边对齐到面板边缘
    }
}

/**
 * 官方样式弹框(对齐官方 Modal / 截图 IMG_1447): 深色圆角卡片, 自上而下:
 * 图标(居中, Info=蓝ⓘ / Success=绿✓, 对齐官方 Modal.Info/Success) → 文案(居中多行)
 * → 「确定」胶囊按钮(居中) → 「不再显示」勾选(传 key 才显示, 勾选后该 key 持久化进
 * SharedPreferences("gyroflow")、下次调用直接不弹; key=null 无勾选行)。
 * 非阻塞悬浮(Dialog 独立窗口, 层级高于 Activity 内容含导出蒙版)。
 */
fun Context.gyroInfoModal(
    message: String,
    dontShowAgainKey: String?,
    success: Boolean = false,
    onConfirm: (() -> Unit)? = null,
) {
    val prefs = getSharedPreferences("gyroflow", Context.MODE_PRIVATE)
    // 已勾「不再显示」: 不弹, 但仍触发 onConfirm(后续动作不能被静默丢弃)。
    if (dontShowAgainKey != null && prefs.getBoolean(dontShowAgainKey, false)) { onConfirm?.invoke(); return }
    val dialog = android.app.Dialog(this)
    dialog.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE)
    val card = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        setPadding(dp(24), dp(20), dp(24), dp(14))
        background = GradientDrawable().apply {
            setColor(0xFF212121.toInt())
            cornerRadius = dp(12).toFloat()
        }
    }
    if (success) {
        card.addView(TextView(this).apply {
            text = "✓"
            textSize = 22f
            setTextColor(android.graphics.Color.WHITE)
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0xFF4CAF50.toInt())
            }
        }, LinearLayout.LayoutParams(dp(40), dp(40)))
    } else {
        card.addView(android.widget.ImageView(this).apply {
            setImageResource(android.R.drawable.ic_dialog_info)
            setColorFilter(0xFF2196F3.toInt())
        }, LinearLayout.LayoutParams(dp(40), dp(40)))
    }
    card.addView(TextView(this).apply {
        text = message
        setTextColor(android.graphics.Color.WHITE)
        textSize = 14f
        gravity = Gravity.CENTER
    }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(14) })
    val check = android.widget.CheckBox(this).apply {
        text = "不再显示"
        setTextColor(android.graphics.Color.WHITE)
        textSize = 13f
        visibility = if (dontShowAgainKey != null) View.VISIBLE else View.GONE
    }
    card.addView(TextView(this).apply {
        text = "确定"
        setTextColor(android.graphics.Color.WHITE)
        textSize = 14f
        gravity = Gravity.CENTER
        setPadding(dp(28), dp(8), dp(28), dp(8))
        background = GradientDrawable().apply {
            setColor(0xFF404040.toInt())
            cornerRadius = dp(6).toFloat()
        }
        isClickable = true
        setOnClickListener {
            if (dontShowAgainKey != null && check.isChecked) {
                prefs.edit().putBoolean(dontShowAgainKey, true).apply()
            }
            dialog.dismiss()
            onConfirm?.invoke()
        }
    }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(18) })
    card.addView(check, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(10) })
    dialog.setContentView(card)
    dialog.window?.setBackgroundDrawable(android.graphics.drawable.ColorDrawable(android.graphics.Color.TRANSPARENT))
    dialog.window?.setDimAmount(0.55f)
    dialog.show()
}
