#import "ParamsModel.h"

@interface ParamsModel ()
@property (nonatomic, strong, nullable) NSTimer *recomputeTimer;
@property (nonatomic, strong) dispatch_queue_t recomputeQueue;
@end

@implementation ParamsModel

- (instancetype)init {
    self = [super init];
    if (self) {
        _recomputeQueue = dispatch_queue_create("gyroflow.params.recompute", DISPATCH_QUEUE_SERIAL);

        // 默认值。
        // gyroOffsetMs:「大致偏移」= 同步搜索起点参数(官方 initialOffset 语义),
        // 不写引擎、不预设默认值。真实偏移只来自 autosync_finish 逐点写入 gyro.offsets。
        _autosyncEnabled = NO;       // Phase α 锁灰
        _gyroOffsetMs = 0.0;
        _syncSearchSizeSec = 5.0;    // 对齐官方(5.0 秒)
        _maxSyncPoints = 3;          // 对齐官方(3)
        _everyNthFrame = 1;          // 对齐官方(每帧分析)
        _timePerSyncpointSec = 1.5;  // 对齐官方(1.50 秒)
        _syncProcessingHeight = 720; // 对齐官方(720p)
        // 下面 3 个是 Rust 枚举真实索引(注意 SyncAdvancedView 的 UI 标签顺序和 Rust 索引相反,
        // 这里按 Rust 实际值设,才能真正跑官方那条路径):
        _ofMethod = 2;               // 2=OpenCV DIS(官方光流方式)
        _poseMethod = 0;             // 0=findEssentialMat(官方姿态方式),OpenCV LMEDS,最鲁棒
        _offsetMethod = 2;           // 2=rs_sync 卷帘快门同步(官方偏移方式)
        _imuLpfHz = 0.0;
        _showDetectedFeatures = NO;  // 默认 OFF
        _showOpticalFlow = NO;       // 默认 OFF
        // 官方 Synchronization.qml 默认：双向搜索关、calc_initial_fast 关、自动选点开
        _checkNegativeInitialOffset = NO;
        _calcInitialFast = NO;
        _autoSyncPointsExperimental = NO;
        _smoothingMethod = 1;
        _smoothness = 0.5;
        _perAxis = NO;
        // per_axis ON 时分轴平滑度,默认与主 smoothness 一致
        _smoothnessPitch = 0.5;
        _smoothnessYaw   = 0.5;
        _smoothnessRoll  = 0.5;
        _horizonLock = NO;
        _horizonLockAmount = 100.0;  // 默认 100% 锁定量;仅在 horizonLock ON 时生效
        _horizonLockRoll = 0.0;
        _horizonLockPitchEnabled = NO;
        _horizonLockPitch = 0.0;
        _automaticHorizonLock = NO;
        _turnThreshold = 0.0;
        _turnSmoothingMs = 0.0;
        _turnMultiplier = 1.0;   // 桌面默认非 0
        _tiltAccelLimit = 0.0;
        _frameReadoutDirection = 0;  // 默认 上→下 (TopToBottom), 加载时按 telemetry 自动识别
        // 纯3D / 固定摄像头 算法参数默认
        _plain3dTimeConstant = 0.25;  // 对齐官方 plain.rs:17 time_constant 默认 0.25s
        _fixedPitch = 0.0;
        _fixedYaw   = 0.0;
        _fixedRoll  = 0.0;
        // 高级 #1 默认值 (对齐 default_algo.rs:42-50)
        _trimRangeOnly = YES;
        _maxSmoothnessSec = 1.0;
        _alphaHighVelSec = 0.1;
        _maxZoomPercent = 130.0;
        _maxZoomIterations = 5;
        _adaptiveZoomSec = 4.0;
        _lensCorrection = 1.0;
        _fov = 1.0;
        // 桌面 Stabilization.qml:614 croppingMode currentIndex=1 (动态缩放) 默认。
        _croppingMode = 1;
        // 桌面 stabilization_params.rs:138 adaptive_zoom_method=1 (Envelope follower) 默认。
        _zoomingMethod = 1;
        _rsCorrection = YES;
        _frameReadoutMs = 11.11;
        _addPitch = 0.0;
        _addYaw = 0.0;
        _addRoll = 0.0;
        _videoSpeed = 1.0;
        _videoSpeedAffectsSmoothing = YES;     // 对齐桌面默认全开
        _videoSpeedAffectsZooming = YES;
        _videoSpeedAffectsZoomingLimit = YES;
        // outputSize 默认 0: 不主动推 FFI; Controller 在视频加载时显式设为视频原生
        // (对齐桌面 controller.rs:698 set_output_size(video_size.0, video_size.1)).
        // 之前写死 (2704,1520) 会跟视频实际尺寸不一致, 让 min_fov / 自适应缩放 fov_limit /
        // shader 写入像素数全部偏离桌面行为, 是 bug.
        _outputSize = CGSizeZero;
        // 渲染背景默认 #111111 (17/255)。
        _bgR = 17.0 / 255.0;
        _bgG = 17.0 / 255.0;
        _bgB = 17.0 / 255.0;
        _bgA = 1.0;
        _backgroundMode = 0;   // 0=纯色 1=边缘拉伸 2=边缘镜像 3=羽化留边
        _showSafeArea = NO;
        _previewResolutionHeight = 0;  // 0 = 视频原生
        // 导出设置默认值 (对齐桌面"导出设置": HEVC + 默认 63Mbps + GPU + 带音频)
        _exportCodecIndex = 1;   // H.265/HEVC
        _exportBitrateMbps = 63; // 默认 63 Mbps
        _useGpuEncoding = YES;
        _exportAudio = YES;
    }
    return self;
}

