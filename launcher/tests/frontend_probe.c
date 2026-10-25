#include "mng_pointer.h"
#include "mng_touch.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static void pointer(void) {
    struct mng_pointer s;mng_pointer_init(&s);struct mng_input out;
    TOTKMouseCapture gate={true,true,false,true,true};
    mng_pointer_gate(&s,gate,1,0);
    assert(totk_mouse_wants_capture(&gate) && !mng_pointer_ready(&s));
    assert(mng_pointer_motion(&s,20,0)==-1 && mng_pointer_button(&s,0,1,1)==-1);
    mng_pointer_gate(&s,gate,1,1);assert(mng_pointer_ready(&s));
    assert(mng_pointer_motion(&s,20,0)==0 && mng_pointer_consume(&s,1,&out)==0 && out.sticks[2]>.99f);
    assert(mng_pointer_motion(&s,0,0)==0);
    assert(mng_pointer_consume(&s,10000001,&out)==0 && out.sticks[2]<1 && out.sticks[2]>0);
    struct mng_input_mapping map;mng_input_mapping_default(&map);
    for(unsigned i=0;i<5;i++)map.targets[17+i]=(uint16_t)(1u<<i);
    assert(mng_pointer_configure(&s,50,0,&map)==0);
    for(unsigned i=0;i<5;i++) {
        assert(mng_pointer_button(&s,i,1,20000000+i*2)==0);
        assert(mng_pointer_button(&s,i,0,20000001+i*2)==0);
    }
    assert(mng_pointer_consume(&s,30000000,&out)==0 && out.buttons==31);
    assert(mng_pointer_consume(&s,30000001,&out)==0 && out.buttons==0);
    assert(mng_pointer_motion(&s,0,10)==0 && mng_pointer_consume(&s,40000000,&out)==0 && out.sticks[3]<0);
    assert(mng_pointer_configure(&s,100,1,&map)==0);
    assert(mng_pointer_motion(&s,0,10)==0 && mng_pointer_consume(&s,50000000,&out)==0 && out.sticks[3]>0);
    struct mng_pointer before=s;
    assert(mng_pointer_configure(&s,0,0,&map)==-1 && !memcmp(&s,&before,sizeof(s)));
    assert(mng_pointer_consume(&s,1,&out)==-1 && !memcmp(&s,&before,sizeof(s)));
    assert(mng_pointer_button(&s,5,1,50000001)==-1 && !memcmp(&s,&before,sizeof(s)));
    assert(mng_pointer_motion(&s,NAN,0)==-1 && mng_pointer_motion(&s,INFINITY,0)==-1);
    gate.text_entry=true;mng_pointer_gate(&s,gate,1,1);
    assert(mng_pointer_consume(&s,60000000,&out)==0 && !out.buttons && !out.sticks[3]);
    gate.text_entry=false;mng_pointer_gate(&s,gate,1,1);
    assert(mng_pointer_consume(&s,70000000,&out)==0 && !out.sticks[3]);
    gate.foreground=false;mng_pointer_gate(&s,gate,1,1);assert(!mng_pointer_ready(&s));
    gate.foreground=true;gate.key_window=false;mng_pointer_gate(&s,gate,1,1);assert(!mng_pointer_ready(&s));
    gate.key_window=true;gate.active_scene=false;mng_pointer_gate(&s,gate,1,1);assert(!mng_pointer_ready(&s));
    gate.active_scene=true;mng_pointer_gate(&s,gate,0,1);assert(!mng_pointer_ready(&s));
}
static void touch(void) {
    struct mng_touch s;assert(mng_touch_layout(&s,48,30,1000,700)==0);struct mng_input out;
    for(unsigned i=0;i<16;i++) {
        assert(s.buttons[i].x>=48 && s.buttons[i].x<=1048 && s.buttons[i].y>=30 && s.buttons[i].y<=730);
        assert(mng_touch_begin(&s,i+1,s.buttons[i].x,s.buttons[i].y,1)==0);
        assert(mng_touch_end(&s,i+1)==0);
        assert(mng_touch_consume(&s,&out)==0 && out.buttons==s.buttons[i].bit);
        assert(mng_touch_consume(&s,&out)==0 && out.buttons==0);
    }
    assert(mng_touch_begin(&s,100,300,600,0)==-1);
    assert(mng_touch_begin(&s,100,300,600,1)==0);
    assert(mng_touch_move(&s,100,900,100)==0 && mng_touch_consume(&s,&out)==0);
    assert(out.sticks[0]>0 && out.sticks[1]>0 && fabsf(hypotf(out.sticks[0],out.sticks[1])-1)<.0001f);
    assert(mng_touch_begin(&s,101,750,600,1)==0 && mng_touch_move(&s,101,700,650)==0);
    assert(mng_touch_consume(&s,&out)==0 && out.sticks[2]<0 && out.sticks[3]<0);
    mng_touch_cancel(&s);assert(mng_touch_move(&s,100,400,600)==-1 && mng_touch_end(&s,100)==-1);
    assert(mng_touch_consume(&s,&out)==0 && !out.buttons && !out.sticks[0] && !out.sticks[2]);
    assert(mng_touch_begin(&s,102,s.buttons[0].x,s.buttons[0].y,1)==0);
    assert(mng_touch_layout(&s,24,20,700,1000)==0 && mng_touch_consume(&s,&out)==0 && !out.buttons);
    assert(mng_touch_move(&s,102,400,600)==-1);
    assert(mng_touch_begin(&s,0,300,600,1)==-1 && mng_touch_begin(&s,103,NAN,600,1)==-1);
    for(unsigned i=1;i<=MNG_TOUCH_CONTACTS;i++)assert(mng_touch_begin(&s,i,300,600,1)==0);
    assert(mng_touch_begin(&s,99,300,600,1)==-1);
    struct mng_touch before=s;
    assert(mng_touch_layout(&s,0,0,INFINITY,700)==-1 && !memcmp(&s,&before,sizeof(s)));
}
int main(int argc,char **argv) {
    assert(argc==2);
    if(!strcmp(argv[1],"pointer"))pointer();else if(!strcmp(argv[1],"touch"))touch();else assert(0);
    puts("{\"status\":\"pass\"}");return 0;
}
