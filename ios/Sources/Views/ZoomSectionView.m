#import "ZoomSectionView.h"
#import "GFTheme.h"
#import "GFViewKit.h"

@interface ZoomSectionView ()
@property (nonatomic, strong) UISlider *maxZoomSlider;
@property (nonatomic, strong) UILabel  *maxZoomVL;
@property (nonatomic, strong) UISlider *iterSlider;
@property (nonatomic, strong) UILabel  *iterVL;
@property (nonatomic, strong) UISlider *adaptiveZoomSlider;
@property (nonatomic, strong) UILabel  *adaptiveZoomVL;
@property (nonatomic, strong) UISlider *lensCorrSlider;
@property (nonatomic, strong) UILabel  *lensCorrVL;
@property (nonatomic, strong) UISlider     *fovSlider;
@property (nonatomic, strong) UITextField  *fovField;
@property (nonatomic, strong) UISwitch *rsSwitch;
@property (nonatomic, strong) UISlider *frameReadoutSlider;
@property (nonatomic, strong) UILabel  *frameReadoutVL;
@property (nonatomic, strong) UISlider *pitchSlider;
@property (nonatomic, strong) UILabel  *pitchVL;
@property (nonatomic, strong) UISlider *yawSlider;
@property (nonatomic, strong) UILabel  *yawVL;
@property (nonatomic, strong) UISlider *rollSlider;
@property (nonatomic, strong) UILabel  *rollVL;
@end

@implementation ZoomSectionView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [GFTheme secondaryBackgroundColor];
        self.layer.cornerRadius = 6.0;

        UILabel *title = [UILabel new];
        title.text = @"缩放与画面";
        title.font = [UIFont boldSystemFontOfSize:14.0];
        title.textColor = [GFTheme textColor];

        UIView *r1 = [self sliderRow:@"缩放限额 (%)"     slider:&_maxZoomSlider      min:100 max:300  vl:&_maxZoomVL];
        [_maxZoomSlider      addTarget:self action:@selector(maxZoomChanged)      forControlEvents:UIControlEventValueChanged];
        UIView *r2 = [self sliderRow:@"迭代次数"        slider:&_iterSlider         min:1   max:10   vl:&_iterVL];
        [_iterSlider         addTarget:self action:@selector(iterChanged)         forControlEvents:UIControlEventValueChanged];
        UIView *r3 = [self sliderRow:@"缩放速度 (s)"    slider:&_adaptiveZoomSlider min:0   max:10   vl:&_adaptiveZoomVL];
        [_adaptiveZoomSlider addTarget:self action:@selector(adaptiveZoomChanged) forControlEvents:UIControlEventValueChanged];
        UIView *r4 = [self sliderRow:@"镜头校正 (%)"    slider:&_lensCorrSlider     min:0   max:100  vl:&_lensCorrVL];
        [_lensCorrSlider     addTarget:self action:@selector(lensCorrChanged)     forControlEvents:UIControlEventValueChanged];
        // 视场角: 右侧改为可输入数值框 (可拖 slider 也可手输 0.30..3.00 的小数)
        UIView *r5 = [GFViewKit sliderRowWithLabel:@"视场角"
                                               min:0.3f
                                               max:3.0f
                                         outSlider:&_fovSlider
                                     outValueField:&_fovField];
        [_fovSlider addTarget:self action:@selector(fovChanged)      forControlEvents:UIControlEventValueChanged];
        [_fovField  addTarget:self action:@selector(fovFieldEdited)  forControlEvents:UIControlEventEditingDidEnd];

        // r6 "缩放方式" (禁用/动态/静态) 已删除 —— 在「稳定」section 的 ZoomGroupView 里有
        // 真·裁剪模式 (无缩放/动态/静态 -> croppingMode) + 缩放方式下拉 (Gaussian/Envelope -> zoomingMethod),
        // 这里这个 segment 字段映射本来就错了 (写 zoomingMethod 当 0/1/2 当裁剪模式用)。
        _rsSwitch = [UISwitch new];
        [GFViewKit applyToSwitch:_rsSwitch];
        [_rsSwitch addTarget:self action:@selector(rsChanged) forControlEvents:UIControlEventValueChanged];
        UIView *r7a = [self labeled:@"卷帘快门校正" control:_rsSwitch];
        UIView *r7b = [self sliderRow:@"帧读出 (ms)" slider:&_frameReadoutSlider min:0 max:50 vl:&_frameReadoutVL];
        [_frameReadoutSlider addTarget:self action:@selector(frameReadoutChanged) forControlEvents:UIControlEventValueChanged];

        UIView *r8a = [self sliderRow:@"3D 旋转 Pitch" slider:&_pitchSlider min:-180 max:180 vl:&_pitchVL];
        [_pitchSlider addTarget:self action:@selector(pitchChanged) forControlEvents:UIControlEventValueChanged];
        UIView *r8b = [self sliderRow:@"3D 旋转 Yaw"   slider:&_yawSlider   min:-180 max:180 vl:&_yawVL];
        [_yawSlider   addTarget:self action:@selector(yawChanged)   forControlEvents:UIControlEventValueChanged];
        UIView *r8c = [self sliderRow:@"3D 旋转 Roll"  slider:&_rollSlider  min:-180 max:180 vl:&_rollVL];
        [_rollSlider  addTarget:self action:@selector(rollChanged)  forControlEvents:UIControlEventValueChanged];

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, r1, r2, r3, r4, r5, r7a, r7b, r8a, r8b, r8c]];
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
    return self;
}