#pragma mark - 把当前所有值一次性推到 stabilizer(loadDefaults 用)

- (void)applyAllToStabilizer {
    if (!self.stabilizer) return;
    GyroflowStabilizer *s = self.stabilizer;

    // 注意: 不推 _gyroOffsetMs —— 「大致偏移」只是同步搜索起点参数, 不写引擎
    // (对齐官方/安卓); gyro.offsets 由 autosync_finish 在 FFI 内逐点管理。
    gyroflow_set_imu_lpf(s, _imuLpfHz);
    NSLog(@"[smooth_diag] applyAllToStabilizer: method=%d smoothness=%.6f per_axis=%d trim_range_only=%d max_smoothness=%.3f alpha_0_1s=%.3f horizonLock=%d amount=%.1f roll=%.1f",
          _smoothingMethod, _smoothness, _perAxis, _trimRangeOnly,
          _maxSmoothnessSec, _alphaHighVelSec,
          _horizonLock, _horizonLockAmount, _horizonLockRoll);
    gyroflow_set_smoothing_method(s, (uint32_t)_smoothingMethod);
    gyroflow_set_smoothing_param(s, "smoothness", _smoothness);
    gyroflow_set_smoothing_param(s, "smoothness_pitch", _smoothnessPitch);
    gyroflow_set_smoothing_param(s, "smoothness_yaw",   _smoothnessYaw);
    gyroflow_set_smoothing_param(s, "smoothness_roll",  _smoothnessRoll);
    gyroflow_set_smoothing_param(s, "per_axis", _perAxis ? 1.0 : 0.0);
    gyroflow_set_smoothing_param(s, "trim_range_only", _trimRangeOnly ? 1.0 : 0.0);
    gyroflow_set_smoothing_param(s, "max_smoothness", _maxSmoothnessSec);
    gyroflow_set_smoothing_param(s, "alpha_0_1s", _alphaHighVelSec);
    // 纯3D(method=2) / 固定摄像头(method=3) 的参数 —— set_smoothing_param 只对
    // 当前算法生效, 推到非当前算法会被忽略, 所以全推安全。
    gyroflow_set_smoothing_param(s, "time_constant", _plain3dTimeConstant);
    gyroflow_set_smoothing_param(s, "pitch", _fixedPitch);
    gyroflow_set_smoothing_param(s, "yaw",   _fixedYaw);
    gyroflow_set_smoothing_param(s, "roll",  _fixedRoll);
    [self applyHorizonLockToFFI];   // 统一走 helper(含 pitch/自动锁定高级参数), 不重复
    gyroflow_set_max_zoom(s, _maxZoomPercent, (uint32_t)_maxZoomIterations);
    // adaptive_zoom 由 croppingMode 决定 (对齐桌面 Stabilization.qml:619-624):
    //   0 (无缩放)   -> 0.0
    //   1 (动态缩放) -> _adaptiveZoomSec (默认 4.0s)
    //   2 (静态缩放) -> -1.0
    double adaptiveZoomFFI;
    switch (_croppingMode) {
        case 0: adaptiveZoomFFI = 0.0; break;
        case 2: adaptiveZoomFFI = -1.0; break;
        case 1: default: adaptiveZoomFFI = _adaptiveZoomSec; break;
    }
    gyroflow_set_adaptive_zoom(s, adaptiveZoomFFI);
    gyroflow_set_lens_correction_amount(s, _lensCorrection);
    gyroflow_set_fov(s, _fov);
    // zoomingMethod = adaptive_zoom_method (Gaussian filter / Envelope follower)。
    gyroflow_set_zooming_method(s, _zoomingMethod);
    gyroflow_set_frame_readout_time(s, _rsCorrection ? _frameReadoutMs : 0.0);
    gyroflow_set_frame_readout_direction(s, _frameReadoutDirection);
    gyroflow_set_additional_rotation(s, _addPitch, _addYaw, _addRoll);
    gyroflow_set_video_speed(s, _videoSpeed,
                             _videoSpeedAffectsSmoothing ? 1 : 0,
                             _videoSpeedAffectsZooming ? 1 : 0,
                             _videoSpeedAffectsZoomingLimit ? 1 : 0);
    // outputSize 仅当 Controller 在视频加载后赋了有效值才推; CGSizeZero 时
    // 不动 stabilizer 的 output_size, 保留 gyroflow_new_stabilizer 初始值。
    if (_outputSize.width > 0.5 && _outputSize.height > 0.5) {
        gyroflow_set_output_size_exact(s, (uint32_t)_outputSize.width, (uint32_t)_outputSize.height);
    }
    gyroflow_set_background_color(s, _bgR, _bgG, _bgB, _bgA);
    gyroflow_set_background_mode(s, _backgroundMode);
    gyroflow_set_show_safe_area(s, _showSafeArea ? 1 : 0);
    gyroflow_set_show_detected_features(s, _showDetectedFeatures ? 1 : 0);
    gyroflow_set_show_optical_flow     (s, _showOpticalFlow      ? 1 : 0);
}

