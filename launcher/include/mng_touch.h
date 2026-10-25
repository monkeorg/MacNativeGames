#ifndef MNG_TOUCH_H
#define MNG_TOUCH_H
#include "mng_input.h"
#define MNG_TOUCH_CONTACTS 10u
struct mng_touch_button { float x,y; uint16_t bit; };
struct mng_touch_contact { uint64_t id; float x,y,origin_x,origin_y; unsigned role; };
struct mng_touch {
    float x,y,width,height,radius,hit_radius;
    struct mng_touch_button buttons[16];
    struct mng_touch_contact contacts[MNG_TOUCH_CONTACTS];
    uint64_t edges;
    struct mng_input input;
};
/* Safe-area rectangle in host points. Relayout cancels ALL old contacts. */
int mng_touch_layout(struct mng_touch *,float x,float y,float width,float height);
void mng_touch_cancel(struct mng_touch *);
/* Only direct touches may begin. Unknown/late moves/end cannot create input. */
int mng_touch_begin(struct mng_touch *,uint64_t id,float x,float y,int direct);
int mng_touch_move(struct mng_touch *,uint64_t id,float x,float y);
int mng_touch_end(struct mng_touch *,uint64_t id);
int mng_touch_consume(struct mng_touch *,struct mng_input *);
#endif
