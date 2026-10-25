/* Original-source native module and production-loader harness; no game payload. */
#define _POSIX_C_SOURCE 200809L
#include "mng_session.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef MNG_SESSION_DRIVER
struct fixture {
    struct mng_native_start start;
    unsigned ticks, inputs, settings;
    int paused;
};
static int create(const struct mng_native_start *start,void **out) {
    struct fixture *f=calloc(1,sizeof(*f));
    if(!f)return -1;
    f->start=*start;*out=f;
    if(start->host.log)start->host.log(start->host.context,0,"fixture-created");
    return 0;
}
static int settings(void *p,const struct mng_session_settings *s) {
    struct fixture *f=p;f->start.settings=*s;f->settings++;return 0;
}
static int input(void *p,const struct mng_session_input *i) {
    struct fixture *f=p;
    if(i->sequence && (i->players[0].buttons!=1 || i->players[1].buttons!=2 || i->players[0].device_id==i->players[1].device_id))return -1;
    f->inputs++;return 0;
}
static int pause_module(void *p,int paused) {((struct fixture *)p)->paused=paused;return 0;}
static int tick(void *p,uint64_t now) {struct fixture *f=p;if(f->paused || !now)return -1;f->ticks++;return 0;}
static void destroy(void *p) {
    struct fixture *f=p;char path[4096];
    snprintf(path,sizeof(path),"%s/fixture-save",f->start.save_root);
    FILE *out=fopen(path,"wb");
    if(out){fprintf(out,"%s %u %u %u %u\n",f->start.profile_id,f->ticks,f->inputs,f->settings,f->start.settings.frame_limit);fclose(out);}
    if(f->start.host.log)f->start.host.log(f->start.host.context,0,"fixture-destroyed");
    free(f);
}
#ifndef FIXTURE_ABI
#define FIXTURE_ABI MNG_NATIVE_ABI_V1
#endif
#ifndef FIXTURE_MISSING_ENTRY
const struct mng_native_module *canopy_native_module_v1(void) {
    static const struct mng_native_module module={FIXTURE_ABI,sizeof(module),0x1234,7,create,settings,input,pause_module,tick,destroy};
    return &module;
}
#else
/* Keep implementation referenced in this malformed fixture. */
const struct mng_native_module *wrong_entry(void) {
    static const struct mng_native_module module={1,sizeof(module),0x1234,7,create,settings,input,pause_module,tick,destroy};return &module;
}
#endif
#else
static uint64_t now(void *p) {(void)p;return 1000000000;}
static unsigned logs, leases;
static int retain(void *p,const char *root) {(void)p;(void)root;leases++;return 0;}
static void release(void *p,const char *root) {(void)p;(void)root;leases--;}
static void log_message(void *p,uint32_t level,const char *message) {(void)p;(void)level;if(!strncmp(message,"fixture-",8))logs++;}
int main(int argc,char **argv) {
    struct mng_session *session=NULL;
    struct mng_session_manifest m={0};
    struct mng_session_host h={sizeof(h),NULL,now,log_message,NULL,retain,release};
    struct mng_session_settings settings={sizeof(settings),1280,720,60,0,0,1};
    struct mng_session_input input={0};
    int rc;
    if(argc!=6)return 99;
    m.version=1;m.execution_capability=1;m.title_id=0x1234;m.title_version=7;
    m.prepared_root=argv[1];m.module_relative_path=argv[2];m.save_root=argv[1];m.profile_id="profile-a";
    m.module_size=strtoull(argv[3],NULL,10);
    if(strlen(argv[4])!=64)return 98;
    for(unsigned i=0;i<32;i++){unsigned x;if(sscanf(argv[4]+2*i,"%2x",&x)!=1)return 97;m.module_sha256[i]=(unsigned char)x;}
    if(!strcmp(argv[5],"unapproved"))m.execution_capability=0;
    if(!strcmp(argv[5],"identity"))m.title_version++;
    rc=mng_session_open(&m,&h,&settings,&session);
    if(rc){if(leases)return 93;printf("%d\n",rc);return 0;}
    input.sequence=1;input.timestamp_ns=now(NULL);
    input.players[0]=(struct mng_player_input){101,1,0.5f,0,0,0,1};
    input.players[1]=(struct mng_player_input){102,2,-0.5f,0,0,0,1};
    if(!strcmp(argv[5],"stale"))input.timestamp_ns=1;
    if(!strcmp(argv[5],"duplicate-device"))input.players[1].device_id=101;
    rc=mng_session_submit_input(session,&input);
    if(!strcmp(argv[5],"valid")) {
        if(rc || mng_session_submit_input(session,&input)!=MNG_SESSION_STALE_INPUT || mng_session_tick(session))return 96;
        settings.frame_limit=30;
        if(mng_session_update_settings(session,&settings) || mng_session_pause(session,1) || mng_session_tick(session)!=MNG_SESSION_INVALID || mng_session_pause(session,0))return 95;
    }
    mng_session_close(session);
    if(logs!=2 || leases)return 94;
    printf("%d\n",rc);return 0;
}
#endif
