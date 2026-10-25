#import <UIKit/UIKit.h>
#import "CanopySaveStore.h"
#import <dispatch/dispatch.h>
NS_ASSUME_NONNULL_BEGIN
/// Candidate-only TOTK reference-family reader/writer. The caller selects the
/// actual TOTK title and passes its EXISTING save-profile serial queue/store.
/// No new store, edit validator, active Apply, automatic import or compatibility
/// capability is created. Only an explicit raw unverified candidate share.
UIViewController *CanopyMakeTOTKSaveEditorController(CanopySaveStore *store,
    dispatch_queue_t existingSaveQueue);
NS_ASSUME_NONNULL_END
