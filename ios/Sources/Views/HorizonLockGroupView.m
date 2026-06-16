#import "HorizonLockGroupView.h"
#import "GFTheme.h"
#import "GFViewKit.h"

@interface HorizonLockGroupView ()
@property (nonatomic, strong) UIButton *lockCheckbox;

// 展开态控件 (包在 expandedContainer 里整体 hidden 切换)
@property (nonatomic, strong) UIView   *expandedContainer;
@property (nonatomic, strong) UISlider *amountSlider;
@property (nonatomic, strong) UITextField *amountValueLabel;
@property (nonatomic, strong) UISlider *rollSlider;
@property (nonatomic, strong) UITextField *rollValueLabel;

// 高级: 锁定俯仰
@property (nonatomic, strong) UIButton *pitchLockCheckbox;
@property (nonatomic, strong) UIView   *pitchSub;
@property (nonatomic, strong) UISlider *pitchSlider;
@property (nonatomic, strong) UITextField *pitchValueLabel;
// 高级: 自动锁定 + 子参数
@property (nonatomic, strong) UIButton *autoLockCheckbox;
@property (nonatomic, strong) UIView   *autoSub;
@property (nonatomic, strong) UISlider *turnThresholdSlider;
@property (nonatomic, strong) UITextField *turnThresholdValueLabel;
@property (nonatomic, strong) UISlider *turnSmoothingSlider;
@property (nonatomic, strong) UITextField *turnSmoothingValueLabel;
@property (nonatomic, strong) UISlider *turnMultiplierSlider;
@property (nonatomic, strong) UITextField *turnMultiplierValueLabel;
@property (nonatomic, strong) UISlider *tiltAccelSlider;
@property (nonatomic, strong) UITextField *tiltAccelValueLabel;
@end

@implementation HorizonLockGroupView

#pragma mark - Construction

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self buildSubviews];
    }
    return self;
}

