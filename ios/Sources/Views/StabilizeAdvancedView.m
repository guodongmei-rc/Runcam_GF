#import "StabilizeAdvancedView.h"
#import "GFTheme.h"
#import "GFViewKit.h"

@interface StabilizeAdvancedView ()
// Checkboxes (替代原 UISwitch, 跟 SyncAdvancedView 风格一致)
@property (nonatomic, strong) UIButton *perAxisCheckbox;
@property (nonatomic, strong) UIButton *trimRangeOnlyCheckbox;

// 各行存为属性, 方便按平滑算法整行 show/hide (纯3D 只保留「仅限修建范围内」)
@property (nonatomic, strong) UIView   *perAxisRow;
@property (nonatomic, strong) UIView   *trimRow;
@property (nonatomic, strong) UIView   *maxSmoothRow;
@property (nonatomic, strong) UIView   *alphaRow;
// per_axis ON 时显露的 3 个分轴平滑度 slider (放在容器 perAxisAxesContainer 里方便整体 hidden)
@property (nonatomic, strong) UIView   *perAxisAxesContainer;
@property (nonatomic, strong) UISlider *pitchSlider;
@property (nonatomic, strong) UITextField *pitchValueLabel;
@property (nonatomic, strong) UISlider *yawSlider;
@property (nonatomic, strong) UITextField *yawValueLabel;
@property (nonatomic, strong) UISlider *rollSlider;
@property (nonatomic, strong) UITextField *rollValueLabel;

// 高级 sliders
@property (nonatomic, strong) UISlider *maxSmoothnessSlider;
@property (nonatomic, strong) UITextField *maxSmoothnessValueLabel;
@property (nonatomic, strong) UISlider *alphaHighVelSlider;
@property (nonatomic, strong) UITextField *alphaHighVelValueLabel;
@end

@implementation StabilizeAdvancedView

#pragma mark - Construction

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self buildSubviews];
    }
    return self;
}

- (void)buildSubviews {
    self.perAxisRow = [self makePerAxisRow];
    self.perAxisAxesContainer = [self makePerAxisAxesContainer];
    self.perAxisAxesContainer.hidden = YES;

    self.trimRow = [self makeTrimRangeOnlyRow];
    self.maxSmoothRow = [self makeMaxSmoothnessRow];
    self.alphaRow = [self makeAlphaHighVelRow];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.perAxisRow,
        self.perAxisAxesContainer,
        self.trimRow,
        self.maxSmoothRow,
        self.alphaRow,
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor      constraintEqualToAnchor:self.topAnchor      constant:6.0],
        [stack.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor   constant:-6.0],
        [stack.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor  constant:6.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6.0],
    ]];
}

#pragma mark - Subview factories

- (UIView *)makePerAxisRow {
    self.perAxisCheckbox = [GFViewKit makeCheckboxWithTarget:self
                                                      action:@selector(perAxisToggled:)];
    return [GFViewKit rowWithLabel:@"按轴" control:self.perAxisCheckbox];
}

// 3 个分轴 slider 包成一个垂直 stack, 整体 hidden 切换不用单独动 3 个
- (UIView *)makePerAxisAxesContainer {
    UIView *pitchRow = [GFViewKit sliderRowWithLabel:@"Pitch 平滑度"
                                                 min:0.001f max:1.0f
                                           outSlider:&_pitchSlider
                                       outValueField:&_pitchValueLabel];
    [self.pitchSlider addTarget:self
                         action:@selector(pitchChanged)
               forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_pitchValueLabel editSlider:_pitchSlider scale:100.0];

    UIView *yawRow = [GFViewKit sliderRowWithLabel:@"Yaw 平滑度"
                                               min:0.001f max:1.0f
                                         outSlider:&_yawSlider
                                     outValueField:&_yawValueLabel];
    [self.yawSlider addTarget:self
                       action:@selector(yawChanged)
             forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_yawValueLabel editSlider:_yawSlider scale:100.0];

    UIView *rollRow = [GFViewKit sliderRowWithLabel:@"Roll 平滑度"
                                                min:0.001f max:1.0f
                                          outSlider:&_rollSlider
                                      outValueField:&_rollValueLabel];
    [self.rollSlider addTarget:self
                        action:@selector(rollChanged)
              forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_rollValueLabel editSlider:_rollSlider scale:100.0];

    UIStackView *container = [[UIStackView alloc] initWithArrangedSubviews:@[pitchRow, yawRow, rollRow]];
    container.axis = UILayoutConstraintAxisVertical;
    container.spacing = 8.0;
    return container;
}

- (UIView *)makeTrimRangeOnlyRow {
    self.trimRangeOnlyCheckbox = [GFViewKit makeCheckboxWithTarget:self
                                                            action:@selector(trimRangeOnlyToggled:)];
    UILabel *hint = [UILabel new];
    hint.text = @"(仅在设置修剪范围时生效)";
    hint.font = [UIFont systemFontOfSize:10.0];
    hint.textColor = [GFTheme secondaryTextColor];
    return [GFViewKit rowWithLabel:@"仅限修建范围内"
                           control:self.trimRangeOnlyCheckbox
                          trailing:hint];
}

