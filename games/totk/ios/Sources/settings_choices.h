#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

void TOTKChooseSetting(UIViewController *owner, NSString *title, NSArray<NSString *> *choices,
                       NSString * _Nullable selected, NSIndexSet * _Nullable disabled,
                       void (^selection)(NSUInteger index));

NS_ASSUME_NONNULL_END
