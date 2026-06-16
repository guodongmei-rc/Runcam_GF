package com.runcam.runcam

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.text.Editable
import android.text.TextWatcher
import android.util.Log
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/**
 * 原生 Gyroflow 界面(MVP 的 View 层, 对齐 iOS)。
 * 职责仅限 UI 与生命周期: 顶栏(关闭) + 预览区(SurfaceView, wgpu) + 底部 Tab(输入/参数/导出)。
 * 解码交给 [VideoDecoder], 帧重排交给 [YuvPacker], 稳定/显示交给 [GyroflowNative]。
 *   - 不自动弹文件选择器; 用户在「输入」页点「选择视频」才选(对齐 iOS)。
 * 待补: 参数/导出面板的具体控件(对齐 iOS 各 SectionView)。
 */
class GyroflowActivity : Activity(), SurfaceHolder.Callback {

    private companion object {
        const val TAG = "GyroflowPreview"
        const val REQ_PICK_VIDEO = 1001
        const val REQ_PICK_LENS = 1002
        const val REQ_PICK_GYRO = 1003
        const val REQ_EXPORT_PERM = 1004
        const val REQ_GRANT_GYRO_DIR = 1005  // 「授权视频所在目录」(同名 sidecar 自动检测)
        const val REQ_PICK_EXPORT_DIR = 1006 // 「…」选导出存储目录(未选默认存相册)
    }

    private val infoLabels = HashMap<String, TextView>()
    private lateinit var extraInfoBox: LinearLayout // 额外元数据动态行(比特率/音频/旋转/recording_settings 等, 存在才显示)
    private lateinit var lensStatusLabel: TextView
    private lateinit var lensResults: LinearLayout
    private lateinit var lensDetail: LinearLayout
    private lateinit var lensAdvancedHeader: TextView
    private lateinit var lensAdvanced: LinearLayout
    private var lensAdvancedExpanded = false
    private lateinit var motionPanel: GyroflowMotionPanel
    private var motionFromVideo = false // 运动数据来自视频本身(内嵌)还是外挂文件(对齐官方 filename 匹配)
    private var lastGyroUri: Uri? = null // 最近一次外挂运动数据文件(「加载全部元数据」切换重载用)

    private var surfaceReady = false
    private var pendingUri: Uri? = null
    private var started = false
    private var decoder: VideoDecoder? = null

    private lateinit var statusLabel: TextView
    private lateinit var selectPlaceholder: TextView
    private lateinit var hudLabel: TextView   // 预览左上角: 时间/帧/缩放
    private lateinit var lensWarningLabel: TextView // 预览缩放框下方: 未加载镜头档案黄色警告(对齐官方)
    private var videoFps = 0.0
    private var videoFrameCount = 0L
    private lateinit var playButton: TextView
    private lateinit var stabButton: TextView
    private var stabEnabled = true
    private lateinit var previewArea: FrameLayout
    private lateinit var videoDirHintLabel: TextView // 视频信息·蓝色目录授权提示框(无运动数据/镜头时显示)
    private var pendingScanLensUri: Uri? = null      // 授权目录扫描到的同名镜头 json, 视频信息刷新时兜底加载
    private var resetExportSize = false              // 导入新视频时按新视频信息重置输出大小(授权后重载不重置)
    private var exportDirUri: Uri? = null            // 用户授权的导出存储目录(SAF tree; null=未授权,导出前强制授权)
    private var pendingExportUri: Uri? = null         // 非 null: 授权目录后继续导出这个视频(对齐官方"先授权再导出")
    private lateinit var surfaceView: SurfaceView
    private lateinit var gyroTimeline: GyroTimelineView
    private var videoDurationUs = 0L
    private var lastProgress = 0.0 // 最近一帧的播放进度(同步后重渲当前帧用)
    private var videoW = 0
    private var videoH = 0
    private lateinit var panelContainer: FrameLayout
    private val tabPanels = arrayOfNulls<View>(3) // 0=输入 1=参数 2=导出
    // 没有视频时锁定「参数/导出」面板(对齐官方 innerItem.enabled: vid.loaded): 拦截触摸 + 灰显。
    private val lockOverlays = mutableListOf<View>()
    private val lockContents = mutableListOf<View>()
    private val tabIcons = arrayOfNulls<ImageView>(3)
    private val tabLabels = arrayOfNulls<TextView>(3)
    private val tabIndicators = arrayOfNulls<View>(3)
    private var currentTab = 0


    private lateinit var syncPanel: GyroflowSyncPanel
    private lateinit var stabPanel: GyroflowStabilizePanel
    private lateinit var advancedPanel: GyroflowAdvancedPanel
    private lateinit var exportPanel: GyroflowExportPanel
    private var exporter: GyroflowExporter? = null
    private var autosync: GyroflowAutosync? = null

    // 自动同步全屏蒙版(对齐官方 Gyroflow 分析覆盖层)
    private lateinit var autosyncOverlay: FrameLayout
    private lateinit var autosyncOverlayTitle: TextView
    private lateinit var autosyncOverlaySub: TextView
    private lateinit var autosyncOverlayBar: android.widget.ProgressBar
    private var autosyncStartMs = 0L

