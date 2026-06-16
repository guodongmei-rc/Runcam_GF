#import "SyncSectionView.h"
#import "SyncAdvancedView.h"
#import "GFTheme.h"
#import "GFViewKit.h"

@interface SyncSectionView () <UITextFieldDelegate>
@property (nonatomic, strong) UIButton *autosyncCheckbox;
@property (nonatomic, strong) UILabel  *autosyncProgressLabel;  // 运行时显示「12/40 (30%)」
@property (nonatomic, strong) UILabel  *quatsWarning;          // 「使用已同步运动数据」提示(对齐官方 usesQuats)
@property (nonatomic, strong) UIView   *quatsWarningContainer; // 黄色底容器(给 Label 4pt 内边距)
@property (nonatomic, assign) BOOL usesQuatsState;            // 对齐官方 show: usesQuats && offsets>0
@property (nonatomic, assign) BOOL hasSyncPointsState;
@property (nonatomic, strong) UITextField *gyroOffsetTF;        // 单位:秒
@property (nonatomic, strong) UITextField *searchSizeTF;        // 单位:秒
@property (nonatomic, strong) UITextField *maxPointsTF;         // 整数
@property (nonatomic, strong) UIButton *advancedButton;
@property (nonatomic, strong) SyncAdvancedView *advancedView;
@property (nonatomic, assign) BOOL autosyncRunning;
// 官方 Synchronization.qml 的 3 个小复选框
@property (nonatomic, strong) UIButton *autoSyncPointsCheckbox;     // 自动选采样点（替代等距）
@property (nonatomic, strong) UIButton *negativeOffsetCheckbox;     // 双向搜索 ±offset
@property (nonatomic, strong) UIButton *calcInitialFastCheckbox;    // 先粗后细
@end

