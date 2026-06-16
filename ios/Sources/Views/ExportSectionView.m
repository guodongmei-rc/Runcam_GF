#import "ExportSectionView.h"
#import "GFTheme.h"
#import "GFViewKit.h"

@interface ExportSectionView () <UITextFieldDelegate>
// 编解码器: 0 = H.264/AVC, 1 = H.265/HEVC
@property (nonatomic, strong) UIButton    *codecDropdown;
// 输出大小 W × H (由 AdvancedSectionView 迁移而来)
@property (nonatomic, strong) UITextField *outWField;
@property (nonatomic, strong) UITextField *outHField;
@property (nonatomic, strong) UIButton    *lockButton;   // 锁定宽高比
@property (nonatomic, strong) UIButton    *sizeMenuBtn;  // 尺寸预设(齿轮)
@property (nonatomic, strong) UIStackView *sizeRowStack; // 输出大小行(标签+控件), 可切单/双行
@property (nonatomic, strong) UIStackView *mainStack;        // 卡片主列(嵌入导出按钮用)
@property (nonatomic, strong) UITextField *outputNameField;  // 输出路径: 输出文件名(可编辑)
@property (nonatomic, strong) UILabel *exportDirLabel;       // 输出路径: 同行显示当前导出目标目录
@property (nonatomic, strong) UIView  *resolutionWarningBox; // 输出大小校验红色提示框(对齐官方 Error InfoMessageSmall)
@property (nonatomic, strong) UILabel *resolutionWarning;    // 提示框内文字(白字居中)
@property (nonatomic, strong) UITextField *bitrateField;
@property (nonatomic, strong) UIButton    *audioCheckbox;
@property (nonatomic, assign) BOOL    aspectLocked;
@property (nonatomic, assign) double  aspectRatio;       // = 宽 / 高
@end

