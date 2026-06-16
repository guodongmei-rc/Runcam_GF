#import "PreviewPlatformView.h"
#import <MetalKit/MetalKit.h>

#include <cmath>
#include <memory>
#include <string>

#include <mdk/Player.h>
#include <mdk/RenderAPI.h>

#import "gyroflow_ffi.h"

// MDK 渲染目标 C 回调:返回当前应渲入的纹理(= _mdkInput)。镜像 PreviewController。
@class PreviewPlatformView;
static const void *PPVCurrentRenderTarget(const void *opaque);

@interface PreviewPlatformView () <MTKViewDelegate>
@property (nonatomic, strong) id<MTLTexture> currentRenderTarget;
@end

@implementation PreviewPlatformView {
  MTKView *_mtkView;
  void *_stabilizer;                       // 共享句柄(engine 的 stabilizer)
  id<MTLDevice> _device;
  id<MTLCommandQueue> _queue;
  id<MTLTexture> _mdkInput;                // MDK 解码目标(视频原生尺寸)
  std::unique_ptr<mdk::Player> _player;
  mdk::MetalRenderAPI _mdkRenderAPI;
  int _inW, _inH, _outW, _outH;
  BOOL _playing;
  FlutterMethodChannel *_channel;          // play/pause 控制
  int _fovProbeN;                          // 复用 Texture 那套打点风格,便于对照
  dispatch_queue_t _renderQueue;           // 专用渲染串行队列:手动驱动 [mtkView draw],不占主线程(对齐原生)
  BOOL _loopRunning;                        // 渲染循环是否在跑
}

- (instancetype)initWithFrame:(CGRect)frame
               viewIdentifier:(int64_t)viewId
                    arguments:(id)args
                    messenger:(NSObject<FlutterBinaryMessenger> *)messenger
                   stabilizer:(void *)stabilizer {
  if (self = [super init]) {
    _stabilizer = stabilizer;
    _device = MTLCreateSystemDefaultDevice();
    _queue = [_device newCommandQueue];
    _renderQueue = dispatch_queue_create("com.runcam.preview_pv.render", DISPATCH_QUEUE_SERIAL);

    _mtkView = [[MTKView alloc] initWithFrame:frame device:_device];
    _mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    _mtkView.framebufferOnly = NO;          // gyroflow 要把 drawable 当渲染目标
    _mtkView.autoResizeDrawable = NO;       // 我们显式设 drawableSize = 输出尺寸(= 原生模型)
    _mtkView.delegate = self;
    _mtkView.enableSetNeedsDisplay = NO;
    _mtkView.paused = YES;                    // 手动驱动:在 _renderQueue 上调 [draw],不占主线程(对齐原生)
    _mtkView.contentMode = UIViewContentModeScaleAspectFit;

    NSString *uri = nil;
    if ([args isKindOfClass:[NSDictionary class]]) {
      id u = ((NSDictionary *)args)[@"uri"];
      if ([u isKindOfClass:[NSString class]]) { uri = u; }
    }

    [self setupSizes];
    [self setupMDKPlayerWithUri:uri ?: @""];

    // 控制通道:Dart 侧用 runcam_gf/preview_pv_<viewId> 调 play/pause/dispose。
    _channel = [FlutterMethodChannel
        methodChannelWithName:[NSString stringWithFormat:@"runcam_gf/preview_pv_%lld", viewId]
              binaryMessenger:messenger];
    __weak typeof(self) weakSelf = self;
    [_channel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
      PreviewPlatformView *s = weakSelf;
      if (!s) { result(nil); return; }
      if ([call.method isEqualToString:@"play"]) { [s play]; result(nil); }
      else if ([call.method isEqualToString:@"pause"]) { [s pause]; result(nil); }
      else if ([call.method isEqualToString:@"dispose"]) { [s teardown]; result(nil); }
      else { result(FlutterMethodNotImplemented); }
    }];

    [self play]; // 进页自动播放
  }
  return self;
}

- (UIView *)view { return _mtkView; }

#pragma mark - 资源

- (void)setupSizes {
  _inW = 1280; _inH = 720; _outW = 1280; _outH = 720;
  if (_stabilizer) {
    gyroflow_use_default_gpu((GyroflowStabilizer *)_stabilizer);
    GyroflowVideoInfo vi = {0};
    if (gyroflow_get_video_info((GyroflowStabilizer *)_stabilizer, &vi) == 0) {
      if (vi.width > 0 && vi.height > 0) { _inW = (int)vi.width; _inH = (int)vi.height; }
      _outW = vi.output_width > 0 ? (int)vi.output_width : _inW;
      _outH = vi.output_height > 0 ? (int)vi.output_height : _inH;
    }
  }
  NSLog(@"[preview_pv] setup in=%dx%d out=%dx%d", _inW, _inH, _outW, _outH);
  _mdkInput = [self makeInputTexWithWidth:_inW height:_inH];
  _mtkView.drawableSize = CGSizeMake(_outW, _outH); // drawable == gyroflow 输出尺寸(原生约束)
}

- (id<MTLTexture>)makeInputTexWithWidth:(int)w height:(int)h {
  if (w <= 0 || h <= 0) { return nil; }
  MTLTextureDescriptor *d =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                         width:w
                                                        height:h
                                                     mipmapped:NO];
  d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  d.storageMode = MTLStorageModePrivate;
  return [_device newTextureWithDescriptor:d];
}

