#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 无头导出器(从旧 `ViewController.mm runExportFromURL` 抽离,供 Pigeon PreviewApi 复用)。
/// 复用调用方传入的共享 stabilizer(== 预览那一份:含上传镜头 + autosync 合成 gyro +
/// 全部参数),逐帧 AVAssetReader 解码 → gyroflow_process_frame_metal_bgra8 → AVAssetWriter 编码。
/// 导出期间把引擎 output_size 改成「夹到源内」尺寸(取景固定),需要时再 GPU 放大到目标尺寸。
@interface GFExporter : NSObject

/// stabilizer:与预览共享的 `GyroflowStabilizer *` 句柄(不持有、不释放)。
/// device/queue:必须传预览(PreviewController)所用的同一套 Metal device/command queue
/// (对齐原生 self.metalDevice/self.commandQueue);否则核心 GPU 上下文与导出队列不匹配会崩。
- (instancetype)initWithStabilizer:(void *)stabilizer
                            device:(void *)device
                             queue:(void *)queue;

/// 取消标志(原子):置 YES 后导出循环下一帧自停,返回「已取消」。
@property (atomic, assign) BOOL cancelled;

/// 同步执行导出(请在后台队列调用)。progress 在调用线程回调(0..1, frame, total)。
/// 返回 nil = 成功;否则错误。
/// trimStartUs/trimEndUs:导出裁剪区间(µs;0 表示从头/到结尾)。仅渲染该段,
/// 视频/音频输出 PTS 以裁剪起点 rebase 到 ~0(reader.timeRange + startSessionAtSourceTime)。
- (NSError *_Nullable)exportFromURL:(NSURL *)srcURL
                              toURL:(NSURL *)dstURL
                         codecIndex:(int)codecIndex
                        bitrateMbps:(int)bitrateMbps
                        exportAudio:(BOOL)exportAudio
                              outW:(uint32_t)outW
                              outH:(uint32_t)outH
                        trimStartUs:(int64_t)trimStartUs
                          trimEndUs:(int64_t)trimEndUs
                           progress:(void (^_Nullable)(double p, NSInteger frame, NSInteger total))progressBlock
    NS_SWIFT_NAME(export(fromURL:toURL:codecIndex:bitrateMbps:exportAudio:outW:outH:trimStartUs:trimEndUs:progress:));

@end

NS_ASSUME_NONNULL_END
