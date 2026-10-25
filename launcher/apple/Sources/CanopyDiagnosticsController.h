#import <UIKit/UIKit.h>
#import "CanopyDiagnostics.h"
NS_ASSUME_NONNULL_BEGIN
/// User-requested diagnostics only. Providers are in-memory main-thread getters.
/// The shared model defaults off; toggling off clears its capped history.
@interface CanopyDiagnosticsController : UITableViewController
- (instancetype)initWithDiagnostics:(CanopyDiagnostics *)diagnostics sources:(CanopyDiagnosticsSources *)sources;
@end
CanopyDiagnosticsController *CanopyMakeDiagnosticsController(CanopyDiagnostics *diagnostics,CanopyDiagnosticsSources *sources);
NS_ASSUME_NONNULL_END
