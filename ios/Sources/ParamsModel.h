#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "gyroflow_ffi.h"

NS_ASSUME_NONNULL_BEGIN

/// MVC - Model:参数面板的所有可调参数。
///
/// 持有每个参数的当前值,setter 内部完成「即时调 FFI + 200ms 防抖触发
/// recompute_blocking」的流程。stabilizer 由 Controller 注入(weak,不持有)。
/// recompute 完成后通过 onRecomputeFinished block 回调,Controller 据此刷新
/// 只读 label / 同步 drawableSize。
@interface ParamsModel : NSObject

/// 调用方注入的 stabilizer。Model 不持有所有权。
@property (nonatomic, assign, nullable) GyroflowStabilizer *stabilizer;

// ---- 同步 ----
// Phase α:这些值都存到 Model,但只有 gyroOffsetMs 和 imuLpfHz 真接 FFI;
// 其余 8 项是 auto-sync 算法用的参数,会在 Phase β 接通 AutosyncProcess。
@property (nonatomic, assign) BOOL    autosyncEnabled;            // 默认 NO,Phase α 锁灰
@property (nonatomic, assign) double  gyroOffsetMs;               // 「大致偏移」= 同步搜索起点参数（官方 initialOffset 语义），不写引擎；默认 0；UI clamp ±60s
@property (nonatomic, assign) double  syncSearchSizeSec;          // 默认 5.0（对齐官方）；UI clamp 0.1–60s
@property (nonatomic, assign) int     maxSyncPoints;              // 默认 3（对齐官方）；UI clamp 1–30
@property (nonatomic, assign) int     everyNthFrame;              // 默认 1；UI clamp 1–100
@property (nonatomic, assign) double  timePerSyncpointSec;        // 默认 1.5（对齐官方）；UI clamp 0.01–10s
@property (nonatomic, assign) int     syncProcessingHeight;       // 默认 720（对齐官方）
@property (nonatomic, assign) int     ofMethod;                   // 0=AKAZE, 1=OpenCV PyrLK, 2=OpenCV DIS（Rust 内部索引；默认 2 对齐官方）
@property (nonatomic, assign) int     poseMethod;                 // 0=findEssentialMat, 1=Almeida, 2=EightPoint, 3=findHomography；默认 0
@property (nonatomic, assign) int     offsetMethod;               // 0=Essential matrix, 1=Visual features, 2=rs-sync；默认 2（对齐官方）
@property (nonatomic, assign) double  imuLpfHz;                   // 默认 0（关闭）；UI clamp 0–500Hz
@property (nonatomic, assign) BOOL    showDetectedFeatures;       // 默认 NO
@property (nonatomic, assign) BOOL    showOpticalFlow;            // 默认 NO

// 官方 Synchronization.qml 的 3 个开关
@property (nonatomic, assign) BOOL    checkNegativeInitialOffset; // 双向搜索 ±offset（耗时翻倍）；默认 NO
@property (nonatomic, assign) BOOL    calcInitialFast;            // 先用 essential matrix 粗算 → rs-sync 精修；默认 NO，搜索 > 10s 时 UI 自动勾上
@property (nonatomic, assign) BOOL    autoSyncPointsExperimental; // Rust 自动挑采样点（替代等距）；默认 YES（FFI 原先就硬编码 true）

// ---- 稳定 ----
@property (nonatomic, assign) int     smoothingMethod;     // 0..3,默认 1 (无平滑/默认/纯3D/固定摄像头)
@property (nonatomic, assign) double  smoothness;          // 0.001..1.0,默认 0.5；FFI key "smoothness"
@property (nonatomic, assign) BOOL    perAxis;             // 默认 NO；ON 时主 smoothness 切到 pitch/yaw/roll 三轴
@property (nonatomic, assign) double  smoothnessPitch;     // 0.001..1.0,默认 0.5；FFI key "smoothness_pitch" (per_axis ON 时生效)
@property (nonatomic, assign) double  smoothnessYaw;       // 0.001..1.0,默认 0.5；FFI key "smoothness_yaw"
@property (nonatomic, assign) double  smoothnessRoll;      // 0.001..1.0,默认 0.5；FFI key "smoothness_roll"
@property (nonatomic, assign) BOOL    horizonLock;         // 默认 NO
@property (nonatomic, assign) double  horizonLockAmount;   // 0..100,默认 100；FFI 第 1 参数 (horizonLock=NO 时强制 0)
@property (nonatomic, assign) double  horizonLockRoll;     // -180..180,默认 0；FFI 第 2 参数 roll 角度校正
// 地平线锁定·高级 (对齐官方 set_horizon_lock 全 9 参)
@property (nonatomic, assign) BOOL    horizonLockPitchEnabled; // 锁定俯仰, 默认 NO
@property (nonatomic, assign) double  horizonLockPitch;        // 俯仰角 -90..90, 默认 0
@property (nonatomic, assign) BOOL    automaticHorizonLock;    // 自动锁定, 默认 NO
@property (nonatomic, assign) double  turnThreshold;           // 转向阈值 °/s, 默认 0
@property (nonatomic, assign) double  turnSmoothingMs;         // 转向平滑 ms, 默认 0
@property (nonatomic, assign) double  turnMultiplier;          // 转向倍率, 默认 1.0
@property (nonatomic, assign) double  tiltAccelLimit;          // 倾斜加速度限 °/s², 默认 0

