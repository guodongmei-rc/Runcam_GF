#import "PreviewHUDView.h"

#pragma mark - 内部: 虚线占位框(自绘虚线边, 随尺寸重绘)

@interface GFDashedPlaceholderView : UIView
@end

@implementation GFDashedPlaceholderView {
    CAShapeLayer *_dashLayer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _dashLayer = [CAShapeLayer layer];
        _dashLayer.strokeColor = [UIColor colorWithWhite:0.55 alpha:1.0].CGColor;
        _dashLayer.fillColor = [UIColor clearColor].CGColor;
        _dashLayer.lineWidth = 1.5;
        _dashLayer.lineDashPattern = @[@7, @5];
        [self.layer addSublayer:_dashLayer];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _dashLayer.frame = self.bounds;
    _dashLayer.path = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:6.0].CGPath;
}

@end

#pragma mark - PreviewHUDView

@interface PreviewHUDView ()
@property (nonatomic, strong, readwrite) UILabel *statusLabel;
@property (nonatomic, strong, readwrite) UILabel *fpsLabel;
@property (nonatomic, strong, readwrite) UILabel *gyroLabel;
@property (nonatomic, strong, readwrite) UILabel *playInfoLabel;
@property (nonatomic, strong, readwrite) UIView  *lensWarningBanner;
@property (nonatomic, strong, readwrite) UIView  *dropPlaceholder;
@end

@implementation PreviewHUDView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self buildOverlays];
    }
    return self;
}

// 半透明黑底等宽字 overlay 标签的公共样式
- (UILabel *)overlayLabelWithFontSize:(CGFloat)size weight:(UIFontWeight)weight {
    UILabel *l = [[UILabel alloc] init];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.numberOfLines = 0;
    l.font = [UIFont monospacedSystemFontOfSize:size weight:weight];
    l.textColor = UIColor.whiteColor;
    l.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.55];
    l.textAlignment = NSTextAlignmentLeft;
    l.layer.cornerRadius = 4.0;
    l.clipsToBounds = YES;
    return l;
}

