#import "CanopyControllers.h"
#import "CanopySettings.h"
#import <GameController/GameController.h>
#include <time.h>
#include <string.h>

@interface CanopyMappedDevice : NSObject {
@public
    struct mng_input_mapping mapping;
    struct mng_input_mapper mapper;
    struct mng_physical_input physical;
    uint64_t token, sequence;
    int type;
}
@end
@implementation CanopyMappedDevice
@end

static BOOL ControllerError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"CanopyControllers" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static BOOL ControllerConfiguration(NSString *type, NSDictionary *bindings, NSDictionary *modes, int *parsedType, struct mng_input_mapping *mapping, NSError **error) {
    if (![type isKindOfClass:NSString.class] || type.length > 32 ||
        ![bindings isKindOfClass:NSDictionary.class] || bindings.count > MNG_PHYSICAL_BUTTONS) return ControllerError(error,@"Invalid controller layout preferences.");
    int parsed = mng_input_controller_type(type.UTF8String);
    if (parsed < 0) return ControllerError(error,@"Unknown controller type.");
    if(![CanopyControllers compileInputMapping:mapping settings:@{@"buttonMappings":bindings,@"mappingModes":modes ?: @{}} error:error])return NO;
    *parsedType = parsed; return YES;
}

@implementation CanopyControllers {
    struct mng_players _players;
    NSMutableDictionary<NSNumber *, GCController *> *_controllers;
    NSMutableDictionary<NSNumber *, id> *_handlers;
    NSMutableDictionary<NSNumber *, NSNumber *> *_tokens;
    NSMutableDictionary<NSNumber *, NSNumber *> *_commandHeld;
    NSMutableDictionary<NSNumber *, CanopyMappedDevice *> *_mappedDevices;
    struct mng_input_mapping _mappings[MNG_PLAYER_COUNT];
    int _controllerTypes[MNG_PLAYER_COUNT];
    NSMutableArray<id> *_observers;
    uint64_t _nextIdentifier;
    uint64_t _commandEdges;
}
+ (BOOL)compileInputMapping:(struct mng_input_mapping *)mapping settings:(NSDictionary *)settings error:(NSError **)error {
    if(!mapping || ![settings isKindOfClass:NSDictionary.class])return ControllerError(error,@"Invalid input map options.");
    NSString *text=[CanopySettings inputMappingTextWithTargets:settings[@"buttonMappings"] ?: @{} modes:settings[@"mappingModes"] ?: @{}];
    NSData *bytes=[text dataUsingEncoding:NSUTF8StringEncoding];
    if(!text || mng_input_mapping_parse(bytes.bytes,bytes.length,mapping,NULL)!=MNG_INPUT_OK)return ControllerError(error,@"The combined target/mode map was rejected.");
    return YES;
}