// ---- 稳定 · 纯3D (smoothing::plain) ----
@property (nonatomic, assign) double  plain3dTimeConstant; // 平滑度(单位 s),默认 0.5；FFI key "time_constant"（仅 method=2 生效）

// ---- 稳定 · 固定摄像头 (smoothing::fixed) ----
@property (nonatomic, assign) double  fixedPitch;          // 俯仰角(°),默认 0；FFI key "pitch"（仅 method=3 生效）
@property (nonatomic, assign) double  fixedYaw;            // 偏航角(°),默认 0；FFI key "yaw"
@property (nonatomic, assign) double  fixedRoll;           // 横滚角(°),默认 0；FFI key "roll"

// ---- 稳定 · 高级 #1 (对应 default_algo.rs 里 advanced=true 的 smoothing params) ----
@property (nonatomic, assign) BOOL    trimRangeOnly;       // 默认 YES (default_algo.rs:48)；FFI key "trim_range_only"
@property (nonatomic, assign) double  maxSmoothnessSec;    // 0.1..5.0,默认 1.0；FFI key "max_smoothness"，单位 s
@property (nonatomic, assign) double  alphaHighVelSec;     // 0.01..1.0,默认 0.1；FFI key "alpha_0_1s"，单位 s

// ---- 缩放 ----
@property (nonatomic, assign) double  maxZoomPercent;      // 100..300,默认 130
@property (nonatomic, assign) int     maxZoomIterations;   // 1..15,默认 5
@property (nonatomic, assign) double  adaptiveZoomSec;     // 0..10,默认 4.0; 只在 croppingMode=Dynamic 时被推到 FFI
@property (nonatomic, assign) double  lensCorrection;      // 0..1,默认 1.0
@property (nonatomic, assign) double  fov;                 // 0.3..3.0,默认 1.0
/// 桌面 Stabilization.qml:612-630 的 croppingMode 下拉, 控制 adaptive_zoom 字段。
/// 0=无缩放(adaptive_zoom=0.0) / 1=动态缩放(adaptive_zoom=adaptiveZoomSec) / 2=静态缩放(adaptive_zoom=-1.0)
/// 默认 1 对齐桌面 currentIndex=1.
@property (nonatomic, assign) int     croppingMode;
/// 桌面 Stabilization.qml:828 的 zoomingMethod 下拉, 挂 adaptive_zoom_method 字段。
/// 0=Gaussian filter / 1=Envelope follower。默认 1 对齐 stabilization_params.rs:138 adaptive_zoom_method=1。
@property (nonatomic, assign) int     zoomingMethod;
@property (nonatomic, assign) BOOL    rsCorrection;        // 默认 YES
@property (nonatomic, assign) double  frameReadoutMs;      // 0..50,默认 11.11
@property (nonatomic, assign) int     frameReadoutDirection;// 0=上→下(默认) 1=下→上 2=左→右 3=右→左; 加载时已从 telemetry 自动设, 此为手动覆盖
@property (nonatomic, assign) double  addPitch;            // -180..180,默认 0
@property (nonatomic, assign) double  addYaw;              // -180..180,默认 0
@property (nonatomic, assign) double  addRoll;             // -180..180,默认 0
/// 视频播放速度倍率 (默认 1.0)。挂 gyroflow_set_video_speed。
@property (nonatomic, assign) double  videoSpeed;
// 视频速度联动开关 (对齐桌面, 默认全 YES): 改速度时是否同步影响 平滑/缩放速度/缩放限额。
@property (nonatomic, assign) BOOL    videoSpeedAffectsSmoothing;     // 链接平滑
@property (nonatomic, assign) BOOL    videoSpeedAffectsZooming;       // 链接缩放速度
@property (nonatomic, assign) BOOL    videoSpeedAffectsZoomingLimit;  // 链接缩放限额

