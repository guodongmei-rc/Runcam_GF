#import <UIKit/UIKit.h>
#import "ParamsModel.h"

NS_ASSUME_NONNULL_BEGIN

/// 「锁定地平线」组合控件子模块。
///
/// 折叠态: 一行 checkbox 「锁定地平线」。
/// 展开态 (checkbox ON): 额外显示
///   - 锁定量 % slider (horizon_lock_amount, 0..100)
///   - Roll 角度校正 ° slider (horizon_lock_roll, -180..180)
///   - 提示 label: 「如果地平线锁定得不理想, 请尝试在"运动数据"部分中采用不同的积分方法。」
///
/// 设计原则:
///   - View 只渲染 + 触发意图;所有 setter 走 ParamsModel
///   - 折叠状态由内部 checkbox 直接控制,父视图不需要管
@interface HorizonLockGroupView : UIView

@property (nonatomic, weak, nullable) ParamsModel *model;

/// 父 view 加载完 model 后调一次。
- (void)refreshFromModel;

@end

NS_ASSUME_NONNULL_END
