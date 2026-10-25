#import <Foundation/Foundation.h>
#include <stdint.h>
#define TOTK_SEED_PACK_READER_ABI 1u
__attribute__((visibility("default"))) unsigned TOTKShaderPackReaderABI(void);
NS_ASSUME_NONNULL_BEGIN
/// Verified private snapshot lifetime, not Apple signing/execution authority.
/// Retain for the whole native session. Never close its borrowed directoryFD.
@interface TOTKShaderSeedLease : NSObject
@property(nonatomic,readonly) NSURL *seedURL;
@property(nonatomic,readonly) NSString *titleID;
@property(nonatomic,readonly) NSString *sourceRomFSSHA256;
@property(nonatomic,readonly) NSString *chain;
@property(nonatomic,readonly) uint32_t titleVersion;
@property(nonatomic,readonly) NSString *streamSHA256;
@property(nonatomic,readonly) NSString *manifestSHA256;
@property(nonatomic,readonly) NSString *metadataSHA256;
@property(nonatomic,readonly) int directoryFD;
- (instancetype)init NS_UNAVAILABLE;
@end
@interface TOTKShaderPack : NSObject
/// Worker-only synchronous API. Roots come only from mainBundle and the app's
/// Documents/ApplicationSupport locations. expectedChain must be compiled host
/// identity, never an environment/imported approval. Progress counts stream
/// bytes (including headers), not shaders compiled or gameplay performance.
+ (nullable TOTKShaderSeedLease *)prepareWithExpectedChain:(NSString *)expectedChain
    progress:(void (^ _Nullable)(uint64_t done,uint64_t total))progress
    error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
