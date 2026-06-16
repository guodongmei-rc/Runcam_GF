#import <UIKit/UIKit.h>
#import "ParamsModel.h"

NS_ASSUME_NONNULL_BEGIN

/// View - 缩放与画面区域:缩放限额 / 迭代次数 / 缩放速度 / 镜头校正 / 视场角 /
/// 缩放方式 / 卷帘快门(开关+帧读出时间) / 附加 3D 旋转(P/Y/R)。
@interface ZoomSectionView : UIView
@property (nonatomic, weak, nullable) ParamsModel *model;
- (void)refreshReadOnly;
@end

NS_ASSUME_NONNULL_END