#pragma mark - 加载默认值

- (void)loadDefaultsFromStabilizer:(GyroflowStabilizer *)stab {
    self.stabilizer = stab;
    if (!stab) return;
    // 先读回引擎已从 telemetry/镜头自动识别的帧读出方向, 否则下面 applyAll 会用
    // 模型默认值把它覆盖掉 (对齐官方: ReadoutDirection 跟随 telemetry 自动识别)。
    int32_t frd = gyroflow_get_frame_readout_direction(stab);
    if (frd >= 0) {
        _frameReadoutDirection = frd;
    }
    // 「大致偏移」(同步搜索起点参数, 不写引擎)每次加载视频复位为 0。
    // 真实偏移唯一来源: autosync_finish 在 FFI 内逐点写入 gyro.offsets
    // (对齐官方/安卓; 引擎侧 offsets 随新视频/新运动数据自动清零)。
    _gyroOffsetMs = 0.0;
    // 输出大小是「每个视频自己的」字段, 同样复位: 不清零的话下面 applyAll 会把
    // 上个视频的 outputSize 推进新 stabilizer(applyAllToStabilizer:158-160),
    // Controller 随后读回的就是旧尺寸 → 导出设置显示上个视频的输出大小。
    // 清零后 applyAll 按守卫跳过推送, 保留 load_video_file 为新视频算好的
    // output_size, 由 Controller 加载完成块读回并重新赋值。直写 ivar 不走 setter,
    // 避免触发 onOutputSizeChanged 推 FFI。
    _outputSize = CGSizeZero;
    [self applyAllToStabilizer];
    // 关键:首次必须**同步** recompute —— 否则 gyroflowReady=YES 之后那段时间
    // 里 stabilizer 没 recompute 过、stab_data 为空,drawInMTKView 调
    // process_frame_metal 会得到空矩阵 → 画面黑。同步阻塞主线程 ~50-200ms,
    // 但只在视频 load 时发生一次,可接受。之后用户拖参数才走 scheduleRecompute 防抖通道。
    gyroflow_recompute_blocking(stab);
    double angles[3] = {0.0, 0.0, 0.0};
    gyroflow_get_max_angles(stab, angles);
    _maxAnglePitch = angles[0];
    _maxAngleYaw   = angles[1];
    _maxAngleRoll  = angles[2];
    double mfv = 0.0;
    gyroflow_get_min_fov(stab, &mfv);
    _minFov = mfv;
    if (self.onRecomputeFinished) self.onRecomputeFinished();
}