@implementation ExportSectionView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [GFTheme secondaryBackgroundColor];
        self.layer.cornerRadius = 6.0;
        _inputSize = CGSizeZero;
        _aspectLocked = YES;   // 默认锁定宽高比(对齐桌面)
        _aspectRatio = 0.0;

        UILabel *title = [UILabel new];
        title.text = @"导出设置";
        title.font = [UIFont boldSystemFontOfSize:14.0];
        title.textColor = [GFTheme textColor];

        // 输出路径(对齐官方导出页顶部 OutputPathField): 标签 + 文件名输入框。
        // 文件名实际用于导出产物(相册条目名), 默认值由 Controller 每次加载视频时
        // 设为「视频名_stabilized.mp4」(对齐官方 VideoArea.qml:438)。
        UILabel *pathLabel = [UILabel new];
        pathLabel.text = @"输出路径:";
        pathLabel.font = [UIFont systemFontOfSize:12.0];
        pathLabel.textColor = [GFTheme secondaryTextColor];
        [pathLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [pathLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        // 同一行显示当前导出目标目录(尾部截断, 未选时显示「未选择」)
        _exportDirLabel = [UILabel new];
        _exportDirLabel.font = [UIFont systemFontOfSize:12.0];
        _exportDirLabel.textColor = [GFTheme textColor];
        _exportDirLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _exportDirLabel.text = @"未选择";
        UIStackView *pathLabelRow = [[UIStackView alloc] initWithArrangedSubviews:@[pathLabel, _exportDirLabel]];
        pathLabelRow.axis = UILayoutConstraintAxisHorizontal;
        pathLabelRow.spacing = 6.0;
        pathLabelRow.alignment = UIStackViewAlignmentFirstBaseline;
        // 文件名输入框: 样式与本卡片其它输入框(numberField)一致, 仅文本左对齐 + 文本键盘
        _outputNameField = [UITextField new];
        _outputNameField.backgroundColor = [GFTheme backgroundColor];
        _outputNameField.textColor = [GFTheme textColor];
        _outputNameField.font = [UIFont systemFontOfSize:13.0];
        _outputNameField.layer.cornerRadius = 4.0;
        _outputNameField.returnKeyType = UIReturnKeyDone;
        _outputNameField.delegate = self;
        _outputNameField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 1)];
        _outputNameField.leftViewMode = UITextFieldViewModeAlways;
        [_outputNameField.heightAnchor constraintEqualToConstant:28.0].active = YES;
        [_outputNameField addTarget:self action:@selector(outputNameEditingEnded) forControlEvents:UIControlEventEditingDidEnd];
        [_outputNameField addTarget:self action:@selector(outputNameChanged) forControlEvents:UIControlEventEditingChanged];
        // 「…」选导出存储路径(对齐官方 OutputPathField 的目录选择按钮)
        UIButton *pickFolderBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [pickFolderBtn setTitle:@"…" forState:UIControlStateNormal];
        pickFolderBtn.titleLabel.font = [UIFont systemFontOfSize:16.0];
        [pickFolderBtn setTitleColor:[GFTheme secondaryTextColor] forState:UIControlStateNormal];
        [pickFolderBtn.widthAnchor constraintEqualToConstant:28.0].active = YES;
        [pickFolderBtn addTarget:self action:@selector(pickExportFolderTapped) forControlEvents:UIControlEventTouchUpInside];
        UIStackView *pathFieldRow = [[UIStackView alloc] initWithArrangedSubviews:@[_outputNameField, pickFolderBtn]];
        pathFieldRow.axis = UILayoutConstraintAxisHorizontal;
        pathFieldRow.spacing = 6.0;
        pathFieldRow.alignment = UIStackViewAlignmentCenter;
        UIStackView *pathRow = [[UIStackView alloc] initWithArrangedSubviews:@[pathLabelRow, pathFieldRow]];
        pathRow.axis = UILayoutConstraintAxisVertical;
        pathRow.spacing = 6.0;

        // 编解码器下拉 (默认 H.265/HEVC)。AVAssetWriter 导出实际支持的 3 种;
        // 顺序必须与 ViewController gfExportCodecForIndex / model.exportCodecIndex 对齐:
        // 0=H.264/AVC(.mp4) 1=H.265/HEVC(.mp4) 2=ProRes(.mov, 仅较新机型硬件支持)。
        __weak typeof(self) weakSelf = self;
        _codecDropdown = [GFViewKit makeDropdownWithTitles:@[@"H.264/AVC", @"H.265/HEVC"]
                                                  selected:1
                                                  onChange:^(NSInteger idx) {
            __strong typeof(weakSelf) sSelf = weakSelf;
            if (sSelf.model) sSelf.model.exportCodecIndex = (int)idx;
            [sSelf updateResolutionWarning];   // 编码器上限不同(4096²/8192²), 切换后重校验
        }];
        UIView *rCodec = [self labeled:@"编解码器" control:_codecDropdown];

        // 输出大小: W [锁定] H [齿轮预设]
        _outWField = [self numberField];
        _outHField = [self numberField];
        UILabel *xLabel = [UILabel new];
        xLabel.text = @"×";
        xLabel.font = [UIFont systemFontOfSize:14.0];
        xLabel.textColor = [GFTheme textColor];

        _lockButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _lockButton.titleLabel.font = [UIFont systemFontOfSize:16.0];
        [_lockButton setTitleColor:[GFTheme primaryColor] forState:UIControlStateNormal];
        [_lockButton addTarget:self action:@selector(lockTapped) forControlEvents:UIControlEventTouchUpInside];
        [_lockButton.widthAnchor constraintEqualToConstant:28.0].active = YES;
        [self updateLockButtonTitle];

        _sizeMenuBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _sizeMenuBtn.titleLabel.font = [UIFont systemFontOfSize:16.0];
        [_sizeMenuBtn setTitle:@"⚙" forState:UIControlStateNormal];
        [_sizeMenuBtn setTitleColor:[GFTheme secondaryTextColor] forState:UIControlStateNormal];
        [_sizeMenuBtn.widthAnchor constraintEqualToConstant:28.0].active = YES;
        [self rebuildSizePresetMenu];

        // 末尾加弹性 spacer: 让 W × H 锁 齿轮 紧挨左排、多余宽度留右边(否则会被撑开有空隙)。
        UIView *sizeTrailingSpacer = [UIView new];
        UIStackView *sizeRow = [[UIStackView alloc] initWithArrangedSubviews:@[_outWField, xLabel, _outHField, _lockButton, _sizeMenuBtn, sizeTrailingSpacer]];
        sizeRow.axis = UILayoutConstraintAxisHorizontal;
        sizeRow.spacing = 6.0;
        sizeRow.alignment = UIStackViewAlignmentCenter;
        // 输出大小行: 默认单行(标签+控件同一行, 竖屏); 横屏窄列由 setSizeRowStacked:YES 切两行。
        UILabel *outSizeLabel = [UILabel new];
        outSizeLabel.text = @"输出大小";
        outSizeLabel.font = [UIFont systemFontOfSize:12.0];
        outSizeLabel.textColor = [GFTheme secondaryTextColor];
        NSLayoutConstraint *outLW = [outSizeLabel.widthAnchor constraintEqualToConstant:130.0];
        outLW.priority = 999;   // 窄列可压缩
        outLW.active = YES;
        UIStackView *rOut = [[UIStackView alloc] initWithArrangedSubviews:@[outSizeLabel, sizeRow]];
        rOut.axis = UILayoutConstraintAxisHorizontal;
        rOut.spacing = 8.0;
        rOut.alignment = UIStackViewAlignmentCenter;
        self.sizeRowStack = rOut;

        // 比特率 (Mbps)。复用 numberField(宽 64), 失焦提交走 bitrateEditingEnded。
        _bitrateField = [self numberField];
        [_bitrateField addTarget:self action:@selector(bitrateEditingEnded) forControlEvents:UIControlEventEditingDidEnd];
        UILabel *mbpsLabel = [UILabel new];
        mbpsLabel.text = @"Mbps";
        mbpsLabel.font = [UIFont systemFontOfSize:13.0];
        mbpsLabel.textColor = [GFTheme secondaryTextColor];
        UIStackView *bitrateRow = [[UIStackView alloc] initWithArrangedSubviews:@[_bitrateField, mbpsLabel]];
        bitrateRow.axis = UILayoutConstraintAxisHorizontal;
        bitrateRow.spacing = 8.0;
        bitrateRow.alignment = UIStackViewAlignmentCenter;
        UIView *rBitrate = [self labeled:@"比特率" control:bitrateRow];

        // 导出音频 (「使用 GPU 编码」按需求隐藏: iOS VideoToolbox 恒为硬件编码, 该开关无实际意义)
        _audioCheckbox = [GFViewKit makeCheckboxWithTarget:self action:@selector(audioTapped)];
        _audioCheckbox.selected = YES;
        UIView *rAudio = [self checkboxRow:@"导出音频" checkbox:_audioCheckbox];

        // 输出大小校验红色提示框(对齐官方 Export.qml:453-466 Error InfoMessageSmall):
        // 红底白字、文字居中。
        _resolutionWarning = [UILabel new];
        _resolutionWarning.font = [UIFont systemFontOfSize:12.0];
        _resolutionWarning.textColor = UIColor.whiteColor;
        _resolutionWarning.numberOfLines = 0;
        _resolutionWarning.textAlignment = NSTextAlignmentCenter;
        _resolutionWarning.translatesAutoresizingMaskIntoConstraints = NO;
        _resolutionWarningBox = [UIView new];
        _resolutionWarningBox.backgroundColor = [UIColor systemRedColor];
        _resolutionWarningBox.layer.cornerRadius = 6.0;
        _resolutionWarningBox.clipsToBounds = YES;
        _resolutionWarningBox.hidden = YES;
        [_resolutionWarningBox addSubview:_resolutionWarning];
        [NSLayoutConstraint activateConstraints:@[
            [_resolutionWarning.topAnchor      constraintEqualToAnchor:_resolutionWarningBox.topAnchor      constant:8],
            [_resolutionWarning.bottomAnchor   constraintEqualToAnchor:_resolutionWarningBox.bottomAnchor   constant:-8],
            [_resolutionWarning.leadingAnchor  constraintEqualToAnchor:_resolutionWarningBox.leadingAnchor  constant:10],
            [_resolutionWarning.trailingAnchor constraintEqualToAnchor:_resolutionWarningBox.trailingAnchor constant:-10],
        ]];

        // 顺序对齐官方导出页: 输出路径 → (导出按钮由 embedExportButton 插到这里) →
        // 编解码器 → 输出大小 → 比特率 → 音频
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, pathRow, rCodec, rOut, _resolutionWarningBox, rBitrate, rAudio]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 8.0;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        self.mainStack = stack;
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

