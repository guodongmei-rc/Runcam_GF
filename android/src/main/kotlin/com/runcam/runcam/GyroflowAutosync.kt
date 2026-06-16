package com.runcam.runcam

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.util.Log
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 自动同步运行器(对齐 iOS AutosyncRunner / 官方 Synchronization)。
 *
 * 流程: [GyroflowNative.nativeAutosyncStart] 拿到各同步点的解码范围 → 用 MediaCodec
 * 按范围 seek 解码灰度 Y 帧(可降到处理分辨率)喂给核心 → [GyroflowNative.nativeAutosyncFinish]
 * 阻塞算偏移并应用 + 重算。核心用 Akaze 光流(纯 Rust, 不需 OpenCV)。
 *
 * 全程在后台线程; 进度/结果通过回调抛回(由调用方切主线程)。
 */
class GyroflowAutosync(
    private val ctx: Context,
    private val uri: Uri,
) {
    private val cancelled = AtomicBoolean(false)
    @Volatile private var worker: Thread? = null

    // 进度直接读核心的 on_progress 三元组 [percent, ready, total](对齐官方, finish 期间也可读)。
    private fun prog(): Progress {
        val s = GyroflowNative.nativeAutosyncStat() ?: return Progress(0.0, 0, 0)
        return Progress(s.getOrElse(0) { 0.0 }, s.getOrElse(1) { 0.0 }.toInt(), s.getOrElse(2) { 0.0 }.toInt())
    }

    fun cancel() {
        cancelled.set(true)
        GyroflowNative.nativeAutosyncCancel()
    }

    fun isRunning(): Boolean = worker?.isAlive == true

    /**
     * @param params 同步参数(来自面板)。
     * @param procHeight 处理分辨率高度(<=0 = 原始)。
     * @param onProgress 进度(百分比 + 帧数/fps), 蒙版显示用。
     * @param onDone 成功: median 偏移(ms) + 同步点 [(midMs, offMs)]; 失败: error 非空。
     */
    fun run(
        params: SyncParams,
        procHeight: Int,
        onProgress: (Progress) -> Unit,
        onDone: (medianMs: Double?, points: List<Pair<Double, Double>>, error: String?) -> Unit,
    ) {
        cancelled.set(false)
        val t = Thread {
            var err: String? = null
            var median: Double? = null
            val points = ArrayList<Pair<Double, Double>>()
            try {
                val flat = GyroflowNative.nativeAutosyncStart(
                    params.initialOffsetMs, params.searchSizeSec, params.maxSyncPoints,
                    params.everyNthFrame, params.timePerSyncpointSec, params.ofMethod,
                    params.poseMethod, params.offsetMethod, params.calcInitialFast,
                    params.initialOffsetInv, params.autoSyncPoints, params.syncLpfHz,
                ) ?: DoubleArray(0)
                if (flat.isEmpty()) {
                    throw IllegalStateException("同步初始化失败(无镜头档案/视频参数异常?)")
                }
                val ranges = ArrayList<Pair<Double, Double>>()
                var i = 0
                while (i + 1 < flat.size) {
                    ranges.add(Pair(flat[i], flat[i + 1]))
                    i += 2
                }
                decodeAndFeed(ranges, params.everyNthFrame, procHeight, onProgress)

                if (cancelled.get()) {
                    err = "已取消"
                } else {
                    // finish 阻塞; 另起线程轮询进度
                    val finishing = AtomicBoolean(true)
                    val watcher = Thread {
                        while (finishing.get()) {
                            onProgress(prog())
                            try { Thread.sleep(200) } catch (_: InterruptedException) { break }
                        }
                    }.apply { start() }
                    val res = GyroflowNative.nativeAutosyncFinish() ?: "FAIL: 无返回"
                    finishing.set(false)
                    watcher.interrupt()
                    if (res.startsWith("FAIL")) {
                        err = res.removePrefix("FAIL:").trim()
                    } else {
                        val o = org.json.JSONObject(res)
                        median = o.optDouble("median", 0.0)
                        val arr = o.optJSONArray("points")
                        if (arr != null) {
                            for (k in 0 until arr.length()) {
                                val p = arr.optJSONArray(k) ?: continue
                                points.add(Pair(p.optDouble(0, 0.0), p.optDouble(1, 0.0)))
                            }
                        }
                        onProgress(prog())
                    }
                }
            } catch (e: Throwable) {
                Log.e("GyroflowAutosync", "run failed", e)
                if (!cancelled.get()) {
                    err = e.message ?: "同步异常"
                }
                GyroflowNative.nativeAutosyncCancel()
                GyroflowNative.nativeAutosyncFinish() // 释放 session
            }
            onDone(median, points, if (cancelled.get() && err == null) "已取消" else err)
        }
        worker = t
        t.start()
    }

    // 按范围 seek 解码, 抽 Y 平面(降到处理分辨率)喂给核心。
    private fun decodeAndFeed(
        ranges: List<Pair<Double, Double>>,
        everyNth: Int,
        procHeight: Int,
        onProgress: (Progress) -> Unit,
    ) {
        val extractor = MediaExtractor()
        extractor.setDataSource(ctx, uri, null)
        val track = selectVideoTrack(extractor)
        if (track < 0) {
            throw IllegalStateException("找不到视频轨道")
        }
        extractor.selectTrack(track)
        val format = extractor.getTrackFormat(track)
        val mime = format.getString(MediaFormat.KEY_MIME) ?: throw IllegalStateException("未知编码")
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(format, null, null, 0)
        codec.start()
        val info = MediaCodec.BufferInfo()
        val nth = everyNth.coerceAtLeast(1)
        try {
            for ((rangeIdx, range) in ranges.withIndex()) {
                val (fromMs, toMs) = range
                if (cancelled.get()) break
                // frame_no 每段独立(段内连续、段间隔 100 万): 核心 (n,n+1) 配对只在段内成立,
                // 不会把上一段末帧和下一段首帧错配 → 偏移锚点(@)落在各段中心(对齐官方), 不跨段。
                var localNo = 0
                val fromUs = (fromMs * 1000.0).toLong()
                val toUs = (toMs * 1000.0).toLong()
                extractor.seekTo(fromUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                codec.flush()
                var inputDone = false
                // 先把该范围内的帧解出来缓存(MediaCodec 输出可能是解码序/B 帧乱序)。
                val collected = ArrayList<Pair<Long, Gray>>()
                while (!cancelled.get()) {
                    if (!inputDone) {
                        val inIdx = codec.dequeueInputBuffer(10000)
                        if (inIdx >= 0) {
                            val inBuf = codec.getInputBuffer(inIdx)
                            val size = if (inBuf != null) extractor.readSampleData(inBuf, 0) else -1
                            if (size < 0) {
                                codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                codec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }
                    val outIdx = codec.dequeueOutputBuffer(info, 10000)
                    if (outIdx >= 0) {
                        val pts = info.presentationTimeUs
                        val eos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                        if (pts in fromUs..toUs && info.size > 0) {
                            val image = runCatching { codec.getOutputImage(outIdx) }.getOrNull()
                            if (image != null) {
                                val gray = extractYDownscaled(image, procHeight)
                                image.close()
                                collected.add(Pair(pts, gray))
                            }
                        }
                        codec.releaseOutputBuffer(outIdx, false)
                        if (pts > toUs || eos) break
                    }
                }
                // 关键: 按 pts 升序喂帧, frame_no 顺序递增 —— 保证"时间相邻=帧号相邻",
                // 否则核心 process_detected_frames 会把时间不相邻的帧配对算光流(→ rs-sync bast_param None)。
                collected.sortBy { it.first }
                collected.forEachIndexed { idx, (pts, gray) ->
                    if (cancelled.get()) return@forEachIndexed
                    if (idx % nth == 0) {
                        // 背压: 在飞帧数 <=2(对齐 iOS pending<4)。akaze 内部已并行吃满核,
                        // 同时跑多帧会严重超额订阅 → 单帧墙钟被拖到 10s+。压到 ~2 帧让 akaze 近独占。
                        while (GyroflowNative.nativeAutosyncPending() > 2 && !cancelled.get()) {
                            Thread.sleep(5)
                        }
                        GyroflowNative.nativeAutosyncFeed(pts, rangeIdx * 1_000_000 + localNo, gray.w, gray.h, gray.y)
                        localNo++
                        onProgress(prog())
                    }
                }
            }
        } finally {
            runCatching { codec.stop() }
            runCatching { codec.release() }
            runCatching { extractor.release() }
        }
    }

    private fun selectVideoTrack(extractor: MediaExtractor): Int {
        for (i in 0 until extractor.trackCount) {
            val m = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (m.startsWith("video/")) return i
        }
        return -1
    }

    private class Gray(val y: ByteArray, val w: Int, val h: Int)

    // 抽 Y 平面并(可选)降采样到 procHeight, 输出紧凑 Y(stride=w)。
    private fun extractYDownscaled(image: android.media.Image, procHeight: Int): Gray {
        val plane = image.planes[0]
        val srcW = image.width
        val srcH = image.height
        val rowStride = plane.rowStride
        val pixStride = plane.pixelStride
        val buf: ByteBuffer = plane.buffer
        val dstH = if (procHeight in 1 until srcH) procHeight and 1.inv() else srcH
        val dstW = if (dstH == srcH) srcW else ((srcW * dstH / srcH) and 1.inv())
        val out = ByteArray(dstW * dstH)
        if (dstW == srcW && dstH == srcH && pixStride == 1 && rowStride == srcW) {
            // 紧凑 1:1, 直接整块拷
            buf.position(0)
            buf.get(out, 0, minOf(out.size, buf.remaining()))
        } else {
            for (dy in 0 until dstH) {
                val sy = dy * srcH / dstH
                val rowBase = sy * rowStride
                val oBase = dy * dstW
                for (dx in 0 until dstW) {
                    val sx = dx * srcW / dstW
                    out[oBase + dx] = buf.get(rowBase + sx * pixStride)
                }
            }
        }
        return Gray(out, dstW, dstH)
    }

    /** 同步参数(面板填充)。method 索引对齐核心。 */
    data class SyncParams(
        val initialOffsetMs: Double,
        val searchSizeSec: Double,
        val maxSyncPoints: Int,
        val everyNthFrame: Int,
        val timePerSyncpointSec: Double,
        val ofMethod: Int,        // 0=Akaze 1=OpenCV PyrLK 2=OpenCV DIS
        val poseMethod: Int,      // 0=findEssentialMat 1=Almeida 2=EightPoint 3=Homography
        val offsetMethod: Int,    // 0=rs-sync(卷帘) ...
        val calcInitialFast: Boolean,
        val initialOffsetInv: Boolean,
        val autoSyncPoints: Boolean,
        val syncLpfHz: Double,    // 同步低通滤波器(Hz); 0=关。对齐官方 set_sync_lpf
    )

    /** 进度(蒙版用, 对齐官方 on_progress): percent=核心总进度 0–1; framesDone=ready; framesTotal=total。 */
    data class Progress(val percent: Double, val framesDone: Int, val framesTotal: Int)
}
