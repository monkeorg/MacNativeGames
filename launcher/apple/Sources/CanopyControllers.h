#import <Foundation/Foundation.h>
#include "mng_players.h"

NS_ASSUME_NONNULL_BEGIN
/// Main-thread owner of the app's GameController handlers and portable routing.
/// No automatic player assignment. IDs are ephemeral monotonic host IDs, never
/// hardware identifiers. The bridge does not persist or log controller data.
@interface CanopyControllers : NSObject
/// Bounded connected-device records: id NSNumber, name NSString,
/// player NSNumber (zero-based, -1 unassigned), supported NSNumber.
@property(nonatomic, readonly) NSArray<NSDictionary<NSString *, id> *> *devices;
/// Called on the main thread after routing/device/focus changes and accepted
/// input updates. The consumer can read each player's independent snapshot.
@property(nonatomic, copy, nullable) void (^stateDidChange)(void);
- (enum mng_player_status)assignDevice:(uint64_t)identifier toPlayer:(unsigned)player;
- (enum mng_player_status)unassignPlayer:(unsigned)player;
- (enum mng_player_status)swapPlayer:(unsigned)first withPlayer:(unsigned)second;
/// The host must deactivate on focus loss, pause or overlay input capture, and
/// reactivate when gameplay owns input again. Both transitions clear held state.
- (enum mng_player_status)setFocused:(BOOL)focused;
- (enum mng_player_status)readPlayer:(unsigned)player deviceID:(uint64_t *)identifier
                             input:(struct mng_input *)input;
@end
NS_ASSUME_NONNULL_END
