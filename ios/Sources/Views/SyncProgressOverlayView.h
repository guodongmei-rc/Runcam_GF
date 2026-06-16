#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 「分析中」浮窗——叠加在视频画面上的进度面板。样式对齐官方桌面版:
///   - 进度条
///   - 主文字 「分析中 X%... (fed/total @ fps)」
///   - 副文字 「耗时: <X秒, 剩余: Y秒」
///   - 「取消」链接按钮(可选,onCancel 为 nil 时隐藏)
///
/// 默认隐藏。Controller 在 autosync 期间(或其它需要分析的场景)调
/// `show... + updateProgress:`,完成时调 `hide`。
@interface SyncProgressOverlayView : UIView

/// 显示 overlay。title 例:「分析中」。onCancel 为 nil 不显示取消按钮。
- (void)showWithTitle:(NSString *)title onCancel:(nullable void(^)(void))onCancel;

/// 更新进度。 framesFed/framesTotal/fps 任一为 0 时不显示该字段。
- (void)updateProgress:(double)progress
             framesFed:(int)framesFed
           framesTotal:(int)framesTotal
                   fps:(double)fps;

/// 隐藏 overlay。
- (void)hide;

@end

NS_ASSUME_NONNULL_END
