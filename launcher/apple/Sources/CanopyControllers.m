#import "CanopyControllers.h"
#import <GameController/GameController.h>

@implementation CanopyControllers {
    struct mng_players _players;
    NSMutableDictionary<NSNumber *, GCController *> *_controllers;
    NSMutableDictionary<NSNumber *, id> *_handlers;
    NSMutableDictionary<NSNumber *, NSNumber *> *_tokens;
    NSMutableDictionary<NSNumber *, NSNumber *> *_commandHeld;
    NSMutableArray<id> *_observers;
    uint64_t _nextIdentifier;
    uint64_t _commandEdges;
}
- (instancetype)init {
    NSAssert(NSThread.isMainThread, @"CanopyControllers belongs on the main thread");
    if ((self = [super init])) {
        mng_players_init(&_players);
        _controllers = [NSMutableDictionary dictionary];
        _handlers = [NSMutableDictionary dictionary];
        _tokens = [NSMutableDictionary dictionary];
        _commandHeld = [NSMutableDictionary dictionary];
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
    __weak CanopyControllers *weakSelf = self;
    __block uint64_t sequence = 0;
    GCExtendedGamepadValueChangedHandler handler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
        (void)element;
        CanopyControllers *owner = weakSelf;
        if (!owner || !NSThread.isMainThread || sequence == UINT64_MAX) return;
        uint64_t currentToken = 0;
        if (mng_players_token(&owner->_players, identifier, &currentToken) != MNG_PLAYER_OK || currentToken != token) return;
        uint64_t command = gamepad.buttonHome.isPressed ? UINT64_C(1) << 16 : 0;
        uint64_t previousCommand = [owner->_commandHeld[key] unsignedLongLongValue];
        uint64_t edges = command & ~previousCommand;
        owner->_commandHeld[key] = @(command);
        owner->_commandEdges |= edges;
        struct mng_input input = {0};
        GCControllerButtonInput *buttons[] = {gamepad.buttonA, gamepad.buttonB, gamepad.buttonX, gamepad.buttonY,
            gamepad.leftShoulder, gamepad.rightShoulder, gamepad.leftTrigger, gamepad.rightTrigger,
            gamepad.buttonMenu, gamepad.buttonOptions, gamepad.leftThumbstickButton, gamepad.rightThumbstickButton,
            gamepad.dpad.up, gamepad.dpad.down, gamepad.dpad.left, gamepad.dpad.right,
            gamepad.buttonHome};
        for (unsigned i=0; i<sizeof(buttons)/sizeof(buttons[0]); i++) if (buttons[i].isPressed) input.buttons |= UINT64_C(1)<<i;
        input.sticks[0]=gamepad.leftThumbstick.xAxis.value;
        input.sticks[1]=gamepad.leftThumbstick.yAxis.value;
        input.sticks[2]=gamepad.rightThumbstick.xAxis.value;
        input.sticks[3]=gamepad.rightThumbstick.yAxis.value;
        input.triggers[0]=gamepad.leftTrigger.value;
        input.triggers[1]=gamepad.rightTrigger.value;
        if (mng_players_update(&owner->_players, identifier, token, ++sequence, &input) == MNG_PLAYER_OK || edges) [owner changed];
    };
    _handlers[key] = [handler copy];
    _tokens[key] = @(token);
    pad.valueChangedHandler = handler;
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
- (enum mng_player_status)readPlayer:(unsigned)player deviceID:(uint64_t *)identifier input:(struct mng_input *)input {
    if (!NSThread.isMainThread) return MNG_PLAYER_INVALID;
    return mng_players_read(&_players, player, identifier, input);
}
- (uint64_t)consumeUICommandEdges {
    NSAssert(NSThread.isMainThread, @"CanopyControllers belongs on the main thread");
    uint64_t edges = _commandEdges; _commandEdges = 0; return edges;
}
@end
