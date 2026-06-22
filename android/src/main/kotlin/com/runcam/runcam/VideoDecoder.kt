package com.runcam.runcam

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.util.Log

/**
 * 用 MediaCodec 解码视频(系统选择器返回的 content URI), 每帧回调紧凑 YUV 帧 + 时间戳(微秒)。
 * 支持播放/暂停: 默认暂停, 须手动 play(); 播放到结尾自动暂停(回调 onEnd), 再 play() 从头播。
 */
class VideoDecoder(
    private val context: Context,
    private val uri: Uri,
    private val onFrame: (YuvPacker.Frame, Long) -> Unit,
) {
    private companion object {
        const val TAG = "GyroflowPreview"
        const val TIMEOUT_US = 10_000L
        const val DROP_THRESHOLD_NS = 15_000_000L // 落后超过 ~15ms 即丢帧
    }

    /** 播放到结尾时回调(在解码线程), UI 据此把按钮复位为"播放"。 */
    var onEnd: (() -> Unit)? = null

    @Volatile private var running = false
    @Volatile private var playing = false   // 默认暂停
    @Volatile private var seekToStart = false
    @Volatile private var seekTargetUs = -1L // >=0 表示有待处理 seek
    @Volatile private var durationUs = 0L
    @Volatile private var lastRenderedPtsUs = -1L // 最近渲染帧的 pts,供 rerender() 暂停态重渲

    /** 跳到进度 0.0–1.0(陀螺时间轴拖动用)。暂停时也会渲染目标帧。 */
    fun seekTo(progress: Double) {
        if (durationUs > 0L) {
            seekTargetUs = (progress.coerceIn(0.0, 1.0) * durationUs).toLong()
        }
    }

    /** 跳到绝对时间戳(微秒)。供 PreviewApi.seekTo 直接用,无需先知时长。暂停时也渲染目标帧。 */
    fun seekToUs(us: Long) {
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
    fun rerender() {
        // 已有待处理 seek 时绝不覆盖:暂停态拖 seek 时 Dart 紧接着会 renderOnce→rerender,
        // 若覆盖 seekTargetUs 会把目标改回上一帧 → 画面不动。
        if (seekTargetUs >= 0L) return
        val t = lastRenderedPtsUs
        if (t >= 0L) seekTargetUs = t
    }

    fun start() {
        running = true
        Thread { runLoop() }.start()
    }

    fun play() {
        playing = true
    }

    fun pause() {
        playing = false
    }

    fun isPlaying(): Boolean = playing

    fun stop() {
        running = false
    }

    private class Track(val index: Int, val format: MediaFormat)

    private fun runLoop() {
        var extractor: MediaExtractor? = null
        var codec: MediaCodec? = null
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
            codec = MediaCodec.createDecoderByType(track.format.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(track.format, null, null, 0)
            codec.start()
            decodeLoop(extractor, codec)
        } catch (t: Throwable) {
            Log.e(TAG, "decode error", t)
        } finally {
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { extractor?.release() } catch (_: Throwable) {}
        }
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
                    if (System.nanoTime() - target <= DROP_THRESHOLD_NS) {
                        renderOutput(codec, outIdx, info.presentationTimeUs)
                        firstShown = true
                        val sleepNs = target - System.nanoTime()
                        if (sleepNs > 0) {
                            try { Thread.sleep(sleepNs / 1_000_000, (sleepNs % 1_000_000).toInt()) } catch (_: InterruptedException) {}
                        }
                    }
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
