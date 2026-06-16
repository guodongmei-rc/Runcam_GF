#import "SyncAdvancedView.h"
#import "GFTheme.h"
#import "GFViewKit.h"

@interface SyncAdvancedView () <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *everyNthTF;
@property (nonatomic, strong) UITextField *perPointTF;
@property (nonatomic, strong) UIButton *resDropdown;
@property (nonatomic, strong) UIButton *ofDropdown;
@property (nonatomic, strong) UIButton *poseDropdown;
@property (nonatomic, strong) UIButton *offsetDropdown;
@property (nonatomic, strong) UIButton *lpfCheckbox;
@property (nonatomic, strong) UITextField *lpfTF;
@property (nonatomic, strong) UILabel *lpfUnitLabel;  // 用来跟 lpfTF 一起显隐
@property (nonatomic, strong) UIButton *showFeaturesCheckbox;
@property (nonatomic, strong) UIButton *showOFCheckbox;

// 下拉选项静态表(标题 → Model 字段值)
@property (nonatomic, strong) NSArray<NSString *> *resTitles;     // 0=原生, 后续是 height 值
@property (nonatomic, strong) NSArray<NSNumber *> *resValues;
@property (nonatomic, strong) NSArray<NSString *> *ofTitles;
@property (nonatomic, strong) NSArray<NSString *> *poseTitles;
@property (nonatomic, strong) NSArray<NSString *> *offsetTitles;
@end

@implementation SyncAdvancedView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [GFTheme backgroundColor];
        self.layer.cornerRadius = 4.0;

        _resTitles    = @[@"原生", @"4K", @"1080p", @"720p", @"480p"];
        _resValues    = @[@0, @2160, @1080, @720, @480];
        // 标题严格对齐官方 app。注意:of_method 顺序必须和 Rust 枚举一致
        // (optical_flow/mod.rs):0=AKAZE,1=PyrLK,2=DIS。之前写反(DIS 在 0)
        // 导致选 DIS 实际跑 AKAZE。pose/offset 的顺序本来就和 Rust 一致。
        _ofTitles     = @[@"AKAZE", @"OpenCV (PyrLK)", @"OpenCV (DIS)"];
        _poseTitles   = @[@"findEssentialMat", @"Almeida", @"EightPoint", @"findHomography"];
        _offsetTitles = @[@"本质矩阵", @"视觉功能", @"卷帘快门同步"];

        [self buildSubviews];
    }
    return self;
}

- (void)buildSubviews {
    _everyNthTF = [self makeTextField:UIKeyboardTypeNumberPad];
    UIView *r1 = [self inputRow:@"每 N 帧执行分析" textField:_everyNthTF unit:@""];

    _perPointTF = [self makeTextField:UIKeyboardTypeDecimalPad];
    UIView *r2 = [self inputRow:@"每个同步点分析时长" textField:_perPointTF unit:@"秒"];

    __weak typeof(self) weakSelf = self;
    _resDropdown    = [self makeDropdownWithTitles:_resTitles    selected:1 onChange:^(NSInteger i) {
        weakSelf.model.syncProcessingHeight = weakSelf.resValues[i].intValue;
    }];
    _ofDropdown     = [self makeDropdownWithTitles:_ofTitles     selected:0 onChange:^(NSInteger i) {
        weakSelf.model.ofMethod = (int)i;
    }];
    _poseDropdown   = [self makeDropdownWithTitles:_poseTitles   selected:0 onChange:^(NSInteger i) {
        weakSelf.model.poseMethod = (int)i;
    }];
    _offsetDropdown = [self makeDropdownWithTitles:_offsetTitles selected:0 onChange:^(NSInteger i) {
        weakSelf.model.offsetMethod = (int)i;
    }];

    UIView *r3 = [self labeled:@"处理分辨率" control:_resDropdown];
    UIView *r4 = [self labeled:@"光流方式"   control:_ofDropdown];
    UIView *r5 = [self labeled:@"姿态方式"   control:_poseDropdown];
    UIView *r6 = [self labeled:@"偏移方式"   control:_offsetDropdown];

    // 低通滤波器:checkbox + (勾选时才显示)Hz 输入框 + 单位标签
    _lpfCheckbox = [self makeCheckbox:@selector(lpfToggled:)];
    _lpfTF = [self makeTextField:UIKeyboardTypeDecimalPad];
    _lpfTF.hidden = YES;  // 初始未勾选 → 隐藏
    UILabel *lpfUnit = [UILabel new];
    lpfUnit.text = @"Hz";
    lpfUnit.font = [UIFont systemFontOfSize:12.0];
    lpfUnit.textColor = [GFTheme secondaryTextColor];
    [lpfUnit.widthAnchor constraintEqualToConstant:30.0].active = YES;
    lpfUnit.hidden = YES;
    _lpfUnitLabel = lpfUnit;
    UIView *r7 = [self lpfRowWithCheckbox:_lpfCheckbox label:@"低通滤波器" textField:_lpfTF unitLabel:lpfUnit];

    _showFeaturesCheckbox = [self makeCheckbox:@selector(showFeaturesToggled:)];
    // 空 UIView 做 flex spacer: row 受 outer UISV alignment 约束需要撑到一个固定宽度,
    // label(150)+checkbox(24)+spacing(8)=182pt 撑不满 -> 拿这个 spacer 吃掉缝隙,
    // 避免 UISV-spacing / UISV-alignment 冲突。trailing:nil 会报 layout constraint 冲突。
    UIView *featuresSpacer = [UIView new];
    UIView *r8 = [self rowLabel:@"显示检测到的特性" control:_showFeaturesCheckbox trailing:featuresSpacer];

    _showOFCheckbox = [self makeCheckbox:@selector(showOFToggled:)];
    UIView *ofSpacer = [UIView new];
    UIView *r9 = [self rowLabel:@"显示光学流量" control:_showOFCheckbox trailing:ofSpacer];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[r1, r2, r3, r4, r5, r6, r7, r8, r9]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor      constraintEqualToAnchor:self.topAnchor      constant:6],
        [stack.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor   constant:-6],
        [stack.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor  constant:6],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
    ]];
}

