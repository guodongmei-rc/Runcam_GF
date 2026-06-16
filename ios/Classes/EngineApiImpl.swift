import Foundation
import Flutter

/// S3 — iOS 引擎转发壳(阶段2)。
///
/// 实现 Pigeon 生成的 `EngineApi` 协议,每个方法转发到 `gyroflow_ffi.h` 的 `gyroflow_*`。
/// `GyroflowStabilizer*` 句柄持有在本类(独立于任何 UIView —— 阶段0「无头引擎」雏形)。
///
/// 约定:
///   - 简单 setter:容错转发(失败不抛,对齐 ParamsModel.m 现有宽松行为)。
///   - openVideo / recomputeBlocking:异步,完成回主线程;recompute 另发
///     `EngineEvents.onRecomputeFinished` 便于 UI 统一刷新。
///   - 不碰预览/解码/Metal —— 老 `open()` 全屏页仍走原路径,二者互不影响。
///
/// 注:FFI C 函数经 pod 的 umbrella header(含 gyroflow_ffi.h)对 Swift 可见;
///     不透明句柄 `GyroflowStabilizer *` 在 Swift 侧为 `OpaquePointer`。
final class EngineApiImpl: EngineApi {

    private var handle: OpaquePointer?

    /// 供 PreviewController 共享同一引擎句柄(阶段1 预览)。
    var stabilizerHandle: OpaquePointer? { handle }

    private let events: EngineEvents?
    private let recomputeQueue = DispatchQueue(label: "gyroflow.engine.recompute")

    init(events: EngineEvents?) {
        self.events = events
    }

    // MARK: - 生命周期

    func createStabilizer() throws {
        if handle == nil {
            handle = gyroflow_stabilizer_new()
        }
        if let h = handle {
            _ = gyroflow_use_default_gpu(h) // best-effort:无 GPU 也不致命
        }
    }

    func freeStabilizer() throws {
        if let h = handle {
            gyroflow_stabilizer_free(h)
        }
        handle = nil
    }

    func openVideo(uriOrPath: String, completion: @escaping (Result<VideoInfo, Error>) -> Void) {
        guard let h = handle else {
            completion(.failure(engineError("NO_STABILIZER", "openVideo 前需先 createStabilizer")))
            return
        }
        recomputeQueue.async {
            var info = GyroflowVideoInfo()
            let r = gyroflow_load_video_file(h, uriOrPath, &info)
            DispatchQueue.main.async {
                if r != 0 {
                    completion(.failure(self.lastError("LOAD_VIDEO_FAILED")))
                    return
                }
                completion(.success(VideoInfo(
                    width: Int64(info.width),
                    height: Int64(info.height),
                    outputWidth: Int64(info.output_width),
                    outputHeight: Int64(info.output_height),
                    fps: info.fps,
                    durationS: info.duration_s,
                    frameCount: Int64(info.frame_count)
                )))
            }
        }
    }

    // MARK: - 稳定

