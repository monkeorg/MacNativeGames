#ifndef TOTK_IOS_MOUSE_CAPTURE_H
#define TOTK_IOS_MOUSE_CAPTURE_H

#include <stdbool.h>
#include <math.h>

// Keep the user's capture request separate from temporary UIKit interruptions.
// Every event must still have both focus and pointer lock before reaching the game.
typedef struct {
    bool requested;
    bool foreground;
    bool text_entry;
    bool key_window;
    bool active_scene;
} TOTKMouseCapture;

static inline bool totk_mouse_wants_capture(const TOTKMouseCapture *state) {
    return state->requested && state->foreground && !state->text_entry && state->key_window && state->active_scene;
}

static inline bool totk_mouse_accepts_input(const TOTKMouseCapture *state,
                                           bool runtime_focus, bool pointer_locked) {
    return totk_mouse_wants_capture(state) && runtime_focus && pointer_locked;
}

/* A zero report must not refresh the shared mouse-look counterweight after motion stops. */
static inline bool totk_mouse_has_motion(double dx, double dy) {
    return isfinite(dx) && isfinite(dy) && (dx != 0 || dy != 0);
}

#endif
