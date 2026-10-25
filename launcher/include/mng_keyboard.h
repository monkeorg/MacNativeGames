#ifndef MNG_KEYBOARD_H
#define MNG_KEYBOARD_H
#include "mng_input.h"
#include "../../games/totk/ios/Sources/keyboard_state.h"
#define MNG_KEY_ACTIONS 24u
struct mng_keyboard {
    TOTKKeyboardState held;
    unsigned short bindings[MNG_KEY_ACTIONS];
    struct mng_input input;
    uint64_t pressed_edges;
};
const char *mng_keyboard_action_name(unsigned action);
int mng_keyboard_key_supported(unsigned usage);
void mng_keyboard_defaults(unsigned short out[MNG_KEY_ACTIONS]);
int mng_keyboard_bindings_valid(const unsigned short bindings[MNG_KEY_ACTIONS]);
void mng_keyboard_init(struct mng_keyboard *);
/* Valid bindings replace atomically and clear old held/queued actions. Zero is
 * None; all nonzero HID usages must be unique. Escape/Command are reserved. */
int mng_keyboard_set_bindings(struct mng_keyboard *, const unsigned short bindings[MNG_KEY_ACTIONS]);
void mng_keyboard_clear(struct mng_keyboard *);
/* source1=GCKeyboard,2=UIKit copies of one physical key. Returns1handled,
 *0unhandled,-1invalid. Releases use the original pressed action. */
int mng_keyboard_event(struct mng_keyboard *, unsigned usage, unsigned source, int down);
int mng_keyboard_consume(struct mng_keyboard *, struct mng_input *out);
#endif
