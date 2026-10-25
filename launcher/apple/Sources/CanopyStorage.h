#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSUInteger, CanopyStorageAction) {
    CanopyStorageVerifyGeneration, CanopyStorageSelectGeneration,
    CanopyStorageRemoveGeneration, CanopyStorageDiscardJob,
    CanopyStorageClearShaderRuntime, CanopyStorageRemoveShaderIdentity
};
typedef void (^CanopyStorageCompletion)(NSDictionary<NSString *,id> *snapshot, NSError * _Nullable error);

/// Main-thread owner; all filesystem/hash work runs on its private serial queue.
/// Roots are app-owned private physical directories. cacheRoot is global
/// Canopy/Caches; shader roots are <titleID>/shader-identities below it.
/// No profiles, saves, accounts, source inputs or unrelated cache kinds are read.
@interface CanopyStorage : NSObject
@property(nonatomic, readonly) BOOL busy;
/// generations/jobs/shaders/issues arrays, complete flag and optional operation.
/// Lists are capped128 real directory entries before filtering, with128 rows
/// per category. Unknown/corrupt entries are preserved. Initial generation sizes
/// are unknown; explicit verification obtains logical asset bytes, not allocation.
@property(nonatomic, readonly) NSDictionary<NSString *,id> *snapshot;
- (instancetype)initWithPreparedRootURL:(NSURL *)prepared cacheRootURL:(NSURL *)cache;
- (BOOL)reloadWithCompletion:(CanopyStorageCompletion)completion;
/// Explicit worker resolution, never a list-time full-game hash. Completes on
/// main after busy clears. Exact native intent and exact identified base are
/// reverified; no current-generation substitution or imported routing approval.
/// Route keys: jobIdentifier/applicationID/baseGenerationID/addonTitleID/
/// verifiedBaseEntry. Missing legacy intent is an error for this typed route.
- (BOOL)resolveAddonResumeJob:(NSString *)jobIdentifier
    completion:(void (^)(NSDictionary<NSString *,id> * _Nullable route,NSError * _Nullable error))completion;
/// Exact lowercase64hex generation/cache IDs or32hex job IDs. Jobs take nil
/// title; all other actions require exact nonzero16hex title. Existing native
/// store/cache APIs enforce current/previous/pins/leases at the point of mutation.
/// Completion is authoritative, even after a controller requests navigation.
/// On I/O failures the operation includes a fresh current read when applicable;
/// never infer that a failed publication/removal left its target unchanged.
- (BOOL)performAction:(CanopyStorageAction)action identifier:(NSString *)identifier
    titleID:(nullable NSString *)title completion:(CanopyStorageCompletion)completion;
@end
NS_ASSUME_NONNULL_END
