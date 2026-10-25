/* Exercise the production keyboard queue without a guest or a controller. */
#include "../games/totk/runtime/input.c"
#include <assert.h>
static unsigned controller_clears;
void runtime_gamepad_clear(void) { controller_clears++; }
int main(void) {
    runtime_input_key_synthetic(38,1);
    runtime_input_key_synthetic(38,0);
    runtime_input_key_synthetic(13,1);
    assert(pending == 1 && keys[13]);
    runtime_input_keyboard_clear();
    assert(!pending && !keys[13] && !controller_clears);
    runtime_input_keyboard_clear();
    assert(!pending && !controller_clears);
    runtime_input_clear();
    assert(controller_clears == 1);
    puts("PASS");
    return 0;
}
