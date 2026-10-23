#import <UIKit/UIKit.h>
#import "save_store.h"

@interface TOTKLauncher : UIViewController
- (instancetype)initWithStore:(TOTKSaveStore *)store unavailable:(NSString *)reason play:(void (^)(void))play;
@end
