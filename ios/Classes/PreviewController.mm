#import "PreviewController.h"
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

#include <cmath>
#include <memory>
#include <string>

#include <mdk/Player.h>
#include <mdk/RenderAPI.h>

#import "gyroflow_ffi.h"

#define PREVIEW_POOL_N 3

// MDK 渲染目标 C 回调:返回当前应渲入的纹理(指向 _mdkInput)。
// 镜像 ViewController.mm:150 的 GyroflowDemoCurrentRenderTarget。
@class PreviewController;
static const void *PreviewCurrentRenderTarget(const void *opaque);

@interface PreviewController ()
// 供 C 回调读取的当前渲染目标(= _mdkInput)。property 自动合成 _currentRenderTarget ivar。
@property (nonatomic, strong) id<MTLTexture> currentRenderTarget;
@end

@implementation PreviewController {
  void *_stabilizer;            // 共享句柄(增量 C 起真正使用)
  CVPixelBufferRef _pool[PREVIEW_POOL_N]; // 三缓冲:onFrame 渲到当前张,完成后轮转
  CVPixelBufferRef _latest;     // 指向 _pool 当前已渲好的一张;copyPixelBuffer 返回它
  int _next;                    // 下一张轮转下标(GPU 完成回调里推进)
  int _outW;                    // 输出(防抖后)尺寸 = CVPB / _latest 尺寸
  int _outH;
  int _inW;                     // 输入(视频原生)尺寸 = _mdkInput 尺寸
  int _inH;

  // 增量 B:CADisplayLink 60Hz 帧驱动。
  CADisplayLink *_link;
  NSObject<FlutterTextureRegistry> *_registry;
  int64_t _textureId;
  NSLock *_lock;                // 保护 _latest/_next 的并发读写
  int _compositeCount;          // copyPixelBuffer 被调次数(= Flutter 合成上屏帧数)
  int _produceCount;            // GPU 产出帧数(= 真实解码+防抖出帧率)
  BOOL _tornDown;               // dispose 后置位:在飞的 GPU 完成回调据此早退,避免 UAF

  // 增量 C:Metal + MDK 解码 + Gyroflow 防抖。
  id<MTLDevice> _device;
  id<MTLCommandQueue> _queue;
  CVMetalTextureCacheRef _texCache;       // CVPB → MTLTexture 零拷贝桥
  id<MTLTexture> _mdkInput;               // MDK 解码目标(视频原生尺寸,带 RenderTarget usage)
  std::unique_ptr<mdk::Player> _player;   // MDK 播放器(.mm 里用 C++)
  mdk::MetalRenderAPI _mdkRenderAPI;      // MDK Metal RenderAPI 描述
  int64_t _lastProcessedTsUs;             // 上一帧已 process 的 ts:同一解码帧只算一次(60Hz 驱动 30fps 源)

  // 诊断(仅日志,不改功能):帧节奏探针。
  int _fovProbeN;
  int64_t _lastProbeTsUs;   // 上一帧 process 的 ts,用来数重复帧 + 步进
  int _dupSincePrint;       // 本窗口内 ts 与上一帧相同(重复处理同一解码帧)的次数
  int64_t _minDtsUs;        // 本窗口内帧间 ts 步进的最小/最大(看节奏是否均匀)
  int64_t _maxDtsUs;
}

- (instancetype)initWithStabilizer:(void *_Nullable)stabilizer {
  if (self = [super init]) {
    _stabilizer = stabilizer;
    _latest = NULL;
    _next = 0;
    _outW = 0;
    _outH = 0;
    _inW = 0;
    _inH = 0;
    _link = nil;
    _registry = nil;
    _textureId = -1;
    _lock = [[NSLock alloc] init];
    _device = nil;
    _queue = nil;
    _texCache = NULL;
    _mdkInput = nil;
    for (int i = 0; i < PREVIEW_POOL_N; i++) { _pool[i] = NULL; }
  }
  return self;
}

