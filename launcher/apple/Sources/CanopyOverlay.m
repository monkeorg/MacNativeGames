#import "CanopyOverlay.h"
#import <QuartzCore/QuartzCore.h>

@interface CanopyOverlayShield : UIView
@property(nonatomic) BOOL expanded;
@end
@implementation CanopyOverlayShield
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return !self.expanded && hit == self ? nil : hit;
}
@end

@interface CanopyOverlay () <UIGestureRecognizerDelegate, UINavigationControllerDelegate>
@end
@implementation CanopyOverlay {
    UIViewController *_content;
    UINavigationController *_navigation;
    CanopyOverlayInputTransition _capture, _restore;
    UIButton *_gear;
    UIView *_card;
    UIVisualEffectView *_material;
    UILabel *_status;
    NSMapTable<UIView *, NSNumber *> *_interactionStates;
    BOOL _expanded, _transitioning, _captured;
}
- (instancetype)initWithContentController:(UIViewController *)content
                            captureInput:(CanopyOverlayInputTransition)capture
                            restoreInput:(CanopyOverlayInputTransition)restore {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _content = content; _capture = [capture copy]; _restore = [restore copy];
        _interactionStates = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}
- (BOOL)isExpanded { return _expanded; }
- (void)loadView { self.view = [CanopyOverlayShield new]; self.view.backgroundColor = UIColor.clearColor; }
- (void)viewDidLoad {
    [super viewDidLoad];
    UIButtonConfiguration *configuration = [UIButtonConfiguration tintedButtonConfiguration];
    configuration.image = [UIImage systemImageNamed:@"gearshape.fill"];
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    _gear = [UIButton buttonWithConfiguration:configuration primaryAction:nil];
    _gear.accessibilityLabel = @"Session settings";
    _gear.accessibilityHint = @"Captures gameplay input and opens the settings menu.";
    _gear.translatesAutoresizingMaskIntoConstraints = NO;
    [_gear addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_gear];
    _card = [UIView new];
    _card.layer.cornerRadius = 24; _card.layer.cornerCurve = kCACornerCurveContinuous; _card.clipsToBounds = YES;
    _card.accessibilityIdentifier = @"CanopySessionSettingsCard";
    _card.translatesAutoresizingMaskIntoConstraints = NO; _card.hidden = YES;
    [self.view addSubview:_card];
    _material = [[UIVisualEffectView alloc] initWithEffect:nil]; _material.userInteractionEnabled = NO;
    _material.translatesAutoresizingMaskIntoConstraints = NO; [_card addSubview:_material];
    [NSLayoutConstraint activateConstraints:@[[_material.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor],[_material.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor],[_material.topAnchor constraintEqualToAnchor:_card.topAnchor],[_material.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor]]];
    _status = [UILabel new]; _status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _status.adjustsFontForContentSizeCategory = YES; _status.numberOfLines = 0;
    _status.textColor = UIColor.secondaryLabelColor; _status.hidden = YES;
    _status.translatesAutoresizingMaskIntoConstraints = NO;
    _navigation = [[UINavigationController alloc] initWithRootViewController:_content];
    _navigation.delegate = self;
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new]; [appearance configureWithTransparentBackground];
    _navigation.navigationBar.standardAppearance = appearance; _navigation.navigationBar.scrollEdgeAppearance = appearance;
    _content.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Resume"
        style:UIBarButtonItemStylePlain target:self action:@selector(closeFromButton)];
    [self addChildViewController:_navigation];
    _navigation.view.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_status,_navigation.view]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:stack]; [_navigation didMoveToParentViewController:self];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *width = [_card.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-24]; width.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *height = [_card.heightAnchor constraintEqualToAnchor:safe.heightAnchor constant:-24]; height.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [_gear.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_gear.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
        [_gear.widthAnchor constraintGreaterThanOrEqualToConstant:48], [_gear.heightAnchor constraintGreaterThanOrEqualToConstant:48],
        [_card.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor], [_card.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor], width, height,
        [_card.widthAnchor constraintLessThanOrEqualToConstant:1008], [_card.heightAnchor constraintLessThanOrEqualToConstant:840],
        [_card.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-24], [_card.heightAnchor constraintLessThanOrEqualToAnchor:safe.heightAnchor constant:-24],
        [stack.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:8], [stack.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-8],
        [stack.topAnchor constraintEqualToAnchor:_card.topAnchor constant:8], [stack.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-8]]];
    UITapGestureRecognizer *outside = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeFromButton)];
    outside.delegate = self; [self.view addGestureRecognizer:outside];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(transparencyChanged:) name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
    [self updateMaterial];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)transparencyChanged:(NSNotification *)notification { (void)notification; [self updateMaterial]; }
