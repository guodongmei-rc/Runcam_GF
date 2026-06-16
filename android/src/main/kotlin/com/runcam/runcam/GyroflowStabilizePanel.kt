package com.runcam.runcam

import android.content.Context
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.Spinner
import android.widget.TextView

/**
 * 稳定面板(对齐官方 Stabilization)。可折叠; 两个「高级选项」可展开。
 * 每个控件变更 → onApply { GyroflowNative.nativeSetXxx(...) } 由宿主在后台线程跑 + 重渲。
 */
class GyroflowStabilizePanel(
    private val ctx: Context,
    private val onApply: (() -> Unit) -> Unit,
) {
    val root: LinearLayout
    private val infoLabel: TextView

    // 高级① / 高级② 容器
    private val adv1: LinearLayout
    private val adv2: LinearLayout
    private var adv1On = false
    private var adv2On = false

    // 按轴平滑: 勾选「按轴」→ 隐藏外层平滑度, 展开 Pitch/Yaw/Roll 平滑度(对齐桌面 default_algo per_axis)
    private val smoothnessRow: View
    private val perAxisSub: LinearLayout

    // 锁定地平线: 勾选展开「锁定量 + Roll 角度校正」两个滑块
    private val horizonSub: LinearLayout
    private var horizonOn = false
    private var horizonAmount = 100.0   // 锁定量 %, 对齐桌面默认 100
    private var horizonRoll = 0.0       // Roll 角度校正 °, 对齐桌面默认 0

    // 视频速度联动开关 + 卷帘开关状态
    private var linkSmooth = true
    private var linkZoom = true
    private var linkZoomLimit = true
    private var rsOn = true
    private var rsReadoutMs = 11.11
    private var rsDirection = 0          // 帧读出方向 0=上到下 1=下到上 2=左到右 3=右到左(对齐官方 ReadoutDirection)
    private lateinit var rsSub: LinearLayout // 卷帘内容(方向+时间), 取消勾选时隐藏
    private var videoSpeedPct = 100.0   // 当前视频速度%, 联动复选框切换时复用以重应用

    // 动态缩放模式: 0=不缩放 1=动态 2=静态裁剪
    private var zoomMode = 1
    private var zoomSpeedSec = 4.0

    init {
        root = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, ctx.dp(8), 0, 0)
        }

        root.addView(title("稳定"))

        // 平滑算法选择(无标题, 整宽)。顺序对齐核心: 0=无平滑 1=默认 2=纯3D 3=固定摄像头。
        root.addView(ctx.gyroSpinner(listOf("无平滑", "默认", "纯3D", "固定摄像头"), 1) { idx ->
            onApply { GyroflowNative.nativeSetSmoothingMethod(idx) }
        })
        // 平滑度(勾选「按轴」后隐藏)
        smoothnessRow = slider("平滑度", "%", 0.0, 100.0, 50.0, 1) { v ->
            onApply { GyroflowNative.nativeSetSmoothingParam("smoothness", v / 100.0) }
        }
        root.addView(smoothnessRow)
        // 按轴平滑度 Pitch/Yaw/Roll(默认隐藏, 勾选「按轴」后显示, 取代外层平滑度)
        perAxisSub = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL; visibility = View.GONE }
        perAxisSub.addView(slider("Pitch 平滑度", "%", 0.0, 100.0, 50.0, 1) { v -> onApply { GyroflowNative.nativeSetSmoothingParam("smoothness_pitch", v / 100.0) } })
        perAxisSub.addView(slider("Yaw 平滑度", "%", 0.0, 100.0, 50.0, 1) { v -> onApply { GyroflowNative.nativeSetSmoothingParam("smoothness_yaw", v / 100.0) } })
        perAxisSub.addView(slider("Roll 平滑度", "%", 0.0, 100.0, 50.0, 1) { v -> onApply { GyroflowNative.nativeSetSmoothingParam("smoothness_roll", v / 100.0) } })
        root.addView(perAxisSub)

        // 高级选项①
        root.addView(advToggle("高级选项") { adv1On = !adv1On; adv1.visibility = if (adv1On) View.VISIBLE else View.GONE })
        adv1 = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL; visibility = View.GONE }
        adv1.addView(check("按轴", false) { on ->
            // 对齐桌面: 按轴开 → 隐藏外层平滑度, 显示 Pitch/Yaw/Roll 平滑度; 关则相反
            smoothnessRow.visibility = if (on) View.GONE else View.VISIBLE
            perAxisSub.visibility = if (on) View.VISIBLE else View.GONE
            onApply { GyroflowNative.nativeSetSmoothingParam("per_axis", if (on) 1.0 else 0.0) }
        })
        adv1.addView(check("仅限修剪范围内", true) { on -> onApply { GyroflowNative.nativeSetSmoothingParam("trim_range_only", if (on) 1.0 else 0.0) } })
        adv1.addView(slider("最大平滑度", "秒", 0.0, 3.0, 1.0, 3) { v -> onApply { GyroflowNative.nativeSetSmoothingParam("max_smoothness", v) } })
        adv1.addView(slider("高速最大平滑度", "秒", 0.0, 1.0, 0.1, 3) { v -> onApply { GyroflowNative.nativeSetSmoothingParam("alpha_0_1s", v) } })
        root.addView(adv1)

        // 锁定地平线: 勾选 → 展开「锁定量 / Roll 角度校正」(对齐桌面 Stabilization.qml)
        root.addView(check("锁定地平线", false) { on ->
            horizonOn = on
            horizonSub.visibility = if (on) View.VISIBLE else View.GONE
            applyHorizon()
        })
        // 左缩进 28dp(勾选框 20dp + 间距 8dp): 子项标签与「锁定地平线」文字左对齐; 右边仍到面板边缘
        horizonSub = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL; visibility = View.GONE
            setPadding(ctx.dp(28), 0, 0, 0)
        }
        // 锁定量 %: 0..100, 默认 100, 精度 0
        horizonSub.addView(slider("锁定量", "%", 0.0, 100.0, 100.0, 0) { v -> horizonAmount = v; applyHorizon() })
        // Roll 角度校正 °: -180..180, 默认 0, 精度 1
        horizonSub.addView(slider("Roll 角度校正", "°", -180.0, 180.0, 0.0, 1) { v -> horizonRoll = v; applyHorizon() })
        root.addView(horizonSub)

        // 只读信息: 最大旋转 / 最大缩放
        infoLabel = TextView(ctx).apply {
            setTextColor(GyroflowTheme.TEXT_SECONDARY)
            textSize = 12f
            setPadding(0, ctx.dp(4), 0, ctx.dp(8))
        }
        root.addView(infoLabel)
        refreshInfo()

        // 动态缩放模式(无标题, 整宽)
        root.addView(ctx.gyroSpinner(listOf("不缩放", "动态缩放", "静态裁剪"), 1) { idx ->
            zoomMode = idx
            onApply { GyroflowNative.nativeSetAdaptiveZoom(zoomWindow()) }
        })
        // 缩放限额(% + 迭代次数在高级里)
        root.addView(slider("缩放限额", "%", 100.0, 300.0, 130.0, 0) { v ->
            zoomLimitPct = v
            onApply { GyroflowNative.nativeSetMaxZoom(v, zoomIters) }
        })
        // 缩放速度
        root.addView(slider("缩放速度", "秒", 0.0, 10.0, 4.0, 3) { v ->
            zoomSpeedSec = v
            onApply { GyroflowNative.nativeSetAdaptiveZoom(zoomWindow()) }
        })
        // 镜头校正
        root.addView(slider("镜头校正", "%", 0.0, 100.0, 100.0, 0) { v ->
            onApply { GyroflowNative.nativeSetLensCorrection(v / 100.0) }
        })

        // 高级选项②
        root.addView(advToggle("高级选项") { adv2On = !adv2On; adv2.visibility = if (adv2On) View.VISIBLE else View.GONE })
        adv2 = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL; visibility = View.GONE }
        adv2.addView(slider("视场角", "", 0.5, 3.0, 1.0, 3) { v -> onApply { GyroflowNative.nativeSetFov(v) } })
        // 卷帘快门校正(对齐官方 CheckBoxWithContent): 取消勾选 → 隐藏内容(方向+时间)且 readout=0(不参与计算)
        adv2.addView(check("卷帘快门校正", true) { on ->
            rsOn = on
            rsSub.visibility = if (on) View.VISIBLE else View.GONE
            onApply { GyroflowNative.nativeSetFrameReadoutTime(if (on) rsReadoutMs else 0.0) }
        })
        rsSub = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
        rsSub.addView(readoutDirectionRow())  // 帧读出方向按钮(在帧读出时间输入框上面, 对齐官方)
        rsSub.addView(slider("帧读出时间", "毫秒", 0.0, 30.0, 11.11, 2) { v -> rsReadoutMs = v; onApply { GyroflowNative.nativeSetFrameReadoutTime(if (rsOn) v else 0.0) } })
        adv2.addView(rsSub)
        // 视频速度 + 3 联动
        adv2.addView(videoSpeedRow())
        adv2.addView(slider("视频速度", "%", 10.0, 300.0, 100.0, 0) { v ->
            videoSpeedPct = v
            applyVideoSpeed()
        })
        // 缩放方式
        adv2.addView(labeled("缩放方式", ctx.gyroSpinner(listOf("Gaussian filter", "Envelope follower"), 1) { idx ->
            onApply { GyroflowNative.nativeSetZoomingMethod(idx) }
        }))
        // 附加 3D 旋转
        adv2.addView(rowLabel("附加 3D 旋转"))
        adv2.addView(slider("Pitch", "°", -180.0, 180.0, 0.0, 2) { v -> pitch = v; apply3DRotation() })
        adv2.addView(slider("Yaw", "°", -180.0, 180.0, 0.0, 2) { v -> yaw = v; apply3DRotation() })
        adv2.addView(slider("Roll", "°", -180.0, 180.0, 0.0, 2) { v -> roll = v; apply3DRotation() })
        // 缩放限额迭代次数
        adv2.addView(slider("缩放限额迭代次数", "", 1.0, 20.0, 5.0, 0) { v ->
            zoomIters = v.toInt().coerceIn(1, 50)
            onApply { GyroflowNative.nativeSetMaxZoom(zoomLimitPct, zoomIters) }
        })
        root.addView(adv2)
    }

    // ── 状态(供组合 setter 用)──
    private var zoomIters = 5
    private var zoomLimitPct = 130.0
    private var pitch = 0.0
    private var yaw = 0.0
    private var roll = 0.0

    private fun zoomWindow(): Double = when (zoomMode) {
        0 -> 0.0       // 不缩放
        2 -> -1.0      // 静态裁剪
        else -> zoomSpeedSec
    }

    private fun apply3DRotation() {
        onApply { GyroflowNative.nativeSetAdditionalRotation(pitch, yaw, roll) }
    }

    // 关闭时 amount/roll 均传 0(对齐桌面: 取消勾选 lockAmount=0, roll=0)。
    private fun applyHorizon() {
        val amount = if (horizonOn) horizonAmount else 0.0
        val roll = if (horizonOn) horizonRoll else 0.0
        onApply { GyroflowNative.nativeSetHorizonLock(amount, roll) }
    }

    /** 刷新「最大旋转/最大缩放」只读信息(读 nativeGetStabInfo)。 */
    fun refreshInfo() {
        val a = GyroflowNative.nativeGetStabInfo() ?: doubleArrayOf(0.0, 0.0, 0.0, 0.0)
        infoLabel.text = "最大旋转: Pitch ${fmt(a.getOrElse(0){0.0},1)}°, Yaw ${fmt(a.getOrElse(1){0.0},1)}°, Roll ${fmt(a.getOrElse(2){0.0},1)}°\n最大缩放: ${fmt(a.getOrElse(3){0.0},1)}%"
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
    private fun check(label: String, checked: Boolean, onChange: (Boolean) -> Unit): View =
        ctx.gyroCheckBox(label, checked, onChange)

    private fun advToggle(t: String, onClick: () -> Unit): TextView = TextView(ctx).apply {
        text = t; setTextColor(GyroflowTheme.ACCENT); textSize = 13f
        gravity = Gravity.CENTER; setPadding(0, ctx.dp(8), 0, ctx.dp(8))
        isClickable = true
        setOnClickListener { onClick() }
    }

    /** 滑杆行(共享实现见 GyroflowViews.gyroSlider)。 */
    private fun slider(label: String, unit: String, min: Double, max: Double, default: Double, precision: Int, onChange: (Double) -> Unit): View =
        ctx.gyroSlider(label, unit, min, max, default, precision, onChange)

    // 视频速度联动: 三个无文字复选框, 顺序对齐官方(左→右): 缩放限额 / 缩放速度 / 平滑。
    // 勾选/取消时 toast 说明并即时重应用视频速度(对齐官方 onCheckedChanged → updateVideoSpeed)。
    private fun videoSpeedRow(): View = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
        addView(TextView(ctx).apply { text = "视频速度联动"; setTextColor(GyroflowTheme.TEXT); textSize = 13f },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        addView(linkCheck("缩放限额", linkZoomLimit) { on -> linkZoomLimit = on })
        addView(linkCheck("缩放速度", linkZoom) { on -> linkZoom = on })
        addView(linkCheck("平滑", linkSmooth) { on -> linkSmooth = on })
    }

    private fun linkCheck(name: String, initial: Boolean, set: (Boolean) -> Unit): View =
        ctx.gyroCheckBox("", initial) { on ->
            set(on)
            toast("链接到「$name」: ${if (on) "开" else "关"}")
            applyVideoSpeed()
        }.apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { marginStart = ctx.dp(12) }
        }

    private fun applyVideoSpeed() {
        onApply { GyroflowNative.nativeSetVideoSpeed(videoSpeedPct / 100.0, linkSmooth, linkZoom, linkZoomLimit) }
    }

    // 帧读出方向按钮(对齐官方 ReadoutDirection): 小边框方块 + 向下箭头, 点击循环 (dir+1)%4,
    // 箭头按 [0,180,-90,90] 旋转, 并把方向应用到内核 + toast 当前方向名。
    private fun readoutDirectionRow(): View {
        val arrow = TextView(ctx).apply {
            text = "↓"; setTextColor(GyroflowTheme.ACCENT); textSize = 14f; gravity = Gravity.CENTER
        }
        val box = LinearLayout(ctx).apply {
            gravity = Gravity.CENTER
            setPadding(ctx.dp(10), ctx.dp(2), ctx.dp(10), ctx.dp(2))
            background = GradientDrawable().apply {
                cornerRadius = ctx.dp(3).toFloat()
                setColor(android.graphics.Color.TRANSPARENT)
                setStroke(ctx.dp(1), GyroflowTheme.TEXT_SECONDARY)
            }
            isClickable = true
            addView(arrow)
            setOnClickListener {
                rsDirection = (rsDirection + 1) % 4
                arrow.rotation = floatArrayOf(0f, 180f, -90f, 90f)[rsDirection]
                onApply { GyroflowNative.nativeSetFrameReadoutDirection(rsDirection) }
                toast("帧读出方向: ${readoutDirName(rsDirection)}")
            }
        }
        return LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(0, ctx.dp(4), 0, ctx.dp(2))
            addView(TextView(ctx).apply { text = "帧读出方向"; setTextColor(GyroflowTheme.TEXT); textSize = 13f },
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(box)
        }
    }

    private fun readoutDirName(d: Int): String = when (d) {
        1 -> "下到上"; 2 -> "左到右"; 3 -> "右到左"; else -> "上到下"
    }

    // 居中提示: Android 11+ 系统 Toast 会忽略 setGravity(强制底部), 故改用 decorView 上的居中浮层。
    private var toastView: View? = null

    private fun toast(msg: String) {
        val activity = ctx as? android.app.Activity
        if (activity == null) {
            android.widget.Toast.makeText(ctx, msg, android.widget.Toast.LENGTH_SHORT).show()
            return
        }
        val root = activity.window.decorView as android.view.ViewGroup
        toastView?.let { (it.parent as? android.view.ViewGroup)?.removeView(it) } // 移除上一个, 避免堆叠
        val tv = TextView(ctx).apply {
            text = msg
            setTextColor(android.graphics.Color.WHITE)
            textSize = 14f
            gravity = Gravity.CENTER
            setPadding(ctx.dp(20), ctx.dp(12), ctx.dp(20), ctx.dp(12))
            background = GradientDrawable().apply {
                cornerRadius = ctx.dp(10).toFloat()
                setColor(android.graphics.Color.parseColor("#CC000000"))
            }
        }
        toastView = tv
        root.addView(
            tv,
            android.widget.FrameLayout.LayoutParams(
                android.widget.FrameLayout.LayoutParams.WRAP_CONTENT,
                android.widget.FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER,
            ),
        )
        tv.postDelayed({
            (tv.parent as? android.view.ViewGroup)?.removeView(tv)
            if (toastView === tv) toastView = null
        }, 1400)
    }

    private fun fmt(v: Double, p: Int): String = gyroFmt(v, p)
}