- (UIView *)sliderRow:(NSString *)t slider:(UISlider * __strong *)s min:(float)mn max:(float)mx vl:(UILabel * __strong *)vl {
    UILabel *label = [UILabel new];
    label.text = t; label.font = [UIFont systemFontOfSize:12.0];
    label.textColor = [GFTheme secondaryTextColor];
    [label.widthAnchor constraintEqualToConstant:130.0].active = YES;

    UISlider *slider = [UISlider new]; slider.minimumValue = mn; slider.maximumValue = mx;
    [GFViewKit applyToSlider:slider];
    *s = slider;

    UILabel *valueLabel = [UILabel new];
    valueLabel.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    valueLabel.textColor = [GFTheme textColor]; valueLabel.textAlignment = NSTextAlignmentRight;
    [valueLabel.widthAnchor constraintEqualToConstant:60.0].active = YES;
    *vl = valueLabel;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, slider, valueLabel]];
    row.axis = UILayoutConstraintAxisHorizontal; row.spacing = 8.0; row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (UIView *)labeled:(NSString *)t control:(UIView *)c {
    UILabel *label = [UILabel new];
    label.text = t; label.font = [UIFont systemFontOfSize:12.0];
    label.textColor = [GFTheme secondaryTextColor];
    [label.widthAnchor constraintEqualToConstant:130.0].active = YES;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, c]];
    row.axis = UILayoutConstraintAxisHorizontal; row.spacing = 8.0; row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (void)setModel:(ParamsModel *)model {
    _model = model;
    if (model == nil) return;
    self.maxZoomSlider.value      = (float)model.maxZoomPercent;     self.maxZoomVL.text      = [NSString stringWithFormat:@"%.0f%%", model.maxZoomPercent];
    self.iterSlider.value         = (float)model.maxZoomIterations;  self.iterVL.text         = [NSString stringWithFormat:@"%d", model.maxZoomIterations];
    self.adaptiveZoomSlider.value = (float)model.adaptiveZoomSec;    self.adaptiveZoomVL.text = [NSString stringWithFormat:@"%.1fs", model.adaptiveZoomSec];
    self.lensCorrSlider.value     = (float)(model.lensCorrection*100); self.lensCorrVL.text   = [NSString stringWithFormat:@"%.0f%%", model.lensCorrection*100];
    self.fovSlider.value          = (float)model.fov;                self.fovField.text       = [NSString stringWithFormat:@"%.2f", model.fov];
    self.rsSwitch.on              = model.rsCorrection;
    self.frameReadoutSlider.value = (float)model.frameReadoutMs;     self.frameReadoutVL.text = [NSString stringWithFormat:@"%.2f", model.frameReadoutMs];
    self.pitchSlider.value        = (float)model.addPitch;           self.pitchVL.text        = [NSString stringWithFormat:@"%+.1f", model.addPitch];
    self.yawSlider.value          = (float)model.addYaw;             self.yawVL.text          = [NSString stringWithFormat:@"%+.1f", model.addYaw];
    self.rollSlider.value         = (float)model.addRoll;            self.rollVL.text         = [NSString stringWithFormat:@"%+.1f", model.addRoll];
}

- (void)refreshReadOnly { /* 本 section 无只读字段 */ }

- (void)maxZoomChanged       { double v = (double)self.maxZoomSlider.value;      self.maxZoomVL.text      = [NSString stringWithFormat:@"%.0f%%", v]; self.model.maxZoomPercent = v; }
- (void)iterChanged          { int v = (int)roundf(self.iterSlider.value);       self.iterVL.text         = [NSString stringWithFormat:@"%d", v];     self.model.maxZoomIterations = v; }
- (void)adaptiveZoomChanged  { double v = (double)self.adaptiveZoomSlider.value; self.adaptiveZoomVL.text = [NSString stringWithFormat:@"%.1fs", v];  self.model.adaptiveZoomSec = v; }
- (void)lensCorrChanged      { double pct = (double)self.lensCorrSlider.value;   self.lensCorrVL.text     = [NSString stringWithFormat:@"%.0f%%", pct]; self.model.lensCorrection = pct/100.0; }
- (void)fovChanged           { double v = (double)self.fovSlider.value;          self.fovField.text       = [NSString stringWithFormat:@"%.2f", v];   self.model.fov = v; }
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
- (void)rsChanged            { self.model.rsCorrection = self.rsSwitch.on; }
- (void)frameReadoutChanged  { double v = (double)self.frameReadoutSlider.value; self.frameReadoutVL.text = [NSString stringWithFormat:@"%.2f", v];   self.model.frameReadoutMs = v; }
- (void)pitchChanged         { double v = (double)self.pitchSlider.value;        self.pitchVL.text        = [NSString stringWithFormat:@"%+.1f", v];  self.model.addPitch = v; }
- (void)yawChanged           { double v = (double)self.yawSlider.value;          self.yawVL.text          = [NSString stringWithFormat:@"%+.1f", v];  self.model.addYaw   = v; }
- (void)rollChanged          { double v = (double)self.rollSlider.value;         self.rollVL.text         = [NSString stringWithFormat:@"%+.1f", v];  self.model.addRoll  = v; }

@end
