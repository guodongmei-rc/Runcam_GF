#import <UIKit/UIKit.h>
#import "ParamsModel.h"

NS_ASSUME_NONNULL_BEGIN

/// 「稳定」section 的「高级选项 #1」折叠区子模块。
///
/// 对应桌面 Stabilization.qml 里 default_algo.rs 标记 `advanced=true` 的 smoothing
/// 参数 + per_axis ON 时显露的 3 个分轴平滑度:
///   - 视轴 (per_axis)               BOOL   checkbox
///   - Pitch 平滑度 (smoothness_pitch) double 0.001..1.0  per_axis ON 时显示
///   - Yaw   平滑度 (smoothness_yaw)   double 0.001..1.0  per_axis ON 时显示
///   - Roll  平滑度 (smoothness_roll)  double 0.001..1.0  per_axis ON 时显示
///   - 仅限修建范围内 (trim_range_only) BOOL  checkbox
///   - 最大水平速度 (max_smoothness)   double 0.1..5.0 s
///   - 高速最大平滑度 (alpha_0_1s)     double 0.01..1.0 s
///
/// 设计原则:
///   - View 只渲染 + 触发意图;所有 setter 走 ParamsModel,FFI 由 Model 调
///   - per_axis 切换时需要通知父 view 同步隐藏 / 显示主 smoothness slider
@interface StabilizeAdvancedView : UIView

@property (nonatomic, weak, nullable) ParamsModel *model;

/// per_axis 切换时回调给父级 (StabilizeSectionView), 让父级根据 perAxis ON/OFF
/// 同步隐藏 / 显示主 smoothness slider。block 参数 = 当前 perAxis 状态。
@property (nonatomic, copy, nullable) void (^onPerAxisChanged)(BOOL perAxisOn);

/// 父 view 加载完 model 后调一次,把控件的初值刷成 model 的当前值。
- (void)refreshFromModel;

/// 按平滑算法(0=无/1=默认/2=纯3D/3=固定)配置高级区各行显隐。
/// 纯3D 只保留「仅限修建范围内」。
- (void)configureForMethod:(int)method;

@end

NS_ASSUME_NONNULL_END
