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
/// 暂停并同步排空渲染队列(等在飞的那帧 process_frame 跑完)。导出前调用,
/// 确保导出不与预览渲染循环并发访问同一 stabilizer(否则核心非线程安全 → 崩溃)。
- (void)pauseAndDrain;
- (void)seekToUs:(int64_t)timestampUs;

/// 暂停态按需重渲一帧:重置「同帧去重」标记后渲当前帧一次,让参数改动即时可见。
- (void)renderOnce;

/// 预览所用的 Metal device / command queue(以 void* 暴露,头文件保持 umbrella 友好)。
/// 导出必须复用同一套(对齐原生 self.metalDevice/self.commandQueue):核心 GPU 上下文绑在
/// 预览的 queue 上,导出若用另建的 queue 会不匹配而崩溃。
- (void *_Nullable)metalDevicePtr;
- (void *_Nullable)commandQueuePtr;

/// 取并清零合成帧计数(= copyPixelBuffer 被调次数),Dart 每秒调一次得真实合成 FPS。
- (int64_t)takeCompositedFrameCount;

- (void)dispose;

@end

NS_ASSUME_NONNULL_END
