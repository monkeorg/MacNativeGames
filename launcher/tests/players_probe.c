#include "mng_players.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
#define CHECK(test) do { if (!(test)) { fprintf(stderr,"line %d: %s\n",__LINE__,#test); return 1; } } while (0)
#define OK(call) CHECK((call)==MNG_PLAYER_OK)
static uint64_t token(const struct mng_players *p,uint64_t id) {
    uint64_t value=0; (void)mng_players_token(p,id,&value); return value;
}
static int neutral(const struct mng_input *input) {
    struct mng_input zero={0}; return memcmp(input,&zero,sizeof(zero))==0;
}
static int opposing(void) {
    struct mng_players p; mng_players_init(&p);
    OK(mng_players_connect(&p,11)); OK(mng_players_connect(&p,22));
    OK(mng_players_assign(&p,0,11)); OK(mng_players_assign(&p,1,22));
    struct mng_input a={1,{1,-1,0,0},{1,0}}, b={2,{-1,1,0,0},{0,1}}, out;
    OK(mng_players_update(&p,11,token(&p,11),1,&a));
    OK(mng_players_update(&p,22,token(&p,22),1,&b));
    uint64_t id=0;
    OK(mng_players_read(&p,0,&id,&out)); CHECK(id==11 && !memcmp(&out,&a,sizeof(a)));
    OK(mng_players_read(&p,1,&id,&out)); CHECK(id==22 && !memcmp(&out,&b,sizeof(b)));
    OK(mng_players_read(&p,3,&id,&out)); CHECK(id==0 && neutral(&out)); return 0;
}
static int disconnect_reassign(void) {
    struct mng_players p; mng_players_init(&p);
    OK(mng_players_connect(&p,1)); OK(mng_players_connect(&p,2));
    OK(mng_players_assign(&p,0,1)); OK(mng_players_assign(&p,1,2));
    struct mng_input held={3,{1,0,0,0},{0,0}}, out; uint64_t id;
    uint64_t previous=token(&p,1), other=token(&p,2);
    OK(mng_players_update(&p,1,previous,1,&held)); OK(mng_players_update(&p,2,other,1,&held));
    OK(mng_players_disconnect(&p,1));
    OK(mng_players_read(&p,0,&id,&out)); CHECK(id==0 && neutral(&out));
    OK(mng_players_read(&p,1,&id,&out)); CHECK(id==2 && out.buttons==3 && token(&p,2)==other);
    CHECK(mng_players_update(&p,1,previous,2,&held)==MNG_PLAYER_NOT_FOUND);
    OK(mng_players_connect(&p,1)); OK(mng_players_assign(&p,0,1));
    CHECK(mng_players_update(&p,1,previous,2,&held)==MNG_PLAYER_STALE);
    OK(mng_players_update(&p,1,token(&p,1),1,&held)); previous=token(&p,1);
    OK(mng_players_unassign(&p,0)); OK(mng_players_assign(&p,2,1));
    OK(mng_players_read(&p,2,&id,&out)); CHECK(id==1 && neutral(&out));
    CHECK(mng_players_update(&p,1,previous,2,&held)==MNG_PLAYER_STALE);
    OK(mng_players_read(&p,1,&id,&out)); CHECK(out.buttons==3); return 0;
}
static int conflicts_swap(void) {
    struct mng_players p; mng_players_init(&p);
    OK(mng_players_connect(&p,1)); OK(mng_players_connect(&p,2));
    CHECK(mng_players_connect(&p,1)==MNG_PLAYER_CONFLICT);
    OK(mng_players_assign(&p,0,1)); OK(mng_players_assign(&p,1,2));
    struct mng_input held={1,{0},{0}}, out; uint64_t id, old=token(&p,1);
    OK(mng_players_update(&p,1,old,1,&held));
    OK(mng_players_assign(&p,0,1)); CHECK(token(&p,1)==old);
    CHECK(mng_players_assign(&p,0,2)==MNG_PLAYER_CONFLICT);
    CHECK(mng_players_assign(&p,2,1)==MNG_PLAYER_CONFLICT);
    OK(mng_players_swap(&p,0,1));
    OK(mng_players_read(&p,0,&id,&out)); CHECK(id==2 && neutral(&out));
    OK(mng_players_read(&p,1,&id,&out)); CHECK(id==1 && neutral(&out));
    CHECK(mng_players_update(&p,1,old,2,&held)==MNG_PLAYER_STALE);
    OK(mng_players_swap(&p,1,3));
    OK(mng_players_read(&p,1,&id,&out)); CHECK(id==0 && neutral(&out));
    OK(mng_players_read(&p,3,&id,&out)); CHECK(id==1 && neutral(&out)); return 0;
}
static int focus_stale(void) {
    struct mng_players p; mng_players_init(&p); OK(mng_players_connect(&p,1)); OK(mng_players_assign(&p,0,1));
    struct mng_input held={1,{1,0,0,0},{1,0}}, out; uint64_t id, old=token(&p,1);
    OK(mng_players_update(&p,1,old,2,&held));
    CHECK(mng_players_update(&p,1,old,1,&held)==MNG_PLAYER_STALE);
    CHECK(mng_players_update(&p,1,old,2,&held)==MNG_PLAYER_STALE);
    OK(mng_players_focus(&p,0)); OK(mng_players_read(&p,0,&id,&out)); CHECK(id==1 && neutral(&out));
    CHECK(mng_players_update(&p,1,token(&p,1),1,&held)==MNG_PLAYER_INACTIVE);
    OK(mng_players_focus(&p,1)); CHECK(mng_players_update(&p,1,old,3,&held)==MNG_PLAYER_STALE);
    OK(mng_players_read(&p,0,&id,&out)); CHECK(neutral(&out));
    OK(mng_players_update(&p,1,token(&p,1),1,&held)); return 0;
}
static int invalid(void) {
    struct mng_players p; mng_players_init(&p); OK(mng_players_connect(&p,1)); OK(mng_players_assign(&p,0,1));
    struct mng_input input={1,{0},{0}}, out; uint64_t id, t=token(&p,1);
    OK(mng_players_update(&p,1,t,1,&input));
    struct mng_players before=p;
    for (unsigned i=0;i<6;i++) {
        struct mng_input bad=input;
        if (i<4) bad.sticks[i]=i&1 ? INFINITY:NAN; else bad.triggers[i-4]=i&1 ? -INFINITY:NAN;
        CHECK(mng_players_update(&p,1,t,2,&bad)==MNG_PLAYER_INVALID);
        CHECK(!memcmp(&p,&before,sizeof(p)));
    }
    input.buttons=UINT64_C(1)<<63; CHECK(mng_players_update(&p,1,t,2,&input)==MNG_PLAYER_INVALID);
    CHECK(mng_players_update(&p,1,0,2,&input)==MNG_PLAYER_INVALID);
    CHECK(mng_players_update(&p,1,t,0,&input)==MNG_PLAYER_INVALID);
    CHECK(mng_players_update(&p,1,t,2,NULL)==MNG_PLAYER_INVALID);
    CHECK(mng_players_connect(&p,0)==MNG_PLAYER_INVALID);
    CHECK(mng_players_assign(&p,4,1)==MNG_PLAYER_INVALID);
    CHECK(mng_players_assign(&p,0,99)==MNG_PLAYER_NOT_FOUND);
    CHECK(mng_players_unassign(&p,4)==MNG_PLAYER_INVALID);
    CHECK(mng_players_focus(&p,2)==MNG_PLAYER_INVALID);
    CHECK(mng_players_read(&p,4,&id,&out)==MNG_PLAYER_INVALID);
    CHECK(mng_players_token(&p,1,NULL)==MNG_PLAYER_INVALID);
    CHECK(mng_players_read(NULL,0,&id,&out)==MNG_PLAYER_INVALID);
    CHECK(!memcmp(&p,&before,sizeof(p))); return 0;
}
static int limits(void) {
    struct mng_players p; mng_players_init(&p);
    for (uint64_t i=1;i<=MNG_DEVICE_COUNT;i++) OK(mng_players_connect(&p,i));
    CHECK(mng_players_connect(&p,9)==MNG_PLAYER_LIMIT);
    OK(mng_players_assign(&p,0,1));
    struct mng_input input={MNG_BUTTON_MASK,{-100,100,-2,2},{-100,100}}, out; uint64_t id;
    OK(mng_players_update(&p,1,token(&p,1),UINT64_MAX,&input));
    OK(mng_players_read(&p,0,&id,&out));
    CHECK(out.buttons==MNG_BUTTON_MASK && out.sticks[0]==-1 && out.sticks[1]==1 && out.sticks[2]==-1 && out.sticks[3]==1 && out.triggers[0]==0 && out.triggers[1]==1);
    CHECK(mng_players_update(&p,1,token(&p,1),1,&input)==MNG_PLAYER_STALE);
    /* Exercise the otherwise unreachable token boundary without wrapping. */
    p.next_token=UINT64_MAX;
    CHECK(mng_players_swap(&p,0,1)==MNG_PLAYER_LIMIT);
    CHECK(mng_players_focus(&p,0)==MNG_PLAYER_LIMIT);
    OK(mng_players_read(&p,0,&id,&out)); CHECK(neutral(&out));
    CHECK(mng_players_focus(&p,1)==MNG_PLAYER_LIMIT);
    CHECK(mng_players_update(&p,1,token(&p,1),1,&input)==MNG_PLAYER_INACTIVE);
    OK(mng_players_disconnect(&p,1)); CHECK(mng_players_connect(&p,1)==MNG_PLAYER_LIMIT); return 0;
}
static int short_taps(void) {
    struct mng_players p; mng_players_init(&p);
    OK(mng_players_connect(&p,1)); OK(mng_players_connect(&p,2));
    OK(mng_players_assign(&p,0,1)); OK(mng_players_assign(&p,1,2));
    struct mng_input press={1,{0},{0}}, release={0}, other={2,{0},{0}}, out; uint64_t id;
    uint64_t t=token(&p,1);
    OK(mng_players_update(&p,1,t,1,&press)); OK(mng_players_update(&p,1,t,2,&release));
    OK(mng_players_update(&p,2,token(&p,2),1,&other));
    OK(mng_players_read(&p,0,&id,&out)); CHECK(out.buttons==0);
    OK(mng_players_consume(&p,0,&id,&out)); CHECK(id==1 && out.buttons==1);
    OK(mng_players_consume(&p,0,&id,&out)); CHECK(out.buttons==0);
    OK(mng_players_consume(&p,1,&id,&out)); CHECK(out.buttons==2);
    OK(mng_players_consume(&p,1,&id,&out)); CHECK(out.buttons==2); /* still held */
    press.buttons=(UINT64_C(1)<<16)|(UINT64_C(1)<<17);
    OK(mng_players_update(&p,1,t,3,&press));
    OK(mng_players_consume(&p,0,&id,&out)); CHECK(out.buttons==0); /* held UI commands also clipped */
    OK(mng_players_update(&p,1,t,4,&release));
    OK(mng_players_consume(&p,0,&id,&out)); CHECK(out.buttons==0); /* UI commands not guest edges */
    return 0;
}
static int edge_cancellation(void) {
    struct mng_players p; mng_players_init(&p); OK(mng_players_connect(&p,1)); OK(mng_players_assign(&p,0,1));
    struct mng_input press={4,{0},{0}}, release={0}, out; uint64_t id,t=token(&p,1);
    OK(mng_players_update(&p,1,t,1,&press)); OK(mng_players_update(&p,1,t,2,&release));
    OK(mng_players_reset_device(&p,1)); CHECK(token(&p,1)!=t);
    CHECK(mng_players_update(&p,1,t,3,&press)==MNG_PLAYER_STALE);
    OK(mng_players_consume(&p,0,&id,&out)); CHECK(id==1 && neutral(&out));
    t=token(&p,1); OK(mng_players_update(&p,1,t,1,&press));
    OK(mng_players_focus(&p,0)); OK(mng_players_focus(&p,1));
    OK(mng_players_consume(&p,0,&id,&out)); CHECK(neutral(&out));
    t=token(&p,1); OK(mng_players_update(&p,1,t,1,&press));
    OK(mng_players_swap(&p,0,2)); OK(mng_players_consume(&p,2,&id,&out)); CHECK(neutral(&out));
    t=token(&p,1); OK(mng_players_update(&p,1,t,1,&press));
    OK(mng_players_disconnect(&p,1)); OK(mng_players_connect(&p,1)); OK(mng_players_assign(&p,2,1));
    OK(mng_players_consume(&p,2,&id,&out)); CHECK(neutral(&out));
    CHECK(mng_players_reset_device(NULL,1)==MNG_PLAYER_INVALID);
    CHECK(mng_players_reset_device(&p,0)==MNG_PLAYER_INVALID);
    CHECK(mng_players_reset_device(&p,99)==MNG_PLAYER_NOT_FOUND);
    struct mng_players before=p;
    CHECK(mng_players_consume(&p,4,&id,&out)==MNG_PLAYER_INVALID && !memcmp(&p,&before,sizeof(p)));
    return 0;
}
int main(int argc,char **argv) {
    if (argc!=2) return 2;
    int result;
    if (!strcmp(argv[1],"opposing")) result=opposing();
    else if (!strcmp(argv[1],"disconnect")) result=disconnect_reassign();
    else if (!strcmp(argv[1],"swap")) result=conflicts_swap();
    else if (!strcmp(argv[1],"focus")) result=focus_stale();
    else if (!strcmp(argv[1],"invalid")) result=invalid();
    else if (!strcmp(argv[1],"limits")) result=limits();
    else if (!strcmp(argv[1],"taps")) result=short_taps();
    else if (!strcmp(argv[1],"edge-cancel")) result=edge_cancellation();
    else return 2;
    if (!result) puts("{\"status\":\"pass\",\"scope\":\"portable player routing only\"}");
    return result;
}
