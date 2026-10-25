#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
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
@end
NS_ASSUME_NONNULL_END
