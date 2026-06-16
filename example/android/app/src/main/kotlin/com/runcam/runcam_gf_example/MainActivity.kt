package com.runcam.runcam_gf_example

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * dev-only:给 example 的 smoke 用的「文档选择器」通道。
 * 用 ACTION_OPEN_DOCUMENT 选视频并取持久读权限,返回 content:// 字符串——
 * 这是 gyroflow 原生 nativeOpenVideo 唯一接受的形式(image_picker/file_picker
 * 给的缓存文件路径会被判 Invalid path)。对齐 GyroflowActivity 的选片方式。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "runcam_gf_example/picker"
    private val reqCode = 0x5A11
    private var pending: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "pickVideo") {
                    if (pending != null) {
                        result.error("BUSY", "picker already active", null)
                        return@setMethodCallHandler
                    }
                    pending = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "video/*"
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivityForResult(intent, reqCode)
                } else {
                    result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != reqCode) return
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
}
