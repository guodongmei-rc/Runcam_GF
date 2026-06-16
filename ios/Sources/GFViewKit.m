#import "GFViewKit.h"
#import "GFTheme.h"
#import <objc/runtime.h>

#pragma mark - slider <-> 数值输入框 双向绑定

// field 编辑结束: 解析显示值 / scale -> 夹到 slider 范围 -> 设回 slider ->
// 触发 slider 既有 valueChanged actions(既有 handler 会写回 model + 重新格式化 field)。
// 这样不用重写每个 slider 的 valueChanged 逻辑。绑定对象用 associated object 保活。
@interface GFFieldSliderBinding : NSObject <UITextFieldDelegate>
@property (nonatomic, weak) UISlider    *slider;
@property (nonatomic, weak) UITextField *field;
@property (nonatomic, assign) double     scale;
@end
@implementation GFFieldSliderBinding
// 获得焦点: 把带单位/正号的显示文本(如 "+5.0°") 换成可编辑的裸数字(如 "5"),
// 否则单位字符会让输入校验把所有按键都判为非法 -> 看起来"无法输入"。
- (void)fieldBeganEditing {
    if (self.slider == nil || self.field == nil) {
        return;
    }
    double s = (self.scale == 0.0) ? 1.0 : self.scale;
    double disp = self.slider.value * s;
    NSString *t = [NSString stringWithFormat:@"%.4f", disp];
    if ([t containsString:@"."]) {
        while ([t hasSuffix:@"0"]) {
            t = [t substringToIndex:t.length - 1];
        }
        if ([t hasSuffix:@"."]) {
            t = [t substringToIndex:t.length - 1];
        }
    }
    self.field.text = t;
    // 光标移到文字最右端 (异步, 避免被 UIKit 默认放置覆盖)
    UITextField *f = self.field;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITextPosition *end = f.endOfDocument;
        f.selectedTextRange = [f textRangeFromPosition:end toPosition:end];
    });
}
// 键盘右下角完成/return 键: 收键盘 -> 触发 editingDidEnd -> 提交 (等同工具条完成)。
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}
- (void)fieldEdited {
    if (self.slider == nil || self.field == nil) {
        return;
    }
    double s = (self.scale == 0.0) ? 1.0 : self.scale;
    double v = [self.field.text doubleValue] / s;
    double lo = self.slider.minimumValue;
    double hi = self.slider.maximumValue;
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    self.slider.value = (float)v;
    [self.slider sendActionsForControlEvents:UIControlEventValueChanged];
}
// 输入校验: 只允许数字 + 最多一个小数点; slider 范围含负数时才允许前导负号。
- (BOOL)textField:(UITextField *)textField
        shouldChangeCharactersInRange:(NSRange)range
        replacementString:(NSString *)string {
    if (string.length == 0) {
        return YES;   // 删除总是允许
    }
    NSString *result = [textField.text stringByReplacingCharactersInRange:range withString:string];
    BOOL allowNeg = (self.slider.minimumValue < 0.0f);
    NSString *pattern = allowNeg ? @"^-?[0-9]*\\.?[0-9]*$" : @"^[0-9]*\\.?[0-9]*$";
    return [result rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}
@end

static const void *kGFFieldBindingKey = &kGFFieldBindingKey;

@implementation GFViewKit

+ (void)toast:(NSString *)message inView:(UIView *)view {
    if (message.length == 0 || view == nil) {
        return;
    }
    UIView *host = view.window ?: view;
    UIView *box = [UIView new];
    box.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.85];
    box.layer.cornerRadius = 8.0;
    box.layer.masksToBounds = YES;
    box.alpha = 0.0;
    box.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *label = [UILabel new];
    label.text = message;
    label.font = [UIFont systemFontOfSize:13.0];
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:label];
    [host addSubview:box];

    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor      constraintEqualToAnchor:box.topAnchor      constant:8],
        [label.bottomAnchor   constraintEqualToAnchor:box.bottomAnchor   constant:-8],
        [label.leadingAnchor  constraintEqualToAnchor:box.leadingAnchor  constant:14],
        [label.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-14],
        [box.centerXAnchor    constraintEqualToAnchor:host.centerXAnchor],
        [box.centerYAnchor    constraintEqualToAnchor:host.centerYAnchor],
        [box.leadingAnchor    constraintGreaterThanOrEqualToAnchor:host.leadingAnchor  constant:24],
        [box.trailingAnchor   constraintLessThanOrEqualToAnchor:host.trailingAnchor constant:-24],
    ]];

    [UIView animateWithDuration:0.2 animations:^{
        box.alpha = 1.0;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.3 delay:1.4 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            box.alpha = 0.0;
        } completion:^(BOOL done) {
            [box removeFromSuperview];
        }];
    }];
}

