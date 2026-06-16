#import <UIKit/UIKit.h>
#import "GyroTimelineModel.h"

NS_ASSUME_NONNULL_BEGIN

/// MVC - View：陀螺仪波形时间轴。
///
/// 把 model 里的三轴角速度画成波形（X 红 / Y 绿 / Z 蓝），并在 progress
/// 对应的横向位置画一条播放游标。纯展示组件，不含业务逻辑、不直接碰 FFI。
/// 设置 model 或 progress 都会自动触发重绘。
@interface GyroTimelineView : UIView

/// 要展示的陀螺仪数据。设置后自动重绘。
@property (nonatomic, strong, nullable) GyroTimelineModel *model;

/// 播放进度 0.0–1.0，决定游标横向位置。设置后自动重绘。
@property (nonatomic, assign) double progress;

/// 视频总时长(ms)。autosync 同步点要按 midpoint_ms / videoDurationMs 横向定位,
/// 没设置时 setSyncPoints 的竖线会按数组下标等距分布。
@property (nonatomic, assign) double videoDurationMs;

/// autosync 找到的同步点列表,每条形如 @{@"midpointMs": @3403, @"offsetMs": @49.097}。
/// 设置后画 N 条竖线 + 下方数值文本(ms)。设 nil/空数组则不画。
- (void)setSyncPoints:(nullable NSArray<NSDictionary<NSString *, NSNumber *> *> *)syncPoints;

/// 用户拖动 / 点击时间轴时回调,参数 progress 是 0.0–1.0 的新进度。
/// Controller 收到后应当调 MDK seek 把播放位置对齐过去。block 为 nil 时拖动只更新 UI 不通知。
@property (nonatomic, copy, nullable) void (^onSeek)(double progress);

@end

NS_ASSUME_NONNULL_END