- (CGSize)setupWithUri:(NSString *)uri {
  // Metal 基建。
  _device = MTLCreateSystemDefaultDevice();
  _queue = [_device newCommandQueue];
  CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, _device, NULL, &_texCache);

  // 默认兜底尺寸(stabilizer 缺失或取信息失败时)。
  _inW = 1280; _inH = 720; _outW = 1280; _outH = 720;

  if (_stabilizer) {
    // 让 gyroflow 走默认 GPU 后端(Metal)。
    gyroflow_use_default_gpu((GyroflowStabilizer *)_stabilizer);
    GyroflowVideoInfo vinfo = {0};
    if (gyroflow_get_video_info((GyroflowStabilizer *)_stabilizer, &vinfo) == 0) {
      if (vinfo.width > 0 && vinfo.height > 0) {
        _inW = (int)vinfo.width;
        _inH = (int)vinfo.height;
      }
      _outW = vinfo.output_width > 0 ? (int)vinfo.output_width : _inW;
      _outH = vinfo.output_height > 0 ? (int)vinfo.output_height : _inH;
    } else {
      NSLog(@"[preview] gyroflow_get_video_info failed: %s", gyroflow_last_error());
    }
  }
  NSLog(@"[preview] setup in=%dx%d out=%dx%d", _inW, _inH, _outW, _outH);

  // 三缓冲(输出尺寸,不填纯色,内容由 GPU 渲)。
  for (int i = 0; i < PREVIEW_POOL_N; i++) {
    _pool[i] = [self makeOutputBuffer];
  }
  _latest = _pool[0];
  _next = 0;

  // MDK 解码目标纹理(视频原生尺寸,带 RenderTarget usage)。
  _mdkInput = [self makeMDKInputTextureWithWidth:_inW height:_inH];

  // MDK 播放器(镜像 ViewController.mm setupMDKPlayer / configureMDKRenderAPI)。
  [self setupMDKPlayerWithUri:uri];

  return CGSizeMake(_outW, _outH);
}

- (void)attachRegistry:(NSObject<FlutterTextureRegistry> *)registry textureId:(int64_t)textureId {
  _registry = registry;
  _textureId = textureId;
}

#pragma mark - 资源创建

// 输出 CVPixelBuffer:IOSurface 背书 + Metal 兼容 + BGRA,输出尺寸,不填内容。
- (CVPixelBufferRef)makeOutputBuffer {
  NSDictionary *attrs = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
  };
  CVPixelBufferRef pb = NULL;
  CVReturn rc = CVPixelBufferCreate(kCFAllocatorDefault, _outW, _outH,
                                    kCVPixelFormatType_32BGRA,
                                    (__bridge CFDictionaryRef)attrs, &pb);
  if (rc != kCVReturnSuccess || !pb) {
    NSLog(@"[preview] CVPixelBufferCreate failed rc=%d", (int)rc);
    return NULL;
  }
  return pb;
}

// MDK 解码目标纹理:BGRA8 + RenderTarget|ShaderRead|ShaderWrite + Private,视频输入尺寸。
// 镜像 ViewController.mm:2100 makeMDKInputTextureWithWidth:height:。
- (id<MTLTexture>)makeMDKInputTextureWithWidth:(int)width height:(int)height {
  if (width <= 0 || height <= 0) { return nil; }
  MTLTextureDescriptor *d =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                         width:width
                                                        height:height
                                                     mipmapped:NO];
  d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  d.storageMode = MTLStorageModePrivate;
  return [_device newTextureWithDescriptor:d];
}

// 镜像 ViewController.mm setupMDKPlayer + configureMDKRenderAPI。
- (void)setupMDKPlayerWithUri:(NSString *)uri {
  _player = std::make_unique<mdk::Player>();

  _mdkRenderAPI = mdk::MetalRenderAPI();
  _mdkRenderAPI.device = (__bridge const void *)_device;
  _mdkRenderAPI.cmdQueue = (__bridge const void *)_queue;
  _mdkRenderAPI.opaque = (__bridge const void *)self;
  _mdkRenderAPI.currentRenderTarget = PreviewCurrentRenderTarget;
  _mdkRenderAPI.colorFormat = (unsigned)MTLPixelFormatBGRA8Unorm;
  _player->setRenderAPI(&_mdkRenderAPI);
  _player->setAspectRatio(mdk::KeepAspectRatio);

  // renderCallback 在此驱动模式下非必需(由 CADisplayLink onFrame 轮询 renderVideo),
  // 仍按 ViewController 结构注册一个空回调(切勿在回调内调 renderVideo,会死锁)。
  _player->setRenderCallback([](void *) {});

  std::string path(uri.UTF8String ?: "");
  _player->setMedia(path.c_str());
  _player->setVideoSurfaceSize(_inW, _inH);
  _player->prepare(0);
}