+ (UIProgressView *)themedProgressView {
    UIProgressView *p = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    p.translatesAutoresizingMaskIntoConstraints = NO;
    p.hidden = YES;
    p.progressTintColor = [GFTheme primaryColor];
    p.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    return p;
}

+ (UIView *)firstResponderIn:(UIView *)view {
    if (view.isFirstResponder) {
        return view;
    }
    for (UIView *sub in view.subviews) {
        UIView *r = [self firstResponderIn:sub];
        if (r != nil) {
            return r;
        }
    }
    return nil;
}

+ (NSString *)formatTimeMmSs:(double)seconds {
    if (seconds < 0.0 || isnan(seconds) || isinf(seconds)) {
        return @"--:--";
    }
    NSInteger total = (NSInteger)floor(seconds);
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)];
}

+ (void)showModalOverView:(UIView *)view
                  message:(NSString *)message
                  success:(BOOL)success
         dontShowAgainKey:(NSString *)key {
    [self showModalOverView:view message:message success:success dontShowAgainKey:key onConfirm:nil];
}

+ (void)showModalOverView:(UIView *)view
                  message:(NSString *)message
                  success:(BOOL)success
         dontShowAgainKey:(NSString *)key
                onConfirm:(void (^)(void))onConfirm {
    if (view == nil || message.length == 0) {
        if (onConfirm) onConfirm();
        return;
    }
    // 已勾「不再显示」: 不弹, 但仍同步触发 onConfirm(后续动作不能被静默丢弃)。
    if (key != nil && [NSUserDefaults.standardUserDefaults boolForKey:key]) {
        if (onConfirm) onConfirm();
        return;
    }
    // 挂 window 层而非传入 view: 调用方的蒙版(导出/同步)随后 bringSubviewToFront
    // 会盖住同层弹框; window 层永远在最前。
    UIView *host = view.window ?: view;
    UIView *overlay = [[UIView alloc] initWithFrame:host.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];

    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1.0];
    card.layer.cornerRadius = 12.0;
    [overlay addSubview:card];

    UIImageView *icon = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:(success ? @"checkmark.circle" : @"info.circle")
                withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:34 weight:UIImageSymbolWeightLight]]];
    icon.tintColor = success ? [UIColor systemGreenColor] : [UIColor systemBlueColor];
    icon.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *label = [UILabel new];
    label.text = message;
    label.font = [UIFont systemFontOfSize:14.0];
    label.textColor = UIColor.whiteColor;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *ok = [UIButton buttonWithType:UIButtonTypeSystem];
    [ok setTitle:@"确定" forState:UIControlStateNormal];
    [ok setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    ok.titleLabel.font = [UIFont systemFontOfSize:14.0];
    ok.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
    ok.layer.cornerRadius = 6.0;
    ok.contentEdgeInsets = UIEdgeInsetsMake(8, 28, 8, 28);
    ok.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *check = [UIButton buttonWithType:UIButtonTypeSystem];
    [check setImage:[UIImage systemImageNamed:@"square"] forState:UIControlStateNormal];
    [check setImage:[UIImage systemImageNamed:@"checkmark.square"] forState:UIControlStateSelected];
    [check setTitle:@" 不再显示" forState:UIControlStateNormal];
    [check setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    check.tintColor = UIColor.whiteColor;
    check.titleLabel.font = [UIFont systemFontOfSize:13.0];
    check.translatesAutoresizingMaskIntoConstraints = NO;
    check.hidden = (key == nil);
    __weak UIButton *weakCheck = check;
    [check addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
        weakCheck.selected = !weakCheck.selected;
    }] forControlEvents:UIControlEventTouchUpInside];

    [ok addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
        if (key != nil && weakCheck.selected) {
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:key];
        }
        [overlay removeFromSuperview];
        if (onConfirm) onConfirm();
    }] forControlEvents:UIControlEventTouchUpInside];

    [card addSubview:icon];
    [card addSubview:label];
    [card addSubview:ok];
    [card addSubview:check];
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [card.widthAnchor   constraintLessThanOrEqualToConstant:340.0],
        [card.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:24.0],
        [card.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-24.0],
        [icon.topAnchor     constraintEqualToAnchor:card.topAnchor constant:20.0],
        [icon.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [label.topAnchor      constraintEqualToAnchor:icon.bottomAnchor constant:14.0],
        [label.leadingAnchor  constraintEqualToAnchor:card.leadingAnchor constant:20.0],
        [label.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20.0],
        [ok.topAnchor       constraintEqualToAnchor:label.bottomAnchor constant:18.0],
        [ok.centerXAnchor   constraintEqualToAnchor:card.centerXAnchor],
    ]];
    // 底边: 有「不再显示」行时由勾选收底, 无(key=nil)时由「确定」按钮收底(不留空档)
    if (key != nil) {
        [NSLayoutConstraint activateConstraints:@[
            [check.topAnchor     constraintEqualToAnchor:ok.bottomAnchor constant:12.0],
            [check.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
            [check.bottomAnchor  constraintEqualToAnchor:card.bottomAnchor constant:-14.0],
        ]];
    } else {
        [ok.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16.0].active = YES;
    }
    [host addSubview:overlay];
}

