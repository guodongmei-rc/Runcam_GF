#import "GFExporter.h"
#import "GFExportUtils.h"
#import <AVFoundation/AVFoundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import "gyroflow_ffi.h"

@implementation GFExporter {
  GyroflowStabilizer *_stab; // 共享句柄,不持有/不释放
  id<MTLDevice> _device;
  id<MTLCommandQueue> _queue;
}

// device/queue 必须复用预览那一套(对齐原生 self.metalDevice/self.commandQueue):
// 核心 GPU 上下文绑在预览的 queue 上,导出另建 queue 会不匹配而崩溃。
- (instancetype)initWithStabilizer:(void *)stabilizer
                            device:(void *)device
                             queue:(void *)queue {
  if (self = [super init]) {
    _stab = (GyroflowStabilizer *)stabilizer;
    _device = (__bridge id<MTLDevice>)device;
    _queue = (__bridge id<MTLCommandQueue>)queue;
  }
  return self;
}

static NSError *gfErr(NSInteger code, NSString *msg) {
  return [NSError errorWithDomain:@"GFExport" code:code
                         userInfo:@{NSLocalizedDescriptionKey: msg}];
}

- (NSError *)exportFromURL:(NSURL *)srcURL
                     toURL:(NSURL *)dstURL
                codecIndex:(int)codecIndex
               bitrateMbps:(int)bitrateMbps
               exportAudio:(BOOL)exportAudio
                     outW:(uint32_t)outWIn
                     outH:(uint32_t)outHIn
                trimStartUs:(int64_t)trimStartUs
                  trimEndUs:(int64_t)trimEndUs
                  progress:(void (^)(double, NSInteger, NSInteger))progressBlock {
  if (_stab == NULL) return gfErr(2, @"stabilizer 未就绪");
  if (_device == nil || _queue == nil) return gfErr(3, @"Metal 不可用");

  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:srcURL
                                          options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
  // 同步等待 tracks/duration 加载完成:新版 iOS 直接访问 .tracks 在未加载时会返回空,
  // 导致误报「无视频轨道」(旧原生在已加载的 asset 上访问才没事)。
  dispatch_semaphore_t loadSem = dispatch_semaphore_create(0);
  [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"] completionHandler:^{
    dispatch_semaphore_signal(loadSem);
  }];
  dispatch_semaphore_wait(loadSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)));

  AVAssetTrack *vTrack = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  if (vTrack == nil) {
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:srcURL.path];
    return gfErr(1, [NSString stringWithFormat:@"视频无视频轨道(文件存在=%d, 路径=%@)",
                                                exists, srcURL.path]);
  }
  AVAssetTrack *aTrack = exportAudio ? [asset tracksWithMediaType:AVMediaTypeAudio].firstObject : nil;

  CGSize natural = vTrack.naturalSize;
  const uint32_t inW = (uint32_t)llround(natural.width);
  const uint32_t inH = (uint32_t)llround(natural.height);

  uint32_t outW = outWIn, outH = outHIn;
  if (outW < 2 || outH < 2) { outW = inW; outH = [GFExportUtils stabilizedHeightForWidth:inW]; }
  if (outW & 1) outW -= 1;
  if (outH & 1) outH -= 1;

  // 稳定按「夹到源内」尺寸算(取景固定,与输出分辨率无关),再放大到 outW×outH 编码(对齐 Android)。
  uint32_t clampW = outW, clampH = outH;
  double scale = MIN((double)inW / outW, (double)inH / outH);
  if (scale < 1.0) {
    clampW = ((uint32_t)llround(outW * scale)) & ~1u;
    clampH = ((uint32_t)llround(outH * scale)) & ~1u;
  }
  BOOL needUpscale = (clampW != outW || clampH != outH);
  NSLog(@"[GFExport] step1 stab=%p in=%ux%u out=%ux%u clamp=%ux%u upscale=%d", (void *)_stab, inW, inH, outW, outH, clampW, clampH, needUpscale);
  gyroflow_set_output_size_exact(_stab, clampW, clampH);
  NSLog(@"[GFExport] step2 set_output_size done, calling recompute");
  gyroflow_recompute_blocking(_stab);
  NSLog(@"[GFExport] step3 recompute done");

  // 中间稳定纹理 + 放大管线(仅放大时)。
  id<MTLTexture> stabTex = nil;
  id<MTLRenderPipelineState> upPipeline = nil;
  id<MTLSamplerState> upSampler = nil;
  if (needUpscale) {
    MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:clampW height:clampH mipmapped:NO];
    sd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    sd.storageMode = MTLStorageModePrivate;
    stabTex = [_device newTextureWithDescriptor:sd];
    NSString *src =
        @"#include <metal_stdlib>\n"
         "using namespace metal;\n"
         "struct VOut { float4 pos [[position]]; float2 uv; };\n"
         "vertex VOut up_vs(uint vid [[vertex_id]]) {\n"
         "  float2 p[3] = { float2(-1.0,-1.0), float2(3.0,-1.0), float2(-1.0,3.0) };\n"
         "  VOut o; o.pos = float4(p[vid], 0.0, 1.0);\n"
         "  o.uv = float2((p[vid].x + 1.0) * 0.5, (1.0 - p[vid].y) * 0.5);\n"
         "  return o;\n"
         "}\n"
         "fragment float4 up_fs(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
         "  return t.sample(s, in.uv);\n"
         "}\n";
    NSError *e = nil;
    id<MTLLibrary> lib = [_device newLibraryWithSource:src options:nil error:&e];
    if (lib) {
      MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
      pd.vertexFunction = [lib newFunctionWithName:@"up_vs"];
      pd.fragmentFunction = [lib newFunctionWithName:@"up_fs"];
      pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
      upPipeline = [_device newRenderPipelineStateWithDescriptor:pd error:&e];
    }
    if (upPipeline) {
      MTLSamplerDescriptor *smp = [[MTLSamplerDescriptor alloc] init];
      smp.minFilter = MTLSamplerMinMagFilterLinear;
      smp.magFilter = MTLSamplerMinMagFilterLinear;
      upSampler = [_device newSamplerStateWithDescriptor:smp];
    } else {
      needUpscale = NO; // 放大管线创建失败 → 退回不放大(直接渲进 outTex)
    }
  }

  // ===== Reader(视频) =====
  NSError *readerErr = nil;
  AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&readerErr];
  if (reader == nil) return readerErr ?: gfErr(4, @"创建 reader 失败");
  AVAssetReaderTrackOutput *vOut = [[AVAssetReaderTrackOutput alloc] initWithTrack:vTrack outputSettings:@{
    (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
  }];
  vOut.alwaysCopiesSampleData = NO;
  if (![reader canAddOutput:vOut]) return gfErr(5, @"无法添加视频读入");
  [reader addOutput:vOut];

  // 音频用独立 reader,解码成 PCM,writer 再 AAC 重编码。
  AVAssetReader *aReader = nil;
  AVAssetReaderTrackOutput *aOut = nil;
  if (aTrack) {
    NSError *ae = nil;
    aReader = [AVAssetReader assetReaderWithAsset:asset error:&ae];
    aOut = [[AVAssetReaderTrackOutput alloc] initWithTrack:aTrack outputSettings:@{
      AVFormatIDKey: @(kAudioFormatLinearPCM),
      AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @NO,
      AVLinearPCMBitDepthKey: @16, AVLinearPCMIsNonInterleaved: @NO,
    }];
    aOut.alwaysCopiesSampleData = NO;
    if (aReader && [aReader canAddOutput:aOut]) {
      [aReader addOutput:aOut];
    } else { aReader = nil; aOut = nil; }
  }

  // ===== Writer =====
  AVVideoCodecType codecType; AVFileType fileType;
  [GFExportUtils codecForIndex:codecIndex codecType:&codecType fileType:&fileType extension:NULL];
  BOOL isProRes = [codecType isEqual:AVVideoCodecTypeAppleProRes422];
  NSError *writerErr = nil;
  AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:dstURL fileType:fileType error:&writerErr];
  if (writer == nil) return writerErr ?: gfErr(6, @"创建 writer 失败");

  NSMutableDictionary *vSettings = [@{
    AVVideoCodecKey: codecType, AVVideoWidthKey: @(outW), AVVideoHeightKey: @(outH),
  } mutableCopy];
  if (!isProRes) {
    NSInteger bps = (bitrateMbps > 0) ? (NSInteger)bitrateMbps * 1000 * 1000 : 64 * 1000 * 1000;
    NSMutableDictionary *comp = [@{
      AVVideoAverageBitRateKey: @(bps), AVVideoMaxKeyFrameIntervalKey: @(30),
    } mutableCopy];
    if ([codecType isEqual:AVVideoCodecTypeH264]) comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel;
    vSettings[AVVideoCompressionPropertiesKey] = comp;
  }
  AVAssetWriterInput *vIn = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:vSettings];
  vIn.expectsMediaDataInRealTime = NO;
  vIn.transform = CGAffineTransformIdentity;
  AVAssetWriterInputPixelBufferAdaptor *adaptor =
      [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:vIn
                                                                          sourcePixelBufferAttributes:@{
    (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    (NSString *)kCVPixelBufferWidthKey: @(outW),
    (NSString *)kCVPixelBufferHeightKey: @(outH),
    (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
  }];
  [writer addInput:vIn];

  AVAssetWriterInput *aIn = nil;
  if (aOut) {
    const AudioStreamBasicDescription *asbd = NULL;
    CMFormatDescriptionRef fmt = (__bridge CMFormatDescriptionRef)aTrack.formatDescriptions.firstObject;
    if (fmt) asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
    aIn = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:@{
      AVFormatIDKey: @(kAudioFormatMPEG4AAC),
      AVNumberOfChannelsKey: @(asbd ? asbd->mChannelsPerFrame : 2),
      AVSampleRateKey: @(asbd ? asbd->mSampleRate : 48000),
      AVEncoderBitRateKey: @(192000),
    }];
    aIn.expectsMediaDataInRealTime = NO;
    if ([writer canAddInput:aIn]) [writer addInput:aIn]; else aIn = nil;
  }

  NSLog(@"[GFExport] step4 reader/writer built, starting");
  CVMetalTextureCacheRef texCache = NULL;
  CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, _device, NULL, &texCache);
  if (texCache == NULL) return gfErr(7, @"创建 MTLTextureCache 失败");

  // ===== 裁剪区间(µs→CMTime):仅导出 [trimStart, trimEnd] =====
  // reader.timeRange 让两个 reader 只产出区间内样本并自动起停;startSessionAtSourceTime:startT
  // 把「源时间 startT」映射为输出时间 0 → 视频(原始 pts append)与音频(透传)PTS 一致 rebase 到 ~0。
  const double assetDurSec = CMTimeGetSeconds(asset.duration);
  const int64_t trimStartUsC = trimStartUs > 0 ? trimStartUs : 0;
  const BOOL hasEndTrim = (trimEndUs > 0) && (assetDurSec <= 0 || (double)trimEndUs / 1.0e6 < assetDurSec);
  const CMTime trimStartT = CMTimeMake(trimStartUsC, 1000000);
  const CMTime trimDurT = hasEndTrim ? CMTimeMake(trimEndUs - trimStartUsC, 1000000) : kCMTimePositiveInfinity;
  const double trimStartSec = (double)trimStartUsC / 1.0e6;
  const double trimEndSec = hasEndTrim ? (double)trimEndUs / 1.0e6 : assetDurSec;
  const double effDurSec = (trimEndSec > trimStartSec) ? (trimEndSec - trimStartSec) : assetDurSec;
  if (trimStartUsC > 0 || hasEndTrim) {
    reader.timeRange = CMTimeRangeMake(trimStartT, trimDurT);
    if (aReader) aReader.timeRange = CMTimeRangeMake(trimStartT, trimDurT);
  }

  if (![reader startReading]) { CFRelease(texCache); return reader.error ?: gfErr(8, @"reader 启动失败"); }
  if (![writer startWriting]) { CFRelease(texCache); return writer.error ?: gfErr(9, @"writer 启动失败"); }
  [writer startSessionAtSourceTime:trimStartT]; // 全片时 trimStartT=0,等价 kCMTimeZero
  NSLog(@"[GFExport] step5 session started, entering frame loop");

  // 音频:回调式异步写入(AVFoundation 自行按节奏拉音频,writer 内部交错,不死锁)。
  dispatch_group_t audioGroup = dispatch_group_create();
  if (aOut && aIn && aReader) {
    if (![aReader startReading]) {
      [aIn markAsFinished];
    } else {
      dispatch_group_enter(audioGroup);
      dispatch_queue_t aq = dispatch_queue_create("gfexport.audio", DISPATCH_QUEUE_SERIAL);
      __block BOOL aDone = NO;
      [aIn requestMediaDataWhenReadyOnQueue:aq usingBlock:^{
        while (aIn.isReadyForMoreMediaData) {
          CMSampleBufferRef s = [aOut copyNextSampleBuffer];
          if (s == NULL) { if (!aDone) { aDone = YES; [aIn markAsFinished]; dispatch_group_leave(audioGroup); } return; }
          if (![aIn appendSampleBuffer:s]) { CFRelease(s); if (!aDone) { aDone = YES; dispatch_group_leave(audioGroup); } return; }
          CFRelease(s);
        }
      }];
    }
  }

  const double durationSec = effDurSec; // 进度按裁剪后时长(全片时 == 资源时长)
  const float fps = vTrack.nominalFrameRate;
  const NSInteger totalFrames = (fps > 0 && durationSec > 0) ? (NSInteger)llround((double)fps * durationSec) : 0;
  double lastReported = 0.0;
  NSInteger frameIdx = 0;
  BOOL ok = YES;
  NSError *loopErr = nil;

  while ([reader status] == AVAssetReaderStatusReading) {
    if (self.cancelled) { ok = NO; loopErr = gfErr(99, @"已取消"); break; }
    @autoreleasepool {
      CMSampleBufferRef sample = [vOut copyNextSampleBuffer];
      if (sample == NULL) break;
      CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
      CVPixelBufferRef inPB = CMSampleBufferGetImageBuffer(sample);
      if (inPB == NULL) { CFRelease(sample); continue; }

      CVPixelBufferRef outPB = NULL;
      if (adaptor.pixelBufferPool) {
        NSDictionary *aux = @{ (NSString *)kCVPixelBufferPoolAllocationThresholdKey: @(3) };
        int wait = 0;
        while (CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL, adaptor.pixelBufferPool,
                   (__bridge CFDictionaryRef)aux, &outPB) == kCVReturnWouldExceedAllocationThreshold) {
          if (self.cancelled || wait++ > 2000) break;
          [NSThread sleepForTimeInterval:0.005];
        }
      }
      if (outPB == NULL) {
        CVPixelBufferCreate(kCFAllocatorDefault, outW, outH, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)@{ (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES }, &outPB);
      }
      if (outPB == NULL) { CFRelease(sample); ok = NO; loopErr = gfErr(10, @"无法分配输出 PixelBuffer"); break; }

      CVMetalTextureRef inRef = NULL, outRef = NULL;
      CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, texCache, inPB, NULL, MTLPixelFormatBGRA8Unorm,
                                                CVPixelBufferGetWidth(inPB), CVPixelBufferGetHeight(inPB), 0, &inRef);
      CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, texCache, outPB, NULL, MTLPixelFormatBGRA8Unorm,
                                                outW, outH, 0, &outRef);
      id<MTLTexture> inTex = inRef ? CVMetalTextureGetTexture(inRef) : nil;
      id<MTLTexture> outTex = outRef ? CVMetalTextureGetTexture(outRef) : nil;
      if (inTex == nil || outTex == nil) {
        if (inRef) CFRelease(inRef); if (outRef) CFRelease(outRef);
        CVPixelBufferRelease(outPB); CFRelease(sample);
        ok = NO; loopErr = gfErr(11, @"创建 Metal 纹理失败"); break;
      }

      int64_t ts_us = (int64_t)llround(CMTimeGetSeconds(pts) * 1.0e6);
      GyroflowProcessInfo gfInfo = {0};
      id<MTLTexture> renderTex = needUpscale ? stabTex : outTex;
      if (frameIdx == 0) NSLog(@"[GFExport] step6 first process_frame in=%lux%lu render=%lux%lu",
                               (unsigned long)inTex.width, (unsigned long)inTex.height,
                               (unsigned long)renderTex.width, (unsigned long)renderTex.height);
      int32_t rc = gyroflow_process_frame_metal_bgra8(_stab, ts_us, -1,
          (__bridge void *)inTex, inTex.width, inTex.height,
          (__bridge void *)renderTex, renderTex.width, renderTex.height,
          (__bridge void *)_queue, &gfInfo);

      if (rc == 0 && needUpscale && upPipeline) {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = outTex;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = [_queue commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:upPipeline];
        [enc setFragmentTexture:stabTex atIndex:0];
        [enc setFragmentSamplerState:upSampler atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
      }

      CFRelease(inRef); CFRelease(outRef);

      if (rc != 0) {
        CVPixelBufferRelease(outPB); CFRelease(sample);
        ok = NO; loopErr = gfErr(12, [NSString stringWithFormat:@"防抖渲染失败:%s", gyroflow_last_error()]); break;
      }

      int wait = 0;
      while (!vIn.isReadyForMoreMediaData) {
        [NSThread sleepForTimeInterval:0.005];
        if (++wait > 2000) { ok = NO; loopErr = writer.error ?: gfErr(14, @"writer 长时间不接收"); break; }
      }
      if (!ok) { CVPixelBufferRelease(outPB); CFRelease(sample); break; }

      if (![adaptor appendPixelBuffer:outPB withPresentationTime:pts]) {
        CVPixelBufferRelease(outPB); CFRelease(sample);
        ok = NO; loopErr = writer.error ?: gfErr(15, @"appendPixelBuffer 失败"); break;
      }
      CVPixelBufferRelease(outPB); CFRelease(sample);
      CVMetalTextureCacheFlush(texCache, 0);

      frameIdx++;
      if (durationSec > 0) {
        double p = (CMTimeGetSeconds(pts) - trimStartSec) / durationSec; // pts 以裁剪起点为基准
        if (p - lastReported > 0.01) { lastReported = p; if (progressBlock) progressBlock(MIN(MAX(p, 0.0), 0.99), frameIdx, totalFrames); }
      }
    }
  }

  [vIn markAsFinished];
  CVMetalTextureCacheFlush(texCache, 0);
  CFRelease(texCache);

  if (!ok) {
    [reader cancelReading];
    [aReader cancelReading];
    dispatch_group_wait(audioGroup, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    [writer cancelWriting];
    // 删除取消/失败留下的半成品文件,避免目录里残留 + 下次导出受其干扰。
    [[NSFileManager defaultManager] removeItemAtURL:dstURL error:nil];
    return loopErr ?: gfErr(13, @"导出过程中断");
  }

  dispatch_group_wait(audioGroup, DISPATCH_TIME_FOREVER);
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

  if (writer.status != AVAssetWriterStatusCompleted) return writer.error ?: gfErr(14, @"writer 未完成");
  if (progressBlock) progressBlock(1.0, frameIdx, totalFrames > 0 ? totalFrames : frameIdx);
  return nil;
}

@end
