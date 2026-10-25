#import "settings_navigation.h"
#import "menu_style.h"

@interface TOTKSettingsNavigation () <UINavigationControllerDelegate>
@property(nonatomic,copy) void (^closeSettings)(void);
@end

@implementation TOTKSettingsNavigation
- (instancetype)initWithRoot:(UIViewController *)root close:(void (^)(void))close {
    if ((self=[super initWithRootViewController:root])) { self.closeSettings=close; self.delegate=self; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.clearColor;
    self.view.layer.cornerRadius=32; self.view.clipsToBounds=YES;
    UIView *glass=TOTKSettingsBackground();
    glass.frame=self.view.bounds; glass.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:glass atIndex:0];
    UINavigationBarAppearance *appearance=[UINavigationBarAppearance new];
    [appearance configureWithTransparentBackground];
    self.navigationBar.standardAppearance=appearance; self.navigationBar.scrollEdgeAppearance=appearance;
    self.navigationBar.prefersLargeTitles=NO;
}
- (void)navigationController:(UINavigationController *)navigation willShowViewController:(UIViewController *)controller animated:(BOOL)animated {
    (void)navigation; (void)animated;
    controller.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    controller.navigationItem.backButtonDisplayMode=UINavigationItemBackButtonDisplayModeMinimal;
    NSMutableArray *buttons=[NSMutableArray array];
    for (UIBarButtonItem *button in controller.navigationItem.rightBarButtonItems)
        if (button.tag!=7301) [buttons addObject:button];
    if (self.closeSettings || self.viewControllers.count>1) {
        UIBarButtonItem *close=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
        close.tag=7301;
        close.accessibilityLabel=self.closeSettings ? @"Close game menu" : @"Back to main menu";
        [buttons addObject:close];
    }
    controller.navigationItem.rightBarButtonItems=buttons;
}
- (void)close {
    if (self.closeSettings) self.closeSettings();
    else [self popToRootViewControllerAnimated:YES];
}
@end

@implementation TOTKSettingsPanel {
    TOTKSettingsNavigation *_navigation;
}
- (instancetype)initWithRoot:(UIViewController *)root {
    if ((self=[super initWithNibName:nil bundle:nil])) _navigation=[[TOTKSettingsNavigation alloc] initWithRoot:root close:nil];
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;
    [self addChildViewController:_navigation];
    UIView *panel=_navigation.view; panel.translatesAutoresizingMaskIntoConstraints=NO;
    panel.accessibilityIdentifier=@"TOTKPrelaunchCard";
    [self.view addSubview:panel]; [_navigation didMoveToParentViewController:self];
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *width=[panel.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-24]; width.priority=UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *height=[panel.heightAnchor constraintEqualToAnchor:safe.heightAnchor constant:-24]; height.priority=UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor], [panel.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        width,height,[panel.widthAnchor constraintLessThanOrEqualToConstant:720],[panel.heightAnchor constraintLessThanOrEqualToConstant:760],
        [panel.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-24],
        [panel.heightAnchor constraintLessThanOrEqualToAnchor:safe.heightAnchor constant:-24]
    ]];
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end