#pragma mark - 控件工厂

// 通用数字输入框 (输出 W/H 与 比特率共用)。数字键盘, 失焦/回车提交。
- (UITextField *)numberField {
    UITextField *f = [UITextField new];
    f.backgroundColor = [GFTheme backgroundColor];
    f.textColor = [GFTheme textColor];
    f.font = [UIFont systemFontOfSize:13.0];
    f.textAlignment = NSTextAlignmentCenter;
    f.layer.cornerRadius = 4.0;
    f.keyboardType = UIKeyboardTypeNumberPad;
    f.returnKeyType = UIReturnKeyDone;
    f.delegate = self;
    // 首选宽 64, 但优先级 < required: 输出大小行控件较多, 窄屏时让数字框先收缩, 不破坏约束。
    NSLayoutConstraint *wc = [f.widthAnchor constraintEqualToConstant:64.0];
    wc.priority = UILayoutPriorityDefaultHigh;
    wc.active = YES;
    [f setContentCompressionResistancePriority:UILayoutPriorityDefaultLow + 1
                                       forAxis:UILayoutConstraintAxisHorizontal];
    [f.heightAnchor constraintEqualToConstant:28.0].active = YES;
    [f addTarget:self action:@selector(sizeFieldEditingEnded:) forControlEvents:UIControlEventEditingDidEnd];
    return f;
}

