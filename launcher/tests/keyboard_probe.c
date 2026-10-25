#include "mng_keyboard.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(int argc,char **argv) {
    assert(argc==2);struct mng_keyboard state;mng_keyboard_init(&state);struct mng_input out;
    if(!strcmp(argv[1],"dedup")) {
        assert(mng_keyboard_event(&state,13,1,1)==1);
        assert(mng_keyboard_event(&state,13,2,1)==1);
        assert(mng_keyboard_event(&state,13,1,0)==1);
        assert(mng_keyboard_event(&state,13,2,0)==0);
        assert(mng_keyboard_consume(&state,&out)==0 && out.buttons==1);
        assert(mng_keyboard_consume(&state,&out)==0 && out.buttons==0);
        assert(mng_keyboard_event(&state,26,2,1)==1);
        assert(mng_keyboard_consume(&state,&out)==0 && out.sticks[1]==1);
        assert(mng_keyboard_event(&state,22,2,1)==1);
        assert(mng_keyboard_consume(&state,&out)==0 && out.sticks[1]==0);
        mng_keyboard_clear(&state);assert(mng_keyboard_consume(&state,&out)==0 && out.sticks[1]==0);
    } else if(!strcmp(argv[1],"bindings")) {
        unsigned short keys[MNG_KEY_ACTIONS];mng_keyboard_defaults(keys);
        keys[8]=4;assert(!mng_keyboard_bindings_valid(keys));
        keys[1]=0;assert(mng_keyboard_bindings_valid(keys));
        assert(mng_keyboard_set_bindings(&state,keys)==0);
        assert(mng_keyboard_event(&state,4,1,1)==1);
        assert(mng_keyboard_consume(&state,&out)==0 && out.buttons==1 && out.sticks[0]==0);
        keys[8]=5;assert(mng_keyboard_set_bindings(&state,keys)==0);
        assert(mng_keyboard_event(&state,4,1,0)==0);
        assert(mng_keyboard_consume(&state,&out)==0 && out.buttons==0);
        assert(mng_keyboard_event(&state,5,1,1)==1);
        struct mng_keyboard before=state;keys[8]=41;
        assert(mng_keyboard_set_bindings(&state,keys)==-1 && !memcmp(&state,&before,sizeof(state)));
        for(unsigned key=0;key<256;key++) {
            if(key==41 || key==227 || key==231)assert(!mng_keyboard_key_supported(key));
        }
        assert(mng_keyboard_event(&state,41,1,1)==0 && mng_keyboard_event(&state,227,1,1)==0);
        assert(mng_keyboard_event(&state,256,1,1)==-1);
    } else if(!strcmp(argv[1],"schema")) {
        for(unsigned i=0;i<MNG_KEY_ACTIONS;i++) {
            mng_keyboard_init(&state);assert(mng_keyboard_action_name(i));
            assert(mng_keyboard_event(&state,state.bindings[i],1,1)==1);
            assert(mng_keyboard_consume(&state,&out)==0);
            if(i<8)assert(out.sticks[i<4 ? (i%2 ? 0:1):(i%2 ? 2:3)]!=0);
            else assert(out.buttons && !(out.buttons & ~MNG_GUEST_BUTTON_MASK));
        }
        assert(!mng_keyboard_action_name(MNG_KEY_ACTIONS));
    } else assert(0);
    puts("{\"status\":\"pass\"}");return 0;
}
