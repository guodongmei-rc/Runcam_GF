#import "GFTheme.h"

@implementation GFTheme

+ (UIColor *)backgroundColor {
    return UIColor.blackColor;
}

+ (UIColor *)primaryColor {
    return [UIColor colorWithRed:255.0/255.0 green:107.0/255.0 blue:0.0/255.0 alpha:1.0];
}

+ (UIColor *)secondaryBackgroundColor {
    return [UIColor colorWithRed:34.0/255.0 green:34.0/255.0 blue:34.0/255.0 alpha:1.0];
}

+ (UIColor *)textColor {
    return UIColor.whiteColor;
}

+ (UIColor *)secondaryTextColor {
    return [UIColor colorWithWhite:1.0 alpha:0.7];
}

+ (UIColor *)dividerColor {
    return [UIColor colorWithRed:42.0/255.0 green:42.0/255.0 blue:42.0/255.0 alpha:1.0];
}

@end