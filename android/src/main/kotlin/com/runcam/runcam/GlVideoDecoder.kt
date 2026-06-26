package com.runcam.runcam

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * 与 [VideoDecoder] 同接口的降级解码器:解码输出到 **ImageReader 的 Surface**(显式多缓冲 + GPU/CPU usage),
 * 用于部分设备(如华为)硬件解码器对高分辨率(4K60 H.264)按默认/ByteBuffer 方式 `start()` 失败的情况。
 *
 * 对齐官方 Gyroflow(`src/rendering/ffmpeg_android.rs`)的做法:官方用
 * `ImageReader::new_with_usage(YUV_420_888, GPU_SAMPLED_IMAGE, 10)` 作为 mediacodec 输出 Surface
 * —— **只给 GPU_SAMPLED、10 个缓冲、不带 CPU_READ**。
 *
 * 关键:之前本类擅自加了 `CPU_READ_OFTEN` 并把缓冲数提到 16。`CPU_READ_OFTEN` 会让分配器在 GPU 平铺
 * 缓冲之外**再分一份 CPU 线性影子**(每帧近乎翻倍),16 个 4K 缓冲 ≈ 380MB 图形内存;在内存吃紧
 * (logcat `trimMemory level: 5`)时 `MediaCodec.start()` 直接报 `0xfffffff4`(-12 NO_MEMORY)失败 → 黑屏。
 * 改回官方的 GPU_SAMPLED + 10 缓冲后占用减半(~120MB),start 成功。YUV_420_888 的 `getPlanes()`
 * 在 Android 上语义即 CPU 可读,无需 CPU_READ_OFTEN usage 标志,故 YUV 回读照常工作。
 */