// （历史：setGyroOffsetMsDisplayOnly"只显示不应用"曾是 Hero6 无防抖根因 → 一度改为
//   setter 全局应用到引擎 → 现在 autosync 结果由 FFI autosync_finish 逐点写 gyro.offsets,
//   setter 回归官方 initialOffset 语义：纯同步搜索起点参数。）

#pragma mark - 防抖 + 后台 recompute

- (void)scheduleRecompute {
    if (!self.stabilizer) return;
    [self.recomputeTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.recomputeTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                          repeats:NO
                                                            block:^(NSTimer * _Nonnull _) {
        __strong typeof(weakSelf) sSelf = weakSelf;
        if (sSelf == nil || sSelf.stabilizer == NULL) return;
        GyroflowStabilizer *stab = sSelf.stabilizer;
        dispatch_async(sSelf.recomputeQueue, ^{
            // [perf_diag] recompute 虽在后台队列, 但 gyroflow 内部锁与主线程的
            // process_frame / 参数 FFI 共享: 若期间主线程等锁, 预览慢帧日志会和
            // 这段「开始..结束」时间窗重合 —— 用于确认锁竞争是否是卡顿来源。
            const CFAbsoluteTime recomputeT0 = CFAbsoluteTimeGetCurrent();
            NSLog(@"[perf_diag] recompute 开始(后台队列)");
            gyroflow_recompute_blocking(stab);
            NSLog(@"[perf_diag] recompute 结束, 耗时 %.0fms",
                  (CFAbsoluteTimeGetCurrent() - recomputeT0) * 1000.0);
            double angles[3] = {0.0, 0.0, 0.0};
            gyroflow_get_max_angles(stab, angles);
            double mfv = 0.0;
            gyroflow_get_min_fov(stab, &mfv);
            // 用标量捕获而非数组 —— ObjC block 不允许直接 capture C 数组
            double a0 = angles[0];
            double a1 = angles[1];
            double a2 = angles[2];
            // 回读 size/output_size 一并打 —— 跟桌面 recompute 日志同字段对齐
            GyroflowVideoInfo vi2 = {0};
            gyroflow_get_video_info(stab, &vi2);
            double scaling2 = (vi2.output_width > 0) ? (double)vi2.width / (double)vi2.output_width : 0.0;
            NSLog(@"[smooth_diag] recompute done: maxAngles P=%.2f Y=%.2f R=%.2f minFov=%.4f "
                  @"| size=%ux%u output=%ux%u scaling_factor=%.4f smoothness=%.4f max_sm=%.3f alpha=%.3f",
                  a0, a1, a2, mfv,
                  vi2.width, vi2.height, vi2.output_width, vi2.output_height, scaling2,
                  sSelf->_smoothness, sSelf->_maxSmoothnessSec, sSelf->_alphaHighVelSec);
            dispatch_async(dispatch_get_main_queue(), ^{
                sSelf->_maxAnglePitch = a0;
                sSelf->_maxAngleYaw   = a1;
                sSelf->_maxAngleRoll  = a2;
                sSelf->_minFov        = mfv;
                if (sSelf.onRecomputeFinished) sSelf.onRecomputeFinished();
            });
        });
    }];
}

