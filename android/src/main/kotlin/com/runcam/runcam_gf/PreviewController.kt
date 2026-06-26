package com.runcam.runcam_gf

import android.content.Context
import android.net.Uri
import android.util.Log
import com.runcam.runcam.AudioPlayer
import com.runcam.runcam.GyroflowNative
import com.runcam.runcam.VideoDecoder
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/**
 * 安卓预览控制器(对齐 iOS PreviewController):零拷贝把「去畸变+稳定」结果显示到 Flutter Texture。
 *
 * 与 iOS 不同(更简单):iOS 纹理 API 是拉取式,需自建 CVPixelBuffer 轮转池;安卓
 * [TextureRegistry.SurfaceProducer] 是推送式 —— 它给出一个 Surface,谁渲进去 Flutter 就采样谁。
 * 而 [GyroflowNative.nativePreviewSurfaceCreated] 早已能把 wgpu 稳定输出渲进任意 Surface
 * (旧全屏页给的是 SurfaceView 的 holder.surface)。故此处把 SurfaceProducer 的 Surface 交给它,
 * 即零拷贝、无缓冲池、无新 GPU 代码。
 *
 * 引擎是 .so 单例:解码出的 YUV 帧经 [GyroflowNative.nativeProcessFrame] 喂给同一引擎实例
 * (与 EngineApiImpl / ParamsModel 共享),稳定后直接渲进 Surface。
 *
 * 生命周期相关的 SurfaceProducer / TextureRegistry 调用须在主线程;解码在 VideoDecoder 自己的线程。
 */
class PreviewController(
    private val context: Context,
    private val textures: TextureRegistry,
) {
    companion object {
        private const val TAG = "GFPreview"
    }

    private var producer: TextureRegistry.SurfaceProducer? = null
    private var decoder: VideoDecoder? = null
    private var audio: AudioPlayer? = null
    private var uri: Uri? = null
    private var outW = 0
    private var outH = 0

    @Volatile private var tornDown = false
    @Volatile private var exporting = false // 导出期间停止预览喂帧(避免与导出并发动单例引擎)
    private val produceCount = AtomicInteger(0) // 已喂帧数(合成 FPS 的近似代理)

    /** 创建预览纹理:建 SurfaceProducer + 绑 wgpu + 起解码器(默认暂停)。返回 [textureId, outW, outH]。 */
    fun setup(uriOrPath: String): Triple<Long, Int, Int> {
        // 此刻引擎已 openVideo 并设好输出尺寸(Dart openAndStart 在 _startBackend 前完成)。
        val size = runCatching { GyroflowNative.nativeGetOutputSize() }.getOrNull()
        outW = size?.getOrNull(0)?.takeIf { it > 0 } ?: 1280
        outH = size?.getOrNull(1)?.takeIf { it > 0 } ?: 720

        val p = textures.createSurfaceProducer()
        p.setSize(outW, outH)
        producer = p
        // 前后台/surface 重建:重绑 wgpu + 重渲当前帧,避免黑屏(对齐旧页 surfaceChanged 重渲)。
        p.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                if (tornDown) return
                bindSurface() // 幂等:destroy→create;onSurfaceAvailable 即便初次也会再绑,无害
                decoder?.rerender() // 重渲当前帧到新 surface
            }

            override fun onSurfaceCleanup() {
                GyroflowNative.nativePreviewSurfaceDestroyed()
            }
        })

        // 初次显式绑定:解码器随即开始喂帧(渲进该 surface),故须在 start 前完成。
        bindSurface()

        uri = toUri(uriOrPath)
        startDecoderAndAudio() // 起解码 + 音频线程(默认暂停 → 渲首帧后停住)

        return Triple(p.id(), outW, outH)
    }

    // 起(或重起)解码线程 + 音频线程(默认暂停)。导出释放预览解码器后用它重建。
    private fun startDecoderAndAudio() {
        val u = uri ?: return
        val d = VideoDecoder(context, u) { frame, ptsUs ->
            // 已拆除/导出中:不喂帧(导出动同一单例引擎,不可并发)。
            if (!tornDown && !exporting) {
                val res = GyroflowNative.nativeProcessFrame(frame.y, frame.u, frame.v, frame.width, frame.height, ptsUs)
                if (res != null && res.startsWith("frame FAIL")) Log.e(TAG, res)
                produceCount.incrementAndGet()
            }
        }
        decoder = d
        // 音频随视频并行播放(对齐 iOS MDK 自带音频);视频放到结尾时把音频也复位到开头并暂停,
        // 下次 play() 两者同时从 0 起。无音轨视频 AudioPlayer 自动为 no-op。
        val a = AudioPlayer(context, u)
        audio = a
        d.onEnd = { a.resetToStart() }
        d.start() // 起解码线程,默认暂停 → 渲首帧后停住(VideoDecoder firstShown 分支)
        a.start() // 起音频线程,默认暂停,随 play/pause/seek 同步
    }

    // 幂等重绑 wgpu 到当前 SurfaceProducer 的 surface:先 destroy 再 create(对齐旧页
    // surfaceChanged 的 destroyed→created 顺序),避免重复 create 不配对而泄漏/双初始化。
    private fun bindSurface() {
        val p = producer ?: return
        GyroflowNative.nativePreviewSurfaceDestroyed()
        val r = GyroflowNative.nativePreviewSurfaceCreated(p.surface, outW, outH)
        Log.d(TAG, "bindSurface ${outW}x$outH -> $r")
    }

    fun play() { decoder?.play(); audio?.play() }

    fun pause() { decoder?.pause(); audio?.pause() }

    fun seekTo(timestampUs: Long) { decoder?.seekToUs(timestampUs); audio?.seekToUs(timestampUs) }

    /** 暂停态参数 recompute 后重渲当前帧(播放时循环已连续刷新,无需调用)。 */
    fun renderOnce() { decoder?.rerender() }

    /** 取并清零产出帧数;推送式无「合成被拉取」计数,以产出帧数近似(dev FPS HUD 用)。 */
    fun takeCompositedFrameCount(): Long {
        val produce = produceCount.getAndSet(0)
        return produce.toLong() * 1000 + produce
    }

    /**
     * 重活(导出 / autosync,后者经 PreviewApiImpl.setExportMode 调用)开始前:
     * 彻底**释放**预览解码器 + 音频(而非仅暂停)。
     * 关键:部分设备(如高通)不能同时存在 2 个全分辨率硬件解码器实例——预览解码器若不释放,
     * 重活再起一个同分辨率解码器时 MediaCodec.start() 会失败。surface/wgpu 绑定保留,不重建纹理。
     */
    fun pauseForExport() {
        exporting = true
        decoder?.stop()
        decoder = null
        audio?.stop()
        audio = null
    }

    /** 重活结束:重建预览解码器 + 音频(渲首帧;导出的输出尺寸恢复由 Dart 侧负责)。 */
    fun resumeAfterExport() {
        exporting = false
        if (tornDown) return
        startDecoderAndAudio()
    }

    fun dispose() {
        tornDown = true
        decoder?.stop()
        decoder = null
        audio?.stop()
        audio = null
        GyroflowNative.nativePreviewSurfaceDestroyed()
        producer?.release()
        producer = null
    }

    private fun toUri(uriOrPath: String): Uri =
        if (uriOrPath.startsWith("content://") || uriOrPath.startsWith("file://")) {
            Uri.parse(uriOrPath)
        } else {
            Uri.fromFile(File(uriOrPath))
        }
}
