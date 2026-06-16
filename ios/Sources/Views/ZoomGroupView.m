#import "ZoomGroupView.h"
#import "GFTheme.h"
#import "GFViewKit.h"

@interface ZoomGroupView () <UITextFieldDelegate>
// ---- 主面板控件 ----
@property (nonatomic, strong) UIButton           *croppingModeDropdown; // 无/动态/静态 -> croppingMode
@property (nonatomic, strong) UIButton           *zoomingMethodDropdown; // Gaussian/Envelope -> zoomingMethod
@property (nonatomic, strong) UISlider *maxZoomSlider;
@property (nonatomic, strong) UITextField *maxZoomValueLabel;
@property (nonatomic, strong) UISlider *adaptiveSlider;
@property (nonatomic, strong) UITextField *adaptiveValueLabel;
@property (nonatomic, strong) UIView   *adaptiveRow;            // 「缩放速度」整行, 仅动态缩放时显示
@property (nonatomic, strong) UISlider *lensCorrSlider;
@property (nonatomic, strong) UITextField *lensCorrValueLabel;

// ---- 高级选项 toggle + 容器 ----
@property (nonatomic, assign) BOOL       advancedExpanded;
@property (nonatomic, strong) UIButton  *advancedToggleBtn;
@property (nonatomic, strong) UIStackView *advancedContainer;

// ---- 高级选项内部控件 ----
@property (nonatomic, strong) UISlider     *fovSlider;
@property (nonatomic, strong) UITextField  *fovField;
@property (nonatomic, strong) UIButton     *rsCheckbox;
@property (nonatomic, strong) UIView       *frameReadoutRow;   // 勾选卷帘校正才显示
@property (nonatomic, strong) UISlider     *frameReadoutSlider;
@property (nonatomic, strong) UITextField *frameReadoutValueLabel;
@property (nonatomic, strong) UISlider     *videoSpeedSlider;
@property (nonatomic, strong) UITextField *videoSpeedValueLabel;
@property (nonatomic, strong) UISlider     *pitchSlider;
@property (nonatomic, strong) UITextField *pitchValueLabel;
@property (nonatomic, strong) UISlider     *yawSlider;
@property (nonatomic, strong) UITextField *yawValueLabel;
@property (nonatomic, strong) UISlider     *rollSlider;
@property (nonatomic, strong) UITextField *rollValueLabel;
@property (nonatomic, strong) UISlider     *maxZoomIterSlider;
@property (nonatomic, strong) UITextField *maxZoomIterValueLabel;
// 视频速度联动小复选框 (左->右: 缩放限额 / 缩放速度 / 平滑)
@property (nonatomic, strong) UIButton     *vsLimitCb;
@property (nonatomic, strong) UIButton     *vsSpeedCb;
@property (nonatomic, strong) UIButton     *vsSmoothCb;
// 帧读出方向选择器 (上↑/左←/下↓/右→ 循环)
@property (nonatomic, strong) UIButton     *readoutDirBtn;
@property (nonatomic, strong) UIView       *readoutDirRow;   // 跟随帧读出时间行显隐
@end

@implementation ZoomGroupView

#pragma mark - Construction

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _advancedExpanded = NO;
        [self buildSubviews];
    }
    return self;
}

- (void)buildSubviews {
    UILabel *groupTitle = [UILabel new];
    groupTitle.text = @"动态缩放";
    groupTitle.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    groupTitle.textColor = [GFTheme textColor];

    UIView *modeRow          = [self makeCroppingModeRow];
    UIView *maxZoomRow       = [self makeMaxZoomRow];
    self.adaptiveRow         = [self makeAdaptiveRow];
    UIView *lensCorrRow      = [self makeLensCorrRow];
    // 「缩放方式」已移到高级选项里「视频速度」下面 (见 buildAdvancedContainer)

    self.advancedToggleBtn = [self makeAdvancedToggleBtn];
    UIView *advancedToggleRow = self.advancedToggleBtn;   // 直接铺满整行, 标题居中

    self.advancedContainer = [self buildAdvancedContainer];
    [GFViewKit applyAdvancedExpandStyle:self.advancedContainer];   // 高级区与主背景区分
    self.advancedContainer.hidden = !self.advancedExpanded;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        groupTitle,
        modeRow,
        maxZoomRow,
        self.adaptiveRow,
        lensCorrRow,
        advancedToggleRow,
        self.advancedContainer,
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor      constraintEqualToAnchor:self.topAnchor],
        [stack.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
        [stack.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];
}

