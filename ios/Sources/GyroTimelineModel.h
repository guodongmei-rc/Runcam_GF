#import <Foundation/Foundation.h>
#import "gyroflow_ffi.h"

NS_ASSUME_NONNULL_BEGIN

/// MVC - Model：整段视频的陀螺仪角速度采样数据。
///
/// 负责通过 FFI 从 GyroflowStabilizer 加载、把整段视频等间隔重采样成定长的
/// 三轴角速度序列，并算好绘制归一化用的峰值。纯数据，不含任何 UI 逻辑。
@interface GyroTimelineModel : NSObject

/// 采样点数
@property (nonatomic, readonly) NSInteger sampleCount;

/// 每点的分量数：3 = 三轴角速度(gyro)，4 = 四元数(x,y,z,w，DJI 等无 raw gyro 的源)
@property (nonatomic, readonly) NSInteger componentCount;

/// 当前数据是否为四元数（componentCount == 4）。供 View 切换曲线条数/图例。
@property (nonatomic, readonly) BOOL isQuaternion;

/// 各分量绝对值的峰值，View 绘制时用于纵向归一化；无数据时为 0
@property (nonatomic, readonly) double maxAbsValue;

/// 是否已成功加载到数据
@property (nonatomic, readonly) BOOL hasData;

/// 取第 index 个采样点的前三轴（°/s 或四元数 x,y,z）。index 越界时输出全 0。
- (void)gyroAtIndex:(NSInteger)index x:(double *)x y:(double *)y z:(double *)z;

/// 取第 index 个采样点的第 component 个分量（0..componentCount-1）。越界返回 0。
- (double)valueAtIndex:(NSInteger)index component:(NSInteger)component;

/// 从 stabilizer 加载并把整段视频重采样成 sampleCount 个点。
/// 成功返回 YES；失败（视频无陀螺仪数据等）会清空并返回 NO。
- (BOOL)loadFromStabilizer:(GyroflowStabilizer *)stabilizer sampleCount:(NSInteger)sampleCount;

/// 清空数据
- (void)clear;

@end

NS_ASSUME_NONNULL_END
