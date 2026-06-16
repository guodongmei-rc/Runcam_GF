#import "StabilizeSectionView.h"
#import "StabilizeAdvancedView.h"
#import "HorizonLockGroupView.h"
#import "ZoomGroupView.h"
#import "GFTheme.h"
#import "GFViewKit.h"

@interface StabilizeSectionView ()
@property (nonatomic, strong) UIButton              *methodDropdown;
@property (nonatomic, strong) UIView                *smoothnessRowView;
@property (nonatomic, strong) UISlider              *smoothnessSlider;
@property (nonatomic, strong) UITextField           *smoothnessValueField;
@property (nonatomic, strong) UIButton              *advancedToggleButton;
@property (nonatomic, strong) UIView                *advancedToggleRow;
@property (nonatomic, strong) StabilizeAdvancedView *advancedView;
@property (nonatomic, assign) BOOL                   advancedExpanded;
// 固定摄像头 (method=3) 的角度滑块 —— Roll/Pitch/Yaw, 仅该算法时显示
@property (nonatomic, strong) UIView                *fixedAnglesContainer;
@property (nonatomic, strong) UISlider              *fixedRollSlider;
@property (nonatomic, strong) UITextField           *fixedRollLabel;
@property (nonatomic, strong) UISlider              *fixedPitchSlider;
@property (nonatomic, strong) UITextField           *fixedPitchLabel;
@property (nonatomic, strong) UISlider              *fixedYawSlider;
@property (nonatomic, strong) UITextField           *fixedYawLabel;
@property (nonatomic, strong) HorizonLockGroupView  *horizonLockGroup;
@property (nonatomic, strong) UILabel               *maxAngleLabel;
@property (nonatomic, strong) UILabel               *minFovLabel;
@property (nonatomic, strong) ZoomGroupView         *zoomGroup;
@end

@implementation StabilizeSectionView

#pragma mark - Construction

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [GFTheme secondaryBackgroundColor];
        self.layer.cornerRadius = 6.0;
        _advancedExpanded = NO;
        [self buildSubviews];
    }
    return self;
}

- (void)buildSubviews {
    UILabel *title = [self makeSectionTitle];

    UIView *methodRow = [self makeMethodRow];
    self.smoothnessRowView = [self makeSmoothnessRow];

    self.advancedToggleButton = [self makeAdvancedToggleButton];
    // 按钮自带「高级选项 ▾」标题, 直接铺满整行并居中显示 (不再用空 label 包)。
    self.advancedToggleRow = self.advancedToggleButton;

    self.advancedView = [StabilizeAdvancedView new];
    [GFViewKit applyAdvancedExpandStyle:self.advancedView];   // 高级区与主背景区分
    self.advancedView.hidden = !self.advancedExpanded;
    // per_axis 勾选时, 用 Pitch/Yaw/Roll 分轴平滑度替换上面的主平滑度行(隐藏主行)。
    __weak typeof(self) weakSelf = self;
    self.advancedView.onPerAxisChanged = ^(BOOL on) {
        [UIView animateWithDuration:0.2 animations:^{
            [weakSelf applyMethodVisibility];
        }];
    };

    // 固定摄像头 (method=3): Roll / Pitch / Yaw 角度滑块 (顺序按用户要求)
    self.fixedAnglesContainer = [self makeFixedAnglesContainer];
    self.fixedAnglesContainer.hidden = YES;

    self.horizonLockGroup = [HorizonLockGroupView new];

    self.maxAngleLabel = [self makeReadOnlyLabel];
    self.maxAngleLabel.text = @"最大旋转  P: -- ° / Y: -- ° / R: -- °";

    self.minFovLabel = [self makeReadOnlyLabel];
    self.minFovLabel.text = @"--%";

    self.zoomGroup = [ZoomGroupView new];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title,
        methodRow,
        self.smoothnessRowView,
        self.fixedAnglesContainer,
        self.advancedToggleRow,
        self.advancedView,
        self.horizonLockGroup,
        self.maxAngleLabel,
        self.minFovLabel,
        self.zoomGroup,
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor      constraintEqualToAnchor:self.topAnchor      constant:8],
        [stack.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor   constant:-8],
        [stack.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor  constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
    ]];
}

