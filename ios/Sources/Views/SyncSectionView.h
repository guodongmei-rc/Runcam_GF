#import <UIKit/UIKit.h>
#import "ParamsModel.h"

NS_ASSUME_NONNULL_BEGIN

/// View - 同步区域。
///   顶部:自动同步勾选/陀螺偏移/搜索尺寸/最大同步点数 + "高级选项"按钮
///   "高级选项"点击 → inline 展开下方的 SyncAdvancedView,再点收起。
///   Phase β:自动同步 checkbox 接通,点击 → 触发外部 onAutosyncTapped 回调,
///   由 Controller 拉起 AutosyncRunner;运行期间 setAutosyncRunning:YES
///   锁住 textfield 并显示进度文字。
@interface SyncSectionView : UIView
@property (nonatomic, weak, nullable) ParamsModel *model;
- (void)refreshReadOnly;

/// 用户点了「自动同步」勾选框。`turningOn` 是新状态。
/// turningOn=YES:Controller 应开始自动同步;turningOn=NO:Controller 应取消。
@property (nonatomic, copy, nullable) void(^onAutosyncTapped)(BOOL turningOn);

/// Controller 用来同步「正在运行」状态(锁/解锁 textfields + 控制进度 label 显示)。
- (void)setAutosyncRunning:(BOOL)running;

/// 更新进度文字。仅在 running=YES 时显示。
- (void)updateAutosyncProgress:(double)progress framesFed:(int)fed framesTotal:(int)total;

/// 自动同步完成后,Controller 把新 gyroOffsetMs 写进 model,然后调这个把
/// gyroOffset textfield 文本刷新成 model 当前值。
- (void)refreshGyroOffsetFromModel;

/// 同步模块整体可用性。enabled=NO 时:
///   - 所有 textfield / dropdown / checkbox / button 都不响应
///   - 整块 alpha 降到 0.5 给视觉提示
/// 调用时机:没视频 / 视频解析未完成 → NO;视频 ready → YES。
/// 自动同步运行时仍用 setAutosyncRunning:YES 控制独立的锁(细粒度,不动 alpha)。
- (void)setSectionEnabled:(BOOL)enabled;

/// 视频使用已同步运动数据(精确时间戳/直接用四元数)时显示提示(对齐官方 usesQuats)。
- (void)setUsesQuats:(BOOL)usesQuats;
/// 当前是否已有同步点(对齐官方 offsets_model.rowCount() > 0; 与 usesQuats 同时满足才弹提示)。
- (void)setHasSyncPoints:(BOOL)has;
@end

NS_ASSUME_NONNULL_END
