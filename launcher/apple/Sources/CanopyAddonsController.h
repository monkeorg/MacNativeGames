#import <UIKit/UIKit.h>
#import "CanopySettings.h"
NS_ASSUME_NONNULL_BEGIN
/// Main-thread UI owner. Catalog verification and installation run on workers.
/// The base entry must be a real verified catalog entry; the installer rechecks
/// this exact title/generation under its native store lock before publication.
@interface CanopyAddonsController : UITableViewController
- (instancetype)initWithBaseEntry:(NSDictionary<NSString *,id> *)base
    preparedRootURL:(NSURL *)prepared globalCacheRootURL:(NSURL *)cache settings:(CanopySettings *)settings;
/// Optional host gate for other preparations/catalog operations/native leases.
/// Evaluated again before starting installation or a storage mutation; never
/// releases a save seal, account identity or active native session.
@property(nonatomic,copy,nullable) BOOL (^mutationAllowed)(void);
@end
CanopyAddonsController *CanopyMakeAddonsController(NSDictionary<NSString *,id> *verifiedBaseEntry,
    NSURL *preparedRoot,NSURL *globalCacheRoot,CanopySettings *settings);
NS_ASSUME_NONNULL_END
