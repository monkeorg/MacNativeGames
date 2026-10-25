#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Opaque, immutable observation from one CanopyProfiles instance. This is a
/// label-only metadata repair, never a save/profile identity or schema rollback.
@interface CanopyProfileLabelRepair : NSObject
@property(nonatomic, readonly, copy) NSString *titleID;
@property(nonatomic, readonly, copy) NSString *selectedID;
@property(nonatomic, readonly, copy) NSDictionary<NSString *,id> *candidateSnapshot;
@property(nonatomic, readonly) NSUInteger repairedLabelCount;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Logical selection metadata only. Never reads/copies account or save bytes.
/// Stateless, bounded reads; mutations serialize with a private registry lock.
/// The UI commits selection on main only after opening the actual SaveStore.
@interface CanopyProfiles : NSObject
- (instancetype)initWithDirectoryURL:(NSURL *)directory;
/// Missing registry/title is the exact existing "default" ID, without a write.
/// Returns selectedID and profiles [{identifier,displayName}]. Unknown schemas
/// and unsafe/corrupt metadata are preserved and refused, never reset.
- (nullable NSDictionary<NSString *,id> *)snapshotForTitleID:(NSString *)title error:(NSError **)error;
/// Registers an empty logical identity without selecting it or making folders.
- (nullable NSString *)createProfileWithName:(NSString *)name titleID:(NSString *)title error:(NSError **)error;
/// Caller must hold the main-thread pre-Play/global-session exclusion. Expected
/// selection prevents an old screen from overwriting another screen's choice.
/// Failure retains the live old store. A post-rename sync error can leave the
/// new registry published: publicationUncertain is YES; reload before Play.
- (BOOL)selectProfileID:(NSString *)identifier titleID:(NSString *)title
     expectedSelection:(NSString *)expected error:(NSError **)error;
/// Existing directory/current/previous required. Only exact known-v1 native
/// JSON, valid IDs/order/selection and malformed NSString display labels qualify.
/// Other title rows and all previous metadata must be valid. Unknown/ambiguous
/// schemas, fields, types, IDs, missing sources and missing labels are refused.
/// Observation alone changes no registry or profile data.
- (nullable CanopyProfileLabelRepair *)prepareLabelRepairForTitleID:(NSString *)title error:(NSError **)error;
/// Caller holds the same main-thread pre-Play/global-session exclusion as
/// selectProfileID, with the real store already open for expectedSelection.
/// Both observed files and directory identity must still match under the lock.
/// Quarantines original current metadata (maximum eight files, 64 KiB each) in
/// the existing metadata directory before publication; previous stays unchanged.
/// A post-rename sync failure reports publicationUncertain: reload before Play.
- (BOOL)applyLabelRepair:(CanopyProfileLabelRepair *)repair
      expectedSelection:(NSString *)expected error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
