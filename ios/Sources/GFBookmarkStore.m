#import "GFBookmarkStore.h"

@implementation GFBookmarkStore

// 解析一条书签数据; 失效(stale)视为无效返回 nil。
static NSURL *GFResolveBookmark(id bookmark) {
    if (![bookmark isKindOfClass:[NSData class]]) {
        return nil;
    }
    BOOL stale = NO;
    NSURL *url = [NSURL URLByResolvingBookmarkData:(NSData *)bookmark
                                           options:NSURLBookmarkResolutionWithoutUI
                                     relativeToURL:nil
                               bookmarkDataIsStale:&stale
                                             error:nil];
    return (url != nil && !stale) ? url : nil;
}

+ (void)addFolderBookmark:(NSURL *)url toListKey:(NSString *)key {
    NSError *err = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:&err];
    if (bookmark == nil) {
        NSLog(@"[GFBookmarkStore] 目录书签创建失败(%@): %@", key, err);
        return;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *existing = [defaults arrayForKey:key] ?: @[];
    NSMutableArray<NSData *> *kept = [NSMutableArray array];
    for (id old in existing) {
        NSURL *oldURL = GFResolveBookmark(old);
        if (oldURL == nil || [oldURL.absoluteString isEqualToString:url.absoluteString]) {
            continue;   // 失效书签清理 / 同目录去重
        }
        [kept addObject:(NSData *)old];
    }
    [kept addObject:bookmark];
    [defaults setObject:kept forKey:key];
}

+ (NSArray<NSURL *> *)resolveFoldersForListKey:(NSString *)key {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (id bookmark in [NSUserDefaults.standardUserDefaults arrayForKey:key]) {
        NSURL *url = GFResolveBookmark(bookmark);
        if (url != nil) {
            [urls addObject:url];
        }
    }
    return urls;
}

+ (void)setFolderBookmark:(NSURL *)url forKey:(NSString *)key {
    NSError *err = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:&err];
    if (bookmark == nil) {
        NSLog(@"[GFBookmarkStore] 目录书签创建失败(%@): %@", key, err);
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:key];
}

+ (NSURL *)resolveFolderForKey:(NSString *)key {
    NSURL *url = GFResolveBookmark([NSUserDefaults.standardUserDefaults objectForKey:key]);
    if (url == nil) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
    }
    return url;
}

@end
