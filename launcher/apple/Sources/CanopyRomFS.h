#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef void (^CanopyRomFSWorkerProgress)(NSString *phase,uint64_t done,uint64_t total);
/// Derives a private asset folder from an exact verified prepared generation.
/// Public methods/progress/completion belong to the main thread. URLs must be
/// canonical physical paths in the app's private storage (no symlink ancestors).
/// Resolve the trusted Application Support base before appending private store
/// and cache names; Apple's /var paths can resolve under /private/var.
/// A returned folder is verified data, never executable capability or gameplay.
/// Strongly retain through native guest lifetime. Holds a genuine shared flock
/// on the cache sidecar and an open descriptor for the exact published folder.
/// This observes ownership, not guest teardown or permission to delete content.
@interface CanopyRomFSLease : NSObject
@property(nonatomic, readonly) NSURL *folderURL;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

@interface CanopyRomFS : NSObject
@property(nonatomic, readonly) BOOL busy;
@property(nonatomic, copy, nullable) void (^progress)(NSString *phase, uint64_t done, uint64_t total);
- (instancetype)initWithPreparedRootURL:(NSURL *)prepared derivedRootURL:(NSURL *)derived;
/// Exact generation and recipe determine the immutable private folder name.
/// Existing folders are reused only after source pin/verification, native RomFS
/// indexing and byte-for-byte file plus exact tree validation. Corruption is
/// refused without replacing/deleting the existing cache. Failed fresh work is
/// unpublished staging and can be retried; no source, keys or saves are modified.
- (BOOL)materializeTitleID:(uint64_t)title generationID:(NSString *)generation
               completion:(void (^)(NSURL * _Nullable folder, NSError * _Nullable error))completion;
/// Once atomic publication begins, later cancellation does not undo it and
/// completion may report success. Completion is the outcome authority.
- (void)cancel;
/// Synchronous worker-only entry to the SAME materializer. The caller has fully
/// verified this exact image and retains its prepared-generation shared lease
/// during the operation AND for the returned folder's native use. The borrowed
/// image descriptor is duplicated; no preparation JSON grants this precondition.
/// Exact generation+RFRecipe determine reuse, independently of app/device/seed.
/// Progress/cancellation run on the calling worker and must not reenter this API.
+ (nullable CanopyRomFSLease *)materializeVerifiedImageFD:(int)image
    titleID:(uint64_t)title generationID:(NSString *)generation
    derivedRootURL:(NSURL *)derived cancelled:(BOOL (^)(void))cancelled
    progress:(nullable CanopyRomFSWorkerProgress)progress
    error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
