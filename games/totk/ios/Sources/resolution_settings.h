#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TOTKResolutionSettings : UITableViewController
- (instancetype)initWithChanged:(void (^)(void))changed;
@end

NS_ASSUME_NONNULL_END
