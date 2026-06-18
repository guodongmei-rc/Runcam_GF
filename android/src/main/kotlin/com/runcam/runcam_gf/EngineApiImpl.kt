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
 *   - setHorizonLock:JNI 目前仅 (amount, roll) 两参,advanced 7 参暂不接(留空)。
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
            val av = if (ok) readAvInfo(uriOrPath) else AvInfo(null, null, null, null)
            main.post {
                if (!ok) {
                    callback(Result.failure(FlutterError("LOAD_VIDEO_FAILED", status ?: "null", null)))
                    return@post
                }
                val out = runCatching { GyroflowNative.nativeGetOutputSize() }.getOrNull()
                callback(Result.success(VideoInfo(
                    outputWidth = out?.getOrNull(0)?.toLong(),
                    outputHeight = out?.getOrNull(1)?.toLong(),
                    // 音视频信息(Android 原生读取);pixelFormat 留 null。失败时各字段保持 null,不影响 openVideo 成功。
                    videoCodec = av.videoCodec,
                    audioCodec = av.audioCodec,
                    audioSampleRate = av.audioSampleRate,
                    rotationDeg = av.rotationDeg,
                )))
            }
        }
    }

    /** openVideo 成功后读到的音视频信息(用 MediaExtractor,失败字段留 null)。 */
    private data class AvInfo(
        val videoCodec: String?,
        val audioCodec: String?,
        val audioSampleRate: Long?,
        val rotationDeg: Long?,
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
                        rotationDeg = runCatching {
                            if (fmt.containsKey(MediaFormat.KEY_ROTATION)) fmt.getInteger(MediaFormat.KEY_ROTATION).toLong() else null
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
        } catch (e: Throwable) {
            Log.w(TAG, "readAvInfo failed: ${e.message}")
        } finally {
            runCatching { extractor.release() }
        }
        return AvInfo(videoCodec, audioCodec, audioSampleRate, rotationDeg)
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
        // JNI 仅两参;advanced(lockPitch/automaticLock/turn*/tilt*)暂未接通。
        GyroflowNative.nativeSetHorizonLock(lockPercent, rollDeg)
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
    override fun getLensInfoFull(): String = GyroflowNative.nativeGetLensInfo() ?: "{}"
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
            val zoomPercent = a?.getOrNull(3) ?: 0.0
            val info = StabInfo(
                maxAnglePitch = a?.getOrNull(0) ?: 0.0,
                maxAngleYaw = a?.getOrNull(1) ?: 0.0,
                maxAngleRoll = a?.getOrNull(2) ?: 0.0,
                // iOS 用 minFov;Android 给的是 max zoom%。zoom% = 100/minFov ⇒ minFov = 100/zoom%。
                minFov = if (zoomPercent > 0.0) 100.0 / zoomPercent else 0.0,
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
