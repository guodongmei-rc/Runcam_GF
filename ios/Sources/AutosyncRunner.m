#import "AutosyncRunner.h"
#import <UIKit/UIKit.h>          // iOS 上 NSValue valueWithCGPoint:/CGPointValue 在 UIKit 里
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Accelerate/Accelerate.h>  // vImage 用于 Y 平面下采样

@interface AutosyncRunner ()
@property (nonatomic, strong) NSURL *videoURL;
@property (nonatomic, assign) GyroflowStabilizer *stab;
@property (nonatomic, assign) GyroflowAutosyncSession *session;  // FFI session,从 start 拿到
@property (nonatomic, assign) BOOL cancelRequested;              // 由 main 设,bg 检查
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong) NSThread *workerThread;
@property (nonatomic, strong, nullable) NSTimer *progressTimer;
@property (nonatomic, assign) int framesFed;
@property (nonatomic, assign) int framesExpected;
@end

@implementation AutosyncRunner

- (instancetype)initWithVideoURL:(NSURL *)videoURL stabilizer:(GyroflowStabilizer *)stab {
    self = [super init];
    if (self) {
        _videoURL = videoURL;
        _stab = stab;
        // 默认值（对齐官方 Synchronization.qml）
        _initialOffsetMs             = 0.0;
        _searchSizeSec               = 5.0;
        _maxSyncPoints               = 3;
        _everyNthFrame               = 1;
        _timePerSyncpointSec         = 1.5;
        _ofMethod                    = 2;   // OpenCV DIS
        _poseMethod                  = 0;   // findEssentialMat
        _offsetMethod                = 2;   // rs-sync
        _calcInitialFast             = NO;
        _checkNegativeInitialOffset  = NO;
        _autoSyncPointsExperimental  = YES;
    }
    return self;
}

- (void)dealloc {
    [self destroySession];
}

- (void)destroySession {
    if (_session) {
        gyroflow_autosync_free(_session);
        _session = NULL;
    }
}

#pragma mark - Public

- (void)start {
    if (self.running) return;
    if (!self.stab || !self.videoURL) {
        if (self.onFailed) self.onFailed(@"stabilizer 或 video URL 为空");
        return;
    }

    // 1) 在主线程拉起 FFI session(轻量,只是构造 SyncParams + on_progress 回调注册)
    self.session = gyroflow_autosync_start(
        self.stab,
        self.initialOffsetMs,
        self.searchSizeSec,
        self.maxSyncPoints,
        self.everyNthFrame,
        self.timePerSyncpointSec,
        self.ofMethod,
        self.poseMethod,
        self.offsetMethod,
        self.calcInitialFast            ? 1 : 0,
        self.checkNegativeInitialOffset ? 1 : 0,
        self.autoSyncPointsExperimental ? 1 : 0
    );
    if (!self.session) {
        const char *err = gyroflow_last_error();
        NSString *errStr = (err && err[0]) ? [NSString stringWithUTF8String:err] : @"未知错误";
        NSLog(@"[Autosync] gyroflow_autosync_start failed: %@", errStr);
        if (self.onFailed) self.onFailed([@"gyroflow_autosync_start 失败:" stringByAppendingString:errStr]);
        return;
    }

    // 2) 拿 ranges。每对 (from_ms, to_ms) 都要解码喂帧。
    NSMutableArray<NSValue *> *ranges = [self fetchRanges];
    if (ranges.count == 0) {
        [self destroySession];
        if (self.onFailed) self.onFailed(@"没有可用的同步点范围");
        return;
    }

    self.cancelRequested = NO;
    self.framesFed = 0;
    self.running = YES;

    // 3) 启动进度 timer(主线程,每 0.1s 读 FFI 进度)
    __weak typeof(self) weakSelf = self;
    self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull t) {
        __strong typeof(weakSelf) sSelf = weakSelf;
        if (!sSelf || !sSelf.session) { [t invalidate]; return; }
        double p = gyroflow_autosync_get_progress(sSelf.session);
        // 用核心 on_progress 的真实 (ready, total) —— 对齐官方, 分子不会超过分母, 总数就是 /N。
        uint32_t ready = 0, total = 0;
        gyroflow_autosync_get_frames(sSelf.session, &ready, &total);
        // total 在喂帧初期可能还是 0(回调未触发), 回退到估算值避免显示 /0。
        int curFrame = (int)ready;
        int totFrame = (total > 0) ? (int)total : sSelf.framesExpected;
        if (sSelf.onProgress) sSelf.onProgress(p, curFrame, totFrame);
    }];

    // 4) 后台线程跑解码 + feed + finish
    NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(workerThreadMain:) object:ranges];
    t.name = @"gyroflow.autosync.worker";
    t.qualityOfService = NSQualityOfServiceUserInitiated;
    self.workerThread = t;
    [t start];
}

