package com.runcam.runcam

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.util.Log

/** 预览解码器接口(预留:便于将来插入其它解码实现)。当前实现:[VideoDecoder]。 */
interface FrameDecoder {
    var onEnd: (() -> Unit)?
    fun start()
    fun play()
    fun pause()
    fun isPlaying(): Boolean
    fun seekTo(progress: Double)
    fun seekToUs(us: Long)
    fun rerender()
    fun stop()
}

/**
 * 用 MediaCodec 解码视频(系统选择器返回的 content URI), 每帧回调紧凑 YUV 帧 + 时间戳(微秒)。
 * 支持播放/暂停: 默认暂停, 须手动 play(); 播放到结尾自动暂停(回调 onEnd), 再 play() 从头播。
 * 解码输出走 CPU 线性 ByteBuffer。若默认(通常硬件)解码器对该流 configure/start 失败(如 4K60 H.264
 * 这台机器硬解只能输出到 Surface、不能输出到 CPU 线性),先把它**彻底释放**,再回调 [onStartFailed],
 * 由上层切到 [GlVideoDecoder](解码到 GPU SurfaceTexture → GL 回读),对齐官方"解码到 GPU"的做法。
 */
class VideoDecoder(
    private val context: Context,
    private val uri: Uri,
    private val onFrame: (YuvPacker.Frame, Long) -> Unit,
) : FrameDecoder {
    private companion object {
        const val TAG = "GyroflowPreview"
        const val TIMEOUT_US = 10_000L
        const val DROP_THRESHOLD_NS = 15_000_000L // 落后超过 ~15ms 即丢帧(略落后→丢帧追赶)
        const val REANCHOR_NS = 200_000_000L // 落后超过 ~200ms 视为"解码慢于实时":重锚时钟+照常渲染,避免丢光
    }

    /** 播放到结尾时回调(在解码线程), UI 据此把按钮复位为"播放"。 */
    override var onEnd: (() -> Unit)? = null

    /** 默认(硬件)解码器 configure/start 失败(且已释放干净)时回调一次,供上层切到 GPU 解码路。 */
    var onStartFailed: (() -> Unit)? = null

    @Volatile private var running = false
    @Volatile private var playing = false   // 默认暂停
    @Volatile private var seekToStart = false
    @Volatile private var seekTargetUs = -1L // >=0 表示有待处理 seek
    @Volatile private var durationUs = 0L
    @Volatile private var lastRenderedPtsUs = -1L // 最近渲染帧的 pts,供 rerender() 暂停态重渲

    /** 跳到进度 0.0–1.0(陀螺时间轴拖动用)。暂停时也会渲染目标帧。 */
    override fun seekTo(progress: Double) {
        if (durationUs > 0L) {
            seekTargetUs = (progress.coerceIn(0.0, 1.0) * durationUs).toLong()
        }
    }

    /** 跳到绝对时间戳(微秒)。供 PreviewApi.seekTo 直接用,无需先知时长。暂停时也渲染目标帧。 */
    override fun seekToUs(us: Long) {
        val t = us.coerceAtLeast(0L)
        // 把"当前位置锚点"也设成目标:即便解码循环已消费 seek、随后的 rerender 也重渲到此处,
        // 不会退回上一帧(修复暂停态拖 seek 后 renderOnce 把画面拉回旧帧)。
        lastRenderedPtsUs = t
        seekTargetUs = t
    }

    /**
     * 暂停态参数改动后重渲当前帧:把 seek 目标置为最近渲染帧的 pts,让解码循环用新变换
     * 重新喂一遍(对齐旧 GyroflowActivity 的 seekTo(lastProgress) 重渲)。尚无渲染帧则跳过。
     */
    override fun rerender() {
        // 已有待处理 seek 时绝不覆盖:暂停态拖 seek 时 Dart 紧接着会 renderOnce→rerender,
        // 若覆盖 seekTargetUs 会把目标改回上一帧 → 画面不动。
        if (seekTargetUs >= 0L) return
        val t = lastRenderedPtsUs
        if (t >= 0L) seekTargetUs = t
    }

    @Volatile private var thread: Thread? = null

    override fun start() {
        running = true
        thread = Thread { runLoop() }.also { it.start() }
    }

    override fun play() {
        playing = true
    }

    override fun pause() {
        playing = false
    }

    override fun isPlaying(): Boolean = playing

    /**
     * 停止并**等待**解码线程退出(其 finally 释放 MediaCodec)再返回。
     * 关键:调用方(如导出/autosync 前的预览拆除)随后会立刻新起一个同分辨率解码器,
     * 若此处不等待释放,部分设备并发 2 个全分辨率硬解会 MediaCodec.start() 失败。
     * 不在解码线程自身调用(无死锁);join 设上限避免万一卡死。
     */
    override fun stop() {
        running = false
        try { thread?.join(800) } catch (_: InterruptedException) {}
        thread = null
    }

    private class Track(val index: Int, val format: MediaFormat)

    private fun runLoop() {
        var extractor: MediaExtractor? = null
        var codec: MediaCodec? = null
        var setupDone = false // start() 成功前为 false:失败=该流硬解吃不下 → 释放干净后触发降级
        try {
            extractor = MediaExtractor()
            extractor.setDataSource(context, uri, null)
            val track = selectVideoTrack(extractor)
            if (track == null) {
                Log.e(TAG, "no video track")
                return
            }
            extractor.selectTrack(track.index)
            if (track.format.containsKey(MediaFormat.KEY_DURATION)) {
                durationUs = track.format.getLong(MediaFormat.KEY_DURATION)
            }
            track.format.setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
            )
            applyLowResourceHints(track.format)
            val c = MediaCodec.createDecoderByType(track.format.getString(MediaFormat.KEY_MIME)!!)
            try {
                c.configure(track.format, null, null, 0)
                c.start()
            } catch (e: Throwable) {
                // configure/start 失败(如 4K 硬解只支持 Surface 输出):**先彻底释放**,避免与降级
                // 的 GPU 解码器并发争用同一硬件解码器(此前 GPU 路失败的根因)。
                try { c.release() } catch (_: Throwable) {}
                throw e
            }
            codec = c
            setupDone = true
            decodeLoop(extractor, codec)
        } catch (t: Throwable) {
            Log.e(TAG, "decode error", t)
            if (!setupDone && running) onStartFailed?.invoke() // 硬解已释放干净,降级解码器无争用
        } finally {
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { extractor?.release() } catch (_: Throwable) {}
        }
    }

    /**
     * 降低解码器资源预留:预览不需要 60fps 实时吞吐。
     * 已实测:本机系统播放器能流畅播 4K60,但我们进程已被 wgpu(Vulkan)+ Flutter 占了图形内存,
     * 高通解码器对 4K**60** 会进高吞吐模式、预留更多内部缓冲 → `start()` 拿不到内存 → −12 NO_MEMORY
     * → 黑屏(同分辨率 4K**30** 因预留更小而幸免,唯一差别就是帧率)。
     * `KEY_OPERATING_RATE=30`(只需 30fps 吞吐)+ `KEY_PRIORITY=1`(非实时/best-effort)
     * 告诉解码器/资源管理器走轻量预留,把内存让给已存在的 wgpu。预览掉到 ~30fps 完全可接受。
     */
    private fun applyLowResourceHints(format: MediaFormat) {
        format.setInteger(MediaFormat.KEY_OPERATING_RATE, 30)
        format.setInteger(MediaFormat.KEY_PRIORITY, 1)
    }

    private fun selectVideoTrack(extractor: MediaExtractor): Track? {
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            if (f.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                return Track(i, f)
            }
        }
        return null
    }

    private fun decodeLoop(extractor: MediaExtractor, codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var anchored = false
        var clockStartNs = 0L
        var basePtsUs = 0L
        var firstShown = false // 是否已渲染过首帧(暂停时也先显示首帧, 而非清屏色, 对齐 iOS)

        while (running) {
            // 拖动 seek(暂停时也要渲染目标帧, 故置于空转判断之前)
            val st = seekTargetUs
            if (st >= 0) {
                codec.flush()
                extractor.seekTo(st, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                inputDone = false
                anchored = false
                firstShown = false // 让暂停分支渲染 seek 后的帧
                seekTargetUs = -1
            }
            // 暂停且首帧已显示 → 空转, 保持当前帧
            if (!playing && firstShown) {
                anchored = false
                try { Thread.sleep(15) } catch (_: InterruptedException) {}
                continue
            }
            // 从头重播(上次播放到结尾后)
            if (seekToStart) {
                codec.flush()
                extractor.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                inputDone = false
                seekToStart = false
                anchored = false
                firstShown = false
            }

            if (!inputDone) {
                inputDone = feedInput(extractor, codec)
            }
            val outIdx = codec.dequeueOutputBuffer(info, TIMEOUT_US)
            if (outIdx < 0) {
                continue
            }
            if (info.size > 0) {
                if (playing) {
                    // 正常播放: 锚定时钟 + 丢帧 + 节流
                    if (!anchored) {
                        clockStartNs = System.nanoTime()
                        basePtsUs = info.presentationTimeUs
                        anchored = true
                    }
                    val target = clockStartNs + (info.presentationTimeUs - basePtsUs) * 1000
                    val behindNs = System.nanoTime() - target
                    if (behindNs > REANCHOR_NS) {
                        // 落后太多(如软解慢于实时):重锚时钟并照常渲染本帧,否则会一路判"迟到"把所有帧
                        // 丢光 → 画面冻住不动。重锚后按"解码能多快就多快"播(慢但会动)。
                        clockStartNs = System.nanoTime()
                        basePtsUs = info.presentationTimeUs
                        renderOutput(codec, outIdx, info.presentationTimeUs)
                        firstShown = true
                    } else if (behindNs <= DROP_THRESHOLD_NS) {
                        // 准时/略早:渲染 + 睡到目标(平滑实时)
                        renderOutput(codec, outIdx, info.presentationTimeUs)
                        firstShown = true
                        val sleepNs = target - System.nanoTime()
                        if (sleepNs > 0) {
                            try { Thread.sleep(sleepNs / 1_000_000, (sleepNs % 1_000_000).toInt()) } catch (_: InterruptedException) {}
                        }
                    }
                    // else: 略落后(DROP_THRESHOLD~REANCHOR)→ 丢本帧追赶(不渲染,末尾统一 release)
                } else {
                    // 暂停且首帧未显示 → 渲染首帧, 让预览有画面(对齐 iOS), 之后保持暂停
                    renderOutput(codec, outIdx, info.presentationTimeUs)
                    firstShown = true
                }
            }
            codec.releaseOutputBuffer(outIdx, false)
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                // 播放完 → 暂停, 标记下次从头, 通知 UI 复位
                playing = false
                seekToStart = true
                inputDone = false
                onEnd?.invoke()
            }
        }
    }

    private fun feedInput(extractor: MediaExtractor, codec: MediaCodec): Boolean {
        val inIdx = codec.dequeueInputBuffer(TIMEOUT_US)
        if (inIdx < 0) {
            return false
        }
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

    /** 取出该输出帧, 打包 YUV 回调上层渲染。 */
    private fun renderOutput(codec: MediaCodec, outIdx: Int, ptsUs: Long) {
        val image = codec.getOutputImage(outIdx) ?: return
        onFrame(YuvPacker.pack(image), ptsUs)
        lastRenderedPtsUs = ptsUs // 记录最近渲染帧,供 rerender() 暂停态重渲
        image.close()
    }
}
