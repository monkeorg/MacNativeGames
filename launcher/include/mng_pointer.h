#ifndef MNG_POINTER_H
#define MNG_POINTER_H
#include "mng_input.h"
#include "../../games/totk/ios/Sources/mouse_capture.h"
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#include "../../games/totk/runtime/mouse_look.h"
struct mng_pointer {
    TOTKMouseCapture capture;
    int granted,runtime_focus;
    MouseLook look;
    MouseLookSettings settings;
    struct mng_input_mapping mapping;
    struct mng_input_mapper mapper;
    struct mng_physical_input physical;
    struct mng_input mapped;
    uint64_t edges,last_tick;
    float camera[2];
};
void mng_pointer_init(struct mng_pointer *);
void mng_pointer_clear(struct mng_pointer *);
/* Every event requires actual granted lock, in addition to this request gate. */
void mng_pointer_gate(struct mng_pointer *,TOTKMouseCapture capture,int runtime_focus,int granted);
int mng_pointer_ready(const struct mng_pointer *);
int mng_pointer_configure(struct mng_pointer *,int sensitivity,int invert,const struct mng_input_mapping *);
int mng_pointer_motion(struct mng_pointer *,double dx,double dy);
int mng_pointer_button(struct mng_pointer *,unsigned button,int down,uint64_t now_ns);
int mng_pointer_consume(struct mng_pointer *,uint64_t now_ns,struct mng_input *);
#endif