#pragma mark - Setters(每个内部都「设字段 + 调 FFI + scheduleRecompute」)

// 「大致偏移」= 同步搜索起点参数(官方 initialOffset 语义), **不写引擎**——
// 对齐官方 Synchronization.qml(initialOffset 只进 sync params)/安卓 GyroflowSyncPanel
// (initialOffsetField 只进 currentParams)。真实偏移由 autosync_finish 在 FFI 内
// 逐点写入 gyro.offsets。
- (void)setGyroOffsetMs:(double)v {
    _gyroOffsetMs = v;
}

- (void)setImuLpfHz:(double)v {
    _imuLpfHz = v;
    if (self.stabilizer) gyroflow_set_imu_lpf(self.stabilizer, v);
    [self scheduleRecompute];
}

- (void)setSmoothingMethod:(int)v {
    _smoothingMethod = v;
    if (self.stabilizer) gyroflow_set_smoothing_method(self.stabilizer, (uint32_t)v);
    [self scheduleRecompute];
}

- (void)setSmoothness:(double)v {
    _smoothness = v;
    if (self.stabilizer) gyroflow_set_smoothing_param(self.stabilizer, "smoothness", v);
    // 这条日志列出公式所有可控输入 + output_size (后者通过 scaling_factor 间接进 fov_ratio).
    // 跟桌面 [recompute done] 行 1:1 对比可定位差异来源。
    GyroflowVideoInfo vi = {0};
    if (self.stabilizer) gyroflow_get_video_info(self.stabilizer, &vi);
    double scaling = (vi.output_width > 0) ? (double)vi.width / (double)vi.output_width : 0.0;
    NSLog(@"[smooth_diag] setSmoothness=%.6f method=%d per_axis=%d trim_range=%d max_sm=%.3f alpha=%.3f "
          @"| size=%ux%u output=%ux%u scaling_factor=%.4f",
          v, _smoothingMethod, _perAxis, _trimRangeOnly, _maxSmoothnessSec, _alphaHighVelSec,
          vi.width, vi.height, vi.output_width, vi.output_height, scaling);
    [self scheduleRecompute];
}

- (void)setPerAxis:(BOOL)v {
    _perAxis = v;
    if (self.stabilizer) gyroflow_set_smoothing_param(self.stabilizer, "per_axis", v ? 1.0 : 0.0);
    [self scheduleRecompute];
}

- (void)setTrimRangeOnly:(BOOL)v {
    _trimRangeOnly = v;
    if (self.stabilizer) gyroflow_set_smoothing_param(self.stabilizer, "trim_range_only", v ? 1.0 : 0.0);
    [self scheduleRecompute];
}

- (void)setMaxSmoothnessSec:(double)v {
    _maxSmoothnessSec = v;
    if (self.stabilizer) gyroflow_set_smoothing_param(self.stabilizer, "max_smoothness", v);
    NSLog(@"[smooth_diag] setMaxSmoothnessSec=%.6f (FFI key=max_smoothness)", v);
    [self scheduleRecompute];
}

- (void)setAlphaHighVelSec:(double)v {
    _alphaHighVelSec = v;
    if (self.stabilizer) gyroflow_set_smoothing_param(self.stabilizer, "alpha_0_1s", v);
    [self scheduleRecompute];
}

- (void)setHorizonLock:(BOOL)v {
    _horizonLock = v;
    [self applyHorizonLockToFFI];
    [self scheduleRecompute];
}

- (void)setHorizonLockAmount:(double)v {
    _horizonLockAmount = v;
    if (_horizonLock) {
        [self applyHorizonLockToFFI];
        [self scheduleRecompute];
    }
}