- (void)setupMDKPlayerWithUri:(NSString *)uri {
  _player = std::make_unique<mdk::Player>();
  _mdkRenderAPI = mdk::MetalRenderAPI();
  _mdkRenderAPI.device = (__bridge const void *)_device;
  _mdkRenderAPI.cmdQueue = (__bridge const void *)_queue;
  _mdkRenderAPI.opaque = (__bridge const void *)self;
  _mdkRenderAPI.currentRenderTarget = PPVCurrentRenderTarget;
  _mdkRenderAPI.colorFormat = (unsigned)MTLPixelFormatBGRA8Unorm;
  _player->setRenderAPI(&_mdkRenderAPI);
  _player->setAspectRatio(mdk::KeepAspectRatio);
  _player->setRenderCallback([](void *) {});
  std::string path(uri.UTF8String ?: "");
  _player->setMedia(path.c_str());
  _player->setVideoSurfaceSize(_inW, _inH);
  _player->prepare(0);
  _player->set(mdk::State::Playing);
}

#pragma mark - 播放控制

- (void)play {
  if (_player) { _player->set(mdk::State::Playing); }
  _playing = YES;
  if (_loopRunning) { return; }
  _loopRunning = YES;
  dispatch_async(_renderQueue, ^{ [self renderTick]; }); // 在专用队列上启动渲染循环
}

- (void)pause {
  _playing = NO;
  _loopRunning = NO; // 循环下一拍自停
  if (_player) { _player->set(mdk::State::Paused); }
}

// 在 _renderQueue 上手动驱动 MTKView 渲染:[draw] 同步触发 drawInMTKView(也在本队列执行),
// 不占主线程。限速到 ~60fps(渲染慢于 16.6ms 则背靠背),避免空跑产热。
- (void)renderTick {
  if (!_loopRunning) { return; }
  CFTimeInterval t0 = CACurrentMediaTime();
  [_mtkView draw]; // 同步:drawInMTKView 在此调用线程(= _renderQueue)执行
  if (!_loopRunning) { return; }
  double spentMs = (CACurrentMediaTime() - t0) * 1000.0;
  double delayMs = 16.6 - spentMs;
  if (delayMs < 0) { delayMs = 0; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)),
                 _renderQueue, ^{ [self renderTick]; });
}

#pragma mark - MTKViewDelegate(原生直出:渲进 drawable + present,无 Flutter 重采样)

- (void)drawInMTKView:(MTKView *)view {
  if (!_player || !_playing) { return; }
  id<CAMetalDrawable> drawable = view.currentDrawable;
  if (drawable == nil) { return; }

  // MDK 解码 → _mdkInput。
  self.currentRenderTarget = _mdkInput;
  double ts = _player->renderVideo();
  if (ts < 0.0) { return; }
  int64_t tsUs = (int64_t)llround(ts * 1.0e6);

  // gyroflow 防抖:input=_mdkInput,output=drawable.texture(= 屏幕 surface,直出)。
  if (_stabilizer) {
    GyroflowProcessInfo info = {0};
    CFTimeInterval t0 = CACurrentMediaTime();
    int32_t r = gyroflow_process_frame_metal_bgra8(
        (GyroflowStabilizer *)_stabilizer,
        tsUs, -1,
        (__bridge void *)_mdkInput, (size_t)_inW, (size_t)_inH,
        (__bridge void *)drawable.texture, (size_t)drawable.texture.width, (size_t)drawable.texture.height,
        (__bridge void *)_queue, &info);
    double procMs = (CACurrentMediaTime() - t0) * 1000.0;
    if (r != 0) {
      NSLog(@"[preview_pv] process_frame failed: %s", gyroflow_last_error());
      return;
    }
    if ((_fovProbeN++ % 60) == 0) {
      printf("[preview_pv][pace] proc=%.1fms fov=%.3f out=%dx%d\n", procMs, info.fov, _outW, _outH);
      fflush(stdout);
    }
  }

  // present:drawable 就是显示 surface,系统合成器直接翻到屏上(无 Flutter 重采样)。
  id<MTLCommandBuffer> cb = [_queue commandBuffer];
  [cb presentDrawable:drawable];
  [cb commit];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
  // drawableSize 由我们显式锁定为输出尺寸,这里不处理 view 尺寸变化(只缩放显示)。
}

#pragma mark - 生命周期

- (void)teardown {
  _playing = NO;
  _loopRunning = NO;
  // 排空渲染队列:等在飞的 [draw]/drawInMTKView 跑完,再释放 _player/_mdkInput,避免 UAF。
  if (_renderQueue) { dispatch_sync(_renderQueue, ^{}); }
  _mtkView.paused = YES;
  _mtkView.delegate = nil;
  if (_channel) { [_channel setMethodCallHandler:nil]; _channel = nil; }
  if (_player) {
    _player->set(mdk::State::Stopped);
    _player.reset();
  }
  _mdkInput = nil;
  self.currentRenderTarget = nil;
}

- (void)dealloc {
  [self teardown];
}

@end

static const void *PPVCurrentRenderTarget(const void *opaque) {
  PreviewPlatformView *v = (__bridge PreviewPlatformView *)opaque;
  return (__bridge const void *)v.currentRenderTarget;
}
