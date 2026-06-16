#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 播放控制条(常驻预览下方): 播放/暂停 + 防抖开关, 等宽横排。
/// 按钮以只读属性暴露, Controller 自行挂 target 与读写状态。
@interface PlaybackControlRowView : UIStackView

@property (nonatomic, strong, readonly) UIButton *playPauseButton;     // 初始「暂停」, 禁用
@property (nonatomic, strong, readonly) UIButton *stabilizationButton; // 初始「开启防抖」, 禁用

@end

NS_ASSUME_NONNULL_END
