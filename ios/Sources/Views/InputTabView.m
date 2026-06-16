#import "InputTabView.h"
#import "GFTheme.h"
#import "GFViewKit.h"

#pragma mark - 方向指示器 View（按官方 MotionData.qml 的 Canvas 翻译为 Core Graphics）

// 四元数辅助 (w,x,y,z, scalar-first, 和 gyroflow 一致)
static inline void gfQuatRotate(const double q[4], double vx, double vy, double vz, double out[3]) {
    double w = q[0], x = q[1], y = q[2], z = q[3];
    double tx = 2.0 * (y * vz - z * vy);
    double ty = 2.0 * (z * vx - x * vz);
    double tz = 2.0 * (x * vy - y * vx);
    out[0] = vx + w * tx + (y * tz - z * ty);
    out[1] = vy + w * ty + (z * tx - x * tz);
    out[2] = vz + w * tz + (x * ty - y * tx);
}
static inline void gfQuatMul(const double a[4], const double b[4], double out[4]) {
    out[0] = a[0]*b[0] - a[1]*b[1] - a[2]*b[2] - a[3]*b[3];
    out[1] = a[0]*b[1] + a[1]*b[0] + a[2]*b[3] - a[3]*b[2];
    out[2] = a[0]*b[2] - a[1]*b[3] + a[2]*b[0] + a[3]*b[1];
    out[3] = a[0]*b[3] + a[1]*b[2] - a[2]*b[1] + a[3]*b[0];
}

@interface GFOrientationIndicatorView : UIView {
    double _rawQ[4];   // 原始姿态 (w,x,y,z)
    double _smQ[4];    // 平滑姿态 (w,x,y,z)
}
@end
@implementation GFOrientationIndicatorView
- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        _rawQ[0] = 1.0; _rawQ[1] = _rawQ[2] = _rawQ[3] = 0.0;  // identity
        _smQ[0]  = 1.0; _smQ[1]  = _smQ[2]  = _smQ[3]  = 0.0;
    }
    return self;
}
// raw/sm 各 4 个 double (w,x,y,z)。对齐官方 quats_at_timestamp 的逐帧驱动。
- (void)updateRaw:(const double *)raw smoothed:(const double *)sm {
    if (raw) { for (int i = 0; i < 4; i++) _rawQ[i] = raw[i]; }
    if (sm)  { for (int i = 0; i < 4; i++) _smQ[i]  = sm[i];  }
    [self setNeedsDisplay];
}
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    const CGFloat w = self.bounds.size.width;
    const CGFloat h = self.bounds.size.height;
    const CGFloat midY = h * 0.5;
    const CGFloat veclen = MIN(30.0, h * 0.35);

    // 官方 dark style 配色
    UIColor *redA   = [UIColor colorWithRed:1.0  green:0.0  blue:0.0  alpha:1.0];
    UIColor *grnA   = [UIColor colorWithRed:0.0  green:1.0  blue:0.0  alpha:1.0];
    UIColor *bluA   = [UIColor colorWithRed:0.27 green:0.27 blue:1.0  alpha:1.0];
    UIColor *axisColors[3] = { redA, grnA, bluA };
    UIColor *main   = [UIColor colorWithWhite:1.0 alpha:0.9];

    // 3 个 cell 的中心圆点（cell 1 / 2 / 3，等分）
    CGContextSetFillColorWithColor(ctx, main.CGColor);
    for (int i = 0; i < 3; i++) {
        CGFloat cx = w / 6.0 * (i * 2 + 1);
        CGContextFillEllipseInRect(ctx, CGRectMake(cx - 3, midY - 3, 6, 6));
    }

    // Cell 1：RGB 三轴 —— 按原始姿态四元数旋转(对齐官方 transform.times(vecs[i]))
    // 官方 vecs: xv=(0,veclen,0)红, yv=(-veclen,0,0)绿, zv=(0,0,veclen)蓝
    CGFloat cx1 = w / 6.0;
    const double axisVecs[3][3] = {
        {     0.0, veclen,    0.0 },   // X 红
        { -veclen,    0.0,    0.0 },   // Y 绿
        {     0.0,    0.0, veclen },   // Z 蓝
    };
    for (int i = 0; i < 3; i++) {
        double tv[3];
        gfQuatRotate(_rawQ, axisVecs[i][0], axisVecs[i][1], axisVecs[i][2], tv);
        CGFloat ex = cx1 + tv[0];
        CGFloat ey = midY - tv[1];
        CGContextSetStrokeColorWithColor(ctx, axisColors[i].CGColor);
        CGContextSetFillColorWithColor(ctx, axisColors[i].CGColor);
        CGContextSetLineWidth(ctx, 3.0);
        CGContextSetAlpha(ctx, 0.5);
        CGContextMoveToPoint(ctx, cx1, midY);
        CGContextAddLineToPoint(ctx, ex, ey);
        CGContextStrokePath(ctx);
        // 端点圆点透明度按 z 投影深度(对齐官方 z/(veclen*2)+0.5)
        CGFloat dotAlpha = MAX(0.1, MIN(tv[2] / (veclen * 2.0) + 0.5, 1.0));
        CGContextSetAlpha(ctx, dotAlpha);
        CGContextFillEllipseInRect(ctx, CGRectMake(ex - 4, ey - 4, 8, 8));
    }
    CGContextSetAlpha(ctx, 1.0);

    // Cell 2 / 3：相机 frustum 线框 —— 中格按原始姿态(rawQ)、右格按平滑姿态旋转。
    // 对齐官方: transforms=[transform, transform_smooth],
    //   transform_smooth = transform * smoothed.inverted() = rawQ * conj(smQ)
    // 官方 3D 顶点: v0..v3=后框, v4=顶点(0,0,0); 投影用 (x, -y)。
    const double camVerts[5][3] = {
        { -30.0, -15.0, -30.0 },
        {  30.0, -15.0, -30.0 },
        {  30.0,  15.0, -30.0 },
        { -30.0,  15.0, -30.0 },
        {   0.0,   0.0,   0.0 },
    };
    const int lines[3][5] = {
        { 0, 1, 2, 3, 0 },
        { 0, 4, 1, -1, -1 },
        { 2, 4, 3, -1, -1 },
    };
    double smConj[4] = { _smQ[0], -_smQ[1], -_smQ[2], -_smQ[3] };  // 平滑姿态的逆(单位四元数=共轭)
    double transformSmooth[4];
    gfQuatMul(_rawQ, smConj, transformSmooth);
    const double *viewQ[2] = { _rawQ, transformSmooth };

    UIColor *frustumColor = [UIColor colorWithWhite:1.0 alpha:0.8];
    CGContextSetStrokeColorWithColor(ctx, frustumColor.CGColor);
    CGContextSetLineWidth(ctx, 1.5);
    CGContextSetLineJoin(ctx, kCGLineJoinBevel);
    for (int view = 0; view < 2; view++) {
        CGFloat ccx = w / 6.0 * (view * 2 + 3);   // 中格=w/2, 右格=5w/6
        for (int li = 0; li < 3; li++) {
            BOOL started = NO;
            for (int pi = 0; pi < 5; pi++) {
                int vi = lines[li][pi];
                if (vi < 0) break;
                double tv[3];
                gfQuatRotate(viewQ[view], camVerts[vi][0], camVerts[vi][1], camVerts[vi][2], tv);
                CGFloat px = ccx + tv[0];
                CGFloat py = midY - tv[1];
                if (!started) { CGContextMoveToPoint(ctx, px, py); started = YES; }
                else { CGContextAddLineToPoint(ctx, px, py); }
            }
            CGContextStrokePath(ctx);
        }
    }
    CGContextSetAlpha(ctx, 1.0);
}
@end