- (void)cancel {
    if (!self.running) return;
    self.cancelRequested = YES;
    if (self.session) gyroflow_autosync_cancel(self.session);
}

#pragma mark - Ranges

- (NSMutableArray<NSValue *> *)fetchRanges {
    NSMutableArray<NSValue *> *result = [NSMutableArray array];
    if (!self.session) return result;
    uint32_t maxPairs = self.maxSyncPoints;
    if (maxPairs == 0) return result;
    double *buf = (double *)calloc(maxPairs * 2, sizeof(double));
    int32_t n = gyroflow_autosync_get_ranges(self.session, buf, maxPairs);
    for (int i = 0; i < n; i++) {
        double from_ms = buf[i * 2];
        double to_ms   = buf[i * 2 + 1];
        // NSRange 不够表达 double,用 CGPoint 凑(x=from_ms, y=to_ms)
        CGPoint p = CGPointMake(from_ms, to_ms);
        [result addObject:[NSValue valueWithCGPoint:p]];
    }
    free(buf);
    return result;
}

#pragma mark - Worker

- (void)workerThreadMain:(NSMutableArray<NSValue *> *)ranges {
    @autoreleasepool {
        // 1) 打开 asset + 找 video track
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:self.videoURL options:nil];
        AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        if (!videoTrack) {
            [self failOnMain:@"找不到视频轨"];
            return;
        }
        double fps = videoTrack.nominalFrameRate;
        if (fps < 1.0) fps = 30.0;

        // **策略 v5**:连续解整段视频,按 stride 抽帧到 ~10fps 采样率。
        // 关键观察:
        // - Arc<GrayImage> 在 AKAZE extract 完成后立即 drop,不会全部堆住
        // - 稳态队列长度 ~ decode_rate × akaze_per_frame_ms ≈ 10 帧
        // - 持久存储的只有 descriptors(13KB/帧),180 帧才 2.3MB
        // - 加上 iOS 解码缓冲、Metal 上下文,峰值 ~150MB,jetsam 安全
        // - 100ms 采样间隔对 AKAZE 还能匹特征(相机不会在 100ms 内完全变样)
        // - 覆盖整段视频 → 合成 gyro 时间线覆盖整段
        double totalSec = CMTimeGetSeconds(asset.duration);

        // 对齐官方(controller.rs:480/532: start_decoder_only(get_ranges)): 只分析同步点范围,
        // 不再覆盖为整段视频。ranges 来自 gyroflow_autosync_get_ranges(传入本方法), 保持不动。
        // 抽帧 stride = 1: 每帧都喂(官方默认 every_nth=1)。
        int decodeStride = 1;
        self.everyNthFrame = (uint32_t)decodeStride;
        // 总帧数与官方同口径: Σ 各同步范围时长 × 帧率 ÷ stride
        double rangesSec = 0.0;
        for (NSValue *rv in ranges) { CGPoint rp = [rv CGPointValue]; rangesSec += MAX(0.0, (rp.y - rp.x) / 1000.0); }
        self.framesExpected = (int)round(rangesSec * fps / decodeStride);
        NSLog(@"[Autosync] worker  strategy=official-ranges  totalSec=%.2f  rangesSec=%.2f  decodeStride=%d  framesExpected=%d  fps=%.2f",
              totalSec, rangesSec, decodeStride, self.framesExpected, fps);

        // 2) 按顺序处理每个 range
        uint32_t globalFrameNo = 0;
        for (NSUInteger i = 0; i < ranges.count; i++) {
            if (self.cancelRequested) break;
            CGPoint p = [ranges[i] CGPointValue];
            NSLog(@"[Autosync] >>> processRange #%lu  from=%.1fms to=%.1fms", (unsigned long)i, p.x, p.y);
            BOOL ok = [self processRangeFromMs:p.x toMs:p.y
                                       asset:asset videoTrack:videoTrack
                              frameNoCounter:&globalFrameNo];
            NSLog(@"[Autosync] <<< processRange #%lu  ok=%d  framesFed_so_far=%d", (unsigned long)i, ok, self.framesFed);
            if (!ok && self.cancelRequested) break;
            // 单段失败不致命,继续下一段
        }

        if (self.cancelRequested) {
            [self failOnMain:@"用户取消"];
            return;
        }

        // 3) finish(阻塞,内部跑光流 + find_offsets;A方案下不应用 offsets 到 gyro)
        NSLog(@"[Autosync] all ranges done, calling gyroflow_autosync_finish  framesFed=%d", self.framesFed);
        double offsetMs = 0.0;
        // 准备 syncpoint buffer(双精度,交错 [mid_0, off_0, mid_1, off_1, ...])
        const uint32_t kCap = 32;  // 32 个 syncpoint 足够(实际通常 5)
        double syncBuf[kCap * 2];
        uint32_t syncCount = 0;
        int32_t rc = gyroflow_autosync_finish(self.session, self.stab, &offsetMs,
                                              syncBuf, kCap, &syncCount);
        NSLog(@"[Autosync] gyroflow_autosync_finish returned rc=%d offsetMs=%.3f syncPoints=%u", rc, offsetMs, syncCount);
        if (rc != 0) {
            const char *err = gyroflow_last_error();
            NSString *errStr = (err && err[0]) ? [NSString stringWithUTF8String:err] : @"未知错误";
            NSLog(@"[Autosync] gyroflow_autosync_finish failed: %@", errStr);
            [self failOnMain:[@"自动同步失败:" stringByAppendingString:errStr]];
            return;
        }

        // 把 syncpoint 数组打包成 NSArray<NSDictionary>
        NSMutableArray *syncPoints = [NSMutableArray arrayWithCapacity:syncCount];
        for (uint32_t i = 0; i < syncCount; i++) {
            [syncPoints addObject:@{
                @"midpointMs": @(syncBuf[i * 2]),
                @"offsetMs":   @(syncBuf[i * 2 + 1]),
            }];
        }

        // 4) 成功,回主线程
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.progressTimer invalidate];
            self.progressTimer = nil;
            [self destroySession];
            self.running = NO;
            if (self.onFinished) self.onFinished(offsetMs, [syncPoints copy]);
        });
    }
}

