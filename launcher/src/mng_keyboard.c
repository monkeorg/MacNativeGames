#include "mng_keyboard.h"
#include <string.h>
_Static_assert(MNG_KEY_ACTIONS==TOTK_KEY_ACTIONS,"keyboard action schema changed");
static const char *names[MNG_KEY_ACTIONS]={
    "moveForward","moveLeft","moveBackward","moveRight","cameraUp","cameraLeft","cameraDown","cameraRight",
    "a","b","x","y","leftStick","rightStick","l","r","zl","zr","plus","minus","dpadLeft","dpadUp","dpadRight","dpadDown"};
static const unsigned buttons[16]={0,1,2,3,10,11,4,5,6,7,8,9,14,12,15,13};
static void ignore_legacy_key(unsigned code,int down) { (void)code; (void)down; }
const char *mng_keyboard_action_name(unsigned action) { return action<MNG_KEY_ACTIONS ? names[action]:NULL; }
int mng_keyboard_key_supported(unsigned usage) { return usage==0 || totk_key_supported(usage); }
void mng_keyboard_defaults(unsigned short out[MNG_KEY_ACTIONS]) { if(out)memcpy(out,totk_key_defaults,sizeof(totk_key_defaults)); }
int mng_keyboard_bindings_valid(const unsigned short bindings[MNG_KEY_ACTIONS]) {
    if(!bindings)return 0;
    for(unsigned i=0;i<MNG_KEY_ACTIONS;i++) {
        if(!mng_keyboard_key_supported(bindings[i]))return 0;
        for(unsigned j=0;bindings[i] && j<i;j++)if(bindings[i]==bindings[j])return 0;
    }
    return 1;
}
void mng_keyboard_init(struct mng_keyboard *state) { if(state){memset(state,0,sizeof(*state));mng_keyboard_defaults(state->bindings);} }
void mng_keyboard_clear(struct mng_keyboard *state) {
    if(!state)return;
    totk_keyboard_clear(&state->held,ignore_legacy_key);
    memset(&state->input,0,sizeof(state->input));state->pressed_edges=0;
}
int mng_keyboard_set_bindings(struct mng_keyboard *state,const unsigned short bindings[MNG_KEY_ACTIONS]) {
    if(!state || !mng_keyboard_bindings_valid(bindings))return -1;
    unsigned short copy[MNG_KEY_ACTIONS];memcpy(copy,bindings,sizeof(copy));
    mng_keyboard_clear(state);memcpy(state->bindings,copy,sizeof(copy));return 0;
}
static int held(const struct mng_keyboard *state,unsigned action) { return state->held.references[totk_key_outputs[action]]!=0; }
int mng_keyboard_event(struct mng_keyboard *state,unsigned usage,unsigned source,int down) {
    if(!state || usage>=256 || !source || source>2 || (down!=0 && down!=1))return -1;
    int accepted=totk_keyboard_event(&state->held,usage,source,down,state->bindings,ignore_legacy_key);
    if(!accepted)return 0;
    struct mng_input input={0};
    input.sticks[0]=(float)(held(state,3)-held(state,1));input.sticks[1]=(float)(held(state,0)-held(state,2));
    input.sticks[2]=(float)(held(state,7)-held(state,5));input.sticks[3]=(float)(held(state,4)-held(state,6));
    for(unsigned i=0;i<16;i++)if(held(state,i+8))input.buttons|=UINT64_C(1)<<buttons[i];
    input.triggers[0]=(float)held(state,16);input.triggers[1]=(float)held(state,17);
    state->pressed_edges|=input.buttons&~state->input.buttons;state->input=input;return 1;
}
int mng_keyboard_consume(struct mng_keyboard *state,struct mng_input *out) {
    if(!state || !out)return -1;
    *out=state->input;out->buttons|=state->pressed_edges;state->pressed_edges=0;return 0;
}
