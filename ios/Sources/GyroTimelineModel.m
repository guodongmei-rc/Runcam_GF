#import "GyroTimelineModel.h"
#import <math.h>

@implementation GyroTimelineModel {
    // 交错存储 [c0_0,c1_0,..,cK_0, c0_1,...]，长度 = sampleCount * componentCount 个 double
    NSData *_buffer;
}

- (void)clear {
    _buffer = nil;
    _sampleCount = 0;
    _componentCount = 3;
    _maxAbsValue = 0.0;
}

- (BOOL)hasData {
    return _sampleCount > 0 && _buffer != nil;
}

- (BOOL)isQuaternion {
    return _componentCount == 4;
}

- (double)valueAtIndex:(NSInteger)index component:(NSInteger)component {
    if (_buffer == nil || index < 0 || index >= _sampleCount ||
        component < 0 || component >= _componentCount) {
        return 0.0;
    }
    const double *p = (const double *)_buffer.bytes;
    return p[index * _componentCount + component];
}

- (void)gyroAtIndex:(NSInteger)index x:(double *)x y:(double *)y z:(double *)z {
    if (x) *x = [self valueAtIndex:index component:0];
    if (y) *y = [self valueAtIndex:index component:1];
    if (z) *z = [self valueAtIndex:index component:2];
}

// 把 stabilizer 重采样到 sampleCount 个点。先按 raw gyro(3 分量)取，失败再按
// 四元数(4 分量)取——对齐官方：DJI/Xtra 等无原始角速度的源回退到 Quaternions 视图。
- (BOOL)loadFromStabilizer:(GyroflowStabilizer *)stabilizer sampleCount:(NSInteger)sampleCount {
    [self clear];
    if (stabilizer == NULL || sampleCount <= 1) {
        return NO;
    }

    NSInteger comp = 3;
    NSMutableData *buf = [NSMutableData dataWithLength:(NSUInteger)sampleCount * 3 * sizeof(double)];
    int32_t rc = gyroflow_get_gyro_timeline(stabilizer, (double *)buf.mutableBytes, (int32_t)sampleCount);
    if (rc != 0) {
        // 无原始陀螺角速度（DJI/Xtra 等）→ 回退取四元数（x,y,z,w）
        comp = 4;
        buf = [NSMutableData dataWithLength:(NSUInteger)sampleCount * 4 * sizeof(double)];
        rc = gyroflow_get_quaternion_timeline(stabilizer, (double *)buf.mutableBytes, (int32_t)sampleCount);
        if (rc != 0) {
            return NO; // 既无 gyro 也无四元数
        }
    }

    // 算各分量绝对值峰值，供 View 纵向归一化
    const double *p = (const double *)buf.bytes;
    const NSInteger total = sampleCount * comp;
    double maxAbs = 0.0;
    for (NSInteger i = 0; i < total; i++) {
        double a = fabs(p[i]);
        if (a > maxAbs) maxAbs = a;
    }

    _buffer = [buf copy];
    _sampleCount = sampleCount;
    _componentCount = comp;
    _maxAbsValue = maxAbs;
    return YES;
}

@end