@interface InputTabView () <UITextFieldDelegate>
// 视频信息行的 value label,按 key 存
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *> *infoValueLabels;
@property (nonatomic, strong) UIStackView *videoInfoStack;            // 视频信息列(供动态追加录制参数行)
@property (nonatomic, strong) NSMutableArray<UIView *> *extraInfoRows; // 动态追加的 recording_settings 行, 换视频时清掉
@property (nonatomic, strong) UITextField *lensSearchField;
@property (nonatomic, strong) UIStackView *lensResultsStack;
@property (nonatomic, strong) UILabel *loadedLensLabel;
@property (nonatomic, strong) UILabel *motionStatusLabel;

// 镜头档案详情字段（按截图）
@property (nonatomic, strong) UIView *lensWarningBanner;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *> *lensInfoValueLabels;
@property (nonatomic, strong) UIButton *lensAdvancedToggle;
@property (nonatomic, strong) UIStackView *lensAdvancedContainer;
@property (nonatomic, strong) UIButton *underwaterCheckbox;
// 标定数值 fx/fy/cx/cy/k1..k4 一律 dictionary 取，不再分 8 个 property
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *> *calibValueLabels;

// 运动数据面板（按截图）—— 每行 = checkbox + 展开 view (+ 输入字段)
@property (nonatomic, strong) UILabel     *motionFormatValue;
@property (nonatomic, strong) UILabel     *motionFileNameValue;

@property (nonatomic, strong) UIButton    *motionOpenButton;   // 运动数据「打开文件」(无视频时禁用)
@property (nonatomic, strong) UIButton    *videoDirHintButton;     // 视频信息·蓝色目录授权提示框(无运动数据/镜头时显示)

// 外挂运动数据文件专属(对齐官方 MotionData.qml:213/227: 仅外挂文件场景显示)
@property (nonatomic, strong) UIView      *allMetadataRow;
@property (nonatomic, strong) UIButton    *allMetadataCheckbox;
@property (nonatomic, strong) UIView      *frameOffsetRow;
@property (nonatomic, strong) UIButton    *frameOffsetCheckbox;
@property (nonatomic, strong) UIView      *frameOffsetExpanded;
@property (nonatomic, strong) UITextField *frameOffsetField;

@property (nonatomic, strong) UIButton    *lpfCheckbox;
@property (nonatomic, strong) UIView      *lpfExpanded;
@property (nonatomic, strong) UITextField *lpfHzField;

@property (nonatomic, strong) UIButton    *medianCheckbox;
@property (nonatomic, strong) UIView      *medianExpanded;
@property (nonatomic, strong) UITextField *medianSamplesField;

@property (nonatomic, strong) UIButton    *rotationCheckbox;
@property (nonatomic, strong) UIView      *rotationExpanded;
@property (nonatomic, strong) UITextField *pitchField;
@property (nonatomic, strong) UITextField *rollField;
@property (nonatomic, strong) UITextField *yawField;

@property (nonatomic, strong) UIButton    *gyroBiasCheckbox;
@property (nonatomic, strong) UIView      *gyroBiasExpanded;
@property (nonatomic, strong) UITextField *biasXField;
@property (nonatomic, strong) UITextField *biasYField;
@property (nonatomic, strong) UITextField *biasZField;

@property (nonatomic, strong) UITextField *imuOrientationField;
@property (nonatomic, strong) UIButton    *integrationMethodDropdown;
@property (nonatomic, assign) BOOL        integrationHasQuats;   // 当前下拉列表是否含 "None"(对齐安卓 hasQuaternions)

@property (nonatomic, strong) UIButton    *orientIndicatorCheckbox;
@property (nonatomic, strong) UIView      *orientIndicatorExpanded;
@property (nonatomic, strong) GFOrientationIndicatorView *orientationIndicator;
@end

@implementation InputTabView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _infoValueLabels = [NSMutableDictionary dictionary];
        _lensInfoValueLabels = [NSMutableDictionary dictionary];
        _calibValueLabels = [NSMutableDictionary dictionary];
        [self buildUI];
    }
    return self;
}

#pragma mark - UI 构建

- (void)buildUI {
    UIStackView *root = [[UIStackView alloc] init];
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 16.0;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:self.topAnchor],
        [root.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [root.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];

    [root addArrangedSubview:[self buildVideoInfoSection]];
    [root addArrangedSubview:[self buildLensSection]];
    [root addArrangedSubview:[self buildMotionSection]];
}

- (UIView *)card {
    UIView *v = [UIView new];
    v.backgroundColor = [GFTheme secondaryBackgroundColor];
    v.layer.cornerRadius = 6.0;
    return v;
}

- (UILabel *)sectionTitle:(NSString *)t {
    UILabel *l = [UILabel new];
    l.text = t;
    l.font = [UIFont boldSystemFontOfSize:15.0];
    l.textColor = [GFTheme textColor];
    return l;
}

- (UIButton *)primaryButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [GFViewKit primaryButtonWithTitle:title];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

// 视频信息:打开文件 + 一列 key:value
- (UIView *)buildVideoInfoSection {
    UIView *card = [self card];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
    ]];

    [stack addArrangedSubview:[self sectionTitle:@"视频信息"]];

    UIButton *openBtn = [self primaryButton:@"打开文件" action:@selector(openVideoTapped)];
    [stack addArrangedSubview:openBtn];

    // 蓝色目录授权提示框 —— 对齐官方 VideoInformation.qml:164-178 InfoMessageSmall(Info=蓝):
    // 视频载入后没有运动数据/镜头信息时显示, 点击弹目录授权, 授权后自动扫描同名文件。
    UIButton *dirHint = [UIButton buttonWithType:UIButtonTypeSystem];
    [dirHint setTitle:@"为了自动检测运动数据和镜头文件,请点击此处并授权视频所在目录" forState:UIControlStateNormal];
    dirHint.titleLabel.font = [UIFont systemFontOfSize:12.0];
    dirHint.titleLabel.numberOfLines = 0;
    dirHint.titleLabel.textAlignment = NSTextAlignmentCenter;
    [dirHint setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    dirHint.backgroundColor = [UIColor systemBlueColor];
    dirHint.layer.cornerRadius = 6.0;
    dirHint.clipsToBounds = YES;
    dirHint.contentEdgeInsets = UIEdgeInsetsMake(8, 10, 8, 10);
    [dirHint addTarget:self action:@selector(motionFolderHintTapped) forControlEvents:UIControlEventTouchUpInside];
    dirHint.hidden = YES;
    _videoDirHintButton = dirHint;
    [stack addArrangedSubview:dirHint];

    NSArray<NSArray<NSString *> *> *rows = @[
        @[@"文件名称", @"fileName"], @[@"检测到的相机", @"cam"], @[@"检测镜头", @"lens"],
        @[@"尺寸", @"size"], @[@"时长", @"duration"], @[@"帧速率", @"fps"],
        @[@"编码解码器", @"codec"], @[@"像素格式", @"pixfmt"], @[@"音频", @"audio"],
        @[@"旋转", @"rotation"], @[@"包含陀螺仪数据", @"hasGyro"],
    ];
    for (NSArray<NSString *> *r in rows) {
        [stack addArrangedSubview:[self infoRowLabel:r[0] key:r[1]]];
    }
    self.videoInfoStack = stack;
    self.extraInfoRows = [NSMutableArray array];
    return card;
}

