#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
NS_ASSUME_NONNULL_BEGIN
/// Worker-only refresh reads a new private export through TOTKSaveStore.
/// It must never return active-file URLs or publish a replacement.
typedef NSData * _Nullable (^TOTKCandidateRefresh)(NSError * _Nullable * _Nullable error);
/// Distinct from the online editor: no edited-data completion and no Apply.
/// Completion runs on main after dismissal; caller then cleans its snapshots.
@interface TOTKSaveCandidate : UITableViewController
- (instancetype)initWithProgressData:(NSData *)data queue:(dispatch_queue_t)queue
    refreshSnapshot:(TOTKCandidateRefresh)refresh completion:(void (^)(void))closed;
@end
NS_ASSUME_NONNULL_END
