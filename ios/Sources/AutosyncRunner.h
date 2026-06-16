#import <Foundation/Foundation.h>
#import "gyroflow_ffi.h"

NS_ASSUME_NONNULL_BEGIN

/// 自动同步运行器。
///
/// 负责把 gyroflow auto-sync 的「Rust 侧 session 生命周期」和「iOS 侧
/// AVAssetReader 解帧循环」串起来:
///
///   1. `-start`        : 调 gyroflow_autosync_start 拿到 N 对时间范围
///   2. 后台线程         : 对每个范围用 AVAssetReader 解 NV12 帧,取 Y 平面
///   3. 每帧            : 调 gyroflow_autosync_feed_frame(非阻塞)
///   4. 喂完           : 调 gyroflow_autosync_finish (阻塞,内部跑光流)
///   5. 完成回调       : 拿到中位 offset_ms,主线程返回给调用方
///
/// 支持取消(`-cancel`)。所有回调在主线程。
@interface AutosyncRunner : NSObject

/// 初始化。`videoURL` 必须可被 AVAsset 打开;`stabilizer` 必须已 load_video_file 完成。
- (instancetype)initWithVideoURL:(NSURL *)videoURL
                      stabilizer:(GyroflowStabilizer *)stab NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// ---- 参数(start 前设,跟 ParamsModel 1:1) ----
@property (nonatomic, assign) double   initialOffsetMs;             // 默认 0
@property (nonatomic, assign) double   searchSizeSec;               // 默认 5.0（对齐官方）
@property (nonatomic, assign) uint32_t maxSyncPoints;               // 默认 3（对齐官方）
@property (nonatomic, assign) uint32_t everyNthFrame;               // 默认 1
@property (nonatomic, assign) double   timePerSyncpointSec;         // 默认 1.5（对齐官方）
@property (nonatomic, assign) uint32_t ofMethod;                    // 0=AKAZE, 1=PyrLK, 2=DIS（Rust 索引，默认 2）
@property (nonatomic, assign) uint32_t poseMethod;                  // 0=findEssential（默认）, 1=Almeida, 2=Eight, 3=Homography
@property (nonatomic, assign) uint32_t offsetMethod;                // 0=Essential, 1=Visual, 2=rs-sync（默认）

// 官方 Synchronization.qml 的 3 个开关
@property (nonatomic, assign) BOOL     calcInitialFast;             // 先粗后细（essential matrix → rs-sync），默认 NO
@property (nonatomic, assign) BOOL     checkNegativeInitialOffset;  // 双向搜索 ±offset，耗时翻倍，默认 NO
@property (nonatomic, assign) BOOL     autoSyncPointsExperimental;  // Rust 自动挑采样点，默认 YES

// ---- 回调(全部主线程) ----
/// 进度 0..1。也会带上「已喂帧数 / 预计帧数」用来显示文字。
@property (nonatomic, copy, nullable) void(^onProgress)(double progress, int framesFed, int framesExpected);
/// 成功完成。`offsetMs` 是 N 个同步点 offset 的中位数;`syncPoints` 是 N 条字典
/// 数组,每条形如 `@{@"midpointMs": @3403.4, @"offsetMs": @49.097}`,用于 UI
/// 在视频时间线上画竖线+数值标注。A方案下 FFI 不会把 offsets 应用到 gyro。
@property (nonatomic, copy, nullable) void(^onFinished)(double offsetMs, NSArray<NSDictionary<NSString *, NSNumber *> *> *syncPoints);
/// 失败或取消。`reason` 含简单原因描述(从 gyroflow_last_error 取或本地填)。
@property (nonatomic, copy, nullable) void(^onFailed)(NSString *reason);

/// 是否在运行(start 后 ~ onFinished/onFailed 之前)。
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;

/// 启动。立刻返回(全在后台跑)。重复调用会被忽略。
- (void)start;
/// 取消。设标志位;后台 loop 在下次检查时退出,通过 onFailed 回调通知。
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