// 设置/刷新「录制参数」动态行(对齐官方 VideoArea.qml: additional_data.recording_settings)。
// 只显示存在的键; 换视频/无数据时清空。键→中文标签 + 顺序对齐官方 VideoInformation.qml。
- (void)setRecordingSettings:(NSDictionary *)settings {
    for (UIView *row in self.extraInfoRows) {
        [row removeFromSuperview];
    }
    [self.extraInfoRows removeAllObjects];
    if (![settings isKindOfClass:[NSDictionary class]] || settings.count == 0) {
        return;
    }
    NSArray<NSArray<NSString *> *> *labels = @[
        @[@"Focal length", @"焦距"],      @[@"Focus mode", @"对焦方式"],
        @[@"Iris", @"光圈"],              @[@"ISO", @"ISO"],
        @[@"Shutter angle", @"快门角度"],  @[@"Shutter speed", @"快门速度"],
        @[@"Exposure", @"曝光"],          @[@"White balance mode", @"白平衡模式"],
        @[@"White balance", @"白平衡"],    @[@"Color primaries", @"色彩原色"],
        @[@"Gamma equation", @"Gamma 曲线"],
    ];
    NSMutableSet *shown = [NSMutableSet set];
    void (^addRow)(NSString *, NSString *) = ^(NSString *label, NSString *value) {
        if (value.length == 0) return;
        UIView *row = [self extraInfoRowLabel:label value:value];
        [self.videoInfoStack addArrangedSubview:row];
        [self.extraInfoRows addObject:row];
    };
    for (NSArray<NSString *> *pair in labels) {
        id v = settings[pair[0]];
        if (v) { addRow(pair[1], [NSString stringWithFormat:@"%@", v]); [shown addObject:pair[0]]; }
    }
    // 兜底: 映射表里没有的键, 按原 key 显示
    [settings enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
        if (![shown containsObject:k]) { addRow(k, [NSString stringWithFormat:@"%@", v]); }
    }];
}

// 静态信息行(不进 infoValueLabels), 用于动态录制参数。样式同 infoRowLabel。
- (UIView *)extraInfoRowLabel:(NSString *)label value:(NSString *)value {
    UILabel *k = [UILabel new];
    k.text = label;
    k.font = [UIFont systemFontOfSize:12.0];
    k.textColor = [GFTheme secondaryTextColor];
    [k setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *v = [UILabel new];
    v.text = value;
    v.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    v.textColor = [GFTheme textColor];
    v.textAlignment = NSTextAlignmentRight;
    v.numberOfLines = 0;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[k, v]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 12.0;
    row.alignment = UIStackViewAlignmentTop;
    return row;
}

- (UIView *)infoRowLabel:(NSString *)label key:(NSString *)key {
    UILabel *k = [UILabel new];
    k.text = label;
    k.font = [UIFont systemFontOfSize:12.0];
    k.textColor = [GFTheme secondaryTextColor];
    [k setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *v = [UILabel new];
    v.text = @"---";
    v.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    v.textColor = [GFTheme textColor];
    v.textAlignment = NSTextAlignmentRight;
    v.numberOfLines = 0;
    self.infoValueLabels[key] = v;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[k, v]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 12.0;
    row.alignment = UIStackViewAlignmentTop;
    return row;
}

// 镜头配置:搜索框 + 结果 + 已加载名 + 打开/创建 + 警告 + 详情 + 高级
- (UIView *)buildLensSection {
    UIView *card = [self card];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
    ]];

    [stack addArrangedSubview:[self sectionTitle:@"镜头配置文件"]];

    _lensSearchField = [UITextField new];
    _lensSearchField.placeholder = @"搜索...";
    _lensSearchField.borderStyle = UITextBorderStyleRoundedRect;
    _lensSearchField.font = [UIFont systemFontOfSize:14.0];
    _lensSearchField.textColor = [GFTheme textColor];
    _lensSearchField.backgroundColor = [GFTheme backgroundColor];
    _lensSearchField.returnKeyType = UIReturnKeySearch;
    _lensSearchField.accessibilityIdentifier = @"lensSearch";
    _lensSearchField.delegate = self;
    _lensSearchField.clearButtonMode = UITextFieldViewModeAlways;
    [_lensSearchField addTarget:self action:@selector(lensSearchChanged) forControlEvents:UIControlEventEditingChanged];
    [stack addArrangedSubview:_lensSearchField];

    _lensResultsStack = [[UIStackView alloc] init];
    _lensResultsStack.axis = UILayoutConstraintAxisVertical;
    _lensResultsStack.spacing = 2.0;
    [stack addArrangedSubview:_lensResultsStack];

    // 打开文件（占满一行；「创建新的」按需求移除）
    UIButton *openBtn = [self primaryButton:@"打开文件" action:@selector(openLensFileTapped)];
    [stack addArrangedSubview:openBtn];

    // 非官方警告横幅（默认隐藏）
    _lensWarningBanner = [self buildLensWarningBanner];
    _lensWarningBanner.hidden = YES;
    [stack addArrangedSubview:_lensWarningBanner];

    _loadedLensLabel = [UILabel new];
    _loadedLensLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    _loadedLensLabel.textColor = [UIColor systemGreenColor];
    _loadedLensLabel.numberOfLines = 0;
    _loadedLensLabel.text = @"未加载镜头档案";
    [stack addArrangedSubview:_loadedLensLabel];

    // 镜头详情字段
    NSArray<NSArray<NSString *> *> *rows = @[
        @[@"相机",     @"camera"],
        @[@"镜头",     @"lens"],
        @[@"设置",     @"setting"],
        @[@"其他信息", @"otherInfo"],
        @[@"尺寸",     @"dimension"],
        @[@"校准人",   @"calibrator"],
    ];
    for (NSArray<NSString *> *r in rows) {
        [stack addArrangedSubview:[self lensDetailRowLabel:r[0] key:r[1]]];
    }

    // 「高级」展开按钮
    _lensAdvancedToggle = [UIButton buttonWithType:UIButtonTypeSystem];
    [_lensAdvancedToggle setTitle:@"高级 ▾" forState:UIControlStateNormal];
    [_lensAdvancedToggle setTitleColor:[GFTheme primaryColor] forState:UIControlStateNormal];
    _lensAdvancedToggle.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    [_lensAdvancedToggle addTarget:self action:@selector(advancedLensToggleTapped) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:_lensAdvancedToggle];

    _lensAdvancedContainer = [self buildLensAdvancedContainer];
    [GFViewKit applyAdvancedExpandStyle:_lensAdvancedContainer];   // 高级区与主背景区分
    _lensAdvancedContainer.hidden = YES;
    [stack addArrangedSubview:_lensAdvancedContainer];

    // 导出 STMap
//    UIButton *stmapBtn = [UIButton buttonWithType:UIButtonTypeSystem];
//    [stmapBtn setTitle:@"导出 STMap" forState:UIControlStateNormal];
//    [stmapBtn setTitleColor:[GFTheme primaryColor] forState:UIControlStateNormal];
//    stmapBtn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
//    [stmapBtn addTarget:self action:@selector(exportSTMapTapped) forControlEvents:UIControlEventTouchUpInside];
//    [stack addArrangedSubview:stmapBtn];

    return card;
}

