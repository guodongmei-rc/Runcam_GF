#import "GyroflowLauncher.h"
#import "ViewController.h"

#pragma mark - 内部：关闭按钮

@interface _GFCloseButton : UIButton
@property (nonatomic, weak) UIViewController *targetVC;
@end

@implementation _GFCloseButton

+ (instancetype)buttonForDismissing:(UIViewController *)target {
    _GFCloseButton *btn = [_GFCloseButton buttonWithType:UIButtonTypeSystem];
    btn.targetVC = target;
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    UIImage *img = [UIImage systemImageNamed:@"xmark.circle.fill"
                            withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightSemibold]];
    [btn setImage:img forState:UIControlStateNormal];
    btn.tintColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    btn.layer.shadowColor = UIColor.blackColor.CGColor;
    btn.layer.shadowOpacity = 0.5;
    btn.layer.shadowRadius = 3;
    btn.layer.shadowOffset = CGSizeMake(0, 1);
    [btn addTarget:btn action:@selector(_dismiss) forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (void)_dismiss {
    // 与 open 配对：iOS push 反向(左→右滑出)，对齐 Flutter 路由 pop 观感
    UIWindow *window = self.targetVC.view.window;
    if (window != nil) {
        CATransition *transition = [CATransition animation];
        transition.duration = 0.3;
        transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        transition.type = kCATransitionPush;
        transition.subtype = kCATransitionFromLeft;
        [window.layer addAnimation:transition forKey:kCATransition];
        [self.targetVC dismissViewControllerAnimated:NO completion:nil];
    } else {
        [self.targetVC dismissViewControllerAnimated:YES completion:nil];
    }
}

@end

#pragma mark - GyroflowLauncher

@implementation GyroflowLauncher

+ (UIViewController *)makeRootViewController {
    ViewController *vc = [[ViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    vc.modalPresentationCapturesStatusBarAppearance = YES;
    // 强制 Dark：避免系统亮色模式下 GF 界面背景与 Flutter 黑底主题撕裂
    if (@available(iOS 13.0, *)) {
        vc.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }

    // 触发 viewDidLoad，让 view 与子控件都先建好，再叠加关闭按钮
    (void)vc.view;

    _GFCloseButton *btn = [_GFCloseButton buttonForDismissing:vc];
    [vc.view addSubview:btn];
    [NSLayoutConstraint activateConstraints:@[
        [btn.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:6],
        [btn.leadingAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [btn.widthAnchor constraintEqualToConstant:36],
        [btn.heightAnchor constraintEqualToConstant:36],
    ]];

    return vc;
}

@end