#pragma mark - 行布局 / 控件构造 helpers

- (UIView *)rowLabel:(NSString *)t control:(UIView *)c trailing:(nullable UIView *)tr {
    UILabel *label = [UILabel new];
    label.text = t; label.font = [UIFont systemFontOfSize:12.0];
    label.textColor = [GFTheme secondaryTextColor];
    NSLayoutConstraint *lw150 = [label.widthAnchor constraintEqualToConstant:150.0];
    lw150.priority = 999;   // 窄列可压缩
    lw150.active = YES;
    NSMutableArray *arr = [NSMutableArray arrayWithObjects:label, c, nil];
    if (tr) [arr addObject:tr];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:arr];
    row.axis = UILayoutConstraintAxisHorizontal; row.spacing = 8.0; row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (UIView *)labeled:(NSString *)t control:(UIView *)c {
    return [self rowLabel:t control:c trailing:nil];
}

- (UIButton *)makeCheckbox:(SEL)action {
    return [GFViewKit makeCheckboxWithTarget:self action:action];
}

/// UIButton + UIMenu 风格的下拉框(iOS 14+)。
- (UIButton *)makeDropdownWithTitles:(NSArray<NSString *> *)titles
                            selected:(NSInteger)selectedIdx
                            onChange:(void(^)(NSInteger))handler {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    btn.titleLabel.font = [UIFont systemFontOfSize:13.0];
    btn.tintColor = [GFTheme textColor];
    [btn setTitleColor:[GFTheme textColor] forState:UIControlStateNormal];
    btn.backgroundColor = [GFTheme secondaryBackgroundColor];
    btn.layer.cornerRadius = 4.0;
    btn.contentEdgeInsets = UIEdgeInsetsMake(4, 8, 4, 8);
    [btn setTitle:[NSString stringWithFormat:@"%@  ▾", titles[selectedIdx]] forState:UIControlStateNormal];

    if (@available(iOS 14.0, *)) {
        NSMutableArray<UIAction *> *actions = [NSMutableArray array];
        for (NSInteger i = 0; i < titles.count; i++) {
            NSString *t = titles[i];
            NSInteger capI = i;
            UIAction *a = [UIAction actionWithTitle:t image:nil identifier:nil handler:^(UIAction * _Nonnull act) {
                if (handler) handler(capI);
                [btn setTitle:[NSString stringWithFormat:@"%@  ▾", t] forState:UIControlStateNormal];
                // 更新菜单打勾位置:直接 mutate 现有 UIAction 的 state(UIAction.state 可写)
                for (UIMenuElement *e in btn.menu.children) {
                    if ([e isKindOfClass:[UIAction class]]) {
                        UIAction *aa = (UIAction *)e;
                        aa.state = ([aa.title isEqualToString:t]) ? UIMenuElementStateOn : UIMenuElementStateOff;
                    }
                }
            }];
            if (i == selectedIdx) a.state = UIMenuElementStateOn;
            [actions addObject:a];
        }
        btn.menu = [UIMenu menuWithChildren:actions];
        btn.showsMenuAsPrimaryAction = YES;
    }
    [btn.widthAnchor  constraintGreaterThanOrEqualToConstant:140.0].active = YES;
    return btn;
}