- (instancetype)init {
    NSAssert(NSThread.isMainThread, @"CanopyControllers belongs on the main thread");
    if ((self = [super init])) {
        mng_players_init(&_players);
        _controllers = [NSMutableDictionary dictionary];
        _handlers = [NSMutableDictionary dictionary];
        _tokens = [NSMutableDictionary dictionary];
        _commandHeld = [NSMutableDictionary dictionary];
        _mappedDevices = [NSMutableDictionary dictionary];
        for (unsigned i = 0; i < MNG_PLAYER_COUNT; i++) mng_input_mapping_default(&_mappings[i]);
        _observers = [NSMutableArray array];
        __weak CanopyControllers *weakSelf = self;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [_observers addObject:[center addObserverForName:GCControllerDidConnectNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            [weakSelf connected:notification.object];
        }]];
        [_observers addObject:[center addObserverForName:GCControllerDidDisconnectNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            [weakSelf disconnected:notification.object];
        }]];
        for (GCController *controller in GCController.controllers) [self connected:controller];
    }
    return self;
}
- (void)clearHandler:(NSNumber *)key {
    GCExtendedGamepad *pad = _controllers[key].extendedGamepad;
    if ((id)pad.valueChangedHandler == _handlers[key]) pad.valueChangedHandler = nil;
    [_handlers removeObjectForKey:key];
    [_tokens removeObjectForKey:key];
    [_mappedDevices removeObjectForKey:key];
}
- (void)dealloc {
    for (id observer in _observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
    for (NSNumber *key in _controllers) [self clearHandler:key];
}
- (void)changed { if (self.stateDidChange) self.stateDidChange(); }
- (NSNumber *)identifierForController:(GCController *)controller {
    for (NSNumber *key in _controllers) if (_controllers[key] == controller) return key;
    return nil;
}
- (void)connected:(id)object {
    if (![object isKindOfClass:GCController.class]) return;
    GCController *controller = object;
    if ([self identifierForController:controller] || _controllers.count >= MNG_DEVICE_COUNT || _nextIdentifier == UINT64_MAX) return;
    uint64_t identifier = _nextIdentifier + 1;
    if (mng_players_connect(&_players, identifier) != MNG_PLAYER_OK) return;
    _nextIdentifier = identifier;
    NSNumber *key = @(identifier);
    _controllers[key] = controller;
    controller.handlerQueue = dispatch_get_main_queue();
    [self installHandler:key];
    [self changed];
}
- (void)disconnected:(id)object {
    NSNumber *key = [self identifierForController:object];
    if (!key) return;
    [self clearHandler:key];
    (void)mng_players_disconnect(&_players, key.unsignedLongLongValue);
    [_controllers removeObjectForKey:key];
    [_commandHeld removeObjectForKey:key];
    [self changed];
    // Previously ignored devices can become eligible after a slot is freed.
    for (GCController *controller in GCController.controllers) [self connected:controller];
}
- (void)installHandler:(NSNumber *)key {
    GCExtendedGamepad *pad = _controllers[key].extendedGamepad;
    if (!pad) return;
    uint64_t identifier = key.unsignedLongLongValue, token = 0;
    if (mng_players_token(&_players, identifier, &token) != MNG_PLAYER_OK) return;
    // Unaffected devices retain their handler and sequence after another
    // player's assignment. Restarting at sequence zero would discard input.
    if (_handlers[key] && _tokens[key].unsignedLongLongValue == token &&
        (id)pad.valueChangedHandler == _handlers[key]) return;
    [self clearHandler:key];
    CanopyMappedDevice *mapped = [CanopyMappedDevice new]; mapped->token = token;
    mng_input_mapping_default(&mapped->mapping);
    for (unsigned player = 0; player < MNG_PLAYER_COUNT; player++) if (_players.seats[player] == identifier) {
        mapped->mapping = _mappings[player]; mapped->type = _controllerTypes[player]; break;
    }
    _mappedDevices[key] = mapped;
    __weak CanopyControllers *weakSelf = self;
    GCExtendedGamepadValueChangedHandler handler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
        (void)element;
        CanopyControllers *owner = weakSelf;
        if (!owner || !NSThread.isMainThread || mapped->sequence == UINT64_MAX) return;
        uint64_t currentToken = 0;
        if (mng_players_token(&owner->_players, identifier, &currentToken) != MNG_PLAYER_OK || currentToken != token) return;
        uint64_t command = gamepad.buttonHome.isPressed ? UINT64_C(1) << 16 : 0;
        uint64_t previousCommand = [owner->_commandHeld[key] unsignedLongLongValue];
        uint64_t edges = command & ~previousCommand;
        owner->_commandHeld[key] = @(command);
        owner->_commandEdges |= edges;
        GCController *controller = owner->_controllers[key];
        struct mng_physical_input physical = {0};
        physical.buttons = mng_input_face_positions(mapped->type,controller.productCategory.UTF8String,controller.vendorName.UTF8String,
            gamepad.buttonA.isPressed,gamepad.buttonB.isPressed,gamepad.buttonX.isPressed,gamepad.buttonY.isPressed);
        GCControllerButtonInput *buttons[] = {gamepad.leftThumbstickButton,gamepad.rightThumbstickButton,
            gamepad.leftShoulder,gamepad.rightShoulder,gamepad.leftTrigger,gamepad.rightTrigger,
            gamepad.buttonMenu,gamepad.buttonOptions,gamepad.dpad.left,gamepad.dpad.up,gamepad.dpad.right,gamepad.dpad.down};
        for (unsigned i = 0; i < sizeof(buttons)/sizeof(buttons[0]); i++) if (buttons[i].isPressed) physical.buttons |= UINT32_C(1) << (i+4);
        if ([gamepad isKindOfClass:GCDualSenseGamepad.class] && ((GCDualSenseGamepad *)gamepad).touchpadButton.isPressed) physical.buttons |= UINT32_C(1)<<16;
        if ([gamepad isKindOfClass:GCDualShockGamepad.class] && ((GCDualShockGamepad *)gamepad).touchpadButton.isPressed) physical.buttons |= UINT32_C(1)<<16;
        physical.sticks[0]=gamepad.leftThumbstick.xAxis.value; physical.sticks[1]=gamepad.leftThumbstick.yAxis.value;
        physical.sticks[2]=gamepad.rightThumbstick.xAxis.value; physical.sticks[3]=gamepad.rightThumbstick.yAxis.value;
        physical.triggers[0]=gamepad.leftTrigger.value; physical.triggers[1]=gamepad.rightTrigger.value;
        if ([owner deliverPhysical:&physical identifier:identifier mapped:mapped] == MNG_PLAYER_OK || edges) [owner changed];
    };
    _handlers[key] = [handler copy];
    _tokens[key] = @(token);
    pad.valueChangedHandler = handler;
}
- (enum mng_player_status)deliverPhysical:(const struct mng_physical_input *)physical identifier:(uint64_t)identifier mapped:(CanopyMappedDevice *)mapped {
    if (mapped->sequence == UINT64_MAX) return MNG_PLAYER_LIMIT;
    uint64_t current = 0;
    if (mng_players_token(&_players,identifier,&current) != MNG_PLAYER_OK || current != mapped->token) return MNG_PLAYER_STALE;
    struct timespec clock;
    if (clock_gettime(CLOCK_MONOTONIC,&clock) != 0) return MNG_PLAYER_INVALID;
    uint64_t now = (uint64_t)clock.tv_sec * UINT64_C(1000000000) + (uint64_t)clock.tv_nsec;
    struct mng_input_mapper next = mapped->mapper; struct mng_input input;
    enum mng_input_status status = mng_input_map(&next,&mapped->mapping,physical,now,&input);
    if (status != MNG_INPUT_OK) return status == MNG_INPUT_STALE ? MNG_PLAYER_STALE : MNG_PLAYER_INVALID;
    enum mng_player_status result = mng_players_update(&_players,identifier,current,mapped->sequence+1,&input);
    if (result == MNG_PLAYER_OK) { mapped->mapper = next; mapped->physical = *physical; mapped->sequence++; }
    return result;
}
- (void)refreshHandlers {
    // Capture the new token in a new block; queued old blocks keep old tokens.
    for (NSNumber *key in _controllers) [self installHandler:key];
    [self changed];
}
- (NSArray<NSDictionary<NSString *, id> *> *)devices {
    NSAssert(NSThread.isMainThread, @"CanopyControllers belongs on the main thread");
    NSMutableArray *devices = [NSMutableArray array];
    for (NSNumber *key in [_controllers.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSInteger player = -1;
        for (unsigned i=0; i<MNG_PLAYER_COUNT; i++) if (_players.seats[i] == key.unsignedLongLongValue) player = (NSInteger)i;
        [devices addObject:@{@"id":key, @"name":_controllers[key].vendorName ?: @"Controller",
            @"player":@(player), @"supported":@(_controllers[key].extendedGamepad != nil)}];
    }
    return [devices copy];
}
- (enum mng_player_status)assignDevice:(uint64_t)identifier toPlayer:(unsigned)player {
    if (!NSThread.isMainThread) return MNG_PLAYER_INVALID;
    GCController *controller = _controllers[@(identifier)];
    if (controller && !controller.extendedGamepad) return MNG_PLAYER_INVALID;
    enum mng_player_status status = mng_players_assign(&_players, player, identifier);
    if (status == MNG_PLAYER_OK) [self refreshHandlers];
    return status;
}
- (enum mng_player_status)unassignPlayer:(unsigned)player {
    if (!NSThread.isMainThread) return MNG_PLAYER_INVALID;
    enum mng_player_status status = mng_players_unassign(&_players, player);
    if (status == MNG_PLAYER_OK) [self refreshHandlers];
    return status;
}
- (enum mng_player_status)swapPlayer:(unsigned)first withPlayer:(unsigned)second {
    if (!NSThread.isMainThread) return MNG_PLAYER_INVALID;
    enum mng_player_status status = mng_players_swap(&_players, first, second);
    if (status == MNG_PLAYER_OK) [self refreshHandlers];
    return status;
}
- (enum mng_player_status)setFocused:(BOOL)focused {
    if (!NSThread.isMainThread) return MNG_PLAYER_INVALID;
    enum mng_player_status status = mng_players_focus(&_players, focused ? 1:0);
    if (status == MNG_PLAYER_OK || status == MNG_PLAYER_LIMIT) [self refreshHandlers];
    return status;
}
- (BOOL)installConfiguration:(const struct mng_input_mapping *)mapping type:(int)type player:(unsigned)player error:(NSError **)error {
    if (_controllerTypes[player] == type && !memcmp(&_mappings[player],mapping,sizeof(*mapping))) return YES;
    uint64_t identifier = _players.seats[player];
    if (identifier && mng_players_reset_device(&_players,identifier) != MNG_PLAYER_OK) return ControllerError(error,@"The controller input epoch could not be reset.");
    _mappings[player] = *mapping; _controllerTypes[player] = type;
    if (identifier) [self installHandler:@(identifier)];
    return YES;
}
- (BOOL)configurePlayer:(unsigned)player controllerType:(NSString *)type buttonMappings:(NSDictionary *)mappings error:(NSError **)error {
    NSAssert(NSThread.isMainThread,@"Controller configuration belongs on main thread");
    if (player >= MNG_PLAYER_COUNT) return ControllerError(error,@"Invalid player seat.");
    struct mng_input_mapping mapping; int parsedType;
    if (!ControllerConfiguration(type,mappings,@{},&parsedType,&mapping,error)) return NO;
    BOOL okay = [self installConfiguration:&mapping type:parsedType player:player error:error];
    if (okay) [self changed];
    return okay;
}
- (BOOL)applySettings:(NSDictionary *)settings error:(NSError **)error {
    NSAssert(NSThread.isMainThread,@"Controller configuration belongs on main thread");
    if (![settings isKindOfClass:NSDictionary.class]) return ControllerError(error,@"Invalid controller settings.");
    struct mng_input_mapping mapping; int type;
    if (!ControllerConfiguration(settings[@"controllerType"],settings[@"buttonMappings"],settings[@"mappingModes"] ?: @{},&type,&mapping,error)) return NO;
    unsigned resets = 0;
    for (unsigned player = 0; player < MNG_PLAYER_COUNT; player++) if (_players.seats[player] &&
        (_controllerTypes[player] != type || memcmp(&_mappings[player],&mapping,sizeof(mapping)))) resets++;
    if (resets > UINT64_MAX - _players.next_token) return ControllerError(error,@"Controller input epochs are exhausted; restart this app.");
    for (unsigned player = 0; player < MNG_PLAYER_COUNT; player++) if (![self installConfiguration:&mapping type:type player:player error:error]) return NO;
    [self changed]; return YES;
}
- (enum mng_player_status)readPlayer:(unsigned)player deviceID:(uint64_t *)identifier input:(struct mng_input *)input {
    if (!NSThread.isMainThread) return MNG_PLAYER_INVALID;
    return mng_players_read(&_players, player, identifier, input);
}
- (enum mng_player_status)consumePlayer:(unsigned)player deviceID:(uint64_t *)identifier input:(struct mng_input *)input {
    if (!NSThread.isMainThread || player >= MNG_PLAYER_COUNT || !identifier || !input) return MNG_PLAYER_INVALID;
    uint64_t device = _players.seats[player]; CanopyMappedDevice *mapped = _mappedDevices[@(device)];
    if (_players.focused && mapped) {
        enum mng_player_status status = [self deliverPhysical:&mapped->physical identifier:device mapped:mapped];
        if (status != MNG_PLAYER_OK) return status;
    }
    struct mng_input routed;
    enum mng_player_status status = mng_players_consume(&_players,player,identifier,&routed);
    if (status != MNG_PLAYER_OK) return status;
    return mng_input_mix(&routed,1,input) == MNG_INPUT_OK ? MNG_PLAYER_OK : MNG_PLAYER_INVALID;
}
- (uint64_t)consumeUICommandEdges {
    NSAssert(NSThread.isMainThread, @"CanopyControllers belongs on the main thread");
    uint64_t edges = _commandEdges; _commandEdges = 0; return edges;
}
@end
