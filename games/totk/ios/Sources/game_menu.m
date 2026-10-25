#import "game_menu.h"
#import "launcher_settings.h"
#import "launcher.h"
#import "settings_navigation.h"
#import "mouse_input.h"
#import "keyboard_input.h"
#import "touch_pad.h"
#include "../../runtime/runtime.h"
#import <QuartzCore/CAMetalLayer.h>
#include "fps_overlay.h"

@interface TOTKMenuView : UIView
@property(nonatomic) BOOL expanded;
@end

@implementation TOTKMenuView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return !self.expanded && hit == self ? nil : hit;
}
@end

@interface TOTKGameMenu : UIViewController <UIGestureRecognizerDelegate>
@property(nonatomic,strong) UIButton *gear;
@property(nonatomic,strong) UIView *card;
@property(nonatomic,strong) UINavigationController *settingsNavigation;
@property(nonatomic,strong) NSMapTable<UIView *,NSNumber *> *controlStates;
@property(nonatomic) BOOL mouseInputWasEnabled;
@end

@implementation TOTKGameMenu
- (UIButton *)buttonWithTitle:(NSString *)title symbol:(NSString *)symbol prominent:(BOOL)prominent action:(SEL)action {
    UIButtonConfiguration *configuration = prominent ? UIButtonConfiguration.prominentGlassButtonConfiguration : UIButtonConfiguration.glassButtonConfiguration;
    configuration.title = title;
    configuration.image = [UIImage systemImageNamed:symbol];
    configuration.imagePadding = title.length ? 8 : 0;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    configuration.buttonSize = UIButtonConfigurationSizeLarge;
    UIButton *button = [UIButton buttonWithConfiguration:configuration primaryAction:nil];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}
