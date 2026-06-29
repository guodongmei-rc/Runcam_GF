import Foundation
import Flutter
import AVFoundation
import AudioToolbox

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

    /// 镜头库搜索专用 stabilizer(裸句柄、无视频/镜头状态),避免搜索结果被当前
    /// 视频/镜头过滤(对齐 ViewController.mm:146 lensSearchStab)。懒创建,freeStabilizer 释放。
    private var lensSearchStab: OpaquePointer?

    /// 供 PreviewController 共享同一引擎句柄(阶段1 预览)。
    var stabilizerHandle: OpaquePointer? { handle }

    private let events: EngineEvents?
    private let recomputeQueue = DispatchQueue(label: "gyroflow.engine.recompute")

    /// 最近一次成功 openVideo 的源(供 autosync 复用,转 URL 喂 AutosyncRunner)。
    private var videoUri: String?
    /// 自动同步运行器(强引用,运行期间存活)。
    private var autosyncRunner: AutosyncRunner?

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
        if let s = lensSearchStab {
            gyroflow_stabilizer_free(s)
            lensSearchStab = nil
        }
    }

    // MARK: - 自动同步(autosync)

    func autosyncStart(uriOrPath: String, initialOffsetMs: Double, searchSizeSec: Double,
                       maxSyncPoints: Int64, everyNthFrame: Int64, timePerSyncpointSec: Double,
                       ofMethod: Int64, poseMethod: Int64, offsetMethod: Int64,
                       calcInitialFast: Bool, checkNegativeInitialOffset: Bool,
                       autoSyncPoints: Bool) throws {
        let path = videoUri ?? uriOrPath
        guard let h = handle, !path.isEmpty, let url = resolveURL(path) else {
            events?.onAutosyncFinished(medianOffsetMs: 0, syncPoints: [], ok: false) { _ in }
            return
        }

        let runner = AutosyncRunner(videoURL: url, stabilizer: h)
        runner.initialOffsetMs = initialOffsetMs
        runner.searchSizeSec = searchSizeSec
        runner.maxSyncPoints = UInt32(truncatingIfNeeded: maxSyncPoints)
        runner.everyNthFrame = UInt32(truncatingIfNeeded: everyNthFrame)
        runner.timePerSyncpointSec = timePerSyncpointSec
        runner.ofMethod = UInt32(truncatingIfNeeded: ofMethod)
        runner.poseMethod = UInt32(truncatingIfNeeded: poseMethod)
        runner.offsetMethod = UInt32(truncatingIfNeeded: offsetMethod)
        runner.calcInitialFast = calcInitialFast
        runner.checkNegativeInitialOffset = checkNegativeInitialOffset
        runner.autoSyncPointsExperimental = autoSyncPoints

        // 回调全部在主线程(AutosyncRunner 保证),直接转发到 EngineEvents。
        runner.onProgress = { [weak self] p, fed, total in
            self?.events?.onAutosyncProgress(progress: p, ready: Int64(fed), total: Int64(total)) { _ in }
        }
        runner.onFinished = { [weak self] offsetMs, points in
            // points: [{midpointMs, offsetMs}] → 摊平成交错 [mid, off, ...]。
            var flat: [Double] = []
            flat.reserveCapacity(points.count * 2)
            for d in points {
                flat.append(d["midpointMs"]?.doubleValue ?? 0)
                flat.append(d["offsetMs"]?.doubleValue ?? 0)
            }
            self?.events?.onAutosyncFinished(medianOffsetMs: offsetMs, syncPoints: flat, ok: true) { _ in }
        }
        runner.onFailed = { [weak self] _ in
            self?.events?.onAutosyncFinished(medianOffsetMs: 0, syncPoints: [], ok: false) { _ in }
        }

        autosyncRunner = runner
        runner.start()
    }

    func autosyncCancel() throws {
        autosyncRunner?.cancel()
    }

    func openVideo(uriOrPath: String, completion: @escaping (Result<VideoInfo, Error>) -> Void) {
        guard let h = handle else {
            completion(.failure(engineError("NO_STABILIZER", "openVideo 前需先 createStabilizer")))
            return
        }
        recomputeQueue.async {
            var info = GyroflowVideoInfo()
            let r = gyroflow_load_video_file(h, uriOrPath, &info)
            if r != 0 {
                DispatchQueue.main.async {
                    completion(.failure(self.lastError("LOAD_VIDEO_FAILED")))
                }
                return
            }
            // 用 AVAsset 补充编解码/采样率/旋转(失败则相应字段留 nil,不让 openVideo 失败)。
            let av = self.extractAVInfo(uriOrPath)
            DispatchQueue.main.async {
                self.videoUri = uriOrPath
                completion(.success(VideoInfo(
                    width: Int64(info.width),
                    height: Int64(info.height),
                    outputWidth: Int64(info.output_width),
                    outputHeight: Int64(info.output_height),
                    fps: info.fps,
                    durationS: info.duration_s,
                    frameCount: Int64(info.frame_count),
                    videoCodec: av.videoCodec,
                    pixelFormat: nil, // AVAsset 难可靠取像素格式 → 留 nil(Dart 显示「---」)
                    audioCodec: av.audioCodec,
                    audioSampleRate: av.audioSampleRate,
                    rotationDeg: av.rotationDeg,
                    videoBitrate: av.videoBitrate
                )))
            }
        }
    }

    // MARK: - 音视频信息 / autosync 辅助

    /// 把源(file:// URL 或纯路径)解析成 URL。含 "://" 视作 URL 字符串,否则按文件路径。
    private func resolveURL(_ s: String) -> URL? {
        if s.contains("://") {
            return URL(string: s)
        }
        return URL(fileURLWithPath: s)
    }

    /// 同步读取 AVAsset 的视频/音频编解码、音频采样率、视频旋转角、源视频码率。读不到返回 nil。
    private func extractAVInfo(_ uriOrPath: String)
        -> (videoCodec: String?, audioCodec: String?, audioSampleRate: Int64?, rotationDeg: Int64?, videoBitrate: Int64?) {
        guard let url = resolveURL(uriOrPath) else { return (nil, nil, nil, nil, nil) }
        let asset = AVURLAsset(url: url)

        var videoCodec: String?
        var rotationDeg: Int64?
        var videoBitrate: Int64?
        if let vt = asset.tracks(withMediaType: .video).first {
            if let fmts = vt.formatDescriptions as? [CMFormatDescription], let fd = fmts.first {
                videoCodec = EngineApiImpl.videoCodecName(CMFormatDescriptionGetMediaSubType(fd))
            }
            // preferredTransform 推回旋转角(0/90/180/270)。
            let t = vt.preferredTransform
            let angle = atan2(t.b, t.a) * 180.0 / .pi
            var deg = Int(angle.rounded())
            deg = ((deg % 360) + 360) % 360
            rotationDeg = Int64(deg)
            // 源视频码率(bit/s),对齐官方默认导出比特率。
            if vt.estimatedDataRate > 0 { videoBitrate = Int64(vt.estimatedDataRate) }
        }

        var audioCodec: String?
        var audioSampleRate: Int64?
        if let at = asset.tracks(withMediaType: .audio).first,
           let fmts = at.formatDescriptions as? [CMFormatDescription], let fd = fmts.first,
           let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
            let asbd = asbdPtr.pointee
            audioCodec = EngineApiImpl.audioCodecName(asbd.mFormatID)
            if asbd.mSampleRate > 0 { audioSampleRate = Int64(asbd.mSampleRate) }
        }

        return (videoCodec, audioCodec, audioSampleRate, rotationDeg, videoBitrate)
    }

    private static func videoCodecName(_ subType: FourCharCode) -> String {
        switch subType {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        default:
            let s = fourCCString(subType)
            return s == "hev1" ? "HEVC" : s
        }
    }

    private static func audioCodecName(_ formatID: AudioFormatID) -> String {
        switch formatID {
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatAC3: return "AC-3"
        case kAudioFormatAppleLossless: return "ALAC"
        default: return fourCCString(formatID)
        }
    }

    /// FourCC(UInt32)转可读 4 字符串,非可见字符以空格替换并裁掉。
    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        let chars = bytes.map { b -> Character in
            (b >= 0x20 && b < 0x7F) ? Character(UnicodeScalar(b)) : " "
        }
        return String(chars).trimmingCharacters(in: .whitespaces)
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

    // 该编码格式最大可导出分辨率 [maxW, maxH]。iOS 走 AVAssetWriter,按编码标准规格上限返回
    // (H.264 4096²、HEVC 8192²),保持现状不变;设备级精确探测(VideoToolbox)留后续。
    func encoderMaxSize(codecIndex: Int64) throws -> [Int64] {
        return codecIndex == 0 ? [4096, 4096] : [8192, 8192]
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

    func setImuMedian(samples: Int64) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_imu_median_filter(h, Int32(truncatingIfNeeded: samples))
    }

    func setImuRotation(pitchDeg: Double, rollDeg: Double, yawDeg: Double) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_imu_rotation(h, pitchDeg, rollDeg, yawDeg)
    }

    func setImuBias(x: Double, y: Double, z: Double) throws {
        guard let h = handle else { return }
        _ = gyroflow_set_imu_bias(h, x, y, z)
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
        // 用专用搜索 stabilizer(裸句柄、无视频/镜头状态),否则 Rust 侧 lens_search 会按
        // 当前已加载的镜头/视频过滤,搜不到结果(对齐 ViewController.mm:1191-1205)。
        if lensSearchStab == nil { lensSearchStab = gyroflow_stabilizer_new() }
        guard let s = lensSearchStab else { return "[]" }
        var buf = [CChar](repeating: 0, count: 65536) // 结果可能很多,缓冲放大(对齐原生)
        let n = gyroflow_lens_search(s, query, &buf, buf.count)
        return n < 0 ? "[]" : String(cString: buf)
    }

    func loadLens(uriOrIdOrJson: String) throws -> String {
        guard let h = handle else { return "{\"ok\":false}" }
        let r = gyroflow_load_lens_profile(h, uriOrIdOrJson)
        if r != 0 { return "{\"ok\":false}" }
        _ = gyroflow_apply_loaded_lens_extras(h)
        return try getLensInfoFull()
    }

    func autoloadLensForCamera() throws -> Int64 {
        // 按相机身份从内置库自动加载镜头(对齐 ViewController.mm:914;RunCam6 等)。
        guard let h = handle else { return -1 }
        let rc = gyroflow_autoload_lens_for_camera(h)
        if rc == 0 { _ = gyroflow_apply_loaded_lens_extras(h) } // 应用档案 frame_readout/gyro_lpf
        return Int64(rc)
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

    // 运动数据回显:iOS 无合并 getGyroInfo,用各单项 getter 拼(符号均在 .a 内)。
    // integration_method 无 getter → 不输出,面板按 has_quaternions 定默认。
    func getGyroInfo() throws -> String {
        guard let h = handle else { return "{}" }
        var buf = [CChar](repeating: 0, count: 256)
        var orient = "XYZ"
        if gyroflow_get_imu_orientation(h, &buf, buf.count) == 0 {
            let s = String(cString: buf)
            if !s.isEmpty { orient = s }
        }
        let hasQ = (gyroflow_has_quaternions(h) == 1)
        let lpf = gyroflow_get_imu_lpf(h)
        let median = gyroflow_get_imu_median_filter(h)
        var rot = [Double](repeating: 0, count: 3)
        _ = gyroflow_get_imu_rotation(h, &rot)
        var bias = [Double](repeating: 0, count: 3)
        _ = gyroflow_get_imu_bias(h, &bias)
        // 朝向只含 xyzXYZ,无需转义;直接拼 JSON。
        return "{\"imu_orientation\":\"\(orient)\",\"has_quaternions\":\(hasQ)," +
               "\"lpf\":\(lpf),\"median\":\(median)," +
               "\"rotation\":[\(rot[0]),\(rot[1]),\(rot[2])]," +
               "\"bias\":[\(bias[0]),\(bias[1]),\(bias[2])]}"
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
