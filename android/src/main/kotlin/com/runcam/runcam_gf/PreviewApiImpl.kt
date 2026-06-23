package com.runcam.runcam_gf

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.runcam.runcam.GyroflowExporter
import io.flutter.view.TextureRegistry
import java.io.File

/**
 * 实现 Pigeon [PreviewApi](阶段1 安卓补齐,对齐 iOS PreviewApiImpl)。
 *
 * 持有 [PreviewController](Texture 预览)与 [GyroflowExporter](导出);引擎为 .so 单例,
 * 与 [EngineApiImpl] / ParamsModel 共享,无需传句柄。导出进度经 [EngineEvents.onExportProgress] 回 Dart。
 */
class PreviewApiImpl(
    private val context: Context,
    private val textures: TextureRegistry,
    private val events: EngineEvents,
) : PreviewApi {

    private val main = Handler(Looper.getMainLooper())

    private var controller: PreviewController? = null
    private var textureId: Long = -1
    private var exporter: GyroflowExporter? = null

    override fun createPreviewTexture(uriOrPath: String): PreviewInfo {
        // 重复进页:先拆旧的,避免纹理/解码泄漏。
        controller?.dispose()
        controller = null
        textureId = -1

        val ctrl = PreviewController(context, textures)
        val (tid, w, h) = ctrl.setup(uriOrPath)
        controller = ctrl
        textureId = tid
        return PreviewInfo(textureId = tid, width = w.toLong(), height = h.toLong())
    }

    override fun disposePreviewTexture(textureId: Long) {
        controller?.dispose()
        controller = null
        this.textureId = -1
    }

    override fun play() { controller?.play() }
    override fun pause() { controller?.pause() }
    override fun seekTo(timestampUs: Long) { controller?.seekTo(timestampUs) }
    override fun renderOnce() { controller?.renderOnce() }
    override fun takeCompositedFrameCount(): Long = controller?.takeCompositedFrameCount() ?: 0L
    override fun setExportMode(on: Boolean) { /* 导出走 startExport;此处不单独用(对齐 iOS) */ }

    /**
     * 导出:复用现成 [GyroflowExporter](解码→去畸变+稳定回读→编码→相册/所选目录)。
     * 返回约定:成功 ""、取消 "已取消"、失败错误信息(对齐 Dart startExport 解析)。
     */
    override fun startExport(req: ExportRequest, callback: (Result<String>) -> Unit) {
        val src = req.srcUri ?: ""
        if (src.isEmpty()) { callback(Result.success("源视频为空")); return }
        val ctrl = controller
        if (ctrl == null) { callback(Result.success("预览未就绪,无法导出")); return }

        // 关键:停预览喂帧 —— 预览(nativeProcessFrame)与导出(nativeRenderFrameI420)都动同一
        // 单例引擎,不可并发(对齐旧 GyroflowActivity.startExport 的 decoder?.pause())。
        ctrl.pauseForExport()

        val outUri = req.outputUri ?: ""
        val s = GyroflowExporter.Settings(
            codecIndex = (req.codecIndex ?: 0L).toInt(),
            outW = (req.width ?: 0L).toInt(),
            outH = (req.height ?: 0L).toInt(),
            bitrateMbps = (req.bitrateMbps ?: 0L).toInt(),
            exportAudio = req.exportAudio ?: true,
            fileName = req.fileName ?: "",
            exportDirUri = if (outUri.isEmpty()) null else outUri,
            trimStartUs = req.trimStartUs ?: 0L,
            trimEndUs = req.trimEndUs ?: 0L,
        )
        val ex = GyroflowExporter(context, toUri(src))
        exporter = ex
        ex.run(
            s,
            onProgress = { p ->
                main.post { events.onExportProgress(p.percent.toDouble(), p.frame.toLong(), p.total.toLong()) {} }
            },
            onDone = { _, err ->
                main.post {
                    exporter = null
                    ctrl.resumeAfterExport() // 恢复预览喂帧(输出尺寸恢复由 Dart 侧负责)
                    // GyroflowExporter 取消时 err == "已取消"(其内部抛 RuntimeException("已取消"))。
                    callback(Result.success(err ?: ""))
                }
            },
        )
    }

    override fun cancelExport() { exporter?.cancel() }

    fun shutdown() {
        exporter?.cancel()
        controller?.dispose()
        controller = null
    }

    private fun toUri(uriOrPath: String): Uri =
        if (uriOrPath.startsWith("content://") || uriOrPath.startsWith("file://")) {
            Uri.parse(uriOrPath)
        } else {
            Uri.fromFile(File(uriOrPath))
        }
}
