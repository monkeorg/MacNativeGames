#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSUInteger,CanopyProviderCacheKind){CanopyProviderCacheMKShader=1,CanopyProviderCacheRomFS=2};
/// Worker-only, serialized fixed-root management. cacheRoot is the private
/// global Canopy/Caches directory. No executable/content verification claim.
@interface CanopyProviderCache : NSObject
- (instancetype)initWithCacheRootURL:(NSURL *)root;
/// Bounded real namespace entries before filtering. Usage is logical lengths;
/// unknown/staged/unsafe entries are preserved and reported through error.
- (nullable NSArray<NSDictionary<NSString *,id> *> *)entriesForTitleID:(NSString *)title error:(NSError * _Nullable * _Nullable)error;
- (BOOL)recoverPendingRemovalsForTitleID:(NSString *)title error:(NSError * _Nullable * _Nullable)error;
- (BOOL)clearRuntimeForTitleID:(NSString *)title identity:(NSString *)identity error:(NSError * _Nullable * _Nullable)error;
- (BOOL)removeKind:(CanopyProviderCacheKind)kind identifier:(NSString *)identifier titleID:(NSString *)title error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
