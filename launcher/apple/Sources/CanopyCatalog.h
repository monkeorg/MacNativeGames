#import <Foundation/Foundation.h>
#import "CanopySettings.h"

NS_ASSUME_NONNULL_BEGIN

/// Verified prepared generations only, never inspection-history records.
/// reload performs real asset hashing: call on a background serial owner queue.
@interface CanopyCatalog : NSObject
/// titleID, generationID, recipeID, displayName, sourceSize, sourceSHA256,
/// assetCount/assetBytes, integrity, preparationState="prepared", runtimeEligibility="unassessed".
@property(nonatomic, readonly) NSArray<NSDictionary<NSString *, id> *> *entries;
/// Bounded sanitized per-title failures. A corrupt title does not hide valid titles.
@property(nonatomic, readonly) NSArray<NSString *> *issues;
- (instancetype)initWithPreparedRootURL:(NSURL *)root settings:(CanopySettings *)settings;
- (BOOL)reload:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
