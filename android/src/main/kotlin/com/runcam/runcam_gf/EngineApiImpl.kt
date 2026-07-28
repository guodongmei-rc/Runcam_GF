package com.runcam.runcam_gf

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.runcam.runcam.GyroflowAutosync
import com.runcam.runcam.GyroflowNative
import java.io.File
import java.util.concurrent.Executors

/**
 * S4 — Android 引擎转发壳(阶段2)。
 *
 * 实现 Pigeon 生成的 [EngineApi],每方法转发到 [GyroflowNative] 的 nativeXxx(JNI)。
 * 与旧 `open`(startActivity 全屏页)并存、互不影响;不碰解码/预览/导出。
 *
 * 说明 / 已知差异(impl 内归一,见 ~/Desktop/迁移步骤/阶段0+2-执行步骤.md S1 核对表):
 *   - Android 引擎是 .so 内单例,无显式 new/free;createStabilizer 只确保 nativeInit 一次。
 *   - 各 setter 在 native 内已即时应用并重算;recomputeBlocking 仅读回 nativeGetStabInfo。
 *   - setHorizonLock:JNI 已扩到全 9 参(锁定俯仰/自动锁定/转向阈值·平滑·倍数/倾斜加速限制),对齐 iOS。
 *   - openVideo:nativeOpenVideo 返回状态串而非结构体;此处只填 output size,
 *     其余字段留 null(结构化解析留后续)。
 *   - getFovAtTimestamp:JNI 无按 ts 查询,返回当前帧 fov(忽略 timestamp)。
 */
