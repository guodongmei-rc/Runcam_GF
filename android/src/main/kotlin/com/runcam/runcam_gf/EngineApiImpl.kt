package com.runcam.runcam_gf

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.runcam.runcam.GyroflowNative
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
            main.post {
                if (!ok) {
                    callback(Result.failure(FlutterError("LOAD_VIDEO_FAILED", status ?: "null", null)))
                    return@post
                }
                val out = runCatching { GyroflowNative.nativeGetOutputSize() }.getOrNull()
                callback(Result.success(VideoInfo(
                    outputWidth = out?.getOrNull(0)?.toLong(),
                    outputHeight = out?.getOrNull(1)?.toLong(),
                )))
            }
        }
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
    override fun setImuOrientation(orientation: String) { GyroflowNative.nativeSetImuOrientation(orientation) }
    override fun setIntegrationMethod(index: Long) { GyroflowNative.nativeSetIntegrationMethod(index.toInt()) }
    override fun setFrameOffset(frames: Long) { GyroflowNative.nativeSetFrameOffset(frames.toInt()) }

    // MARK: - 镜头

    override fun lensSearch(query: String): String = GyroflowNative.nativeLensSearch(query) ?: "[]"
    override fun loadLens(uriOrIdOrJson: String): String = GyroflowNative.nativeLoadLens(uriOrIdOrJson) ?: "{\"ok\":false}"
    override fun getLensInfoFull(): String = GyroflowNative.nativeGetLensInfo() ?: "{}"
    override fun loadGyro(uriOrPath: String, loadAllMetadata: Boolean): String =
        GyroflowNative.nativeLoadGyro(uriOrPath, loadAllMetadata) ?: "{\"ok\":false}"
    override fun folderAccessGranted(folderUrl: String) { GyroflowNative.nativeFolderAccessGranted(folderUrl) }

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
}
