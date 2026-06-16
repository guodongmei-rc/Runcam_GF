#import "PlaybackControlRowView.h"
#import "GFViewKit.h"

@interface PlaybackControlRowView ()
@property (nonatomic, strong, readwrite) UIButton *playPauseButton;
@property (nonatomic, strong, readwrite) UIButton *stabilizationButton;
@end

@implementation PlaybackControlRowView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.playPauseButton = [GFViewKit primaryButtonWithTitle:@"暂停"];
        self.playPauseButton.translatesAutoresizingMaskIntoConstraints = NO;
        self.playPauseButton.enabled = NO;

        self.stabilizationButton = [GFViewKit primaryButtonWithTitle:@"开启防抖"];
        self.stabilizationButton.translatesAutoresizingMaskIntoConstraints = NO;
        self.stabilizationButton.enabled = NO;

        self.axis = UILayoutConstraintAxisHorizontal;
        self.distribution = UIStackViewDistributionFillEqually;
        self.spacing = 12.0;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self addArrangedSubview:self.playPauseButton];
        [self addArrangedSubview:self.stabilizationButton];
    }
    return self;
}

@end
