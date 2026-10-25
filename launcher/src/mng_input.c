#include "mng_input.h"
/* Reuse this project's original, portable layout/parser logic without editing
 * the working Mac/TOTK frontend or inheriting its process-global preferences. */
#include "../../games/totk/runtime/controller_map.h"
#include "../../games/totk/runtime/gamepad_layout.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(CONTROLLER_BUTTONS==MNG_PHYSICAL_BUTTONS,"physical mapping schema changed");
_Static_assert(CONTROLLER_SWITCH_BUTTONS==16,"native button schema changed");
_Static_assert((int)MNG_CONTROLLER_AUTO==(int)GAMEPAD_TYPE_AUTO &&
    (int)MNG_CONTROLLER_XBOX==(int)GAMEPAD_TYPE_XBOX &&
    (int)MNG_CONTROLLER_PLAYSTATION==(int)GAMEPAD_TYPE_PLAYSTATION &&
    (int)MNG_CONTROLLER_SWITCH==(int)GAMEPAD_TYPE_SWITCH,"controller type schema changed");

static const unsigned native_to_portable[16]={0,1,2,3,10,11,4,5,6,7,8,9,14,12,15,13};
uint16_t mng_input_native_to_portable(uint16_t bits) {
    uint16_t result=0;
    for (unsigned i=0;i<16;i++) if (bits&(1u<<i)) result|=(uint16_t)(1u<<native_to_portable[i]);
    return result;
}
uint16_t mng_input_portable_to_native(uint16_t bits) {
    uint16_t result=0;
    for (unsigned i=0;i<16;i++) if (bits&(1u<<native_to_portable[i])) result|=(uint16_t)(1u<<i);
    return result;
}
void mng_input_mapping_default(struct mng_input_mapping *out) {
    if (!out) return;
    uint16_t map[CONTROLLER_BUTTONS]; controller_map_default(map,out->modes);
    for (unsigned i=0;i<MNG_PHYSICAL_BUTTONS;i++) out->targets[i]=mng_input_native_to_portable(map[i]);
}
enum mng_input_status mng_input_mapping_parse(const char *text,size_t length,
    struct mng_input_mapping *out,unsigned *error_line) {
    if (!out || (!text && length)) return MNG_INPUT_INVALID;
    if (length>4096) return MNG_INPUT_LIMIT;
    if (length && memchr(text,0,length)) return MNG_INPUT_INVALID;
    char *copy=malloc(length+1); if (!copy) return MNG_INPUT_NOMEM;
    if (length) memcpy(copy,text,length);
    copy[length]=0;
    uint16_t map[CONTROLLER_BUTTONS]; struct mng_input_mapping next;
    controller_map_default(map,next.modes); const char *problem=NULL;
    int line=controller_map_parse(copy,map,next.modes,&problem); free(copy);
    if (error_line) *error_line=(unsigned)line;
    if (line) return MNG_INPUT_INVALID;
    for (unsigned i=0;i<MNG_PHYSICAL_BUTTONS;i++) next.targets[i]=mng_input_native_to_portable(map[i]);
    *out=next; return MNG_INPUT_OK;
}
int mng_input_controller_type(const char *word) {
    if (!word) return -1;
    size_t n=0; while (n<32 && word[n]) n++;
    return n==32 ? -1:gamepad_type_parse(word);
}
static void bounded_name(const char *input,char output[257]) {
    size_t n=0; if (input) while (n<256 && input[n]) { output[n]=input[n]; n++; }
    output[n]=0;
}
uint32_t mng_input_face_positions(int type,const char *category,const char *vendor,int a,int b,int x,int y) {
    if (type<MNG_CONTROLLER_AUTO || type>MNG_CONTROLLER_SWITCH) return 0;
    char c[257],v[257]; bounded_name(category,c); bounded_name(vendor,v);
    int detected=type==MNG_CONTROLLER_AUTO ? gamepad_type_detect(c,v):type;
    return (uint32_t)gamepad_face_positions(!!a,!!b,!!x,!!y,detected!=MNG_CONTROLLER_SWITCH);
}
void mng_input_mapper_reset(struct mng_input_mapper *state) { if (state) memset(state,0,sizeof(*state)); }
static float bounded(float value,float low) { return value<low ? low:value>1 ? 1:value; }
static int mapping_valid(const struct mng_input_mapping *map) {
    for (unsigned i=0;i<MNG_PHYSICAL_BUTTONS;i++) {
        uint16_t target=map->targets[i]; unsigned mode=map->modes[i],kind=mode&7;
        if ((target && (target&(target-1))) || kind>CONTROLLER_AIM ||
            (kind!=CONTROLLER_AIM && mode!=kind) ||
            (kind==CONTROLLER_AIM && ((mode>>3)>=MNG_PHYSICAL_BUTTONS || (mode>>3)==i)) ||
            (!target && mode!=CONTROLLER_HOLD)) return 0;
    }
    return 1;
}
enum mng_input_status mng_input_map(struct mng_input_mapper *state,const struct mng_input_mapping *map,
    const struct mng_physical_input *physical,uint64_t now,struct mng_input *out) {
    if (!state || !map || !physical || !out || !now || (physical->buttons&~MNG_PHYSICAL_MASK) || !mapping_valid(map)) return MNG_INPUT_INVALID;
    if (state->last_ns && now<state->last_ns) return MNG_INPUT_STALE;
    struct mng_input result={0};
    for (unsigned i=0;i<4;i++) { if (!isfinite(physical->sticks[i])) return MNG_INPUT_INVALID; result.sticks[i]=bounded(physical->sticks[i],-1); }
    for (unsigned i=0;i<2;i++) { if (!isfinite(physical->triggers[i])) return MNG_INPUT_INVALID; result.triggers[i]=bounded(physical->triggers[i],0); }
    struct mng_input_mapper next=*state;
    uint32_t edges=physical->buttons&~next.previous,suppressed=0;
    int moving=result.sticks[0]!=0 || result.sticks[1]!=0;
    for (unsigned i=0;i<MNG_PHYSICAL_BUTTONS;i++) if ((map->modes[i]&7)==CONTROLLER_AIM &&
        (physical->buttons&(UINT32_C(1)<<i))) suppressed|=UINT32_C(1)<<(map->modes[i]>>3);
    for (unsigned i=0;i<MNG_PHYSICAL_BUTTONS;i++) {
        uint32_t bit=UINT32_C(1)<<i; unsigned kind=map->modes[i]&7;
        if (suppressed&bit) { next.tap_until[i]=0; next.toggled[i]=0; next.moved[i]=0; continue; }
        if (kind==CONTROLLER_TAP && (edges&bit)) next.tap_until[i]=now>UINT64_MAX-UINT64_C(400000000) ? UINT64_MAX:now+UINT64_C(400000000);
        if (kind==CONTROLLER_TOGGLE) {
            if (edges&bit) { next.toggled[i]=!next.toggled[i]; next.moved[i]=(uint8_t)moving; }
            if (next.toggled[i] && moving) next.moved[i]=1;
            if (next.toggled[i] && next.moved[i] && !moving) next.toggled[i]=0;
        }
        if (kind==CONTROLLER_AIM && (physical->buttons&bit)) {
            uint32_t fire=UINT32_C(1)<<(map->modes[i]>>3);
            if (!(physical->buttons&fire)) result.buttons|=map->targets[i];
        } else if ((kind==CONTROLLER_TAP && (now<next.tap_until[i] || (edges&bit))) ||
                   (kind==CONTROLLER_TOGGLE && next.toggled[i])) result.buttons|=map->targets[i];
    }
    uint32_t held=physical->buttons&~suppressed;
    for (unsigned i=0;i<MNG_PHYSICAL_BUTTONS;i++) if (map->modes[i]==CONTROLLER_HOLD && (held&(UINT32_C(1)<<i))) result.buttons|=map->targets[i];
    next.previous=physical->buttons; next.last_ns=now; *state=next; *out=result; return MNG_INPUT_OK;
}
enum mng_input_status mng_input_mix(const struct mng_input *sources,size_t count,struct mng_input *out) {
    if (!out || (!sources && count)) return MNG_INPUT_INVALID;
    if (count>MNG_INPUT_MAX_SOURCES) return MNG_INPUT_LIMIT;
    struct mng_input result={0};
    for (size_t i=0;i<count;i++) {
        if (sources[i].buttons&~MNG_GUEST_BUTTON_MASK) return MNG_INPUT_INVALID;
        result.buttons|=sources[i].buttons;
        for (unsigned axis=0;axis<4;axis++) {
            if (!isfinite(sources[i].sticks[axis])) return MNG_INPUT_INVALID;
            float value=bounded(sources[i].sticks[axis],-1);
            if (fabsf(value)>fabsf(result.sticks[axis])) result.sticks[axis]=value;
        }
        for (unsigned trigger=0;trigger<2;trigger++) {
            if (!isfinite(sources[i].triggers[trigger])) return MNG_INPUT_INVALID;
            float value=bounded(sources[i].triggers[trigger],0);
            if (value>result.triggers[trigger]) result.triggers[trigger]=value;
        }
    }
    *out=result; return MNG_INPUT_OK;
}