#pragma mark - Subview factories (拆开避免 buildSubviews 太长)

- (UILabel *)makeSectionTitle {
    UILabel *title = [UILabel new];
    title.text = @"稳定";
    title.font = [UIFont boldSystemFontOfSize:14.0];
    title.textColor = [GFTheme textColor];
    return title;
}

- (UIView *)makeMethodRow {
    NSArray<NSString *> *titles = @[@"无平滑", @"默认", @"纯3D", @"固定摄像头"];
    __weak typeof(self) weakSelf = self;
    self.methodDropdown = [GFViewKit makeDropdownWithTitles:titles
                                                   selected:1
                                                   onChange:^(NSInteger idx) {
        weakSelf.model.smoothingMethod = (int)idx;
        [weakSelf applyMethodVisibility];
    }];
    return [GFViewKit rowWithLabel:@"平滑算法" control:self.methodDropdown];
}

- (UIView *)makeSmoothnessRow {
    // 桌面 default_algo.rs:88-99: smoothness 范围 0.001-1.0, precision 3 (显示 0.500)。
    // 之前 iOS 是 0-100% 映射, 1.0 推到 FFI 时跟桌面一致, 但显示风格不同造成用户认知混淆。
    // 右侧改为可输入数值框 —— 可拖 slider 也可直接输入百分比。
    UIView *row = [GFViewKit sliderRowWithLabel:@"平滑度"
                                            min:0.001f
                                            max:1.0f
                                      outSlider:&_smoothnessSlider
                                  outValueField:&_smoothnessValueField];
    [self.smoothnessSlider addTarget:self
                              action:@selector(smoothnessChanged)
                    forControlEvents:UIControlEventValueChanged];
    [self.smoothnessValueField addTarget:self
                                  action:@selector(smoothnessFieldEdited)
                        forControlEvents:UIControlEventEditingDidEnd];
    return row;
}

// 固定摄像头角度容器: Roll / Pitch / Yaw 三个角度滑块 (-180..180°)。
// FFI key 分别是 roll/pitch/yaw, 由 model.fixedRoll/Pitch/Yaw setter 推到 "fixed" 算法。
- (UIView *)makeFixedAnglesContainer {
    UIView *rollRow = [GFViewKit sliderRowWithLabel:@"Roll 角度"
                                                min:-180.0f max:180.0f
                                          outSlider:&_fixedRollSlider
                                      outValueField:&_fixedRollLabel];
    [self.fixedRollSlider addTarget:self action:@selector(fixedRollChanged) forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_fixedRollLabel editSlider:_fixedRollSlider scale:1.0];

    UIView *pitchRow = [GFViewKit sliderRowWithLabel:@"Pitch 角度"
                                                 min:-180.0f max:180.0f
                                           outSlider:&_fixedPitchSlider
                                       outValueField:&_fixedPitchLabel];
    [self.fixedPitchSlider addTarget:self action:@selector(fixedPitchChanged) forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_fixedPitchLabel editSlider:_fixedPitchSlider scale:1.0];

    UIView *yawRow = [GFViewKit sliderRowWithLabel:@"Yaw 角度"
                                               min:-180.0f max:180.0f
                                         outSlider:&_fixedYawSlider
                                     outValueField:&_fixedYawLabel];
    [self.fixedYawSlider addTarget:self action:@selector(fixedYawChanged) forControlEvents:UIControlEventValueChanged];
    [GFViewKit makeField:_fixedYawLabel editSlider:_fixedYawSlider scale:1.0];

    UIStackView *c = [[UIStackView alloc] initWithArrangedSubviews:@[rollRow, pitchRow, yawRow]];
    c.axis = UILayoutConstraintAxisVertical;
    c.spacing = 8.0;
    return c;
}

