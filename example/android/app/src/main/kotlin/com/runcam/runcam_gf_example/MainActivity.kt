package com.runcam.runcam_gf_example

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * dev-only:给 example 的 smoke 用的「文档选择器」通道。
 * 用 ACTION_OPEN_DOCUMENT 选视频并取持久读权限,返回 content:// 字符串——
 * 这是 gyroflow 原生 nativeOpenVideo 唯一接受的形式(image_picker/file_picker
 * 给的缓存文件路径会被判 Invalid path)。对齐 GyroflowActivity 的选片方式。
 *
 * 另提供两个目录相关方法,对齐 GyroflowActivity 的「授权视频所在目录 + 扫描同名 sidecar」:
 *   - pickFolder:ACTION_OPEN_DOCUMENT_TREE,持久化读权限,返回 tree uri 字符串
 *     (Dart 拿它调 nativeFolderAccessGranted 注册白名单)。
 *   - scanFolderForSidecars:递归遍历授权目录树,找与视频同名的运动数据/镜头文件,
 *     返回 content:// uri(loadGyro/loadLens 直接接受该形式,见 EngineApiImpl)。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "runcam_gf_example/picker"
    private val reqCode = 0x5A11        // ACTION_OPEN_DOCUMENT(单文件)
    private val reqFolderCode = 0x5A12  // ACTION_OPEN_DOCUMENT_TREE(目录授权)
    private var pending: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 单文件选择:视频 / 镜头档案 / 陀螺 sidecar。
                    "pickVideo", "pickLensFile", "pickMotionFile" -> {
                        val mime = when (call.method) {
                            "pickVideo" -> "video/*"
                            // .json,部分机型 application/json 过滤太严,放开
                            "pickLensFile" -> "*/*"
                            // .gcsv/.csv/.bbl 无标准 MIME,放开
                            else -> "*/*"
                        }
                        if (pending != null) {
                            result.error("BUSY", "picker already active", null)
                            return@setMethodCallHandler
                        }
                        pending = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = mime
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivityForResult(intent, reqCode)
                    }
                    // 目录授权:返回 tree uri 字符串,取消返回 null。
                    "pickFolder" -> {
                        if (pending != null) {
                            result.error("BUSY", "picker already active", null)
                            return@setMethodCallHandler
                        }
                        pending = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivityForResult(intent, reqFolderCode)
                    }
                    // 扫描授权目录树,找与视频同名的运动数据/镜头文件,返回 JSON。
                    "scanFolderForSidecars" -> {
                        val folder = call.argument<String>("folder")
                        val base = call.argument<String>("base")
                        if (folder == null || base == null) {
                            result.error("BAD_ARGS", "folder/base required", null)
                            return@setMethodCallHandler
                        }
                        // 递归 query 可能较慢,放后台线程,结果回主线程给 MethodChannel。
                        Thread {
                            val json = try {
                                scanFolderForSidecars(Uri.parse(folder), base)
                            } catch (_: Throwable) {
                                null
                            }
                            runOnUiThread { result.success(json) }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            reqCode -> {
                val r = pending ?: return
                pending = null
                val uri = data?.data
                if (resultCode == Activity.RESULT_OK && uri != null) {
                    try {
                        contentResolver.takePersistableUriPermission(
                            uri, Intent.FLAG_GRANT_READ_URI_PERMISSION,
                        )
                    } catch (_: Exception) {
                        // best-effort:某些来源不支持持久授权,但本次会话内仍可读。
                    }
                    r.success(uri.toString())
                } else {
                    r.success(null) // 用户取消
                }
            }
            reqFolderCode -> {
                val r = pending ?: return
                pending = null
                val treeUri = data?.data
                if (resultCode == Activity.RESULT_OK && treeUri != null) {
                    try {
                        contentResolver.takePersistableUriPermission(
                            treeUri, Intent.FLAG_GRANT_READ_URI_PERMISSION,
                        )
                    } catch (_: Exception) {
                        // best-effort:持久授权失败不影响本次会话内访问。
                    }
                    r.success(treeUri.toString())
                } else {
                    r.success(null) // 用户取消
                }
            }
        }
    }

    /**
     * 递归遍历授权目录树 [treeUri],找「显示名去扩展名 == [base]」的:
     *   - 运动数据(gcsv/bbl/bfl/csv)→ motionPath
     *   - 镜头(json)→ lensPath
     * 返回 JSON {"motionPath":...,"lensPath":...}(未匹配的字段为 null)。
     * 返回的 path 为 content:// uri(buildDocumentUriUsingTree),与 EngineApiImpl 的
     * loadGyro/loadLens 接受的形式一致(它们把字符串直接转发给 nativeLoadGyro/nativeLoadLens)。
     * 对齐 GyroflowActivity.scanGrantedTree 的扩展名集合与匹配逻辑。
     */
    private fun scanFolderForSidecars(treeUri: Uri, base: String): String {
        val motionExts = setOf("gcsv", "bbl", "bfl", "csv")
        var motionUri: Uri? = null
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
}
