#import <UIKit/UIKit.h>
#import "CanopyStorage.h"
NS_ASSUME_NONNULL_BEGIN
@interface CanopyStorageController : UITableViewController
- (instancetype)initWithPreparedRootURL:(NSURL *)prepared cacheRootURL:(NSURL *)cache;
/// Optional actual host availability check, evaluated on main before mutation.
/// Reject while preparation/catalog reload/native session owns the library.
/// It supplements native locks/leases and never releases a session/save seal.
@property(nonatomic, copy, nullable) BOOL (^mutationAllowed)(void);
/// Re-select inputs for this exact unfinished job; native fingerprint checks
/// remain authoritative. Contains no URLs, keys or inferred source identity.
@property(nonatomic, copy, nullable) void (^resumePreparation)(NSString *jobIdentifier);
/// Exact add-on route from the native verified resolver, never an inferred
/// generic job kind. Consumer must recheck its own library/session exclusion.
@property(nonatomic, copy, nullable) void (^resumeAddonPreparation)(NSDictionary<NSString *,id> *route);
/// Latest actual backend observation; no filesystem work is performed here.
@property(nonatomic, readonly) NSDictionary<NSString *,id> *diagnosticSnapshot;
@end
CanopyStorageController *CanopyMakeStorageController(NSURL *preparedRoot, NSURL *cacheRoot);
NS_ASSUME_NONNULL_END
