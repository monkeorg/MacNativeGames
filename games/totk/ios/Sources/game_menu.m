#import "game_menu.h"
#import "launcher_settings.h"
#import "mouse_input.h"
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

@interface TOTKGameMenu : UIViewController
@property(nonatomic,strong) UIButton *gear;
@property(nonatomic,strong) UIVisualEffectView *card;
@property(nonatomic,strong) UISegmentedControl *hud;
@property(nonatomic,strong) UISwitch *metalHUD;
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
- (UILabel *)label:(NSString *)text style:(UIFontTextStyle)style color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
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
    self.gear.accessibilityHint = @"Show game display controls. The game stays active.";
    self.gear.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.gear];

    UIGlassEffect *glass = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    self.card = [[UIVisualEffectView alloc] initWithEffect:glass];
    self.card.accessibilityIdentifier = @"TOTKGameMenuCard";
    self.card.layer.cornerRadius = 28;
    self.card.clipsToBounds = YES;
    self.card.translatesAutoresizingMaskIntoConstraints = NO;
    self.card.hidden = YES;
    [self.view addSubview:self.card];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.card.contentView addSubview:scroll];
    UIStackView *content = [UIStackView new];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 16;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];

    UILabel *title = [self label:@"Game menu" style:UIFontTextStyleTitle2 color:UIColor.labelColor];
    UIButton *close = [self buttonWithTitle:@"" symbol:@"xmark" prominent:NO action:@selector(closeMenu)];
    close.accessibilityLabel = @"Close game menu";
    UIStackView *heading = [[UIStackView alloc] initWithArrangedSubviews:@[title,close]];
    heading.alignment = UIStackViewAlignmentCenter;
    heading.spacing = 12;
    [close.widthAnchor constraintEqualToConstant:44].active = YES;
    [close.heightAnchor constraintEqualToConstant:44].active = YES;
    [content addArrangedSubview:heading];
    [content addArrangedSubview:[self label:@"The game stays active." style:UIFontTextStyleSubheadline color:UIColor.secondaryLabelColor]];

    [content addArrangedSubview:[self label:@"Game overlay" style:UIFontTextStyleHeadline color:UIColor.labelColor]];
    self.hud = [[UISegmentedControl alloc] initWithItems:@[@"Full",@"FPS",@"Off"]];
    self.hud.accessibilityLabel = @"Game overlay";
    [self.hud addTarget:self action:@selector(changeHUD:) forControlEvents:UIControlEventValueChanged];
    [content addArrangedSubview:self.hud];

    self.metalHUD = [UISwitch new];
    self.metalHUD.accessibilityLabel = @"Metal performance HUD";
    [self.metalHUD addTarget:self action:@selector(changeMetalHUD:) forControlEvents:UIControlEventValueChanged];
    UIStackView *metalRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self label:@"Metal performance HUD" style:UIFontTextStyleHeadline color:UIColor.labelColor], self.metalHUD]];
    metalRow.alignment = UIStackViewAlignmentCenter;
    metalRow.spacing = 12;
    [self.metalHUD setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [content addArrangedSubview:metalRow];
    [content addArrangedSubview:[self label:@"Reopen the app to change resolution or language." style:UIFontTextStyleFootnote color:UIColor.secondaryLabelColor]];
    [content addArrangedSubview:[self buttonWithTitle:@"Close menu" symbol:@"chevron.down" prominent:YES action:@selector(closeMenu)]];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *width = [self.card.widthAnchor constraintEqualToConstant:340];
    width.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *height = [self.card.heightAnchor constraintEqualToAnchor:content.heightAnchor constant:40];
    height.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [self.gear.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.gear.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [self.gear.widthAnchor constraintEqualToConstant:48],
        [self.gear.heightAnchor constraintEqualToConstant:48],
        [self.card.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.card.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor], width, height,
        [self.card.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-32],
        [self.card.heightAnchor constraintLessThanOrEqualToAnchor:safe.heightAnchor constant:-24],
        [scroll.leadingAnchor constraintEqualToAnchor:self.card.contentView.leadingAnchor constant:20],
        [scroll.trailingAnchor constraintEqualToAnchor:self.card.contentView.trailingAnchor constant:-20],
        [scroll.topAnchor constraintEqualToAnchor:self.card.contentView.topAnchor constant:20],
        [scroll.bottomAnchor constraintEqualToAnchor:self.card.contentView.bottomAnchor constant:-20],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
    ]];
}
- (void)openMenu {
    TOTKMenuView *shield = (TOTKMenuView *)self.view;
    if (shield.expanded) return;
    self.mouseInputWasEnabled = TOTKMouseInputEnabled();
    TOTKSetMouseInputEnabled(NO);
    NSInteger hud = fps_overlay_hud_mode();
    self.hud.selectedSegmentIndex = hud == HUD_MODE_ALL ? 0 : hud == HUD_MODE_MINIMAL ? 1 : 2;
    self.metalHUD.on = TOTKLauncherMetalHUD(NSUserDefaults.standardUserDefaults);
    for (UIView *control in self.view.superview.subviews) {
        if (control == self.view) continue;
        [self.controlStates setObject:@(control.userInteractionEnabled) forKey:control];
        control.userInteractionEnabled = NO;
    }
    shield.expanded = YES;
    self.view.accessibilityViewIsModal = YES;
    self.gear.hidden = YES;
    self.card.hidden = NO;
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.card);
}
- (void)closeMenu {
    for (UIView *control in self.controlStates.keyEnumerator) {
        control.userInteractionEnabled = [[self.controlStates objectForKey:control] boolValue];
    }
    [self.controlStates removeAllObjects];
    TOTKSetMouseInputEnabled(self.mouseInputWasEnabled);
    ((TOTKMenuView *)self.view).expanded = NO;
    self.view.accessibilityViewIsModal = NO;
    self.card.hidden = YES;
    self.gear.hidden = NO;
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.gear);
}
- (BOOL)canBecomeFirstResponder { return YES; }
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
- (void)changeHUD:(UISegmentedControl *)sender {
    NSInteger modes[] = {HUD_MODE_ALL,HUD_MODE_MINIMAL,HUD_MODE_OFF};
    if (sender.selectedSegmentIndex < 0 || sender.selectedSegmentIndex > 2) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setInteger:modes[sender.selectedSegmentIndex] forKey:@"TOTK_LAUNCHER_HUD"];
    NSInteger wanted = TOTKLauncherHUD(defaults);
    for (unsigned i=0; i<3 && fps_overlay_hud_mode()!=wanted; i++) fps_overlay_toggle_hints();
}
- (void)applyMetalHUD:(BOOL)enabled toView:(UIView *)view {
    if ([view.layer isKindOfClass:CAMetalLayer.class]) {
        ((CAMetalLayer *)view.layer).developerHUDProperties = @{@"mode": enabled ? @"default" : @"disabled"};
    }
    for (UIView *child in view.subviews) [self applyMetalHUD:enabled toView:child];
}
- (void)changeMetalHUD:(UISwitch *)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:sender.on forKey:@"TOTK_LAUNCHER_METAL_HUD"];
    BOOL enabled = TOTKLauncherMetalHUD(defaults);
    [defaults setBool:enabled forKey:@"MetalHUDForceEnabled"];
    [self applyMetalHUD:enabled toView:self.parentViewController.view];
}
@end

void TOTKAttachGameMenu(UIViewController *gameController) {
    for (UIViewController *child in gameController.childViewControllers) {
        if ([child isKindOfClass:TOTKGameMenu.class]) return;
    }
    TOTKGameMenu *menu = [TOTKGameMenu new];
    [gameController addChildViewController:menu];
    menu.view.frame = gameController.view.bounds;
    menu.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [gameController.view addSubview:menu.view];
    [menu didMoveToParentViewController:gameController];
}
