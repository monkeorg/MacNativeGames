#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Separate user metadata; never stored in or used to delete prepared generations.
/// Call on one serial owner queue. Loading malformed metadata never rewrites it.
/// Absent mouseEnabled in existing v1 rows inherits YES; no metadata rewrite.
@interface CanopySettings : NSObject
@property(nonatomic, readonly) BOOL recoveryRequired;
+ (NSDictionary<NSString *, id> *)defaults;
/// Validate a complete or partial options dictionary without persistence.
+ (BOOL)areValidOptions:(NSDictionary *)options;
+ (NSArray<NSString *> *)keyboardActions;
+ (NSArray<NSNumber *> *)keyboardSupportedKeys;
+ (NSString *)keyboardKeyTitle:(unsigned)usage;
+ (unsigned)keyboardBindingForAction:(NSString *)action settings:(NSDictionary *)settings;
+ (BOOL)isValidTitleID:(NSString *)titleID;
- (instancetype)initWithDirectoryURL:(NSURL *)directory;
- (BOOL)load:(NSError **)error;
- (nullable NSDictionary<NSString *, id> *)settingsForTitleID:(NSString *)titleID error:(NSError **)error;
- (nullable NSString *)displayNameForTitleID:(NSString *)titleID;
- (BOOL)setValue:(id)value forSetting:(NSString *)key titleID:(NSString *)titleID error:(NSError **)error;
/// Optional modes are hold/tap/toggle or aim plus another same-source fire slot.
/// Missing overrides preserve legacy Hold and the special default mouse Aim.
+ (nullable NSString *)inputMappingTextWithTargets:(NSDictionary *)targets modes:(NSDictionary *)modes;
/// Atomic paired update: invalid combinations never leave partially saved maps.
- (BOOL)setButtonMappings:(NSDictionary *)targets modes:(NSDictionary *)modes titleID:(NSString *)titleID error:(NSError **)error;
- (BOOL)setDisplayName:(NSString *)name forTitleID:(NSString *)titleID error:(NSError **)error;
/// Explicit recovery operation: clears settings/names only, never prepared assets.
- (BOOL)resetMetadata:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