- (void)setHorizonLockRoll:(double)v {
    _horizonLockRoll = v;
    if (_horizonLock) {
        [self applyHorizonLockToFFI];
        [self scheduleRecompute];
    }
}

// 地平线锁定·高级 setter —— 改完都重推 FFI(仅 horizonLock ON 时生效)。
- (void)_pushHorizonAdvanced {
    if (_horizonLock) {
        [self applyHorizonLockToFFI];
        [self scheduleRecompute];
    }
}
- (void)setHorizonLockPitchEnabled:(BOOL)v { _horizonLockPitchEnabled = v; [self _pushHorizonAdvanced]; }
- (void)setHorizonLockPitch:(double)v      { _horizonLockPitch = v;        [self _pushHorizonAdvanced]; }
- (void)setAutomaticHorizonLock:(BOOL)v    { _automaticHorizonLock = v;    [self _pushHorizonAdvanced]; }
- (void)setTurnThreshold:(double)v         { _turnThreshold = v;           [self _pushHorizonAdvanced]; }
- (void)setTurnSmoothingMs:(double)v       { _turnSmoothingMs = v;         [self _pushHorizonAdvanced]; }
- (void)setTurnMultiplier:(double)v        { _turnMultiplier = v;          [self _pushHorizonAdvanced]; }
- (void)setTiltAccelLimit:(double)v        { _tiltAccelLimit = v;          [self _pushHorizonAdvanced]; }

// 卷帘方向(#3): 改完直接推 FFI + 重算。
- (void)setFrameReadoutDirection:(int)v {
    _frameReadoutDirection = v;
    if (self.stabilizer) {
        gyroflow_set_frame_readout_direction(self.stabilizer, v);
        [self scheduleRecompute];
    }
}

// 私有 helper: horizonLock 主开关 / amount / roll 三个 setter 都走同一份推 FFI 逻辑,
// 避免重复 (用户规则: 不重复代码)。
- (void)applyHorizonLockToFFI {
    if (!self.stabilizer) {
        return;
    }
    double amount = _horizonLock ? _horizonLockAmount : 0.0;
    gyroflow_set_horizon_lock(self.stabilizer,
                              amount,
                              _horizonLockRoll,
                              _horizonLockPitchEnabled ? 1 : 0,
                              _horizonLockPitchEnabled ? _horizonLockPitch : 0.0,
                              _automaticHorizonLock ? 1 : 0,
                              _turnThreshold,
                              _turnSmoothingMs,
                              _turnMultiplier,
                              _tiltAccelLimit);
}

- (void)setSmoothnessPitch:(double)v {
    _smoothnessPitch = v;
    if (self.stabilizer) gyroflow_set_smoothing_param(self.stabilizer, "smoothness_pitch", v);
    [self scheduleRecompute];
}

- (void)setSmoothnessYaw:(double)v {
    _smoothnessYaw = v;
    if (self.stabilizer) gyroflow_set_smoothing_param(self.stabilizer, "smoothness_yaw", v);
    [self scheduleRecompute];
}

- (void)setSmoothnessRoll:(double)v {
    _smoothnessRoll = v;
    if (self.stabilizer) gyroflow_set_smoothing_param(self.stabilizer, "smoothness_roll", v);
    [self scheduleRecompute];
}

- (void)setPlain3dTimeConstant:(double)v {
    _plain3dTimeConstant = v;
    if (self.stabilizer) gyroflow_set_smoothing_param(self.stabilizer, "time_constant", v);
    [self scheduleRecompute];
}

- (void)setFixedPitch:(double)v {
    _fixedPitch = v;
    if (self.stabilizer) gyroflow_set_smoothing_param(self.stabilizer, "pitch", v);
    [self scheduleRecompute];
}

- (void)setFixedYaw:(double)v {
    _fixedYaw = v;
    if (self.stabilizer) gyroflow_set_smoothing_param(self.stabilizer, "yaw", v);
    [self scheduleRecompute];
}

