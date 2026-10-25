#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Derives a private asset folder from an exact verified prepared generation.
/// Public methods/progress/completion belong to the main thread. URLs must be
/// canonical physical paths in the app's private storage (no symlink ancestors).
/// Resolve the trusted Application Support base before appending private store
/// and cache names; Apple's /var paths can resolve under /private/var.
/// A returned folder is verified data, never executable capability or gameplay.
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
@end
NS_ASSUME_NONNULL_END