// 非官方警告横幅：橙底 + 提示 + Good | Bad 评价
- (UIView *)buildLensWarningBanner {
    UIView *banner = [UIView new];
    banner.backgroundColor = [GFTheme primaryColor];
    banner.layer.cornerRadius = 6.0;

    UILabel *msg = [UILabel new];
    msg.text = @"此镜头配置文件并非官方提供，我们无法保证它的正确性。请自行承担风险。";
    msg.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    msg.textColor = [GFTheme textColor];
    msg.numberOfLines = 0;
    msg.textAlignment = NSTextAlignmentCenter;

    UILabel *rateLead = [UILabel new];
    rateLead.text = @"评价此配置文件:";
    rateLead.font = [UIFont systemFontOfSize:12.0];
    rateLead.textColor = [GFTheme textColor];

    UIButton *good = [UIButton buttonWithType:UIButtonTypeSystem];
    [good setTitle:@"Good" forState:UIControlStateNormal];
    [good setTitleColor:[GFTheme textColor] forState:UIControlStateNormal];
    good.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    [good addTarget:self action:@selector(rateLensGood) forControlEvents:UIControlEventTouchUpInside];

    UILabel *sep = [UILabel new];
    sep.text = @"|";
    sep.textColor = [GFTheme textColor];
    sep.font = [UIFont systemFontOfSize:12.0];

    UIButton *bad = [UIButton buttonWithType:UIButtonTypeSystem];
    [bad setTitle:@"Bad" forState:UIControlStateNormal];
    [bad setTitleColor:[GFTheme textColor] forState:UIControlStateNormal];
    bad.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    [bad addTarget:self action:@selector(rateLensBad) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *rateRow = [[UIStackView alloc] initWithArrangedSubviews:@[rateLead, good, sep, bad]];
    rateRow.axis = UILayoutConstraintAxisHorizontal;
    rateRow.spacing = 6.0;
    rateRow.alignment = UIStackViewAlignmentCenter;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[msg, rateRow]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 6.0;
    content.alignment = UIStackViewAlignmentCenter;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [banner addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor      constraintEqualToAnchor:banner.topAnchor      constant:10],
        [content.bottomAnchor   constraintEqualToAnchor:banner.bottomAnchor   constant:-10],
        [content.leadingAnchor  constraintEqualToAnchor:banner.leadingAnchor  constant:10],
        [content.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-10],
    ]];
    return banner;
}

// 「相机：xxx」类只读行
- (UIView *)lensDetailRowLabel:(NSString *)label key:(NSString *)key {
    UILabel *k = [UILabel new];
    k.text = [label stringByAppendingString:@":"];
    k.font = [UIFont systemFontOfSize:12.0];
    k.textColor = [GFTheme secondaryTextColor];
    [k setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [k.widthAnchor constraintEqualToConstant:72.0].active = YES;

    UILabel *v = [UILabel new];
    v.text = @"---";
    v.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    v.textColor = [GFTheme textColor];
    v.numberOfLines = 0;
    self.lensInfoValueLabels[key] = v;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[k, v]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8.0;
    row.alignment = UIStackViewAlignmentTop;
    return row;
}

// 「高级」标定数值展开区
- (UIStackView *)buildLensAdvancedContainer {
    // 水下镜头 checkbox —— 全局共用 GFTheme 工厂
    _underwaterCheckbox = [GFViewKit makeCheckboxWithTarget:self action:@selector(underwaterTapped)];
    UILabel *underwaterLabel = [UILabel new];
    underwaterLabel.text = @"水下镜头";
    underwaterLabel.font = [UIFont systemFontOfSize:13.0];
    underwaterLabel.textColor = [GFTheme textColor];
    UIStackView *underwaterRow = [[UIStackView alloc] initWithArrangedSubviews:@[_underwaterCheckbox, underwaterLabel]];
    underwaterRow.axis = UILayoutConstraintAxisHorizontal;
    underwaterRow.spacing = 8.0;
    underwaterRow.alignment = UIStackViewAlignmentCenter;

    // 8 个标定值都是同形态 UILabel；一次性建出来塞进 calibValueLabels[key]
    for (NSString *key in @[@"fx", @"fy", @"cx", @"cy", @"k1", @"k2", @"k3", @"k4"]) {
        self.calibValueLabels[key] = [self calibValueBox];
    }
    UIView *focalGroup  = [self calibGroupLabel:@"像素焦距"
                                          first:self.calibValueLabels[@"fx"]
                                         second:self.calibValueLabels[@"fy"]];
    UIView *centerGroup = [self calibGroupLabel:@"聚焦中心"
                                          first:self.calibValueLabels[@"cx"]
                                         second:self.calibValueLabels[@"cy"]];
    UIStackView *kRow1 = [self calibEqualRow:@[self.calibValueLabels[@"k1"], self.calibValueLabels[@"k2"]]];
    UIStackView *kRow2 = [self calibEqualRow:@[self.calibValueLabels[@"k3"], self.calibValueLabels[@"k4"]]];
    UILabel *distortHead = [UILabel new];
    distortHead.text = @"畸变系数";
    distortHead.font = [UIFont systemFontOfSize:12.0];
    distortHead.textColor = [GFTheme secondaryTextColor];
    UIStackView *distortGroup = [[UIStackView alloc] initWithArrangedSubviews:@[distortHead, kRow1, kRow2]];
    distortGroup.axis = UILayoutConstraintAxisVertical;
    distortGroup.spacing = 4.0;

    UIStackView *container = [[UIStackView alloc] initWithArrangedSubviews:@[
        underwaterRow, focalGroup, centerGroup, distortGroup
    ]];
    container.axis = UILayoutConstraintAxisVertical;
    container.spacing = 10.0;
    return container;
}

// 「像素焦距」/ 「聚焦中心」 两值一行 + 上方标签
- (UIView *)calibGroupLabel:(NSString *)label first:(UILabel *)a second:(UILabel *)b {
    UILabel *head = [UILabel new];
    head.text = label;
    head.font = [UIFont systemFontOfSize:12.0];
    head.textColor = [GFTheme secondaryTextColor];
    UIStackView *valueRow = [self calibEqualRow:@[a, b]];
    UIStackView *group = [[UIStackView alloc] initWithArrangedSubviews:@[head, valueRow]];
    group.axis = UILayoutConstraintAxisVertical;
    group.spacing = 4.0;
    return group;
}

// 等分两/三列横排（calib 数值用）
- (UIStackView *)calibEqualRow:(NSArray<UIView *> *)views {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:views];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8.0;
    row.distribution = UIStackViewDistributionFillEqually;
    return row;
}

// 单个数值「框」（深底白字 monospace）
- (UILabel *)calibValueBox {
    UILabel *l = [UILabel new];
    l.text = @"---";
    l.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    l.textColor = [GFTheme textColor];
    l.backgroundColor = [GFTheme backgroundColor];
    l.textAlignment = NSTextAlignmentCenter;
    l.layer.cornerRadius = 4.0;
    l.clipsToBounds = YES;
    [l.heightAnchor constraintEqualToConstant:28.0].active = YES;
    return l;
}

