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

        val bufInfo = MediaCodec.BufferInfo()
        var inputDone = false
        var decodeDone = false
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

        // 分段计时累加器(定位导出耗时分布)
        var tPack = 0L; var tRender = 0L; var tFeed = 0L; var tFrames = 0L
        // 进度统计: 起始时间 + 总帧数(对齐官方浮层的 帧数/fps/耗时/剩余)
        val startNs = System.nanoTime()
        val totalFrames = if (durationUs > 0) Math.round(durationUs / 1e6 * fps).toInt() else 0

        // 解码 → 稳定 → 编码 主循环(最快速度, 不按实时节流)
        while (!encodeDone) {
            if (cancelled) throw RuntimeException("已取消")

            // 喂解码器输入
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

            // 取解码输出帧 → 稳定 → 编码
            if (!decodeDone) {
                val outIdx = decoder.dequeueOutputBuffer(bufInfo, TIMEOUT_US)
                if (outIdx >= 0) {
                    val eos = bufInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    if (bufInfo.size > 0) {
                        val image = decoder.getOutputImage(outIdx)
                        if (image != null) {
                            val t0 = System.nanoTime()
                            val f = YuvPacker.pack(image)
                            image.close()
                            val t1 = System.nanoTime()
                            val ptsUs = bufInfo.presentationTimeUs
                            val i420 = GyroflowNative.nativeRenderFrameI420(f.y, f.u, f.v, f.width, f.height, ptsUs)
                            val t2 = System.nanoTime()
                            if (i420.isNotEmpty()) {
                                feedEncoder(encoder, i420, outW, outH, ptsUs) { drainEncoder(false) }
                            }
                            val t3 = System.nanoTime()
                            // 分段计时(累计平均, 每 60 帧打一行)→ 定位真正的耗时段
                            tPack += t1 - t0; tRender += t2 - t1; tFeed += t3 - t2; tFrames++
                            if (tFrames % 60 == 0L) {
                                Log.d(TAG, "export avg ms/帧: pack=%.1f render(native:稳定+回读)=%.1f feed(编码)=%.1f"
                                    .format(tPack / tFrames / 1e6, tRender / tFrames / 1e6, tFeed / tFrames / 1e6))
                            }
                            // 进度统计(帧数/导出fps/耗时/剩余)→ 浮层显示
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
                    }
                    decoder.releaseOutputBuffer(outIdx, false)
                    if (eos) decodeDone = true
                }
            }

            // ByteBuffer 输入的编码器: 解码结束后送一个 EOS 输入包并排空到结束
            if (decodeDone) {
                val inIdx = encoder.dequeueInputBuffer(TIMEOUT_US)
                if (inIdx >= 0) {
                    encoder.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    drainEncoder(true)
                } else {
                    drainEncoder(false) // 暂无输入 buffer, 先排空输出避免死锁
                }
            } else {
                drainEncoder(false)
            }
        }

        // 音频透传: 把源音频压缩样本复制进 muxer
        if (aExtractor != null && audioTrack >= 0 && muxerStarted) {
            copyAudio(aExtractor, muxer, audioTrack)
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

    private fun copyAudio(extractor: MediaExtractor, muxer: MediaMuxer, track: Int) {
        val maxChunk = 256 * 1024
        val buffer = ByteBuffer.allocate(maxChunk)
        val info = MediaCodec.BufferInfo()
        while (!cancelled) {
            buffer.clear()
            val sz = extractor.readSampleData(buffer, 0)
            if (sz < 0) break
            info.offset = 0
            info.size = sz
            info.presentationTimeUs = extractor.sampleTime
            info.flags = if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0)
                MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
            muxer.writeSampleData(track, buffer, info)
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