#pragma mark - 主面板控件工厂

- (UIView *)makeCroppingModeRow {
    NSArray<NSString *> *titles = @[@"无缩放", @"动态缩放", @"静态缩放"];
    __weak typeof(self) weakSelf = self;
    self.croppingModeDropdown = [GFViewKit makeDropdownWithTitles:titles
                                                         selected:1
                                                         onChange:^(NSInteger idx) {
        __strong typeof(weakSelf) sSelf = weakSelf;
        if (sSelf == nil) { return; }
        sSelf.model.croppingMode = (int)idx;
        [sSelf updateAdaptiveRowVisibility];   // 动态缩放才显示「缩放速度」
    }];
    return [GFViewKit rowWithLabel:@"裁剪模式" control:self.croppingModeDropdown];
}

- (UIView *)makeMaxZoomRow {
    UIView *row = [GFViewKit sliderRowWithLabel:@"缩放限额 (%)"
                                            min:100.0f max:300.0f
                                      outSlider:&_maxZoomSlider
                                  outValueField:&_maxZoomValueLabel];
    [self.maxZoomSlider addTarget:self
                           action:@selector(maxZoomChanged)
                 forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_maxZoomValueLabel editSlider:_maxZoomSlider scale:1.0];
    return row;
}

- (UIView *)makeAdaptiveRow {
    UIView *row = [GFViewKit sliderRowWithLabel:@"缩放速度 (s)"
                                            min:0.1f max:5.0f
                                      outSlider:&_adaptiveSlider
                                  outValueField:&_adaptiveValueLabel];
    [self.adaptiveSlider addTarget:self
                            action:@selector(adaptiveChanged)
                  forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_adaptiveValueLabel editSlider:_adaptiveSlider scale:1.0];
    return row;
}

- (UIView *)makeZoomingMethodRow {
    NSArray<NSString *> *titles = @[@"Gaussian filter", @"Envelope follower"];
    NSInteger defaultIdx = 1;
    __weak typeof(self) weakSelf = self;
    self.zoomingMethodDropdown = [GFViewKit makeDropdownWithTitles:titles
                                                          selected:defaultIdx
                                                          onChange:^(NSInteger idx) {
        weakSelf.model.zoomingMethod = (int)idx;
    }];
    return [GFViewKit rowWithLabel:@"缩放方式" control:self.zoomingMethodDropdown];
}

- (UIView *)makeLensCorrRow {
    UIView *row = [GFViewKit sliderRowWithLabel:@"镜头校正 (%)"
                                            min:0.0f max:100.0f
                                      outSlider:&_lensCorrSlider
                                  outValueField:&_lensCorrValueLabel];
    [self.lensCorrSlider addTarget:self
                            action:@selector(lensCorrChanged)
                  forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_lensCorrValueLabel editSlider:_lensCorrSlider scale:1.0];
    return row;
}

#pragma mark - 高级选项 toggle + 容器

