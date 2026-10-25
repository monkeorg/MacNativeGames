#pragma once
#include <stdint.h>
#include <string.h>

/* HID keyboard usages enter here. Only these controller actions reach the runtime. */
enum { TOTK_KEY_ACTIONS = 24 };
static const unsigned short totk_key_defaults[TOTK_KEY_ACTIONS] = {26,4,22,7,82,80,81,79,13,14,12,24,29,6,20,8,226,225,40,43,9,23,11,10};
static const unsigned char totk_key_outputs[TOTK_KEY_ACTIONS] = {13,0,1,2,126,123,125,124,38,40,34,32,6,8,12,14,58,56,36,48,3,17,4,5};
static inline int totk_key_supported(unsigned key) {
    return (key >= 4 && key <= 40) || (key >= 42 && key <= 44) || (key >= 79 && key <= 82) ||
        key == 225 || key == 226 || key == 229 || key == 230;
}
typedef struct {
    unsigned char sources[256], output[256], references[128];
} TOTKKeyboardState;
typedef void (*TOTKKeyboardEmit)(unsigned code, int down);
static inline int totk_keyboard_event(TOTKKeyboardState *state, unsigned key, unsigned source, int down,
                                      const unsigned short bindings[TOTK_KEY_ACTIONS], TOTKKeyboardEmit emit) {
    if (key >= 256 || !source || source > 2) return 0;
    if (!down) {
        int handled = state->output[key] != 0 && (state->sources[key] & source) != 0;
        if (!handled) return 0;
        /* GCKeyboard and UIKit report copies of the same physical key, not independent holds. */
        state->sources[key] = 0;
        unsigned output = state->output[key] - 1;
        state->output[key] = 0;
        if (!--state->references[output]) emit(output,0);
        return 1;
    }
    if (!totk_key_supported(key)) return 0;
    if (state->sources[key]) { state->sources[key] |= source; return state->output[key] != 0; }
    for (unsigned i=0; i<TOTK_KEY_ACTIONS; i++) if (bindings[i] == key) {
        unsigned output = totk_key_outputs[i];
        state->sources[key] = source;
        state->output[key] = (unsigned char)(output + 1);
        if (!state->references[output]++) emit(output,1);
        return 1;
    }
    return 0;
}
static inline void totk_keyboard_clear(TOTKKeyboardState *state, TOTKKeyboardEmit emit) {
    for (unsigned i=0; i<128; i++) if (state->references[i]) emit(i,0);
    memset(state,0,sizeof(*state));
}
