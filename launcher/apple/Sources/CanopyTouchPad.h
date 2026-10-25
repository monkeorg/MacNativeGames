#import <UIKit/UIKit.h>
#include "mng_touch.h"
NS_ASSUME_NONNULL_BEGIN
/// Session-local direct-touch controls. Never calls process-global runtime APIs.
/// VoiceOver stick directions hold until Neutral, accessibility focus loss, direct
/// touch takeover, or input cancellation. Captured/inactive views reject actions.
/// Cancellation invalidates the current focus session; leave and refocus the
/// stick before sending another direction. Cached elements retain stable identity.
@interface CanopyTouchPad : UIView
- (void)cancelInput;
- (void)consumeInput:(struct mng_input *)input;
@end
NS_ASSUME_NONNULL_END