class GlVideoDecoder(
    private val context: Context,
    private val uri: Uri,
    private val onFrame: (YuvPacker.Frame, Long) -> Unit,
) : FrameDecoder {

    private companion object {
        const val TAG = "GyroflowPreview"
        const val TIMEOUT_US = 10_000L
        const val DROP_THRESHOLD_NS = 15_000_000L
        const val REANCHOR_NS = 200_000_000L
        const val MAX_IMAGES = 10 // 对齐官方 ffmpeg_android.rs:GPU_SAMPLED + 10 缓冲(更多会 OOM)
        const val IMAGE_WAIT_MS = 300L
    }

    override var onEnd: (() -> Unit)? = null

    @Volatile private var running = false
    @Volatile private var playing = false
    @Volatile private var seekToStart = false
    @Volatile private var seekTargetUs = -1L
    @Volatile private var durationUs = 0L
    @Volatile private var lastRenderedPtsUs = -1L
    @Volatile private var thread: Thread? = null

    private val frameQueue = ArrayBlockingQueue<Image>(MAX_IMAGES - 2)
    private var frameCount = 0

    override fun seekTo(progress: Double) {
        if (durationUs > 0L) seekTargetUs = (progress.coerceIn(0.0, 1.0) * durationUs).toLong()
    }

    override fun seekToUs(us: Long) {
        val t = us.coerceAtLeast(0L); lastRenderedPtsUs = t; seekTargetUs = t
    }

    override fun rerender() {
        if (seekTargetUs >= 0L) return
        val t = lastRenderedPtsUs
        if (t >= 0L) seekTargetUs = t
    }

    override fun start() { running = true; thread = Thread { runLoop() }.also { it.start() } }
    override fun play() { playing = true }
    override fun pause() { playing = false }
    override fun isPlaying(): Boolean = playing

    override fun stop() {
        running = false
        try { thread?.join(800) } catch (_: InterruptedException) {}
        thread = null
    }

    private fun runLoop() {
        var extractor: MediaExtractor? = null
        var codec: MediaCodec? = null
        var reader: ImageReader? = null
        var listenerThread: HandlerThread? = null
        try {
            extractor = MediaExtractor()
            extractor.setDataSource(context, uri, null)
            val track = selectVideoTrack(extractor) ?: run { Log.e(TAG, "gl: no video track"); return }
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            if (format.containsKey(MediaFormat.KEY_DURATION)) durationUs = format.getLong(MediaFormat.KEY_DURATION)
            val w = format.getInteger(MediaFormat.KEY_WIDTH)
            val h = format.getInteger(MediaFormat.KEY_HEIGHT)

            val lt = HandlerThread("GfImgReader").also { it.start() }
            listenerThread = lt
            val ir = newImageReader(w, h)
            reader = ir
            ir.setOnImageAvailableListener({ r ->
                val img = try { r.acquireNextImage() } catch (_: Throwable) { null }
                if (img != null && !frameQueue.offer(img)) img.close()
            }, Handler(lt.looper))

            // 同 VideoDecoder:降低 4K60 解码器资源预留(预览不需要 60fps 实时吞吐),把内存让给 wgpu。
            format.setInteger(MediaFormat.KEY_OPERATING_RATE, 30)
            format.setInteger(MediaFormat.KEY_PRIORITY, 1)
            codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(format, ir.surface, null, 0) // 输出到 ImageReader 的 Surface
            codec.start()
            Log.i(TAG, "imgreader decode started ${w}x$h buffers=$MAX_IMAGES")
            decodeLoop(extractor, codec)
        } catch (t: Throwable) {
            Log.e(TAG, "gl decode error", t)
        } finally {
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            drainQueue()
            try { reader?.close() } catch (_: Throwable) {}
            try { listenerThread?.quitSafely() } catch (_: Throwable) {}
            try { extractor?.release() } catch (_: Throwable) {}
        }
    }

    private fun newImageReader(w: Int, h: Int): ImageReader {
        // 对齐官方:**只给 GPU_SAMPLED**(不加 CPU_READ_OFTEN —— 它会再分一份 CPU 线性影子致 4K OOM)。
        // YUV_420_888 的 getPlanes() 本身即 CPU 可读,无需该 usage 标志。
        return if (Build.VERSION.SDK_INT >= 29) {
            ImageReader.newInstance(w, h, ImageFormat.YUV_420_888, MAX_IMAGES, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE)
        } else {
            ImageReader.newInstance(w, h, ImageFormat.YUV_420_888, MAX_IMAGES)
        }
    }

    private fun selectVideoTrack(extractor: MediaExtractor): Int? {
        for (i in 0 until extractor.trackCount) {
            if (extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) return i
        }
        return null
    }

    private fun decodeLoop(extractor: MediaExtractor, codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var anchored = false
        var clockStartNs = 0L
        var basePtsUs = 0L
        var firstShown = false

        while (running) {
            val st = seekTargetUs
            if (st >= 0) {
                codec.flush(); drainQueue()
                extractor.seekTo(st, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                inputDone = false; anchored = false; firstShown = false
                seekTargetUs = -1
            }
            if (!playing && firstShown) {
                anchored = false
                try { Thread.sleep(15) } catch (_: InterruptedException) {}
                continue
            }
            if (seekToStart) {
                codec.flush(); drainQueue()
                extractor.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                inputDone = false; seekToStart = false; anchored = false; firstShown = false
            }

            if (!inputDone) inputDone = feedInput(extractor, codec)
            val outIdx = codec.dequeueOutputBuffer(info, TIMEOUT_US)
            if (outIdx < 0) continue

            var rendered = false
            if (info.size > 0) {
                if (playing) {
                    if (!anchored) { clockStartNs = System.nanoTime(); basePtsUs = info.presentationTimeUs; anchored = true }
                    val target = clockStartNs + (info.presentationTimeUs - basePtsUs) * 1000
                    val behindNs = System.nanoTime() - target
                    if (behindNs > REANCHOR_NS) {
                        clockStartNs = System.nanoTime(); basePtsUs = info.presentationTimeUs
                        rendered = true; if (renderOutput(codec, outIdx, info.presentationTimeUs)) firstShown = true
                    } else if (behindNs <= DROP_THRESHOLD_NS) {
                        rendered = true; if (renderOutput(codec, outIdx, info.presentationTimeUs)) firstShown = true
                        val sleepNs = target - System.nanoTime()
                        if (sleepNs > 0) try { Thread.sleep(sleepNs / 1_000_000, (sleepNs % 1_000_000).toInt()) } catch (_: InterruptedException) {}
                    }
                } else {
                    rendered = true; if (renderOutput(codec, outIdx, info.presentationTimeUs)) firstShown = true
                }
            }
            if (!rendered) codec.releaseOutputBuffer(outIdx, false)
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                playing = false; seekToStart = true; inputDone = false
                onEnd?.invoke()
            }
        }
    }

    private fun feedInput(extractor: MediaExtractor, codec: MediaCodec): Boolean {
        val inIdx = codec.dequeueInputBuffer(TIMEOUT_US)
        if (inIdx < 0) return false
        val ib = codec.getInputBuffer(inIdx)!!
        val sz = extractor.readSampleData(ib, 0)
        if (sz < 0) {
            codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            return true
        }
        codec.queueInputBuffer(inIdx, 0, sz, extractor.sampleTime, 0)
        extractor.advance()
        return false
    }

    /** 渲染该帧到 ImageReader 的 surface → 取回 Image → 打包 YUV 回调。返回是否真取到帧。 */
    private fun renderOutput(codec: MediaCodec, outIdx: Int, ptsUs: Long): Boolean {
        codec.releaseOutputBuffer(outIdx, true) // 送到 ImageReader 的 surface
        val image = try {
            frameQueue.poll(IMAGE_WAIT_MS, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            null
        } ?: run { Log.w(TAG, "imgreader poll timeout"); return false }
        try {
            val frame = YuvPacker.pack(image)
            if (frameCount < 3) {
                val mid = (frame.height / 2) * frame.width + (frame.width / 2)
                Log.i(TAG, "imgreader frame #$frameCount pts=$ptsUs midY=${frame.y[mid].toInt() and 0xFF}")
            }
            frameCount++
            onFrame(frame, ptsUs)
            lastRenderedPtsUs = ptsUs
            return true
        } finally {
            image.close()
        }
    }

    private fun drainQueue() {
        while (true) {
            val img = frameQueue.poll() ?: break
            try { img.close() } catch (_: Throwable) {}
        }
    }
}
