/* Unrun iPhoneOS regression fixture. Build only in an isolated Apple test host
   with no physical controllers, excluding its separate gamepad.m translation
   unit: this fixture includes the production source to inspect queued state.
   No platform macros or SDK classes are replaced. */
#import <TargetConditionals.h>
#if !TARGET_OS_IPHONE
#error This fixture requires the actual iPhoneOS gamepad implementation.
#endif
#include "../../runtime/gamepad.m"

_Noreturn void runtime_fail(const char *message) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
uint64_t runtime_now_ns(void) { return 1000000000ULL; }
void runtime_feedback_attach(GCController *controller) { (void)controller; }
void runtime_feedback_detach(GCController *controller) { (void)controller; }
void runtime_feedback_quiet(void) {}
int runtime_gyro_enabled(void) { return 0; }
void runtime_motion_mouse(int on) { (void)on; }
void runtime_motion_feed_mouse(const double acc[3], const double gyro[3], uint64_t now) { (void)acc; (void)gyro; (void)now; }

static int failures;
static void check(int ok, const char *message) {
    if (!ok) { failures++; fprintf(stderr, "FAIL: %s\n", message); }
}
static RuntimeGamepadState read_state(void) {
    RuntimeGamepadState state;
    runtime_gamepad_read(&state);
    return state;
}
static void reset_state(void) {
    runtime_gamepad_clear();
    RuntimeGamepadState touch = {0}; runtime_touch_pad_set(&touch);
    // The production iOS HID placeholder supplies synthetic controller input
    // here only; runtime does not populate this placeholder on a real device.
    hidPad = (HIDPadState){.present = 1};
    mouseButtons = 0;
    atomic_store(&mouseMode, 1);
    controller_map_default(controllerMap, controllerModes);
}

enum { A = 1, B = 2, Y = 8 };
int main(void) { @autoreleasepool {
    if (GCController.controllers.count) {
        fprintf(stderr, "Run this isolated fixture without physical controllers.\n");
        return 2;
    }
    for (int button = 0; button < CONTROLLER_MOUSE_BUTTONS; button++) {
        reset_state();
        int slot = CONTROLLER_MOUSE_FIRST + button;
        controllerMap[slot] = Y; controllerModes[slot] = CONTROLLER_TAP;
        runtime_mouse_button(button, 1); runtime_mouse_button(button, 0);
        check(gamepadState.buttons == Y && mouseButtons == 0, "tap remains after its raw button is up");
        runtime_mouse_release();
        check(read_state().buttons == 0, "capture loss drops pending and live mouse tap");
        check(tapUntil[slot] == 0 && !(physicalPrev & mousePhysicalMask), "mouse tap state and physical history are clear");
    }

    reset_state();
    controllerModes[CONTROLLER_MOUSE_FIRST] = CONTROLLER_TOGGLE;
    runtime_mouse_button(0, 1); runtime_mouse_button(0, 0);
    check(toggleOn[CONTROLLER_MOUSE_FIRST] && gamepadState.buttons == Y, "mouse toggle survives raw release before cancellation");
    runtime_mouse_release();
    check(read_state().buttons == 0 && !toggleOn[CONTROLLER_MOUSE_FIRST], "capture loss drops mouse toggle");

    reset_state();
    runtime_mouse_button(0, 1); runtime_mouse_button(0, 0);
    check(mousePressedEdges == Y && gamepadState.buttons == 0, "short mouse hold leaves a queued edge");
    runtime_mouse_release();
    check(read_state().buttons == 0, "capture loss cancels even a raw-up queued mouse edge");

    reset_state();
    runtime_mouse_button(0, 1);
    hidPad.buttons = 1ULL << 2; refresh_gamepads(); // controller west also maps Y
    hidPad.buttons = 0; refresh_gamepads();
    runtime_mouse_release();
    check(read_state().buttons == Y, "controller tap overlapping held mouse Y is retained");
    check(read_state().buttons == 0, "retained controller tap is consumed once");

    reset_state();
    runtime_mouse_button(0, 1);
    RuntimeGamepadState touch = {.connected = 1, .buttons = Y}; runtime_touch_pad_set(&touch);
    touch.buttons = 0; runtime_touch_pad_set(&touch);
    runtime_mouse_release();
    check(read_state().buttons == Y, "touch tap sharing mouse Y is retained");
    check(read_state().buttons == 0, "retained touch tap is consumed once");

    reset_state();
    controllerModes[0] = CONTROLLER_TOGGLE; toggleOn[0] = 1;
    controllerModes[1] = CONTROLLER_TAP; tapUntil[1] = runtime_now_ns() + 400000000ULL;
    refresh_gamepads(); read_state();
    runtime_mouse_button(0, 1); runtime_mouse_release();
    check(toggleOn[0] && tapUntil[1] > runtime_now_ns(), "controller toggle and tap timers remain intact");
    check(read_state().buttons == (A | B), "controller synthetic input remains live");

    reset_state();
    hidPad.buttons = 1ULL << 1; refresh_gamepads();
    runtime_mouse_button(0, 1); runtime_mouse_release();
    check(read_state().buttons == A && physicalPrev == (1ULL << 1), "held controller input and physical history survive");

    reset_state();
    runtime_mouse_button(1, 1); runtime_mouse_button(0, 1);
    runtime_mouse_release();
    check(read_state().buttons == 0, "default aim/fire release leaves no queued mouse action");
    printf("{\"status\":\"%s\",\"probe\":\"ios-mouse-release\",\"failures\":%d}\n", failures ? "fail" : "pass", failures);
    return failures != 0;
}}
