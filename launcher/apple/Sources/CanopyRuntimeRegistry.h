#import <Foundation/Foundation.h>
#import "CanopyRuntime.h"
NS_ASSUME_NONNULL_BEGIN
/// Internal dispatch only. Registry rows are actual compiled descriptors, not
/// metadata profiles. Existing TOTK ABI3 stays on its original Runtime path.
FOUNDATION_EXPORT NSDictionary * _Nullable CanopyAppleTrustedProfile(NSString *titleID);
FOUNDATION_EXPORT BOOL CanopyRuntimeProcessOccupied(void);
FOUNDATION_EXPORT BOOL CanopyRuntimeClaimProcess(CanopyRuntime *owner);
/// Pre-entry only; after native entry the owner is deliberately retained.
FOUNDATION_EXPORT void CanopyRuntimeReleaseBeforeEntry(CanopyRuntime *owner);
@interface CanopyAppleRuntime : CanopyRuntime
@end
NS_ASSUME_NONNULL_END