+ (void)makeField:(UITextField *)field editSlider:(UISlider *)slider scale:(double)scale {
    if (field == nil || slider == nil) {
        return;
    }
    GFFieldSliderBinding *b = [GFFieldSliderBinding new];
    b.slider = slider;
    b.field = field;
    b.scale = scale;
    objc_setAssociatedObject(field, kGFFieldBindingKey, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [field addTarget:b action:@selector(fieldBeganEditing) forControlEvents:UIControlEventEditingDidBegin];
    [field addTarget:b action:@selector(fieldEdited) forControlEvents:UIControlEventEditingDidEnd];
    field.delegate = b;   // 输入校验(只允许合法数字)
    // 负值范围用带负号的键盘(NumbersAndPunctuation 有 "-"); 正值用 DecimalPad。
    field.keyboardType = (slider.minimumValue < 0.0f)
        ? UIKeyboardTypeNumbersAndPunctuation
        : UIKeyboardTypeDecimalPad;
}

+ (UIButton *)primaryButtonWithTitle:(NSString *)title {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.4] forState:UIControlStateDisabled];
    btn.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    btn.backgroundColor = [GFTheme primaryColor];
    btn.layer.cornerRadius = 10.0;
    btn.clipsToBounds = YES;
    btn.contentEdgeInsets = UIEdgeInsetsMake(10.0, 16.0, 10.0, 16.0);
    return btn;
}

+ (UIImage *)checkboxImageChecked:(BOOL)checked {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightRegular];
    NSString *sym = checked ? @"checkmark.square" : @"square";
    return [UIImage systemImageNamed:sym withConfiguration:cfg];
}

+ (UIButton *)makeCheckbox {
    return [self makeCheckboxWithTarget:nil action:nil];
}

+ (UIButton *)makeCheckboxWithTarget:(id)target action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [btn setImage:[self checkboxImageChecked:NO]  forState:UIControlStateNormal];
    [btn setImage:[self checkboxImageChecked:YES] forState:UIControlStateSelected];
    [btn setImage:[self checkboxImageChecked:YES] forState:UIControlStateSelected | UIControlStateHighlighted];
    btn.tintColor = [GFTheme primaryColor]; // 白色：未选/选中同色，只靠中间的对勾区分
    [btn.widthAnchor  constraintEqualToConstant:24.0].active = YES;
    [btn.heightAnchor constraintEqualToConstant:24.0].active = YES;
    if (target != nil && action != NULL) {
        [btn addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    }
    return btn;
}

+ (void)applyToSlider:(UISlider *)slider {
    if (slider == nil) return;
    slider.minimumTrackTintColor = [GFTheme primaryColor];
    slider.maximumTrackTintColor = [GFTheme backgroundColor];
}

+ (void)applyToSwitch:(UISwitch *)sw {
    if (sw == nil) return;
    sw.onTintColor = [GFTheme primaryColor];
}

+ (void)applyToLabel:(UILabel *)label primary:(BOOL)isPrimary {
    if (label == nil) return;
    label.textColor = isPrimary ? [GFTheme textColor] : [GFTheme secondaryTextColor];
}

#pragma mark - Row helpers

