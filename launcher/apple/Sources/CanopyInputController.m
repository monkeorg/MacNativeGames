#import "CanopyInputController.h"
#import "CanopyTouchPad.h"
#import "CanopySettings.h"
#import <GameController/GameController.h>
#include "mng_keyboard.h"
#include "mng_pointer.h"
#include <time.h>

@interface CanopyMouseDevice : NSObject {
@public struct mng_pointer pointer;
}
@property(nonatomic,strong) GCMouse *mouse;
@property(nonatomic,copy) id motionHandler;
@property(nonatomic,copy) NSArray *buttonInputs;
@property(nonatomic,copy) NSArray *buttonHandlers;
@end
@implementation CanopyMouseDevice
@end

static uint64_t InputNow(void) {
    struct timespec now;if(clock_gettime(CLOCK_MONOTONIC,&now)!=0)return 0;
    return (uint64_t)now.tv_sec*UINT64_C(1000000000)+(uint64_t)now.tv_nsec;
}
static BOOL TextOwnsInput(UIView *view) {
    if(view.isFirstResponder && [view conformsToProtocol:@protocol(UITextInput)])return YES;
    for(UIView *child in view.subviews)if(TextOwnsInput(child))return YES;
    return NO;
}
static NSArray *MouseButtons(GCMouseInput *input) {
    NSArray *extra=input.auxiliaryButtons;
    return @[input.leftButton ?: NSNull.null,input.rightButton ?: NSNull.null,input.middleButton ?: NSNull.null,
        extra.count>0?extra[0]:NSNull.null,extra.count>1?extra[1]:NSNull.null];
}
static NSDictionary *Applied(id value,NSString *message) {
    return @{@"state":@"applied",@"desiredValue":value,@"effectiveValue":value,@"message":message};
}
@implementation CanopyInputController {
    __weak UIViewController *_host;
    __weak UIView *_hostView;
    CanopyControllers *_controllers;
    CanopyTouchPad *_touch;
    struct mng_keyboard _keyboard;
    NSMutableArray<CanopyMouseDevice *> *_mice;
    NSMutableArray<id> *_observers;
    NSDictionary *_settings;
    GCKeyboard *_attachedKeyboard;
    id _keyboardHandler;
    uint64_t _epoch;
    unsigned _localPlayer;
    BOOL _captured,_textEntry,_touchEnabled,_mouseEnabled,_eligible,_rebuilding;
}
- (instancetype)initWithHostController:(UIViewController *)host hostView:(UIView *)view
                           controllers:(CanopyControllers *)controllers localPlayer:(unsigned)player {
    NSAssert(NSThread.isMainThread,@"Frontend input belongs on main thread");
    if(player>=MNG_PLAYER_COUNT)return nil;
    if((self=[super init])) {
        _host=host;_hostView=view;_controllers=controllers;_localPlayer=player;_captured=YES;_mouseEnabled=YES;_epoch=1;
        mng_keyboard_init(&_keyboard);_settings=CanopySettings.defaults;
        _mice=[NSMutableArray array];_observers=[NSMutableArray array];
        _touch=[[CanopyTouchPad alloc] initWithFrame:view.bounds];_touch.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        _touch.hidden=YES;_touch.userInteractionEnabled=NO;[view addSubview:_touch];
        __weak CanopyInputController *weakSelf=self;
        for(NSNotificationName name in @[GCKeyboardDidConnectNotification,GCKeyboardDidDisconnectNotification,
            GCMouseDidConnectNotification,GCMouseDidDisconnectNotification,UIApplicationWillResignActiveNotification,
            UIApplicationDidBecomeActiveNotification,UIWindowDidResignKeyNotification,UIWindowDidBecomeKeyNotification,
            UISceneWillDeactivateNotification,UISceneDidActivateNotification,UIKeyboardWillShowNotification,
            UIKeyboardDidHideNotification,UIPointerLockStateDidChangeNotification]) {
            [_observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){[weakSelf notified:note];}]];
        }
        [self rebuildHardware];[self refreshGates];
    }
    return self;
}
- (unsigned)localPlayer{return _localPlayer;}
- (BOOL)hasLocalInput{return !_captured && (_touchEnabled || _attachedKeyboard || (_mouseEnabled && _mice.count));}
- (BOOL)eligible {
    UIWindow *window=_hostView.window;
    return !_captured && !_host.presentedViewController && !_textEntry && window.isKeyWindow &&
        window.windowScene.activationState==UISceneActivationStateForegroundActive &&
        UIApplication.sharedApplication.applicationState==UIApplicationStateActive && !TextOwnsInput(window);
}
- (TOTKMouseCapture)captureState {
    UIWindow *window=_hostView.window;
    return (TOTKMouseCapture){.requested=_mouseEnabled && !_captured && !_host.presentedViewController,.foreground=UIApplication.sharedApplication.applicationState==UIApplicationStateActive,
        .text_entry=_textEntry||TextOwnsInput(window),.key_window=window.isKeyWindow,
        .active_scene=window.windowScene.activationState==UISceneActivationStateForegroundActive};
}
- (BOOL)wantsPointerLock { TOTKMouseCapture state=[self captureState];return _mouseEnabled && _mice.count && totk_mouse_wants_capture(&state); }
- (BOOL)acceptsMouseInput { return _mouseEnabled && [self eligible] && _hostView.window.windowScene.pointerLockState.locked && _mice.count; }
- (void)clearInput {
    mng_keyboard_clear(&_keyboard);[_touch cancelInput];
    for(CanopyMouseDevice *device in _mice)mng_pointer_clear(&device->pointer);
}
- (void)refreshGates {
    BOOL eligible=[self eligible];
    if(eligible!=_eligible) {
        _eligible=eligible;[self clearInput];
        // Hardware text responders need not post keyboard notifications. Both
        // observed edges invalidate callbacks, including the one polling here.
        [self rebuildHardware];
    }
    _touch.userInteractionEnabled=eligible && _touchEnabled;_touch.hidden=!_touchEnabled || !eligible;
    TOTKMouseCapture capture=[self captureState];
    for(CanopyMouseDevice *device in _mice)mng_pointer_gate(&device->pointer,capture,eligible,_hostView.window.windowScene.pointerLockState.locked);
    [_host setNeedsUpdateOfPrefersPointerLocked];
}
- (void)setCaptured:(BOOL)captured {
    NSAssert(NSThread.isMainThread,@"Frontend capture belongs on main thread");
    _captured=captured;[self clearInput];_eligible=[self eligible];[self rebuildHardware];[self refreshGates];
}
- (void)notified:(NSNotification *)notification {
    if(([notification.name isEqual:UIWindowDidResignKeyNotification] || [notification.name isEqual:UIWindowDidBecomeKeyNotification]) && notification.object!=_hostView.window)return;
    if(([notification.name isEqual:UISceneWillDeactivateNotification] || [notification.name isEqual:UISceneDidActivateNotification]) && notification.object!=_hostView.window.windowScene)return;
    if([notification.name isEqual:UIPointerLockStateDidChangeNotification] && notification.userInfo[UIPointerLockStateSceneUserInfoKey]!=_hostView.window.windowScene)return;
    if([notification.name isEqual:UIKeyboardWillShowNotification])_textEntry=YES;
    if([notification.name isEqual:UIKeyboardDidHideNotification])_textEntry=NO;
    // Reinstall with a fresh epoch on grant/focus/text/device transitions. A
    // queued callback from before an interruption can never reassert a hold.
    [self clearInput];_eligible=[self eligible];[self rebuildHardware];[self refreshGates];
}
- (void)detachHardware {
    if((id)_attachedKeyboard.keyboardInput.keyChangedHandler==_keyboardHandler)_attachedKeyboard.keyboardInput.keyChangedHandler=nil;
    _attachedKeyboard=nil;_keyboardHandler=nil;
    for(CanopyMouseDevice *device in _mice) {
        GCMouseInput *input=device.mouse.mouseInput;
        if((id)input.mouseMovedHandler==device.motionHandler)input.mouseMovedHandler=nil;
        for(NSUInteger i=0;i<device.buttonInputs.count;i++) {
            id button=device.buttonInputs[i],handler=device.buttonHandlers[i];
            if(button!=NSNull.null && (id)((GCControllerButtonInput *)button).pressedChangedHandler==handler)
                ((GCControllerButtonInput *)button).pressedChangedHandler=nil;
        }
        device.motionHandler=nil;device.buttonHandlers=nil;device.buttonInputs=nil;
    }
    [_mice removeAllObjects];
}
- (void)rebuildHardware {
    if(_rebuilding)return;
    _rebuilding=YES;
    [self detachHardware];
    if(_epoch==UINT64_MAX){_captured=YES;_eligible=NO;_rebuilding=NO;return;}
    uint64_t epoch=++_epoch;
    // Global GameController callbacks belong only to the eligible session.
    // Captured/failed/detached owners still invalidate old callbacks but may
    // not steal handlers from a newer owner on a connect notification.
    if(![self eligible]){_rebuilding=NO;return;}
    __weak CanopyInputController *weakSelf=self;
    _attachedKeyboard=GCKeyboard.coalescedKeyboard;_attachedKeyboard.handlerQueue=dispatch_get_main_queue();
    void (^handler)(GCKeyboardInput *,GCControllerButtonInput *,GCKeyCode,BOOL)=^(GCKeyboardInput *input,GCControllerButtonInput *button,GCKeyCode key,BOOL down){
        (void)button;CanopyInputController *owner=weakSelf;
        if(!owner || !NSThread.isMainThread || owner->_rebuilding || owner->_epoch!=epoch)return;
        [owner refreshGates];
        if(owner->_rebuilding || owner->_epoch!=epoch)return;
        BOOL command=[input buttonForKeyCode:(GCKeyCode)227].pressed || [input buttonForKeyCode:(GCKeyCode)231].pressed;
        if(command || key==227 || key==231){mng_keyboard_clear(&owner->_keyboard);return;}
        if(!owner->_eligible)return;
        (void)mng_keyboard_event(&owner->_keyboard,(unsigned)key,1,down);
    };
    _keyboardHandler=[handler copy];_attachedKeyboard.keyboardInput.keyChangedHandler=handler;
    struct mng_input_mapping mapping;[self mapping:&mapping settings:_settings];
    for(GCMouse *mouse in GCMouse.mice) {
        if(!_mouseEnabled)break; // Disabled sessions must not own global mouse handlers.
        if(_mice.count>=4)break;
        CanopyMouseDevice *device=[CanopyMouseDevice new];device.mouse=mouse;mng_pointer_init(&device->pointer);
        (void)mng_pointer_configure(&device->pointer,[_settings[@"mouseSensitivity"] intValue],[_settings[@"mouseInvertY"] boolValue],&mapping);
        [_mice addObject:device];mouse.handlerQueue=dispatch_get_main_queue();
        __weak CanopyMouseDevice *weakDevice=device;
        void (^motion)(GCMouseInput *,float,float)=^(GCMouseInput *input,float dx,float dy){
            (void)input;CanopyInputController *owner=weakSelf;
            if(!owner || !NSThread.isMainThread || owner->_rebuilding || owner->_epoch!=epoch)return;
            [owner refreshGates];CanopyMouseDevice *current=weakDevice;
            if(!current || owner->_rebuilding || owner->_epoch!=epoch || ![owner acceptsMouseInput])return;
            (void)mng_pointer_motion(&current->pointer,dx,-dy);
        };
        device.motionHandler=[motion copy];mouse.mouseInput.mouseMovedHandler=motion;
        NSArray *buttons=MouseButtons(mouse.mouseInput);
        NSMutableArray *handlers=[NSMutableArray arrayWithCapacity:5];
        for(unsigned index=0;index<5;index++)if(buttons[index]!=NSNull.null) {
            void (^pressedHandler)(GCControllerButtonInput *,float,BOOL)=^(GCControllerButtonInput *button,float value,BOOL pressed){
                (void)button;(void)value;CanopyInputController *owner=weakSelf;
                if(!owner || !NSThread.isMainThread || owner->_rebuilding || owner->_epoch!=epoch)return;
                [owner refreshGates];CanopyMouseDevice *current=weakDevice;
                if(!current || owner->_rebuilding || owner->_epoch!=epoch || ![owner acceptsMouseInput])return;
                (void)mng_pointer_button(&current->pointer,index,pressed,InputNow());
            };
            [handlers addObject:[pressedHandler copy]];((GCControllerButtonInput *)buttons[index]).pressedChangedHandler=pressedHandler;
        } else [handlers addObject:NSNull.null];
        device.buttonInputs=buttons;device.buttonHandlers=handlers;
    }
    _rebuilding=NO;
}
- (BOOL)mapping:(struct mng_input_mapping *)mapping settings:(NSDictionary *)settings {
    NSMutableString *text=[NSMutableString string];NSDictionary *bindings=settings[@"buttonMappings"];
    if(![bindings isKindOfClass:NSDictionary.class])return NO;
    for(NSString *key in [bindings.allKeys sortedArrayUsingSelector:@selector(compare:)])if(![bindings[key] isEqual:@"default"])[text appendFormat:@"%@ = %@\n",key,bindings[key]];
    NSData *bytes=[text dataUsingEncoding:NSUTF8StringEncoding];return mng_input_mapping_parse(bytes.bytes,bytes.length,mapping,NULL)==MNG_INPUT_OK;
}
- (NSDictionary *)applySettings:(NSDictionary *)settings {
    NSAssert(NSThread.isMainThread,@"Frontend settings belong on main thread");
    // The public settings store owns full validation; validate this boundary too.
    if(![CanopySettings areValidOptions:settings])return @{@"keyboardBindings":@{@"state":@"rejected",@"desiredValue":@{},@"effectiveValue":_settings[@"keyboardBindings"],@"message":@"Input options failed schema validation."}};
    NSMutableDictionary *complete=[CanopySettings.defaults mutableCopy];[complete addEntriesFromDictionary:settings];settings=[complete copy];
    struct mng_input_mapping mapping;unsigned short bindings[MNG_KEY_ACTIONS];mng_keyboard_defaults(bindings);
    NSArray *actions=CanopySettings.keyboardActions;
    for(unsigned i=0;i<MNG_KEY_ACTIONS;i++)bindings[i]=(unsigned short)[CanopySettings keyboardBindingForAction:actions[i] settings:settings];
    NSError *error=nil;
    if(![self mapping:&mapping settings:settings] || !mng_keyboard_bindings_valid(bindings) ||
       ![_controllers applySettings:settings error:&error])return @{@"keyboardBindings":@{@"state":@"rejected",@"desiredValue":settings[@"keyboardBindings"] ?: @{},@"effectiveValue":_settings[@"keyboardBindings"],@"message":error.localizedDescription ?: @"Input configuration was rejected."}};
    _settings=[settings copy];_touchEnabled=[settings[@"touch"] boolValue];_mouseEnabled=[settings[@"mouseEnabled"] boolValue];
    (void)mng_keyboard_set_bindings(&_keyboard,bindings);[self clearInput];_eligible=[self eligible];[self rebuildHardware];[self refreshGates];
    NSMutableDictionary *states=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"touch",@"mouseSensitivity",@"mouseInvertY",@"mouseEnabled",@"controllerType",@"buttonMappings",@"keyboardBindings"])
        states[key]=Applied(settings[key] ?: CanopySettings.defaults[key],@"Configured in this session's input frontend. Hardware availability and pointer-lock grant are checked for every event.");
    states[@"mouseEnabled"]=Applied(@(_mouseEnabled),_mouseEnabled ?
        @"Mouse input is enabled by this session's frontend policy. Motion and buttons still require active focus and an actual pointer-lock grant." :
        @"Mouse input is disabled. Pending mouse state was cleared, owned mouse handlers detached and the pointer-lock request withdrawn. System lock transition is asynchronous.");
    return states;
}
- (BOOL)handlePress:(UIPress *)press down:(BOOL)down {
    uint64_t epoch=_epoch;[self refreshGates];
    if(_epoch!=epoch || !_eligible || !press.key)return NO;
    if(press.key.modifierFlags & UIKeyModifierCommand){mng_keyboard_clear(&_keyboard);return NO;}
    return mng_keyboard_event(&_keyboard,(unsigned)press.key.keyCode,2,down)>0;
}
- (BOOL)consumeInput:(struct mng_input *)input now:(uint64_t)ns {
    if(!input || !ns)return NO;[self refreshGates];memset(input,0,sizeof(*input));if(!_eligible)return YES;
    struct mng_input sources[6]={0};(void)mng_keyboard_consume(&_keyboard,&sources[0]);[_touch consumeInput:&sources[1]];
    unsigned count=2;
    for(CanopyMouseDevice *device in _mice)if(mng_pointer_consume(&device->pointer,ns,&sources[count])==0)count++;
    return mng_input_mix(sources,count,input)==MNG_INPUT_OK;
}
- (void)dealloc {
    for(id observer in _observers)[NSNotificationCenter.defaultCenter removeObserver:observer];
    [self detachHardware];[_touch cancelInput];[_touch removeFromSuperview];
}
@end
