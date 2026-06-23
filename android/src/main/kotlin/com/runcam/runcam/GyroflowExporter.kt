package com.runcam.runcam

import android.content.ContentValues
import android.content.Context
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import java.io.File
import java.nio.ByteBuffer

/**
 * 导出: 逐帧解码源视频 → native 去畸变+稳定 → 回读 I420 → MediaCodec 编码(H.264/HEVC)
 * → MediaMuxer 封装(视频 + 原音频透传)→ 存到相册(Movies/Gyroflow)。
 *
 * 对齐 iOS: AVAssetReader 解码 → 稳定 → AVAssetWriter 编码 → PHPhotoLibrary 存相册。
 * 安卓无硬件 ProRes, 仅 H.264 / H.265。稳定帧经"像素回读"(nativeRenderFrameI420)取回。
 */
class GyroflowExporter(
    private val context: Context,
    private val source: Uri,
) {
    data class Settings(
        val codecIndex: Int,     // 0=H.264/AVC, 1=H.265/HEVC
        val outW: Int,
        val outH: Int,
        val bitrateMbps: Int,
        val exportAudio: Boolean,
        val fileName: String = "",       // 输出文件名(导出面板「输出路径」; 空白用时间戳兜底)
        val exportDirUri: String? = null, // 用户选定的导出存储目录(SAF tree uri; null=默认存相册)
        val trimStartUs: Long = 0L,      // 裁剪起点(µs); 0=从头
        val trimEndUs: Long = 0L,        // 裁剪终点(µs); 0=到结尾
    )

    /** 导出进度统计(对齐官方浮层): 当前帧/总帧、导出速度、已耗时、预计剩余、百分比。 */
    data class Progress(
        val frame: Int,
        val total: Int,
        val fps: Float,
        val elapsedSec: Float,
        val remainingSec: Float,
        val percent: Float,
    )

    companion object {
        private const val TAG = "GyroflowExport"
        private const val TIMEOUT_US = 10_000L
        private const val QUEUE_CAPACITY = 3 // 流水线队列(控内存:高分辨率 I420 单帧大)

        /**
         * 目标位置(所选目录或相册)查重后的最终文件名(对齐官方 App.qml:738-748
         * renameOutput): 已有同名 → _1.._999 自增(已带 _N 后缀则替换); 无同名原样返回。
         * 输入框提交查重与导出落盘共用。
         */
        fun uniqueExportName(context: Context, name: String, exportDirUri: String?): String {
            val exists: (String) -> Boolean = when {
                exportDirUri != null -> {
                    val tree = Uri.parse(exportDirUri)
                    val children = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(
                        tree, android.provider.DocumentsContract.getTreeDocumentId(tree))
                    val existing = HashSet<String>()
                    try {
                        context.contentResolver.query(children,
                            arrayOf(android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                            null, null, null)?.use { c ->
                            while (c.moveToNext()) c.getString(0)?.let { existing.add(it) }
                        }
                    } catch (_: Throwable) {}
                    existing::contains
                }
                Build.VERSION.SDK_INT >= 29 -> {
                    val existing = HashSet<String>()
                    try {
                        context.contentResolver.query(MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                            arrayOf(MediaStore.Video.Media.DISPLAY_NAME),
                            "${MediaStore.Video.Media.RELATIVE_PATH} LIKE ?",
                            arrayOf("%${Environment.DIRECTORY_MOVIES}/Gyroflow%"), null)?.use { c ->
                            while (c.moveToNext()) c.getString(0)?.let { existing.add(it) }
                        }
                    } catch (_: Throwable) {}
                    existing::contains
                }
                else -> {
                    val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES), "Gyroflow")
                    ({ n: String -> File(dir, n).exists() })
                }
            }
            if (!exists(name)) return name
            var newName = name
            for (i in 1 until 1000) {
                newName = name.replace(Regex("(_\\d+)?(\\.[A-Za-z0-9]+)$"), "_${i}\$2")
                if (!exists(newName)) break
            }
            return newName
        }
    }

    @Volatile private var cancelled = false
    fun cancel() { cancelled = true }

    /** 后台线程执行。onProgress(0..1) 在导出线程回调; onDone(uri, err) 同理(err!=null 表失败)。 */
    fun run(s: Settings, onProgress: (Progress) -> Unit, onDone: (Uri?, String?) -> Unit) {
        Thread {
            var result: Uri? = null
            var err: String? = null
            GyroflowNative.nativeSetExportMode(true) // 导出期间只渲染供回读, 不上屏(预览不"动" + 更快)
            try {
                result = export(s, onProgress)
            } catch (t: Throwable) {
                Log.e(TAG, "export failed", t)
                err = t.message ?: t.toString()
            } finally {
                GyroflowNative.nativeSetExportMode(false)
                GyroflowNative.nativeSetExportTarget(0, 0) // 关掉放大, 预览回读恢复正常
            }
            // 预览输出尺寸的恢复由宿主在 onDone 里做(applyExportPreviewAspect)
            onDone(result, err)
        }.start()
    }

    private fun export(s: Settings, onProgress: (Progress) -> Unit): Uri {
        // 源视频信息: 帧率 / 时长 / 旋转
        val vExtractor = MediaExtractor()
        vExtractor.setDataSource(context, source, null)
        val vTrackIdx = firstTrack(vExtractor, "video/") ?: error("无视频轨")
        val vFormat = vExtractor.getTrackFormat(vTrackIdx)
        var durationUs = if (vFormat.containsKey(MediaFormat.KEY_DURATION)) vFormat.getLong(MediaFormat.KEY_DURATION) else 0L
        if (durationUs <= 0) {
            // 轨道无时长 → 用 MediaMetadataRetriever 兜底, 否则进度算不出来(恒为 0)
            try {
                val mmr = android.media.MediaMetadataRetriever()
                mmr.setDataSource(context, source)
                durationUs = (mmr.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L) * 1000
                mmr.release()
            } catch (_: Throwable) {}
        }
        val fps = if (vFormat.containsKey(MediaFormat.KEY_FRAME_RATE)) vFormat.getInteger(MediaFormat.KEY_FRAME_RATE) else 30

        // ── 裁剪区间(µs): 导出仅渲染 [effStart, effEnd] ──
        // start>0 → seek 到前一个关键帧解码、丢弃起点前帧; end>0 且 <时长 → 越过终点即停。
        // 输出视频/音频 PTS 都以 effStart 为基准 rebase 到 ~0(A/V 保持同步)。
        val effStart = s.trimStartUs.coerceAtLeast(0L)
        val hasEndTrim = s.trimEndUs > 0L && (durationUs <= 0L || s.trimEndUs < durationUs)
        val effEnd = if (hasEndTrim) s.trimEndUs else Long.MAX_VALUE
        val trimmed = effStart > 0L || hasEndTrim
        val endForCount = if (hasEndTrim) s.trimEndUs else durationUs
        val trimDurUs = (endForCount - effStart).coerceAtLeast(0L)

        // 对齐官方: 稳定用夹后尺寸(取景固定, 与预览一致), 回读时 GPU 放大到目标分辨率编码。
        val outW = s.outW and 1.inv()
        val outH = s.outH and 1.inv()
        GyroflowNative.nativeSetOutputSize(s.outW, s.outH)   // 稳定: 夹到源内 → 取景固定
        GyroflowNative.nativeSetExportTarget(outW, outH)     // 回读: 放大到用户选的尺寸(如 8K)

        // 编码器
        val mime = if (s.codecIndex == 0) MediaFormat.MIMETYPE_VIDEO_AVC else MediaFormat.MIMETYPE_VIDEO_HEVC
        val encFormat = MediaFormat.createVideoFormat(mime, outW, outH).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            val bps = (if (s.bitrateMbps > 0) s.bitrateMbps else 64) * 1_000_000
            setInteger(MediaFormat.KEY_BIT_RATE, bps)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1) // 1s 一个关键帧
        }
        val encoder = MediaCodec.createEncoderByType(mime)
        encoder.configure(encFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        encoder.start()

        // 解码器
        vExtractor.selectTrack(vTrackIdx)
        // 裁剪起点: seek 到 ≤effStart 的关键帧(解码须从关键帧起; 区间前的帧在入队时丢弃)。
        if (effStart > 0L) vExtractor.seekTo(effStart, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        vFormat.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
        val decoder = MediaCodec.createDecoderByType(vFormat.getString(MediaFormat.KEY_MIME)!!)
        decoder.configure(vFormat, null, null, 0)
        decoder.start()

        // 音频透传(可选): 独立 extractor, 压缩样本直接复制, 不重编码
        var aExtractor: MediaExtractor? = null
        var aFormat: MediaFormat? = null
        if (s.exportAudio) {
            val ae = MediaExtractor()
            ae.setDataSource(context, source, null)
            val aIdx = firstTrack(ae, "audio/")
            if (aIdx != null) {
                ae.selectTrack(aIdx)
                aFormat = ae.getTrackFormat(aIdx)
                aExtractor = ae
            } else {
                ae.release()
            }
        }

        // 输出文件(相册) + muxer
        val (outUri, muxer, finalize) = openMuxer(s.fileName, s.exportDirUri)

        var videoTrack = -1
        var audioTrack = -1
        var muxerStarted = false

        val bufInfo = MediaCodec.BufferInfo() // 编码器输出,仅消费者(本)线程用
        var encodeDone = false

        fun drainEncoder(endOfStream: Boolean) {
            while (true) {
                val idx = encoder.dequeueOutputBuffer(bufInfo, TIMEOUT_US)
                when {
                    idx == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!endOfStream) return else { /* 等 EOS */ }
                    idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        check(videoTrack < 0) { "格式重复变更" }
                        videoTrack = muxer.addTrack(encoder.outputFormat)
                        aFormat?.let { audioTrack = muxer.addTrack(it) }
                        muxer.start()
                        muxerStarted = true
                    }
                    idx >= 0 -> {
                        val outBuf = encoder.getOutputBuffer(idx)!!
                        if (bufInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) bufInfo.size = 0
                        if (bufInfo.size > 0 && muxerStarted) {
                            outBuf.position(bufInfo.offset)
                            outBuf.limit(bufInfo.offset + bufInfo.size)
                            muxer.writeSampleData(videoTrack, outBuf, bufInfo)
                        }
                        encoder.releaseOutputBuffer(idx, false)
                        if (bufInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) { encodeDone = true; return }
                    }
                }
                if (idx == MediaCodec.INFO_TRY_AGAIN_LATER && endOfStream) continue
            }
        }

        // 进度统计: 起始时间 + 总帧数(对齐官方浮层的 帧数/fps/耗时/剩余)
        val startNs = System.nanoTime()
        val totalFrames = if (trimDurUs > 0) Math.round(trimDurUs / 1e6 * fps).toInt() else 0

        // ── 双线程流水线:生产者(解码+打包+稳定+回读)→ 有界队列 → 消费者(本线程:编码+封装)──
        // 让"每帧 GPU 回读阻塞"与"上一帧编码"重叠;引擎(nativeRenderFrameI420)只在生产者单线程调用,
        // 编码器/muxer 只在消费者线程,互不共享。取消/出错/EOS 经 原子量 + 哨兵 + 带超时入/出队,无死锁。
        class EncFrame(val i420: ByteArray, val ptsUs: Long, val eos: Boolean)
        val queue = java.util.concurrent.ArrayBlockingQueue<EncFrame>(QUEUE_CAPACITY)
        val producerError = java.util.concurrent.atomic.AtomicReference<Throwable?>(null)
        val consumerStopped = java.util.concurrent.atomic.AtomicBoolean(false)
        val MS = java.util.concurrent.TimeUnit.MILLISECONDS

        val producer = Thread {
            val decInfo = MediaCodec.BufferInfo()
            var inputDone = false
            var decodeDone = false
            var tRender = 0L; var tFrames = 0L
            var prevPts = -1L // 流水线滞后一帧:nativeRenderFrameI420 返回的是上一帧 I420,配上一帧 pts
            try {
                while (!decodeDone) {
                    if (cancelled) throw RuntimeException("已取消")
                    if (!inputDone) {
                        val inIdx = decoder.dequeueInputBuffer(TIMEOUT_US)
                        if (inIdx >= 0) {
                            val ib = decoder.getInputBuffer(inIdx)!!
                            val sz = vExtractor.readSampleData(ib, 0)
                            if (sz < 0) {
                                decoder.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                decoder.queueInputBuffer(inIdx, 0, sz, vExtractor.sampleTime, 0)
                                vExtractor.advance()
                            }
                        }
                    }
                    val outIdx = decoder.dequeueOutputBuffer(decInfo, TIMEOUT_US)
                    if (outIdx >= 0) {
                        val eos = decInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        if (decInfo.size > 0) {
                            val image = decoder.getOutputImage(outIdx)
                            if (image != null) {
                                val f = YuvPacker.pack(image)
                                image.close()
                                val ptsUs = decInfo.presentationTimeUs
                                val t1 = System.nanoTime()
                                val i420 = GyroflowNative.nativeRenderFrameI420(f.y, f.u, f.v, f.width, f.height, ptsUs)
                                tRender += System.nanoTime() - t1
                                // 返回的是上一帧的 I420(滞后一帧)→ 用上一帧的 pts 入队;首帧 i420 为空跳过。
                                // 裁剪:仅区间内的帧入队(prevPts ∈ [effStart, effEnd]),输出 pts 以 effStart rebase 到 ~0。
                                if (i420.isNotEmpty() && prevPts >= effStart && prevPts <= effEnd) {
                                    while (!queue.offer(EncFrame(i420, prevPts - effStart, false), 50, MS)) {
                                        if (cancelled || consumerStopped.get()) throw RuntimeException("已取消")
                                    }
                                    tFrames++
                                    if (tFrames % 60 == 0L) {
                                        Log.d(TAG, "export avg ms/帧: render(稳定+回读)=%.1f (编码已并行)".format(tRender / tFrames / 1e6))
                                    }
                                    val elapsed = (System.nanoTime() - startNs) / 1e9f
                                    val efps = if (elapsed > 0f) tFrames / elapsed else 0f
                                    val pct = when {
                                        totalFrames > 0 -> tFrames.toFloat() / totalFrames
                                        durationUs > 0 -> ptsUs.toFloat() / durationUs
                                        else -> 0f
                                    }.coerceIn(0f, 1f)
                                    val remain = if (efps > 0f && totalFrames > 0) ((totalFrames - tFrames) / efps).coerceAtLeast(0f) else 0f
                                    onProgress(Progress(tFrames.toInt(), totalFrames, efps, elapsed, remain, pct))
                                }
                                prevPts = ptsUs
                                // 越过裁剪终点:最后一个区间内帧已入队(滞后一帧),停止解码。
                                if (trimmed && ptsUs > effEnd) decodeDone = true
                            }
                        }
                        decoder.releaseOutputBuffer(outIdx, false)
                        if (eos) decodeDone = true
                    }
                }
                // 排空流水线滞留的最后一帧:总要调用 flush 清空引擎内部 lag,但仅区间内才入队(rebase)。
                val last = GyroflowNative.nativeRenderFlushI420()
                if (last.isNotEmpty() && prevPts >= effStart && prevPts <= effEnd) {
                    while (!queue.offer(EncFrame(last, prevPts - effStart, false), 50, MS)) {
                        if (cancelled || consumerStopped.get()) throw RuntimeException("已取消")
                    }
                }
            } catch (t: Throwable) {
                producerError.set(t)
            } finally {
                runCatching { queue.offer(EncFrame(ByteArray(0), 0, true), 300, MS) } // EOS 哨兵
            }
        }
        producer.start()

        // 消费者(本线程):取 I420 → 编码 → 封装
        try {
            while (!encodeDone) {
                if (cancelled) throw RuntimeException("已取消")
                producerError.get()?.let { throw it }
                val fr = queue.poll(50, MS) ?: continue
                if (fr.eos) {
                    var sent = false
                    while (!encodeDone) {
                        if (!sent) {
                            val inIdx = encoder.dequeueInputBuffer(TIMEOUT_US)
                            if (inIdx >= 0) {
                                encoder.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                sent = true
                            }
                        }
                        drainEncoder(sent)
                    }
                    break
                }
                feedEncoder(encoder, fr.i420, outW, outH, fr.ptsUs) { drainEncoder(false) }
                drainEncoder(false)
            }
        } finally {
            consumerStopped.set(true)
            producer.join(3000)
        }
        producerError.get()?.let { throw it }

        // 音频透传: 把源音频压缩样本复制进 muxer
        if (aExtractor != null && audioTrack >= 0 && muxerStarted) {
            copyAudio(aExtractor, muxer, audioTrack, effStart, effEnd)
        }

        // 收尾
        try { muxer.stop() } catch (_: Throwable) {}
        muxer.release()
        decoder.stop(); decoder.release()
        encoder.stop(); encoder.release()
        vExtractor.release()
        aExtractor?.release()
        finalize() // MediaStore: 清 IS_PENDING / 旧版: 媒体扫描
        return outUri
    }

    // ── 编码器输入: I420 → getInputImage(尊重 plane stride) ──
    private fun feedEncoder(encoder: MediaCodec, i420: ByteArray, w: Int, h: Int, ptsUs: Long, drain: () -> Unit) {
        while (true) {
            val inIdx = encoder.dequeueInputBuffer(TIMEOUT_US)
            if (inIdx >= 0) {
                val image = encoder.getInputImage(inIdx)
                if (image != null) {
                    fillImageFromI420(image, i420, w, h)
                }
                encoder.queueInputBuffer(inIdx, 0, w * h * 3 / 2, ptsUs, 0)
                return
            }
            drain() // 输入暂时不可用 → 先排空输出, 避免死锁
        }
    }

    private fun fillImageFromI420(image: Image, i420: ByteArray, w: Int, h: Int) {
        val cw = (w + 1) / 2
        val ch = (h + 1) / 2
        copyToPlane(image.planes[0], i420, 0, w, h, w)
        copyToPlane(image.planes[1], i420, w * h, cw, ch, cw)
        copyToPlane(image.planes[2], i420, w * h + cw * ch, cw, ch, cw)
    }

    /** 把紧凑源平面(srcStride=w)写入 Image.Plane(尊重其 rowStride / pixelStride, 兼容 NV12/I420)。 */
    private fun copyToPlane(plane: Image.Plane, src: ByteArray, srcOff: Int, w: Int, h: Int, srcStride: Int) {
        val buf: ByteBuffer = plane.buffer
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        if (pixelStride == 1) {
            val rowTmp = ByteArray(w)
            for (r in 0 until h) {
                buf.position(r * rowStride)
                System.arraycopy(src, srcOff + r * srcStride, rowTmp, 0, w)
                buf.put(rowTmp, 0, w)
            }
        } else {
            // 交错半平面(NV12/NV21 的 U/V 共用缓冲): 整行「读-改-写」——读出整行(保留交错的另一
            // 通道字节), 只改本通道 stride 位, 再写回。一次 get + 一次 put/行, 既快又不覆盖另一通道。
            val rowLen = (w - 1) * pixelStride + 1
            val tmp = ByteArray(rowLen)
            for (r in 0 until h) {
                val pos = r * rowStride
                buf.position(pos)
                val n = minOf(rowLen, buf.remaining())
                buf.get(tmp, 0, n)
                val srcRow = srcOff + r * srcStride
                var c = 0
                while (c < w && c * pixelStride < n) { tmp[c * pixelStride] = src[srcRow + c]; c++ }
                buf.position(pos)
                buf.put(tmp, 0, n)
            }
        }
    }

    // 音频透传(可裁剪): seek 到起点关键帧 → 丢弃起点前样本、越过终点即停 → PTS 以 startUs rebase。
    private fun copyAudio(
        extractor: MediaExtractor, muxer: MediaMuxer, track: Int, startUs: Long, endUs: Long,
    ) {
        if (startUs > 0L) extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
        val maxChunk = 256 * 1024
        val buffer = ByteBuffer.allocate(maxChunk)
        val info = MediaCodec.BufferInfo()
        while (!cancelled) {
            buffer.clear()
            val sz = extractor.readSampleData(buffer, 0)
            if (sz < 0) break
            val sampleTime = extractor.sampleTime
            if (sampleTime > endUs) break          // 越过裁剪终点
            if (sampleTime >= startUs) {           // seek 可能落到更早关键帧 → 丢弃起点前
                info.offset = 0
                info.size = sz
                info.presentationTimeUs = sampleTime - startUs
                info.flags = if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0)
                    MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                muxer.writeSampleData(track, buffer, info)
            }
            extractor.advance()
        }
    }

    private fun firstTrack(extractor: MediaExtractor, prefix: String): Int? {
        for (i in 0 until extractor.trackCount) {
            if (extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?.startsWith(prefix) == true) return i
        }
        return null
    }

    // ── 输出落盘 ──
    // 返回 (输出 Uri, muxer, 收尾闭包)。
    // exportDirUri 非空 → 写入用户选定目录(SAF createDocument, 对齐官方导出到所选目录);
    // 空 → 默认相册: 29+ 走 MediaStore(Movies/Gyroflow);26–28 写公共 Movies 后扫描。
    private fun openMuxer(fileName: String, exportDirUri: String?): Triple<Uri, MediaMuxer, () -> Unit> {
        val ext = "mp4" // H.264/HEVC 均封 mp4
        // 文件名取「输出路径」输入框(对齐官方 OutputPathField): 清掉路径分隔符防穿越,
        // 扩展名强制 .mp4; 空白时兜底时间戳名。
        val sanitized = fileName.replace("/", "_").trim()
        val name = when {
            sanitized.isEmpty() -> "Gyroflow_${System.currentTimeMillis()}.$ext"
            sanitized.lowercase().endsWith(".$ext") -> sanitized
            else -> "${sanitized.substringBeforeLast('.', sanitized)}.$ext"
        }
        // 同名冲突自动 _X 改名(对齐官方 App.qml:738-748 renameOutput): 与输入框
        // 提交时共用一份查重逻辑(uniqueExportName)。
        val finalName = uniqueExportName(context, name, exportDirUri)
        if (exportDirUri != null) {
            val tree = Uri.parse(exportDirUri)
            val parentDoc = android.provider.DocumentsContract.buildDocumentUriUsingTree(
                tree, android.provider.DocumentsContract.getTreeDocumentId(tree))
            val fileUri = android.provider.DocumentsContract.createDocument(
                context.contentResolver, parentDoc, "video/mp4", finalName)
                ?: error("无法在所选目录创建文件")
            val pfd = context.contentResolver.openFileDescriptor(fileUri, "rw") ?: error("无法打开输出")
            val muxer = MediaMuxer(pfd.fileDescriptor, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val finalize = {
                try { pfd.close() } catch (_: Throwable) {}
                Unit
            }
            return Triple(fileUri, muxer, finalize)
        }
        if (Build.VERSION.SDK_INT >= 29) {
            val resolver = context.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, finalName)
                put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/Gyroflow")
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
                ?: error("无法创建相册条目")
            val pfd = resolver.openFileDescriptor(uri, "rw") ?: error("无法打开输出")
            val muxer = MediaMuxer(pfd.fileDescriptor, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val finalize = {
                try { pfd.close() } catch (_: Throwable) {}
                val v = ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }
                resolver.update(uri, v, null, null)
                Unit
            }
            return Triple(uri, muxer, finalize)
        } else {
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES), "Gyroflow")
            dir.mkdirs()
            val file = File(dir, finalName)
            val muxer = MediaMuxer(file.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val finalize = {
                MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), arrayOf("video/mp4"), null)
            }
            return Triple(Uri.fromFile(file), muxer, finalize)
        }
    }

}
