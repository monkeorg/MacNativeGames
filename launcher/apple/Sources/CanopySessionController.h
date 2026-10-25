#import <UIKit/UIKit.h>
#import "CanopyControllers.h"
#import "CanopySettings.h"
#import "CanopySaveStore.h"

NS_ASSUME_NONNULL_BEGIN
/// Real trusted-host session. Public builds have no eligible title profile.
/// The caller transfers save-operation ownership to this controller/queue.
@interface CanopySessionController : UIViewController
/// Main-thread read-only ownership gate; never releases a native lease/seal.
+ (BOOL)nativeSessionOwnsProcess;
- (nullable instancetype)initWithEntry:(NSDictionary *)entry preparedRootURL:(NSURL *)root
                             settings:(CanopySettings *)settings controllers:(CanopyControllers *)controllers
                            saveStore:(CanopySaveStore *)saves saveQueue:(dispatch_queue_t)queue
                             cacheURL:(NSURL *)cache error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
