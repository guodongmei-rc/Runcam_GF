#import "GFSegmentedTabs.h"
#import "GFTheme.h"

@interface GFSegmentedTabs ()
@property (nonatomic, strong) NSMutableArray<UIImageView *> *iconViews;
@property (nonatomic, strong) NSMutableArray<UILabel *> *labelViews;
@property (nonatomic, strong) NSMutableArray<UIView *> *indicatorViews;
@end

@implementation GFSegmentedTabs

- (instancetype)initWithTitles:(NSArray<NSString *> *)titles
                     iconNames:(NSArray<NSString *> *)iconNames {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _selectedSegmentIndex = 0;
        _iconViews = [NSMutableArray array];
        _labelViews = [NSMutableArray array];
        _indicatorViews = [NSMutableArray array];

        self.backgroundColor = [GFTheme secondaryBackgroundColor];
        self.layer.cornerRadius = 5.0;
        self.clipsToBounds = YES;

        // 等宽横向排列
        UIStackView *row = [[UIStackView alloc] init];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionFillEqually;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.topAnchor constraintEqualToAnchor:self.topAnchor],
            [row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];

        for (NSUInteger i = 0; i < titles.count; i++) {
            UIView *seg = [[UIView alloc] init];
            seg.tag = (NSInteger)i;
            seg.userInteractionEnabled = YES;

            UIImageView *icon = [[UIImageView alloc] init];
            icon.contentMode = UIViewContentModeScaleAspectFit;
            icon.tintColor = [GFTheme textColor];
            icon.translatesAutoresizingMaskIntoConstraints = NO;
            if (@available(iOS 13.0, *)) {
                NSString *name = (i < iconNames.count) ? iconNames[i] : @"";
                UIImage *img = [UIImage systemImageNamed:name];
                icon.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            }

            UILabel *label = [[UILabel alloc] init];
            label.text = titles[i];
            label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
            label.textColor = [GFTheme textColor];

            UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[icon, label]];
            content.axis = UILayoutConstraintAxisHorizontal;
            content.alignment = UIStackViewAlignmentCenter;
            content.spacing = 6.0;
            content.translatesAutoresizingMaskIntoConstraints = NO;
            [seg addSubview:content];

            UIView *indicator = [[UIView alloc] init];
            indicator.backgroundColor = UIColor.clearColor;
            indicator.translatesAutoresizingMaskIntoConstraints = NO;
            [seg addSubview:indicator];

            [NSLayoutConstraint activateConstraints:@[
                [content.centerXAnchor constraintEqualToAnchor:seg.centerXAnchor],
                [content.centerYAnchor constraintEqualToAnchor:seg.centerYAnchor],
                [icon.widthAnchor constraintEqualToConstant:20.0],
                [icon.heightAnchor constraintEqualToConstant:20.0],
                [indicator.leadingAnchor constraintEqualToAnchor:seg.leadingAnchor],
                [indicator.trailingAnchor constraintEqualToAnchor:seg.trailingAnchor],
                [indicator.bottomAnchor constraintEqualToAnchor:seg.bottomAnchor],
                [indicator.heightAnchor constraintEqualToConstant:3.0],
            ]];

            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
            [seg addGestureRecognizer:tap];

            [row addArrangedSubview:seg];
            [_iconViews addObject:icon];
            [_labelViews addObject:label];
            [_indicatorViews addObject:indicator];
        }
        [self applySelection];
    }
    return self;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, 48.0);
}

- (void)onTap:(UITapGestureRecognizer *)g {
    NSInteger idx = g.view.tag;
    if (idx != _selectedSegmentIndex) {
        self.selectedSegmentIndex = idx;
        [self sendActionsForControlEvents:UIControlEventValueChanged];
    }
}

- (void)setSelectedSegmentIndex:(NSInteger)selectedSegmentIndex {
    _selectedSegmentIndex = selectedSegmentIndex;
    [self applySelection];
}

// 对齐安卓: 文字/图标均白色, 未选中整体变暗(alpha 0.5), 仅选中段主题色下划线。
- (void)applySelection {
    for (NSUInteger i = 0; i < self.labelViews.count; i++) {
        BOOL on = ((NSInteger)i == _selectedSegmentIndex);
        self.labelViews[i].alpha = on ? 1.0 : 0.5;
        self.iconViews[i].alpha = on ? 1.0 : 0.5;
        self.indicatorViews[i].backgroundColor = on ? [GFTheme primaryColor] : UIColor.clearColor;
    }
}

@end
