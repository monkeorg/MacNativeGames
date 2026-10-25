#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// One real native preparation job. Public methods and notifications belong on
/// the main thread; file coordination/decryption/store work uses a private queue.
@interface CanopyPreparation : NSObject
@property(nonatomic, readonly) BOOL busy;
@property(nonatomic, readonly, nullable) NSString *jobIdentifier;
@property(nonatomic, copy, nullable) void (^progress)(NSString *phase, uint64_t done, uint64_t total);
- (instancetype)initWithPreparedRootURL:(NSURL *)directory;
/// Optional jobIdentifier resumes that 32-lowercase-hex staging job. No source
/// URL, bookmark, key or payload is persisted outside the private native store.
- (BOOL)startSourceURL:(NSURL *)source keysURL:(NSURL *)keys
        jobIdentifier:(nullable NSString *)identifier
           completion:(void (^)(NSDictionary<NSString *, id> * _Nullable result,
                                NSError * _Nullable error))completion;
/// Selects the highest declared update revision and publishes composed assets.
/// A nil update keeps base-only preparation. Both input URLs are coordinated.
- (BOOL)startSourceURL:(NSURL *)source updateURL:(nullable NSURL *)update
              keysURL:(NSURL *)keys jobIdentifier:(nullable NSString *)identifier
           completion:(void (^)(NSDictionary<NSString *, id> * _Nullable result,
                                NSError * _Nullable error))completion;
/// Optional exact verified-generation reuse. Both IDs must be absent or valid
/// together (nonzero lowercase16hex title and lowercase64hex generation).
/// The source is fully verified/leased before staging; commit still enforces
/// the resulting title/application owner. Existing invalid candidates abort.
/// Result and error.userInfo include ioMetrics for observed logical payload I/O;
/// these counters do not measure physical disk allocation or saved space.
- (BOOL)startSourceURL:(NSURL *)source keysURL:(NSURL *)keys
    reuseTitleID:(nullable NSString *)title reuseGenerationID:(nullable NSString *)generation
    jobIdentifier:(nullable NSString *)identifier
    completion:(void (^)(NSDictionary<NSString *,id> * _Nullable,NSError * _Nullable))completion;
- (BOOL)startSourceURL:(NSURL *)source updateURL:(nullable NSURL *)update keysURL:(NSURL *)keys
    reuseTitleID:(nullable NSString *)title reuseGenerationID:(nullable NSString *)generation
    jobIdentifier:(nullable NSString *)identifier
    completion:(void (^)(NSDictionary<NSString *,id> * _Nullable,NSError * _Nullable))completion;
/// Supported NCA folder (keys required) or exefs/ + romfs/romfs.bin layout
/// (no keys). Identity is a canonical consumed-member inventory, not a file SHA.
- (BOOL)startFolderURL:(NSURL *)folder keysURL:(nullable NSURL *)keys
        jobIdentifier:(nullable NSString *)identifier
           completion:(void (^)(NSDictionary<NSString *, id> * _Nullable result,
                                NSError * _Nullable error))completion;
/// Actual full-install add-on installation. Identifiers are exact lowercase
/// hexadecimal (owner/add-on16, base generation64). The native installer
/// rehashes that base generation and derives its known version under its lock;
/// caller metadata never supplies version authority. No game DLC activation.
/// Error userInfo preserves publicationUncertain/reloadRequired/currentReadable
/// and currentGenerationID (observed pointer only, not an execution assertion).
- (BOOL)startAddonURL:(NSURL *)source keysURL:(NSURL *)keys
       applicationID:(NSString *)applicationID baseGenerationID:(NSString *)baseGenerationID
        addonTitleID:(NSString *)addonTitleID jobIdentifier:(nullable NSString *)identifier
          completion:(void (^)(NSDictionary<NSString *, id> * _Nullable result,
                               NSError * _Nullable error))completion;
/// Requests cancellation, including native verification. Completion is the
/// authority: a request after publication may still return a successful result.
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