// 标准 "标签(等宽 130) + 控件" 一行
- (UIView *)labeled:(NSString *)t control:(UIView *)c {
    UILabel *label = [UILabel new];
    label.text = t; label.font = [UIFont systemFontOfSize:12.0];
    label.textColor = [GFTheme secondaryTextColor];
    NSLayoutConstraint *lw = [label.widthAnchor constraintEqualToConstant:130.0];
    lw.priority = 999;   // 窄列可压缩, 避免约束冲突
    lw.active = YES;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, c]];
    row.axis = UILayoutConstraintAxisHorizontal; row.spacing = 8.0; row.alignment = UIStackViewAlignmentCenter;
    return row;
}

// 切换输出大小行布局: 竖屏单行(横向) / 横屏窄列两行(纵向)。
- (void)setSizeRowStacked:(BOOL)stacked {
    _sizeRowStacked = stacked;
    self.sizeRowStack.axis      = stacked ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.sizeRowStack.alignment = stacked ? UIStackViewAlignmentLeading : UIStackViewAlignmentCenter;
    self.sizeRowStack.spacing   = stacked ? 6.0 : 8.0;
}

// "checkbox + 文字标签" 一行 (对齐其它 Section 的勾选行)
- (UIView *)checkboxRow:(NSString *)t checkbox:(UIButton *)cb {
    UILabel *label = [UILabel new];
    label.text = t; label.font = [UIFont systemFontOfSize:13.0];
    label.textColor = [GFTheme textColor];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[cb, label]];
    row.axis = UILayoutConstraintAxisHorizontal; row.spacing = 8.0; row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (void)updateLockButtonTitle {
    [self.lockButton setTitle:(self.aspectLocked ? @"🔒" : @"🔓") forState:UIControlStateNormal];
}

