#ifndef MNG_INPUT_H
#define MNG_INPUT_H
#include "mng_players.h"
#include <stddef.h>

/* Physical schema is deliberately distinct from guest portable bits:
 * south,east,west,north,l3,r3,l1,r1,l2,r2,menu,view,left,up,right,down,
 * touchpad,mouse_left,mouse_right,mouse_middle,mouse4,mouse5. Home/Capture
 * are host commands and are never physical mapping slots or guest outputs. */
#define MNG_PHYSICAL_BUTTONS 22u
#define MNG_PHYSICAL_MASK UINT32_C(0x3fffff)
#define MNG_INPUT_MAX_SOURCES 8u
enum mng_input_status { MNG_INPUT_OK, MNG_INPUT_INVALID, MNG_INPUT_LIMIT, MNG_INPUT_STALE, MNG_INPUT_NOMEM };
enum mng_controller_type { MNG_CONTROLLER_AUTO, MNG_CONTROLLER_XBOX, MNG_CONTROLLER_PLAYSTATION, MNG_CONTROLLER_SWITCH };
struct mng_physical_input { uint32_t buttons; float sticks[4], triggers[2]; };
/* Targets are zero or one portable guest button bit. Modes use the existing
 * original controller-map encoding: hold0,tap1,toggle2,aim3|(fire_slot<<3). */
struct mng_input_mapping { uint16_t targets[MNG_PHYSICAL_BUTTONS]; uint8_t modes[MNG_PHYSICAL_BUTTONS]; };
struct mng_input_mapper {
    uint32_t previous;
    uint64_t last_ns, tap_until[MNG_PHYSICAL_BUTTONS];
    uint8_t toggled[MNG_PHYSICAL_BUTTONS], moved[MNG_PHYSICAL_BUTTONS];
};
uint16_t mng_input_native_to_portable(uint16_t native_buttons);
uint16_t mng_input_portable_to_native(uint16_t portable_buttons);
void mng_input_mapping_default(struct mng_input_mapping *);
/* Complete overrides from defaults; bounded4096bytes, no embedded NUL. Reuses
 * the existing original controller-map grammar. Output unchanged on failure. */
enum mng_input_status mng_input_mapping_parse(const char *text, size_t length,
    struct mng_input_mapping *out, unsigned *error_line);
int mng_input_controller_type(const char *word);
/* GameController A/B/X/Y labels -> four physical positions. Auto uses bounded
 * category/vendor detection only; never inherits TOTK_FACE_BUTTONS or env. */
uint32_t mng_input_face_positions(int controller_type, const char *category,
    const char *vendor, int a, int b, int x, int y);
void mng_input_mapper_reset(struct mng_input_mapper *);
/* Serialized per-device state; reset on config, focus, assignment or disconnect.
 * Time is monotonic ns. Caller polls again to expire tap pulses even without
 * a fresh device event. Active aim suppresses its fire slot in EVERY mode and
 * cancels that slot's pending tap/toggle state (no delayed attack on aim release).
 * Rejects invalid state atomically, clamps finite axes. */
enum mng_input_status mng_input_map(struct mng_input_mapper *, const struct mng_input_mapping *,
    const struct mng_physical_input *, uint64_t now_ns, struct mng_input *out);
/* Only combine sources explicitly assigned to THE SAME player. OR buttons,
 * choose strongest signed axis (earlier source wins ties), max triggers. Never
 * enumerate or merge other player/controller slots. Output unchanged on error. */
enum mng_input_status mng_input_mix(const struct mng_input *sources, size_t count, struct mng_input *out);
#endif