// 运动数据:打开 .gcsv + 状态
- (UIView *)buildMotionSection {
    UIView *card = [self card];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
    ]];

    [stack addArrangedSubview:[self sectionTitle:@"运动数据"]];

    // 打开文件 居中按钮 —— 未载入视频前禁用(对齐官方 MotionData.qml:36 无视频拒绝加载)
    UIButton *openBtn = [self primaryButton:@"打开文件" action:@selector(openMotionTapped)];
    _motionOpenButton = openBtn;
    openBtn.enabled = NO;
    openBtn.alpha = 0.4;
    [stack addArrangedSubview:openBtn];

    // 检测到的格式 + 文件名称（key:value 行）
    [stack addArrangedSubview:[self motionKeyValueRow:@"检测到的格式" valueLabel:&_motionFormatValue]];
    [stack addArrangedSubview:[self motionKeyValueRow:@"文件名称"      valueLabel:&_motionFileNameValue]];

    // 外挂文件专属控件(对齐官方 MotionData.qml:213/227: 仅运动数据来自外挂文件时显示, 初始隐藏)
    _allMetadataRow = [self motionCheckboxRow:@"加载全部元数据"
                                  checkboxOut:&_allMetadataCheckbox
                                     expanded:[UIView new]   // 无展开内容, 仅勾选
                                       action:@selector(allMetadataToggled)];
    _allMetadataRow.hidden = YES;
    [stack addArrangedSubview:_allMetadataRow];
    // 帧偏移(帧, 整数可负; 渲染前把视频时间戳整帧平移后再查陀螺)
    _frameOffsetField = [self motionDarkField:@"0" keyboard:UIKeyboardTypeNumbersAndPunctuation];
    _frameOffsetField.delegate = self;   // 提交时回调 onFrameOffsetChanged
    _frameOffsetField.returnKeyType = UIReturnKeyDone;
    _frameOffsetExpanded = [self motionValueRowWithFields:@[_frameOffsetField] units:@[@"帧"]];
    _frameOffsetRow = [self motionCheckboxRow:@"帧偏移"
                                  checkboxOut:&_frameOffsetCheckbox
                                     expanded:_frameOffsetExpanded
                                       action:@selector(frameOffsetToggled)];
    _frameOffsetRow.hidden = YES;
    [stack addArrangedSubview:_frameOffsetRow];

    // 低通滤波器 + Hz 输入框（默认折叠）
    _lpfHzField = [self motionDarkField:@"50.00"];
    _lpfHzField.keyboardType = UIKeyboardTypeDecimalPad;
    _lpfExpanded = [self motionValueRowWithFields:@[_lpfHzField] units:@[@"Hz"]];
    [stack addArrangedSubview:[self motionCheckboxRow:@"低通滤波器" checkboxOut:&_lpfCheckbox expanded:_lpfExpanded action:@selector(lpfToggled)]];

    // Median filter + samples 输入框
    _medianSamplesField = [self motionDarkField:@"5"];
    _medianSamplesField.keyboardType = UIKeyboardTypeNumberPad;
    _medianExpanded = [self motionValueRowWithFields:@[_medianSamplesField] units:@[@"samples"]];
    [stack addArrangedSubview:[self motionCheckboxRow:@"Median filter" checkboxOut:&_medianCheckbox expanded:_medianExpanded action:@selector(medianToggled)]];

    // 旋转 Pitch / Roll / Yaw
    _pitchField = [self motionDarkField:@"0.0" keyboard:UIKeyboardTypeNumbersAndPunctuation];
    _rollField  = [self motionDarkField:@"0.0" keyboard:UIKeyboardTypeNumbersAndPunctuation];
    _yawField   = [self motionDarkField:@"0.0" keyboard:UIKeyboardTypeNumbersAndPunctuation];
    _rotationExpanded = [self motionTripleRowLabels:@[@"Pitch", @"Roll", @"Yaw"]
                                             fields:@[_pitchField, _rollField, _yawField]
                                               unit:@"°"];
    [stack addArrangedSubview:[self motionCheckboxRow:@"旋转"
                                          checkboxOut:&_rotationCheckbox
                                             expanded:_rotationExpanded
                                               action:@selector(rotationToggled)]];

    // 陀螺仪偏差 X / Y / Z
    _biasXField = [self motionDarkField:@"0.00" keyboard:UIKeyboardTypeNumbersAndPunctuation];
    _biasYField = [self motionDarkField:@"0.00" keyboard:UIKeyboardTypeNumbersAndPunctuation];
    _biasZField = [self motionDarkField:@"0.00" keyboard:UIKeyboardTypeNumbersAndPunctuation];
    _gyroBiasExpanded = [self motionTripleRowLabels:@[@"X", @"Y", @"Z"]
                                             fields:@[_biasXField, _biasYField, _biasZField]
                                               unit:@"°/s"];
    [stack addArrangedSubview:[self motionCheckboxRow:@"陀螺仪偏差"
                                          checkboxOut:&_gyroBiasCheckbox
                                             expanded:_gyroBiasExpanded
                                               action:@selector(gyroBiasToggled)]];

    // IMU 朝向 textfield
    _imuOrientationField = [self motionDarkField:@"ZyX"];
    _imuOrientationField.delegate = self;                                       // 编辑提交→校验→回调
    _imuOrientationField.autocapitalizationType = UITextAutocapitalizationTypeNone; // 大小写表示轴向正反, 不能被自动大写改掉
    _imuOrientationField.autocorrectionType = UITextAutocorrectionTypeNo;
    _imuOrientationField.returnKeyType = UIReturnKeyDone;
    [stack addArrangedSubview:[self motionLabeledRow:@"IMU 朝向" field:_imuOrientationField]];

    // 积分方法 dropdown —— 对齐官方 MotionData.qml 的 6 个选项（不含 None，本机大多数视频用 hasRawGyro 路径）
    _integrationMethodDropdown = [self makeIntegrationMethodDropdown];
    [stack addArrangedSubview:[self motionLabeledControl:@"积分方法" control:_integrationMethodDropdown]];

    // 方向指示器 checkbox（展开后是 3 个示意图标占位）
    _orientIndicatorExpanded = [self orientationIndicatorIcons];
    [stack addArrangedSubview:[self motionCheckboxRow:@"方向指示器" checkboxOut:&_orientIndicatorCheckbox expanded:_orientIndicatorExpanded action:@selector(orientIndicatorToggled)]];

    // 运动数据模块的底部「统计 / 导出」按钮已按需求隐藏(不创建)。

    // 保留老接口（Controller 通过 setMotionStatus: 设的文字），但隐藏不显示
    _motionStatusLabel = [UILabel new];
    _motionStatusLabel.hidden = YES;
    [stack addArrangedSubview:_motionStatusLabel];

    return card;
}

#pragma mark - 运动数据面板 helpers