- (void)updateMaterial {
    BOOL reduced = UIAccessibilityIsReduceTransparencyEnabled();
    _material.effect = reduced ? nil : [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    _card.backgroundColor = reduced ? UIColor.secondarySystemGroupedBackgroundColor : UIColor.clearColor;
    _navigation.view.backgroundColor = UIColor.clearColor;
    for (UIViewController *controller in _navigation.viewControllers) if (controller.isViewLoaded) controller.view.backgroundColor = reduced ? UIColor.systemGroupedBackgroundColor : UIColor.clearColor;
}
- (void)navigationController:(UINavigationController *)navigationController willShowViewController:(UIViewController *)viewController animated:(BOOL)animated {
    (void)navigationController; (void)animated;
    viewController.view.backgroundColor = UIAccessibilityIsReduceTransparencyEnabled() ? UIColor.systemGroupedBackgroundColor : UIColor.clearColor;
}
- (BOOL)open {
    NSAssert(NSThread.isMainThread,@"Overlay belongs on main thread");
    if (_expanded || _transitioning) return _expanded && _captured;
    [self loadViewIfNeeded]; _transitioning = YES;
    [self.view.window endEditing:YES];
    _expanded = YES; ((CanopyOverlayShield *)self.view).expanded = YES;
    for (UIView *sibling in self.view.superview.subviews) if (sibling != self.view) {
        [_interactionStates setObject:@(sibling.userInteractionEnabled) forKey:sibling]; sibling.userInteractionEnabled = NO;
    }
    [_navigation popToRootViewControllerAnimated:NO];
    _card.hidden = NO; _gear.hidden = YES; self.view.accessibilityViewIsModal = YES;
    [self showStatus:nil];
    NSError *error = nil; BOOL captured = _capture(&error); _captured = captured;
    if (!captured) [self showStatus:error.localizedDescription ?: @"Input capture or pause failed. Gameplay may still be running; the menu remains open."];
    [self becomeFirstResponder]; _transitioning = NO;
    if (self.stateDidChange) self.stateDidChange(YES);
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification,_card);
    return captured;
}
- (BOOL)close {
    NSAssert(NSThread.isMainThread,@"Overlay belongs on main thread");
    if (!_expanded) return YES;
    if (_transitioning) return NO;
    if (_navigation.presentedViewController || _navigation.topViewController.presentedViewController) {
        // A Home/Escape edge must not dismiss a confirmation and then restore
        // gameplay behind its dismissal animation. Keep capture until the
        // dialog ends and the user explicitly requests Resume again.
        [self showStatus:@"Finish or cancel the current dialog before resuming gameplay."]; return NO;
    }
    _transitioning = YES; [self.view.window endEditing:YES];
    NSError *error = nil; BOOL restored = _restore(&error);
    if (!restored) {
        [self showStatus:error.localizedDescription ?: @"The session could not resume. Input remains captured."];
        _transitioning = NO; return NO;
    }
    for (UIView *sibling in _interactionStates.keyEnumerator) if (sibling.superview == self.view.superview) sibling.userInteractionEnabled = [[_interactionStates objectForKey:sibling] boolValue];
    [_interactionStates removeAllObjects];
    _expanded = NO; _captured = NO; ((CanopyOverlayShield *)self.view).expanded = NO;
    self.view.accessibilityViewIsModal = NO; _card.hidden = YES; _gear.hidden = NO;
    [self showStatus:nil]; [self resignFirstResponder]; _transitioning = NO;
    if (self.stateDidChange) self.stateDidChange(NO);
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification,_gear); return YES;
}
- (void)showStatus:(NSString *)message { [self loadViewIfNeeded]; _status.text = message; _status.hidden = !message.length; }
- (void)toggleMenu { if (_expanded) [self close]; else [self open]; }
- (void)closeFromButton { [self close]; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    (void)gesture;
    if (!_expanded || _navigation.presentedViewController || _navigation.topViewController.presentedViewController) return NO;
    CGPoint point = [touch locationInView:self.view];
    return ![_card pointInside:[_card convertPoint:point fromView:self.view] withEvent:nil];
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (NSArray<UIKeyCommand *> *)keyCommands {
    UIKeyCommand *escape = [UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(toggleMenu)];
    escape.discoverabilityTitle = @"Session settings"; return @[escape];
}
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event { if (!_expanded) [super pressesBegan:presses withEvent:event]; }
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event { if (!_expanded) [super pressesEnded:presses withEvent:event]; }
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event { if (!_expanded) [super pressesCancelled:presses withEvent:event]; }
- (BOOL)accessibilityPerformEscape { return _expanded ? [self close] : NO; }
@end