- (UIView *)makeMaxSmoothnessRow {
    UIView *row = [GFViewKit sliderRowWithLabel:@"最大平滑度"
                                            min:0.1f max:5.0f
                                      outSlider:&_maxSmoothnessSlider
                                  outValueField:&_maxSmoothnessValueLabel];
    [self.maxSmoothnessSlider addTarget:self
                                 action:@selector(maxSmoothnessChanged)
                       forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_maxSmoothnessValueLabel editSlider:_maxSmoothnessSlider scale:1.0];
    return row;
}

- (UIView *)makeAlphaHighVelRow {
    UIView *row = [GFViewKit sliderRowWithLabel:@"高速最大平滑度"
                                            min:0.01f max:1.0f
                                      outSlider:&_alphaHighVelSlider
                                  outValueField:&_alphaHighVelValueLabel];
    [self.alphaHighVelSlider addTarget:self
                                action:@selector(alphaHighVelChanged)
                      forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_alphaHighVelValueLabel editSlider:_alphaHighVelSlider scale:1.0];
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
    self.perAxisCheckbox.selected       = m.perAxis;
    self.trimRangeOnlyCheckbox.selected = m.trimRangeOnly;
    self.perAxisAxesContainer.hidden    = !m.perAxis;

    self.pitchSlider.value          = (float)m.smoothnessPitch;
    self.yawSlider.value            = (float)m.smoothnessYaw;
    self.rollSlider.value           = (float)m.smoothnessRoll;
    self.maxSmoothnessSlider.value  = (float)m.maxSmoothnessSec;
    self.alphaHighVelSlider.value   = (float)m.alphaHighVelSec;
    [self refreshValueLabels];
}

// 按平滑算法配置高级区各行的显隐:
//   纯3D(method=2): 只保留「仅限修建范围内」(time_constant 算法只有这一个 advanced 参数)
//   其它(默认): 全量显示。per_axis 容器另由 per_axis 开关控制。
- (void)configureForMethod:(int)method {
    BOOL isPlain = (method == 2);
    self.perAxisRow.hidden          = isPlain;
    self.maxSmoothRow.hidden        = isPlain;
    self.alphaRow.hidden            = isPlain;
    self.perAxisAxesContainer.hidden = isPlain || !self.model.perAxis;
    self.trimRow.hidden             = NO;   // 「仅限修建范围内」始终保留
}

- (void)refreshValueLabels {
    self.pitchValueLabel.text         = [NSString stringWithFormat:@"%.1f%%", self.pitchSlider.value * 100.0];
    self.yawValueLabel.text           = [NSString stringWithFormat:@"%.1f%%", self.yawSlider.value * 100.0];
    self.rollValueLabel.text          = [NSString stringWithFormat:@"%.1f%%", self.rollSlider.value * 100.0];
    self.maxSmoothnessValueLabel.text = [NSString stringWithFormat:@"%.3fs", self.maxSmoothnessSlider.value];
    self.alphaHighVelValueLabel.text  = [NSString stringWithFormat:@"%.3fs", self.alphaHighVelSlider.value];
}

#pragma mark - Actions (view -> model)

- (void)perAxisToggled:(UIButton *)sender {
    sender.selected = !sender.selected;
    BOOL on = sender.selected;
    self.model.perAxis = on;
    [UIView animateWithDuration:0.2 animations:^{
        self.perAxisAxesContainer.hidden = !on;
    }];
    if (self.onPerAxisChanged) {
        self.onPerAxisChanged(on);
    }
}

- (void)trimRangeOnlyToggled:(UIButton *)sender {
    sender.selected = !sender.selected;
    self.model.trimRangeOnly = sender.selected;
}

- (void)pitchChanged {
    double v = (double)self.pitchSlider.value;
    self.model.smoothnessPitch = v;
    self.pitchValueLabel.text = [NSString stringWithFormat:@"%.1f%%", v * 100.0];
}

- (void)yawChanged {
    double v = (double)self.yawSlider.value;
    self.model.smoothnessYaw = v;
    self.yawValueLabel.text = [NSString stringWithFormat:@"%.1f%%", v * 100.0];
}

- (void)rollChanged {
    double v = (double)self.rollSlider.value;
    self.model.smoothnessRoll = v;
    self.rollValueLabel.text = [NSString stringWithFormat:@"%.1f%%", v * 100.0];
}

- (void)maxSmoothnessChanged {
    double v = (double)self.maxSmoothnessSlider.value;
    self.model.maxSmoothnessSec = v;
    self.maxSmoothnessValueLabel.text = [NSString stringWithFormat:@"%.3fs", v];
}

- (void)alphaHighVelChanged {
    double v = (double)self.alphaHighVelSlider.value;
    self.model.alphaHighVelSec = v;
    self.alphaHighVelValueLabel.text = [NSString stringWithFormat:@"%.3fs", v];
}

@end