- (UIView *)motionKeyValueRow:(NSString *)label valueLabel:(UILabel * __strong *)valueOut {
    UILabel *k = [UILabel new];
    k.text = [label stringByAppendingString:@":"];
    k.font = [UIFont systemFontOfSize:12.0];
    k.textColor = [GFTheme secondaryTextColor];
    [k setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *v = [UILabel new];
    v.text = @"---";
    v.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    v.textColor = [GFTheme textColor];
    v.numberOfLines = 0;
    *valueOut = v;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[k, v]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8.0;
    row.alignment = UIStackViewAlignmentTop;
    return row;
}

- (UIView *)motionCheckboxRow:(NSString *)label
                  checkboxOut:(UIButton * __strong *)checkboxOut
                     expanded:(UIView *)expanded
                       action:(SEL)action {
    UIButton *btn = [GFViewKit makeCheckboxWithTarget:self action:action];
    *checkboxOut = btn;

    UILabel *l = [UILabel new];
    l.text = label;
    l.font = [UIFont systemFontOfSize:13.0];
    l.textColor = [GFTheme textColor];

    UIStackView *checkboxRow = [[UIStackView alloc] initWithArrangedSubviews:@[btn, l]];
    checkboxRow.axis = UILayoutConstraintAxisHorizontal;
    checkboxRow.spacing = 8.0;
    checkboxRow.alignment = UIStackViewAlignmentCenter;

    expanded.hidden = YES;
    [GFViewKit applyRevealIndent:expanded];   // 勾选展开内容统一左缩进 12px
    UIStackView *root = [[UIStackView alloc] initWithArrangedSubviews:@[checkboxRow, expanded]];
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 6.0;
    return root;
}

- (UITextField *)motionDarkField:(NSString *)placeholder {
    UITextField *tf = [UITextField new];
    tf.placeholder = placeholder;
    tf.font = [UIFont systemFontOfSize:13.0];
    tf.textColor = [GFTheme textColor];
    tf.backgroundColor = [GFTheme backgroundColor];
    tf.borderStyle = UITextBorderStyleNone;
    tf.layer.cornerRadius = 4.0;
    tf.clipsToBounds = YES;
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    [tf.heightAnchor constraintEqualToConstant:32.0].active = YES;
    tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 0)];
    tf.leftViewMode = UITextFieldViewModeAlways;
    tf.rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 0)];
    tf.rightViewMode = UITextFieldViewModeAlways;
    return tf;
}

- (UITextField *)motionDarkField:(NSString *)placeholder keyboard:(UIKeyboardType)kb {
    UITextField *tf = [self motionDarkField:placeholder];
    tf.keyboardType = kb;
    return tf;
}

// 单字段 + 单位 行（如 "50.00 Hz"）
- (UIView *)motionValueRowWithFields:(NSArray<UITextField *> *)fields units:(NSArray<NSString *> *)units {
    NSMutableArray *arranged = [NSMutableArray array];
    for (NSUInteger i = 0; i < fields.count; i++) {
        [arranged addObject:fields[i]];
        if (i < units.count) {
            UILabel *u = [UILabel new];
            u.text = units[i];
            u.font = [UIFont systemFontOfSize:12.0];
            u.textColor = [GFTheme secondaryTextColor];
            [arranged addObject:u];
        }
    }
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:arranged];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 6.0;
    row.alignment = UIStackViewAlignmentCenter;
    row.distribution = UIStackViewDistributionFill;
    return row;
}

// 三字段一行（标签 + 输入框 × 3），如 "Pitch [0.0°] Roll [0.0°] Yaw [0.0°]"
- (UIView *)motionTripleRowLabels:(NSArray<NSString *> *)labels fields:(NSArray<UITextField *> *)fields unit:(NSString *)unit {
    NSMutableArray *arranged = [NSMutableArray array];
    for (NSUInteger i = 0; i < labels.count && i < fields.count; i++) {
        UILabel *lab = [UILabel new];
        lab.text = labels[i];
        lab.font = [UIFont systemFontOfSize:12.0];
        lab.textColor = [GFTheme secondaryTextColor];
        [arranged addObject:lab];
        [arranged addObject:fields[i]];
        if (unit.length > 0) {
            UILabel *u = [UILabel new];
            u.text = unit;
            u.font = [UIFont systemFontOfSize:12.0];
            u.textColor = [GFTheme secondaryTextColor];
            [arranged addObject:u];
        }
    }
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:arranged];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 4.0;
    row.alignment = UIStackViewAlignmentCenter;
    row.distribution = UIStackViewDistributionFill;
    return row;
}

// "标签：输入框"行（如 "IMU 朝向: [ZyX]"）
- (UIView *)motionLabeledRow:(NSString *)label field:(UIView *)field {
    UILabel *l = [UILabel new];
    l.text = label;
    l.font = [UIFont systemFontOfSize:12.0];
    l.textColor = [GFTheme secondaryTextColor];
    [l.widthAnchor constraintEqualToConstant:80.0].active = YES;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[l, field]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8.0;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (UIView *)motionLabeledControl:(NSString *)label control:(UIView *)ctrl {
    return [self motionLabeledRow:label field:ctrl];
}

// 积分方法 dropdown —— UIMenu (iOS 14+) 形式。
// 列表对齐安卓 GyroflowMotionPanel / 官方 MotionData.qml：
//   有原生四元数: [None, Complementary, VQF, Simple gyro, Simple gyro+accel, Mahony, Madgwick]
//   无:           [Complementary, ... Madgwick](FFI 索引 = 列表位置 + 1)
- (UIButton *)makeIntegrationMethodDropdown {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    btn.titleLabel.font = [UIFont systemFontOfSize:13.0];
    [btn setTitleColor:[GFTheme textColor] forState:UIControlStateNormal];
    btn.backgroundColor = [GFTheme backgroundColor];
    btn.layer.cornerRadius = 4.0;
    btn.contentEdgeInsets = UIEdgeInsetsMake(6, 8, 6, 8);
    [btn.heightAnchor constraintEqualToConstant:32.0].active = YES;
    _integrationMethodDropdown = btn;
    // 初始按"无四元数 + Complementary(FFI 1)"建; 加载视频/陀螺后由
    // configureIntegrationMethodsHasQuaternions:selectedFFIIndex: 按真实状态重建。
    _integrationHasQuats = NO;
    [self rebuildIntegrationMenuSelectingFFIIndex:1];
    return btn;
}

// 当前列表(随是否含 None 变化)。
- (NSArray<NSString *> *)integrationTitles {
    if (_integrationHasQuats) {
        return @[@"None", @"Complementary", @"VQF", @"Simple gyro", @"Simple gyro + accel", @"Mahony", @"Madgwick"];
    }
    return @[@"Complementary", @"VQF", @"Simple gyro", @"Simple gyro + accel", @"Mahony", @"Madgwick"];
}

// 按当前 integrationHasQuats 重建 UIMenu, 选中 ffiIndex 对应项(不触发回调)。
- (void)rebuildIntegrationMenuSelectingFFIIndex:(NSInteger)ffiIndex {
    UIButton *btn = _integrationMethodDropdown;
    if (!btn) return;
    NSArray<NSString *> *titles = [self integrationTitles];
    const BOOL hasQuats = _integrationHasQuats;
    NSInteger selectedPos = hasQuats ? ffiIndex : ffiIndex - 1;   // FFI索引 → 列表位置
    if (selectedPos < 0 || selectedPos >= (NSInteger)titles.count) selectedPos = 0;

    [btn setTitle:[NSString stringWithFormat:@"%@  ▾", titles[selectedPos]] forState:UIControlStateNormal];

    if (@available(iOS 14.0, *)) {
        __weak typeof(self) weakSelf = self;
        __weak UIButton *weakBtn = btn;
        NSMutableArray<UIAction *> *actions = [NSMutableArray array];
        for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
            NSString *t = titles[i];
            NSInteger capFFI = hasQuats ? i : i + 1;   // 列表位置 → FFI索引(对齐安卓 position/position+1)
            UIAction *a = [UIAction actionWithTitle:t image:nil identifier:nil handler:^(UIAction * _Nonnull act) {
                [weakBtn setTitle:[NSString stringWithFormat:@"%@  ▾", t] forState:UIControlStateNormal];
                for (UIMenuElement *e in weakBtn.menu.children) {
                    if ([e isKindOfClass:[UIAction class]]) {
                        UIAction *aa = (UIAction *)e;
                        aa.state = [aa.title isEqualToString:t] ? UIMenuElementStateOn : UIMenuElementStateOff;
                    }
                }
                if (weakSelf.onIntegrationMethodSelected) weakSelf.onIntegrationMethodSelected(capFFI);
            }];
            if (i == selectedPos) a.state = UIMenuElementStateOn;
            [actions addObject:a];
        }
        btn.menu = [UIMenu menuWithChildren:actions];
        btn.showsMenuAsPrimaryAction = YES;
    }
}