- (UITextField *)makeTextField:(UIKeyboardType)keyboard {
    UITextField *tf = [UITextField new];
    tf.borderStyle = UITextBorderStyleRoundedRect;
    tf.font = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightRegular];
    tf.textColor = [GFTheme textColor];
    tf.backgroundColor = [GFTheme secondaryBackgroundColor];
    tf.textAlignment = NSTextAlignmentRight;
    tf.keyboardType = keyboard;
    tf.returnKeyType = UIReturnKeyDone;
    tf.delegate = self;
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    NSLayoutConstraint *tfw = [tf.widthAnchor constraintEqualToConstant:90.0];
    tfw.priority = 999;   // 窄列可压缩
    tfw.active = YES;

    UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 40)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:tf action:@selector(resignFirstResponder)];
    toolbar.items = @[flex, done];
    tf.inputAccessoryView = toolbar;
    return tf;
}

- (UIView *)inputRow:(NSString *)labelText textField:(UITextField *)tf unit:(NSString *)unit {
    UILabel *label = [UILabel new];
    label.text = labelText;
    label.font = [UIFont systemFontOfSize:12.0];
    label.textColor = [GFTheme secondaryTextColor];
    NSLayoutConstraint *lw150 = [label.widthAnchor constraintEqualToConstant:150.0];
    lw150.priority = 999;   // 窄列可压缩
    lw150.active = YES;

    UILabel *unitLabel = [UILabel new];
    unitLabel.text = unit;
    unitLabel.font = [UIFont systemFontOfSize:12.0];
    unitLabel.textColor = [GFTheme secondaryTextColor];
    [unitLabel.widthAnchor constraintEqualToConstant:30.0].active = YES;

    UIView *spacer = [UIView new];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, spacer, tf, unitLabel]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 6.0;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

