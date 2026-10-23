#import "mouse_input.h"
#import <GameController/GameController.h>
#include "runtime.h"

static __weak UIViewController *mouseHost;
static BOOL mouseStarted, mouseEnabled, mouseForeground;

static BOOL mouse_ready(void) {
    return mouseEnabled && mouseForeground && runtime_front_focus() &&
        mouseHost.view.window.windowScene.pointerLockState.locked;
}

static BOOL mouse_prepare(void) {
    if (!mouse_ready()) return NO;
    if (!runtime_mouse_enabled()) runtime_mouse_toggle();
    return YES;
}

static void attach_mouse(GCMouse *mouse) {
    mouse.handlerQueue = dispatch_get_main_queue();
    GCMouseInput *input = mouse.mouseInput;
    input.mouseMovedHandler = ^(GCMouseInput *device, float dx, float dy) {
        (void)device;
        if (mouse_prepare()) runtime_mouse_move(dx, -dy);
    };
    NSArray *buttons = @[
        input.leftButton ?: NSNull.null,
        input.rightButton ?: NSNull.null,
        input.middleButton ?: NSNull.null,
    ];
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

BOOL TOTKMouseInputEnabled(void) { return mouseEnabled; }

void TOTKSetMouseInputEnabled(BOOL enabled) {
    NSCAssert(NSThread.isMainThread, @"Mouse UI state must change on the main thread");
    mouseEnabled = enabled;
    if (!enabled) runtime_mouse_release();
    [mouseHost setNeedsUpdateOfPrefersPointerLocked];
}

void TOTKStartMouseInput(UIViewController *gameController) {
    NSCAssert(NSThread.isMainThread, @"Mouse observers must start on the main thread");
    mouseHost = gameController;
    if (mouseStarted) return;
    mouseStarted = YES;
    mouseForeground = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:GCMouseDidConnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        attach_mouse(note.object);
    }];
    [center addObserverForName:GCMouseDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        GCMouseInput *input = ((GCMouse *)note.object).mouseInput;
        input.mouseMovedHandler = nil;
        input.leftButton.pressedChangedHandler = nil;
        input.rightButton.pressedChangedHandler = nil;
        input.middleButton.pressedChangedHandler = nil;
        runtime_mouse_release();
    }];
    [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        (void)note; mouseForeground = NO; runtime_mouse_release();
    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        (void)note; mouseForeground = YES;
    }];
    [center addObserverForName:UIPointerLockStateDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        if (note.userInfo[UIPointerLockStateSceneUserInfoKey] == mouseHost.view.window.windowScene && !mouse_ready()) runtime_mouse_release();
    }];
    for (GCMouse *mouse in GCMouse.mice) attach_mouse(mouse);
    TOTKSetMouseInputEnabled(YES);
}
