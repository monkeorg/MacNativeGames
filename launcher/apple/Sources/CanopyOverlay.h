#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
typedef BOOL (^CanopyOverlayInputTransition)(NSError * _Nullable * _Nullable error);

/// Floating session controls. Callbacks must neutralize every actual gameplay
/// input source. Capture failure leaves the shield open; restore failure keeps
/// it open. A callback must never report pause/resume success speculatively.
@interface CanopyOverlay : UIViewController
@property(nonatomic, readonly, getter=isExpanded) BOOL expanded;
/// Runs after the visible/capture state changes, so hosts can recompute pointer
/// lock from the final state rather than from inside a restore callback.
@property(nonatomic, copy, nullable) void (^stateDidChange)(BOOL expanded);
- (instancetype)initWithContentController:(UIViewController *)content
                            captureInput:(CanopyOverlayInputTransition)capture
                            restoreInput:(CanopyOverlayInputTransition)restore;
- (BOOL)open;
- (BOOL)close;
/// Show actual host/application state without changing input ownership.
- (void)showStatus:(nullable NSString *)message;
@end
NS_ASSUME_NONNULL_END
