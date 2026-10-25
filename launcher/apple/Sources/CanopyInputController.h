#import <UIKit/UIKit.h>
#import "CanopyControllers.h"
NS_ASSUME_NONNULL_BEGIN
/// Main-thread, session-local frontend. Host commands never become guest bits.
@interface CanopyInputController : NSObject
@property(nonatomic, readonly) unsigned localPlayer;
@property(nonatomic, readonly) BOOL hasLocalInput;
- (instancetype)initWithHostController:(UIViewController *)host hostView:(UIView *)view
                           controllers:(CanopyControllers *)controllers localPlayer:(unsigned)player;
/// Validated title preferences. Returns actual per-key apply/effective outcomes.
- (NSDictionary<NSString *,NSDictionary *> *)applySettings:(NSDictionary *)settings;
/// Both transitions clear pending inputs and invalidate old hardware callbacks.
- (void)setCaptured:(BOOL)captured;
- (BOOL)wantsPointerLock;
- (BOOL)acceptsMouseInput;
/// Return YES only for a handled guest action. Escape/Command remain with UIKit.
- (BOOL)handlePress:(UIPress *)press down:(BOOL)down;
- (BOOL)consumeInput:(struct mng_input *)input now:(uint64_t)nanoseconds;
@end
NS_ASSUME_NONNULL_END
