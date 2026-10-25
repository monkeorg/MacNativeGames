#import "keyboard_input.h"
#import "keyboard_state.h"
#if TARGET_OS_IPHONE
#import <GameController/GameController.h>
#endif
#include <math.h>

void runtime_input_key(unsigned code,int down);
void runtime_input_keyboard_clear(void);
static TOTKKeyboardState held;
#if TARGET_OS_IPHONE
static __weak UIViewController *keyboardHost;
static BOOL requested = YES, active = YES;
static unsigned commandKeys;
#endif

NSArray<NSString *> *TOTKKeyboardActions(void) {
    return @[@"Move forward",@"Move left",@"Move backward",@"Move right",@"Camera up",@"Camera left",@"Camera down",@"Camera right",
        @"A",@"B",@"X",@"Y",@"Left stick press",@"Right stick press",@"L",@"R",@"ZL",@"ZR",@"Plus",@"Minus",
        @"D-pad left",@"D-pad up",@"D-pad right",@"D-pad down"];
}
NSArray<NSNumber *> *TOTKKeyboardSupportedKeys(void) {
    NSMutableArray *keys = [NSMutableArray arrayWithObject:@0];
    for (unsigned i=0; i<256; i++) if (totk_key_supported(i)) [keys addObject:@(i)];
    return keys;
}
NSString *TOTKKeyboardKeyTitle(unsigned key) {
    if (!key) return @"None";
    if (key >= 4 && key <= 29) return [NSString stringWithFormat:@"%c",'A' + key - 4];
    if (key >= 30 && key <= 39) return [NSString stringWithFormat:@"%u",(key - 29) % 10];
    return @{@40:@"Return",@42:@"Backspace",@43:@"Tab",@44:@"Space",@79:@"Right arrow",@80:@"Left arrow",@81:@"Down arrow",@82:@"Up arrow",
        @225:@"Left Shift",@226:@"Left Option",@229:@"Right Shift",@230:@"Right Option"}[@(key)] ?: @"None";
}
unsigned TOTKKeyboardBinding(NSUserDefaults *defaults, NSUInteger action) {
    if (action >= TOTK_KEY_ACTIONS) return 0;
    NSString *name = [NSString stringWithFormat:@"TOTK_KEY_BIND_%lu",(unsigned long)action];
    id value = [defaults objectForKey:name];
    if ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [value doubleValue] == [value unsignedIntValue] &&
        (![value unsignedIntValue] || totk_key_supported([value unsignedIntValue]))) return [value unsignedIntValue];
    [defaults removeObjectForKey:name];
    return totk_key_defaults[action];
}
BOOL TOTKKeyboardSetBinding(NSUserDefaults *defaults, NSUInteger action, unsigned key) {
    if (action >= TOTK_KEY_ACTIONS || (key && !totk_key_supported(key))) return NO;
    for (unsigned i=0; key && i<TOTK_KEY_ACTIONS; i++) if (i != action && TOTKKeyboardBinding(defaults,i) == key) return NO;
    TOTKClearKeyboardInput();
    [defaults setInteger:key forKey:[NSString stringWithFormat:@"TOTK_KEY_BIND_%lu",(unsigned long)action]];
    return YES;
}
void TOTKClearKeyboardInput(void) {
    totk_keyboard_clear(&held,runtime_input_key);
    runtime_input_keyboard_clear();
}
#if TARGET_OS_IPHONE
void TOTKSetKeyboardInputEnabled(BOOL enabled) { requested = enabled; TOTKClearKeyboardInput(); }
static BOOL has_text_focus(UIView *view) {
    if (view.isFirstResponder && [view conformsToProtocol:@protocol(UITextInput)]) return YES;
    for (UIView *child in view.subviews) if (has_text_focus(child)) return YES;
    return NO;
}
static BOOL can_play(void) {
    return requested && active && !commandKeys && keyboardHost.view.window.isKeyWindow &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
        !keyboardHost.presentedViewController && !has_text_focus(keyboardHost.view.window);
}
static BOOL key_event(unsigned key, unsigned source, BOOL down) {
    if (key == 227 || key == 231) {
        unsigned bit = key == 227 ? 1 : 2;
        if (down) commandKeys |= bit; else commandKeys &= ~bit;
        TOTKClearKeyboardInput(); return NO;
    }
    if (!can_play()) { TOTKClearKeyboardInput(); return NO; }
    unsigned short bindings[TOTK_KEY_ACTIONS];
    for (unsigned i=0; i<TOTK_KEY_ACTIONS; i++) bindings[i] = (unsigned short)TOTKKeyboardBinding(NSUserDefaults.standardUserDefaults,i);
    return totk_keyboard_event(&held,key,source,down,bindings,runtime_input_key);
}
BOOL TOTKKeyboardPress(UIPress *press, BOOL down) {
    if (!press.key) return NO;
    if (press.key.modifierFlags & UIKeyModifierCommand) { TOTKClearKeyboardInput(); return NO; }
    return key_event((unsigned)press.key.keyCode,2,down);
}
static void attach_keyboard(void) {
    GCKeyboard.coalescedKeyboard.keyboardInput.keyChangedHandler = ^(GCKeyboardInput *input, GCControllerButtonInput *button, GCKeyCode key, BOOL down) {
        (void)input; (void)button;
        if (NSThread.isMainThread) key_event((unsigned)key,1,down);
        else dispatch_async(dispatch_get_main_queue(), ^{ key_event((unsigned)key,1,down); });
    };
}
void TOTKStartKeyboardInput(UIViewController *host) {
    keyboardHost = host;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:GCKeyboardDidConnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note; TOTKClearKeyboardInput(); commandKeys=0; attach_keyboard();
        }];
        [center addObserverForName:GCKeyboardDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note; TOTKClearKeyboardInput(); commandKeys=0;
        }];
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note; active=NO; commandKeys=0; TOTKClearKeyboardInput();
        }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note; active=YES; TOTKClearKeyboardInput();
        }];
        [center addObserverForName:UISceneWillDeactivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            if (note.object == keyboardHost.view.window.windowScene) { active=NO; commandKeys=0; TOTKClearKeyboardInput(); }
        }];
        [center addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            if (note.object == keyboardHost.view.window.windowScene) { active=YES; TOTKClearKeyboardInput(); }
        }];
        for (NSNotificationName name in @[UITextFieldTextDidBeginEditingNotification, UITextViewTextDidBeginEditingNotification]) {
            [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                (void)note; TOTKClearKeyboardInput();
            }];
        }
        for (NSNotificationName name in @[UIWindowDidResignKeyNotification, UIWindowDidBecomeKeyNotification]) {
            [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                if (note.object == keyboardHost.view.window) { commandKeys=0; TOTKClearKeyboardInput(); }
            }];
        }
    });
    attach_keyboard();
}
#endif
