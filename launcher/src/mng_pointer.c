#include "mng_pointer.h"
#include <string.h>
void mng_pointer_clear(struct mng_pointer *s) {
    if(!s)return;
    mouse_look_reset(&s->look);mng_input_mapper_reset(&s->mapper);
    memset(&s->physical,0,sizeof(s->physical));memset(&s->mapped,0,sizeof(s->mapped));
    s->edges=0;s->last_tick=0;s->camera[0]=s->camera[1]=0;
}
void mng_pointer_init(struct mng_pointer *s) {
    if(!s)return;
    memset(s,0,sizeof(*s));s->settings=(MouseLookSettings){50,0,20,18,6};mng_input_mapping_default(&s->mapping);
}
int mng_pointer_ready(const struct mng_pointer *s){return s && totk_mouse_accepts_input(&s->capture,s->runtime_focus,s->granted);}
void mng_pointer_gate(struct mng_pointer *s,TOTKMouseCapture capture,int focus,int granted) {
    if(!s)return;
    s->capture=capture;s->runtime_focus=!!focus;s->granted=!!granted;
    if(!mng_pointer_ready(s))mng_pointer_clear(s);
}
int mng_pointer_configure(struct mng_pointer *s,int sensitivity,int invert,const struct mng_input_mapping *mapping) {
    if(!s||!mapping||sensitivity<1||sensitivity>100||(invert!=0 && invert!=1))return -1;
    struct mng_input_mapper probe={0};struct mng_physical_input empty={0};struct mng_input output;
    if(mng_input_map(&probe,mapping,&empty,1,&output)!=MNG_INPUT_OK)return -1;
    mng_pointer_clear(s);s->settings.sensitivity=sensitivity;s->settings.invert_y=invert;s->mapping=*mapping;return 0;
}
int mng_pointer_motion(struct mng_pointer *s,double dx,double dy) {
    if(!mng_pointer_ready(s)||!isfinite(dx)||!isfinite(dy))return -1;
    if(!totk_mouse_has_motion(dx,dy))return 0;
    // Bound single-provider reports before they can overflow the shared look model.
    dx=fmax(-4096,fmin(4096,dx));dy=fmax(-4096,fmin(4096,dy));
    mouse_look_move(&s->look,dx,dy,&s->settings);return 0;
}
int mng_pointer_button(struct mng_pointer *s,unsigned button,int down,uint64_t ns) {
    if(!mng_pointer_ready(s)||button>=5||(down!=0 && down!=1))return -1;
    struct mng_physical_input physical=s->physical;
    uint32_t bit=UINT32_C(1)<<(17+button);
    if(down)physical.buttons|=bit;else physical.buttons&=~bit;
    struct mng_input output;
    if(mng_input_map(&s->mapper,&s->mapping,&physical,ns,&output)!=MNG_INPUT_OK)return -1;
    s->edges|=output.buttons&~s->mapped.buttons;s->mapped=output;s->physical=physical;return 0;
}
int mng_pointer_consume(struct mng_pointer *s,uint64_t ns,struct mng_input *out) {
    if(!s||!out||!ns)return -1;
    if(!mng_pointer_ready(s)){mng_pointer_clear(s);memset(out,0,sizeof(*out));return 0;}
    if(ns<s->last_tick)return -1;
    struct mng_input output;
    if(mng_input_map(&s->mapper,&s->mapping,&s->physical,ns,&output)!=MNG_INPUT_OK)return -1;
    s->edges|=output.buttons&~s->mapped.buttons;s->mapped=output;
    uint64_t elapsed=s->last_tick ? (ns-s->last_tick)/MOUSE_LOOK_TICK_NS:1;
    unsigned ticks=(unsigned)(elapsed>64?1:elapsed);
    if(elapsed>64)mouse_look_reset(&s->look);
    if(ticks) {
        for(unsigned i=0;i<ticks;i++) {
            int32_t x,y;double gyro[3],acc[3];mouse_look_tick(&s->look,&s->settings,&x,&y,gyro,acc);
            s->camera[0]=x/32767.f;s->camera[1]=y/32767.f;
        }
        s->last_tick=ns;
    }
    *out=output;out->buttons|=s->edges;s->edges=0;out->sticks[2]=s->camera[0];out->sticks[3]=s->camera[1];return 0;
}