class EngineApiImpl(
    private val appContext: Context,
    private val events: EngineEvents,
) : EngineApi {

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var inited = false

    // MARK: - 生命周期

    override fun createStabilizer() {
        if (!inited) {
            GyroflowNative.nativeInit(appContext)
            inited = true
        }
    }

    override fun freeStabilizer() {
        // .so 内单例,无显式释放;留空(对齐现状)。
    }

    override fun openVideo(uriOrPath: String, callback: (Result<VideoInfo>) -> Unit) {
        worker.execute {
            val status = GyroflowNative.nativeOpenVideo(uriOrPath)
            val ok = status != null && !status.contains("FAIL", true) &&
                !status.contains("✗") && !status.contains("error", true)
            // 在工作线程读音视频信息(MediaExtractor 阻塞);失败时各字段为 null。
            val av = if (ok) readAvInfo(uriOrPath) else AvInfo(null, null, null, null, null)
            // 源尺寸/帧率/帧数/时长:取引擎权威值(对齐 iOS 用 GyroflowVideoInfo,而非 MediaExtractor),
            // 同时保证 width×height 与镜头库自动匹配用的尺寸一致。
            val meta = if (ok) parseOpenStatus(status!!) else OpenMeta(null, null, null, null, null)
            main.post {
                if (!ok) {
                    callback(Result.failure(FlutterError("LOAD_VIDEO_FAILED", status ?: "null", null)))
                    return@post
                }
                val out = runCatching { GyroflowNative.nativeGetOutputSize() }.getOrNull()
                callback(Result.success(VideoInfo(
                    width = meta.width,
                    height = meta.height,
                    outputWidth = out?.getOrNull(0)?.toLong(),
                    outputHeight = out?.getOrNull(1)?.toLong(),
                    fps = meta.fps,
                    durationS = meta.durationS,
                    frameCount = meta.frameCount,
                    // 音视频信息(Android 原生读取);pixelFormat 留 null。失败时各字段保持 null,不影响 openVideo 成功。
                    videoCodec = av.videoCodec,
                    audioCodec = av.audioCodec,
                    audioSampleRate = av.audioSampleRate,
                    rotationDeg = av.rotationDeg,
                    videoBitrate = av.videoBitrate,
                )))
            }
        }
    }

    /** 从 nativeOpenVideo 状态串解析出的视频元数据(对齐 iOS 引擎值)。 */
    private data class OpenMeta(
        val width: Long?,
        val height: Long?,
        val fps: Double?,
        val durationS: Double?,
        val frameCount: Long?,
    )

    /**
     * 解析 nativeOpenVideo 的成功状态串(stab.rs):
     *   "opened {w}x{h}->{ow}x{oh} fps={:.3} frames={fc} gyro=... lens=... ..."
     * 取源尺寸/帧率/帧数;时长按 frames/fps 估算(对齐 Dart `_endUs` 的帧数/帧率口径)。
     * 任一项缺失则留 null(Dart 显示「---」),不影响打开。
     */
    private fun parseOpenStatus(status: String): OpenMeta {
        val wh = Regex("""opened (\d+)x(\d+)""").find(status)?.groupValues
        val w = wh?.getOrNull(1)?.toLongOrNull()
        val h = wh?.getOrNull(2)?.toLongOrNull()
        val fps = Regex("""fps=([\d.]+)""").find(status)?.groupValues?.getOrNull(1)?.toDoubleOrNull()
        val frames = Regex("""frames=(\d+)""").find(status)?.groupValues?.getOrNull(1)?.toLongOrNull()
        val durationS = if (fps != null && fps > 0.0 && frames != null) frames / fps else null
        return OpenMeta(w, h, fps, durationS, frames)
    }

    /** openVideo 成功后读到的音视频信息(用 MediaExtractor,失败字段留 null)。 */
    private data class AvInfo(
        val videoCodec: String?,
        val audioCodec: String?,
        val audioSampleRate: Long?,
        val rotationDeg: Long?,
        val videoBitrate: Long?,
    )

    /**
     * 用 [MediaExtractor] 读 [uriOrPath] 的音视频信息。content:// / file:// 用 Context+Uri,
     * 普通文件路径直接 setDataSource(path)。任何异常都吞掉、对应字段返回 null,绝不抛出。
     */
    private fun readAvInfo(uriOrPath: String): AvInfo {
        var videoCodec: String? = null
        var audioCodec: String? = null
        var audioSampleRate: Long? = null
        var rotationDeg: Long? = null
        var videoBitrate: Long? = null
        var videoTrackIdx = -1          // 视频轨索引(供「实测纯视频码率」回退用)
        var videoDurationUs = -1L       // 视频轨时长(us)
        val extractor = MediaExtractor()
        try {
            if (uriOrPath.startsWith("content://") || uriOrPath.startsWith("file://")) {
                extractor.setDataSource(appContext, Uri.parse(uriOrPath), null)
            } else {
                extractor.setDataSource(uriOrPath)
            }
            for (i in 0 until extractor.trackCount) {
                val fmt = extractor.getTrackFormat(i)
                val mime = fmt.getString(MediaFormat.KEY_MIME) ?: continue
                when {
                    mime.startsWith("video/") && videoCodec == null -> {
                        videoCodec = mapVideoCodec(mime)
                        videoTrackIdx = i
                        videoDurationUs = runCatching {
                            if (fmt.containsKey(MediaFormat.KEY_DURATION)) fmt.getLong(MediaFormat.KEY_DURATION) else -1L
                        }.getOrNull() ?: -1L
                        // 有视频轨即给出旋转角:无 KEY_ROTATION 时取 0(对齐 iOS 显示「0°」而非「---」)。
                        rotationDeg = runCatching {
                            if (fmt.containsKey(MediaFormat.KEY_ROTATION)) fmt.getInteger(MediaFormat.KEY_ROTATION).toLong() else 0L
                        }.getOrNull() ?: 0L
                        // 源视频码率(bit/s),对齐官方默认导出比特率 = 此值/1024/1024。
                        videoBitrate = runCatching {
                            if (fmt.containsKey(MediaFormat.KEY_BIT_RATE)) fmt.getInteger(MediaFormat.KEY_BIT_RATE).toLong() else null
                        }.getOrNull()
                    }
                    mime.startsWith("audio/") && audioCodec == null -> {
                        audioCodec = mapAudioCodec(mime)
                        audioSampleRate = runCatching {
                            if (fmt.containsKey(MediaFormat.KEY_SAMPLE_RATE)) fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE).toLong() else null
                        }.getOrNull()
                    }
                }
            }
            // 对齐 iOS:iOS 用 AVAssetTrack.estimatedDataRate(纯视频轨实测平均码率)。
            // 视频轨无 KEY_BIT_RATE 时,这里走「视频轨样本字节总和 ÷ 时长」实测纯视频码率,
            // 而非整文件码率——后者含音频(Sony RX100VII 为 LPCM,码率很高)与封装开销,会把
            // 默认导出比特率顶高(实测 Android 102 vs iOS 98 即此因)。只读样本大小、不读样本数据。
            if (videoBitrate == null && videoTrackIdx >= 0 && videoDurationUs > 0) {
                videoBitrate = runCatching {
                    extractor.selectTrack(videoTrackIdx)
                    var total = 0L
                    while (true) {
                        val sz = extractor.getSampleSize()
                        if (sz < 0) break
                        total += sz
                        if (!extractor.advance()) break
                    }
                    if (total > 0) total * 8L * 1_000_000L / videoDurationUs else null
                }.getOrNull()
            }
        } catch (e: Throwable) {
            Log.w(TAG, "readAvInfo failed: ${e.message}")
        } finally {
            runCatching { extractor.release() }
        }
        // 兜底:连样本遍历都失败(无时长等)才退回整文件码率(含音频,与 iOS 不完全一致)。
        if (videoBitrate == null) {
            videoBitrate = runCatching {
                val mmr = android.media.MediaMetadataRetriever()
                try {
                    if (uriOrPath.startsWith("content://") || uriOrPath.startsWith("file://")) {
                        mmr.setDataSource(appContext, Uri.parse(uriOrPath))
                    } else {
                        mmr.setDataSource(uriOrPath)
                    }
                    mmr.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toLongOrNull()
                } finally {
                    runCatching { mmr.release() }
                }
            }.getOrNull()
        }
        return AvInfo(videoCodec, audioCodec, audioSampleRate, rotationDeg, videoBitrate)
    }

    private fun mapVideoCodec(mime: String): String = when (mime.lowercase()) {
        "video/avc" -> "H.264"
        "video/hevc" -> "HEVC"
        "video/av01" -> "AV1"
        "video/x-vnd.on2.vp9" -> "VP9"
        "video/x-vnd.on2.vp8" -> "VP8"
        "video/mp4v-es" -> "MPEG-4"
        else -> mime
    }

    private fun mapAudioCodec(mime: String): String = when (mime.lowercase()) {
        "audio/mp4a-latm" -> "AAC"
        "audio/ac3" -> "AC-3"
        "audio/eac3" -> "E-AC-3"
        "audio/opus" -> "Opus"
        "audio/vorbis" -> "Vorbis"
        "audio/mpeg" -> "MP3"
        "audio/raw" -> "PCM"
        else -> mime
    }

    // MARK: - 稳定

    override fun setStabEnabled(enabled: Boolean) { GyroflowNative.nativeSetStabEnabled(enabled) }
    override fun setSmoothingMethod(index: Long) { GyroflowNative.nativeSetSmoothingMethod(index.toInt()) }
    override fun setSmoothingParam(name: String, value: Double) { GyroflowNative.nativeSetSmoothingParam(name, value) }

    override fun setHorizonLock(
        lockPercent: Double, rollDeg: Double, lockPitch: Boolean, pitchDeg: Double,
        automaticLock: Boolean, turnThreshold: Double, turnSmoothingMs: Double,
        turnMultiplier: Double, tiltAccelLimit: Double,
    ) {
        // 全 9 参透传(对齐 iOS):地平线锁定的「锁定俯仰/自动锁定/转向阈值·平滑·倍数/倾斜加速限制」高级项。
        GyroflowNative.nativeSetHorizonLock(
            lockPercent, rollDeg, lockPitch, pitchDeg,
            automaticLock, turnThreshold, turnSmoothingMs, turnMultiplier, tiltAccelLimit,
        )
    }

    // MARK: - 缩放

    override fun setAdaptiveZoom(windowSeconds: Double) { GyroflowNative.nativeSetAdaptiveZoom(windowSeconds) }
    override fun setMaxZoom(percent: Double, iterations: Long) { GyroflowNative.nativeSetMaxZoom(percent, iterations.toInt()) }
    override fun setZoomingMethod(index: Long) { GyroflowNative.nativeSetZoomingMethod(index.toInt()) }
    override fun setLensCorrection(amount: Double) { GyroflowNative.nativeSetLensCorrection(amount) }
    override fun setFov(fov: Double) { GyroflowNative.nativeSetFov(fov) }

    // MARK: - 卷帘 / 速度 / 旋转 / 背景 / 安全区 / 预览分辨率 / 输出尺寸

    override fun setFrameReadoutTime(ms: Double) { GyroflowNative.nativeSetFrameReadoutTime(ms) }
    override fun setFrameReadoutDirection(dir: Long) { GyroflowNative.nativeSetFrameReadoutDirection(dir.toInt()) }
    override fun setVideoSpeed(speed: Double, affectsSmoothing: Boolean, affectsZooming: Boolean, affectsZoomingLimit: Boolean) {
        GyroflowNative.nativeSetVideoSpeed(speed, affectsSmoothing, affectsZooming, affectsZoomingLimit)
    }
    override fun setAdditionalRotation(pitchDeg: Double, yawDeg: Double, rollDeg: Double) {
        GyroflowNative.nativeSetAdditionalRotation(pitchDeg, yawDeg, rollDeg)
    }
    override fun setBackgroundColor(r: Double, g: Double, b: Double, a: Double) {
        GyroflowNative.nativeSetBackgroundColor(r, g, b, a)
    }
    override fun setBackgroundMode(mode: Long) { GyroflowNative.nativeSetBackgroundMode(mode.toInt()) }
    override fun setShowSafeArea(show: Boolean) { GyroflowNative.nativeSetShowSafeArea(show) }
    override fun setShowDetectedFeatures(show: Boolean) { GyroflowNative.nativeSetShowDetectedFeatures(show) }
    override fun setShowOpticalFlow(show: Boolean) { GyroflowNative.nativeSetShowOpticalFlow(show) }
    override fun setPreviewResolution(targetHeight: Long) { GyroflowNative.nativeSetPreviewResolution(targetHeight.toInt()) }
    override fun setOutputSize(width: Long, height: Long) { GyroflowNative.nativeSetOutputSize(width.toInt(), height.toInt()) }
    override fun setOutputSizeExact(width: Long, height: Long) { GyroflowNative.nativeSetOutputSizeExact(width.toInt(), height.toInt()) }

    // 本机该编码格式硬件编码器最大可导出分辨率 [maxW, maxH]。只读查编解码器清单(不实例化编码器,
    // 避免预览占用编解码资源时查询失败),优先取硬件编码器。查不到→规格上限兜底(H.264 4096²/HEVC 8192²)。
    // 供 Dart 导出面板「按当前机型 + 编码格式」过滤输出大小预设。不碰引擎/导出逻辑。
    override fun encoderMaxSize(codecIndex: Long): List<Long> {
        val mime = if (codecIndex == 0L) android.media.MediaFormat.MIMETYPE_VIDEO_AVC
                   else android.media.MediaFormat.MIMETYPE_VIDEO_HEVC
        val fallback = if (codecIndex == 0L) listOf(4096L, 4096L) else listOf(8192L, 8192L)
        return try {
            val infos = android.media.MediaCodecList(android.media.MediaCodecList.REGULAR_CODECS).codecInfos
            fun pick(hwOnly: Boolean): android.media.MediaCodecInfo.VideoCapabilities? {
                for (info in infos) {
                    if (!info.isEncoder) continue
                    if (android.os.Build.VERSION.SDK_INT >= 29 && hwOnly && !info.isHardwareAccelerated) continue
                    if (info.supportedTypes.none { it.equals(mime, ignoreCase = true) }) continue
                    return info.getCapabilitiesForType(mime).videoCapabilities
                }
                return null
            }
            val vc = pick(hwOnly = true) ?: pick(hwOnly = false) ?: return fallback
            listOf(vc.supportedWidths.upper.toLong(), vc.supportedHeights.upper.toLong())
        } catch (_: Throwable) { fallback }
    }

    // MARK: - IMU / 运动数据

    override fun setGyroOffset(offsetMs: Double) { GyroflowNative.nativeSetGyroOffset(offsetMs) }
    override fun setImuLpf(hz: Double) { GyroflowNative.nativeSetImuLpf(hz) }
    override fun setImuMedian(samples: Long) { GyroflowNative.nativeSetImuMedian(samples.toInt()) }
    override fun setImuRotation(pitchDeg: Double, rollDeg: Double, yawDeg: Double) {
        GyroflowNative.nativeSetImuRotation(pitchDeg, rollDeg, yawDeg)
    }
    override fun setImuBias(x: Double, y: Double, z: Double) { GyroflowNative.nativeSetImuBias(x, y, z) }
    override fun setImuOrientation(orientation: String) { GyroflowNative.nativeSetImuOrientation(orientation) }
    override fun setIntegrationMethod(index: Long) { GyroflowNative.nativeSetIntegrationMethod(index.toInt()) }
    override fun setFrameOffset(frames: Long) { GyroflowNative.nativeSetFrameOffset(frames.toInt()) }

    // MARK: - 镜头

    override fun lensSearch(query: String): String = GyroflowNative.nativeLensSearch(query) ?: "[]"
    override fun loadLens(uriOrIdOrJson: String): String = GyroflowNative.nativeLoadLens(uriOrIdOrJson) ?: "{\"ok\":false}"

    /** 当前镜头库版本号(内置库或已安装更新包, 对应 gyroflow/lens_profiles release 号)。 */
    override fun getLensProfileDbVersion(): Long = GyroflowNative.nativeGetLensDbVersion().toLong()

    /** 安装下载的 profiles.cbor.gz 并热重载镜头库。原生验证失败(返回-1)时抛 FlutterError。 */
    override fun installLensProfiles(data: ByteArray): Long {
        val v = GyroflowNative.nativeInstallLensProfiles(data)
        if (v <= 0) throw FlutterError("LENS_INSTALL_FAILED", "profiles.cbor.gz 验证或写入失败", null)
        return v.toLong()
    }

    /**
     * 取镜头档案完整信息。安卓 nativeGetLensInfo 不含 sync_settings(那是独立的
     * nativeGetSyncSettings),但 Dart 的 _fetchLensInfo 期望 sync_settings **内嵌**在此(对齐 iOS)——
     * 否则 lensDoAutosync 恒为 false,打开需自动同步的视频时 autosync 永不触发(陀螺与画面不对齐 →
     * 预览"看起来没防抖")。故此处把 nativeGetSyncSettings 合并进来,补齐与 iOS 一致的契约。
     */
    override fun getLensInfoFull(): String {
        val lensJson = GyroflowNative.nativeGetLensInfo() ?: "{}"
        return try {
            val obj = org.json.JSONObject(lensJson)
            val sync = org.json.JSONObject(GyroflowNative.nativeGetSyncSettings() ?: "{}")
            if (sync.length() > 0) obj.put("sync_settings", sync)
            obj.toString()
        } catch (_: Throwable) {
            lensJson // 解析失败:退回原始镜头信息(不阻断打开)
        }
    }
    override fun loadGyro(uriOrPath: String, loadAllMetadata: Boolean): String =
        GyroflowNative.nativeLoadGyro(uriOrPath, loadAllMetadata) ?: "{\"ok\":false}"
    override fun getGyroInfo(): String = GyroflowNative.nativeGetGyroInfo() ?: "{}"
    override fun folderAccessGranted(folderUrl: String) { GyroflowNative.nativeFolderAccessGranted(folderUrl) }

    // 安卓:nativeLoadGyro 加载 .gcsv 时已在原生层按 camera_id 自动配镜头(stab.rs),
    // GyroflowNative 无独立 autoload JNI → no-op,返回 -2(无可匹配/已有档案,与 FFI 语义一致)。
    override fun autoloadLensForCamera(): Long = -2L

    // MARK: - 查询 / 重算

    override fun recomputeBlocking(callback: (Result<StabInfo>) -> Unit) {
        worker.execute {
            // Android 各 setter 已即时重算;此处只读回稳定信息。
            val a = runCatching { GyroflowNative.nativeGetStabInfo() }.getOrNull()
            // nativeGetStabInfo[3] = get_min_fov()*100(min_fov 的百分数,≤100),不是 max zoom%。
            // minFov 必须与 iOS(gyroflow_get_min_fov,≤1)同义:此处 /100 还原,而非取倒数。
            // 之前误当 max zoom% 取 100/它 → 得到的是 1/min_fov(倒数),导致最大缩放%/HUD/导出尺寸全反。
            val minFovPercent = a?.getOrNull(3) ?: 0.0
            val info = StabInfo(
                maxAnglePitch = a?.getOrNull(0) ?: 0.0,
                maxAngleYaw = a?.getOrNull(1) ?: 0.0,
                maxAngleRoll = a?.getOrNull(2) ?: 0.0,
                minFov = if (minFovPercent > 0.0) minFovPercent / 100.0 else 0.0,
            )
            main.post {
                events.onRecomputeFinished(info) {}
                callback(Result.success(info))
            }
        }
    }

    override fun getVideoMetadata(): String = GyroflowNative.nativeGetVideoMetadata() ?: "{}"
    override fun gyroTimeline(count: Long): List<Double> =
        GyroflowNative.nativeGyroTimeline(count.toInt())?.toList() ?: emptyList()
    override fun quaternionTimeline(count: Long): List<Double> =
        GyroflowNative.nativeQuaternionTimeline(count.toInt())?.toList() ?: emptyList()
    override fun quatsAtTimestamp(timestampUs: Long): List<Double> =
        GyroflowNative.nativeQuatsAtTimestamp(timestampUs)?.toList() ?: emptyList()
    override fun getFovAtTimestamp(timestampUs: Long): Double = GyroflowNative.nativeGetCurrentFov()

    // MARK: - 自动同步(autosync)

    @Volatile private var autosync: GyroflowAutosync? = null

    /**
     * 真移植:复用旧全屏编辑器的 [GyroflowAutosync](com.runcam.runcam)。
     * 它用 nativeAutosyncStart 取各同步点区间 → MediaCodec/MediaExtractor 解灰度 Y 帧 →
     * nativeAutosyncFeed 逐帧喂核心 → nativeAutosyncFinish 内部阻塞算偏移并应用 + 重算(对齐 iOS)。
     * 进度经 [EngineEvents.onAutosyncProgress]、结束经 [EngineEvents.onAutosyncFinished] 回 Dart。
     *
     * 注:Pigeon 暂未透传 syncLpf / 处理分辨率,这里 syncLpfHz=0(关)、procHeight 用默认。
     */
    override fun autosyncStart(
        uriOrPath: String, initialOffsetMs: Double, searchSizeSec: Double,
        maxSyncPoints: Long, everyNthFrame: Long, timePerSyncpointSec: Double,
        ofMethod: Long, poseMethod: Long, offsetMethod: Long,
        calcInitialFast: Boolean, checkNegativeInitialOffset: Boolean, autoSyncPoints: Boolean,
    ) {
        autosync?.cancel()
        val uri = if (uriOrPath.startsWith("content://") || uriOrPath.startsWith("file://")) {
            Uri.parse(uriOrPath)
        } else {
            Uri.fromFile(File(uriOrPath))
        }
        val runner = GyroflowAutosync(appContext, uri)
        autosync = runner
        val params = GyroflowAutosync.SyncParams(
            initialOffsetMs = initialOffsetMs,
            searchSizeSec = searchSizeSec,
            maxSyncPoints = maxSyncPoints.toInt(),
            everyNthFrame = everyNthFrame.toInt(),
            timePerSyncpointSec = timePerSyncpointSec,
            ofMethod = ofMethod.toInt(),
            poseMethod = poseMethod.toInt(),
            offsetMethod = offsetMethod.toInt(),
            calcInitialFast = calcInitialFast,
            initialOffsetInv = checkNegativeInitialOffset,
            autoSyncPoints = autoSyncPoints,
            syncLpfHz = 0.0,
        )
        runner.run(
            params = params,
            procHeight = AUTOSYNC_PROC_HEIGHT,
            onProgress = { p ->
                main.post {
                    events.onAutosyncProgress(p.percent, p.framesDone.toLong(), p.framesTotal.toLong()) {}
                }
            },
            onDone = { median, points, error ->
                // syncPoints 摊平为交错 [mid_ms, off_ms, ...](对齐 Pigeon 约定)。
                val flat = ArrayList<Double>(points.size * 2)
                for ((mid, off) in points) { flat.add(mid); flat.add(off) }
                val ok = error == null
                autosync = null
                main.post {
                    events.onAutosyncFinished(median ?: 0.0, flat, ok) {}
                }
            },
        )
    }

    override fun autosyncCancel() {
        autosync?.cancel()
    }

    private companion object {
        const val TAG = "EngineApiImpl"
        // 自动同步处理分辨率(高度);<=0 = 原始。降到 720 加速 Akaze 光流(对齐旧全屏页默认量级)。
        const val AUTOSYNC_PROC_HEIGHT = 720
    }
}
