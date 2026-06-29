package com.runcam.runcam_gf

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import org.json.JSONObject

/**
 * RuncamGF Flutter 插件 — Android 入口。
 *
 * Channel:
 *   - `runcam_gf_example/picker`:编辑器(PreviewPage/EditController)用的文件选择器。
 *     用 ACTION_OPEN_DOCUMENT / OPEN_DOCUMENT_TREE 选文件/目录并取持久读权限,返回 content:// 串
 *     (gyroflow 核心 nativeOpenVideo 只接受该形式,缓存路径会被判 Invalid path)。原先放在
 *     example 的 MainActivity,现内聚进插件 —— 宿主无需任何配置即可使用编辑器。
 *
 * 原样从原 App 的 MainActivity 抽离: 行为不变。Gyroflow 的 Kotlin 源码、
 * libruncam_gyroflow.so 都在本插件模块里。
 */
class RuncamGfPlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.ActivityResultListener {

    private lateinit var pickerChannel: MethodChannel
    private var appContext: Context? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var engineEvents: EngineEvents? = null // 阶段2:原生→Dart 回调通道
    private var previewApi: PreviewApiImpl? = null  // 阶段1:预览 Texture + 导出转发壳

    // —— 文件选择器状态 ——
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pickerPending: Result? = null
    private val reqPickFile = 0x5A11   // ACTION_OPEN_DOCUMENT(单文件)
    private val reqPickFolder = 0x5A12 // ACTION_OPEN_DOCUMENT_TREE(目录授权)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext

        // 文件选择器通道(供编辑器选视频/镜头/陀螺/授权目录)。
        pickerChannel = MethodChannel(binding.binaryMessenger, "runcam_gf_example/picker")
        pickerChannel.setMethodCallHandler { call, result -> handlePicker(call, result) }

        // 阶段2:注册 Pigeon 引擎桥(与旧 `open` channel 并存,互不影响)。
        val events = EngineEvents(binding.binaryMessenger)
        engineEvents = events
        EngineApi.setUp(
            binding.binaryMessenger,
            EngineApiImpl(binding.applicationContext, events),
        )

        // 阶段1:注册预览 API(共享同一 .so 单例引擎 + 插件纹理注册表;导出进度复用同一 events)。
        val preview = PreviewApiImpl(binding.applicationContext, binding.textureRegistry, events)
        PreviewApi.setUp(binding.binaryMessenger, preview)
        previewApi = preview
    }

    // —— 文件选择器:对齐安卓 SAF,返回 content:// 字符串 ——
    private fun handlePicker(call: MethodCall, result: Result) {
        when (call.method) {
            // 单文件选择:视频 / 镜头档案(.json)/ 陀螺 sidecar(.gcsv)。
            "pickVideo", "pickLensFile", "pickMotionFile" -> {
                val act = activity
                if (act == null) {
                    result.error("NO_ACTIVITY", "插件未附着到 Activity", null)
                    return
                }
                if (pickerPending != null) {
                    result.error("BUSY", "picker already active", null)
                    return
                }
                val mime = when (call.method) {
                    "pickVideo" -> "video/*"
                    "pickLensFile" -> "application/json"
                    else -> "*/*" // .gcsv 无标准 MIME;Dart 侧按扩展名校验兜底
                }
                pickerPending = result
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mime
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                act.startActivityForResult(intent, reqPickFile)
            }
            // 目录授权:返回 tree uri 字符串,取消返回 null。
            "pickFolder" -> {
                val act = activity
                if (act == null) {
                    result.error("NO_ACTIVITY", "插件未附着到 Activity", null)
                    return
                }
                if (pickerPending != null) {
                    result.error("BUSY", "picker already active", null)
                    return
                }
                pickerPending = result
                // 导出目录需写权限:createDocument/openFileDescriptor("rw") 写视频文件,
                // 仅读会在重启后(持久授权只剩读)导出失败,故请求读+写持久授权。
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                    addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
                    )
                }
                act.startActivityForResult(intent, reqPickFolder)
            }
            // 扫描授权目录树,找与视频同名的运动数据/镜头文件,返回 JSON。
            "scanFolderForSidecars" -> {
                val folder = call.argument<String>("folder")
                val base = call.argument<String>("base")
                if (folder == null || base == null) {
                    result.error("BAD_ARGS", "folder/base required", null)
                    return
                }
                Thread {
                    val json = try {
                        scanFolderForSidecars(Uri.parse(folder), base)
                    } catch (_: Throwable) {
                        null
                    }
                    mainHandler.post { result.success(json) }
                }.start()
            }
            else -> result.notImplemented()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != reqPickFile && requestCode != reqPickFolder) return false
        val r = pickerPending ?: return true
        pickerPending = null
        val uri = data?.data
        if (resultCode == Activity.RESULT_OK && uri != null) {
            try {
                // 目录授权(导出落盘)需持久化读+写;单文件(视频/镜头/运动数据)仅读。
                val flags = if (requestCode == reqPickFolder) {
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                } else {
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                }
                appContext?.contentResolver?.takePersistableUriPermission(uri, flags)
            } catch (_: Exception) {
                // best-effort:某些来源不支持持久授权,但本次会话内仍可读。
            }
            r.success(uri.toString())
        } else {
            r.success(null) // 用户取消
        }
        return true
    }

    /**
     * 递归遍历授权目录树 [treeUri],找「显示名去扩展名 == [base]」的运动数据(gcsv/bbl/bfl/csv)
     * 与镜头(json)文件,返回 JSON {"motionPath":...,"lensPath":...}(未匹配字段为 null)。
     * path 为 content:// uri(buildDocumentUriUsingTree),与核心 loadGyro/loadLens 接受的形式一致。
     */
    private fun scanFolderForSidecars(treeUri: Uri, base: String): String {
        val resolver = appContext?.contentResolver
        val motionExts = setOf("gcsv", "bbl", "bfl", "csv")
        var motionUri: Uri? = null
        var lensUri: Uri? = null

        fun walk(dirDocId: String) {
            if (resolver == null) return
            if (motionUri != null && lensUri != null) return
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, dirDocId)
            val cols = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            )
            try {
                resolver.query(children, cols, null, null, null)?.use { c ->
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
                            } else if (lensUri == null && ext == "json") {
                                lensUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                            }
                        }
                        if (motionUri != null && lensUri != null) break
                    }
                }
            } catch (_: Throwable) {
                // 某些子目录不可枚举(不透明 id 等):忽略,继续其余目录。
            }
        }

        walk(DocumentsContract.getTreeDocumentId(treeUri))

        return JSONObject().apply {
            put("motionPath", motionUri?.toString() ?: JSONObject.NULL)
            put("lensPath", lensUri?.toString() ?: JSONObject.NULL)
        }.toString()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        pickerChannel.setMethodCallHandler(null)
        EngineApi.setUp(binding.binaryMessenger, null)
        PreviewApi.setUp(binding.binaryMessenger, null)
        previewApi?.shutdown()
        previewApi = null
        engineEvents = null
        appContext = null
    }

    // —— ActivityAware: 拿到宿主 Activity(startActivity / startActivityForResult)+ 监听返回结果 ——
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    private fun detachActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
    }
}