- (void)setFixedRoll:(double)v {
    _fixedRoll = v;
    if (self.stabilizer) gyroflow_set_smoothing_param(self.stabilizer, "roll", v);
    [self scheduleRecompute];
}

- (void)setMaxZoomPercent:(double)v {
    _maxZoomPercent = v;
    if (self.stabilizer) gyroflow_set_max_zoom(self.stabilizer, v, (uint32_t)_maxZoomIterations);
    [self scheduleRecompute];
}

- (void)setMaxZoomIterations:(int)v {
    _maxZoomIterations = v;
    if (self.stabilizer) gyroflow_set_max_zoom(self.stabilizer, _maxZoomPercent, (uint32_t)v);
    [self scheduleRecompute];
}

- (void)setAdaptiveZoomSec:(double)v {
    _adaptiveZoomSec = v;
    // 仅在「动态缩放」模式下,这个 slider 才生效。否则 adaptive_zoom 由 croppingMode 锁定。
    if (self.stabilizer && _croppingMode == 1) {
        gyroflow_set_adaptive_zoom(self.stabilizer, v);
    }
    [self scheduleRecompute];
}

- (void)setCroppingMode:(int)v {
    // 桌面 Stabilization.qml:619-624: 0->0.0, 1->adaptive_zoom_value, 2->-1.0。
    if (v < 0 || v > 2) {
        return;
    }
    _croppingMode = v;
    if (self.stabilizer) {
        double adaptiveZoomFFI;
        switch (v) {
            case 0: adaptiveZoomFFI = 0.0; break;
            case 2: adaptiveZoomFFI = -1.0; break;
            case 1: default: adaptiveZoomFFI = _adaptiveZoomSec; break;
        }
        gyroflow_set_adaptive_zoom(self.stabilizer, adaptiveZoomFFI);
    }
    [self scheduleRecompute];
}

- (void)setLensCorrection:(double)v {
    _lensCorrection = v;
    if (self.stabilizer) gyroflow_set_lens_correction_amount(self.stabilizer, v);
    [self scheduleRecompute];
}

- (void)setFov:(double)v {
    _fov = v;
    if (self.stabilizer) gyroflow_set_fov(self.stabilizer, v);
    [self scheduleRecompute];
}

- (void)setZoomingMethod:(int)v {
    _zoomingMethod = v;
    if (self.stabilizer) gyroflow_set_zooming_method(self.stabilizer, v);
    [self scheduleRecompute];
}

- (void)setRsCorrection:(BOOL)v {
    _rsCorrection = v;
    if (self.stabilizer) gyroflow_set_frame_readout_time(self.stabilizer, v ? _frameReadoutMs : 0.0);
    [self scheduleRecompute];
}

- (void)setFrameReadoutMs:(double)v {
    _frameReadoutMs = v;
    if (self.stabilizer && _rsCorrection) gyroflow_set_frame_readout_time(self.stabilizer, v);
    [self scheduleRecompute];
}

- (void)setAddPitch:(double)v {
    _addPitch = v;
    if (self.stabilizer) gyroflow_set_additional_rotation(self.stabilizer, v, _addYaw, _addRoll);
    [self scheduleRecompute];
}

- (void)setAddYaw:(double)v {
    _addYaw = v;
    if (self.stabilizer) gyroflow_set_additional_rotation(self.stabilizer, _addPitch, v, _addRoll);
    [self scheduleRecompute];
}

- (void)setAddRoll:(double)v {
    _addRoll = v;
    if (self.stabilizer) gyroflow_set_additional_rotation(self.stabilizer, _addPitch, _addYaw, v);
    [self scheduleRecompute];
}

// 统一把 videoSpeed + 3 个联动开关推到引擎。
- (void)pushVideoSpeed {
    if (!self.stabilizer) {
        return;
    }
    gyroflow_set_video_speed(self.stabilizer, _videoSpeed,
                             _videoSpeedAffectsSmoothing ? 1 : 0,
                             _videoSpeedAffectsZooming ? 1 : 0,
                             _videoSpeedAffectsZoomingLimit ? 1 : 0);
}