#pragma mark - FlutterTexture

- (CVPixelBufferRef _Nullable)copyPixelBuffer {
  [_lock lock];
  CVPixelBufferRef pb = _latest ? CVPixelBufferRetain(_latest) : NULL; // Flutter 拿走后会 release
  _compositeCount++;
  [_lock unlock];
  return pb;
}

// 取并清零计数。编码:高位 produce(产出率)、低位 composite(合成率)。
- (int64_t)takeCompositedFrameCount {
  [_lock lock];
  int composite = _compositeCount;
  int produce = _produceCount;
  _compositeCount = 0;
  _produceCount = 0;
  [_lock unlock];
  NSLog(@"[preview] produce=%d/s composite=%d/s", produce, composite);
  return (int64_t)produce * 1000 + composite;
}

#pragma mark - 60Hz 驱动:解码 + 防抖

- (void)play {
  if (_player) { _player->set(mdk::State::Playing); }
  if (_link) {
    _link.paused = NO;
    return;
  }
  _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame)];
  if (@available(iOS 15.0, *)) {
    _link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
  }
  [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)pause {
  if (_player) { _player->set(mdk::State::Paused); }
  _link.paused = YES;
}

// 每帧:MDK 渲染到 _mdkInput → gyroflow 防抖渲染到 _pool[_next] 的 CVPB-backed 纹理。
// GPU 完成栅栏触发后才把该张设为 _latest 并通知 Flutter。
- (void)onFrame {
  if (!_player) { return; }

  // MDK 渲染目标指向解码纹理,然后驱动一次解码渲染。renderVideo 返回秒(<0 = 无可渲染帧)。
  self.currentRenderTarget = _mdkInput;
  double ts = _player->renderVideo();
  if (ts < 0.0) { return; }
  int64_t tsUs = (int64_t)llround(ts * 1.0e6);

  // 30fps 源 / 60Hz 驱动:renderVideo 必须每 tick 调(驱动 MDK 解码),但 ts 没变 = 还是上一帧,
  // 重复 process 纯浪费一倍 GPU(produce~2x),偶发把单 tick 顶过 16.6ms → 掉显示帧 = 卡顿。
  // 同一解码帧只 process 一次;Flutter 由 Dart ticker 维持 60Hz 合成,_latest 不变即按住前帧。
  if (tsUs == _lastProcessedTsUs) { return; }
  _lastProcessedTsUs = tsUs;

  // 取下一张输出缓冲,并在锁内**立即推进** _next(取帧时推进,而非完成回调里):
  // 否则 GPU 慢于帧间隔时连续两帧会选到同一张 → 三缓冲退化成单缓冲 + 撕裂。
  [_lock lock];
  int idx = _next;
  _next = (_next + 1) % PREVIEW_POOL_N;
  CVPixelBufferRef pb = _pool[idx];
  [_lock unlock];
  if (!pb) { return; }

  // CVPB → MTLTexture(零拷贝)。注意:CVMetalTextureCache 产出的纹理是否带 RenderTarget
  // usage 取决于 IOSurface/系统;若 process_frame 渲染失败,这是头号嫌疑(见回报)。
  CVMetalTextureRef cvtex = NULL;
  CVReturn rc = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, _texCache, pb, NULL,
      MTLPixelFormatBGRA8Unorm, _outW, _outH, 0, &cvtex);
  if (rc != kCVReturnSuccess || !cvtex) {
    NSLog(@"[preview] CVMetalTextureCacheCreateTextureFromImage failed rc=%d", (int)rc);
    if (cvtex) { CFRelease(cvtex); }
    return;
  }
  id<MTLTexture> outputTex = CVMetalTextureGetTexture(cvtex);

  if (_stabilizer) {
    GyroflowProcessInfo info = {0};
    int32_t r = gyroflow_process_frame_metal_bgra8(
        (GyroflowStabilizer *)_stabilizer,
        tsUs, -1,
        (__bridge void *)_mdkInput, (size_t)_inW, (size_t)_inH,
        (__bridge void *)outputTex, (size_t)_outW, (size_t)_outH,
        (__bridge void *)_queue, &info);
    if (r != 0) {
      NSLog(@"[preview] process_frame_metal_bgra8 failed: %s", gyroflow_last_error());
      CFRelease(cvtex);
      return;
    }
    // 节奏诊断(仅日志,printf 走 stdout):每秒统计帧间 ts 步进与重复帧。
    //   30fps 视频理想:每个唯一帧 process 一次,dts≈33333us、dup≈0;
    //   dup 高(~半数)→ 在重复处理同一解码帧(60Hz 轮询 30fps);
    //   dts min/max 差大 → 步进不均(judder,看着一卡一卡)。
    if (_fovProbeN > 0) {
      int64_t dts = tsUs - _lastProbeTsUs;
      if (dts == 0) { _dupSincePrint++; }
      if (_minDtsUs == 0 || dts < _minDtsUs) { _minDtsUs = dts; }
      if (dts > _maxDtsUs) { _maxDtsUs = dts; }
    }
    _lastProbeTsUs = tsUs;
    if ((_fovProbeN++ % 60) == 0) {
      printf("[preview][pace] dup/60=%d  dts(min..max)=%lld..%lldus  fov=%.3f\n",
             _dupSincePrint, (long long)_minDtsUs, (long long)_maxDtsUs, info.fov);
      _dupSincePrint = 0; _minDtsUs = 0; _maxDtsUs = 0;
      fflush(stdout);
    }
  }

  // GPU 完成栅栏:本空命令缓冲在同一队列上排在 process_frame 之后,其完成回调
  // 即代表防抖输出已写入 outputTex(= pb)。此时才轮转 _latest / 通知 Flutter。
  id<MTLCommandBuffer> cb = [_queue commandBuffer];
  __weak typeof(self) weakSelf = self;
  [cb addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull _cbuf) {
    PreviewController *s = weakSelf;
    if (!s) { return; }
    [s->_lock lock];
    if (s->_tornDown) { [s->_lock unlock]; return; } // dispose 后早退,勿触碰已释放的 pool
    s->_latest = pb;
    s->_produceCount++;
    NSObject<FlutterTextureRegistry> *reg = s->_registry;
    int64_t tid = s->_textureId;
    [s->_lock unlock];
    if (reg) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [reg textureFrameAvailable:tid];
      });
    }
  }];
  [cb commit];
  CFRelease(cvtex);
}