#pragma mark - 尺寸预设(齿轮)菜单

- (void)rebuildSizePresetMenu {
    if (@available(iOS 14.0, *)) {
        // 各比例分组 + 固定档 (对齐桌面 Export.qml outputSizePresets)。
        NSArray *groups = @[
            @{@"name": @"16:9", @"wp": @16, @"hp": @9,
              @"presets": @[@[@"8k",@7680,@4320], @[@"6k",@6016,@3384], @[@"4k",@3840,@2160], @[@"1080p",@1920,@1080], @[@"720p",@1280,@720]]},
            @{@"name": @"17:9", @"wp": @17, @"hp": @9,
              @"presets": @[@[@"4k",@4096,@2160], @[@"2k",@2048,@1080]]},
            @{@"name": @"9:16", @"wp": @9, @"hp": @16,
              @"presets": @[@[@"8k",@4320,@7680], @[@"6k",@3384,@6016], @[@"4k",@2160,@3840], @[@"1080p",@1080,@1920], @[@"720p",@720,@1280]]},
            @{@"name": @"4:3", @"wp": @4, @"hp": @3,
              @"presets": @[@[@"480p",@640,@480]]},
            @{@"name": @"1:1", @"wp": @1, @"hp": @1,
              @"presets": @[@[@"4k",@2160,@2160], @[@"1080p",@1080,@1080]]},
        ];
        CGSize in = self.inputSize;
        int iw = (in.width  > 0.5) ? (int)round(in.width)  : 0;
        int ih = (in.height > 0.5) ? (int)round(in.height) : 0;
        double maxZoom = (self.model && self.model.maxZoomPercent > 1.0) ? self.model.maxZoomPercent : 130.0;

        NSMutableArray<UIMenu *> *submenus = [NSMutableArray array];
        for (NSDictionary *g in groups) {
            NSMutableArray<UIAction *> *items = [NSMutableArray array];
            int wp = [g[@"wp"] intValue], hp = [g[@"hp"] intValue];
            if (iw > 0 && ih > 0) {
                // 原始 (输入原生尺寸)
                [items addObject:[self presetActionTitle:@"原始" w:iw h:ih]];
                // 比例: 把原生尺寸按该比例做 proportional fit (对齐桌面 "Proportional")
                double scale = MIN((double)iw / (double)wp, (double)ih / (double)hp);
                int nw = (int)round(wp * scale); if (nw & 1) nw -= 1;
                int nh = (int)round(hp * scale); if (nh & 1) nh -= 1;
                if (nw >= 4 && nh >= 4) {
                    [items addObject:[self presetActionTitle:@"比例" w:nw h:nh]];
                    // Based on "Max zoom": 再按 100/maxZoom 缩 (对齐桌面)
                    int nwz = (int)round(nw * (100.0 / maxZoom)); if (nwz & 1) nwz -= 1;
                    int nhz = (int)round(nh * (100.0 / maxZoom)); if (nhz & 1) nhz -= 1;
                    if (nwz >= 4 && nhz >= 4) {
                        [items addObject:[self presetActionTitle:@"按最大缩放" w:nwz h:nhz]];
                    }
                }
            }
            for (NSArray *p in g[@"presets"]) {
                [items addObject:[self presetActionTitle:p[0] w:[p[1] intValue] h:[p[2] intValue]]];
            }
            [submenus addObject:[UIMenu menuWithTitle:g[@"name"] children:items]];
        }
        self.sizeMenuBtn.menu = [UIMenu menuWithTitle:@"输出大小预设" children:submenus];
        self.sizeMenuBtn.showsMenuAsPrimaryAction = YES;
    }
}