@implementation SyncSectionView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [GFTheme secondaryBackgroundColor];
        self.layer.cornerRadius = 6.0;

        UILabel *title = [UILabel new];
        title.text = @"同步";
        title.font = [UIFont boldSystemFontOfSize:14.0];
        title.textColor = [GFTheme textColor];

        // 「使用已同步运动数据」提示(对齐官方 Synchronization.qml usesQuats InfoMessage), 默认隐藏。
        // 黄色容器 + 内嵌居中 Label, Label 四边缩进 4pt(UILabel 自身不支持内边距)。
        _quatsWarning = [UILabel new];
        _quatsWarning.text = @"此文件使用已同步的运动数据，无需额外同步点，强行同步可能会使输出结果变得更糟。";
        _quatsWarning.font = [UIFont systemFontOfSize:12.0];
        _quatsWarning.textColor = [UIColor blackColor];
        _quatsWarning.numberOfLines = 0;
        _quatsWarning.textAlignment = NSTextAlignmentCenter;   // 文字居中
        _quatsWarning.translatesAutoresizingMaskIntoConstraints = NO;

        _quatsWarningContainer = [UIView new];
        _quatsWarningContainer.backgroundColor = [UIColor colorWithRed:0.949 green:0.761 blue:0.0 alpha:1.0]; // #F2C200
        _quatsWarningContainer.layer.cornerRadius = 6.0;
        _quatsWarningContainer.layer.masksToBounds = YES;
        _quatsWarningContainer.hidden = YES;
        [_quatsWarningContainer addSubview:_quatsWarning];
        [NSLayoutConstraint activateConstraints:@[
            [_quatsWarning.topAnchor      constraintEqualToAnchor:_quatsWarningContainer.topAnchor      constant:4],
            [_quatsWarning.bottomAnchor   constraintEqualToAnchor:_quatsWarningContainer.bottomAnchor   constant:-4],
            [_quatsWarning.leadingAnchor  constraintEqualToAnchor:_quatsWarningContainer.leadingAnchor  constant:4],
            [_quatsWarning.trailingAnchor constraintEqualToAnchor:_quatsWarningContainer.trailingAnchor constant:-4],
        ]];

        // 自动同步 —— 圆角 pill 按钮(对齐官方截图: 深灰底 + 橙色刷新图标 + 白字)
        _autosyncCheckbox = [self makeAutosyncButton];
        _autosyncProgressLabel = [UILabel new];
        _autosyncProgressLabel.font = [UIFont monospacedSystemFontOfSize:10.0 weight:UIFontWeightRegular];
        _autosyncProgressLabel.textColor = [GFTheme primaryColor];
        _autosyncProgressLabel.text = @"";
        // 「自动选点」（experimentalAutoSyncPoints）—— 官方默认勾上，scale 0.7 紧贴主按钮右侧
        _autoSyncPointsCheckbox = [GFViewKit makeCheckboxWithTarget:self action:@selector(autoSyncPointsTapped:)];
        _autoSyncPointsCheckbox.selected = FALSE;
        UIView *leftSpacer  = [UIView new];
        UIView *rightSpacer = [UIView new];
        leftSpacer.translatesAutoresizingMaskIntoConstraints  = NO;
        rightSpacer.translatesAutoresizingMaskIntoConstraints = NO;
        // pill 按钮单独占一行,左侧无 label, 右侧放进度文字 + 自动选点
        UIStackView *autosyncRow = [[UIStackView alloc] initWithArrangedSubviews:@[
            leftSpacer,
            _autosyncCheckbox,
            _autoSyncPointsCheckbox,
            rightSpacer,
        ]];
        autosyncRow.axis = UILayoutConstraintAxisHorizontal;
        autosyncRow.spacing = 8.0;
        autosyncRow.alignment = UIStackViewAlignmentCenter;
        // 左右 spacer 等宽 → 中间两个控件被居中
        [leftSpacer.widthAnchor constraintEqualToAnchor:rightSpacer.widthAnchor].active = YES;

        // 陀螺偏移 + 「双向」复选框（checkNegativeInitialOffset）
        // 限制输入 >= 1.0 后,负号没意义,统一用 DecimalPad
        _gyroOffsetTF = [self makeTextField:UIKeyboardTypeDecimalPad];
        _negativeOffsetCheckbox = [GFViewKit makeCheckboxWithTarget:self action:@selector(negativeOffsetTapped:)];
        UIView *r1 = [self inputRow:@"陀螺大致偏移"
                          textField:_gyroOffsetTF
                               unit:@"秒"
                           trailing:[self trailingHStackWithViews:@[ _negativeOffsetCheckbox]]];

        // 同步搜索尺寸 + 「先粗后细」复选框（calc_initial_fast）
        _searchSizeTF = [self makeTextField:UIKeyboardTypeDecimalPad];
        _calcInitialFastCheckbox = [GFViewKit makeCheckboxWithTarget:self action:@selector(calcInitialFastTapped:)];
        UIView *r2 = [self inputRow:@"同步搜索尺寸"
                          textField:_searchSizeTF
                               unit:@"秒"
                           trailing:[self trailingHStackWithViews:@[ _calcInitialFastCheckbox]]];

        // 最大同步点数(整数)
        _maxPointsTF = [self makeTextField:UIKeyboardTypeNumberPad];
        UIView *r3 = [self inputRow:@"最大同步点数" textField:_maxPointsTF unit:@""];

        // 高级选项 按钮
        _advancedButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_advancedButton setTitle:@"高级选项 ▾" forState:UIControlStateNormal];
        [_advancedButton setTitleColor:[GFTheme primaryColor] forState:UIControlStateNormal];
        _advancedButton.titleLabel.font = [UIFont systemFontOfSize:12.0];
        [_advancedButton addTarget:self action:@selector(advancedTapped) forControlEvents:UIControlEventTouchUpInside];

        _advancedView = [[SyncAdvancedView alloc] initWithFrame:CGRectZero];
        [GFViewKit applyAdvancedExpandStyle:_advancedView];   // 高级区与主背景区分
        _advancedView.hidden = YES;

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, _quatsWarningContainer, autosyncRow, r1, r2, r3, _advancedButton, _advancedView]];
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

#pragma mark - 通用行布局 / 文本框构造

- (UIView *)rowLabel:(NSString *)labelText control:(UIView *)ctrl trailing:(nullable UIView *)trailing {
    UILabel *label = [UILabel new];
    label.text = labelText;
    label.font = [UIFont systemFontOfSize:12.0];
    label.textColor = [GFTheme secondaryTextColor];
    NSLayoutConstraint *lw = [label.widthAnchor constraintEqualToConstant:130.0];
    lw.priority = 999;   // 窄列可压缩, 避免约束冲突
    lw.active = YES;
    NSMutableArray *arranged = [NSMutableArray arrayWithObjects:label, ctrl, nil];
    if (trailing) [arranged addObject:trailing];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:arranged];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8.0;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