- (UIButton *)makeAdvancedToggleButton {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.titleLabel.font = [UIFont systemFontOfSize:12.0];
    btn.tintColor = [GFTheme primaryColor];
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    [btn setTitle:[self advancedToggleTitle] forState:UIControlStateNormal];
    [btn addTarget:self
            action:@selector(advancedToggleTapped)
  forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (UILabel *)makeReadOnlyLabel {
    UILabel *label = [UILabel new];
    label.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    label.textColor = [GFTheme secondaryTextColor];
    return label;
}

#pragma mark - Advanced collapse / expand

- (NSString *)advancedToggleTitle {
    return self.advancedExpanded ? @"高级选项 ▴" : @"高级选项 ▾";
}

- (void)advancedToggleTapped {
    self.advancedExpanded = !self.advancedExpanded;
    [self.advancedToggleButton setTitle:[self advancedToggleTitle] forState:UIControlStateNormal];
    [UIView animateWithDuration:0.2 animations:^{
        [self applyMethodVisibility];
    }];
}

#pragma mark - 按平滑算法切换面板显隐

// 平滑算法切换 / per_axis 切换 / 展开折叠 / 加载 model 时统一调这里:
//   无平滑(0):  隐藏平滑度 + 高级选项
//   默认(1):    平滑度(%) + 高级选项(全量); per_axis ON 时主平滑度让位给分轴
//   纯3D(2):    平滑度(按秒) + 高级选项(仅「仅限修建范围内」)
//   固定摄像头(3): 隐藏平滑度 + 高级选项, 显示 Roll/Pitch/Yaw 角度
- (void)applyMethodVisibility {
    ParamsModel *m = self.model;
    int method = m ? m.smoothingMethod : 1;
    BOOL isPlain   = (method == 2);
    BOOL isFixed   = (method == 3);
    BOOL isDefault = (method == 1);

    BOOL showSmooth = isDefault ? !m.perAxis : isPlain;
    self.smoothnessRowView.hidden = !showSmooth;
    [self configureSmoothnessRowForMethod:method];

    BOOL showAdvanced = (isDefault || isPlain);
    self.advancedToggleRow.hidden = !showAdvanced;
    self.advancedView.hidden = !(showAdvanced && self.advancedExpanded);
    [self.advancedView configureForMethod:method];

    self.fixedAnglesContainer.hidden = !isFixed;
}

// 平滑度行的滑块范围/数值随算法变: 默认=百分比(0.001..1.0), 纯3D=秒(time_constant 0..3)。
- (void)configureSmoothnessRowForMethod:(int)method {
    ParamsModel *m = self.model;
    if (m == nil) {
        return;
    }
    if (method == 2) {
        self.smoothnessSlider.minimumValue = 0.0f;
        self.smoothnessSlider.maximumValue = 3.0f;
        self.smoothnessSlider.value = (float)m.plain3dTimeConstant;
        self.smoothnessValueField.text = [NSString stringWithFormat:@"%.2f", m.plain3dTimeConstant];
    } else {
        self.smoothnessSlider.minimumValue = 0.001f;
        self.smoothnessSlider.maximumValue = 1.0f;
        self.smoothnessSlider.value = (float)m.smoothness;
        self.smoothnessValueField.text = [NSString stringWithFormat:@"%.1f", m.smoothness * 100.0];
    }
}

#pragma mark - Model sync

- (void)setModel:(ParamsModel *)model {
    _model = model;
    self.advancedView.model    = model;
    self.horizonLockGroup.model = model;
    self.zoomGroup.model       = model;
    if (model == nil) {
        return;
    }
    // dropdown 初始 title 在 makeDropdown 时按 selected:1 设置好。如 model 切到别的 index,
    // 这里手动更新一下 button 标题保持同步 (UIMenu 内部 state 在 onChange 才更新)。
    if (@available(iOS 14.0, *)) {
        NSArray<NSString *> *titles = @[@"无平滑", @"默认", @"纯3D", @"固定摄像头"];
        NSInteger idx = MAX(0, MIN((NSInteger)titles.count - 1, model.smoothingMethod));
        [self.methodDropdown setTitle:[NSString stringWithFormat:@"%@  ▾", titles[idx]]
                             forState:UIControlStateNormal];
    }
    // 固定摄像头角度回填
    self.fixedRollSlider.value  = (float)model.fixedRoll;
    self.fixedPitchSlider.value = (float)model.fixedPitch;
    self.fixedYawSlider.value   = (float)model.fixedYaw;
    self.fixedRollLabel.text  = [NSString stringWithFormat:@"%+.1f°", model.fixedRoll];
    self.fixedPitchLabel.text = [NSString stringWithFormat:@"%+.1f°", model.fixedPitch];
    self.fixedYawLabel.text   = [NSString stringWithFormat:@"%+.1f°", model.fixedYaw];
    // 平滑度行(值/单位/显隐)+ 高级 + 固定角度 一并按当前算法配置
    [self applyMethodVisibility];
    [self refreshReadOnly];
}

- (void)refreshReadOnly {
    ParamsModel *m = self.model;
    if (m == nil) {
        return;
    }
    self.maxAngleLabel.text = [NSString stringWithFormat:
        @"最大旋转  P:%5.1f° / Y:%5.1f° / R:%5.1f°",
        m.maxAnglePitch, m.maxAngleYaw, m.maxAngleRoll];
    double zoomPct = (m.minFov > 0.0001) ? (100.0 / m.minFov) : 0.0;
    self.minFovLabel.text = [NSString stringWithFormat:@"%.1f%%", zoomPct];
}

#pragma mark - Actions (view -> model)

- (void)smoothnessChanged {
    double v = (double)self.smoothnessSlider.value;
    if (self.model.smoothingMethod == 2) {
        // 纯3D: 平滑度 = time_constant, 按秒显示
        self.smoothnessValueField.text = [NSString stringWithFormat:@"%.2f", v];
        self.model.plain3dTimeConstant = v;
    } else {
        // 默认: 输入框显示 0..100 的百分比, 跟桌面 SliderWithField 默认风格一致。
        self.smoothnessValueField.text = [NSString stringWithFormat:@"%.1f", v * 100.0];
        self.model.smoothness = v;
    }
}

- (void)fixedRollChanged {
    double v = (double)self.fixedRollSlider.value;
    self.fixedRollLabel.text = [NSString stringWithFormat:@"%+.1f°", v];
    self.model.fixedRoll = v;
}

- (void)fixedPitchChanged {
    double v = (double)self.fixedPitchSlider.value;
    self.fixedPitchLabel.text = [NSString stringWithFormat:@"%+.1f°", v];
    self.model.fixedPitch = v;
}

- (void)fixedYawChanged {
    double v = (double)self.fixedYawSlider.value;
    self.fixedYawLabel.text = [NSString stringWithFormat:@"%+.1f°", v];
    self.model.fixedYaw = v;
}

// 用户在数值框里输入回车 / 失焦时回调。把百分比 (0..100) 转回 0..1, clamp 到
// slider 范围 (0.001..1.0), 同步 slider 位置 + 写回 model; 非法输入回滚到当前 model 值。
- (void)smoothnessFieldEdited {
    NSString *txt = self.smoothnessValueField.text ?: @"";
    NSScanner *scanner = [NSScanner scannerWithString:txt];
    double parsed = 0.0;
    BOOL ok = [scanner scanDouble:&parsed];
    if (self.model.smoothingMethod == 2) {
        // 纯3D: 输入的是秒 (time_constant), clamp 0..3
        if (!ok) {
            self.smoothnessValueField.text = [NSString stringWithFormat:@"%.2f", self.model.plain3dTimeConstant];
            return;
        }
        double v = parsed;
        if (v < 0.0) v = 0.0;
        if (v > 3.0) v = 3.0;
        self.smoothnessSlider.value = (float)v;
        self.smoothnessValueField.text = [NSString stringWithFormat:@"%.2f", v];
        self.model.plain3dTimeConstant = v;
        return;
    }
    // 默认: 输入百分比 (0..100) → 0..1, clamp 到 slider 范围 (0.001..1.0)
    if (!ok) {
        self.smoothnessValueField.text = [NSString stringWithFormat:@"%.1f", self.model.smoothness * 100.0];
        return;
    }
    double v = parsed / 100.0;
    if (v < 0.001) v = 0.001;
    if (v > 1.0)   v = 1.0;
    self.smoothnessSlider.value = (float)v;
    self.smoothnessValueField.text = [NSString stringWithFormat:@"%.1f", v * 100.0];
    self.model.smoothness = v;
}

@end
