#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 预览区(videoView)上的全部叠加 UI(从 ViewController 抽出):
///   底部半透明状态文字 / 右上 FPS(默认隐藏) / 左上陀螺角速度(默认隐藏) /
///   左上 时间·帧·缩放 / 镜头缺失黄条(默认隐藏) / 无视频「选择文件」虚线占位框。
/// 自身对触摸透明: 只有占位框可点, 其余区域事件穿透到下层。
/// 子控件以只读属性暴露, Controller 直接读写其内容/显隐(引用方式与抽出前一致)。
@interface PreviewHUDView : UIView

@property (nonatomic, strong, readonly) UILabel *statusLabel;       // 底部状态文字
@property (nonatomic, strong, readonly) UILabel *fpsLabel;          // 右上 FPS / 性能(默认隐藏)
@property (nonatomic, strong, readonly) UILabel *gyroLabel;         // 左上陀螺角速度(默认隐藏)
@property (nonatomic, strong, readonly) UILabel *playInfoLabel;     // 左上 时间/帧/缩放
@property (nonatomic, strong, readonly) UIView  *lensWarningBanner; // 镜头缺失黄条(默认隐藏)
@property (nonatomic, strong, readonly) UIView  *dropPlaceholder;   // 「选择文件」占位框

/// 占位框点击(= 打开文件)。
@property (nonatomic, copy, nullable) void(^onSelectFile)(void);

@end

NS_ASSUME_NONNULL_END
