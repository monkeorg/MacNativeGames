#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CanopyDiagnosticsPhase) {
    CanopyDiagnosticsPhaseUnknown, CanopyDiagnosticsPhaseIdle, CanopyDiagnosticsPhaseInspecting,
    CanopyDiagnosticsPhasePreparing, CanopyDiagnosticsPhaseVerifying, CanopyDiagnosticsPhaseComposing,
    CanopyDiagnosticsPhasePrepared, CanopyDiagnosticsPhasePreflight, CanopyDiagnosticsPhaseStarting,
    CanopyDiagnosticsPhaseActive, CanopyDiagnosticsPhaseInputCaptured, CanopyDiagnosticsPhaseCancelling,
    CanopyDiagnosticsPhaseFailed, CanopyDiagnosticsPhaseClosed, CanopyDiagnosticsPhaseUnsupported
};
typedef NS_ENUM(NSInteger, CanopyDiagnosticsError) {
    CanopyDiagnosticsErrorNone, CanopyDiagnosticsErrorUnknown, CanopyDiagnosticsErrorCancelled,
    CanopyDiagnosticsErrorInvalid, CanopyDiagnosticsErrorUnsupported, CanopyDiagnosticsErrorKeys,
    CanopyDiagnosticsErrorIntegrity, CanopyDiagnosticsErrorIO, CanopyDiagnosticsErrorBusy,
    CanopyDiagnosticsErrorUnverified, CanopyDiagnosticsErrorNativeStart,
    CanopyDiagnosticsErrorNativeBackend, CanopyDiagnosticsErrorLimit
};

/// No timers, file reads/writes, telemetry transport or automatic collection.
/// Event collection defaults off; disabling immediately discards its16 samples.
/// On-demand snapshot/export methods are for an explicit user request, even off.
/// Callers supply actual prepared results and observed state, never imported
/// metadata as a compatibility assertion. Unknown fields/free text are omitted.
@interface CanopyDiagnostics : NSObject
@property(nonatomic) BOOL enabled;
@property(nonatomic, readonly) NSUInteger recordedSampleCount;
+ (CanopyDiagnosticsPhase)phaseForRuntimeState:(nullable NSString *)state;
/// Reads only recognized domains/numeric codes. Never copies error text/info.
+ (CanopyDiagnosticsError)errorForError:(nullable NSError *)error;
/// Exact native callback units; unknown phases remain unspecified.
+ (NSString *)progressUnitForNativePhase:(nullable NSString *)phase;
/// Closed logical I/O/publication projection from one actual job completion.
/// Does not retain the supplied NSError/result or sample process state.
+ (NSDictionary<NSString *,id> *)preparationMetricsForResult:(nullable NSDictionary *)result
    error:(nullable NSError *)error;
/// Returns NO without sampling/retaining arguments when collection is off.
/// Preparation may use Catalog's nested integrity or Job's flat flags. Optional
/// phaseDone/phaseTotal are counts, with phaseUnit bytes/blocks/records; omitted
/// or unknown units are unspecified, never guessed from an overall percentage.
/// preparationIO accepts only scope logicalPayloadIO and observed streamed,
/// written, cloned-logical, compared-equal, resumed bytes and clone asset counts.
/// These are attempt counters, including failed attempts, never saved space or
/// proof of publication. Separate preparationPublished and
/// preparationPublicationMayHaveCompleted booleans preserve result uncertainty.
- (BOOL)recordPreparedEntry:(nullable NSDictionary<NSString *,id> *)entry
    phase:(CanopyDiagnosticsPhase)phase errorCode:(CanopyDiagnosticsError)error
    metrics:(nullable NSDictionary<NSString *,id> *)metrics;
/// Mach RSS/footprint describe the whole process, not guest-only memory or GPU
/// allocation. OS failures produce unavailable values, not zero estimates.
/// FPS is unavailable: frameLimit is configuration, not measured throughput.
- (NSDictionary<NSString *,id> *)snapshotPreparedEntry:(nullable NSDictionary<NSString *,id> *)entry
    phase:(CanopyDiagnosticsPhase)phase errorCode:(CanopyDiagnosticsError)error
    metrics:(nullable NSDictionary<NSString *,id> *)metrics;
/// Returns a redacted JSON document, at most64KiB. The caller owns any explicit
/// local export/share operation. No private file paths, device/profile identifiers, keys,
/// save contents, display names, raw stderr or localized error text are copied.
/// Title/generation/container hashes are intentional diagnostic metadata.
- (nullable NSData *)redactedJSONPreparedEntry:(nullable NSDictionary<NSString *,id> *)entry
    phase:(CanopyDiagnosticsPhase)phase errorCode:(CanopyDiagnosticsError)error
    metrics:(nullable NSDictionary<NSString *,id> *)metrics
    error:(NSError * _Nullable * _Nullable)failure;
@end

/// Actual host observations, read only during an explicit main-thread request.
/// Providers must be quick in-memory getters, never perform I/O or wait for a
/// worker. Capture host owners weakly when their lifetime includes this object.
/// Missing providers remain unknown. No timer or inferred performance counters.
@interface CanopyDiagnosticsSources : NSObject
@property(nonatomic, copy, nullable) NSDictionary<NSString *,id> * _Nullable (^preparedEntry)(void);
@property(nonatomic, copy, nullable) NSDictionary<NSString *,id> * _Nullable (^metrics)(void);
@property(nonatomic, copy, nullable) NSDictionary<NSString *,id> * _Nullable (^storageSnapshot)(void);
@property(nonatomic, copy, nullable) CanopyDiagnosticsPhase (^phase)(void);
@property(nonatomic, copy, nullable) CanopyDiagnosticsError (^errorCode)(void);
/// Sanitizes real provider values; records at most one sample when requested
/// and collection is enabled. Storage bytes cover listed verified/available
/// rows only, never total disk use, allocation or promised reclaimed space.
- (NSDictionary<NSString *,id> *)snapshotWithDiagnostics:(CanopyDiagnostics *)diagnostics
    recordIfEnabled:(BOOL)record;
/// Explicit user export; no files/network, same64KiB backend limit.
- (nullable NSData *)redactedJSONWithDiagnostics:(CanopyDiagnostics *)diagnostics
    error:(NSError * _Nullable * _Nullable)failure;
@end
NS_ASSUME_NONNULL_END