// ---- 高级 ----
/// 算法/导出目标分辨率(对应 gyroflow_core 的 params.output_size)。
/// 影响: 自适应缩放上限、平滑度迭代基准、min_fov 缩放系数、shader 写入纹理像素数。
/// **不影响**预览渲染清晰度(那是 previewResolutionHeight 的事)。
/// 默认 CGSizeZero = 不主动推 FFI, 保留 stabilizer 已有值。
/// 视频加载完 Controller 应当把它设成视频原生 (videoInfo.width, videoInfo.height),
/// 对齐桌面 controller.rs:698 `set_output_size(video_size.0, video_size.1)` 默认行为。
@property (nonatomic, assign) CGSize  outputSize;
@property (nonatomic, assign) double  bgR;                 // 0..1,默认 0
@property (nonatomic, assign) double  bgG;                 // 0..1,默认 0
@property (nonatomic, assign) double  bgB;                 // 0..1,默认 0
@property (nonatomic, assign) double  bgA;                 // 0..1,默认 1
// 背景填充模式: 0=纯色 1=边缘拉伸 2=边缘镜像 3=羽化留边 (对齐桌面 BackgroundMode)
@property (nonatomic, assign) int     backgroundMode;      // 默认 0
@property (nonatomic, assign) BOOL    showSafeArea;        // 默认 NO

// ---- 预览分辨率 ----
/// 预览渲染清晰度的目标高度像素。对应桌面 `set_preview_resolution` ——
/// 改的是 gyroflow 实际渲染输出分辨率(output_size + drawable 等比缩小),
/// **不动 outputSize 这个逻辑全尺寸**(它仍代表导出/高级·输出大小的目标)。
/// 输入纹理与 MDK surface 始终保持视频原生, 只降像素不缩画面。
/// 0 = 视频原生; 其它如 1080 / 720 / 480。改变后触发 onPreviewResolutionChanged。
@property (nonatomic, assign) int     previewResolutionHeight;

/// 预览分辨率改变时回调,Controller 据此把 stabilizer 输出 output_size 等比缩到
/// 预览尺寸(set_output_size_exact + recompute)并同步 drawable。
@property (nonatomic, copy, nullable) void(^onPreviewResolutionChanged)(void);

/// outputSize(导出/逻辑输出尺寸)改变时回调。Controller 据此**同步**协调更新
/// stabilizer 输出尺寸 + 重读 videoInfo + drawable(走 applyPreviewOutputSizeToStabilizer),
/// 三者一次性对齐 —— 避免"setter 改了 stabilizer 但 drawable 还没跟上"那一帧的
/// 纹理尺寸不匹配。预览按当前预览分辨率渲染(像素受控), 画面只跟随导出比例变化。
@property (nonatomic, copy, nullable) void(^onOutputSizeChanged)(void);

// ---- 导出设置 (仅导出时读取; 这些值不接 FFI / 不触发 recompute) ----
/// 编解码器: 0 = H.264/AVC, 1 = H.265/HEVC。默认 1 (对齐桌面"导出设置")。
@property (nonatomic, assign) int     exportCodecIndex;
/// 导出码率, 单位 Mbps。0 = 自动(用内置默认 64Mbps)。
@property (nonatomic, assign) int     exportBitrateMbps;
/// 使用 GPU 编码。iOS VideoToolbox 对 H.264/HEVC 恒为硬件编码, 该开关仅与桌面 UI 对齐。默认 YES。
@property (nonatomic, assign) BOOL    useGpuEncoding;
/// 导出时是否包含源音频轨。默认 YES。
@property (nonatomic, assign) BOOL    exportAudio;

// ---- 只读输出(recompute 后由 onRecomputeFinished 刷新)----
@property (nonatomic, assign, readonly) double maxAnglePitch;
@property (nonatomic, assign, readonly) double maxAngleYaw;
@property (nonatomic, assign, readonly) double maxAngleRoll;
@property (nonatomic, assign, readonly) double minFov;            // 全局 min_fov；UI 显示 zoom%% = 100/min_fov

/// Controller 在 stabilizer 创建好后调一次:重置 ivars 为默认 + 立即把所有
/// 默认值通过 FFI 推到 stabilizer + 触发一次 recompute_blocking(后台串行)。
/// 之后所有 setter 都走 200ms 防抖。
- (void)loadDefaultsFromStabilizer:(GyroflowStabilizer *)stab;

/// recompute_blocking 在后台串行队列完成后,回到主线程触发该 block。
/// Controller 用来:① 刷新 maxAngle* label;② 同步 videoView.drawableSize。
@property (nonatomic, copy, nullable) void(^onRecomputeFinished)(void);

// （历史：FFI autosync_finish 现已对齐官方/安卓，在 FFI 内逐点写 gyro.offsets；
//   gyroOffsetMs 回归官方 initialOffset 语义=纯同步搜索起点参数，不写引擎。）

/// 给 Controller 用来触发一次 recompute(不改任何参数)。比如 auto-sync 完成后
/// 想让平滑用新 offsets 重算一遍。
- (void)scheduleRecompute;

@end

NS_ASSUME_NONNULL_END
