#import <UIKit/UIKit.h>
#import "ParamsModel.h"

NS_ASSUME_NONNULL_BEGIN

/// 同步段的"高级选项"展开面板(UIView,inline 嵌入,不是 modal)。
/// 默认 hidden=YES,由 SyncSectionView 的"高级选项"按钮切换显隐。
/// Phase α:每 N 帧 / 每个同步点时长 / 处理分辨率 / 光流方式 / 姿态方式 /
/// 偏移方式 / 低通滤波器 可编辑(只存到 Model);
/// 显示检测到的特性 / 显示光学流量 锁灰。
@interface SyncAdvancedView : UIView
@property (nonatomic, weak, nullable) ParamsModel *model;
- (void)refreshFromModel;
@end

NS_ASSUME_NONNULL_END