    // 导出全屏蒙版(对齐 iOS 导出时禁用预览交互 + 显示进度): 半透明遮罩 + 「导出中 XX%」+ 进度条 + 取消
    private lateinit var exportOverlay: FrameLayout
    private lateinit var exportOverlayTitle: TextView
    private lateinit var exportOverlaySub: TextView
    private lateinit var exportOverlayBar: android.widget.ProgressBar

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // 必须在任何其它原生调用之前初始化 ndk_context(对齐 lib.rs 注释:
        // 否则 gyroflow_core 取数据目录 / 解析 content:// 时 android_context()
        // 未初始化 → Rust panic("non-string panic payload"))。幂等。
        GyroflowNative.nativeInit(applicationContext)
        setContentView(buildUi())
        restoreGrantedDirs()
    }

    /**
     * 启动时把已持久化的 SAF 目录授权重新注册进 gyroflow 白名单 —— 对齐官方
     * App.qml:679 restore_allowed_folders。白名单(ALLOWED_FOLDERS)只在内存,
     * 不恢复则「授权视频所在目录」只在授权当次会话生效, 重启后 content:// 的
     * get_folder 匹配不到 tree(core/filesystem/mod.rs:232-247), 同名 sidecar
     * (gcsv/bbl/bfl/csv)自动加载失效。OS 级权限已由 takePersistableUriPermission 持久化。
     */
    private fun restoreGrantedDirs() {
        Thread {
            contentResolver.persistedUriPermissions
                .filter { it.isReadPermission }
                .forEach { GyroflowNative.nativeFolderAccessGranted(it.uri.toString()) }
        }.start()
        // 恢复用户上次选定的导出存储目录(权限已被 takePersistableUriPermission 持久化;
        // 授权已失效则回落默认存相册)
        getSharedPreferences("gyroflow", MODE_PRIVATE).getString("export_dir_uri", null)?.let { saved ->
            val uri = Uri.parse(saved)
            val stillGranted = contentResolver.persistedUriPermissions.any { it.uri == uri && it.isWritePermission }
            exportDirUri = if (stillGranted) uri else null
        }
        // 「输出路径:」同行显示当前导出目录(未授权→「未选择」)
        exportPanel.setExportDir(exportDirDisplay(exportDirUri))
    }

    // 导出目录显示串: SAF tree 段名形如 "primary:Movies/Gyroflow" → 取冒号后的 "Movies/Gyroflow"
    // (对齐"a/b文件夹名"格式)。null → null。
    private fun exportDirDisplay(uri: Uri?): String? {
        val seg = uri?.lastPathSegment ?: return null
        return seg.substringAfter(':', seg)
    }

    // ── UI 构建(代码布局; 后续按 iOS 细化各面板)──
    private fun buildUi(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(GyroflowTheme.BG)
        }
        root.addView(buildTopBar())
        root.addView(buildPreviewArea())
        root.addView(buildGyroTimeline())
        root.addView(buildButtonRow())
        root.addView(buildTabBar())
        root.addView(buildPanelContainer())
        selectTab(0)

        // 全屏容器: 根布局 + 自动同步蒙版(盖在最上层)
        val container = FrameLayout(this)
        container.addView(
            root,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT),
        )
        autosyncOverlay = buildAutosyncOverlay()
        container.addView(
            autosyncOverlay,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT),
        )
        exportOverlay = buildExportOverlay()
        container.addView(
            exportOverlay,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT),
        )
        return container
    }

    // 导出全屏蒙版: 半透明遮罩(拦截触摸, 盖住导出时一卡一卡的预览) + 进度条 + 「导出中 XX%」+ 取消。
    private fun buildExportOverlay(): FrameLayout {
        val overlay = FrameLayout(this).apply {
            setBackgroundColor(android.graphics.Color.parseColor("#CC000000"))
            isClickable = true
            visibility = View.GONE
        }
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }
        exportOverlayBar = android.widget.ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 1000; progress = 0
            progressTintList = android.content.res.ColorStateList.valueOf(GyroflowTheme.ACCENT)
        }
        exportOverlayTitle = TextView(this).apply {
            text = "渲染中 0.00%..."
            setTextColor(GyroflowTheme.TEXT); textSize = 14f; gravity = Gravity.CENTER
        }
        exportOverlaySub = TextView(this).apply {
            text = ""
            setTextColor(GyroflowTheme.TEXT_SECONDARY); textSize = 12f; gravity = Gravity.CENTER
        }
        val cancel = TextView(this).apply {
            text = "取消"
            setTextColor(GyroflowTheme.ACCENT); textSize = 15f; gravity = Gravity.CENTER
            setPadding(dp(24), dp(8), dp(24), dp(8))
            setOnClickListener { exporter?.cancel() }
        }
        box.addView(exportOverlayBar, LinearLayout.LayoutParams(dp(240), dp(6)).apply { bottomMargin = dp(10) })
        box.addView(exportOverlayTitle, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(4) })
        box.addView(exportOverlaySub, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(12) })
        box.addView(cancel)
        overlay.addView(box, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        return overlay
    }

    private fun showExportOverlay() {
        exportOverlayTitle.text = "渲染中 0.00%..."
        exportOverlaySub.text = ""
        exportOverlayBar.progress = 0
        exportOverlay.visibility = View.VISIBLE
    }

    // 对齐官方: 渲染中 X.XX%... (帧/总帧 @ fps) / 耗时: Ns, 剩余: Ns
    private fun updateExportOverlay(p: GyroflowExporter.Progress) {
        exportOverlayBar.progress = (p.percent.coerceIn(0f, 1f) * 1000).toInt()
        exportOverlayTitle.text = "渲染中 %.2f%%...  (%d/%d @ %.1ffps)".format(p.percent * 100, p.frame, p.total, p.fps)
        exportOverlaySub.text = "耗时: ${p.elapsedSec.toInt()}秒, 剩余: ${p.remainingSec.toInt()}秒"
    }

    private fun hideExportOverlay() { exportOverlay.visibility = View.GONE }

    // 自动同步全屏蒙版: 半透明遮罩 + 居中「分析中 XX.XX%」+ 进度条 + 取消(对齐官方截图)
    private fun buildAutosyncOverlay(): FrameLayout {
        val overlay = FrameLayout(this).apply {
            setBackgroundColor(android.graphics.Color.parseColor("#CC000000")) // 半透明黑遮罩
            isClickable = true   // 拦截触摸 —— 真正的蒙版, 同步中禁止误操作底层 UI
            visibility = View.GONE
        }
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }
        autosyncOverlayTitle = TextView(this).apply {
            text = "分析中 0.00%"
            setTextColor(GyroflowTheme.TEXT)
            textSize = 14f
            gravity = Gravity.CENTER
        }
        autosyncOverlayBar = android.widget.ProgressBar(
            this, null, android.R.attr.progressBarStyleHorizontal,
        ).apply {
            max = 10000
            progress = 0
            progressTintList = android.content.res.ColorStateList.valueOf(GyroflowTheme.ACCENT)
        }
        autosyncOverlaySub = TextView(this).apply {
            text = "正在分析运动数据…"
            setTextColor(GyroflowTheme.TEXT_SECONDARY)
            textSize = 12f
            gravity = Gravity.CENTER
        }
        val cancel = TextView(this).apply {
            text = "取消"
            setTextColor(GyroflowTheme.ACCENT)
            textSize = 15f
            gravity = Gravity.CENTER
            setPadding(dp(24), dp(8), dp(24), dp(8))
            setOnClickListener { onAutosyncToggle(false) }
        }
        // 顺序对齐官方: 进度条在最上 → 分析中文字 → 耗时/剩余 → 取消
        box.addView(
            autosyncOverlayBar,
            LinearLayout.LayoutParams(dp(220), dp(6)).apply { bottomMargin = dp(10) },
        )
        box.addView(
            autosyncOverlayTitle,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                .apply { bottomMargin = dp(6) },
        )
        box.addView(
            autosyncOverlaySub,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                .apply { bottomMargin = dp(14) },
        )
        box.addView(cancel)
        overlay.addView(
            box,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER),
        )
        return overlay
    }

    private fun showAutosyncOverlay() {
        autosyncStartMs = System.currentTimeMillis()
        autosyncOverlayTitle.text = "分析中 0.00%"
        autosyncOverlayBar.progress = 0
        autosyncOverlaySub.text = ""
        autosyncOverlay.visibility = View.VISIBLE
    }

    private fun hideAutosyncOverlay() {
        autosyncOverlay.visibility = View.GONE
    }

    // 成功收尾: 核心进度分两段(喂帧 0–58%, 求偏移 60–100%), 求偏移很快、随即 onDone 隐藏,
    // 导致 100% 一闪即逝看不到。这里显式置 100% 停留片刻再隐藏。
    private fun completeAutosyncOverlay() {
        autosyncOverlayBar.progress = 10000
        autosyncOverlayTitle.text = "分析完成 100.00%"
        autosyncOverlaySub.text = "耗时: ${timeToStr((System.currentTimeMillis() - autosyncStartMs) / 1000.0)}"
        autosyncOverlay.postDelayed({ hideAutosyncOverlay() }, 600)
    }

    // 完全对齐官方 LoaderOverlay.qml + Util.js(calculateTimesAndFps): 进度用 raw 值(不钳制/不重映射),
    // 百分比 = min(progress,1)*100 保留两位; fps = 当前帧/已耗时秒; 剩余 = 已耗时/progress − 已耗时。
    private fun updateAutosyncOverlay(pr: GyroflowAutosync.Progress) {
        val progress = pr.percent
        val pct = Math.min(progress, 1.0) * 100.0
        autosyncOverlayBar.progress = (Math.min(progress, 1.0) * 10000.0).toInt().coerceIn(0, 10000)

        val cur = pr.framesDone
        val total = pr.framesTotal
        val elapsedMs = (System.currentTimeMillis() - autosyncStartMs).toDouble()
        var fpsText = ""
        var line2 = ""
        if (progress > 0.0 && progress <= 1.0 && autosyncStartMs > 0L) {
            val remainingMs = elapsedMs / progress - elapsedMs
            if (remainingMs > 5 || elapsedMs > 5) {
                line2 = "耗时: ${timeToStr(elapsedMs / 1000.0)}。剩余: ${timeToStr(remainingMs / 1000.0)}"
            }
            if (elapsedMs > 5 && cur > 0) {
                fpsText = " @ ${String.format("%.1f", cur / (elapsedMs / 1000.0))}fps"
            }
        }
        val framesText = if (total > 0) " ($cur/$total$fpsText)" else ""
        autosyncOverlayTitle.text = "分析中 ${String.format("%.2f", pct)}%$framesText"
        autosyncOverlaySub.text = line2
    }

    // 对齐官方 Util.js timeToStr
    // HUD 时间: HH:MM:SS
    private fun fmtTime(sec: Double): String {
        val t = sec.toLong()
        return String.format("%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    private fun timeToStr(sec: Double): String {
        var v = sec % 31536000.0
        val d = Math.floor(v / 86400.0).toInt(); v %= 86400.0
        val h = Math.floor(v / 3600.0).toInt(); v %= 3600.0
        val m = Math.floor(v / 60.0).toInt()
        val s = Math.round(v % 60.0).toInt()
        if (d != 0 || h != 0 || m != 0 || s != 0) {
            val sb = StringBuilder()
            if (d != 0) sb.append("${d}天")
            if (h != 0) sb.append("${h}时")
            if (m != 0) sb.append("${m}分")
            sb.append("${s}秒")
            return sb.toString()
        }
        return "< 1秒"
    }

    private fun buildTopBar(): View {
        val topBar = FrameLayout(this).apply {
            setBackgroundColor(GyroflowTheme.BG_BAR)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(48))
        }
        val title = TextView(this).apply {
            text = "Gyroflow"
            setTextColor(GyroflowTheme.TEXT)
            textSize = 16f
            gravity = Gravity.CENTER
        }
        val closeBtn = TextView(this).apply {
            text = "✕"
            setTextColor(GyroflowTheme.TEXT)
            textSize = 20f
            setPadding(dp(16), dp(10), dp(16), dp(10))
            setOnClickListener { finish() }
        }
        topBar.addView(title, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER))
        topBar.addView(closeBtn, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.START or Gravity.CENTER_VERTICAL))
        return topBar
    }

    private fun buildPreviewArea(): View {
        // 预览默认 16:9(开防抖时); 关防抖时改为按宽定高(原始比例)
        val previewH = resources.displayMetrics.widthPixels * 9 / 16
        previewArea = FrameLayout(this).apply {
            setBackgroundColor(GyroflowTheme.BG)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, previewH)
        }
        surfaceView = SurfaceView(this)
        surfaceView.holder.addCallback(this)
        previewArea.addView(surfaceView, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        statusLabel = TextView(this).apply {
            text = "未选择视频"
            setTextColor(GyroflowTheme.TEXT)
            textSize = 11f
            setPadding(dp(10), dp(6), dp(10), dp(6))
            setBackgroundColor(GyroflowTheme.OVERLAY) // 黑色半透明底(对齐 iOS)
        }
        previewArea.addView(statusLabel, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.START))

        // 左上角竖排: HUD(时间/帧/缩放) + 缩放框下方的镜头未加载黄色警告(对齐官方)
        val topLeftColumn = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        hudLabel = TextView(this).apply {
            text = ""
            setTextColor(GyroflowTheme.TEXT)
            textSize = 11f
            typeface = android.graphics.Typeface.MONOSPACE
            setPadding(dp(8), dp(4), dp(8), dp(4))
            setBackgroundColor(GyroflowTheme.OVERLAY)
            visibility = View.GONE
        }
        topLeftColumn.addView(hudLabel, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        // 黄色警告框: 未加载镜头档案时显示, 紧贴缩放框下方(对齐官方 Gyroflow 预览警告)
        lensWarningLabel = TextView(this).apply {
            text = "镜头配置文件并未加载，结果看起来可能会不正确。请为您的相机加载镜头配置文件。"
            setTextColor(Color.BLACK)
            textSize = 11f
            setPadding(dp(8), dp(5), dp(8), dp(5))
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#F2C200")) // 琥珀黄
                cornerRadius = dp(4).toFloat()
            }
            visibility = View.GONE
        }
        // 警告框宽度撑满预览(右边与预览画面右边对齐)
        topLeftColumn.addView(lensWarningLabel, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) })
        previewArea.addView(topLeftColumn, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.START))

        // 预览正中的虚线「选择文件」占位(对齐 iOS dropPlaceholder), 点击选片, 选后隐藏
        selectPlaceholder = TextView(this).apply {
            text = "选择文件"
            setTextColor(GyroflowTheme.TEXT_MUTED)
            textSize = 18f
            setPadding(dp(24), dp(14), dp(24), dp(14))
            background = GradientDrawable().apply {
                setColor(Color.TRANSPARENT)
                setStroke(dp(2), GyroflowTheme.TEXT_HINT, dp(7).toFloat(), dp(5).toFloat())
                cornerRadius = dp(4).toFloat()
            }
            setOnClickListener { pickVideo() }
        }
        previewArea.addView(selectPlaceholder, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        return previewArea
    }

    // 陀螺数据时间轴(预览下方、按钮上方, 对齐 iOS GyroTimelineView)
    private fun buildGyroTimeline(): View {
        gyroTimeline = GyroTimelineView(this).apply {
            onSeek = { p -> decoder?.seekTo(p) }
        }
        val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(64))
        lp.setMargins(dp(12), dp(8), dp(12), 0)
        gyroTimeline.layoutParams = lp
        return gyroTimeline
    }

    // 播放控制条(预览下方, 对齐 iOS): 播放/暂停 + 开启/关闭防抖, 等宽并排
    private fun buildButtonRow(): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(GyroflowTheme.BG_BAR)
            setPadding(dp(12), dp(8), dp(12), dp(8))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        }
        playButton = gyroPrimaryButton("播放") { togglePlay() }
        stabButton = gyroPrimaryButton("关闭防抖") { toggleStab() } // 默认开启防抖, 按钮显示"关闭防抖"
        setButtonEnabled(playButton, false)
        setButtonEnabled(stabButton, false)
        row.addView(playButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginEnd = dp(6) })
        row.addView(stabButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = dp(6) })
        return row
    }

    private fun setButtonEnabled(b: TextView, e: Boolean) {
        b.isEnabled = e
        b.alpha = if (e) 1f else 0.45f
    }

    // 分段控件(对齐 iOS mobile Tabs): 输入/参数/导出, 图标 + 文字 + 选中下划线指示器。
    private fun buildTabBar(): View {
        val tabBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            background = GradientDrawable().apply {
                setColor(GyroflowTheme.BG_TAB)
                cornerRadius = dp(5).toFloat() // 对齐 iOS styleBackground2 radius 5
            }
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(52))
        }
        // (标题, 图标, 图标尺寸) 对齐 iOS: video/settings/save, 20/24/24
        val items = listOf(
            Triple("输入", R.drawable.ic_gf_video, 20),
            Triple("参数", R.drawable.ic_gf_settings, 22),
            Triple("导出", R.drawable.ic_gf_save, 22),
        )
        items.forEachIndexed { i, (title, iconRes, size) ->
            val tab = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f)
                setOnClickListener { selectTab(i) }
            }
            val content = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
            }
            val icon = ImageView(this).apply {
                setImageResource(iconRes)
                layoutParams = LinearLayout.LayoutParams(dp(size), dp(size))
            }
            val label = TextView(this).apply {
                text = title
                textSize = 13f
                setTypeface(typeface, android.graphics.Typeface.BOLD) // 对齐 iOS font.bold
                gravity = Gravity.CENTER
                setPadding(dp(6), 0, 0, 0)
            }
            content.addView(icon)
            content.addView(label)
            val indicator = View(this).apply {
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(3))
            }
            tab.addView(content)
            tab.addView(indicator)
            tabBar.addView(tab)
            tabIcons[i] = icon
            tabLabels[i] = label
            tabIndicators[i] = indicator
        }
        return tabBar
    }

    private fun buildPanelContainer(): View {
        // 面板占据预览下方剩余空间
        panelContainer = FrameLayout(this).apply {
            setBackgroundColor(GyroflowTheme.BG_PANEL)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
        }
        tabPanels[0] = buildInputPanel()
        tabPanels[1] = buildParamsPanel()
        tabPanels[2] = buildExportPanel()
        return panelContainer
    }

    // 「导出」Tab(对齐官方 Export)
    // 把面板包一层: 透明遮罩 + 内容灰显, 用于「无视频时不可操作」(对齐官方 enabled: vid.loaded)。
    // 遮罩是「滚动代理」: 消费触摸(子控件收不到 → 不可操作), 但把事件转交 ScrollView →
    // 列表仍可滚动, 只是内部控件点不动。默认锁定, 视频就绪后 setInputLocked(false) 解锁。
    private fun lockableWrap(content: ScrollView): View {
        val frame = FrameLayout(this)
        frame.addView(content, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        val overlay = View(this).apply {
            @Suppress("ClickableViewAccessibility")
            setOnTouchListener { _, event -> content.onTouchEvent(event); true } // 只滚动, 不下发给子控件
        }
        frame.addView(overlay, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        content.alpha = 0.5f     // 初始灰显(锁定)
        lockContents.add(content)
        lockOverlays.add(overlay)
        return frame
    }

    private fun setInputLocked(locked: Boolean) {
        lockOverlays.forEach { it.visibility = if (locked) View.VISIBLE else View.GONE }
        lockContents.forEach { it.alpha = if (locked) 0.5f else 1f }
    }

    private fun buildExportPanel(): View {
        val scroll = ScrollView(this)
        exportPanel = GyroflowExportPanel(
            this,
            { exportSizePresets() },
            { w, h -> applyExportPreviewAspect(w, h) },
            { startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQ_PICK_EXPORT_DIR) },
            { resolveExportFileNameConflict() },
        ) { onExportTapped() }
        scroll.addView(exportPanel.root)
        return lockableWrap(scroll)
    }

    // 导出输出尺寸变化 → 同步预览: ① native 按官方语义(W×H 当比例缩到源内)重渲 ② 预览框按比例改高。
    // 同比例不同分辨率(8K / 1080p)会得到同一 output_size → 画面框选一致(对齐官方)。
    private fun applyExportPreviewAspect(w: Int, h: Int) {
        if (videoW <= 0 || videoH <= 0 || w <= 0 || h <= 0) return
        resizePreview(w, h)
        applyStab { GyroflowNative.nativeSetOutputSize(w, h) }
    }

    // ⚙ 输出尺寸预设(对齐官方比例组 16:9/17:9/9:16/4:3/1:1)。每组: 原始/比例/Based on Max zoom + 固定档。
    private fun exportSizePresets(): List<Pair<String, List<Triple<String, Int, Int>>>> {
        if (videoW <= 0 || videoH <= 0) return emptyList()
        // 最大缩放因子 = 1/min_fov。nativeGetStabInfo()[3] = min_fov*100, 故 z = 100/[3]。
        val info3 = GyroflowNative.nativeGetStabInfo()?.getOrNull(3) ?: 0.0
        val z = if (info3 > 1.0) 100.0 / info3 else 1.0
        fun group(name: String, wp: Int, hp: Int, fixed: List<Triple<String, Int, Int>>): Pair<String, List<Triple<String, Int, Int>>> {
            // 比例换算结果取偶(向下), 避免预设自己引入「必须可被 2 整除」报错
            val rh = ((videoW.toLong() * hp / wp).toInt() / 2) * 2
            val mw = ((videoW / z).toInt() / 2) * 2
            val mh = ((mw.toLong() * hp / wp).toInt() / 2) * 2
            val dyn = listOf(
                Triple("原始 ($videoW x $videoH)", videoW, videoH),
                Triple("比例 ($videoW x $rh)", videoW, rh),
                Triple("Based on \"Max zoom\" ($mw x $mh)", mw, mh),
            )
            return name to (dyn + fixed)
        }
        return listOf(
            group("16:9", 16, 9, listOf(Triple("8k (7680 x 4320)", 7680, 4320), Triple("6k (6016 x 3384)", 6016, 3384), Triple("4k (3840 x 2160)", 3840, 2160), Triple("1080p (1920 x 1080)", 1920, 1080), Triple("720p (1280 x 720)", 1280, 720))),
            group("17:9", 17, 9, listOf(Triple("4k (4096 x 2160)", 4096, 2160), Triple("2k (2048 x 1080)", 2048, 1080))),
            group("9:16", 9, 16, listOf(Triple("8k (4320 x 7680)", 4320, 7680), Triple("6k (3384 x 6016)", 3384, 6016), Triple("4k (2160 x 3840)", 2160, 3840), Triple("1080p (1080 x 1920)", 1080, 1920), Triple("720p (720 x 1280)", 720, 1280))),
            group("4:3", 4, 3, listOf(Triple("480p (640 x 480)", 640, 480))),
            group("1:1", 1, 1, listOf(Triple("4k (2160 x 2160)", 2160, 2160), Triple("1080p (1080 x 1080)", 1080, 1080))),
        )
    }

    private fun onExportTapped() {
        val uri = pendingUri
        if (uri == null) { exportPanel.setStatus("请先选择视频"); return }
        if (videoW <= 0 || videoH <= 0) { exportPanel.setStatus("视频未就绪"); return }
        // 对齐官方: 受系统文件访问限制, 必须先手动授权目标文件夹才能导出。
        // 未授权 → 弹提示(IMG_1471) → 确定 → 打开文件夹选择器 → 授权后在
        // onActivityResult 的 REQ_PICK_EXPORT_DIR 分支续导出; 取消则中止(不回落相册)。
        if (exportDirUri == null) {
            pendingExportUri = uri
            gyroInfoModal(
                "由于文件访问限制，您需要手动选择目标文件夹。\n单击确定并选择目标文件夹。",
                "dontShowAgain_exportFolderHint",
                onConfirm = { startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQ_PICK_EXPORT_DIR) },
            )
            return
        }
        startExport(uri)
    }

    /**
     * 导出开始时的前台提示(对齐官方 App.qml:374-378, 移动端专属): 非阻塞 ——
     * 弹框悬浮在导出蒙版之上, 渲染照常进行; 勾选「不再显示」后持久化不再弹
     * (对齐官方 settings "dontShowAgain-keep-in-foreground")。
     */
    private fun maybeShowKeepForegroundHint() {
        gyroInfoModal("将此 APP 保持在前台运行并不要锁定屏幕。\n受限于系统视频编码器，不支持后台渲染。", "dontShowAgain_keepInForeground")
    }

    /**
     * 文件名查重(输入框提交/默认名设置/换导出目录后调用): 目标位置(所选目录或相册)
     * 已有同名 → 自增 _X 回写输入框; 无同名保持原名(与导出落盘共用 uniqueExportName)。
     */
    private fun resolveExportFileNameConflict() {
        val name = exportPanel.currentSettings().fileName
        if (name.isEmpty()) return
        Thread {
            val unique = GyroflowExporter.uniqueExportName(this, name, exportDirUri?.toString())
            if (unique != name) {
                runOnUiThread { exportPanel.setDefaultFileName(unique) }
            }
        }.start()
    }

    private fun startExport(uri: Uri) {
        val raw = exportPanel.currentSettings()
        // 输出尺寸: 0(原始)→ 源宽 × 16:9(对齐 iOS officialStabilizedHeightForWidth)
        var ow = raw.outW
        var oh = raw.outH
        if (ow <= 0 || oh <= 0) { ow = videoW; oh = (videoW * 9 / 16 / 2) * 2 }
        val s = raw.copy(outW = ow, outH = oh, exportDirUri = exportDirUri?.toString())

        decoder?.pause()
        updatePlayButton()
        exportPanel.setExporting(true)
        exportPanel.setStatus("导出中…")
        showExportOverlay()
        maybeShowKeepForegroundHint()
        val ex = GyroflowExporter(this, uri)
        exporter = ex
        ex.run(
            s,
            onProgress = { p -> runOnUiThread { exportPanel.setProgress(p.percent); updateExportOverlay(p) } },
            onDone = { _, err ->
                runOnUiThread {
                    hideExportOverlay()
                    exportPanel.setExporting(false)
                    exporter = null
                    applyExportPreviewAspect(s.outW, s.outH) // 恢复预览输出为所选比例 + 重渲
                    val dest = exportDirUri?.lastPathSegment?.substringAfterLast(':')?.let { "目录($it)" }
                        ?: "相册(Movies/Gyroflow)"
                    exportPanel.setStatus(if (err == null) "已保存到$dest" else "导出失败: $err")
                    if (err == null) {
                        // 导出成功弹框(对齐官方 RenderQueue.qml:156-170 Modal.Success / 截图 IMG_1462,
                        // 移动端官方仅「确定」按钮、无打开文件入口)
                        gyroInfoModal("渲染完成。文件已写入: $dest。", null, success = true)
                    }
                }
            },
        )
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_EXPORT_PERM) {
            if (grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED) {
                pendingUri?.let { startExport(it) }
            } else {
                exportPanel.setStatus("未授予存储权限, 无法保存到相册")
            }
        }
    }

    // 「参数」页(对齐 iOS: 同步 / 稳定)
    private fun buildParamsPanel(): View {
        val scroll = ScrollView(this)
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(16), dp(16), dp(16))
        }

        // ① 同步(自动同步, 对齐官方 Synchronization)
        syncPanel = GyroflowSyncPanel(this) { start -> onAutosyncToggle(start) }
        panel.addView(syncPanel.root)

        // ② 稳定(对齐官方 Stabilization)
        stabPanel = GyroflowStabilizePanel(this) { action -> applyStab(action) }
        panel.addView(stabPanel.root)

        // ③ 高级(对齐官方 Advanced): 与同步/稳定同级的独立模块, 不折叠
        advancedPanel = GyroflowAdvancedPanel(this) { action -> applyStab(action) }
        panel.addView(advancedPanel.root)

        scroll.addView(panel)
        return lockableWrap(scroll)
    }

    // 稳定参数变更: native setter(含 recompute, 重) 跑后台线程, 完成后重渲当前帧 + 刷新信息。
    private fun applyStab(action: () -> Unit) {
        Thread {
            action()
            runOnUiThread {
                decoder?.seekTo(lastProgress)
                stabPanel.refreshInfo()
            }
        }.start()
    }

    // 自动同步开关(对齐 iOS onAutosyncTapped): 启动 GyroflowAutosync / 取消。
    private fun onAutosyncToggle(start: Boolean) {
        if (!start) {
            autosync?.cancel()
            return
        }
        val uri = pendingUri
        if (uri == null) {
            statusLabel.text = "请先选择视频"
            syncPanel.setRunning(false)
            return
        }
        decoder?.pause()
        updatePlayButton()
        val runner = GyroflowAutosync(this, uri)
        autosync = runner
        syncPanel.setRunning(true)
        showAutosyncOverlay()
        statusLabel.text = "自动同步中…"
        runner.run(
            syncPanel.currentParams(),
            syncPanel.currentProcHeight(),
            onProgress = { pr -> runOnUiThread { syncPanel.setProgress(pr.percent); updateAutosyncOverlay(pr) } },
            onDone = { median, points, err ->
                runOnUiThread {
                    syncPanel.setRunning(false)
                    autosync = null
                    if (err != null) {
                        hideAutosyncOverlay()
                        statusLabel.text = "同步: $err"
                    } else {
                        completeAutosyncOverlay()  // 显示 100% 片刻再隐藏
                        syncPanel.setResult(median, points)
                        syncPanel.setHasSyncPoints(points.isNotEmpty()) // 有同步点 → usesQuats 时才弹提示(对齐官方)
                        gyroTimeline.setSyncPoints(points) // 时间轴上画同步点竖线 + 偏移数值
                        statusLabel.text = "同步完成: 偏移 ${median?.let { String.format("%.1f", it) } ?: "?"} ms"
                        syncPanel.applyShowFlags() // 应用「显示特征/光流」默认勾选(对齐官方), 再重渲
                        decoder?.seekTo(lastProgress) // 立即重渲当前帧, 看到同步后效果(对齐官方)
                    }
                }
            },
        )
    }

    // 「输入」Tab(对齐 iOS InputTabView): 视频信息 / 镜头配置文件 / 运动数据
    private fun buildInputPanel(): View {
        val scroll = ScrollView(this)
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(8), dp(16), dp(16))
        }

        // ① 视频信息
        col.addView(sectionTitle("视频信息"))
        col.addView(fullButton("打开文件") { pickVideo() })
        // 蓝色目录授权提示框 —— 对齐官方 VideoInformation.qml:164-178 InfoMessageSmall(Info=蓝):
        // 视频载入后无运动数据/镜头信息时显示, 点击授权目录后自动扫描同名文件。
        videoDirHintLabel = TextView(this).apply {
            text = "为了自动检测运动数据和镜头文件,请点击此处并授权视频所在目录"
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 12f
            gravity = Gravity.CENTER
            setPadding(dp(10), dp(8), dp(10), dp(8))
            background = GradientDrawable().apply {
                setColor(0xFF1976D2.toInt())
                cornerRadius = dp(6).toFloat()
            }
            visibility = View.GONE
            setOnClickListener { startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQ_GRANT_GYRO_DIR) }
        }
        col.addView(videoDirHintLabel, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) })
        listOf(
            "文件名称" to "name", "检测到的相机" to "cam", "检测镜头" to "lens",
            "尺寸" to "size", "时长" to "duration", "帧速率" to "fps", "包含陀螺仪数据" to "gyro",
        ).forEach { col.addView(infoRow(it.first, it.second)) }
        // 额外元数据(比特率/音频/旋转/拍摄日期 + Sony 等 recording_settings: ISO/快门/白平衡…), 仅显示存在的字段
        extraInfoBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        col.addView(extraInfoBox)

        // ② 镜头配置文件(搜索内置库 + 结果列表 + 打开文件)
        col.addView(sectionTitle("镜头配置文件"))
        val searchField = EditText(this).apply {
            hint = "搜索..."
            setTextColor(GyroflowTheme.TEXT)
            setHintTextColor(GyroflowTheme.TEXT_HINT)
            textSize = 14f
            isSingleLine = true
            imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_DONE // 键盘右下角「完成」
            setPadding(dp(12), dp(10), dp(12), dp(10))
            background = GradientDrawable().apply {
                setColor(GyroflowTheme.INPUT_BG) // 对齐 iOS 深色输入框
                cornerRadius = dp(8).toFloat()
            }
            finishInputOnDone() // 按「完成」: 收键盘 + 清焦点(边打边搜, 无需额外提交)
        }
        col.addView(searchField, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) })
        lensResults = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        col.addView(lensResults)
        col.addView(fullButton("打开文件") { pickFile(REQ_PICK_LENS, "*/*") })
        lensStatusLabel = subLabel("未加载镜头档案")
        col.addView(lensStatusLabel)
        lensDetail = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        col.addView(lensDetail)
        // 高级(居中蓝色链接, 可展开): 水下镜头 + 相机矩阵 + 畸变系数(对齐 iOS)
        lensAdvancedHeader = TextView(this).apply {
            text = "高级"
            setTextColor(GyroflowTheme.ACCENT) // 主题色
            textSize = 13f
            gravity = Gravity.CENTER
            setPadding(0, dp(10), 0, dp(6))
            visibility = View.GONE
            setOnClickListener { toggleLensAdvanced() }
        }
        col.addView(lensAdvancedHeader, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        lensAdvanced = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
        }
        col.addView(lensAdvanced)
        searchField.addTextChangedListener(object : TextWatcher {
            override fun afterTextChanged(s: Editable?) { searchLens(s?.toString() ?: "") }
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
        })

        // ③ 运动数据(独立模块, 对齐 iOS MotionData)
        motionPanel = GyroflowMotionPanel(
            this,
            { pickFile(REQ_PICK_GYRO, "*/*") },
            { refreshUsesQuats() },
            { allMetadata -> lastGyroUri?.let { loadGyroFile(it, allMetadata) } }, // 「加载全部元数据」切换 → 重载外挂文件
            { startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQ_GRANT_GYRO_DIR) } // 「授权视频所在目录」
        )
        col.addView(motionPanel.root)

        scroll.addView(col)
        return scroll
    }

    private fun updateVideoInfo(openRes: String) {
        fun grp(re: String) = Regex(re).find(openRes)?.groupValues?.getOrNull(1)
        grp("""opened (\d+x\d+)""")?.let { infoLabels["size"]?.text = it }
        val fps = grp("""fps=([\d.]+)""")
        fps?.let { infoLabels["fps"]?.text = it }
        val frames = grp("""frames=(\d+)""")?.toIntOrNull()
        if (frames != null) videoFrameCount = frames.toLong()
        val fpsD = fps?.toDoubleOrNull()
        if (fpsD != null && fpsD > 0) videoFps = fpsD
        if (frames != null && fpsD != null && fpsD > 0) {
            infoLabels["duration"]?.text = String.format("%.1f s", frames / fpsD)
            val durMs = frames / fpsD * 1000.0
            videoDurationUs = (durMs * 1000.0).toLong()
            gyroTimeline.setVideoDurationMs(durMs)
        }
        // 陀螺时间轴波形(无原始角速度时回退四元数; 都没有则显示占位提示)
        loadTimelineWaveformAsync()
        grp("""gyro=(true|false)""")?.let {
            val on = it == "true"
            infoLabels["gyro"]?.text = if (on) "是" else "否"
            if (on) {
                // 内嵌陀螺: 运动数据文件即视频本身
                motionPanel.setFileName(infoLabels["name"]?.text?.toString() ?: "---")
                motionPanel.refresh()
            } else {
                motionPanel.showEmpty("未加载, 可手动打开运动数据文件")
            }
            // 无运动数据且视频是 content:// 单文件(无法列父目录) → 提示授权目录以自动查同名陀螺文件
            motionPanel.setAuthorizeDirVisible(!on && pendingUri?.scheme == "content")
            motionFromVideo = on        // 内嵌陀螺 = 来自视频本身(对齐官方 filename 匹配)
            refreshUsesQuats()
        }
        motionPanel.setOpenFileEnabled(true)  // 视频已载入 → 允许打开外挂运动数据(对齐官方: 无视频拒绝加载)
        grp("""lens=(true|false)""")?.let {
            val on = it == "true"
            if (on) {
                showLensWarning(false)
                showLensInfo()
            } else {
                infoLabels["lens"]?.text = "未匹配"
                lensStatusLabel.text = "未匹配, 可手动打开镜头文件"
                showLensWarning(true) // 未加载镜头档案 → 预览缩放框下方黄色警告
            }
        }
        // 蓝色目录授权提示框(视频信息·打开文件下方, 对齐官方 VideoInformation.qml:164-178):
        // 无运动数据或无镜头时显示, 点击授权目录后自动扫描同名文件。
        val gyroOn = grp("""gyro=(true|false)""") == "true"
        val lensOn = grp("""lens=(true|false)""") == "true"
        videoDirHintLabel.visibility = if (!gyroOn || !lensOn) View.VISIBLE else View.GONE
        // 授权目录扫描记下的同名镜头 json: 重载后(core 的 lensprofile 自动配)仍无镜头则兜底加载
        val scanLens = pendingScanLensUri
        if (!lensOn && scanLens != null) {
            pendingScanLensUri = null
            Thread {
                val lr = GyroflowNative.nativeLoadLens(scanLens.toString())
                if (lr?.startsWith("lens ok") == true) {
                    runOnUiThread {
                        showLensInfo()   // 内部隐藏黄警告并填镜头明细
                        videoDirHintLabel.visibility = if (gyroOn) View.GONE else View.VISIBLE
                    }
                }
            }.start()
        }
        pendingUri?.let { populateExtraVideoInfo(it) } // 额外元数据(相机设置 + 容器信息), 存在才显示
    }

    // 显示官方「视频信息」里那些额外字段(存在才显示, 不存在不展示):
    //   ① 容器信息: 比特率/音频/旋转/拍摄日期(Android MediaExtractor/Retriever)
    //   ② 相机录制参数: recording_settings(ISO/快门/曝光/白平衡/光圈/焦距/对焦方式…, 来自核心 telemetry)
    private fun populateExtraVideoInfo(uri: Uri) {
        Thread {
            val rows = ArrayList<Pair<String, String>>()
            // ① 容器信息 —— 编码 + 比特率, 音频
            try {
                val ext = android.media.MediaExtractor()
                ext.setDataSource(this, uri, null)
                var vMime = ""; var aMime = ""; var aRate = 0
                for (i in 0 until ext.trackCount) {
                    val f = ext.getTrackFormat(i)
                    val mime = f.getString(android.media.MediaFormat.KEY_MIME) ?: ""
                    if (mime.startsWith("video/") && vMime.isEmpty()) vMime = mime
                    if (mime.startsWith("audio/") && aMime.isEmpty()) {
                        aMime = mime
                        if (f.containsKey(android.media.MediaFormat.KEY_SAMPLE_RATE)) aRate = f.getInteger(android.media.MediaFormat.KEY_SAMPLE_RATE)
                    }
                }
                ext.release()
                var bitrateMbps = ""
                val r = android.media.MediaMetadataRetriever()
                r.setDataSource(this, uri)
                r.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toLongOrNull()?.let {
                    if (it > 0) bitrateMbps = String.format("%.2f Mbps", it / 1_000_000.0)
                }
                val codec = codecName(vMime)
                if (codec.isNotEmpty() || bitrateMbps.isNotEmpty()) {
                    rows.add("比特率" to listOf(codec, bitrateMbps).filter { it.isNotEmpty() }.joinToString(" "))
                }
                if (aMime.isNotEmpty()) {
                    val a = codecName(aMime) + (if (aRate > 0) " $aRate Hz" else "")
                    rows.add("音频" to a.trim())
                }
                r.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull()?.let {
                    rows.add("旋转" to "$it °")
                }
                r.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DATE)?.let {
                    if (it.isNotBlank()) rows.add("拍摄日期" to it)
                }
                r.release()
            } catch (_: Throwable) {}

            // ② 相机录制参数(recording_settings) + 检测相机
            val mo = try {
                org.json.JSONObject(GyroflowNative.nativeGetVideoMetadata() ?: "{}")
            } catch (_: Throwable) {
                org.json.JSONObject()
            }
            val camera = mo.optString("camera").trim()
            val rec = mo.optJSONObject("additional_data")?.optJSONObject("recording_settings")
            val recRows = ArrayList<Pair<String, String>>()
            if (rec != null) {
                // 标签映射(对齐官方 VideoInformation.qml 的键), 顺序固定; 其余未知键按原名兜底显示
                val labels = linkedMapOf(
                    "Focal length" to "焦距", "Focus mode" to "对焦方式",
                    "Iris" to "光圈", "ISO" to "ISO",
                    "Shutter angle" to "快门角度", "Shutter speed" to "快门速度",
                    "Exposure" to "曝光", "White balance mode" to "白平衡模式",
                    "White balance" to "白平衡", "Color primaries" to "色彩原色",
                    "Gamma equation" to "Gamma 曲线",
                )
                for ((k, label) in labels) {
                    val v = rec.optString(k).trim()
                    if (rec.has(k) && v.isNotEmpty()) recRows.add(label to v)
                }
                val keys = rec.keys()
                while (keys.hasNext()) {
                    val k = keys.next()
                    if (!labels.containsKey(k)) {
                        val v = rec.optString(k).trim()
                        if (v.isNotEmpty()) recRows.add(k to v)
                    }
                }
            }

            runOnUiThread {
                if (camera.isNotEmpty()) infoLabels["cam"]?.text = camera
                extraInfoBox.removeAllViews()
                (rows + recRows).forEach { extraInfoBox.addView(staticInfoRow(it.first, it.second)) }
            }
        }.start()
    }

    private fun codecName(mime: String): String = when (mime) {
        "video/avc" -> "H264"
        "video/hevc" -> "H265"
        "video/x-vnd.on2.vp9" -> "VP9"
        "video/av01" -> "AV1"
        "video/mp4v-es" -> "MPEG4"
        "audio/mp4a-latm" -> "AAC"
        "audio/raw" -> "PCM"
        "audio/ac3" -> "AC3"
        "audio/opus" -> "Opus"
        "audio/vorbis" -> "Vorbis"
        else -> mime.substringAfter('/').uppercase()
    }

    // 静态信息行(标签右对齐 + 粗体值), 用于额外元数据(不进 infoLabels)。
    private fun staticInfoRow(label: String, value: String): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(3), 0, dp(3))
        }
        row.addView(TextView(this).apply {
            text = "$label:"
            setTextColor(GyroflowTheme.TEXT_SECONDARY)
            textSize = 13f
            gravity = Gravity.END
            setPadding(0, 0, dp(8), 0)
            layoutParams = LinearLayout.LayoutParams(dp(120), LinearLayout.LayoutParams.WRAP_CONTENT)
        })
        row.addView(TextView(this).apply {
            text = value
            setTextColor(GyroflowTheme.TEXT)
            textSize = 13f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        return row
    }

    /** 预览缩放框下方的黄色镜头警告显隐(未加载/未匹配镜头档案时显示, 对齐官方)。 */
    private fun showLensWarning(show: Boolean) {
        lensWarningLabel.visibility = if (show) View.VISIBLE else View.GONE
    }

    /** 刷新预览下方陀螺时间轴波形(手动加载运动数据后重画, 与内嵌陀螺一致)。 */
    private fun refreshGyroTimeline() {
        loadTimelineWaveformAsync()
    }

    /**
     * 异步加载陀螺时间轴波形: 先取原始角速度(3 轴); 取不到(DJI/Xtra 等只输出融合姿态、
     * 无原始角速度的源)则回退取四元数(4 分量 x,y,z,w)——对齐官方 Quaternions 视图。
     */
    private fun loadTimelineWaveformAsync() {
        Thread {
            val g = GyroflowNative.nativeGyroTimeline(600)
            if (g != null && g.size >= 6) {
                runOnUiThread { gyroTimeline.setData(g, 3) }
            } else {
                val q = GyroflowNative.nativeQuaternionTimeline(600)
                runOnUiThread { gyroTimeline.setData(q, 4) }
            }
        }.start()
    }

    // 读取已加载镜头信息并渲染(基础表 + 高级), 字段顺序对齐 iOS LensProfile.qml。
    private fun showLensInfo() {
        Thread {
            val json = GyroflowNative.nativeGetLensInfo() ?: "{}"
            val o = try {
                org.json.JSONObject(json)
            } catch (_: Throwable) {
                org.json.JSONObject()
            }
            // 镜头档案带 sync_settings → 覆盖同步面板(对齐官方按镜头检测)
            val syncJson = GyroflowNative.nativeGetSyncSettings()
            runOnUiThread {
                renderLensInfo(o)
                syncPanel.applySyncSettings(syncJson)
            }
        }.start()
    }

    private fun renderLensInfo(o: org.json.JSONObject) {
        lensDetail.removeAllViews()
        lensAdvanced.removeAllViews()
        showLensWarning(false) // 已加载/匹配镜头 → 隐藏预览黄色警告
        val hasLens = o.optBoolean("has_lens", false)
        if (!hasLens) {
            infoLabels["lens"]?.text = "已匹配"
            lensStatusLabel.text = "已匹配镜头档案(随视频自动)"
            lensAdvancedHeader.visibility = View.GONE
            lensAdvanced.visibility = View.GONE
            return
        }
        val camera = o.optString("camera").trim()
        infoLabels["lens"]?.text = camera
        lensStatusLabel.text = "已匹配: $camera"

        // —— 基础表(前 6 项始终显示, 对齐 iOS TableList) ——
        lensDetailRow(lensDetail, "相机", camera, true)
        lensDetailRow(lensDetail, "镜头", o.optString("lens").trim(), true)
        lensDetailRow(lensDetail, "设置", o.optString("camera_setting").trim(), true)
        lensDetailRow(lensDetail, "其他信息", o.optString("note").trim(), true)
        val cd = o.optJSONObject("calib_dimension")
        val sizeStr = if (cd != null && cd.optInt("w") > 0) "${cd.optInt("w")}x${cd.optInt("h")}" else ""
        lensDetailRow(lensDetail, "尺寸", sizeStr, true)
        lensDetailRow(lensDetail, "校准人", o.optString("calibrated_by").trim(), true)
        // —— 条件项(有值才显示, 对齐 iOS) ——
        val focal = o.optDouble("focal_length", 0.0)
        if (focal > 0) {
            lensDetailRow(lensDetail, "焦距", String.format("%.2f mm", focal), false)
        }
        val crop = o.optDouble("crop_factor", 0.0)
        if (crop > 0) {
            lensDetailRow(lensDetail, "裁切系数", String.format("%.2fx", crop), false)
        }
        if (o.optBoolean("asymmetrical", false)) {
            lensDetailRow(lensDetail, "非对称", "是", false)
        }
//        val dm = o.optString("distortion_model").trim()
//        if (dm.isNotEmpty() && dm != "opencv_fisheye") {
//            lensDetailRow(lensDetail, "畸变模型", dm, false)
//        }
//        val digital = o.optString("digital_lens").trim()
//        if (digital.isNotEmpty()) {
//            lensDetailRow(lensDetail, "数码镜头", digital, false)
//        }

        // —— 高级(对齐 iOS AdvancedSection): 水下镜头 + 像素焦距 + 聚焦中心 + 畸变系数 ——
        val refr = o.optDouble("light_refraction_coefficient", 1.0)
        lensAdvanced.addView(gyroCheckBox("水下镜头", Math.round(refr * 1000) == 1330L) { on -> setUnderwater(on) })
        val fx = o.optDouble("fx", Double.NaN)
        if (!fx.isNaN()) {
            val fy = o.optDouble("fy", 0.0)
            val cx = o.optDouble("cx", 0.0)
            val cy = o.optDouble("cy", 0.0)
            // 像素焦距 fx, fy / 聚焦中心 cx, cy: 可编辑, precision 12(对齐 iOS SmallNumberField)
            lensAdvanced.addView(advLabel("像素焦距"))
            paramRow(numField(fmtNum(fx), "fx", 12), numField(fmtNum(fy), "fy", 12))
            lensAdvanced.addView(advLabel("聚焦中心"))
            paramRow(numField(fmtNum(cx), "cx", 12), numField(fmtNum(cy), "cy", 12))
        }
        val coeffs = o.optJSONArray("distortion_coeffs")
        if (coeffs != null && coeffs.length() > 0) {
            fun coef(i: Int): String {
                val v = coeffs.opt(i)
                return if (v != null && v != org.json.JSONObject.NULL) fmtNum((v as Number).toDouble()) else "0"
            }
            // 畸变系数 k1..k4: 可编辑, precision 16(对齐 iOS)
            lensAdvanced.addView(advLabel("畸变系数"))
            paramRow(numField(coef(0), "k1", 16), numField(coef(1), "k2", 16))
            paramRow(numField(coef(2), "k3", 16), numField(coef(3), "k4", 16))
        }

        lensAdvancedHeader.visibility = View.VISIBLE
        lensAdvanced.visibility = if (lensAdvancedExpanded) View.VISIBLE else View.GONE
    }

    private fun setUnderwater(on: Boolean) {
        Thread { GyroflowNative.nativeSetUnderwater(on) }.start()
    }

    // 提交相机矩阵/畸变系数编辑(对齐 iOS controller.set_lens_param)。
    private fun commitLensParam(param: String, text: String) {
        val v = text.trim().toDoubleOrNull() ?: return
        Thread { GyroflowNative.nativeSetLensParam(param, v) }.start()
    }

    private fun toggleLensAdvanced() {
        lensAdvancedExpanded = !lensAdvancedExpanded
        lensAdvanced.visibility = if (lensAdvancedExpanded) View.VISIBLE else View.GONE
    }

    // 全精度数值字符串(对齐 iOS 显示原始标定值, 不四舍五入)。
    private fun fmtNum(d: Double): String =
        if (d == Math.floor(d) && !d.isInfinite()) d.toLong().toString() else d.toString()

    // 高级区小标题(独占一行, 对齐 iOS Label)。
    private fun advLabel(text: String): TextView = TextView(this).apply {
        this.text = text
        setTextColor(GyroflowTheme.TEXT_MUTED)
        textSize = 12f
        setPadding(0, dp(8), 0, dp(4))
    }

    // 镜头参数数值框(复用 [gyroNumberField], 提交到 set_lens_param)。
    private fun numField(value: String, param: String, precision: Int): EditText =
        gyroNumberField(value, precision) { text -> commitLensParam(param, text) }

    // 一行并排的数值框(每个等宽, 对齐 iOS Row)。
    private fun paramRow(vararg boxes: EditText) {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 0, 0, dp(4))
        }
        boxes.forEachIndexed { i, b ->
            row.addView(b, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                if (i > 0) marginStart = dp(6)
            })
        }
        lensAdvanced.addView(row)
    }

    // 镜头明细行: 右对齐标签(带冒号) + 粗体值。always=true 时空值也显示(对齐 iOS TableList)。
    private fun lensDetailRow(parent: LinearLayout, label: String, value: String, always: Boolean) {
        if (value.isEmpty() && !always) {
            return
        }
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(3), 0, dp(3))
        }
        row.addView(TextView(this).apply {
            text = "$label:"
            setTextColor(GyroflowTheme.TEXT_SECONDARY)
            textSize = 13f
            gravity = Gravity.END
            setPadding(0, 0, dp(8), 0)
            layoutParams = LinearLayout.LayoutParams(dp(82), LinearLayout.LayoutParams.WRAP_CONTENT)
        })
        row.addView(TextView(this).apply {
            text = value
            setTextColor(GyroflowTheme.TEXT)
            textSize = 13f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        parent.addView(row)
    }

    private fun sectionTitle(t: String): TextView = TextView(this).apply {
        text = t
        setTextColor(GyroflowTheme.TEXT)
        textSize = 15f
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        setPadding(0, dp(14), 0, dp(8))
    }

    private fun subLabel(t: String): TextView = TextView(this).apply {
        text = t
        setTextColor(GyroflowTheme.TEXT_SECONDARY)
        textSize = 13f
        setPadding(0, dp(6), 0, 0)
    }

    // 搜索内置镜头库(后台线程)→ 填充可点击结果行。
    private fun searchLens(query: String) {
        val q = query.trim()
        if (q.length < 2) {
            lensResults.removeAllViews()
            return
        }
        Thread {
            val json = GyroflowNative.nativeLensSearch(q) ?: "[]"
            val arr = try {
                org.json.JSONArray(json)
            } catch (_: Throwable) {
                org.json.JSONArray()
            }
            runOnUiThread {
                lensResults.removeAllViews()
                val n = minOf(arr.length(), 30)
                for (i in 0 until n) {
                    val o = arr.optJSONObject(i) ?: continue
                    val name = o.optString("name")
                    val id = o.optString("id")
                    lensResults.addView(TextView(this).apply {
                        text = name
                        setTextColor(GyroflowTheme.TEXT_RESULT)
                        textSize = 13f
                        setPadding(dp(8), dp(8), dp(8), dp(8))
                        setOnClickListener { loadLensById(id, name) }
                    })
                }
            }
        }.start()
    }

    // 按 id 加载内置镜头档案(后台线程)→ 更新状态与视频信息。
    private fun loadLensById(id: String, name: String) {
        lensStatusLabel.text = "镜头加载中…"
        Thread {
            val r = GyroflowNative.nativeLoadLens(id)
            runOnUiThread {
                val ok = r?.startsWith("lens ok") == true
                if (ok) {
                    lensResults.removeAllViews()
                    showLensInfo()
                } else {
                    lensStatusLabel.text = r ?: "加载失败"
                }
            }
        }.start()
    }

    private fun infoRow(label: String, key: String): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(3), 0, dp(3))
        }
        row.addView(TextView(this).apply {
            text = "$label:"
            setTextColor(GyroflowTheme.TEXT_SECONDARY)
            textSize = 13f
            gravity = Gravity.END
            setPadding(0, 0, dp(8), 0)
            layoutParams = LinearLayout.LayoutParams(dp(120), LinearLayout.LayoutParams.WRAP_CONTENT)
        })
        val v = TextView(this).apply {
            text = "---"
            setTextColor(GyroflowTheme.TEXT)
            textSize = 13f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        infoLabels[key] = v
        row.addView(v)
        return row
    }

    private fun fullButton(label: String, onClick: () -> Unit): TextView =
        gyroPrimaryButton(label, onClick).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) }
        }

    private fun placeholderPanel(text: String): View = TextView(this).apply {
        setText(text)
        setTextColor(GyroflowTheme.TEXT_TERTIARY)
        textSize = 13f
        gravity = Gravity.CENTER
    }

    private fun selectTab(index: Int) {
        currentTab = index
        panelContainer.removeAllViews()
        tabPanels[index]?.let {
            panelContainer.addView(it, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        }
        // 对齐 iOS Material Tabs: 文字/图标均为白色, 未选中整体变暗, 仅选中段主题色下划线。
        for (i in 0 until 3) {
            val on = i == index
            tabLabels[i]?.setTextColor(GyroflowTheme.TEXT)
            tabLabels[i]?.alpha = if (on) 1f else 0.5f
            tabIcons[i]?.setColorFilter(GyroflowTheme.TEXT)
            tabIcons[i]?.alpha = if (on) 1f else 0.5f
            tabIndicators[i]?.setBackgroundColor(if (on) GyroflowTheme.ACCENT else Color.TRANSPARENT)
        }
    }

    // 系统文件选择器(对齐 iOS UIDocumentPicker)。
    private fun pickVideo() = pickFile(REQ_PICK_VIDEO, "video/*")

    private fun pickFile(reqCode: Int, mime: String) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            type = mime
            addCategory(Intent.CATEGORY_OPENABLE)
        }
        startActivityForResult(intent, reqCode)
    }

    private fun queryName(uri: Uri): String = try {
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
        } ?: uri.lastPathSegment ?: "video"
    } catch (_: Throwable) {
        uri.lastPathSegment ?: "video"
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode != RESULT_OK) {
            // 取消文件夹授权 → 中止待导出(对齐官方: 必须授权才能导出, 不回落相册)
            if (requestCode == REQ_PICK_EXPORT_DIR && pendingExportUri != null) {
                pendingExportUri = null
                exportPanel.setStatus("已取消导出：需要先选择目标文件夹才能导出。")
            }
            return
        }
        val uri = data?.data ?: return
        try {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: Throwable) {}
        when (requestCode) {
            REQ_PICK_VIDEO -> {
                pendingScanLensUri = null   // 新视频: 不带入上一个视频扫描到的镜头
                resetExportSize = true      // 新视频: 输出大小按新视频信息重置(对齐官方每次加载重置)
                openVideoFile(uri)
            }
            REQ_GRANT_GYRO_DIR -> {
                // 注册授权目录到 gyroflow 白名单(对齐官方 MotionData.qml:163-177),
                // 然后扫描目录及子目录找当前视频的同名运动数据/镜头文件并加载。
                Thread {
                    GyroflowNative.nativeFolderAccessGranted(uri.toString())
                    scanGrantedTree(uri)
                }.start()
            }
            REQ_PICK_LENS -> {
                lensStatusLabel.text = "镜头加载中…"
                Thread {
                    val r = GyroflowNative.nativeLoadLens(uri.toString())
                    runOnUiThread {
                        if (r?.startsWith("lens ok") == true) {
                            lensStatusLabel.text = "已加载: ${queryName(uri)}"
                            lensResults.removeAllViews()
                            showLensInfo() // 解析镜头文件并渲染明细表 + 高级参数(对齐搜索库加载)
                        } else {
                            lensStatusLabel.text = r ?: ""
                        }
                    }
                }.start()
            }
            REQ_PICK_GYRO -> {
                lastGyroUri = uri
                loadGyroFile(uri, motionPanel.loadAllMetadataChecked())
            }
            REQ_PICK_EXPORT_DIR -> {
                // 导出存储目录(对齐官方 OutputPathField 目录选择): 持久化, 重启后恢复。
                // 顶部通用 take 只拿了读权限, 写文件还需写权限。
                try {
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                    )
                } catch (_: Throwable) {}
                exportDirUri = uri
                getSharedPreferences("gyroflow", MODE_PRIVATE).edit().putString("export_dir_uri", uri.toString()).apply()
                exportPanel.setStatus("导出将保存到: ${uri.lastPathSegment ?: uri}")
                exportPanel.setExportDir(exportDirDisplay(uri))   // 「输出路径:」同行更新目录(末两级路径)
                resolveExportFileNameConflict()   // 换目录后按新目录重新查重当前文件名
                // 若这次授权是导出前强制触发的 → 授权成功后接着导出
                val pend = pendingExportUri
                if (pend != null) {
                    pendingExportUri = null
                    startExport(pend)
                }
            }
        }
    }

    /** 打开/重载视频(初次选择与「授权目录后重载」共用): 停旧解码器、复位状态、起播。 */
    private fun openVideoFile(uri: Uri) {
        // 切换视频: 先停旧解码器并复位状态, 否则 started 守卫会让 maybeStart() 直接返回,
        // 预览继续渲染旧视频(对齐"重新选片即重载")。
        decoder?.stop()
        decoder = null
        started = false
        lastProgress = 0.0
        hudLabel.visibility = View.GONE
        gyroTimeline.setProgress(0.0)
        gyroTimeline.setSyncPoints(emptyList())   // 清掉上一个视频的同步点标记
        syncPanel.setHasSyncPoints(false)         // 新视频无同步点(对齐官方 offsets 清零)
        lastGyroUri = null                        // 外挂运动数据状态随新视频复位
        motionPanel.setExternalGyroLoaded(false)  // 隐藏「加载全部元数据/帧偏移」(新会话 frame_offset 默认 0)
        motionPanel.setOpenFileEnabled(false)     // 载入完成前禁用「打开文件」(对齐官方: 无视频拒绝加载)
        motionPanel.setAuthorizeDirVisible(false) // 载入完成后按是否有运动数据重新决定显隐
        videoDirHintLabel.visibility = View.GONE  // 蓝色目录授权提示同理, 载入完成后再决定
        setButtonEnabled(playButton, false)
        setButtonEnabled(stabButton, false)
        setInputLocked(true)      // 新视频载入完成前, 重新锁定「参数/导出」面板
        pendingUri = uri
        infoLabels["name"]?.text = queryName(uri)
        statusLabel.text = "已选择, 载入中…"
        maybeStart()
    }

    /**
     * 授权目录后的自动扫描(后台线程): 递归(含子目录)找「与当前视频同名」的运动数据
     * (gcsv/bbl/bfl/csv)和镜头(json)文件。
     * - 同名运动数据在视频同目录(或没找到) → 对齐官方授权后语义(MotionData.qml:173-174):
     *   重载视频, core 的 sidecar 自动检测 + gcsv 内 lensprofile 字段自动配镜头一并生效;
     * - 在子目录 → core 的同目录检测够不到, 走手动加载链路 loadGyroFile;
     * - 同名镜头 json → 记入 pendingScanLensUri, 后续仍无镜头时兜底加载
     *   (官方 core 只认 gcsv 内 lensprofile 字段, 同名 json 是产品扩展)。
     */
    private fun scanGrantedTree(treeUri: Uri) {
        val videoUri = pendingUri ?: return
        val base = queryName(videoUri).substringBeforeLast('.')
        // 视频所在目录的 document id(SAF 路径型 id 如 "primary:Dir/x.MP4" 可取父段;
        // 不可解析(如 Downloads 的 msf: 不透明 id)则视为非同目录, 走手动加载链路, 仍可用。
        val videoParentId = try {
            DocumentsContract.getDocumentId(videoUri).substringBeforeLast('/', "")
        } catch (_: Throwable) {
            ""
        }
        val motionExts = setOf("gcsv", "bbl", "bfl", "csv")
        var motionUri: Uri? = null
        var motionDirId: String? = null
        var lensUri: Uri? = null
        fun walk(dirDocId: String) {
            if (motionUri != null && lensUri != null) return
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, dirDocId)
            val cols = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            )
            try {
                contentResolver.query(children, cols, null, null, null)?.use { c ->
                    while (c.moveToNext()) {
                        val docId = c.getString(0) ?: continue
                        val name = c.getString(1) ?: continue
                        val mime = c.getString(2) ?: ""
                        if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                            walk(docId)
                        } else if (name.substringBeforeLast('.') == base) {
                            val ext = name.substringAfterLast('.', "").lowercase()
                            if (motionUri == null && ext in motionExts) {
                                motionUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                                motionDirId = dirDocId
                            } else if (lensUri == null && ext == "json") {
                                lensUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                            }
                        }
                        if (motionUri != null && lensUri != null) break
                    }
                }
            } catch (e: Throwable) {
                Log.w(TAG, "scanGrantedTree query failed: $e")
            }
        }
        walk(DocumentsContract.getTreeDocumentId(treeUri))
        Log.d(TAG, "scanGrantedTree base=$base motion=$motionUri lens=$lensUri")
        pendingScanLensUri = lensUri
        val motion = motionUri
        val sameDir = motion != null && videoParentId.isNotEmpty() && motionDirId == videoParentId
        runOnUiThread {
            if (motion != null && !sameDir) {
                loadGyroFile(motion, motionPanel.loadAllMetadataChecked())
            } else {
                openVideoFile(videoUri)
            }
        }
    }

    /** 加载外挂运动数据文件(初次选择与「加载全部元数据」切换重载共用)。 */
    private fun loadGyroFile(uri: Uri, loadAllMetadata: Boolean) {
        motionPanel.showEmpty("运动数据加载中…")
        Thread {
            val r = GyroflowNative.nativeLoadGyro(uri.toString(), loadAllMetadata)
            // 授权目录扫描记下的同名镜头 json: 运动数据载入后仍无镜头则兜底加载
            var hasLens = try {
                org.json.JSONObject(GyroflowNative.nativeGetLensInfo() ?: "{}").optBoolean("has_lens", false)
            } catch (_: Throwable) {
                false
            }
            val scanLens = pendingScanLensUri
            if (r?.startsWith("gyro ok") == true && !hasLens && scanLens != null) {
                pendingScanLensUri = null
                hasLens = GyroflowNative.nativeLoadLens(scanLens.toString())?.startsWith("lens ok") == true
            }
            runOnUiThread {
                if (r?.startsWith("gyro ok") == true) {
                    if (hasLens) {
                        // 镜头可能由原生层按 camera_id 自动配上(stab.rs load_gyro)或 json 兜底
                        // (scanLensLoaded) → 刷新镜头面板/黄警告; 已有镜头时重渲无害
                        showLensInfo()
                    }
                    // 蓝色目录授权提示: 运动数据已就位, 仅镜头仍缺时保持显示
                    videoDirHintLabel.visibility = if (hasLens) View.GONE else View.VISIBLE
                    infoLabels["gyro"]?.text = "是"
                    motionPanel.setAuthorizeDirVisible(false)  // 已手动加载运动数据, 收起目录授权提示
                    motionPanel.setExternalGyroLoaded(true) // 显示「加载全部元数据/帧偏移」(仅外挂文件场景, 对齐官方)
                    motionPanel.setFileName(queryName(uri))
                    motionPanel.refresh()       // 解析运动数据并填入「陀螺数据信息」
                    refreshGyroTimeline()        // 重画预览下方陀螺波形时间轴
                    // 清除上一份运动数据算出的同步点 —— 引擎已在 load_gyro_data 里清掉
                    // (gyro.clear() → clear_offsets), 这里把 UI 标记同步归零(对齐官方 update_offset_model)。
                    gyroTimeline.setSyncPoints(emptyList())
                    syncPanel.setHasSyncPoints(false)
                    motionFromVideo = false     // 外挂运动数据 → 非视频自带, usesQuats=false(对齐官方 filename 不匹配)
                    refreshUsesQuats()
                    // 对齐官方 autosyncTimer: 陀螺数据重新载入后满足条件则自动同步。
                    // 「加载全部元数据」勾选时镜头档案随文件载入, 其 sync_settings.do_autosync
                    // 会让 maybeAutoSync 的官方门控通过(offsets 刚清空、无准确时间戳)。
                    maybeAutoSync()
                } else {
                    motionPanel.showEmpty(r ?: "加载失败")
                }
            }
        }.start()
    }

    // ── Surface 回调 ──
    override fun surfaceCreated(holder: SurfaceHolder) {}

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        GyroflowNative.nativePreviewSurfaceDestroyed()
        val r = GyroflowNative.nativePreviewSurfaceCreated(holder.surface, width, height)
        Log.d(TAG, "surfaceChanged ${width}x${height} -> $r")
        surfaceReady = true
        maybeStart()
        // 回前台: surface 重建后, 把当前帧重渲到新 surface(否则黑屏)。已在播放则照常继续。
        decoder?.let { if (!it.isPlaying()) it.seekTo(lastProgress) }
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        // 退后台只暂停(保留解码线程), 回来才能重渲; 真正销毁在 onDestroy 停线程。
        decoder?.pause()
        surfaceReady = false
        GyroflowNative.nativePreviewSurfaceDestroyed()
    }

    override fun onDestroy() {
        decoder?.stop()
        GyroflowNative.nativePreviewSurfaceDestroyed()
        super.onDestroy()
    }

    private fun maybeStart() {
        val uri = pendingUri
        if (surfaceReady && uri != null && !started) {
            started = true
            selectPlaceholder.visibility = View.GONE
            startPlayback(uri)
        }
    }

    private fun startPlayback(uri: Uri) {
        Thread {
            // 载入视频(元数据 + 内嵌陀螺 + 自动镜头) + 配参 + 预计算稳定
            val openRes = GyroflowNative.nativeOpenVideo(uri.toString())
            Log.d(TAG, "nativeOpenVideo -> $openRes")
            runOnUiThread {
                statusLabel.text = openRes ?: ""
                // 解析视频原始尺寸(供关防抖时按宽定高)
                Regex("""opened (\d+)x(\d+)""").find(openRes ?: "")?.let {
                    videoW = it.groupValues[1].toInt()
                    videoH = it.groupValues[2].toInt()
                    // 导出输出大小默认 16:9(高取偶) + 输出路径默认名(视频名_stabilized.mp4,
                    // 对齐官方 VideoArea.qml:437-438): 导入新视频时按新视频信息重置;
                    // 同视频重载(授权目录后)保留用户已填值。
                    val defH = (videoW * 9 / 16 / 2) * 2
                    val defName = "${queryName(uri).substringBeforeLast('.')}_stabilized.mp4"
                    if (resetExportSize) {
                        resetExportSize = false
                        exportPanel.setDefaultSize(videoW, defH)
                        exportPanel.setDefaultFileName(defName)
                    } else {
                        exportPanel.setDefaultSizeIfEmpty(videoW, defH)
                        exportPanel.setDefaultFileNameIfEmpty(defName)
                    }
                    resolveExportFileNameConflict()   // 默认名也查重: 目标位置已有同名 → _X
                }
                updateVideoInfo(openRes ?: "")
            }

            val d = VideoDecoder(this, uri) { frame, ptsUs ->
                val r = GyroflowNative.nativeProcessFrame(frame.y, frame.u, frame.v, frame.width, frame.height, ptsUs)
                if (r != null && r.startsWith("frame FAIL")) {
                    Log.e(TAG, r)
                }
                motionPanel.updateOrientation(ptsUs) // 驱动方向指示器
                if (videoDurationUs > 0) {
                    lastProgress = ptsUs.toDouble() / videoDurationUs
                    gyroTimeline.setProgress(lastProgress) // 时间轴游标
                }
                // 左上角 HUD: 时间 / 帧 / 缩放(竖排三行)
                val timeSec = ptsUs / 1_000_000.0
                val frameNo = if (videoFps > 0) Math.round(timeSec * videoFps) else 0L
                // 缩放% = 100/fov(对齐桌面 controller.current_fov / iOS, 见 GyroflowNative.nativeGetCurrentFov)
                val fov = GyroflowNative.nativeGetCurrentFov()
                val zoomStr = if (fov > 0.0001) String.format("%.2f%%", 100.0 / fov) else "--"
                val hud = "时间: ${fmtTime(timeSec)}\n帧: ($frameNo/$videoFrameCount)\n缩放: $zoomStr"
                runOnUiThread {
                    hudLabel.text = hud
                    if (hudLabel.visibility != View.VISIBLE) hudLabel.visibility = View.VISIBLE
                }
            }
            d.onEnd = { runOnUiThread { updatePlayButton() } }
            runOnUiThread {
                decoder = d
                d.start()                 // 线程启动, 默认暂停
                setButtonEnabled(playButton, true)
                setButtonEnabled(stabButton, true)
                updatePlayButton()        // "播放", 须手动点
                setInputLocked(false)     // 视频就绪 → 解锁「参数/导出」面板(对齐官方 enabled: vid.loaded)
                maybeAutoSync()           // 满足条件则自动同步(对齐官方 autosyncTimer)
            }
        }.start()
    }

    /**
     * 对齐官方 Synchronization.qml autosyncTimer: 载入视频后满足条件则自动触发同步(无需手动点)。
     * 条件: 镜头档案 sync_settings.do_autosync==true && 有陀螺数据 && 陀螺无准确时间戳 && 尚无同步点。
     * (官方: 有准确时间戳 Sony/DJI/Insta360/Canon 等直接跳过; do_autosync 仅特定镜头档案为 true。)
     */
    private fun maybeAutoSync() {
        Thread {
            val syncJson = GyroflowNative.nativeGetSyncSettings() ?: "{}"
            val gyroJson = GyroflowNative.nativeGetGyroInfo() ?: "{}"
            val so = try { org.json.JSONObject(syncJson) } catch (_: Throwable) { org.json.JSONObject() }
            val go = try { org.json.JSONObject(gyroJson) } catch (_: Throwable) { org.json.JSONObject() }
            val doAuto = so.optBoolean("do_autosync", false)
            val hasMotion = go.optBoolean("has_motion", false)
            val accurateTs = go.optBoolean("has_accurate_timestamps", false)
            if (doAuto && hasMotion && !accurateTs) {
                runOnUiThread {
                    // 先把镜头携带的同步参数应用到面板(确保 currentParams 用档案值), 再触发(对齐官方 loadGyroflow→doSync)
                    syncPanel.applySyncSettings(syncJson)
                    if (autosync == null) { // 没在同步中、且刚载入无同步点时触发
                        onAutosyncToggle(true)
                    }
                }
            }
        }.start()
    }

    /**
     * 计算并刷新 usesQuats(对齐官方 Synchronization.qml:211):
     *   usesQuats = 运动数据来自视频本身 && (精确时间戳 || (有四元数 && 积分方法 None=0))。
     * 载入视频 / 加载运动数据 / 改积分方法后都应调用一次。
     */
    private fun refreshUsesQuats() {
        Thread {
            val go = try {
                org.json.JSONObject(GyroflowNative.nativeGetGyroInfo() ?: "{}")
            } catch (_: Throwable) {
                org.json.JSONObject()
            }
            val accurate = go.optBoolean("has_accurate_timestamps", false)
            val quats = go.optBoolean("has_quaternions", false)
            val intM = go.optInt("integration_method", 1)
            val usesQuats = motionFromVideo && (accurate || (quats && intM == 0))
            runOnUiThread { syncPanel.setUsesQuats(usesQuats) }
        }.start()
    }

    private fun togglePlay() {
        val d = decoder ?: return
        if (d.isPlaying()) d.pause() else d.play()
        updatePlayButton()
    }

    private fun updatePlayButton() {
        playButton.text = if (decoder?.isPlaying() == true) "暂停" else "播放"
    }

    private fun toggleStab() {
        stabEnabled = !stabEnabled
        stabButton.text = if (stabEnabled) "关闭防抖" else "开启防抖"
        // 开防抖 → 16:9; 关防抖 → 按视频原始比例(按宽定高)
        if (stabEnabled) resizePreview(16, 9) else resizePreview(videoW, videoH)
        Thread {
            val r = GyroflowNative.nativeSetStabEnabled(stabEnabled)
            Log.d(TAG, "setStabEnabled($stabEnabled) -> $r")
        }.start()
    }

    /**
     * 按宽定高调整预览区(aw:ah 为目标比例), 高度封顶屏高 45%——对齐官方桌面版
     * VideoArea.qml 的信箱式 aspect-fit, 比例再高也不把 Tab/面板挤出屏幕。
     * 超限时 SurfaceView 不再铺满, 按输出比例算宽、水平居中(比例与输出一致, 画面不变形)。
     */
    private fun resizePreview(aw: Int, ah: Int) {
        if (aw <= 0 || ah <= 0) return
        val screenW = resources.displayMetrics.widthPixels
        val maxH = (resources.displayMetrics.heightPixels * 0.45f).toInt()
        val desiredH = (screenW.toLong() * ah / aw).toInt()
        val boxH = minOf(desiredH, maxH)
        val lp = previewArea.layoutParams
        lp.height = boxH
        previewArea.layoutParams = lp
        val surfaceLp = if (desiredH <= maxH) {
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
        } else {
            FrameLayout.LayoutParams((boxH.toLong() * aw / ah).toInt(), FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER)
        }
        surfaceView.layoutParams = surfaceLp
        previewArea.requestLayout()
    }
}
