#import "AdvancedSectionView.h"
#import "GFTheme.h"
#import "GFViewKit.h"

@interface AdvancedSectionView () <UITextFieldDelegate>
// 预览分辨率: MDK 解码源像素数, **不影响 output_size**。对齐桌面"高级选项·预览分辨率"。
// 注: 输出大小已迁移到 ExportSectionView(导出设置)。
@property (nonatomic, strong) UIButton    *previewResDropdown;
@property (nonatomic, strong) UIView      *colorSwatch;
@property (nonatomic, strong) UITextField *hexField;        // 渲染背景: 6 位 HEX 输入
@property (nonatomic, strong) UIButton    *bgModeDropdown;  // 背景填充模式
@property (nonatomic, strong) UIButton    *safeAreaCheckbox;
@end

@implementation AdvancedSectionView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [GFTheme secondaryBackgroundColor];
        self.layer.cornerRadius = 6.0;

        UILabel *title = [UILabel new];
        title.text = @"高级";
        title.font = [UIFont boldSystemFontOfSize:14.0];
        title.textColor = [GFTheme textColor];

        // 预览分辨率 dropdown (真·MDK 解码源, 跟 output_size 无关)
        _previewResDropdown = [self makePreviewResDropdown];
        UIView *rPrev = [self labeled:@"预览分辨率" control:_previewResDropdown];

        // 渲染背景: 色块 + 固定 "#" 前缀 + 6 位 HEX 输入框
        // (用 HEX 直填, 绕开 UIColorPicker 对灰度/P3 取色 getRed 失败的坑)。
        _colorSwatch = [UIView new];
        _colorSwatch.backgroundColor = UIColor.blackColor;
        _colorSwatch.layer.borderColor = [UIColor whiteColor].CGColor;
        _colorSwatch.layer.borderWidth = 1.0;
        [_colorSwatch.widthAnchor  constraintEqualToConstant:24.0].active = YES;
        [_colorSwatch.heightAnchor constraintEqualToConstant:24.0].active = YES;

        UILabel *hashLabel = [UILabel new];
        hashLabel.text = @"#";
        hashLabel.font = [UIFont systemFontOfSize:14.0];
        hashLabel.textColor = [GFTheme textColor];
        [hashLabel.widthAnchor  constraintEqualToConstant:16.0].active = YES;

        _hexField = [UITextField new];
        _hexField.delegate = self;
        _hexField.font = [UIFont monospacedSystemFontOfSize:14.0 weight:UIFontWeightRegular];
        _hexField.textColor = [GFTheme textColor];
        _hexField.backgroundColor = [GFTheme backgroundColor];
        _hexField.borderStyle = UITextBorderStyleRoundedRect;
        _hexField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        _hexField.autocorrectionType = UITextAutocorrectionTypeNo;
        _hexField.keyboardType = UIKeyboardTypeASCIICapable;
        _hexField.clearButtonMode = UITextFieldViewModeNever;
        [_hexField addTarget:self action:@selector(hexEditingChanged) forControlEvents:UIControlEventEditingChanged];
        [_hexField addTarget:self action:@selector(hexEditingEnded)   forControlEvents:UIControlEventEditingDidEnd];
        [_hexField.widthAnchor constraintEqualToConstant:88.0].active = YES;

        // "#" 与输入框紧挨: 用 2pt 子栈包一起; 色块与它们之间保留间距。
        UIStackView *hexGroup = [[UIStackView alloc] initWithArrangedSubviews:@[hashLabel, _hexField]];
        hexGroup.axis = UILayoutConstraintAxisHorizontal;
        hexGroup.alignment = UIStackViewAlignmentCenter;

        // 色块靠左、HEX 组靠右: 中间塞一个可伸缩 spacer 把 hexGroup 顶到右端。
        UIView *colorSpacer = [UIView new];
        [colorSpacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [colorSpacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

        UIStackView *colorRow = [[UIStackView alloc] initWithArrangedSubviews:@[_colorSwatch, colorSpacer, hexGroup]];
        colorRow.axis = UILayoutConstraintAxisHorizontal;
        colorRow.spacing = 8.0;
        colorRow.alignment = UIStackViewAlignmentCenter;
        UIView *rBg = [self labeled:@"渲染背景" control:colorRow];

        // 背景填充模式 dropdown (0 纯色 / 1 边缘拉伸 / 2 边缘镜像 / 3 羽化留边)
        _bgModeDropdown = [self makeBgModeDropdown];
        UIView *rBgMode = [self labeled:@"背景模式" control:_bgModeDropdown];

        _safeAreaCheckbox = [GFViewKit makeCheckboxWithTarget:self action:@selector(safeAreaToggled:)];
        // 复选框固定 24 宽, 直接放进 labeled: 会被布局拉到最右。包一个尾部 spacer,
        // 让复选框停在控件区左侧, 和"渲染背景/预览分辨率"等行的控件左边对齐。
        UIView *safeSpacer = [UIView new];
        UIStackView *safeWrap = [[UIStackView alloc] initWithArrangedSubviews:@[_safeAreaCheckbox, safeSpacer]];
        safeWrap.axis = UILayoutConstraintAxisHorizontal;
        safeWrap.alignment = UIStackViewAlignmentCenter;
        UIView *rSafe = [self labeled:@"安全区域指示" control:safeWrap];

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, rPrev, rBg, rBgMode, rSafe]];
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

