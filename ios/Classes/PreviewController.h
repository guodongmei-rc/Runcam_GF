#import <Foundation/Foundation.h>
#import <Flutter/Flutter.h>

NS_ASSUME_NONNULL_BEGIN

/// 阶段1 预览渲染控制器。实现 FlutterTexture,把 CVPixelBuffer 交给 Flutter 合成器。
/// 增量 A:仅纯色 CVPixelBuffer;后续增量接 CADisplayLink / MDK / process_frame。
///
/// 头文件保持纯 ObjC(无 C++/CoreVideo 类型),以便经 pod umbrella header 对 Swift 可见。
@interface PreviewController : NSObject <FlutterTexture>

/// stabilizer 由调用方注入(与 EngineApiImpl 共享同一句柄)。可为 NULL(增量 A/B 不用)。
- (instancetype)initWithStabilizer:(void *_Nullable)stabilizer;

/// 建解码/CVPB 池,返回画面尺寸(增量 A:固定一个测试尺寸)。
- (CGSize)setupWithUri:(NSString *)uri;

/// 注入 Flutter 纹理注册表与 textureId(注册后由 PreviewApiImpl 回传),
/// 供增量 B 的 CADisplayLink 回调每帧调用 `textureFrameAvailable:`。
- (void)attachRegistry:(NSObject<FlutterTextureRegistry> *)registry textureId:(int64_t)textureId
    NS_SWIFT_NAME(attach(registry:textureId:));

- (void)play;
- (void)pause;
- (void)seekToUs:(int64_t)timestampUs;

/// 取并清零合成帧计数(= copyPixelBuffer 被调次数),Dart 每秒调一次得真实合成 FPS。
- (int64_t)takeCompositedFrameCount;

- (void)dispose;

@end

NS_ASSUME_NONNULL_END
