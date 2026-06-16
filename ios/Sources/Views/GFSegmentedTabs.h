#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 自定义分段控件(与安卓端 GyroflowActivity 的分段对齐):
/// 图标 + 文字, 选中段主题色下划线、白字; 未选段整体变暗; 圆角深色底。
/// 对外暴露与 UISegmentedControl 一致的关键接口: selectedSegmentIndex +
/// UIControlEventValueChanged, 方便直接替换原有 UISegmentedControl。
@interface GFSegmentedTabs : UIControl

/// titles 与 iconNames 一一对应; iconNames 为 SF Symbol 名称。
- (instancetype)initWithTitles:(NSArray<NSString *> *)titles
                     iconNames:(NSArray<NSString *> *)iconNames;

@property (nonatomic, assign) NSInteger selectedSegmentIndex;

@end

NS_ASSUME_NONNULL_END
