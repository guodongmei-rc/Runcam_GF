package com.runcam.runcam

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.util.Log

/**
 * 预览音频播放(对齐 iOS MDK 自带音频输出):用 MediaCodec 解码音轨 → PCM → AudioTrack 播放。
 *
 * 与 [VideoDecoder] 并行、各自独立线程;两者由 [com.runcam.runcam_gf.PreviewController] 同步驱动
 * play/pause/seek/stop。无音轨的视频此类整体为 no-op(静默)。
 *
 * 同步策略(预览够用即可,不追求逐样本对齐,iOS 的 MDK 内部自做精确同步):视频按墙钟节流自走时钟,
 * 音频按 AudioTrack 硬件时钟实时播放;二者在 play() 同时开始、seek 跳到同一时间戳,故唇音基本一致。
 * AudioTrack 缓冲写满即回压(write 返回 0),从而把解码节流到实时速度 —— 音频本身即其时钟。
 */
class AudioPlayer(
    private val context: Context,
    private val uri: Uri,
) {
    private companion object {
        const val TAG = "GyroflowPreview"
        const val TIMEOUT_US = 10_000L
    }

    @Volatile private var running = false
    @Volatile private var playing = false       // 默认暂停,对齐 VideoDecoder
    @Volatile private var seekTargetUs = -1L     // >=0 表示有待处理 seek(绝对微秒)

    fun start() {
        running = true
        Thread { runLoop() }.start()
    }

    fun play() { playing = true }

    fun pause() { playing = false }

    /** 跳到绝对时间戳(微秒),与 [VideoDecoder.seekToUs] 同步调用。 */
    fun seekToUs(us: Long) { seekTargetUs = us.coerceAtLeast(0L) }

    /** 视频放到结尾时调用:音频也回到开头并暂停,下次 play() 两者同时从 0 起。 */
    fun resetToStart() {
        playing = false
        seekToUs(0)
    }

    fun stop() { running = false }

    private fun runLoop() {
        var extractor: MediaExtractor? = null
        var codec: MediaCodec? = null
        var track: AudioTrack? = null
        try {
            extractor = MediaExtractor()
            extractor.setDataSource(context, uri, null)
            val trackIndex = selectAudioTrack(extractor)
            if (trackIndex == null) {
                Log.d(TAG, "no audio track, audio playback skipped")
                return
            }
            extractor.selectTrack(trackIndex)
            val format = extractor.getTrackFormat(trackIndex)
            codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(format, null, null, 0)
            codec.start()
            track = buildAudioTrack(format)
            playLoop(extractor, codec, track)
        } catch (t: Throwable) {
            Log.e(TAG, "audio decode error", t)
        } finally {
            try { track?.pause() } catch (_: Throwable) {}
            try { track?.flush() } catch (_: Throwable) {}
            try { track?.release() } catch (_: Throwable) {}
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { extractor?.release() } catch (_: Throwable) {}
        }
    }

    private fun selectAudioTrack(extractor: MediaExtractor): Int? {
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) return i
        }
        return null
    }

    private fun buildAudioTrack(format: MediaFormat): AudioTrack {
        val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val channelCount =
            if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT))
                format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            else 2
        val channelMask =
            if (channelCount >= 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val minBuf = AudioTrack.getMinBufferSize(sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT)
        val bufSize = (if (minBuf > 0) minBuf else sampleRate * channelCount * 2) * 2
        return AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(channelMask)
                    .build(),
            )
            .setBufferSizeInBytes(bufSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
    }

    private fun playLoop(extractor: MediaExtractor, codec: MediaCodec, track: AudioTrack) {
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var started = false // AudioTrack 是否处于 play() 态

        while (running) {
            // 待处理 seek(拖动跳转 / 结尾复位走 resetToStart→seekToUs(0) 同一路径):
            // 与视频同步跳转,清空已缓冲音频避免残留。
            val st = seekTargetUs
            if (st >= 0) {
                codec.flush()
                extractor.seekTo(st, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                if (started) { track.pause(); started = false }
                track.flush()
                inputDone = false
                seekTargetUs = -1
            }
            // 暂停:停 AudioTrack,空转保持位置
            if (!playing) {
                if (started) { track.pause(); started = false }
                try { Thread.sleep(15) } catch (_: InterruptedException) {}
                continue
            }
            // 播放:确保 AudioTrack 在播
            if (!started) { track.play(); started = true }

            if (!inputDone) {
                val inIdx = codec.dequeueInputBuffer(TIMEOUT_US)
                if (inIdx >= 0) {
                    val ib = codec.getInputBuffer(inIdx)!!
                    val sz = extractor.readSampleData(ib, 0)
                    if (sz < 0) {
                        codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        codec.queueInputBuffer(inIdx, 0, sz, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }

            val outIdx = codec.dequeueOutputBuffer(info, TIMEOUT_US)
            if (outIdx >= 0) {
                if (info.size > 0) {
                    val ob = codec.getOutputBuffer(outIdx)!!
                    ob.position(info.offset)
                    ob.limit(info.offset + info.size)
                    // 非阻塞写 + 回压:缓冲满则短睡重试;随 pause/seek/stop 立即退出,不卡线程。
                    while (ob.hasRemaining() && running && playing && seekTargetUs < 0) {
                        val w = track.write(ob, ob.remaining(), AudioTrack.WRITE_NON_BLOCKING)
                        if (w < 0) break
                        if (w == 0) {
                            try { Thread.sleep(5) } catch (_: InterruptedException) {}
                        }
                    }
                }
                codec.releaseOutputBuffer(outIdx, false)
                // 音频先于视频放完:停喂、空转等待视频 onEnd 触发 resetToStart 复位(见 PreviewController)。
            }
        }
    }
}