    func setStabEnabled(enabled: Bool) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_stab_enabled(h, enabled ? 1 : 0)
    }

    func setSmoothingMethod(index: Int64) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_smoothing_method(h, UInt32(truncatingIfNeeded: index))
    }

    func setSmoothingParam(name: String, value: Double) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_smoothing_param(h, name, value)
    }

    func setHorizonLock(lockPercent: Double, rollDeg: Double, lockPitch: Bool, pitchDeg: Double,
                        automaticLock: Bool, turnThreshold: Double, turnSmoothingMs: Double,
                        turnMultiplier: Double, tiltAccelLimit: Double) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_horizon_lock(h, lockPercent, rollDeg,
                                      lockPitch ? 1 : 0, pitchDeg,
                                      automaticLock ? 1 : 0, turnThreshold,
                                      turnSmoothingMs, turnMultiplier, tiltAccelLimit)
    }

    // MARK: - 缩放

    func setAdaptiveZoom(windowSeconds: Double) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_adaptive_zoom(h, windowSeconds)
    }

    func setMaxZoom(percent: Double, iterations: Int64) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_max_zoom(h, percent, UInt32(truncatingIfNeeded: iterations))
    }

    func setZoomingMethod(index: Int64) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_zooming_method(h, Int32(truncatingIfNeeded: index))
    }

    func setLensCorrection(amount: Double) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_lens_correction_amount(h, amount)
    }

    func setFov(fov: Double) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_fov(h, fov)
    }

    // MARK: - 卷帘 / 速度 / 旋转 / 背景 / 安全区 / 预览分辨率 / 输出尺寸

    func setFrameReadoutTime(ms: Double) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_frame_readout_time(h, ms)
    }

    func setFrameReadoutDirection(dir: Int64) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_frame_readout_direction(h, Int32(truncatingIfNeeded: dir))
    }

    func setVideoSpeed(speed: Double, affectsSmoothing: Bool, affectsZooming: Bool,
                       affectsZoomingLimit: Bool) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_video_speed(h, speed,
                                     affectsSmoothing ? 1 : 0,
                                     affectsZooming ? 1 : 0,
                                     affectsZoomingLimit ? 1 : 0)
    }

    func setAdditionalRotation(pitchDeg: Double, yawDeg: Double, rollDeg: Double) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_additional_rotation(h, pitchDeg, yawDeg, rollDeg)
    }

    func setBackgroundColor(r: Double, g: Double, b: Double, a: Double) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_background_color(h, r, g, b, a)
    }

    func setBackgroundMode(mode: Int64) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_background_mode(h, Int32(truncatingIfNeeded: mode))
    }

    func setShowSafeArea(show: Bool) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_show_safe_area(h, show ? 1 : 0)
    }

    func setShowDetectedFeatures(show: Bool) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_show_detected_features(h, show ? 1 : 0)
    }

    func setShowOpticalFlow(show: Bool) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_show_optical_flow(h, show ? 1 : 0)
    }

    func setPreviewResolution(targetHeight: Int64) throws {
        // 预览降采样:对齐 set_output_size_exact 思路。具体等比缩放由 UI/Controller
        // 决策;阶段0+2 仅透传到 exact(0/-1=原生时不动)。
        guard let h = handle, targetHeight > 0 else { return }
        var info = GyroflowVideoInfo()
        guard gyroflow_get_video_info(h, &info) == 0, info.height > 0 else { return }
        let scale = Double(targetHeight) / Double(info.height)
        let w = UInt32(max(2.0, (Double(info.width) * scale).rounded()))
        let hgt = UInt32(targetHeight)
        _ = gyroflow_set_output_size_exact(h, w, hgt)
    }

    func setOutputSize(width: Int64, height: Int64) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_output_size(h, UInt32(truncatingIfNeeded: width), UInt32(truncatingIfNeeded: height))
    }

    func setOutputSizeExact(width: Int64, height: Int64) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_output_size_exact(h, UInt32(truncatingIfNeeded: width), UInt32(truncatingIfNeeded: height))
    }

    // MARK: - IMU / 运动数据

    func setGyroOffset(offsetMs: Double) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_gyro_offset(h, offsetMs)
    }

    func setImuLpf(hz: Double) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_imu_lpf(h, hz)
    }

    func setImuOrientation(orientation: String) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_imu_orientation(h, orientation)
    }

    func setIntegrationMethod(index: Int64) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_integration_method(h, UInt32(truncatingIfNeeded: index))
    }

    func setFrameOffset(frames: Int64) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_frame_offset(h, Int32(truncatingIfNeeded: frames))
    }

    // MARK: - 镜头

    func lensSearch(query: String) throws -> String {
        guard let h = handle else { return "[]" }
        var buf = [CChar](repeating: 0, count: 8192)
        let n = gyroflow_lens_search(h, query, &buf, buf.count)
        return n < 0 ? "[]" : String(cString: buf)
    }

    func loadLens(uriOrIdOrJson: String) throws -> String {
        guard let h = handle else { return "{\"ok\":false}" }
        let r = gyroflow_load_lens_profile(h, uriOrIdOrJson)
        if r != 0 { return "{\"ok\":false}" }
        _ = gyroflow_apply_loaded_lens_extras(h)
        return try getLensInfoFull()
    }

    func getLensInfoFull() throws -> String {
        guard let h = handle else { return "{}" }
        var buf = [CChar](repeating: 0, count: 8192)
        let r = gyroflow_get_lens_info_full(h, &buf, buf.count)
        return r != 0 ? "{}" : String(cString: buf)
    }

    func loadGyro(uriOrPath: String, loadAllMetadata: Bool) throws -> String {
        guard let h = handle else { return "{\"ok\":false}" }
        let r = gyroflow_load_gyro_data(h, uriOrPath, loadAllMetadata ? 1 : 0)
        return r == 0 ? "{\"ok\":true}" : "{\"ok\":false}"
    }

    func folderAccessGranted(folderUrl: String) throws {
        _ = gyroflow_folder_access_granted(folderUrl)
    }

    // MARK: - 查询 / 重算

    func recomputeBlocking(completion: @escaping (Result<StabInfo, Error>) -> Void) {
        guard let h = handle else {
            completion(.success(StabInfo()))
            return
        }
        recomputeQueue.async {
            gyroflow_recompute_blocking(h)
            var ang = [Double](repeating: 0, count: 3)
            _ = gyroflow_get_max_angles(h, &ang)
            var minFov: Double = 0
            _ = gyroflow_get_min_fov(h, &minFov)
            let info = StabInfo(maxAnglePitch: ang[0], maxAngleYaw: ang[1],
                                maxAngleRoll: ang[2], minFov: minFov)
            DispatchQueue.main.async {
                self.events?.onRecomputeFinished(info: info) { _ in }
                completion(.success(info))
            }
        }
    }

    func getVideoMetadata() throws -> String {
        guard let h = handle else { return "{}" }
        var buf = [CChar](repeating: 0, count: 8192)
        let r = gyroflow_get_video_metadata(h, &buf, buf.count)
        return r != 0 ? "{}" : String(cString: buf)
    }

    func gyroTimeline(count: Int64) throws -> [Double] {
        guard let h = handle, count > 0 else { return [] }
        let c = Int(count)
        var out = [Double](repeating: 0, count: c * 3)
        let r = gyroflow_get_gyro_timeline(h, &out, Int32(c))
        return r != 0 ? [] : out
    }

    func quaternionTimeline(count: Int64) throws -> [Double] {
        guard let h = handle, count > 0 else { return [] }
        let c = Int(count)
        var out = [Double](repeating: 0, count: c * 4)
        let r = gyroflow_get_quaternion_timeline(h, &out, Int32(c))
        return r != 0 ? [] : out
    }

    func quatsAtTimestamp(timestampUs: Int64) throws -> [Double] {
        guard let h = handle else { return [] }
        var out = [Double](repeating: 0, count: 8)
        let r = gyroflow_quats_at_timestamp(h, timestampUs, &out)
        return r != 0 ? [] : out
    }

    func getFovAtTimestamp(timestampUs: Int64) throws -> Double {
        guard let h = handle else { return 0 }
        var fov: Double = 0
        var minFov: Double = 0
        let r = gyroflow_get_fov_at_timestamp(h, timestampUs, &fov, &minFov)
        return r != 0 ? 0 : fov
    }

    // MARK: - 错误辅助

    // 用 Pigeon 生成的 PigeonError(符合 Swift Error;FlutterError 不符合,
    // 不能放进 Result<_, Error>.failure)。
    private func engineError(_ code: String, _ msg: String) -> PigeonError {
        PigeonError(code: code, message: msg, details: nil)
    }

    private func lastError(_ code: String) -> PigeonError {
        let msg = gyroflow_last_error().map { String(cString: $0) } ?? "unknown"
        return PigeonError(code: code, message: msg, details: nil)
    }
}
