#import <UIKit/UIKit.h>
#include "mng_touch.h"
NS_ASSUME_NONNULL_BEGIN
/// Session-local direct-touch controls. Never calls process-global runtime APIs.
@interface CanopyTouchPad : UIView
- (void)cancelInput;
- (void)consumeInput:(struct mng_input *)input;
@end
NS_ASSUME_NONNULL_END
