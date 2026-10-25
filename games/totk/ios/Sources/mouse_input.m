#import "mouse_input.h"
#include "mouse_capture.h"
#import <GameController/GameController.h>
#include "runtime.h"

static __weak UIViewController *mouseHost;
static BOOL mouseStarted;
static TOTKMouseCapture mouseCapture;
static uint64_t mouseReports, mouseAccepted, mouseIgnoredReports, mouseBlockedReports, mouseLockChanges;

static void count_report(uint64_t *counter) { if (*counter < UINT64_MAX) (*counter)++; }

BOOL TOTKMouseInputWantsPointerLock(void) {
    return totk_mouse_wants_capture(&mouseCapture);
}

static BOOL mouse_ready(void) {
    UIWindow *window = mouseHost.view.window;
    return totk_mouse_accepts_input(&mouseCapture,
        runtime_front_focus(), window.windowScene.pointerLockState.locked);
}

NSDictionary<NSString *, NSNumber *> *TOTKMouseInputDiagnostics(void) {
    NSCAssert(NSThread.isMainThread, @"Mouse diagnostics must be read on the main thread");
    return @{@"devices":@(GCMouse.mice.count), @"requested":@(mouseCapture.requested),
        @"eligible":@(TOTKMouseInputWantsPointerLock()),
        @"locked":@(mouseHost.view.window.windowScene.pointerLockState.locked),
        @"runtimeFocus":@(runtime_front_focus()), @"reports":@(mouseReports), @"accepted":@(mouseAccepted),
        @"ignoredReports":@(mouseIgnoredReports), @"blockedReports":@(mouseBlockedReports), @"lockChanges":@(mouseLockChanges)};
}

static BOOL mouse_prepare(void) {
    if (!mouse_ready()) { runtime_mouse_release(); return NO; }
    if (!runtime_mouse_enabled()) runtime_mouse_toggle();
    return YES;
}

static NSArray *mouse_buttons(GCMouseInput *input) {
    // Public GameController API, iPadOS 14+: optional extras are ordered by the
    // device profile. The shared controller map has two auxiliary mouse slots.
    NSArray<GCControllerButtonInput *> *extra = input.auxiliaryButtons;
    return @[
        input.leftButton ?: NSNull.null,
        input.rightButton ?: NSNull.null,
        input.middleButton ?: NSNull.null,
        extra.count > 0 ? extra[0] : NSNull.null,
        extra.count > 1 ? extra[1] : NSNull.null,
    ];
}

static void attach_mouse(GCMouse *mouse) {
    mouse.handlerQueue = dispatch_get_main_queue();
    GCMouseInput *input = mouse.mouseInput;
    input.mouseMovedHandler = ^(GCMouseInput *device, float dx, float dy) {
        (void)device;
        count_report(&mouseReports);
        if (!mouse_prepare()) { count_report(&mouseBlockedReports); return; }
        if (!totk_mouse_has_motion(dx, dy)) { count_report(&mouseIgnoredReports); return; }
        count_report(&mouseAccepted);
        runtime_mouse_move(dx, -dy);
    };
    NSArray *buttons = mouse_buttons(input);
    for (NSUInteger i=0; i<buttons.count; i++) {
        if (buttons[i] == NSNull.null) continue;
        GCDeviceButtonInput *button = buttons[i];
        button.pressedChangedHandler = ^(GCControllerButtonInput *device, float value, BOOL pressed) {
            (void)device; (void)value;
            if (!pressed) runtime_mouse_button((int)i, 0);
            else if (mouse_prepare()) runtime_mouse_button((int)i, 1);
        };
    }
}

BOOL TOTKMouseInputEnabled(void) { return mouseCapture.requested; }

void TOTKSetMouseInputEnabled(BOOL enabled) {
    NSCAssert(NSThread.isMainThread, @"Mouse UI state must change on the main thread");
    mouseCapture.requested = enabled;
    if (!enabled) runtime_mouse_release();
    [mouseHost setNeedsUpdateOfPrefersPointerLocked];
}

void TOTKMouseInputHostDidAppear(void) {
    UIWindow *window = mouseHost.view.window;
    mouseCapture.key_window = window.isKeyWindow;
    mouseCapture.active_scene = window.windowScene.activationState == UISceneActivationStateForegroundActive;
    [mouseHost setNeedsUpdateOfPrefersPointerLocked];
}

void TOTKStartMouseInput(UIViewController *gameController) {
    NSCAssert(NSThread.isMainThread, @"Mouse observers must start on the main thread");
    mouseHost = gameController;
    if (mouseStarted) return;
    mouseStarted = YES;
    mouseCapture.foreground = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:GCMouseDidConnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        attach_mouse(note.object);
    }];
    [center addObserverForName:GCMouseDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        GCMouseInput *input = ((GCMouse *)note.object).mouseInput;
        input.mouseMovedHandler = nil;
        for (id button in mouse_buttons(input)) {
            if (button != NSNull.null) ((GCControllerButtonInput *)button).pressedChangedHandler = nil;
        }
        runtime_mouse_release();
    }];
    [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        (void)note; mouseCapture.foreground = NO; runtime_mouse_release();
        [mouseHost setNeedsUpdateOfPrefersPointerLocked];
    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        (void)note; mouseCapture.foreground = YES;
        [mouseHost setNeedsUpdateOfPrefersPointerLocked];
    }];
    [center addObserverForName:UISceneWillDeactivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        if (note.object != mouseHost.view.window.windowScene) return;
        mouseCapture.active_scene = false;
        runtime_mouse_release();
        [mouseHost setNeedsUpdateOfPrefersPointerLocked];
    }];
    [center addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        if (note.object != mouseHost.view.window.windowScene) return;
        mouseCapture.active_scene = true;
        [mouseHost setNeedsUpdateOfPrefersPointerLocked];
    }];
    [center addObserverForName:UIWindowDidResignKeyNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        if (note.object != mouseHost.view.window) return;
        mouseCapture.key_window = false;
        runtime_mouse_release();
        [mouseHost setNeedsUpdateOfPrefersPointerLocked];
    }];
    [center addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        if (note.object != mouseHost.view.window) return;
        mouseCapture.key_window = true;
        [mouseHost setNeedsUpdateOfPrefersPointerLocked];
    }];
    [center addObserverForName:UIKeyboardWillShowNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        (void)note; mouseCapture.text_entry = YES; runtime_mouse_release();
        [mouseHost setNeedsUpdateOfPrefersPointerLocked];
    }];
    [center addObserverForName:UIKeyboardDidHideNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        (void)note; mouseCapture.text_entry = NO;
        [mouseHost setNeedsUpdateOfPrefersPointerLocked];
    }];
    [center addObserverForName:UIPointerLockStateDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        if (note.userInfo[UIPointerLockStateSceneUserInfoKey] != mouseHost.view.window.windowScene) return;
        count_report(&mouseLockChanges);
        if (!mouse_ready()) runtime_mouse_release();
    }];
    for (GCMouse *mouse in GCMouse.mice) attach_mouse(mouse);
    TOTKSetMouseInputEnabled(YES);
}