- (void)setVideoSpeed:(double)v {
    if (v < 0.0001) {
        v = 0.0001; // 防 0/负值导致 Rust 端除 0
    }
    _videoSpeed = v;
    [self pushVideoSpeed];
    [self scheduleRecompute];
}

- (void)setVideoSpeedAffectsSmoothing:(BOOL)v {
    _videoSpeedAffectsSmoothing = v;
    [self pushVideoSpeed];
    [self scheduleRecompute];
}

- (void)setVideoSpeedAffectsZooming:(BOOL)v {
    _videoSpeedAffectsZooming = v;
    [self pushVideoSpeed];
    [self scheduleRecompute];
}

- (void)setVideoSpeedAffectsZoomingLimit:(BOOL)v {
    _videoSpeedAffectsZoomingLimit = v;
    [self pushVideoSpeed];
    [self scheduleRecompute];
}

- (void)setOutputSize:(CGSize)v {
    _outputSize = v;
    // 走 onOutputSizeChanged 让 Controller 同步协调更新 stabilizer/videoInfo/drawable,
    // 避免"立刻改 stabilizer + 防抖 recompute"造成 drawable 滞后那一帧的尺寸不匹配。
    if (self.onOutputSizeChanged) {
        self.onOutputSizeChanged();
    } else if (self.stabilizer) {
        // 兜底(回调未接): 老行为。
        gyroflow_set_output_size_exact(self.stabilizer, (uint32_t)v.width, (uint32_t)v.height);
        [self scheduleRecompute];
    }
}

- (void)setBgR:(double)v { _bgR = v; if (self.stabilizer) gyroflow_set_background_color(self.stabilizer, v, _bgG, _bgB, _bgA); [self scheduleRecompute]; }
- (void)setBgG:(double)v { _bgG = v; if (self.stabilizer) gyroflow_set_background_color(self.stabilizer, _bgR, v, _bgB, _bgA); [self scheduleRecompute]; }
- (void)setBgB:(double)v { _bgB = v; if (self.stabilizer) gyroflow_set_background_color(self.stabilizer, _bgR, _bgG, v, _bgA); [self scheduleRecompute]; }
- (void)setBgA:(double)v { _bgA = v; if (self.stabilizer) gyroflow_set_background_color(self.stabilizer, _bgR, _bgG, _bgB, v); [self scheduleRecompute]; }

- (void)setBackgroundMode:(int)v {
    _backgroundMode = v;
    if (self.stabilizer) {
        gyroflow_set_background_mode(self.stabilizer, v);
    }
    [self scheduleRecompute];
}

- (void)setShowSafeArea:(BOOL)v {
    _showSafeArea = v;
    if (self.stabilizer) gyroflow_set_show_safe_area(self.stabilizer, v ? 1 : 0);
    [self scheduleRecompute];
}

// drawing flag: 下一帧 draw_overlays 直接读, 不需要 scheduleRecompute
// (重算 smoothing 跟 features / OF 渲染无关, 避免无谓的 50-200ms 阻塞)
- (void)setShowDetectedFeatures:(BOOL)v {
    _showDetectedFeatures = v;
    if (self.stabilizer) gyroflow_set_show_detected_features(self.stabilizer, v ? 1 : 0);
}

- (void)setShowOpticalFlow:(BOOL)v {
    _showOpticalFlow = v;
    if (self.stabilizer) gyroflow_set_show_optical_flow(self.stabilizer, v ? 1 : 0);
}

// 预览分辨率: 只通知 Controller 重建 MDK 输入纹理 + 改 surface size,
// 跟算法 (outputSize / smoothing / adaptive zoom) 无关, 不调 FFI / 不 recompute。
- (void)setPreviewResolutionHeight:(int)v {
    if (v < 0) {
        v = 0;
    }
    if (_previewResolutionHeight == v) {
        return;
    }
    _previewResolutionHeight = v;
    if (self.onPreviewResolutionChanged) {
        self.onPreviewResolutionChanged();
    }
}

@end