- (void)buildSubviews {
    UIView *checkboxRow = [self makeCheckboxRow];
    self.expandedContainer = [self makeExpandedContainer];
    self.expandedContainer.hidden = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        checkboxRow,
        self.expandedContainer,
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

#pragma mark - Subview factories

- (UIView *)makeCheckboxRow {
    self.lockCheckbox = [GFViewKit makeCheckboxWithTarget:self
                                                   action:@selector(lockToggled:)];
    return [GFViewKit rowWithLabel:@"锁定地平线" control:self.lockCheckbox];
}

- (UIView *)makeExpandedContainer {
    UIView *amountRow = [GFViewKit sliderRowWithLabel:@"锁定量 %"
                                                  min:0.0f max:100.0f
                                            outSlider:&_amountSlider
                                        outValueField:&_amountValueLabel];
    [self.amountSlider addTarget:self
                          action:@selector(amountChanged)
                forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_amountValueLabel editSlider:_amountSlider scale:1.0];

    UIView *rollRow = [GFViewKit sliderRowWithLabel:@"Roll 角度校正 °"
                                                min:-180.0f max:180.0f
                                          outSlider:&_rollSlider
                                      outValueField:&_rollValueLabel];
    [self.rollSlider addTarget:self
                        action:@selector(rollChanged)
              forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_rollValueLabel editSlider:_rollSlider scale:1.0];

    // ---- 高级: 锁定俯仰角 ----
    self.pitchLockCheckbox = [GFViewKit makeCheckboxWithTarget:self action:@selector(pitchLockToggled:)];
    UIView *pitchCbRow = [GFViewKit rowWithLabel:@"锁定俯仰角" control:self.pitchLockCheckbox];
    UIView *pitchRow = [GFViewKit sliderRowWithLabel:@"俯仰角 °"
                                                 min:-90.0f max:90.0f
                                           outSlider:&_pitchSlider
                                       outValueField:&_pitchValueLabel];
    [self.pitchSlider addTarget:self action:@selector(pitchChanged) forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_pitchValueLabel editSlider:_pitchSlider scale:1.0];
    UIStackView *pitchSub = [[UIStackView alloc] initWithArrangedSubviews:@[pitchRow]];
    pitchSub.axis = UILayoutConstraintAxisVertical; pitchSub.spacing = 8.0; pitchSub.hidden = YES;
    [GFViewKit applyRevealIndent:pitchSub];
    self.pitchSub = pitchSub;

    // ---- 高级: 自动锁定 + 子参数 ----
    self.autoLockCheckbox = [GFViewKit makeCheckboxWithTarget:self action:@selector(autoLockToggled:)];
    UIView *autoCbRow = [GFViewKit rowWithLabel:@"自动锁定" control:self.autoLockCheckbox];
    UIView *thRow  = [GFViewKit sliderRowWithLabel:@"转向阈值 °/s"   min:0.0f max:50.0f   outSlider:&_turnThresholdSlider  outValueField:&_turnThresholdValueLabel];
    UIView *smRow  = [GFViewKit sliderRowWithLabel:@"转向平滑 ms"     min:0.0f max:2000.0f outSlider:&_turnSmoothingSlider  outValueField:&_turnSmoothingValueLabel];
    UIView *mulRow = [GFViewKit sliderRowWithLabel:@"转向倍率"        min:0.0f max:2.0f    outSlider:&_turnMultiplierSlider outValueField:&_turnMultiplierValueLabel];
    UIView *tiltRow= [GFViewKit sliderRowWithLabel:@"倾斜加速度限 °/s²" min:0.0f max:30.0f outSlider:&_tiltAccelSlider      outValueField:&_tiltAccelValueLabel];
    [self.turnThresholdSlider  addTarget:self action:@selector(turnThresholdChanged)  forControlEvents:UIControlEventValueChanged];
    [self.turnSmoothingSlider  addTarget:self action:@selector(turnSmoothingChanged)  forControlEvents:UIControlEventValueChanged];
    [self.turnMultiplierSlider addTarget:self action:@selector(turnMultiplierChanged) forControlEvents:UIControlEventValueChanged];
    [self.tiltAccelSlider      addTarget:self action:@selector(tiltAccelChanged)      forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_turnThresholdValueLabel  editSlider:_turnThresholdSlider  scale:1.0];
    [GFViewKit makeField:_turnSmoothingValueLabel  editSlider:_turnSmoothingSlider  scale:1.0];
    [GFViewKit makeField:_turnMultiplierValueLabel editSlider:_turnMultiplierSlider scale:1.0];
    [GFViewKit makeField:_tiltAccelValueLabel      editSlider:_tiltAccelSlider      scale:1.0];
    UIStackView *autoSub = [[UIStackView alloc] initWithArrangedSubviews:@[thRow, smRow, mulRow, tiltRow]];
    autoSub.axis = UILayoutConstraintAxisVertical; autoSub.spacing = 8.0; autoSub.hidden = YES;
    [GFViewKit applyRevealIndent:autoSub];
    self.autoSub = autoSub;

    UILabel *hint = [UILabel new];
    hint.numberOfLines = 0;
    hint.text = @"如果地平线锁定得不理想, 请尝试在\"运动数据\"部分中采用不同的积分方法。";
    hint.font = [UIFont systemFontOfSize:10.0];
    hint.textColor = [GFTheme secondaryTextColor];

    UIStackView *container = [[UIStackView alloc] initWithArrangedSubviews:@[amountRow, rollRow, pitchCbRow, pitchSub, autoCbRow, autoSub, hint]];
    container.axis = UILayoutConstraintAxisVertical;
    container.spacing = 8.0;
    [GFViewKit applyRevealIndent:container];   // 锁定地平线勾选展开内容左缩进 12px
    return container;
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
    self.lockCheckbox.selected     = m.horizonLock;
    self.expandedContainer.hidden  = !m.horizonLock;
    self.amountSlider.value        = (float)m.horizonLockAmount;
    self.rollSlider.value          = (float)m.horizonLockRoll;
    self.pitchLockCheckbox.selected = m.horizonLockPitchEnabled;
    self.pitchSub.hidden            = !m.horizonLockPitchEnabled;
    self.pitchSlider.value          = (float)m.horizonLockPitch;
    self.autoLockCheckbox.selected  = m.automaticHorizonLock;
    self.autoSub.hidden             = !m.automaticHorizonLock;
    self.turnThresholdSlider.value  = (float)m.turnThreshold;
    self.turnSmoothingSlider.value  = (float)m.turnSmoothingMs;
    self.turnMultiplierSlider.value = (float)m.turnMultiplier;
    self.tiltAccelSlider.value      = (float)m.tiltAccelLimit;
    [self refreshValueLabels];
}

- (void)refreshValueLabels {
    self.amountValueLabel.text = [NSString stringWithFormat:@"%.1f%%", self.amountSlider.value];
    self.rollValueLabel.text   = [NSString stringWithFormat:@"%.1f°", self.rollSlider.value];
    self.pitchValueLabel.text          = [NSString stringWithFormat:@"%.1f°", self.pitchSlider.value];
    self.turnThresholdValueLabel.text  = [NSString stringWithFormat:@"%.1f", self.turnThresholdSlider.value];
    self.turnSmoothingValueLabel.text  = [NSString stringWithFormat:@"%.0f", self.turnSmoothingSlider.value];
    self.turnMultiplierValueLabel.text = [NSString stringWithFormat:@"%.2f", self.turnMultiplierSlider.value];
    self.tiltAccelValueLabel.text      = [NSString stringWithFormat:@"%.1f", self.tiltAccelSlider.value];
}

#pragma mark - Actions

- (void)lockToggled:(UIButton *)sender {
    sender.selected = !sender.selected;
    BOOL on = sender.selected;
    self.model.horizonLock = on;
    [UIView animateWithDuration:0.2 animations:^{
        self.expandedContainer.hidden = !on;
    }];
}

- (void)amountChanged {
    double v = (double)self.amountSlider.value;
    self.model.horizonLockAmount = v;
    self.amountValueLabel.text = [NSString stringWithFormat:@"%.1f%%", v];
}

- (void)rollChanged {
    double v = (double)self.rollSlider.value;
    self.model.horizonLockRoll = v;
    self.rollValueLabel.text = [NSString stringWithFormat:@"%.1f°", v];
}

- (void)pitchLockToggled:(UIButton *)sender {
    sender.selected = !sender.selected;
    self.model.horizonLockPitchEnabled = sender.selected;
    [UIView animateWithDuration:0.2 animations:^{ self.pitchSub.hidden = !sender.selected; }];
}

- (void)pitchChanged {
    double v = (double)self.pitchSlider.value;
    self.model.horizonLockPitch = v;
    self.pitchValueLabel.text = [NSString stringWithFormat:@"%.1f°", v];
}

- (void)autoLockToggled:(UIButton *)sender {
    sender.selected = !sender.selected;
    self.model.automaticHorizonLock = sender.selected;
    [UIView animateWithDuration:0.2 animations:^{ self.autoSub.hidden = !sender.selected; }];
}

- (void)turnThresholdChanged {
    double v = (double)self.turnThresholdSlider.value;
    self.model.turnThreshold = v;
    self.turnThresholdValueLabel.text = [NSString stringWithFormat:@"%.1f", v];
}

- (void)turnSmoothingChanged {
    double v = (double)self.turnSmoothingSlider.value;
    self.model.turnSmoothingMs = v;
    self.turnSmoothingValueLabel.text = [NSString stringWithFormat:@"%.0f", v];
}

- (void)turnMultiplierChanged {
    double v = (double)self.turnMultiplierSlider.value;
    self.model.turnMultiplier = v;
    self.turnMultiplierValueLabel.text = [NSString stringWithFormat:@"%.2f", v];
}

- (void)tiltAccelChanged {
    double v = (double)self.tiltAccelSlider.value;
    self.model.tiltAccelLimit = v;
    self.tiltAccelValueLabel.text = [NSString stringWithFormat:@"%.1f", v];
}

@end
