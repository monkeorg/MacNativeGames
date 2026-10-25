#include "mng_touch.h"
#include <math.h>
#include <string.h>
static float clamp(float value,float low,float high){return fminf(high,fmaxf(low,value));}
static uint16_t button_at(const struct mng_touch *s,float x,float y) {
    float best=s->hit_radius;uint16_t bit=0;
    for(unsigned i=0;i<16;i++) {
        float distance=hypotf(x-s->buttons[i].x,y-s->buttons[i].y);
        if(distance<best){best=distance;bit=s->buttons[i].bit;}
    }
    return bit;
}
static void update(struct mng_touch *s) {
    struct mng_input next={0};unsigned stick_set=0;
    for(unsigned i=0;i<MNG_TOUCH_CONTACTS;i++) {
        const struct mng_touch_contact *c=&s->contacts[i];if(!c->id)continue;
        if(!c->role){next.buttons|=button_at(s,c->x,c->y);continue;}
        unsigned stick=c->role-1;if(stick_set&(1u<<stick))continue;stick_set|=1u<<stick;
        float x=(c->x-c->origin_x)/s->radius,y=(c->origin_y-c->y)/s->radius;
        float length=hypotf(x,y);if(length>1){x/=length;y/=length;}
        next.sticks[stick*2]=x;next.sticks[stick*2+1]=y;
    }
    next.triggers[0]=(next.buttons&(UINT64_C(1)<<6))!=0;
    next.triggers[1]=(next.buttons&(UINT64_C(1)<<7))!=0;
    s->edges|=next.buttons&~s->input.buttons;s->input=next;
}
void mng_touch_cancel(struct mng_touch *s){if(s){memset(s->contacts,0,sizeof(s->contacts));memset(&s->input,0,sizeof(s->input));s->edges=0;}}
int mng_touch_layout(struct mng_touch *s,float x,float y,float w,float h) {
    if(!s || !isfinite(x)||!isfinite(y)||!isfinite(w)||!isfinite(h)||w<240||h<160||w>16384||h>16384||fabsf(x)>16384||fabsf(y)>16384)return -1;
    memset(s,0,sizeof(*s));s->x=x;s->y=y;s->width=w;s->height=h;
    s->radius=fminf(70,h*.16f);float d=fminf(52,h*.14f);s->hit_radius=fminf(30,d*.68f);
    float face=x+w*.86f,pad=x+w*.14f,cy=y+h*.42f,top=y+h*.12f,bottom=y+h*.88f;
    struct mng_touch_button b[16]={
        {face+d,cy,1},{face,cy+d,2},{face,cy-d,4},{face-d,cy,8},
        {x+w*.05f,top,64},{x+w*.16f,top,16},{x+w*.84f,top,32},{x+w*.95f,top,128},
        {x+w*.40f,top,512},{x+w*.60f,top,256},
        {pad-d,cy,16384},{pad,cy-d,4096},{pad+d,cy,32768},{pad,cy+d,8192},
        {x+w*.05f,bottom,1024},{x+w*.95f,bottom,2048}};
    for(unsigned i=0;i<16;i++){b[i].x=clamp(b[i].x,x+22,x+w-22);b[i].y=clamp(b[i].y,y+22,y+h-22);s->buttons[i]=b[i];}
    return 0;
}
static struct mng_touch_contact *find(struct mng_touch *s,uint64_t id){for(unsigned i=0;i<MNG_TOUCH_CONTACTS;i++)if(s->contacts[i].id==id)return &s->contacts[i];return NULL;}
int mng_touch_begin(struct mng_touch *s,uint64_t id,float x,float y,int direct) {
    if(!s||!id||!direct||!s->radius||!isfinite(x)||!isfinite(y)||x<s->x||y<s->y||x>s->x+s->width||y>s->y+s->height||find(s,id))return -1;
    for(unsigned i=0;i<MNG_TOUCH_CONTACTS;i++)if(!s->contacts[i].id){
        unsigned role=button_at(s,x,y)?0:(x<s->x+s->width*.5f?1:2);
        s->contacts[i]=(struct mng_touch_contact){id,x,y,x,y,role};update(s);return 0;
    }
    return -1;
}
int mng_touch_move(struct mng_touch *s,uint64_t id,float x,float y) {
    if(!s||!id||!isfinite(x)||!isfinite(y)||fabsf(x)>32768||fabsf(y)>32768)return -1;
    struct mng_touch_contact *c=find(s,id);if(!c)return -1;c->x=x;c->y=y;update(s);return 0;
}
int mng_touch_end(struct mng_touch *s,uint64_t id) {
    if(!s||!id)return -1;
    struct mng_touch_contact *c=find(s,id);if(!c)return -1;
    memset(c,0,sizeof(*c));update(s);return 0;
}
int mng_touch_consume(struct mng_touch *s,struct mng_input *out){if(!s||!out)return -1;*out=s->input;out->buttons|=s->edges;s->edges=0;return 0;}
