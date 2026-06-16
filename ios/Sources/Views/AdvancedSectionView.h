#import <UIKit/UIKit.h>
#import "ParamsModel.h"

NS_ASSUME_NONNULL_BEGIN

/// View - 高级区域:预览分辨率 / 渲染背景色 / 安全区域指示。
/// 渲染背景色用 UIColorPickerViewController 弹出选择,需要 presenter。
@protocol AdvancedSectionViewDelegate <NSObject>
- (void)advancedSectionRequestsColorPicker:(UIColor *)current
                                completion:(void(^)(UIColor *picked))completion;
@end

@interface AdvancedSectionView : UIView
@property (nonatomic, weak, nullable) ParamsModel *model;
@property (nonatomic, weak, nullable) id<AdvancedSectionViewDelegate> presenterDelegate;
- (void)refreshReadOnly;
@end

NS_ASSUME_NONNULL_END
