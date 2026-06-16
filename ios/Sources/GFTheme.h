#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Gyroflow 模块主题色板。与 Flutter 端 lib/app/core/theme/app_theme.dart 保持视觉一致。
// Flutter 改主色/背景时需手动同步本文件。
// 仅放色值；通用控件工厂在 GFViewKit。
@interface GFTheme : NSObject

+ (UIColor *)backgroundColor;          // #000000
+ (UIColor *)primaryColor;             // #FF6B00
+ (UIColor *)secondaryBackgroundColor; // #222222
+ (UIColor *)textColor;                // white
+ (UIColor *)secondaryTextColor;       // white alpha 0.7
+ (UIColor *)dividerColor;             // #2A2A2A

@end

NS_ASSUME_NONNULL_END
