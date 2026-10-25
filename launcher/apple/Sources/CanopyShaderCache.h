#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
NS_ASSUME_NONNULL_BEGIN
/// Keeps the identity's shared lease open. Retain through the native session;
/// active caches cannot be cleared/deleted. Contains no executable capability.
@interface CanopyShaderCacheLease : NSObject
@property(nonatomic,readonly) NSURL *seedURL;
@property(nonatomic,readonly) NSURL *cacheURL;
@property(nonatomic,readonly) NSString *identityHash;
/// Bytes actually copied/reused by this importer, excluding legacy runtime
/// seed-import work and filesystem allocation/clone savings.
@property(nonatomic,readonly) NSDictionary<NSString *,NSNumber *> *metrics;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Synchronous worker-thread API. Caller serializes operations. Callbacks run
/// in normal worker context and must not reenter/mutate source/cache. RootURL
/// must be a canonical physical private path; only its final component is made.
@interface CanopyShaderCache : NSObject
- (instancetype)initWithRootURL:(NSURL *)root;
/// Obtain from the actual selected Metal device, never imported profile JSON.
/// Device details remain private; diagnostics expose only the identity hash.
+ (nullable NSDictionary<NSString *,id> *)deviceIdentityForDevice:(id<MTLDevice>)device
    error:(NSError * _Nullable * _Nullable)error;
/// Manifest SHA and chain are compiled trusted-host pins, not values approved
/// by imported metadata. Source RomFS hash/title bind the approved generation.
/// Existing immutable seeds are rehashed and compared before reuse. Runtime
/// output is separate and mutable; its contents are not seed-authenticated.
- (nullable CanopyShaderCacheLease *)prepareSeedURL:(NSURL *)source
    titleID:(NSString *)title sourceRomFSSHA256:(NSString *)romfs
    expectedManifestSHA256:(NSString *)manifestSHA expectedChain:(NSString *)chain
    deviceIdentity:(NSDictionary<NSString *,id> *)device
    cancelled:(BOOL (^ _Nullable)(void))cancelled
    progress:(void (^ _Nullable)(NSString *,uint64_t,uint64_t))progress
    error:(NSError * _Nullable * _Nullable)error;
- (nullable NSArray<NSString *> *)identitiesForTitleID:(NSString *)title
    error:(NSError * _Nullable * _Nullable)error;
/// Reconcile only this cache's durable recorded removal under its operation
/// lock. Opens an existing private root; absent retirement metadata is a no-op.
/// Unknown/corrupt records, replaced identities and active leases are refused.
- (BOOL)recoverPendingRemovalWithError:(NSError * _Nullable * _Nullable)error;
- (nullable NSDictionary<NSString *,NSNumber *> *)usageForIdentityHash:(NSString *)identity
    titleID:(NSString *)title error:(NSError * _Nullable * _Nullable)error;
/// Refuse active leases. Clear preserves the immutable seed; remove deletes
/// only the exact owned identity. Never traverses symlinks or touches saves.
/// Removal errors may occur after retirement/deletion; retry or reload invokes
/// exact-record recovery. Unrecorded partial identities are never deleted.
- (BOOL)clearRuntimeForIdentityHash:(NSString *)identity titleID:(NSString *)title
    error:(NSError * _Nullable * _Nullable)error;
- (BOOL)removeIdentityHash:(NSString *)identity titleID:(NSString *)title
    error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
