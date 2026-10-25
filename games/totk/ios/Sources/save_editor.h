#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Edits a copy only. Completion follows dismissal; nil means cancelled.
@interface TOTKSaveEditor : UIViewController
- (instancetype)initWithProgressData:(NSData *)data completion:(void (^)(NSData * _Nullable editedData))completion;
@end

NS_ASSUME_NONNULL_END