- (UIButton *)makePreviewResDropdown {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    btn.titleLabel.font = [UIFont systemFontOfSize:13.0];
    [btn setTitleColor:[GFTheme textColor] forState:UIControlStateNormal];
    btn.backgroundColor = [GFTheme backgroundColor];
    btn.layer.cornerRadius = 4.0;
    btn.contentEdgeInsets = UIEdgeInsetsMake(6, 8, 6, 8);
    [btn.heightAnchor constraintEqualToConstant:32.0].active = YES;

    NSArray<NSString *> *titles = @[@"视频原生", @"1080p", @"720p", @"480p"];
    NSArray<NSNumber *> *heights = @[@0, @1080, @720, @480];
    NSInteger defaultIdx = 0;
    [btn setTitle:[NSString stringWithFormat:@"%@  ▾", titles[defaultIdx]] forState:UIControlStateNormal];

    if (@available(iOS 14.0, *)) {
        __weak typeof(self) weakSelf = self;
        __weak UIButton *weakBtn = btn;
        NSMutableArray<UIAction *> *actions = [NSMutableArray array];
        for (NSInteger i = 0; i < titles.count; i++) {
            NSString *t = titles[i];
            NSInteger capH = heights[i].integerValue;
            UIAction *a = [UIAction actionWithTitle:t image:nil identifier:nil handler:^(UIAction * _Nonnull act) {
                [weakBtn setTitle:[NSString stringWithFormat:@"%@  ▾", t] forState:UIControlStateNormal];
                for (UIMenuElement *e in weakBtn.menu.children) {
                    if ([e isKindOfClass:[UIAction class]]) {
                        UIAction *aa = (UIAction *)e;
                        aa.state = [aa.title isEqualToString:t] ? UIMenuElementStateOn : UIMenuElementStateOff;
                    }
                }
                weakSelf.model.previewResolutionHeight = (int)capH;
            }];
            if (i == defaultIdx) {
                a.state = UIMenuElementStateOn;
            }
            [actions addObject:a];
        }
        btn.menu = [UIMenu menuWithChildren:actions];
        btn.showsMenuAsPrimaryAction = YES;
    }
    return btn;
}

- (UIView *)labeled:(NSString *)t control:(UIView *)c {
    UILabel *label = [UILabel new];
    label.text = t;
    label.font = [UIFont systemFontOfSize:12.0];
    label.textColor = [GFTheme secondaryTextColor];
    NSLayoutConstraint *lw = [label.widthAnchor constraintEqualToConstant:130.0];
    lw.priority = 999;   // 窄列可压缩, 避免约束冲突
    lw.active = YES;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, c]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8.0;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (void)setModel:(ParamsModel *)model {
    _model = model;
    if (model == nil) return;
    [self syncPreviewDropdownFromModel];
    [self syncHexFromModel];
    [self syncBgModeFromModel];
    self.safeAreaCheckbox.selected = model.showSafeArea;
}

// recompute 后 previewResolutionHeight 可能被外部改动 (镜头档案加载),
// 刷新一下下拉显示, 不让 UI 跟 Model 漂移。
- (void)refreshReadOnly {
    [self syncPreviewDropdownFromModel];
    [self syncHexFromModel];
    [self syncBgModeFromModel];
}

- (void)syncPreviewDropdownFromModel {
    if (self.model == nil) return;
    if (@available(iOS 14.0, *)) {
        int h = self.model.previewResolutionHeight;
        NSString *want = (h <= 0) ? @"视频原生"
                                 : [NSString stringWithFormat:@"%dp", h];
        [self.previewResDropdown setTitle:[NSString stringWithFormat:@"%@  ▾", want]
                                  forState:UIControlStateNormal];
        for (UIMenuElement *e in self.previewResDropdown.menu.children) {
            if ([e isKindOfClass:[UIAction class]]) {
                UIAction *aa = (UIAction *)e;
                aa.state = [aa.title isEqualToString:want] ? UIMenuElementStateOn : UIMenuElementStateOff;
            }
        }
    }
}

#pragma mark - 渲染背景 HEX 输入

// 把 model 的 bgR/G/B 显示成 6 位大写 HEX, 同步输入框 + 色块。
- (void)syncHexFromModel {
    if (self.model == nil) return;
    int r = [self clamp255:(int)lround(self.model.bgR * 255.0)];
    int g = [self clamp255:(int)lround(self.model.bgG * 255.0)];
    int b = [self clamp255:(int)lround(self.model.bgB * 255.0)];
    self.hexField.text = [NSString stringWithFormat:@"%02X%02X%02X", r, g, b];
    self.colorSwatch.backgroundColor = [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1.0];
}

