#define _POSIX_C_SOURCE 200809L
#include "mng_input.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line%d:%s\n",__LINE__,#x);return 1; } } while(0)
#define OK(x) CHECK((x)==MNG_INPUT_OK)
static int parse(struct mng_input_mapping *map,const char *text) {
    return mng_input_mapping_parse(text,strlen(text),map,NULL)==MNG_INPUT_OK;
}
static int layouts(void) {
    CHECK(mng_input_native_to_portable(1u<<4)==(1u<<10));
    CHECK(mng_input_native_to_portable(1u<<8)==(1u<<6));
    CHECK(mng_input_native_to_portable(1u<<12)==(1u<<14));
    CHECK(mng_input_native_to_portable(1u<<13)==(1u<<12));
    for (unsigned i=0;i<65536;i++) CHECK(mng_input_portable_to_native(mng_input_native_to_portable((uint16_t)i))==i);
    struct mng_input_mapping map; mng_input_mapping_default(&map);
    struct mng_input_mapper state={0}; struct mng_physical_input physical={0}; struct mng_input out;
    physical.buttons=mng_input_face_positions(MNG_CONTROLLER_AUTO,"Xbox One","Microsoft",1,0,0,0);
    OK(mng_input_map(&state,&map,&physical,1,&out)); CHECK(out.buttons==2); /* bottom means Switch B */
    mng_input_mapper_reset(&state);
    physical.buttons=mng_input_face_positions(MNG_CONTROLLER_AUTO,"Nintendo Switch Pro Controller","Nintendo",1,0,0,0);
    OK(mng_input_map(&state,&map,&physical,1,&out)); CHECK(out.buttons==1); /* Nintendo A by label */
    CHECK(setenv("TOTK_FACE_BUTTONS","label",1)==0);
    CHECK(mng_input_face_positions(MNG_CONTROLLER_AUTO,"Xbox","",1,0,0,0)==1);
    CHECK(unsetenv("TOTK_FACE_BUTTONS")==0);
    CHECK(mng_input_face_positions(MNG_CONTROLLER_SWITCH,"Xbox","",1,0,0,0)==2);
    CHECK(mng_input_face_positions(MNG_CONTROLLER_PLAYSTATION,"DualSense","",1,0,0,0)==1);
    CHECK(mng_input_controller_type("switch")==MNG_CONTROLLER_SWITCH && mng_input_controller_type("unknown")==-1);
    CHECK(mng_input_face_positions(99,"","",1,1,1,1)==0);
    return 0;
}
static int parser(void) {
    struct mng_input_mapping map,before; mng_input_mapping_default(&map); before=map;
    unsigned line=0; const char *bad[]={"unknown = a","south = invalid","south = none tap","south = zr aim south","south = a hold extra"};
    for (unsigned i=0;i<sizeof(bad)/sizeof(bad[0]);i++) {
        CHECK(mng_input_mapping_parse(bad[i],strlen(bad[i]),&map,&line)==MNG_INPUT_INVALID);
        CHECK(line==1 && !memcmp(&map,&before,sizeof(map)));
    }
    const char nul[]="south\0 = a";
    CHECK(mng_input_mapping_parse(nul,sizeof(nul)-1,&map,NULL)==MNG_INPUT_INVALID);
    char large[4097]; memset(large,' ',sizeof(large));
    CHECK(mng_input_mapping_parse(large,sizeof(large),&map,NULL)==MNG_INPUT_LIMIT);
    CHECK(!memcmp(&map,&before,sizeof(map)));
    CHECK(parse(&map,"# own mappings\nSOUTH = a\ntouchpad = plus\nmouse4 = none\n"));
    CHECK(map.targets[0]==1 && map.targets[16]==(1u<<8) && map.targets[20]==0);
    CHECK(map.modes[18]==(3u|(17u<<3))); /* untouched default aim/fire */
    OK(mng_input_mapping_parse(NULL,0,&map,NULL)); CHECK(!memcmp(&map,&before,sizeof(map)));
    return 0;
}
static int modes(void) {
    struct mng_input_mapping map; CHECK(parse(&map,"south = a tap\neast = b toggle\n"));
    struct mng_input_mapper state={0},other={0}; struct mng_physical_input p={0}; struct mng_input out;
    p.buttons=1; OK(mng_input_map(&state,&map,&p,10,&out)); CHECK(out.buttons==1);
    p.buttons=0; OK(mng_input_map(&state,&map,&p,399999999,&out)); CHECK(out.buttons==1);
    OK(mng_input_map(&state,&map,&p,400000010,&out)); CHECK(out.buttons==0);
    p.buttons=2; OK(mng_input_map(&state,&map,&p,500000000,&out)); CHECK(out.buttons==2);
    p.buttons=0; OK(mng_input_map(&state,&map,&p,500000001,&out)); CHECK(out.buttons==2);
    p.sticks[0]=1; OK(mng_input_map(&state,&map,&p,500000002,&out)); CHECK(out.buttons==2);
    p.sticks[0]=0; OK(mng_input_map(&state,&map,&p,500000003,&out)); CHECK(out.buttons==0);
    OK(mng_input_map(&other,&map,&p,1,&out)); CHECK(out.buttons==0); /* isolated device */
    mng_input_mapping_default(&map); mng_input_mapper_reset(&state);
    p.buttons=1u<<18; OK(mng_input_map(&state,&map,&p,1,&out)); CHECK(out.buttons==(1u<<7));
    p.buttons|=1u<<17; OK(mng_input_map(&state,&map,&p,2,&out)); CHECK(out.buttons==0); /* aim release, no attack */
    p.buttons=1u<<17; OK(mng_input_map(&state,&map,&p,3,&out)); CHECK(out.buttons==(1u<<3));
    CHECK(parse(&map,"south = a\neast = a")); mng_input_mapper_reset(&state);
    p.buttons=3; OK(mng_input_map(&state,&map,&p,1,&out)); CHECK(out.buttons==1);
    p.buttons=2; OK(mng_input_map(&state,&map,&p,2,&out)); CHECK(out.buttons==1); /* shared target still held */
    CHECK(parse(&map,"south = a tap")); mng_input_mapper_reset(&state); p.buttons=1;
    OK(mng_input_map(&state,&map,&p,UINT64_MAX,&out)); CHECK(out.buttons==1 && state.tap_until[0]==UINT64_MAX);
    p.buttons=0; OK(mng_input_map(&state,&map,&p,UINT64_MAX,&out)); CHECK(out.buttons==0);
    return 0;
}
static int invalid(void) {
    struct mng_input_mapping map; mng_input_mapping_default(&map);
    struct mng_input_mapper state={0}; struct mng_physical_input p={1,{2,-2,.5f,0},{2,-2}}; struct mng_input out;
    OK(mng_input_map(&state,&map,&p,10,&out)); CHECK(out.sticks[0]==1 && out.sticks[1]==-1 && out.triggers[0]==1 && out.triggers[1]==0);
    struct mng_input_mapper before=state; struct mng_input previous=out;
    CHECK(mng_input_map(&state,&map,&p,9,&out)==MNG_INPUT_STALE);
    CHECK(!memcmp(&state,&before,sizeof(state)) && !memcmp(&out,&previous,sizeof(out)));
    for (unsigned i=0;i<7;i++) {
        struct mng_physical_input bad=p; struct mng_input_mapping badmap=map;
        if (i<4) bad.sticks[i]=NAN;
        else if (i==4) bad.triggers[0]=INFINITY;
        else if (i==5) bad.buttons=1u<<22;
        else badmap.targets[0]=3;
        CHECK(mng_input_map(&state,&badmap,&bad,11,&out)==MNG_INPUT_INVALID);
        CHECK(!memcmp(&state,&before,sizeof(state)) && !memcmp(&out,&previous,sizeof(out)));
    }
    CHECK(mng_input_map(&state,&map,&p,0,&out)==MNG_INPUT_INVALID);
    mng_input_mapper_reset(&state); CHECK(state.last_ns==0 && state.previous==0);
    return 0;
}
static int aim_fire_modes(void) {
    for (unsigned kind=0;kind<2;kind++) for (unsigned reverse=0;reverse<2;reverse++) {
        const char *aim=reverse ? "r2":"l2",*fire=reverse ? "l2":"r2";
        unsigned aim_slot=reverse ? 9:8,fire_slot=reverse ? 8:9;
        char text[96]; snprintf(text,sizeof(text),"%s = zr aim %s\n%s = y %s\n",aim,fire,fire,kind ? "toggle":"tap");
        struct mng_input_mapping map; CHECK(parse(&map,text));
        struct mng_input_mapper state={0}; struct mng_physical_input p={0}; struct mng_input out;
        p.buttons=UINT32_C(1)<<fire_slot;
        OK(mng_input_map(&state,&map,&p,1,&out)); CHECK(out.buttons==(1u<<3));
        p.buttons=0; OK(mng_input_map(&state,&map,&p,2,&out)); CHECK(out.buttons==(1u<<3));
        p.buttons=UINT32_C(1)<<aim_slot;
        OK(mng_input_map(&state,&map,&p,3,&out)); CHECK(out.buttons==(1u<<7)); /* pending fire canceled */
        p.buttons|=UINT32_C(1)<<fire_slot;
        OK(mng_input_map(&state,&map,&p,4,&out)); CHECK(out.buttons==0);
        p.buttons=UINT32_C(1)<<fire_slot;
        OK(mng_input_map(&state,&map,&p,5,&out)); CHECK(out.buttons==0); /* no delayed attack */
        p.buttons=0; OK(mng_input_map(&state,&map,&p,6,&out)); CHECK(out.buttons==0);
        p.buttons=UINT32_C(1)<<fire_slot;
        OK(mng_input_map(&state,&map,&p,7,&out)); CHECK(out.buttons==(1u<<3)); /* fresh press works */
    }
    return 0;
}
static int mixer(void) {
    struct mng_input selected[3]={{1,{.8f,0,.2f,0},{0,.5f}}, {2,{-.8f,-2,0,0},{.7f,0}}, {4,{0,0,-.9f,2},{0,2}}},out;
    OK(mng_input_mix(selected,3,&out)); CHECK(out.buttons==7 && out.sticks[0]==.8f && out.sticks[1]==-1 && out.sticks[2]==-.9f && out.sticks[3]==1 && out.triggers[0]==.7f && out.triggers[1]==1);
    struct mng_input before=out;
    selected[1].buttons=UINT64_C(1)<<16;
    CHECK(mng_input_mix(selected,3,&out)==MNG_INPUT_INVALID && !memcmp(&out,&before,sizeof(out)));
    selected[1].buttons=0; selected[2].sticks[0]=INFINITY;
    CHECK(mng_input_mix(selected,3,&out)==MNG_INPUT_INVALID && !memcmp(&out,&before,sizeof(out)));
    CHECK(mng_input_mix(selected,9,&out)==MNG_INPUT_LIMIT && !memcmp(&out,&before,sizeof(out)));
    OK(mng_input_mix(NULL,0,&out)); struct mng_input zero={0}; CHECK(!memcmp(&out,&zero,sizeof(out)));
    return 0;
}
int main(int argc,char **argv) {
    if (argc!=2) return 2;
    int result= !strcmp(argv[1],"layouts") ? layouts():!strcmp(argv[1],"parser") ? parser():!strcmp(argv[1],"modes") ? modes():!strcmp(argv[1],"aim-fire") ? aim_fire_modes():!strcmp(argv[1],"invalid") ? invalid():!strcmp(argv[1],"mixer") ? mixer():2;
    if (!result) puts("{\"status\":\"pass\"}");
    return result;
}