- (UIAction *)presetActionTitle:(NSString *)label w:(int)w h:(int)h API_AVAILABLE(ios(14.0)) {
    __weak typeof(self) weakSelf = self;
    NSString *title = [NSString stringWithFormat:@"%@  (%d×%d)", label, w, h];
    return [UIAction actionWithTitle:title image:nil identifier:nil handler:^(UIAction *act) {
        __strong typeof(weakSelf) sSelf = weakSelf;
        if (sSelf == nil || sSelf.model == nil) return;
        if (h > 0) sSelf.aspectRatio = (double)w / (double)h;
        sSelf.model.outputSize = CGSizeMake(w, h);
        [sSelf syncOutputFieldsFromModel];
    }];
}

#pragma mark - 输出路径

- (NSString *)outputFileName {
    NSString *name = [self.outputNameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return (name.length > 0) ? name : nil;
}

- (void)setDefaultOutputFileName:(NSString *)name {
    self.outputNameField.text = name ?: @"";
    // 程序设值不触发 EditingChanged, 主动通知 Controller 刷新「导出」按钮可用态(长度>3)
    if (self.onOutputFileNameChanged) {
        self.onOutputFileNameChanged();
    }
}

- (void)setExportFolderDisplay:(NSString *)path {
    if (path == nil) {
        self.exportDirLabel.text = @"未选择";      // 未授权任何目录
        return;
    }
    // 已授权: 剥完系统前缀后为空说明选的是存储根目录(对齐官方 OutputPathField 空显示兜底)
    NSString *p = [path stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.exportDirLabel.text = (p.length > 0) ? p : @"根目录";
}

- (void)embedExportButton:(UIButton *)button {
    if (button == nil || self.mainStack == nil) {
        return;
    }
    // 插到「输出路径」行之后(index: 0=标题 1=输出路径 → 2)
    [self.mainStack insertArrangedSubview:button atIndex:2];
}

- (void)pickExportFolderTapped {
    if (self.onPickExportFolder) {
        self.onPickExportFolder();
    }
}

- (void)outputNameEditingEnded {
    if (self.onOutputFileNameEdited) {
        self.onOutputFileNameEdited();
    }
}

// 实时输入处理(对齐官方 OutputPathField.qml:31): 剥掉路径前缀, 只保留最后一段文件名
// (禁止文件名含路径分隔符); 改完通知 Controller 刷新「导出」按钮可用态(长度>3)。
- (void)outputNameChanged {
    NSString *t = self.outputNameField.text ?: @"";
    NSRange slash = [t rangeOfString:@"/" options:NSBackwardsSearch];
    if (slash.location != NSNotFound) {
        // 保留光标在末尾的自然体验: 截到最后一个「/」之后
        self.outputNameField.text = [t substringFromIndex:slash.location + 1];
    }
    if (self.onOutputFileNameChanged) {
        self.onOutputFileNameChanged();
    }
}

#pragma mark - Model 绑定

- (void)setModel:(ParamsModel *)model {
    _model = model;
    if (model == nil) return;
    [self syncOutputFieldsFromModel];
    self.bitrateField.text = (model.exportBitrateMbps > 0)
        ? [NSString stringWithFormat:@"%d", model.exportBitrateMbps] : @"";
    self.audioCheckbox.selected = model.exportAudio;
    [self rebuildSizePresetMenu];  // 此时 model 已就绪, 让"按最大缩放"用上真实 maxZoom
}

- (void)setInputSize:(CGSize)inputSize {
    _inputSize = inputSize;
    [self rebuildSizePresetMenu];
}

// recompute / 镜头档案加载后 outputSize 可能被外部改动, 刷新输入框显示。
- (void)refreshReadOnly {
    [self syncOutputFieldsFromModel];
}

// 输出大小范围校验(对齐官方 Export.qml:117/453-466): ①超所选编码器最大分辨率
// (H.264→4096x4096, H.265→8192x8192, 对齐官方 max_size); ②分辨率必须可被 2 整除。
// 违规 → 红色提示框(文案对齐官方 zh_CN 翻译) + 回调 Controller 禁用导出(canExport)。
- (void)updateResolutionWarning {
    int maxDim = (self.model && self.model.exportCodecIndex == 0) ? 4096 : 8192;
    int w = self.model ? (int)round(self.model.outputSize.width) : 0;
    int h = self.model ? (int)round(self.model.outputSize.height) : 0;
    NSMutableArray<NSString *> *messages = [NSMutableArray array];
    if (w > 0 && h > 0) {
        if (w > maxDim || h > maxDim) {
            [messages addObject:[NSString stringWithFormat:
                @"选择的编码解码器不支持此分辨率。\n支持的最大分辨率是 %dx%d。", maxDim, maxDim]];
        }
        if ((w % 2) != 0 || (h % 2) != 0) {
            [messages addObject:@"分辨率必须可以被 2 整除。"];
        }
    }
    BOOL invalid = (messages.count > 0);
    self.resolutionWarningBox.hidden = !invalid;
    self.resolutionWarning.text = invalid ? [messages componentsJoinedByString:@"\n"] : @"";
    if (self.onResolutionValidChanged) {
        self.onResolutionValidChanged(!invalid);
    }
}

- (void)syncOutputFieldsFromModel {
    if (self.model == nil) return;
    CGSize os = self.model.outputSize;
    self.outWField.text = (os.width  > 0.5) ? [NSString stringWithFormat:@"%d", (int)round(os.width)]  : @"";
    self.outHField.text = (os.height > 0.5) ? [NSString stringWithFormat:@"%d", (int)round(os.height)] : @"";
    if (self.aspectLocked && os.width > 0.5 && os.height > 0.5) {
        self.aspectRatio = (double)os.width / (double)os.height;
    }
    [self updateResolutionWarning];   // 输入框/预设/外部改动统一在这里过校验
}

#pragma mark - 交互

- (void)lockTapped {
    self.aspectLocked = !self.aspectLocked;
    [self updateLockButtonTitle];
    if (self.aspectLocked && self.model
        && self.model.outputSize.width > 0.5 && self.model.outputSize.height > 0.5) {
        self.aspectRatio = (double)self.model.outputSize.width / (double)self.model.outputSize.height;
    }
}

// 输出大小输入框提交。锁定宽高比时按比例联动另一边。
- (void)sizeFieldEditingEnded:(UITextField *)f {
    if (self.model == nil) return;
    if (f != self.outWField && f != self.outHField) return;
    BOOL isWidth = (f == self.outWField);
    int v = [f.text intValue];
    if (v <= 0) {                 // 空/0/非法值回滚, 不写脏数据(不再卡最小 16, 对齐官方:
        [self syncOutputFieldsFromModel];  // 官方无最小尺寸限制, 偶数到 2 都允许, 奇数由"被2整除"红框拦)
        return;
    }
    int w = (int)round(self.model.outputSize.width);
    int h = (int)round(self.model.outputSize.height);
    // 比例联动算出的另一边取整到偶数(就近): 避免联动自己引入「必须可被 2 整除」报错;
    // 用户手输的那一边保留原值, 由校验红框提示。
    if (isWidth) {
        w = v;
        if (self.aspectLocked && self.aspectRatio > 0) h = (int)(round(w / self.aspectRatio / 2.0) * 2.0);
    } else {
        h = v;
        if (self.aspectLocked && self.aspectRatio > 0) w = (int)(round(h * self.aspectRatio / 2.0) * 2.0);
    }
    // 不再自动改成偶数(对齐官方): 奇数值保留显示, updateResolutionWarning 弹
    // 「分辨率必须可以被 2 整除」红框并禁用导出, 由用户自己改。
    CGSize next = CGSizeMake(w, h);
    if (!CGSizeEqualToSize(next, self.model.outputSize)) self.model.outputSize = next;
    [self syncOutputFieldsFromModel];
}

- (void)bitrateEditingEnded {
    if (self.model == nil) return;
    int v = [self.bitrateField.text intValue];
    self.model.exportBitrateMbps = (v > 0) ? v : 0;   // 0 = 自动
}

- (void)audioTapped {
    self.audioCheckbox.selected = !self.audioCheckbox.selected;
    if (self.model) self.model.exportAudio = self.audioCheckbox.selected;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
