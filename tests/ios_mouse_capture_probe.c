#define _DEFAULT_SOURCE
#include <assert.h>
#include <stdio.h>
#include "mouse_capture.h"
#include "../games/totk/runtime/mouse_look.h"

int main(void) {
    assert(!totk_mouse_has_motion(0, 0));
    assert(!totk_mouse_has_motion(-0.0, 0));
    assert(!totk_mouse_has_motion(NAN, 1));
    assert(!totk_mouse_has_motion(1, INFINITY));
    assert(totk_mouse_has_motion(0.01, 0));
    assert(totk_mouse_has_motion(0, -0.01));
    MouseLookSettings settings = mouse_look_settings(NULL,NULL,NULL,NULL,NULL);
    MouseLook filtered = {0}, unfiltered = {0};
    mouse_look_move(&filtered, 0.1, 0, &settings);
    unfiltered = filtered;
    int32_t rx, ry; double gyro[3], acc[3];
    for (unsigned tick = 0; tick < 300; tick++) {
        mouse_look_move(&unfiltered, 0, 0, &settings);
        if (totk_mouse_has_motion(0, 0)) mouse_look_move(&filtered, 0, 0, &settings);
        mouse_look_tick(&unfiltered,&settings,&rx,&ry,gyro,acc);
        mouse_look_tick(&filtered,&settings,&rx,&ry,gyro,acc);
    }
    assert(unfiltered.x > 0.18); // Zero reports re-arm the 20% counterweight.
    assert(filtered.x == 0 && rx == 0); // The adapter must let the existing decay settle.
    TOTKMouseCapture state = {.foreground = true, .key_window = true, .active_scene = true};
    assert(!totk_mouse_wants_capture(&state)); // before Play
    state.requested = true;
    assert(totk_mouse_wants_capture(&state));
    assert(!totk_mouse_accepts_input(&state, true, false)); // system has not granted lock
    assert(totk_mouse_accepts_input(&state, true, true));
    state.requested = false; // open menu while a mouse button is held
    assert(!totk_mouse_accepts_input(&state, true, true));
    state.foreground = false; // app backgrounds with menu open
    state.requested = true; // dismissing menu preserves preference but cannot resume input
    assert(!totk_mouse_wants_capture(&state));
    state.foreground = true;
    state.key_window = false; // notification arrives before UIKit's property changes
    assert(!totk_mouse_wants_capture(&state));
    assert(!totk_mouse_accepts_input(&state, true, true));
    state.key_window = true;
    state.active_scene = false; // scene deactivated, app remains active
    assert(!totk_mouse_wants_capture(&state));
    assert(!totk_mouse_accepts_input(&state, true, true));
    state.active_scene = true;
    assert(!totk_mouse_accepts_input(&state, false, true));
    state.text_entry = true;
    assert(!totk_mouse_wants_capture(&state));
    assert(!totk_mouse_accepts_input(&state, true, true));
    state.text_entry = false;
    assert(totk_mouse_wants_capture(&state));
    assert(!totk_mouse_accepts_input(&state, true, false)); // lock must be granted again
    assert(totk_mouse_accepts_input(&state, true, true));
    mouse_look_move(&filtered, 0.1, 0, &settings);
    if (!totk_mouse_accepts_input(&state, true, false)) mouse_look_reset(&filtered);
    assert(filtered.x == 0); // Lock loss clears the previous capture session.
    for (unsigned report = 0; report < 100; report++) {
        if (totk_mouse_accepts_input(&state,true,true) && totk_mouse_has_motion(0,0))
            mouse_look_move(&filtered,0,0,&settings);
    }
    assert(filtered.x == 0); // A zero-only burst after relock does not resume the old turn.
    assert(totk_mouse_accepts_input(&state,true,true) && totk_mouse_has_motion(0.01,0));
    mouse_look_move(&filtered,0.01,0,&settings);
    assert(filtered.x >= 0.19); // Real movement retains the existing dead-zone counterweight.
    puts("{\"status\":\"pass\"}");
}