static const CGFloat kGFRowLabelWidth = 130.0;
static const CGFloat kGFValueLabelWidth = 60.0;

// 私有 helper:统一构造行标签 (固定宽 + 副文本色 + 12pt)
static UILabel *gf_make_row_label(NSString *title) {
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = [UIFont systemFontOfSize:12.0];
    label.textColor = [GFTheme secondaryTextColor];
    NSLayoutConstraint *gfLabelW = [label.widthAnchor constraintEqualToConstant:kGFRowLabelWidth];
    gfLabelW.priority = 999;  // 窄列(iPad 横屏三栏)放不下时可被打破, 避免约束冲突
    gfLabelW.active = YES;
    return label;
}

// 私有 helper:统一构造一行的 UIStackView (水平 / 居中 / 8pt 间距)
static UIStackView *gf_make_horizontal_row(NSArray<UIView *> *arranged) {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:arranged];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8.0;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

+ (UIStackView *)rowWithLabel:(NSString *)title control:(UIView *)control {
    // 自动加透明 UIView 做尾部 spacer ——
    // outer UISV-alignment 把 row 强制撑到容器宽度, 若只有 label(130)+ctrl(24)+spacing(8)=162pt,
    // 内容撑不满会冲突 (典型: checkbox / 系统 UISwitch / dropdown 行)。
    // 让 spacer 吃掉剩余宽度避免约束打架。
    UIView *spacer = [UIView new];
    return [self rowWithLabel:title control:control trailing:spacer];
}

+ (UIStackView *)rowWithLabel:(NSString *)title
                      control:(UIView *)control
                     trailing:(nullable UIView *)trailing {
    UILabel *label = gf_make_row_label(title);
    NSMutableArray<UIView *> *arranged = [NSMutableArray arrayWithObjects:label, control, nil];
    if (trailing != nil) {
        [arranged addObject:trailing];
    }
    return gf_make_horizontal_row(arranged);
}

+ (UIButton *)makeDropdownWithTitles:(NSArray<NSString *> *)titles
                            selected:(NSInteger)selectedIdx
                            onChange:(void(^)(NSInteger))onChange {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    btn.titleLabel.font = [UIFont systemFontOfSize:13.0];
    btn.tintColor = [GFTheme textColor];
    [btn setTitleColor:[GFTheme textColor] forState:UIControlStateNormal];
    btn.backgroundColor = [GFTheme secondaryBackgroundColor];
    btn.layer.cornerRadius = 4.0;
    btn.contentEdgeInsets = UIEdgeInsetsMake(4.0, 8.0, 4.0, 8.0);
    NSInteger initIdx = MAX(0, MIN((NSInteger)titles.count - 1, selectedIdx));
    if (titles.count > 0) {
        [btn setTitle:[NSString stringWithFormat:@"%@  ▾", titles[initIdx]] forState:UIControlStateNormal];
    }

    if (@available(iOS 14.0, *)) {
        NSMutableArray<UIAction *> *actions = [NSMutableArray array];
        for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
            NSString *t = titles[i];
            NSInteger capI = i;
            UIAction *a = [UIAction actionWithTitle:t
                                              image:nil
                                         identifier:nil
                                            handler:^(UIAction * _Nonnull act) {
                if (onChange != nil) {
                    onChange(capI);
                }
                [btn setTitle:[NSString stringWithFormat:@"%@  ▾", t] forState:UIControlStateNormal];
                // 更新菜单里 √ 的位置: mutate UIAction.state
                for (UIMenuElement *e in btn.menu.children) {
                    if ([e isKindOfClass:[UIAction class]]) {
                        UIAction *aa = (UIAction *)e;
                        aa.state = ([aa.title isEqualToString:t]) ? UIMenuElementStateOn : UIMenuElementStateOff;
                    }
                }
            }];
            if (i == initIdx) {
                a.state = UIMenuElementStateOn;
            }
            [actions addObject:a];
        }
        btn.menu = [UIMenu menuWithChildren:actions];
        btn.showsMenuAsPrimaryAction = YES;
    }
    [btn.widthAnchor constraintGreaterThanOrEqualToConstant:140.0].active = YES;
    return btn;
}

