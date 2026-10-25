#import <Foundation/Foundation.h>
#import "CanopySaveStore.h"
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN
/// Reviewed compiled metadata only; neither function grants native execution.
FOUNDATION_EXPORT NSString * _Nullable CanopyGameNameForTitleID(NSString *titleID);
/// revision/identified must come from the verified native catalog result.
FOUNDATION_EXPORT NSString *CanopyGameVersionLabel(NSString *titleID, uint32_t revision, BOOL identified);
/// Closed mapping to an existing structural validator. No edit validator or
/// runtime/imported metadata can register a callback through this interface.
FOUNDATION_EXPORT CanopySaveValidator _Nullable CanopyGameSaveValidatorForTitleID(NSString *titleID);
NS_ASSUME_NONNULL_END
