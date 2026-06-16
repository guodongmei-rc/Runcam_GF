#import "GFExportUtils.h"

@implementation GFExportUtils

+ (NSURL *)uniqueURLInFolder:(NSURL *)folder forName:(NSString *)name {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:[folder URLByAppendingPathComponent:name].path]) {
        return [folder URLByAppendingPathComponent:name];
    }
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(_\\d+)?(\\.[A-Za-z0-9]+)$"
                                                                        options:0
                                                                          error:nil];
    NSString *candidate = name;
    for (int i = 1; i < 1000; i++) {
        candidate = [re stringByReplacingMatchesInString:name
                                                 options:0
                                                   range:NSMakeRange(0, name.length)
                                            withTemplate:[NSString stringWithFormat:@"_%d$2", i]];
        if (![fm fileExistsAtPath:[folder URLByAppendingPathComponent:candidate].path]) {
            break;
        }
    }
    return [folder URLByAppendingPathComponent:candidate];
}

+ (void)codecForIndex:(int)idx
            codecType:(AVVideoCodecType _Nullable *)outCodec
             fileType:(AVFileType _Nullable *)outFileType
            extension:(NSString *_Nullable *)outExt {
    AVVideoCodecType codec; AVFileType ft; NSString *ext;
    switch (idx) {
        case 0:  codec = AVVideoCodecTypeH264;           ft = AVFileTypeMPEG4;          ext = @"mp4"; break;
        case 2:  codec = AVVideoCodecTypeAppleProRes422; ft = AVFileTypeQuickTimeMovie; ext = @"mov"; break;
        case 1:
        default: codec = AVVideoCodecTypeHEVC;           ft = AVFileTypeMPEG4;          ext = @"mp4"; break;
    }
    if (outCodec)    *outCodec    = codec;
    if (outFileType) *outFileType = ft;
    if (outExt)      *outExt      = ext;
}

+ (uint32_t)stabilizedHeightForWidth:(uint32_t)width {
    uint32_t height = (uint32_t)llround((double)width * 9.0 / 16.0);
    if ((height % 2) != 0) {
        height -= 1;
    }
    return MAX(height, 2);
}

@end