- (void)loadView {
    self.view = [TOTKMenuView new];
    self.view.backgroundColor = UIColor.clearColor;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.controlStates = [NSMapTable weakToStrongObjectsMapTable];
    self.gear = [self buttonWithTitle:@"" symbol:@"gearshape.fill" prominent:NO action:@selector(openMenu)];
    self.gear.accessibilityLabel = @"Game menu";
    self.gear.accessibilityHint = @"Show all settings. The game stays active.";
    self.gear.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.gear];

    __weak TOTKGameMenu *weakSelf = self;
    TOTKLauncher *settings = [[TOTKLauncher alloc] initForGameWithResume:^{
        [weakSelf closeMenu];
    } HUDChanged:^{
        [weakSelf applyHUDPreferences];
    }];
    self.settingsNavigation = [[TOTKSettingsNavigation alloc] initWithRoot:settings close:^{ [weakSelf closeMenu]; }];
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithTransparentBackground];
    self.settingsNavigation.navigationBar.standardAppearance = appearance;
    self.settingsNavigation.navigationBar.scrollEdgeAppearance = appearance;
    [self addChildViewController:self.settingsNavigation];
    self.card = self.settingsNavigation.view;
    self.card.backgroundColor = UIColor.clearColor;
    self.card.accessibilityIdentifier = @"TOTKGameMenuCard";
    self.card.translatesAutoresizingMaskIntoConstraints = NO;
    self.card.hidden = YES;
    [self.view addSubview:self.card];
    [self.settingsNavigation didMoveToParentViewController:self];
    UITapGestureRecognizer *outsideTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeMenu)];
    outsideTap.delegate = self;
    [self.view addGestureRecognizer:outsideTap];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *width = [self.card.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-24];
    width.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *height = [self.card.heightAnchor constraintEqualToAnchor:safe.heightAnchor constant:-24];
    height.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [self.gear.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.gear.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
        [self.gear.widthAnchor constraintEqualToConstant:44],
        [self.gear.heightAnchor constraintEqualToConstant:44],
        [self.card.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.card.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor], width, height,
        [self.card.widthAnchor constraintLessThanOrEqualToConstant:720],
        [self.card.heightAnchor constraintLessThanOrEqualToConstant:760],
        [self.card.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-24],
        [self.card.heightAnchor constraintLessThanOrEqualToAnchor:safe.heightAnchor constant:-24],
    ]];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (!((TOTKMenuView *)self.view).expanded) return NO;
    if (self.settingsNavigation.presentedViewController || self.settingsNavigation.topViewController.presentedViewController) return NO;
    CGPoint point = [touch locationInView:self.view];
    if ([self.card pointInside:[self.card convertPoint:point fromView:self.view] withEvent:nil]) return NO;
    if ([self.gear pointInside:[self.gear convertPoint:point fromView:self.view] withEvent:nil]) return NO;
    return YES;
}
- (void)openMenu {
    TOTKMenuView *shield = (TOTKMenuView *)self.view;
    if (shield.expanded) return;
    self.mouseInputWasEnabled = TOTKMouseInputEnabled();
    TOTKSetMouseInputEnabled(NO);
    TOTKSetKeyboardInputEnabled(NO);
    [self.settingsNavigation popToRootViewControllerAnimated:NO];
    for (UIView *control in self.view.superview.subviews) {
        if (control == self.view) continue;
        [self.controlStates setObject:@(control.userInteractionEnabled) forKey:control];
        control.userInteractionEnabled = NO;
    }
    shield.expanded = YES;
    shield.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.12];
    self.view.accessibilityViewIsModal = YES;
    self.gear.hidden = YES;
    self.card.hidden = NO;
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.card);
}
- (void)closeMenu {
    if (!((TOTKMenuView *)self.view).expanded) return;
    if (self.settingsNavigation.presentedViewController || self.settingsNavigation.topViewController.presentedViewController) {
        __weak TOTKGameMenu *weakSelf = self;
        [self.settingsNavigation dismissViewControllerAnimated:NO completion:^{ [weakSelf closeMenu]; }];
        return;
    }
    for (UIView *control in self.controlStates.keyEnumerator) {
        if (control.superview != self.view.superview) continue;
        control.userInteractionEnabled = [[self.controlStates objectForKey:control] boolValue];
    }
    [self.controlStates removeAllObjects];
    TOTKSetMouseInputEnabled(self.mouseInputWasEnabled);
    ((TOTKMenuView *)self.view).expanded = NO;
    self.view.backgroundColor = UIColor.clearColor;
    self.view.accessibilityViewIsModal = NO;
    self.card.hidden = YES;
    self.gear.hidden = NO;
    TOTKSetKeyboardInputEnabled(YES);
    [self becomeFirstResponder];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.gear);
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)forwardPresses:(NSSet<UIPress *> *)presses event:(UIPressesEvent *)event down:(BOOL)down cancelled:(BOOL)cancelled {
    NSMutableSet<UIPress *> *unhandled = [NSMutableSet set];
    for (UIPress *press in presses) if (!TOTKKeyboardPress(press,down)) [unhandled addObject:press];
    if (!unhandled.count) return;
    if (down) [super pressesBegan:unhandled withEvent:event];
    else if (cancelled) [super pressesCancelled:unhandled withEvent:event];
    else [super pressesEnded:unhandled withEvent:event];
}
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event { [self forwardPresses:presses event:event down:YES cancelled:NO]; }
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event { [self forwardPresses:presses event:event down:NO cancelled:NO]; }
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self forwardPresses:presses event:event down:NO cancelled:YES];
    TOTKClearKeyboardInput();
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self becomeFirstResponder];
}
- (NSArray<UIKeyCommand *> *)keyCommands {
    UIKeyCommand *menu = [UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(toggleMenu)];
    menu.discoverabilityTitle = @"Game menu";
    return @[menu];
}
- (void)toggleMenu {
    if (((TOTKMenuView *)self.view).expanded) [self closeMenu];
    else [self openMenu];
}
- (BOOL)accessibilityPerformEscape {
    if (!((TOTKMenuView *)self.view).expanded) return NO;
    [self closeMenu];
    return YES;
}
- (void)applyHUDPreferences {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger wanted = TOTKLauncherHUD(defaults);
    for (unsigned i=0; i<3 && fps_overlay_hud_mode()!=wanted; i++) fps_overlay_toggle_hints();
    BOOL enabled = TOTKLauncherMetalHUD(defaults);
    [defaults setBool:enabled forKey:@"MetalHUDForceEnabled"];
    [self applyMetalHUD:enabled toView:self.parentViewController.view];
    runtime_ios_set_thermal_hud_visible(enabled || fps_overlay_full_hud());
    runtime_ios_set_shader_hud_visible([defaults boolForKey:@"TOTK_LAUNCHER_SHADER_HUD"]);
    runtime_ios_set_fps_limit((unsigned)TOTKLauncherFPSLimit(defaults));
    runtime_ios_set_taa_enabled(TOTKLauncherTAA(defaults));
    TOTKTouchPad *pad = TOTKSetTouchControlsVisible(self.parentViewController.view,TOTKLauncherTouch(defaults));
    if (pad && ((TOTKMenuView *)self.view).expanded) {
        if (![self.controlStates objectForKey:pad]) [self.controlStates setObject:@YES forKey:pad];
        pad.userInteractionEnabled = NO;
    }
}
- (void)applyMetalHUD:(BOOL)enabled toView:(UIView *)view {
    if ([view.layer isKindOfClass:CAMetalLayer.class]) {
        ((CAMetalLayer *)view.layer).developerHUDProperties = @{@"mode": enabled ? @"default" : @"disabled"};
    }
    for (UIView *child in view.subviews) [self applyMetalHUD:enabled toView:child];
}

@end

void TOTKAttachGameMenu(UIViewController *gameController) {
    for (UIViewController *child in gameController.childViewControllers) {
        if ([child isKindOfClass:TOTKGameMenu.class]) return;
    }
    TOTKGameMenu *menu = [TOTKGameMenu new];
    TOTKStartKeyboardInput(gameController);
    [gameController addChildViewController:menu];
    menu.view.frame = gameController.view.bounds;
    menu.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [gameController.view addSubview:menu.view];
    [menu didMoveToParentViewController:gameController];
}
