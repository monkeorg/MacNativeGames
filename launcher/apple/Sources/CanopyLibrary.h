#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Stores inspected-container metadata only. All calls belong on the main thread.
@interface CanopyLibrary : NSObject
@property(nonatomic, readonly) NSArray<NSDictionary<NSString *, id> *> *records;
@property(nonatomic, readonly) BOOL recoveryRequired;
- (instancetype)initWithDirectoryURL:(NSURL *)directory;
- (BOOL)load:(NSError **)error;
- (BOOL)addDisplayName:(NSString *)name format:(NSString *)format
            sourceSize:(uint64_t)size entryCount:(NSUInteger)count error:(NSError **)error;
- (BOOL)removeIdentifier:(NSString *)identifier error:(NSError **)error;
/// Call only following explicit user confirmation. Replaces metadata, not source files.
- (BOOL)reset:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