- (void)seekToUs:(int64_t)timestampUs {
  if (_player) { _player->seek(timestampUs / 1000); } // MDK seek 单位 ms
}

- (void)releasePool {
  [_lock lock];
  _latest = NULL;
  for (int i = 0; i < PREVIEW_POOL_N; i++) {
    if (_pool[i]) { CVPixelBufferRelease(_pool[i]); _pool[i] = NULL; }
  }
  [_lock unlock];
}

- (void)teardown {
  // 先置 _tornDown 并清 _registry(锁内):在飞的 GPU 完成回调据此早退,
  // 不再写 _latest / 不通知 Flutter,避免触碰下面 releasePool 释放掉的 pool。
  [_lock lock];
  _tornDown = YES;
  _registry = nil;
  [_lock unlock];
  if (_link) {
    [_link invalidate];
    _link = nil;
  }
  if (_player) {
    _player->set(mdk::State::Stopped);
    _player.reset();
  }
  [self releasePool];
  _mdkInput = nil;
  self.currentRenderTarget = nil;
  if (_texCache) {
    CVMetalTextureCacheFlush(_texCache, 0);
    CFRelease(_texCache);
    _texCache = NULL;
  }
}

- (void)dispose {
  [self teardown];
}

- (void)dealloc {
  [self teardown];
}

@end

static const void *PreviewCurrentRenderTarget(const void *opaque) {
  PreviewController *controller = (__bridge PreviewController *)opaque;
  return (__bridge const void *)controller.currentRenderTarget;
}
