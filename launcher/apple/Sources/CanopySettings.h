#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Separate user metadata; never stored in or used to delete prepared generations.
/// Call on one serial owner queue. Loading malformed metadata never rewrites it.
@interface CanopySettings : NSObject
@property(nonatomic, readonly) BOOL recoveryRequired;
+ (NSDictionary<NSString *, id> *)defaults;
+ (BOOL)isValidTitleID:(NSString *)titleID;
- (instancetype)initWithDirectoryURL:(NSURL *)directory;
- (BOOL)load:(NSError **)error;
- (nullable NSDictionary<NSString *, id> *)settingsForTitleID:(NSString *)titleID error:(NSError **)error;
- (nullable NSString *)displayNameForTitleID:(NSString *)titleID;
- (BOOL)setValue:(id)value forSetting:(NSString *)key titleID:(NSString *)titleID error:(NSError **)error;
- (BOOL)setDisplayName:(NSString *)name forTitleID:(NSString *)titleID error:(NSError **)error;
/// Explicit recovery operation: clears settings/names only, never prepared assets.
- (BOOL)resetMetadata:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
