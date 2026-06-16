#import "GyroTimelineView.h"
#import "GFTheme.h"

@interface GyroTimelineView ()
@property (nonatomic, copy, nullable) NSArray<NSDictionary<NSString *, NSNumber *> *> *syncPoints;
@end

@implementation GyroTimelineView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.85];
        self.layer.cornerRadius = 4.0;
        self.clipsToBounds = YES;
        self.contentMode = UIViewContentModeRedraw; // bounds 变化时重绘
        _progress = 0.0;
        _videoDurationMs = 0.0;
        // 拖动游标改播放位置: 同一个 handler 兼容点击 (Tap) 和拖动 (Pan)
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(handleSeekGesture:)];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(handleSeekGesture:)];
        [self addGestureRecognizer:pan];
        [self addGestureRecognizer:tap];
        self.userInteractionEnabled = YES;
    }
    return self;
}

#pragma mark - 拖动 / 点击 seek

- (void)handleSeekGesture:(UIGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan
        && g.state != UIGestureRecognizerStateChanged
        && g.state != UIGestureRecognizerStateEnded) {
        return;
    }
    CGFloat w = self.bounds.size.width;
    if (w < 1.0) {
        return;
    }
    CGPoint p = [g locationInView:self];
    double frac = (double)(p.x / w);
    if (frac < 0.0) {
        frac = 0.0;
    }
    if (frac > 1.0) {
        frac = 1.0;
    }
    self.progress = frac;
    if (self.onSeek != nil) {
        self.onSeek(frac);
    }
}

- (void)setSyncPoints:(NSArray<NSDictionary<NSString *,NSNumber *> *> *)syncPoints {
    _syncPoints = [syncPoints copy];
    [self setNeedsDisplay];
}

- (void)setVideoDurationMs:(double)videoDurationMs {
    if (fabs(_videoDurationMs - videoDurationMs) < 1e-6) return;
    _videoDurationMs = videoDurationMs;
    [self setNeedsDisplay];
}

#pragma mark - 数据/状态变化触发重绘

- (void)setModel:(GyroTimelineModel *)model {
    _model = model;
    [self setNeedsDisplay];
}

- (void)setProgress:(double)progress {
    if (progress < 0.0) progress = 0.0;
    if (progress > 1.0) progress = 1.0;
    if (fabs(progress - _progress) < 1e-6) return;
    _progress = progress;
    [self setNeedsDisplay];
}

