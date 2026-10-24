#include <assert.h>
#include <stdio.h>
#include "mouse_capture.h"

int main(void) {
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
    puts("{\"status\":\"pass\"}");
}
