#import <Foundation/Foundation.h>
#include "mng_players.h"
#include "mng_input.h"

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
/// Drain host command edges (portable Home/Capture bits16/17). Physical held
/// state survives guest focus changes so resuming cannot replay held Home.
/// Commands are separate from guest snapshots; consume them before guest input.
- (uint64_t)consumeUICommandEdges;
/// One shared production compiler for controller and mouse target/mode options.
+ (BOOL)compileInputMapping:(struct mng_input_mapping *)mapping settings:(NSDictionary *)settings error:(NSError * _Nullable * _Nullable)error;
/// Per-player physical layout. Mapping values use existing Default/None or
/// target strings; defaults preserve position-based Xbox/PlayStation controls.
/// A changed configuration clears that device's held/pending input and epoch.
- (BOOL)configurePlayer:(unsigned)player controllerType:(NSString *)type
        buttonMappings:(NSDictionary<NSString *, NSString *> *)mappings error:(NSError **)error;
/// Apply the title's common layout to all four isolated player configurations.
- (BOOL)applySettings:(NSDictionary<NSString *, id> *)settings error:(NSError **)error;
- (enum mng_player_status)readPlayer:(unsigned)player deviceID:(uint64_t *)identifier
                             input:(struct mng_input *)input;
/// Gameplay consumer: polls timed mapping modes and drains short-tap edges once.
- (enum mng_player_status)consumePlayer:(unsigned)player deviceID:(uint64_t *)identifier
                                input:(struct mng_input *)input;
@end
NS_ASSUME_NONNULL_END
