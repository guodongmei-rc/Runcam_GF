#import <UIKit/UIKit.h>
#import "ParamsModel.h"

NS_ASSUME_NONNULL_BEGIN

/// 「缩放」组合控件子模块,嵌在「稳定」section 大卡片内 (不再单独 section)。
///
/// 控件:
///   - 3-段 UISegmentedControl: 无缩放 / 动态缩放 / 静态缩放 -> croppingMode (0/1/2),
///     对齐桌面 Stabilization.qml:612-630 的 croppingMode ComboBox (改 adaptive_zoom 字段)
///   - 缩放限额 slider (maxZoomPercent 100..300 %)
///   - 缩放速度 slider (adaptiveZoomSec 0..10 s, 仅 croppingMode=Dynamic 时生效)
///   - 缩放方式 dropdown: Gaussian filter / Envelope follower -> zoomingMethod (0/1),
///     对齐桌面 Stabilization.qml:828 (改 adaptive_zoom_method 字段)
///   - 镜头校正 slider (lensCorrection 0..1, UI 显示 0..100 %)
@interface ZoomGroupView : UIView

@property (nonatomic, weak, nullable) ParamsModel *model;

- (void)refreshFromModel;

@end

NS_ASSUME_NONNULL_END
