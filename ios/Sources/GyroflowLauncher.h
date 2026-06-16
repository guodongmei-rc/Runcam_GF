#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Gyroflow 防抖 UI 的入口。隐藏内部 `ViewController` 实现，
/// 对 Runner target 只暴露「创建一个可全屏 modal 呈现 + 自带关闭按钮」的 UIViewController。
@interface GyroflowLauncher : NSObject

+ (UIViewController *)makeRootViewController;

@end

NS_ASSUME_NONNULL_END