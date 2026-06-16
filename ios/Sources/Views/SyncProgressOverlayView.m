#import "SyncProgressOverlayView.h"
#import "GFTheme.h"

// 对齐官方 Util.js timeToStr(与安卓一致): d天h时m分s秒, 全 0 → "< 1秒"
static NSString *GFTimeToStr(double sec) {
    double v = fmod(sec, 31536000.0);
    int d = (int)floor(v / 86400.0); v = fmod(v, 86400.0);
    int h = (int)floor(v / 3600.0);  v = fmod(v, 3600.0);
    int m = (int)floor(v / 60.0);
    int s = (int)round(fmod(v, 60.0));
    if (d || h || m || s) {
        NSMutableString *r = [NSMutableString string];
        if (d) [r appendFormat:@"%d天", d];
        if (h) [r appendFormat:@"%d时", h];
        if (m) [r appendFormat:@"%d分", m];
        [r appendFormat:@"%d秒", s];
        return r;
    }
    return @"< 1秒";
}

@interface SyncProgressOverlayView ()
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIProgressView *progressBar;
@property (nonatomic, strong) UILabel *mainLabel;     // 「分析中 X.XX% (a/b @ C.Cfps)」(对齐安卓/官方)
@property (nonatomic, strong) UILabel *etaLabel;      // 「耗时: X。剩余: Y」(timeToStr)
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, copy, nullable) void(^onCancelHandler)(void);
@property (nonatomic, copy, nullable) NSString *currentTitle;
@property (nonatomic, strong) NSDate *startedAt;
@end

@implementation SyncProgressOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.hidden = YES;
        self.userInteractionEnabled = YES;
        self.backgroundColor = [UIColor clearColor];

        // panel: 圆角半透黑底
        _panel = [UIView new];
        _panel.translatesAutoresizingMaskIntoConstraints = NO;
        _panel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.85];
        _panel.layer.cornerRadius = 8.0;
        [self addSubview:_panel];

        // 进度条
        _progressBar = [UIProgressView new];
        _progressBar.translatesAutoresizingMaskIntoConstraints = NO;
        _progressBar.progressTintColor = [GFTheme primaryColor];
        _progressBar.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.2];
        [_panel addSubview:_progressBar];

        // 主文字
        _mainLabel = [UILabel new];
        _mainLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _mainLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
        _mainLabel.textColor = [UIColor whiteColor];
        _mainLabel.textAlignment = NSTextAlignmentCenter;
        [_panel addSubview:_mainLabel];

        // 副文字
        _etaLabel = [UILabel new];
        _etaLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _etaLabel.font = [UIFont systemFontOfSize:11.0];
        _etaLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
        _etaLabel.textAlignment = NSTextAlignmentCenter;
        [_panel addSubview:_etaLabel];

        // 取消按钮(链接样式)
        _cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_cancelButton setTitle:@"取消" forState:UIControlStateNormal];
        _cancelButton.titleLabel.font = [UIFont systemFontOfSize:12.0];
        [_cancelButton setTitleColor:[UIColor colorWithRed:0.4 green:0.65 blue:1.0 alpha:1.0]
                            forState:UIControlStateNormal];
        [_cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:_cancelButton];

        // 布局: panel 居中, 宽 260, 高自适应内容
        [NSLayoutConstraint activateConstraints:@[
            [_panel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_panel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_panel.widthAnchor   constraintEqualToConstant:260.0],

            [_progressBar.topAnchor       constraintEqualToAnchor:_panel.topAnchor      constant:16.0],
            [_progressBar.leadingAnchor   constraintEqualToAnchor:_panel.leadingAnchor  constant:20.0],
            [_progressBar.trailingAnchor  constraintEqualToAnchor:_panel.trailingAnchor constant:-20.0],

            [_mainLabel.topAnchor         constraintEqualToAnchor:_progressBar.bottomAnchor constant:10.0],
            [_mainLabel.leadingAnchor     constraintEqualToAnchor:_panel.leadingAnchor      constant:12.0],
            [_mainLabel.trailingAnchor    constraintEqualToAnchor:_panel.trailingAnchor     constant:-12.0],

            [_etaLabel.topAnchor          constraintEqualToAnchor:_mainLabel.bottomAnchor   constant:6.0],
            [_etaLabel.leadingAnchor      constraintEqualToAnchor:_panel.leadingAnchor      constant:12.0],
            [_etaLabel.trailingAnchor     constraintEqualToAnchor:_panel.trailingAnchor     constant:-12.0],

            [_cancelButton.topAnchor      constraintEqualToAnchor:_etaLabel.bottomAnchor    constant:4.0],
            [_cancelButton.centerXAnchor  constraintEqualToAnchor:_panel.centerXAnchor],
            [_cancelButton.bottomAnchor   constraintEqualToAnchor:_panel.bottomAnchor       constant:-12.0],
        ]];
    }
    return self;
}

#pragma mark - Public

- (void)showWithTitle:(NSString *)title onCancel:(void (^)(void))onCancel {
    self.currentTitle = title ?: @"分析中";
    self.onCancelHandler = onCancel;
    self.cancelButton.hidden = (onCancel == nil);
    self.startedAt = [NSDate date];
    self.progressBar.progress = 0.0;
    self.mainLabel.text = [NSString stringWithFormat:@"%@ 0.00%%", self.currentTitle];
    self.etaLabel.text = @"";
    self.hidden = NO;
}

- (void)updateProgress:(double)progress
             framesFed:(int)framesFed
           framesTotal:(int)framesTotal
                   fps:(double)fps {
    if (self.hidden) return;
    if (progress < 0.0) progress = 0.0;
    if (progress > 1.0) progress = 1.0;
    [self.progressBar setProgress:(float)progress animated:YES];

    // 完全对齐安卓(=官方 Util.js calculateTimesAndFps): percent 两位小数, raw 不钳制;
    // fps = 当前帧/已耗时秒; remaining = 已耗时/progress − 已耗时; 时间用 timeToStr。
    (void)fps; // 改为自算(与官方一致), 忽略外部传入
    double elapsedMs = self.startedAt ? (-[self.startedAt timeIntervalSinceNow]) * 1000.0 : 0.0;
    NSString *fpsText = @"";
    NSString *line2 = @"";
    if (progress > 0.0 && progress <= 1.0 && self.startedAt) {
        double remainingMs = elapsedMs / progress - elapsedMs;
        if (remainingMs > 5.0 || elapsedMs > 5.0) {
            line2 = [NSString stringWithFormat:@"耗时: %@。剩余: %@",
                     GFTimeToStr(elapsedMs / 1000.0), GFTimeToStr(remainingMs / 1000.0)];
        }
        if (elapsedMs > 5.0 && framesFed > 0) {
            fpsText = [NSString stringWithFormat:@" @ %.1ffps", framesFed / (elapsedMs / 1000.0)];
        }
    }
    NSString *framesText = (framesTotal > 0)
        ? [NSString stringWithFormat:@" (%d/%d%@)", framesFed, framesTotal, fpsText] : @"";
    self.mainLabel.text = [NSString stringWithFormat:@"%@ %.2f%%%@",
                           self.currentTitle ?: @"", progress * 100.0, framesText];
    self.etaLabel.text = line2;
}

- (void)hide {
    self.hidden = YES;
    self.onCancelHandler = nil;
    self.startedAt = nil;
}

- (void)cancelTapped {
    if (self.onCancelHandler) self.onCancelHandler();
}

@end