// 按视频/陀螺真实状态配置下拉(每次加载后调用, 不触发回调)。
- (void)configureIntegrationMethodsHasQuaternions:(BOOL)hasQuats selectedFFIIndex:(NSInteger)ffiIndex {
    _integrationHasQuats = hasQuats;
    [self rebuildIntegrationMenuSelectingFFIIndex:ffiIndex];
}

// 程序化设置 IMU 朝向输入框显示的真实值(不触发 onIMUOrientationChanged)。
- (void)setIMUOrientationText:(NSString *)text {
    _imuOrientationField.text = (text.length > 0) ? text : nil; // 空→显示占位
}

// 方向指示器（按官方 MotionData.qml Canvas 翻成 Core Graphics 的静态版）：
// 3 个 cell：cell 1 = RGB 三轴 + 中心点；cell 2/3 = camera frustum 线框（raw / smoothed）。
// 实时姿态（quats_at_timestamp 驱动）需要再扩 FFI + per-frame requestPaint，本期不上。
- (UIView *)orientationIndicatorIcons {
    GFOrientationIndicatorView *v = [[GFOrientationIndicatorView alloc] initWithFrame:CGRectZero];
    v.backgroundColor = [UIColor clearColor];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [v.heightAnchor constraintEqualToConstant:100.0].active = YES;
    _orientationIndicator = v;   // 持有实例, 供 Controller 逐帧驱动
    return v;
}

// Controller 每帧调: raw/sm 各 4 个 double (w,x,y,z), 对齐官方 quats_at_timestamp。
- (void)updateOrientationIndicatorRaw:(const double *)raw smoothed:(const double *)smoothed {
    [_orientationIndicator updateRaw:raw smoothed:smoothed];
}

#pragma mark - 动作

- (void)openVideoTapped { if (self.onOpenVideo) self.onOpenVideo(); }
- (void)openLensFileTapped { if (self.onOpenLensFile) self.onOpenLensFile(); }
- (void)openMotionTapped { if (self.onOpenMotionData) self.onOpenMotionData(); }
- (void)createNewLensTapped { if (self.onCreateNewLensProfile) self.onCreateNewLensProfile(); }
- (void)exportSTMapTapped { if (self.onExportSTMap) self.onExportSTMap(); }
- (void)rateLensGood { if (self.onRateLensProfile) self.onRateLensProfile(YES); }
- (void)rateLensBad  { if (self.onRateLensProfile) self.onRateLensProfile(NO);  }

- (void)underwaterTapped {
    self.underwaterCheckbox.selected = !self.underwaterCheckbox.selected;
    if (self.onUnderwaterToggled) self.onUnderwaterToggled(self.underwaterCheckbox.selected);
}

// 运动数据各 checkbox：切换 selected + 折叠/展开内嵌输入区
- (void)_toggleMotionCheckbox:(UIButton *)cb expanded:(UIView *)expanded {
    cb.selected = !cb.selected;
    [UIView animateWithDuration:0.18 animations:^{
        expanded.hidden = !cb.selected;
    }];
}
- (void)lpfToggled        { [self _toggleMotionCheckbox:self.lpfCheckbox      expanded:self.lpfExpanded]; }
// 「加载全部元数据」: 无展开内容, 勾选即回调(Controller 重载外挂文件, 对齐官方切换即重载)
- (void)allMetadataToggled {
    self.allMetadataCheckbox.selected = !self.allMetadataCheckbox.selected;
    if (self.onLoadAllMetadataToggled) self.onLoadAllMetadataToggled(self.allMetadataCheckbox.selected);
}
// 「帧偏移」: 勾选展开输入框并回调当前值(关=0, 对齐官方 focb.checked? fo.value : 0)
- (void)frameOffsetToggled {
    [self _toggleMotionCheckbox:self.frameOffsetCheckbox expanded:self.frameOffsetExpanded];
    [self notifyFrameOffset];
}
- (void)notifyFrameOffset {
    NSInteger frames = self.frameOffsetCheckbox.selected ? self.frameOffsetField.text.integerValue : 0;
    if (self.onFrameOffsetChanged) self.onFrameOffsetChanged(frames);
}
- (void)medianToggled     { [self _toggleMotionCheckbox:self.medianCheckbox   expanded:self.medianExpanded]; }
- (void)rotationToggled   { [self _toggleMotionCheckbox:self.rotationCheckbox expanded:self.rotationExpanded]; }
- (void)gyroBiasToggled   { [self _toggleMotionCheckbox:self.gyroBiasCheckbox expanded:self.gyroBiasExpanded]; }
- (void)orientIndicatorToggled { [self _toggleMotionCheckbox:self.orientIndicatorCheckbox expanded:self.orientIndicatorExpanded]; }

- (void)advancedLensToggleTapped {
    BOOL willShow = self.lensAdvancedContainer.hidden;
    [UIView animateWithDuration:0.2 animations:^{
        self.lensAdvancedContainer.hidden = !willShow;
        [self.lensAdvancedToggle setTitle:(willShow ? @"高级 ▴" : @"高级 ▾")
                                 forState:UIControlStateNormal];
    }];
}

- (void)lensSearchChanged {
    NSString *q = self.lensSearchField.text ?: @"";
    if (q.length < 2) {
        [self renderResults:@[]];
        return;
    }
    if (!self.onLensSearch) return;
    __weak typeof(self) weakSelf = self;
    self.onLensSearch(q, ^(NSString *resultJson) {
        // 回到主线程渲染
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf renderResultsFromJson:resultJson];
        });
    });
}

- (void)renderResultsFromJson:(NSString *)json {
    NSArray *arr = nil;
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (d) arr = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![arr isKindOfClass:[NSArray class]]) arr = @[];
    [self renderResults:arr];
}

