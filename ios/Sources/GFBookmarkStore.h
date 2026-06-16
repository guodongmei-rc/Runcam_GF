#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 安全作用域目录书签持久化(NSUserDefaults)。
/// 两种形态: 列表键(多目录, 去重 + 顺带清理失效书签)与单键(覆盖式)。
/// 只负责书签的存取与解析; startAccessingSecurityScopedResource / FFI 注册等
/// 副作用由调用方处理。
@interface GFBookmarkStore : NSObject

/// 目录书签追加进列表键(同目录去重, 失效书签顺带清理)。
+ (void)addFolderBookmark:(NSURL *)url toListKey:(NSString *)key;

/// 解析列表键里所有仍有效的目录 URL(失效项跳过, 不修改存储)。
+ (NSArray<NSURL *> *)resolveFoldersForListKey:(NSString *)key;

/// 目录书签存入单键(覆盖式)。
+ (void)setFolderBookmark:(NSURL *)url forKey:(NSString *)key;

/// 解析单键目录 URL; 书签失效/缺失时自动清键并返回 nil。
+ (nullable NSURL *)resolveFolderForKey:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