- (BOOL)processRangeFromMs:(double)fromMs toMs:(double)toMs
                     asset:(AVURLAsset *)asset
                videoTrack:(AVAssetTrack *)videoTrack
            frameNoCounter:(uint32_t *)pFrameNo {

    NSError *err = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
    if (!reader) {
        NSLog(@"[Autosync] AVAssetReader alloc failed: %@", err);
        return NO;
    }

    CMTime fromT = CMTimeMakeWithSeconds(fromMs / 1000.0, 600);
    CMTime durT  = CMTimeMakeWithSeconds((toMs - fromMs) / 1000.0, 600);
    reader.timeRange = CMTimeRangeMake(fromT, durT);

    // NV12 输出,Y 平面就是灰度
    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    };
    AVAssetReaderTrackOutput *out = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:settings];
    out.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:out]) {
        NSLog(@"[Autosync] cannot add reader output");
        return NO;
    }
    [reader addOutput:out];

    if (![reader startReading]) {
        NSLog(@"[Autosync] startReading failed: status=%ld error=%@", (long)reader.status, reader.error);
        return NO;
    }
    double fps = videoTrack.nominalFrameRate;
    if (fps < 1.0) fps = 30.0;
    NSLog(@"[Autosync] reader started OK, beginning decode loop (fps=%.2f for frame_no calc)", fps);

    // 用 finalStride 抽帧(在 workerThreadMain 里已算好放进 self.everyNthFrame)
    const uint32_t stride_frames = MAX(1u, self.everyNthFrame);
    uint32_t decodedInRange = 0;
    while (1) {
        @autoreleasepool {
            if (self.cancelRequested) {
                [reader cancelReading];
                return NO;
            }
            CMSampleBufferRef sb = [out copyNextSampleBuffer];
            if (!sb) break;

            // 抽帧:只喂每第 stride_frames 个,其它直接丢
            BOOL feedThis = (decodedInRange % stride_frames == 0);
            decodedInRange++;

            if (!feedThis) {
                CFRelease(sb);
                continue;
            }

            CVImageBufferRef ib = CMSampleBufferGetImageBuffer(sb);
            if (!ib) { CFRelease(sb); continue; }

            CVPixelBufferLockBaseAddress(ib, kCVPixelBufferLock_ReadOnly);

            size_t w      = CVPixelBufferGetWidthOfPlane(ib, 0);
            size_t h      = CVPixelBufferGetHeightOfPlane(ib, 0);
            size_t stride = CVPixelBufferGetBytesPerRowOfPlane(ib, 0);
            uint8_t *plane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(ib, 0);

            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
            int64_t ts_us = (int64_t)round(CMTimeGetSeconds(pts) * 1e6);

            if (plane && w > 0 && h > 0) {
                if (self.framesFed == 0) {
                    NSLog(@"[Autosync] first frame about to feed: w=%zu h=%zu stride=%zu ts_us=%lld", w, h, stride, ts_us);
                }
                // 处理分辨率 720p —— 对齐官方「处理分辨率 720p」。不降分辨率。
                // 30fps 全帧率 540 帧靠背压(in-flight ≤4 帧)钳住内存峰值。
                const size_t targetH = 720;
                if (h > targetH) {
                    size_t targetW = (size_t)round(((double)w / (double)h) * targetH);
                    if (targetW % 2 != 0) targetW -= 1;
                    size_t downStride = targetW; // 紧凑无 padding
                    uint8_t *downBuf = (uint8_t *)malloc(downStride * targetH);
                    if (downBuf) {
                        vImage_Buffer src = {
                            .data = plane,
                            .width = w,
                            .height = h,
                            .rowBytes = stride,
                        };
                        vImage_Buffer dst = {
                            .data = downBuf,
                            .width = targetW,
                            .height = targetH,
                            .rowBytes = downStride,
                        };
                        vImage_Error verr = vImageScale_Planar8(&src, &dst, NULL, kvImageHighQualityResampling);
                        if (verr == kvImageNoError) {
                            if (self.framesFed == 0) {
                                NSLog(@"[Autosync] after vImageScale: targetW=%zu targetH=%zu downStride=%zu", targetW, targetH, downStride);
                            }
                            // frame_no 改回全局自增 —— 现在策略是连续解整段视频
                            // 按 stride 抽帧,gyroflow 内部 (frame_no, frame_no+1) 配对
                            // 才能成对,如果用时间戳算 frame_no(0, 3, 6, ...)就配不上对了。
                            uint32_t frameNo = (*pFrameNo)++;
                            gyroflow_autosync_feed_frame(
                                self.session,
                                ts_us,
                                frameNo,
                                (uint32_t)targetW,
                                (uint32_t)targetH,
                                (uint32_t)downStride,
                                downBuf,
                                downStride * targetH
                            );
                            if (self.framesFed == 0) {
                                NSLog(@"[Autosync] first feed_frame returned");
                            }
                            self.framesFed++;
                            if (self.framesFed % 10 == 0) {
//                                NSLog(@"[Autosync] fed %d frames", self.framesFed);
                            }
                            // **背压**:iOS HW 解码远快于 OpenCV pose 估算,不控制的话
                            // rayon 队列堆满 Arc<GrayImage> 把内存撑爆(OOM)。这里等
                            // 待处理队列降到阈值以下再继续 feed,把 in-flight 帧数
                            // 钳在 ~12 帧(12×480p ≈ 5MB),内存稳定。
                            while (!self.cancelRequested) {
                                int pending = gyroflow_autosync_pending_count(self.session);
                                if (pending < 4) break;
                                usleep(20000); // 20ms
                            }
                        } else {
                            NSLog(@"[Autosync] vImageScale failed: %ld", (long)verr);
                        }
                        free(downBuf);
                    }
                } else {
                    // 已经 ≤ 720p,直接喂原图
                    gyroflow_autosync_feed_frame(
                        self.session,
                        ts_us,
                        (*pFrameNo)++,
                        (uint32_t)w,
                        (uint32_t)h,
                        (uint32_t)stride,
                        plane,
                        stride * h
                    );
                    self.framesFed++;
                }
            }

            CVPixelBufferUnlockBaseAddress(ib, kCVPixelBufferLock_ReadOnly);
            CFRelease(sb);
        }
    }

    return reader.status == AVAssetReaderStatusCompleted;
}

#pragma mark - Helpers

- (void)failOnMain:(NSString *)reason {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.progressTimer invalidate];
        self.progressTimer = nil;
        [self destroySession];
        self.running = NO;
        if (self.onFailed) self.onFailed(reason);
    });
}

@end