- (int)clamp255:(int)v {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return v;
}

// 输入满 6 位即实时应用; 不足 6 位先不动 model, 等失焦兜底。
- (void)hexEditingChanged {
    if (self.hexField.text.length == 6) {
        [self applyHex:self.hexField.text];
    }
}

// 失焦: 6 位则应用, 否则用 model 现值回填, 避免残缺串。
- (void)hexEditingEnded {
    if (self.hexField.text.length == 6) {
        [self applyHex:self.hexField.text];
    } else {
        [self syncHexFromModel];
    }
}

- (void)applyHex:(NSString *)hex {
    unsigned int val = 0;
    NSScanner *sc = [NSScanner scannerWithString:hex];
    if (![sc scanHexInt:&val]) {
        return;
    }
    double r = ((val >> 16) & 0xFF) / 255.0;
    double g = ((val >> 8)  & 0xFF) / 255.0;
    double b = ( val        & 0xFF) / 255.0;
    self.model.bgR = r;
    self.model.bgG = g;
    self.model.bgB = b;
    self.model.bgA = 1.0;
    self.colorSwatch.backgroundColor = [UIColor colorWithRed:r green:g blue:b alpha:1.0];
}

// 只允许 0-9 a-f A-F, 且总长度 ≤ 6。
- (BOOL)textField:(UITextField *)textField
        shouldChangeCharactersInRange:(NSRange)range
        replacementString:(NSString *)string {
    if (textField != self.hexField) {
        return YES;
    }
    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    for (NSUInteger i = 0; i < string.length; i++) {
        if (![hexSet characterIsMember:[string characterAtIndex:i]]) {
            return NO;
        }
    }
    NSString *next = [textField.text stringByReplacingCharactersInRange:range withString:string];
    return next.length <= 6;
}

#pragma mark - 背景模式

- (UIButton *)makeBgModeDropdown {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    btn.titleLabel.font = [UIFont systemFontOfSize:13.0];
    [btn setTitleColor:[GFTheme textColor] forState:UIControlStateNormal];
    btn.backgroundColor = [GFTheme backgroundColor];
    btn.layer.cornerRadius = 4.0;
    btn.contentEdgeInsets = UIEdgeInsetsMake(6, 8, 6, 8);
    [btn.heightAnchor constraintEqualToConstant:32.0].active = YES;

    NSArray<NSString *> *titles = @[@"纯色", @"边缘拉伸", @"边缘镜像", @"羽化留边"];
    [btn setTitle:[NSString stringWithFormat:@"%@  ▾", titles[0]] forState:UIControlStateNormal];

    if (@available(iOS 14.0, *)) {
        __weak typeof(self) weakSelf = self;
        __weak UIButton *weakBtn = btn;
        NSMutableArray<UIAction *> *actions = [NSMutableArray array];
        for (NSInteger i = 0; i < titles.count; i++) {
            NSString *t = titles[i];
            NSInteger mode = i;
            UIAction *a = [UIAction actionWithTitle:t image:nil identifier:nil handler:^(UIAction * _Nonnull act) {
                [weakBtn setTitle:[NSString stringWithFormat:@"%@  ▾", t] forState:UIControlStateNormal];
                for (UIMenuElement *e in weakBtn.menu.children) {
                    if ([e isKindOfClass:[UIAction class]]) {
                        UIAction *aa = (UIAction *)e;
                        aa.state = [aa.title isEqualToString:t] ? UIMenuElementStateOn : UIMenuElementStateOff;
                    }
                }
                weakSelf.model.backgroundMode = (int)mode;
            }];
            if (i == 0) {
                a.state = UIMenuElementStateOn;
            }
            [actions addObject:a];
        }
        btn.menu = [UIMenu menuWithChildren:actions];
        btn.showsMenuAsPrimaryAction = YES;
    }
    return btn;
}

- (void)syncBgModeFromModel {
    if (self.model == nil) return;
    if (@available(iOS 14.0, *)) {
        NSArray<NSString *> *titles = @[@"纯色", @"边缘拉伸", @"边缘镜像", @"羽化留边"];
        int m = self.model.backgroundMode;
        if (m < 0 || m >= (int)titles.count) {
            m = 0;
        }
        NSString *want = titles[m];
        [self.bgModeDropdown setTitle:[NSString stringWithFormat:@"%@  ▾", want] forState:UIControlStateNormal];
        for (UIMenuElement *e in self.bgModeDropdown.menu.children) {
            if ([e isKindOfClass:[UIAction class]]) {
                UIAction *aa = (UIAction *)e;
                aa.state = [aa.title isEqualToString:want] ? UIMenuElementStateOn : UIMenuElementStateOff;
            }
        }
    }
}

- (void)safeAreaToggled:(UIButton *)sender {
    sender.selected = !sender.selected;
    self.model.showSafeArea = sender.selected;
}

@end