- (void)buildOverlays {
    // 底部状态文字
    self.statusLabel = [self overlayLabelWithFontSize:10.0 weight:UIFontWeightRegular];
    self.statusLabel.text = @"  选择视频后由 MDK 播放;开启/关闭防抖不会重启播放器。  ";
    [self addSubview:self.statusLabel];

    // 右上 FPS / 性能(按需关闭, 默认隐藏)
    self.fpsLabel = [self overlayLabelWithFontSize:11.0 weight:UIFontWeightSemibold];
    self.fpsLabel.textAlignment = NSTextAlignmentCenter;
    self.fpsLabel.text = @"  -- fps  ffi --ms  ";
    self.fpsLabel.hidden = YES;
    [self addSubview:self.fpsLabel];

    // 左上陀螺角速度(按需求隐藏)
    self.gyroLabel = [self overlayLabelWithFontSize:11.0 weight:UIFontWeightSemibold];
    self.gyroLabel.text = @" Gyro (°/s)\n  X  --\n  Y  --\n  Z  -- ";
    self.gyroLabel.hidden = YES;
    [self addSubview:self.gyroLabel];

    // 左上 时间/帧/缩放(gyroLabel 已隐藏, 直接贴顶)
    self.playInfoLabel = [self overlayLabelWithFontSize:11.0 weight:UIFontWeightSemibold];
    self.playInfoLabel.text = @" 时间 --:-- / --:--\n 帧 --/--\n 缩放 --% ";
    [self addSubview:self.playInfoLabel];

    // 镜头档案缺失警告横幅: 琥珀黄底深色字(对齐桌面黄条), 默认隐藏。
    // 容器(背景/圆角) + 内层 label(文字, 四周内边距)实现内边距。
    self.lensWarningBanner = [[UIView alloc] init];
    self.lensWarningBanner.translatesAutoresizingMaskIntoConstraints = NO;
    self.lensWarningBanner.backgroundColor = [UIColor colorWithRed:0.96 green:0.62 blue:0.07 alpha:0.95];
    self.lensWarningBanner.layer.cornerRadius = 8.0;
    self.lensWarningBanner.clipsToBounds = YES;
    self.lensWarningBanner.hidden = YES;
    UILabel *lensWarnText = [[UILabel alloc] init];
    lensWarnText.translatesAutoresizingMaskIntoConstraints = NO;
    lensWarnText.numberOfLines = 0;
    lensWarnText.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    lensWarnText.textColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    lensWarnText.textAlignment = NSTextAlignmentCenter;
    lensWarnText.text = @"镜头配置文件并未加载，结果看起来可能会不正确，请为您的相机和镜头加载镜头配置文件。";
    [self.lensWarningBanner addSubview:lensWarnText];
    [self addSubview:self.lensWarningBanner];

    // 无视频时的「选择文件」占位框(对齐官方中间预览区拖放占位; iOS 点击=打开文件)
    self.dropPlaceholder = [GFDashedPlaceholderView new];
    self.dropPlaceholder.translatesAutoresizingMaskIntoConstraints = NO;
    self.dropPlaceholder.backgroundColor = [UIColor clearColor];
    self.dropPlaceholder.userInteractionEnabled = YES;
    UILabel *phLabel = [UILabel new];
    phLabel.text = @"选择文件";
    phLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    phLabel.font = [UIFont systemFontOfSize:18.0];
    phLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.dropPlaceholder addSubview:phLabel];
    UITapGestureRecognizer *phTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(placeholderTapped)];
    [self.dropPlaceholder addGestureRecognizer:phTap];
    [self addSubview:self.dropPlaceholder];

    [NSLayoutConstraint activateConstraints:@[
        // 底部状态文字
        [self.statusLabel.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor  constant:8.0],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8.0],
        [self.statusLabel.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor   constant:-8.0],
        // 右上 FPS
        [self.fpsLabel.topAnchor      constraintEqualToAnchor:self.topAnchor      constant:8.0],
        [self.fpsLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8.0],
        [self.fpsLabel.heightAnchor   constraintEqualToConstant:22.0],
        [self.fpsLabel.widthAnchor    constraintGreaterThanOrEqualToConstant:160.0],
        // 左上陀螺角速度
        [self.gyroLabel.topAnchor     constraintEqualToAnchor:self.topAnchor     constant:8.0],
        [self.gyroLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8.0],
        [self.gyroLabel.widthAnchor   constraintGreaterThanOrEqualToConstant:120.0],
        // 左上 时间/帧/缩放
        [self.playInfoLabel.topAnchor     constraintEqualToAnchor:self.topAnchor     constant:8.0],
        [self.playInfoLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8.0],
        [self.playInfoLabel.widthAnchor   constraintGreaterThanOrEqualToConstant:160.0],
        // 黄条: 时间/帧/缩放 下方 8pt, 左右内缩 8pt; 内层文字四周内边距(横 12 / 纵 7)
        [self.lensWarningBanner.topAnchor      constraintEqualToAnchor:self.playInfoLabel.bottomAnchor constant:8.0],
        [self.lensWarningBanner.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor   constant:8.0],
        [self.lensWarningBanner.trailingAnchor constraintEqualToAnchor:self.trailingAnchor  constant:-8.0],
        [lensWarnText.topAnchor      constraintEqualToAnchor:self.lensWarningBanner.topAnchor      constant:7.0],
        [lensWarnText.bottomAnchor   constraintEqualToAnchor:self.lensWarningBanner.bottomAnchor   constant:-7.0],
        [lensWarnText.leadingAnchor  constraintEqualToAnchor:self.lensWarningBanner.leadingAnchor  constant:12.0],
        [lensWarnText.trailingAnchor constraintEqualToAnchor:self.lensWarningBanner.trailingAnchor constant:-12.0],
        // 占位框: 虚框只包住文字(加内边距), 整体居中, 不铺满
        [self.dropPlaceholder.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [self.dropPlaceholder.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [phLabel.leadingAnchor  constraintEqualToAnchor:self.dropPlaceholder.leadingAnchor  constant:18.0],
        [phLabel.trailingAnchor constraintEqualToAnchor:self.dropPlaceholder.trailingAnchor constant:-18.0],
        [phLabel.topAnchor      constraintEqualToAnchor:self.dropPlaceholder.topAnchor      constant:10.0],
        [phLabel.bottomAnchor   constraintEqualToAnchor:self.dropPlaceholder.bottomAnchor   constant:-10.0],
    ]];
}

- (void)placeholderTapped {
    if (self.onSelectFile) {
        self.onSelectFile();
    }
}

// 空白区触摸穿透: 命中自身(非子控件)时返回 nil, 让事件落到下层(videoView/手势)。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}

@end
