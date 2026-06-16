#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 导出相关纯工具(无状态): 文件名冲突改名 / 编解码器映射 / 默认输出高。
@interface GFExportUtils : NSObject

/// 输出文件名冲突自动改名(对齐官方 App.qml:738-748 renameOutput): 目录中已有同名 →
/// 在扩展名前加 _1.._999(已带 _N 后缀则替换); 无同名原样返回。
+ (NSURL *)uniqueURLInFolder:(NSURL *)folder forName:(NSString *)name;

/// 编解码器索引 → (AVVideoCodecType, 容器 fileType, 文件扩展名)。AVAssetWriter 可用的 3 种:
/// 0 = H.264/AVC (.mp4), 1 = H.265/HEVC (.mp4), 2 = ProRes 422 (.mov, 仅较新机型硬件支持)。
/// 任一出参可传 NULL。
+ (void)codecForIndex:(int)idx
            codecType:(AVVideoCodecType _Nullable *_Nullable)outCodec
             fileType:(AVFileType _Nullable *_Nullable)outFileType
            extension:(NSString *_Nullable *_Nullable)outExt;

/// 按宽算 16:9 偶数高(对齐官方默认输出尺寸; 偶数为编码器要求), 最小 2。
+ (uint32_t)stabilizedHeightForWidth:(uint32_t)width;

@end

NS_ASSUME_NONNULL_END
