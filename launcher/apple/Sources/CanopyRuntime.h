#import <Foundation/Foundation.h>
#include "mng_session.h"
NS_ASSUME_NONNULL_BEGIN
/// Main-thread owner of the explicitly compiled private native host. The public
/// app has no trusted host descriptor and therefore exposes no executable title.
@interface CanopyRuntime : NSObject
@property(nonatomic, readonly) NSString *state;
@property(nonatomic, readonly) BOOL nativeEntryInvoked;
@property(nonatomic, readonly, nullable) NSString *titleID;
@property(nonatomic, readonly) NSDictionary<NSString *, id> *capabilities;
@property(nonatomic, readonly) NSDictionary<NSString *, NSDictionary *> *settingStates;
/// Actual native-entry state, configured frame ceiling and verified shader import
/// counters only. Contains no frame/presentation/gameplay throughput estimate.
@property(nonatomic, readonly) NSDictionary<NSString *, id> *diagnosticMetrics;
+ (nullable NSDictionary<NSString *, id> *)trustedProfileForTitleID:(NSString *)titleID;
- (instancetype)initWithPreparedRootURL:(NSURL *)root;
/// hostAssets holds approved private fonts/shaders and native host resources;
/// the runtime index is produced in private cache and checked against host pins.
/// Assets are distinct from the immutable extracted generation. Existing loader pins
/// remain mandatory. activeSaves and identity belong to CanopySaveStore.
- (BOOL)startTitleID:(NSString *)titleID generationID:(NSString *)generationID
       hostAssetsURL:(NSURL *)hostAssets activeSavesURL:(NSURL *)activeSaves
         identityURL:(NSURL *)identity cacheURL:(NSURL *)cache
            settings:(NSDictionary<NSString *, id> *)settings
     graphicsSurface:(id)surface hostView:(id)hostView error:(NSError **)error
          completion:(void (^)(BOOL started, NSError * _Nullable error))completion;
/// Request cancellation of preflight only. Await start completion before
/// releasing its save seal; native entry will not be invoked after acceptance.
- (BOOL)cancelPreparation:(NSError **)error;
/// Each result: state applied/restartRequired/rejected/unsupported,
/// desiredValue, effectiveValue (NSNull when unknown), message.
- (NSDictionary<NSString *, NSDictionary *> *)applyDesiredSettings:(NSDictionary<NSString *, id> *)settings;
/// Clears all actual host input sources, releases pointer capture and informs
/// native graphics/focus. This is not a promise that guest CPU execution paused.
- (BOOL)captureInput:(NSError **)error;
- (BOOL)restoreInput:(NSError **)error;
/// Revalidate current oriented bounds and resize presentation only. Outcome
/// state applied/restartRequired/rejected; incompatible layouts capture input.
/// Returning to compatible bounds never restores focus automatically.
- (NSDictionary<NSString *, id> *)updatePresentationLayout;
/// Existing TOTK accepts one native pad; additional connected players refuse.
- (BOOL)submitInput:(const struct mng_session_input *)input error:(NSError **)error;
/// Host owns its display/render loop. Tick never manufactures frame evidence.
- (BOOL)tick:(NSError **)error;
/// Single-use host currently refuses CPU pause and teardown/relaunch. The lease
/// and save seal must remain until process exit; caller must not finishSession.
- (BOOL)pause:(BOOL)paused error:(NSError **)error;
- (BOOL)close:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