// 方框勾选 —— 全局共用 GFTheme 工厂（白色 tint + 描边粗细一致）
- (UIButton *)makeCheckbox {
    return [GFViewKit makeCheckboxWithTarget:self action:@selector(checkboxTapped:)];
}

// 「自动同步」按钮 —— 圆角 pill: 深灰底 + 橙色 sync 图标 + 白字
- (UIButton *)makeAutosyncButton {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1.0];
    btn.layer.cornerRadius = 6.0;
    btn.clipsToBounds = YES;
//    btn.contentEdgeInsets = UIEdgeInsetsMake(8, 8, 8, 8);
    btn.titleEdgeInsets   = UIEdgeInsetsMake(0, 6, 0, 0);  // 图标和文字之间留 6pt
    btn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    [btn setTitle:@"自动同步" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightSemibold];
        UIImage *icon = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath" withConfiguration:cfg];
        [btn setImage:icon forState:UIControlStateNormal];
        btn.tintColor = [GFTheme primaryColor];
    }

    [btn addTarget:self action:@selector(checkboxTapped:) forControlEvents:UIControlEventTouchUpInside];
    [btn.heightAnchor constraintEqualToConstant:32.0].active = YES;
    [btn.widthAnchor constraintEqualToConstant:100.0].active = YES;
    return btn;
}

- (void)checkboxTapped:(UIButton *)sender {
    if (sender == self.autosyncCheckbox) {
        // 不直接 toggle —— Controller 决定:开始/取消由 Controller 接管,
        // 完成时由 Controller 调 setAutosyncRunning: 把 selected 状态收尾。
        BOOL turningOn = !sender.selected;
        if (self.onAutosyncTapped) self.onAutosyncTapped(turningOn);
        // Controller 会在 onAutosyncTapped 内部决定是否真的进入 running 态;
        // 这里先把 selected 同步上去,让用户立刻看到反馈。如果 Controller
        // 拒绝(没视频/没陀螺数据),会通过 setAutosyncRunning:NO 把它扳回来。
        sender.selected = turningOn;
    } else {
        sender.selected = !sender.selected;
    }
}

- (UITextField *)makeTextField:(UIKeyboardType)keyboard {
    UITextField *tf = [UITextField new];
    tf.borderStyle = UITextBorderStyleRoundedRect;
    tf.font = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightRegular];
    tf.textColor = [GFTheme textColor];
    tf.backgroundColor = [GFTheme backgroundColor];
    tf.textAlignment = NSTextAlignmentRight;
    tf.keyboardType = keyboard;
    tf.returnKeyType = UIReturnKeyDone;
    tf.delegate = self;
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    NSLayoutConstraint *tfw = [tf.widthAnchor constraintEqualToConstant:90.0];
    tfw.priority = 999;   // 窄列可压缩
    tfw.active = YES;

    // numeric / decimal pad 没有 Done 键 → 加 inputAccessoryView 工具条
    UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 40)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:tf action:@selector(resignFirstResponder)];
    toolbar.items = @[flex, done];
    tf.inputAccessoryView = toolbar;
    return tf;
}

- (UIView *)inputRow:(NSString *)labelText textField:(UITextField *)tf unit:(NSString *)unit {
    return [self inputRow:labelText textField:tf unit:unit trailing:nil];
}

- (UIView *)inputRow:(NSString *)labelText
           textField:(UITextField *)tf
                unit:(NSString *)unit
            trailing:(nullable UIView *)trailing {
    UILabel *label = [UILabel new];
    label.text = labelText;
    label.font = [UIFont systemFontOfSize:12.0];
    label.textColor = [GFTheme secondaryTextColor];
    NSLayoutConstraint *lw = [label.widthAnchor constraintEqualToConstant:130.0];
    lw.priority = 999;   // 窄列可压缩, 避免约束冲突
    lw.active = YES;

    UILabel *unitLabel = [UILabel new];
    unitLabel.text = unit;
    unitLabel.font = [UIFont systemFontOfSize:12.0];
    unitLabel.textColor = [GFTheme secondaryTextColor];
    [unitLabel.widthAnchor constraintEqualToConstant:30.0].active = YES;

    UIView *spacer = [UIView new];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    NSMutableArray *arranged = [NSMutableArray arrayWithObjects:label, spacer, tf, unitLabel, nil];
    if (trailing) [arranged addObject:trailing];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:arranged];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 6.0;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

