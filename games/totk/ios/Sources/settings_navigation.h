#import <UIKit/UIKit.h>

@interface TOTKSettingsNavigation : UINavigationController
- (instancetype)initWithRoot:(UIViewController *)root close:(void (^)(void))close;
@end

@interface TOTKSettingsPanel : UIViewController
- (instancetype)initWithRoot:(UIViewController *)root;
@end