#pragma mark - 绘制

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    const CGFloat w = self.bounds.size.width;
    const CGFloat h = self.bounds.size.height;
    const CGFloat midY = h * 0.5;

    // 中线（0 °/s 基准）
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.2].CGColor);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextMoveToPoint(ctx, 0, midY);
    CGContextAddLineToPoint(ctx, w, midY);
    CGContextStrokePath(ctx);

    GyroTimelineModel *m = self.model;
    if (m != nil && m.hasData) {
        const NSInteger n = m.sampleCount;
        const double maxAbs = (m.maxAbsValue > 1e-6) ? m.maxAbsValue : 1.0;
        const CGFloat halfH = midY * 0.92;

        // 每分量一条颜色：gyro 三轴 X 红 / Y 绿 / Z 蓝；四元数模式多一条 W 橙。
        UIColor *colors[4] = {
            [UIColor colorWithRed:1.00 green:0.35 blue:0.35 alpha:0.95],
            [UIColor colorWithRed:0.35 green:0.95 blue:0.45 alpha:0.95],
            [UIColor colorWithRed:0.40 green:0.65 blue:1.00 alpha:0.95],
            [UIColor colorWithRed:1.00 green:0.75 blue:0.30 alpha:0.95],
        };
        const NSInteger comp = m.componentCount;
        for (int axis = 0; axis < comp; axis++) {
            CGContextSetStrokeColorWithColor(ctx, colors[axis].CGColor);
            CGContextSetLineWidth(ctx, 1.0);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            BOOL started = NO;
            for (NSInteger i = 0; i < n; i++) {
                double v = [m valueAtIndex:i component:axis];
                CGFloat px = (n > 1) ? ((CGFloat)i / (CGFloat)(n - 1) * w) : 0.0;
                CGFloat py = midY - (CGFloat)(v / maxAbs) * halfH;
                if (!started) {
                    CGContextMoveToPoint(ctx, px, py);
                    started = YES;
                } else {
                    CGContextAddLineToPoint(ctx, px, py);
                }
            }
            CGContextStrokePath(ctx);
        }
    } else {
        // 无数据占位提示
        NSString *msg = @"无陀螺仪数据";
        NSDictionary *attr = @{
            NSFontAttributeName: [UIFont systemFontOfSize:11.0],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.5],
        };
        CGSize sz = [msg sizeWithAttributes:attr];
        [msg drawAtPoint:CGPointMake((w - sz.width) / 2.0, (h - sz.height) / 2.0)
          withAttributes:attr];
    }

    // autosync 同步点: 竖线 + 下方数字标注(单位 ms)
    NSArray<NSDictionary<NSString *, NSNumber *> *> *points = self.syncPoints;
    if (points.count > 0) {
        // 数字字符串字体
        UIFont *spFont = [UIFont systemFontOfSize:9.0 weight:UIFontWeightMedium];
        NSDictionary *spAttr = @{
            NSFontAttributeName: spFont,
            NSForegroundColorAttributeName: [UIColor colorWithRed:0.20 green:0.95 blue:0.50 alpha:1.0],
        };
        UIColor *spLineColor = [UIColor colorWithRed:0.20 green:0.95 blue:0.50 alpha:0.85];

        // 数字标注横向占多少空间(避免相邻挤一起,简化处理):跟数字宽度比较再决定要不要绘制
        CGFloat textRowH = ceil(spFont.lineHeight) + 2.0;

        for (NSUInteger i = 0; i < points.count; i++) {
            NSDictionary *p = points[i];
            double midMs = [p[@"midpointMs"] doubleValue];
            double offMs = [p[@"offsetMs"] doubleValue];

            // 计算横向 x: 优先按 videoDurationMs, 否则按数组下标等距
            CGFloat sx;
            if (self.videoDurationMs > 1.0) {
                double frac = midMs / self.videoDurationMs;
                if (frac < 0.0) frac = 0.0;
                if (frac > 1.0) frac = 1.0;
                sx = (CGFloat)frac * w;
            } else {
                sx = (points.count > 1) ? ((CGFloat)i / (CGFloat)(points.count - 1)) * w : (w * 0.5);
            }

            // 竖线(从顶到底,在波形上半叠加),宽 1.5 px
            CGContextSetStrokeColorWithColor(ctx, spLineColor.CGColor);
            CGContextSetLineWidth(ctx, 1.5);
            CGContextMoveToPoint(ctx, sx, 0);
            CGContextAddLineToPoint(ctx, sx, h - textRowH);
            CGContextStrokePath(ctx);

            // 数字文本 (e.g. "49.42 毫秒"), 居中放在竖线正下方
            NSString *txt = [NSString stringWithFormat:@"%.2f 毫秒", offMs];
            CGSize txtSize = [txt sizeWithAttributes:spAttr];
            CGFloat tx = sx - txtSize.width / 2.0;
            if (tx < 2.0) tx = 2.0;
            if (tx + txtSize.width > w - 2.0) tx = w - 2.0 - txtSize.width;
            [txt drawAtPoint:CGPointMake(tx, h - textRowH + 1.0) withAttributes:spAttr];
        }
    }

    // 播放游标
    CGFloat playX = (CGFloat)self.progress * w;
    CGContextSetStrokeColorWithColor(ctx, [GFTheme primaryColor].CGColor);
    CGContextSetLineWidth(ctx, 1.5);
    CGContextMoveToPoint(ctx, playX, 0);
    CGContextAddLineToPoint(ctx, playX, h);
    CGContextStrokePath(ctx);
}


@end