// 「双向」/「先粗后细」/「自动选点」等附带的小说明标签
- (UILabel *)subLabel:(NSString *)text {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [UIFont systemFontOfSize:10.0];
    l.textColor = [GFTheme secondaryTextColor];
    return l;
}

// 把若干 view 横排成一个紧凑的 trailing 区
- (UIView *)trailingHStackWithViews:(NSArray<UIView *> *)views {
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:views];
    s.axis = UILayoutConstraintAxisHorizontal;
    s.spacing = 4.0;
    s.alignment = UIStackViewAlignmentCenter;
    return s;
}

#pragma mark - 小复选框动作

- (void)autoSyncPointsTapped:(UIButton *)sender {
    sender.selected = !sender.selected;
    self.model.autoSyncPointsExperimental = sender.selected;
}

- (void)negativeOffsetTapped:(UIButton *)sender {
    sender.selected = !sender.selected;
    self.model.checkNegativeInitialOffset = sender.selected;
}

- (void)calcInitialFastTapped:(UIButton *)sender {
    sender.selected = !sender.selected;
    self.model.calcInitialFast = sender.selected;
}

#pragma mark - Model 绑定 & 刷新

- (void)setModel:(ParamsModel *)model {
    _model = model;
    if (model == nil) return;
    self.autosyncCheckbox.selected         = model.autosyncEnabled;
    self.gyroOffsetTF.text                 = [NSString stringWithFormat:@"%.1f", model.gyroOffsetMs / 1000.0];
    self.searchSizeTF.text                 = [NSString stringWithFormat:@"%.1f",  model.syncSearchSizeSec];
    self.maxPointsTF.text                  = [NSString stringWithFormat:@"%d",    model.maxSyncPoints];
    self.autoSyncPointsCheckbox.selected   = model.autoSyncPointsExperimental;
    self.negativeOffsetCheckbox.selected   = model.checkNegativeInitialOffset;
    self.calcInitialFastCheckbox.selected  = model.calcInitialFast;
    self.advancedView.model = model;
}

- (void)refreshReadOnly { /* 无只读 */ }

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

// 手动输入限制(陀螺大致偏移 / 同步搜索尺寸): 数字 + 至多 1 个小数点 + 小数最多 1 位。
// (外部 setModel 显示不走这里,所以镜头预设里 0.5 等值能正常回显)
- (BOOL)textField:(UITextField *)textField
shouldChangeCharactersInRange:(NSRange)range
replacementString:(NSString *)string {
    if (textField != self.gyroOffsetTF && textField != self.searchSizeTF) {
        return YES; // 整数字段(maxPoints)走它自己的逻辑
    }
    if (string.length == 0) return YES; // 删除键放行

    NSString *candidate = [textField.text stringByReplacingCharactersInRange:range withString:string];

    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789."];
    NSCharacterSet *typed   = [NSCharacterSet characterSetWithCharactersInString:string];
    if (![allowed isSupersetOfSet:typed]) return NO;
    NSUInteger dotCount = [[candidate componentsSeparatedByString:@"."] count] - 1;
    if (dotCount > 1) return NO;
    NSRange dotRange = [candidate rangeOfString:@"."];
    if (dotRange.location != NSNotFound) {
        NSString *decimals = [candidate substringFromIndex:dotRange.location + 1];
        if (decimals.length > 1) return NO;
    }
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    double v = [textField.text doubleValue];
    if (textField == self.gyroOffsetTF) {
        // 手动输入约束: > 0, 1 位小数。(外部 setModel 显示不走这里)
        if (v < 0.1) v = 0.1;
        else if (v > 60.0) v = 60.0;
        v = round(v * 10.0) / 10.0;
        textField.text = [NSString stringWithFormat:@"%.1f", v];
        self.model.gyroOffsetMs = v * 1000.0;
    } else if (textField == self.searchSizeTF) {
        // 手动输入约束: > 0, 1 位小数
        if (v < 0.1) v = 0.1;
        else if (v > 60.0) v = 60.0;
        v = round(v * 10.0) / 10.0;
        textField.text = [NSString stringWithFormat:@"%.1f", v];
        self.model.syncSearchSizeSec = v;
        // 对齐官方 Synchronization.qml:252  value > 10 时自动勾上 calculateInitialOffsetFirst
        if (v > 10.0) {
            self.model.calcInitialFast = YES;
            self.calcInitialFastCheckbox.selected = YES;
        }
    } else if (textField == self.maxPointsTF) {
        // 官方 UI 1–30，硬限 1–500。这里取保守上限 30 防 iOS 端跑爆
        int iv = (int)round(v);
        if (iv < 1) iv = 1;
        else if (iv > 30) iv = 30;
        textField.text = [NSString stringWithFormat:@"%d", iv];
        self.model.maxSyncPoints = iv;
    }
}

