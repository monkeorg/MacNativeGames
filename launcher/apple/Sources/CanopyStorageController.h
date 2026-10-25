#import <UIKit/UIKit.h>
#import "CanopyStorage.h"
NS_ASSUME_NONNULL_BEGIN
@interface CanopyStorageController : UITableViewController
- (instancetype)initWithPreparedRootURL:(NSURL *)prepared cacheRootURL:(NSURL *)cache;
/// Optional actual host availability check, evaluated on main before mutation.
/// Reject while preparation/catalog reload/native session owns the library.
/// It supplements native locks/leases and never releases a session/save seal.
@property(nonatomic, copy, nullable) BOOL (^mutationAllowed)(void);
@end
CanopyStorageController *CanopyMakeStorageController(NSURL *preparedRoot, NSURL *cacheRoot);
NS_ASSUME_NONNULL_END