- (UIButton *)makeAdvancedToggleBtn {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.titleLabel.font = [UIFont systemFontOfSize:12.0];
    btn.tintColor = [GFTheme primaryColor];
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    [btn setTitle:[self advancedToggleTitle] forState:UIControlStateNormal];
    [btn addTarget:self action:@selector(advancedToggleTapped) forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (NSString *)advancedToggleTitle {
    return self.advancedExpanded ? @"高级选项 ▴" : @"高级选项 ▾";
}

- (void)advancedToggleTapped {
    self.advancedExpanded = !self.advancedExpanded;
    self.advancedContainer.hidden = !self.advancedExpanded;
    [self.advancedToggleBtn setTitle:[self advancedToggleTitle] forState:UIControlStateNormal];
}

- (UIStackView *)buildAdvancedContainer {
    UIView *fovRow         = [self makeFovRow];
    UIView *rsRow          = [self makeRsRow];
    UIView *frameReadoutRow= [self makeFrameReadoutRow];
    self.frameReadoutRow   = frameReadoutRow;
    [GFViewKit applyRevealIndent:frameReadoutRow];   // 勾选展开内容缩进 12px
    frameReadoutRow.hidden = YES;                     // 勾选卷帘校正后才显示
    // 帧读出方向选择器 (在帧读出时间行上面, 跟随其显隐)
    UIView *readoutDirRow  = [self makeReadoutDirRow];
    self.readoutDirRow     = readoutDirRow;
    readoutDirRow.hidden   = YES;
    UIView *videoSpeedRow  = [self makeVideoSpeedRow];
    // 视频速度联动小复选框 (在视频速度行上面)
    UIView *vsLinksRow     = [self makeVideoSpeedLinksRow];
    UIView *zoomingMethodRow = [self makeZoomingMethodRow];  // 「缩放方式」放在「视频速度」下面

    UILabel *rotTitle = [UILabel new];
    rotTitle.text = @"附加 3D 旋转";
    rotTitle.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    rotTitle.textColor = [GFTheme textColor];

    UIView *pitchRow = [self makePitchRow];
    UIView *yawRow   = [self makeYawRow];
    UIView *rollRow  = [self makeRollRow];

    // 附加 3D 旋转下面: 缩放限额迭代次数 (max_zoom_iterations, 整数)。
    UIView *maxZoomIterRow = [self makeMaxZoomIterRow];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        fovRow, rsRow, readoutDirRow, frameReadoutRow, vsLinksRow, videoSpeedRow, zoomingMethodRow,
        rotTitle, pitchRow, yawRow, rollRow,
        maxZoomIterRow,
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    return stack;
}

#pragma mark - 高级选项内部控件工厂

// 视场角: slider + 可输入数值框 (跟独立 ZoomSectionView 的逻辑同步保留)
- (UIView *)makeFovRow {
    UIView *row = [GFViewKit sliderRowWithLabel:@"视场角"
                                            min:0.3f max:3.0f
                                      outSlider:&_fovSlider
                                  outValueField:&_fovField];
    [self.fovSlider addTarget:self action:@selector(fovChanged)      forControlEvents:UIControlEventValueChanged];
    [self.fovField  addTarget:self action:@selector(fovFieldEdited)  forControlEvents:UIControlEventEditingDidEnd];
    return row;
}

- (UIView *)makeRsRow {
    self.rsCheckbox = [GFViewKit makeCheckboxWithTarget:self action:@selector(rsToggled:)];
    return [GFViewKit rowWithLabel:@"卷帘快门校正" control:self.rsCheckbox];
}

- (UIView *)makeFrameReadoutRow {
    UIView *row = [GFViewKit sliderRowWithLabel:@"帧读出时间 (ms)"
                                            min:0.0f max:50.0f
                                      outSlider:&_frameReadoutSlider
                                  outValueField:&_frameReadoutValueLabel];
    [self.frameReadoutSlider addTarget:self
                                action:@selector(frameReadoutChanged)
                      forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_frameReadoutValueLabel editSlider:_frameReadoutSlider scale:1.0];
    return row;
}

- (UIView *)makeVideoSpeedRow {
    // 桌面 stabilization_params.rs:174 video_speed: 1.0 默认; 按百分比显示 10%..1000% (=0.1..10.0)。
    UIView *row = [GFViewKit sliderRowWithLabel:@"视频速度"
                                            min:0.1f max:10.0f
                                      outSlider:&_videoSpeedSlider
                                  outValueField:&_videoSpeedValueLabel];
    [self.videoSpeedSlider addTarget:self
                              action:@selector(videoSpeedChanged)
                    forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_videoSpeedValueLabel editSlider:_videoSpeedSlider scale:100.0];
    return row;
}

- (UIView *)makePitchRow {
    UIView *row = [GFViewKit sliderRowWithLabel:@"Pitch"
                                            min:-180.0f max:180.0f
                                      outSlider:&_pitchSlider
                                  outValueField:&_pitchValueLabel];
    [self.pitchSlider addTarget:self action:@selector(pitchChanged) forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_pitchValueLabel editSlider:_pitchSlider scale:1.0];
    return row;
}

- (UIView *)makeYawRow {
    UIView *row = [GFViewKit sliderRowWithLabel:@"Yaw"
                                            min:-180.0f max:180.0f
                                      outSlider:&_yawSlider
                                  outValueField:&_yawValueLabel];
    [self.yawSlider addTarget:self action:@selector(yawChanged) forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_yawValueLabel editSlider:_yawSlider scale:1.0];
    return row;
}

- (UIView *)makeRollRow {
    UIView *row = [GFViewKit sliderRowWithLabel:@"Roll"
                                            min:-180.0f max:180.0f
                                      outSlider:&_rollSlider
                                  outValueField:&_rollValueLabel];
    [self.rollSlider addTarget:self action:@selector(rollChanged) forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_rollValueLabel editSlider:_rollSlider scale:1.0];
    return row;
}

// 缩放限额迭代次数 (max_zoom_iterations, 整数 1..15, 默认 5)。迭代越多对
// 「缩放限额」约束的拟合越精确(收敛更准), 代价是计算更慢。源码 set_max_zoom 接收。
- (UIView *)makeMaxZoomIterRow {
    UIView *row = [GFViewKit sliderRowWithLabel:@"缩放限额迭代次数"
                                            min:1.0f max:15.0f
                                      outSlider:&_maxZoomIterSlider
                                  outValueField:&_maxZoomIterValueLabel];
    [self.maxZoomIterSlider addTarget:self
                               action:@selector(maxZoomIterChanged)
                     forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_maxZoomIterValueLabel editSlider:_maxZoomIterSlider scale:1.0];
    return row;
}

// 视频速度联动小复选框: 左->右 = 缩放限额 / 缩放速度 / 平滑 (对齐桌面 affects_*)。
- (UIView *)makeVideoSpeedLinksRow {
    _vsLimitCb  = [GFViewKit makeCheckboxWithTarget:self action:@selector(vsLimitToggled:)];
    _vsSpeedCb  = [GFViewKit makeCheckboxWithTarget:self action:@selector(vsSpeedToggled:)];
    _vsSmoothCb = [GFViewKit makeCheckboxWithTarget:self action:@selector(vsSmoothToggled:)];
    for (UIButton *cb in @[_vsLimitCb, _vsSpeedCb, _vsSmoothCb]) {
        cb.transform = CGAffineTransformMakeScale(0.7, 0.7);   // 显得小一点
        cb.selected = YES;   // 默认全开
    }
    UIView *spacer = [UIView new];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[spacer, _vsLimitCb, _vsSpeedCb, _vsSmoothCb]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 2.0;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

// 帧读出方向选择器: 点击循环 上↑->左←->下↓->右→ (枚举 1->3->0->2)。
- (UIView *)makeReadoutDirRow {
    _readoutDirBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _readoutDirBtn.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    [_readoutDirBtn setTitleColor:[GFTheme primaryColor] forState:UIControlStateNormal];
    _readoutDirBtn.backgroundColor = [GFTheme backgroundColor];
    _readoutDirBtn.layer.cornerRadius = 4.0;
    [_readoutDirBtn.widthAnchor  constraintEqualToConstant:34.0].active = YES;
    [_readoutDirBtn.heightAnchor constraintEqualToConstant:26.0].active = YES;
    [_readoutDirBtn setTitle:@"↓" forState:UIControlStateNormal];   // 默认 上→下, 加载后按识别值回显
    [_readoutDirBtn addTarget:self action:@selector(readoutDirTapped) forControlEvents:UIControlEventTouchUpInside];
    UIView *spacer = [UIView new];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[spacer, _readoutDirBtn]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

#pragma mark - Model sync

- (void)setModel:(ParamsModel *)model {
    _model = model;
    [self refreshFromModel];
}

- (void)refreshFromModel {
    ParamsModel *m = self.model;
    if (m == nil) {
        return;
    }
    // 主面板
    [self syncCroppingDropdownFromModel];
    [self updateAdaptiveRowVisibility];
    self.maxZoomSlider.value  = (float)m.maxZoomPercent;
    self.adaptiveSlider.value = (float)m.adaptiveZoomSec;
    self.lensCorrSlider.value = (float)(m.lensCorrection * 100.0);
    [self syncZoomingMethodDropdownFromModel];
    // 高级选项
    self.fovSlider.value          = (float)m.fov;
    self.fovField.text            = [NSString stringWithFormat:@"%.2f", m.fov];
    self.rsCheckbox.selected      = m.rsCorrection;
    self.frameReadoutRow.hidden   = !m.rsCorrection;   // 勾选卷帘校正才显示帧读出时间
    self.readoutDirRow.hidden     = !m.rsCorrection;   // 方向选择器跟随
    self.frameReadoutSlider.value = (float)m.frameReadoutMs;
    [self updateReadoutDirButton];
    self.videoSpeedSlider.value   = (float)m.videoSpeed;
    self.vsLimitCb.selected       = m.videoSpeedAffectsZoomingLimit;
    self.vsSpeedCb.selected       = m.videoSpeedAffectsZooming;
    self.vsSmoothCb.selected      = m.videoSpeedAffectsSmoothing;
    self.pitchSlider.value        = (float)m.addPitch;
    self.yawSlider.value          = (float)m.addYaw;
    self.rollSlider.value         = (float)m.addRoll;
    self.maxZoomIterSlider.value  = (float)m.maxZoomIterations;
    [self refreshValueLabels];
}

- (void)syncZoomingMethodDropdownFromModel {
    if (self.model == nil || self.zoomingMethodDropdown == nil) {
        return;
    }
    if (@available(iOS 14.0, *)) {
        NSString *want = (self.model.zoomingMethod == 0) ? @"Gaussian filter" : @"Envelope follower";
        [self.zoomingMethodDropdown setTitle:[NSString stringWithFormat:@"%@  ▾", want]
                                    forState:UIControlStateNormal];
        for (UIMenuElement *e in self.zoomingMethodDropdown.menu.children) {
            if ([e isKindOfClass:[UIAction class]]) {
                UIAction *aa = (UIAction *)e;
                aa.state = [aa.title isEqualToString:want] ? UIMenuElementStateOn : UIMenuElementStateOff;
            }
        }
    }
}

- (void)refreshValueLabels {
    self.maxZoomValueLabel.text       = [NSString stringWithFormat:@"%.0f%%", self.maxZoomSlider.value];
    self.adaptiveValueLabel.text      = [NSString stringWithFormat:@"%.3fs", self.adaptiveSlider.value];
    self.lensCorrValueLabel.text      = [NSString stringWithFormat:@"%.0f%%", self.lensCorrSlider.value];
    self.frameReadoutValueLabel.text  = [NSString stringWithFormat:@"%.2fms", self.frameReadoutSlider.value];
    self.videoSpeedValueLabel.text    = [NSString stringWithFormat:@"%.0f%%", self.videoSpeedSlider.value * 100.0];
    self.pitchValueLabel.text         = [NSString stringWithFormat:@"%+.1f°", self.pitchSlider.value];
    self.yawValueLabel.text           = [NSString stringWithFormat:@"%+.1f°", self.yawSlider.value];
    self.rollValueLabel.text          = [NSString stringWithFormat:@"%+.1f°", self.rollSlider.value];
    self.maxZoomIterValueLabel.text   = [NSString stringWithFormat:@"%d", (int)lround(self.maxZoomIterSlider.value)];
}

#pragma mark - Actions

// 「缩放速度」只在「动态缩放」(croppingMode==1) 时有意义 —— 无缩放/静态缩放时隐藏整行。
- (void)updateAdaptiveRowVisibility {
    self.adaptiveRow.hidden = (self.model.croppingMode != 1);
}

// 按 model.croppingMode 同步下拉标题 + 勾选(不触发 onChange)。
- (void)syncCroppingDropdownFromModel {
    if (self.model == nil || self.croppingModeDropdown == nil) {
        return;
    }
    if (@available(iOS 14.0, *)) {
        NSArray<NSString *> *titles = @[@"无缩放", @"动态缩放", @"静态缩放"];
        NSInteger idx = MAX(0, MIN(2, self.model.croppingMode));
        NSString *want = titles[idx];
        [self.croppingModeDropdown setTitle:[NSString stringWithFormat:@"%@  ▾", want]
                                   forState:UIControlStateNormal];
        for (UIMenuElement *e in self.croppingModeDropdown.menu.children) {
            if ([e isKindOfClass:[UIAction class]]) {
                UIAction *aa = (UIAction *)e;
                aa.state = [aa.title isEqualToString:want] ? UIMenuElementStateOn : UIMenuElementStateOff;
            }
        }
    }
}

- (void)maxZoomChanged {
    double v = (double)self.maxZoomSlider.value;
    self.model.maxZoomPercent = v;
    self.maxZoomValueLabel.text = [NSString stringWithFormat:@"%.0f%%", v];
}

- (void)adaptiveChanged {
    double v = (double)self.adaptiveSlider.value;
    self.model.adaptiveZoomSec = v;
    self.adaptiveValueLabel.text = [NSString stringWithFormat:@"%.3fs", v];
}

- (void)lensCorrChanged {
    double pct = (double)self.lensCorrSlider.value;
    self.model.lensCorrection = pct / 100.0;
    self.lensCorrValueLabel.text = [NSString stringWithFormat:@"%.0f%%", pct];
}

- (void)fovChanged {
    double v = (double)self.fovSlider.value;
    self.fovField.text = [NSString stringWithFormat:@"%.2f", v];
    self.model.fov = v;
}

- (void)fovFieldEdited {
    NSString *txt = self.fovField.text ?: @"";
    NSScanner *scanner = [NSScanner scannerWithString:txt];
    double v = 0.0;
    if (![scanner scanDouble:&v]) {
        self.fovField.text = [NSString stringWithFormat:@"%.2f", self.model.fov];
        return;
    }
    if (v < 0.3) v = 0.3;
    if (v > 3.0) v = 3.0;
    self.fovSlider.value = (float)v;
    self.fovField.text   = [NSString stringWithFormat:@"%.2f", v];
    self.model.fov = v;
}


- (void)rsToggled:(UIButton *)sender {
    sender.selected = !sender.selected;
    self.model.rsCorrection = sender.selected;
    [UIView animateWithDuration:0.2 animations:^{
        self.frameReadoutRow.hidden = !sender.selected;   // 勾选卷帘校正才显示帧读出时间
        self.readoutDirRow.hidden   = !sender.selected;   // 方向选择器跟随
    }];
}

- (void)frameReadoutChanged {
    double v = (double)self.frameReadoutSlider.value;
    self.frameReadoutValueLabel.text = [NSString stringWithFormat:@"%.2fms", v];
    self.model.frameReadoutMs = v;
}

- (void)videoSpeedChanged {
    double v = (double)self.videoSpeedSlider.value;
    self.videoSpeedValueLabel.text = [NSString stringWithFormat:@"%.0f%%", v * 100.0];
    self.model.videoSpeed = v;
}

- (void)pitchChanged {
    double v = (double)self.pitchSlider.value;
    self.pitchValueLabel.text = [NSString stringWithFormat:@"%+.1f°", v];
    self.model.addPitch = v;
}

- (void)yawChanged {
    double v = (double)self.yawSlider.value;
    self.yawValueLabel.text = [NSString stringWithFormat:@"%+.1f°", v];
    self.model.addYaw = v;
}

- (void)rollChanged {
    double v = (double)self.rollSlider.value;
    self.rollValueLabel.text = [NSString stringWithFormat:@"%+.1f°", v];
    self.model.addRoll = v;
}

- (void)maxZoomIterChanged {
    int v = (int)lround(self.maxZoomIterSlider.value);
    self.maxZoomIterSlider.value = (float)v;   // 吸附到整数
    self.model.maxZoomIterations = v;
    self.maxZoomIterValueLabel.text = [NSString stringWithFormat:@"%d", v];
}

#pragma mark - 视频速度联动复选框

- (void)vsLimitToggled:(UIButton *)b {
    b.selected = !b.selected;
    self.model.videoSpeedAffectsZoomingLimit = b.selected;
    [GFViewKit toast:[NSString stringWithFormat:@"链接到「缩放限额」: %@", b.selected ? @"开" : @"关"] inView:self];
}

- (void)vsSpeedToggled:(UIButton *)b {
    b.selected = !b.selected;
    self.model.videoSpeedAffectsZooming = b.selected;
    [GFViewKit toast:[NSString stringWithFormat:@"链接到「缩放速度」: %@", b.selected ? @"开" : @"关"] inView:self];
}

- (void)vsSmoothToggled:(UIButton *)b {
    b.selected = !b.selected;
    self.model.videoSpeedAffectsSmoothing = b.selected;
    [GFViewKit toast:[NSString stringWithFormat:@"链接到「平滑」: %@", b.selected ? @"开" : @"关"] inView:self];
}

#pragma mark - 帧读出方向

// 循环顺序 上↑(1) -> 右→(2) -> 左←(3) -> 下↓(0) -> 上↑  (= 枚举 +1 取模)
- (void)readoutDirTapped {
    int cur = self.model.frameReadoutDirection;
    int next;
    switch (cur) {
        case 1: next = 2; break;   // 上 -> 右
        case 2: next = 3; break;   // 右 -> 左
        case 3: next = 0; break;   // 左 -> 下
        case 0: default: next = 1; break;   // 下 -> 上
    }
    self.model.frameReadoutDirection = next;
    [self updateReadoutDirButton];
    [GFViewKit toast:[NSString stringWithFormat:@"帧读出方向: %@", [self readoutDirName:next]] inView:self];
}

- (void)updateReadoutDirButton {
    [self.readoutDirBtn setTitle:[self readoutDirArrow:self.model.frameReadoutDirection]
                        forState:UIControlStateNormal];
}

// 枚举 -> 箭头: 0=↓(上→下) 1=↑(下→上) 2=→(左→右) 3=←(右→左)
- (NSString *)readoutDirArrow:(int)d {
    switch (d) {
        case 1: return @"↑";
        case 2: return @"→";
        case 3: return @"←";
        default: return @"↓";
    }
}

- (NSString *)readoutDirName:(int)d {
    switch (d) {
        case 1: return @"上";
        case 2: return @"右";
        case 3: return @"左";
        default: return @"下";
    }
}

@end