#pragma mark - Phase β:自动同步运行态

- (void)setAutosyncRunning:(BOOL)running {
    // 注意:这个方法本身就是 autosyncRunning 属性的 setter,
    // 千万**不能**写 self.autosyncRunning = running —— 会无限递归直到爆栈。
    _autosyncRunning = running;
    // pill 按钮: running=YES 显示「取消同步」,running=NO 显示「自动同步」
    [self.autosyncCheckbox setTitle:@"自动同步" forState:UIControlStateNormal];
    self.autosyncCheckbox.selected = running;
    // 跑的时候锁住 textfield 和高级选项按钮 —— 它们改的参数都是 SyncParams,
    // 跑到一半改没意义
    self.gyroOffsetTF.enabled = !running;
    self.searchSizeTF.enabled = !running;
    self.maxPointsTF.enabled  = !running;
    self.advancedButton.enabled = !running;
    if (!running) self.autosyncProgressLabel.text = @"";
}

// 视频使用已同步运动数据(精确时间戳/直接用四元数)时显示提示(对齐官方 usesQuats)。
- (void)setUsesQuats:(BOOL)usesQuats {
    self.usesQuatsState = usesQuats;
    [self refreshQuatsWarning];
}

// 当前是否已有同步点(对齐官方 offsets_model.rowCount() > 0)。
- (void)setHasSyncPoints:(BOOL)has {
    self.hasSyncPointsState = has;
    [self refreshQuatsWarning];
}

// 官方 Synchronization.qml:212 —— 仅「用已同步数据」且「已有同步点」才弹(同步后才提示)。
- (void)refreshQuatsWarning {
    self.quatsWarningContainer.hidden = !(self.usesQuatsState && self.hasSyncPointsState);
}

- (void)setSectionEnabled:(BOOL)enabled {
    self.userInteractionEnabled = enabled;
    self.alpha = enabled ? 1.0 : 0.5;
}

- (void)updateAutosyncProgress:(double)progress framesFed:(int)fed framesTotal:(int)total {
    if (!self.autosyncRunning) return;
    if (total > 0) {
        self.autosyncProgressLabel.text = [NSString stringWithFormat:@"%d/%d %d%%", fed, total, (int)round(progress * 100.0)];
    } else {
        self.autosyncProgressLabel.text = [NSString stringWithFormat:@"%d%%", (int)round(progress * 100.0)];
    }
}

- (void)refreshGyroOffsetFromModel {
    if (!self.model) return;
    self.gyroOffsetTF.text = [NSString stringWithFormat:@"%+.3f", self.model.gyroOffsetMs / 1000.0];
}

#pragma mark - 高级选项切换

- (void)advancedTapped {
    BOOL willShow = self.advancedView.hidden;
    [UIView animateWithDuration:0.2 animations:^{
        self.advancedView.hidden = !willShow;
        [self.advancedButton setTitle:(willShow ? @"高级选项 ▴" : @"高级选项 ▾")
                             forState:UIControlStateNormal];
        [self layoutIfNeeded];
    }];
}

@end