+ (UIStackView *)sliderRowWithLabel:(NSString *)title
                                min:(float)minVal
                                max:(float)maxVal
                          outSlider:(UISlider *__strong _Nullable *_Nonnull)outSlider
                      outValueLabel:(UILabel *__strong _Nullable *_Nonnull)outValueLabel {
    UILabel *label = gf_make_row_label(title);

    UISlider *slider = [UISlider new];
    slider.minimumValue = minVal;
    slider.maximumValue = maxVal;
    [self applyToSlider:slider];
    *outSlider = slider;

    UILabel *valueLabel = [UILabel new];
    valueLabel.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    valueLabel.textColor = [GFTheme textColor];
    valueLabel.textAlignment = NSTextAlignmentRight;
    NSLayoutConstraint *gfValW = [valueLabel.widthAnchor constraintEqualToConstant:kGFValueLabelWidth];
    gfValW.priority = 999;
    gfValW.active = YES;
    *outValueLabel = valueLabel;

    return gf_make_horizontal_row(@[label, slider, valueLabel]);
}

+ (UIStackView *)sliderRowWithLabel:(NSString *)title
                                min:(float)minVal
                                max:(float)maxVal
                          outSlider:(UISlider *__strong _Nullable *_Nonnull)outSlider
                      outValueField:(UITextField *__strong _Nullable *_Nonnull)outValueField {
    UILabel *label = gf_make_row_label(title);

    UISlider *slider = [UISlider new];
    slider.minimumValue = minVal;
    slider.maximumValue = maxVal;
    [self applyToSlider:slider];
    *outSlider = slider;

    UITextField *field = [UITextField new];
    field.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    field.textColor = [GFTheme textColor];
    field.textAlignment = NSTextAlignmentRight;
    field.keyboardType = UIKeyboardTypeDecimalPad;
    field.returnKeyType = UIReturnKeyDone;
    field.backgroundColor = [GFTheme backgroundColor];
    field.layer.cornerRadius = 4.0;
    field.borderStyle = UITextBorderStyleNone;
    // 右对齐文字贴边 -> 加 4pt 右内边距 (rightView 占位)。
    UIView *rightPad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 4, 1)];
    field.rightView = rightPad;
    field.rightViewMode = UITextFieldViewModeAlways;
    // inputAccessoryView 工具条: 用固定 frame(屏宽 × 44) + autoresizing, 不走 Auto Layout,
    // 也不 sizeToFit —— 否则会和键盘内部布局产生 UIView-Encapsulated-Layout-Height 约束冲突。
    CGFloat barW = UIScreen.mainScreen.bounds.size.width;
    UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, barW, 44)];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    bar.barStyle = UIBarStyleDefault;
    UIBarButtonItem *spacer = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                            target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                          target:field
                                                                          action:@selector(resignFirstResponder)];
    bar.items = @[spacer, done];
    field.inputAccessoryView = bar;
    NSLayoutConstraint *gfFieldW = [field.widthAnchor constraintEqualToConstant:kGFValueLabelWidth];
    gfFieldW.priority = 999;
    gfFieldW.active = YES;
    [field.heightAnchor constraintEqualToConstant:26.0].active = YES;
    *outValueField = field;

    return gf_make_horizontal_row(@[label, slider, field]);
}

+ (void)applyRevealIndent:(UIView *)container {
    if (![container isKindOfClass:[UIStackView class]]) return;
    UIStackView *sv = (UIStackView *)container;
    sv.layoutMarginsRelativeArrangement = YES;
    NSDirectionalEdgeInsets m = sv.directionalLayoutMargins;
    m.leading += 12.0;   // 勾选展开内容统一左缩进 12px
    sv.directionalLayoutMargins = m;
}

+ (void)applyAdvancedExpandStyle:(UIView *)container {
    // 卡片本身是 #222, 这里用更亮一档(~#333)形成嵌套面板对比。
    container.backgroundColor = [UIColor colorWithWhite:0.20 alpha:1.0];
    container.layer.cornerRadius = 6.0;
    // 关键: 不开 clipsToBounds —— 圆角只圆背景填充, 不裁切子视图(否则会裁掉输入框/
    // 导致勾选展开内容错乱)。输入框自身背景仍是 GFViewKit 统一的 #000, 不受影响。
    container.clipsToBounds = NO;
    if ([container isKindOfClass:[UIStackView class]]) {
        UIStackView *sv = (UIStackView *)container;
        sv.layoutMarginsRelativeArrangement = YES;
        sv.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(6.0, 6.0, 6.0, 6.0);
    }
}

@end
