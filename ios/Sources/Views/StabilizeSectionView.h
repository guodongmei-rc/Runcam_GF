#import <UIKit/UIKit.h>
#import "ParamsModel.h"

NS_ASSUME_NONNULL_BEGIN

/// View - 「稳定」section。
///
/// 主区:平滑算法 / 平滑度 / 锁定地平线 / 最大旋转(只读) / min_fov 显示。
/// 高级 #1 折叠区:由 `StabilizeAdvancedView` 子模块承担(视轴 / 仅限修建范围内 /
/// 最大水平速度 / 高速最大平滑度)。本类只负责「高级选项 ∨」按钮的折叠/展开交互。
@interface StabilizeSectionView : UIView

@property (nonatomic, weak, nullable) ParamsModel *model;

/// recompute 完成后 Controller 调用,刷新 maxAngle + minFov 只读 label。
- (void)refreshReadOnly;

@end

NS_ASSUME_NONNULL_END
