#import <Flutter/Flutter.h>
#import <UIKit/UIKit.h>

/// PlatformView 方式的预览(对照 Texture):内嵌原生 MTKView,
/// process_frame 直接渲进 drawable 并由 MTKView present —— 没有 Flutter 合成器那道每帧重采样,
/// 平滑度等同原生全屏页。共享 engine 的 stabilizer 句柄(与 Texture 预览同一个)。
@interface PreviewPlatformView : NSObject <FlutterPlatformView>

- (instancetype)initWithFrame:(CGRect)frame
               viewIdentifier:(int64_t)viewId
                    arguments:(id _Nullable)args
                    messenger:(NSObject<FlutterBinaryMessenger> *)messenger
                   stabilizer:(void *_Nullable)stabilizer;

- (UIView *)view;

@end