- (void)renderResults:(NSArray<NSDictionary *> *)items {
    for (UIView *v in self.lensResultsStack.arrangedSubviews) {
        [self.lensResultsStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSInteger shown = 0;
    for (NSDictionary *it in items) {
        if (shown >= 30) break; // 最多显示 30 条
        NSString *name = it[@"name"];
        NSString *lensId = it[@"id"];
        if (![name isKindOfClass:[NSString class]] || ![lensId isKindOfClass:[NSString class]]) continue;
        // 用 UIButton(UIControl, 在 UIScrollView 里点击可靠; 自定义手势会被 scroll view
        // 的 delaysContentTouches 干扰)。镜头名很长 → 开多行 + 按宽度换行显示完整。
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:name forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:13.0];
        b.titleLabel.numberOfLines = 0;
        b.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        b.titleLabel.textAlignment = NSTextAlignmentLeft;
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        [b setTitleColor:[GFTheme primaryColor] forState:UIControlStateNormal];
        b.contentEdgeInsets = UIEdgeInsetsMake(6, 8, 6, 8);
        b.accessibilityIdentifier = lensId;   // 暂存 id
        [b addTarget:self action:@selector(lensResultTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.lensResultsStack addArrangedSubview:b];
        // 约束 titleLabel 宽度 = 按钮宽 - 左右内边距(8+8), 逼标题按宽度换行 + 按钮高度自适应
        [b.titleLabel.widthAnchor constraintEqualToAnchor:b.widthAnchor constant:-16.0].active = YES;
        shown++;
    }
}

- (void)lensResultTapped:(UIButton *)sender {
    NSString *lensId = sender.accessibilityIdentifier;
    NSLog(@"[Lens] result tapped, id=%@", lensId);
    if (lensId.length > 0 && self.onSelectLensId) self.onSelectLensId(lensId);
    // 选完收起结果 + 收键盘
    [self.lensSearchField resignFirstResponder];
    [self renderResults:@[]];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField == _frameOffsetField) {
        [self notifyFrameOffset];
        return;
    }
    if (textField != _imuOrientationField) return;
    // IMU 朝向必须是 3 位、每位 ∈ {x,y,z,X,Y,Z}(大小写表示轴向正反)。
    // 校验通过→回调 Controller 写回引擎; 不通过→恢复占位、不触发回调(避免把脏值写进引擎)。
    NSString *s = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"xyzXYZ"];
    // 必须正好 3 位, 且每一位都 ∈ allowed (用反集查中间字符, 不能用 trim——trim 只裁首尾)。
    BOOL valid = (s.length == 3) &&
                 ([s rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound);
    if (valid) {
        textField.text = s;
        if (self.onIMUOrientationChanged) self.onIMUOrientationChanged(s);
    } else {
        textField.text = nil; // 显示占位; 引擎保持当前(自动识别)值不变
    }
}

#pragma mark - Controller 刷新接口

- (void)setVideoInfoFileName:(NSString *)fileName detectedCam:(NSString *)cam detectedLens:(NSString *)lens
                        size:(NSString *)size duration:(NSString *)duration fps:(NSString *)fps
                       codec:(NSString *)codec pixelFormat:(NSString *)pixfmt audio:(NSString *)audio
                    rotation:(NSString *)rotation hasGyro:(NSString *)hasGyro {
    NSDictionary *m = @{
        @"fileName": fileName ?: @"---", @"cam": cam ?: @"---", @"lens": lens ?: @"---",
        @"size": size ?: @"---", @"duration": duration ?: @"---", @"fps": fps ?: @"---",
        @"codec": codec ?: @"---", @"pixfmt": pixfmt ?: @"---", @"audio": audio ?: @"---",
        @"rotation": rotation ?: @"---", @"hasGyro": hasGyro ?: @"---",
    };
    [m enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *val, BOOL *stop) {
        self.infoValueLabels[k].text = val;
    }];
}

- (void)setLoadedLensName:(NSString *)name {
    if (name.length > 0) {
        self.loadedLensLabel.text = [@"✓ " stringByAppendingString:name];
        self.loadedLensLabel.textColor = [UIColor systemGreenColor];
    } else {
        self.loadedLensLabel.text = @"未加载镜头档案";
        self.loadedLensLabel.textColor = [GFTheme secondaryTextColor];
    }
}

- (void)setMotionStatus:(NSString *)status {
    if (status.length > 0) self.motionStatusLabel.text = status;
}

- (void)setMotionInfoFormat:(NSString *)format
                   fileName:(NSString *)fileName
                     loaded:(BOOL)loaded {
    self.motionFormatValue.text   = (loaded && format.length   > 0) ? format   : @"---";
    self.motionFileNameValue.text = (loaded && fileName.length > 0) ? fileName : @"---";
}

- (void)setMotionOpenFileEnabled:(BOOL)enabled {
    self.motionOpenButton.enabled = enabled;
    self.motionOpenButton.alpha = enabled ? 1.0 : 0.4;
}

- (void)setVideoDirHintVisible:(BOOL)visible {
    self.videoDirHintButton.hidden = !visible;
}

- (void)motionFolderHintTapped {
    if (self.onAuthorizeMotionFolder) self.onAuthorizeMotionFolder();
}

- (BOOL)loadAllMetadataChecked {
    // 对齐官方 root.allMetadata = allMetadataCb.visible && allMetadataCb.checked
    return !self.allMetadataRow.hidden && self.allMetadataCheckbox.selected;
}

- (void)setExternalMotionControlsVisible:(BOOL)visible {
    self.allMetadataRow.hidden = !visible;
    self.frameOffsetRow.hidden = !visible;
    if (!visible) {
        // 新视频: 复位勾选与数值(引擎侧随新 stabilizer 已是 frame_offset=0/完整解析默认)
        self.allMetadataCheckbox.selected = NO;
        self.frameOffsetCheckbox.selected = NO;
        self.frameOffsetExpanded.hidden = YES;
        self.frameOffsetField.text = nil;
    }
}

- (void)setLensDetailsOfficial:(BOOL)official
                        camera:(NSString *)camera
                          lens:(NSString *)lens
                       setting:(NSString *)setting
                     otherInfo:(NSString *)otherInfo
                     dimension:(NSString *)dimension
                    calibrator:(NSString *)calibrator {
    self.lensWarningBanner.hidden = official;
    NSDictionary<NSString *, NSString *> *m = @{
        @"camera":     camera     ?: @"---",
        @"lens":       lens       ?: @"---",
        @"setting":    setting    ?: @"---",
        @"otherInfo":  otherInfo  ?: @"---",
        @"dimension":  dimension  ?: @"---",
        @"calibrator": calibrator ?: @"---",
    };
    [m enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        self.lensInfoValueLabels[k].text = v;
    }];
}

- (void)setLensCalibrationUnderwater:(BOOL)underwater
                                  fx:(double)fx fy:(double)fy
                                  cx:(double)cx cy:(double)cy
                                  k1:(double)k1 k2:(double)k2 k3:(double)k3 k4:(double)k4 {
    self.underwaterCheckbox.selected = underwater;
    // 焦距 / 主点 用 6 位小数；畸变系数用 10 位（对齐官方桌面版精度）
    [self setCalibValueForKey:@"fx" value:fx format:@"%.6f"];
    [self setCalibValueForKey:@"fy" value:fy format:@"%.6f"];
    [self setCalibValueForKey:@"cx" value:cx format:@"%.6f"];
    [self setCalibValueForKey:@"cy" value:cy format:@"%.6f"];
    [self setCalibValueForKey:@"k1" value:k1 format:@"%.10f"];
    [self setCalibValueForKey:@"k2" value:k2 format:@"%.10f"];
    [self setCalibValueForKey:@"k3" value:k3 format:@"%.10f"];
    [self setCalibValueForKey:@"k4" value:k4 format:@"%.10f"];
}

- (void)setCalibValueForKey:(NSString *)key value:(double)v format:(NSString *)fmt {
    UILabel *l = self.calibValueLabels[key];
    if (l == nil) return;
    l.text = isnan(v) ? @"---" : [NSString stringWithFormat:fmt, v];
}

@end