/// 「label + checkbox + textField + unit」行(用于低通滤波器:勾选了才启用 Hz 输入)
- (UIView *)inputRowWithCheckbox:(NSString *)labelText
                        checkbox:(UIButton *)checkbox
                       textField:(UITextField *)tf
                            unit:(NSString *)unit {
    UILabel *label = [UILabel new];
    label.text = labelText;
    label.font = [UIFont systemFontOfSize:12.0];
    label.textColor = [GFTheme secondaryTextColor];
    NSLayoutConstraint *lw120 = [label.widthAnchor constraintEqualToConstant:120.0];
    lw120.priority = 999;   // 窄列可压缩
    lw120.active = YES;

    UILabel *unitLabel = [UILabel new];
    unitLabel.text = unit;
    unitLabel.font = [UIFont systemFontOfSize:12.0];
    unitLabel.textColor = [GFTheme secondaryTextColor];
    [unitLabel.widthAnchor constraintEqualToConstant:30.0].active = YES;

    UIView *spacer = [UIView new];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[checkbox, label, spacer, tf, unitLabel]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 6.0;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

/// 低通滤波器专用行: checkbox + label + spacer + 外部传入的 tf + 外部传入的 unitLabel。
/// 单独写这个方法的原因: 上面 inputRowWithCheckbox 把 unitLabel 内部 new,没法外部
/// 拿到引用来显隐。低通滤波器要在 checkbox 切换时一起显隐 tf 和 unitLabel,所以
/// 接收外部已构造好的 unitLabel(让 caller 持有引用)。
- (UIView *)lpfRowWithCheckbox:(UIButton *)checkbox
                          label:(NSString *)labelText
                      textField:(UITextField *)tf
                      unitLabel:(UILabel *)unitLabel {
    UILabel *label = [UILabel new];
    label.text = labelText;
    label.font = [UIFont systemFontOfSize:12.0];
    label.textColor = [GFTheme secondaryTextColor];
    NSLayoutConstraint *lw120 = [label.widthAnchor constraintEqualToConstant:120.0];
    lw120.priority = 999;   // 窄列可压缩
    lw120.active = YES;

    UIView *spacer = [UIView new];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[checkbox, label, spacer, tf, unitLabel]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 6.0;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

#pragma mark - Model 绑定 & 刷新

- (void)setModel:(ParamsModel *)model {
    _model = model;
    [self refreshFromModel];
}

- (void)refreshFromModel {
    if (self.model == nil) return;
    self.everyNthTF.text = [NSString stringWithFormat:@"%d", self.model.everyNthFrame];
    self.perPointTF.text = [NSString stringWithFormat:@"%.2f", self.model.timePerSyncpointSec];

    // 4 个下拉框同步 button title + UIMenu 勾选位置(setDropdown 内部两件都做)
    [self setDropdown:self.resDropdown    titles:self.resTitles    selectedIdx:[self resIndexForHeight:self.model.syncProcessingHeight] onChange:nil];

    NSInteger ofIdx     = MAX(0, MIN((NSInteger)self.ofTitles.count - 1,     self.model.ofMethod));
    NSInteger poseIdx   = MAX(0, MIN((NSInteger)self.poseTitles.count - 1,   self.model.poseMethod));
    NSInteger offsetIdx = MAX(0, MIN((NSInteger)self.offsetTitles.count - 1, self.model.offsetMethod));
    [self setDropdown:self.ofDropdown     titles:self.ofTitles     selectedIdx:ofIdx     onChange:nil];
    [self setDropdown:self.poseDropdown   titles:self.poseTitles   selectedIdx:poseIdx   onChange:nil];
    [self setDropdown:self.offsetDropdown titles:self.offsetTitles selectedIdx:offsetIdx onChange:nil];

    BOOL lpfOn = self.model.imuLpfHz > 0.0;
    self.lpfCheckbox.selected = lpfOn;
    self.lpfTF.hidden       = !lpfOn;  // 未勾选 → 不显示输入框
    self.lpfUnitLabel.hidden = !lpfOn;  // 单位标签 Hz 也跟着隐
    self.lpfTF.text = [NSString stringWithFormat:@"%.0f", lpfOn ? self.model.imuLpfHz : 50.0];

    self.showFeaturesCheckbox.selected = self.model.showDetectedFeatures;
    self.showOFCheckbox.selected       = self.model.showOpticalFlow;
}

- (NSInteger)resIndexForHeight:(int)h {
    for (NSInteger i = 0; i < self.resValues.count; i++) {
        if (self.resValues[i].intValue == h) return i;
    }
    return 0; // 找不到 → 原生
}

- (void)setDropdown:(UIButton *)btn titles:(NSArray<NSString *> *)titles selectedIdx:(NSInteger)idx onChange:(void(^)(NSInteger))h {
    [btn setTitle:[NSString stringWithFormat:@"%@  ▾", titles[idx]] forState:UIControlStateNormal];
    // 同步 UIMenu 里 UIAction 的勾选状态 —— 没这步外部 setModel 改了 idx,
    // 按钮文字对了,但下拉打开菜单里的勾还在初始位置(典型 bug 表现:
    // 按钮显示 720p,菜单里却勾着「原始」)
    if (@available(iOS 14.0, *)) {
        if (btn.menu == nil) return;
        NSInteger i = 0;
        for (UIMenuElement *e in btn.menu.children) {
            if ([e isKindOfClass:[UIAction class]]) {
                UIAction *a = (UIAction *)e;
                a.state = (i == idx) ? UIMenuElementStateOn : UIMenuElementStateOff;
                i++;
            }
        }
    }
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    double v = [textField.text doubleValue];
    if (textField == self.everyNthTF) {
        // 官方 from:1 无上限。给 1–100 兜底
        int iv = (int)round(v);
        if (iv < 1) iv = 1;
        else if (iv > 100) iv = 100;
        textField.text = [NSString stringWithFormat:@"%d", iv];
        self.model.everyNthFrame = iv;
    } else if (textField == self.perPointTF) {
        // 官方默认 1.5s，from:0.01 无上限。给 0.01–10 兜底
        if (v < 0.01) v = 0.01;
        else if (v > 10.0) v = 10.0;
        textField.text = [NSString stringWithFormat:@"%.2f", v];
        self.model.timePerSyncpointSec = v;
    } else if (textField == self.lpfTF) {
        // 官方默认 0（关闭），from:0 无上限。给 0–500Hz 兜底
        if (v < 0.0) v = 0.0;
        else if (v > 500.0) v = 500.0;
        textField.text = [NSString stringWithFormat:@"%.0f", v];
        // 只有当 checkbox 勾选才推到 Model
        if (self.lpfCheckbox.selected) self.model.imuLpfHz = v;
    }
}

#pragma mark - checkbox actions

- (void)lpfToggled:(UIButton *)sender {
    sender.selected = !sender.selected;
    self.lpfTF.hidden       = !sender.selected;  // 未勾选 → 不显示输入框
    self.lpfUnitLabel.hidden = !sender.selected;  // 单位标签 Hz 也跟着隐
    if (sender.selected) {
        double v = [self.lpfTF.text doubleValue];
        if (v < 1.0) v = 50.0;
        self.lpfTF.text = [NSString stringWithFormat:@"%.0f", v];
        self.model.imuLpfHz = v;
    } else {
        self.model.imuLpfHz = 0.0;
    }
}

- (void)showFeaturesToggled:(UIButton *)sender {
    sender.selected = !sender.selected;
    self.model.showDetectedFeatures = sender.selected;
}

- (void)showOFToggled:(UIButton *)sender {
    sender.selected = !sender.selected;
    self.model.showOpticalFlow = sender.selected;
}

@end
