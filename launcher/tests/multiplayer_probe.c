/* Original native client of the real guest HID bridge. No game instruction data. */
#include "mng_multiplayer.h"
#include "mng_players.h"
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef MNG_MULTIPLAYER_MODULE
static void check(int condition,const char *message) {if(!condition){fprintf(stderr,"%s\n",message);exit(2);}}
#endif
typedef int (*states_fn)(struct mng_npad_fullkey_state *,int,const uint32_t *);
typedef uint32_t (*style_fn)(const uint32_t *);
static states_fn guest_states(void) {return (states_fn)mng_multiplayer_override("_ZN2nn3hid13GetNpadStatesEPNS0_16NpadFullKeyStateEiRKj");}
static style_fn guest_style(void) {return (style_fn)mng_multiplayer_override("_ZN2nn3hid15GetNpadStyleSetERKj");}
#ifdef MNG_MULTIPLAYER_MODULE
struct native_client {struct mng_multiplayer *service;struct mng_session_host host;};
static int create(const struct mng_native_start *start,void **out) {
    struct native_client *client=calloc(1,sizeof(*client));if(!client)return -1;
    client->host=start->host;
    if(mng_multiplayer_create(4,&client->service) || mng_multiplayer_bind(client->service)) {
        mng_multiplayer_destroy(client->service);free(client);return -1;
    }
    mng_multiplayer_guest_fn initialize=mng_multiplayer_override("_ZN2nn3hid14InitializeNpadEv");initialize();*out=client;return 0;
}
static int settings(void *context,const struct mng_session_settings *settings) {(void)context;(void)settings;return 0;}
static int input(void *context,const struct mng_session_input *snapshot) {
    struct native_client *client=context;
    if(mng_multiplayer_submit(client->service,snapshot,client->host.monotonic_ns(client->host.context)))return -1;
    for(uint32_t id=0;id<4;id++) {
        struct mng_npad_fullkey_state state;
        if(guest_states()(&state,1,&id)!=1 || state.buttons!=snapshot->players[id].buttons ||
           state.attributes!=snapshot->players[id].connected || guest_style()(&id)!=snapshot->players[id].connected)return -1;
    }
    if(snapshot->sequence && snapshot->players[0].connected && snapshot->players[1].connected && snapshot->players[2].connected && snapshot->players[3].connected && client->host.log)client->host.log(client->host.context,0,"four-native-guest-hid-states-consumed");
    return 0;
}
static int pause_client(void *context,int paused) {(void)context;(void)paused;return 0;}
static int tick(void *context,uint64_t now) {(void)context;return now?0:-1;}
static void destroy(void *context) {struct native_client *client=context;mng_multiplayer_destroy(client->service);free(client);}
const struct mng_native_module *canopy_native_module_v1(void) {
    static const struct mng_native_module module={1,sizeof(module),UINT64_C(0x1234),9,create,settings,input,pause_client,tick,destroy};return &module;
}
#else
static struct mng_session_input snapshot(uint64_t sequence) {
    struct mng_session_input result={.sequence=sequence,.timestamp_ns=1000+sequence};
    for(unsigned i=0;i<4;i++)result.players[i]=(struct mng_player_input){100+i,UINT64_C(1)<<i,(float)i/4,-(float)i/4,0,0,1};
    return result;
}
static struct mng_multiplayer *make(unsigned capacity) {
    struct mng_multiplayer *s=NULL;check(!mng_multiplayer_create(capacity,&s),"create");mng_multiplayer_initialize(s);return s;
}
static void four(void) {
    struct mng_multiplayer *s=make(4);struct mng_session_input input=snapshot(1);
    check(!mng_multiplayer_submit(s,&input,1001),"submit4");check(!mng_multiplayer_bind(s),"bind");
    for(uint32_t id=0;id<4;id++) {
        struct {struct mng_npad_fullkey_state state;uint64_t sentinel;} out={.sentinel=UINT64_C(0xabcdef)};
        check(guest_states()(&out.state,1,&id)==1 && guest_style()(&id)==1,"guest read/style");
        check(out.state.buttons==(UINT64_C(1)<<id) && out.state.attributes==1,"independent guest button");
        check(out.state.lx==(int32_t)lrintf(input.players[id].left_x*32767) && out.state.ly==-out.state.lx,"independent sticks");
        check(out.sentinel==UINT64_C(0xabcdef) && !out.state.reserved,"ABI output size");
    }
    check(!mng_multiplayer_override("_ZN2nn3ldn10InitializeEv"),"unsupported service spoof");
    check(!mng_multiplayer_override("_ZN2nn3hid21ShowControllerSupportEPNS0_27ControllerSupportResultInfoERKNS0_20ControllerSupportArgE"),"unsupported applet spoof");
    mng_multiplayer_destroy(s);uint32_t id=0;struct mng_npad_fullkey_state state;
    check(guest_states()(&state,1,&id)==0 && guest_style()(&id)==0,"detached guest callback");
}
static void mapping(void) {
    static const unsigned expected[16]={0,1,2,3,6,7,8,9,10,11,4,5,13,15,12,14};struct mng_multiplayer *s=make(4);
    for(unsigned bit=0;bit<16;bit++) {
        struct mng_session_input input=snapshot(bit+1);input.players[0].buttons=UINT64_C(1)<<bit;
        check(!mng_multiplayer_submit(s,&input,input.timestamp_ns),"mapping submit");struct mng_npad_fullkey_state state;
        check(mng_multiplayer_states(s,&state,1,0)==1 && state.buttons==(UINT64_C(1)<<expected[bit]),"native guest bit layout");
    }
    mng_multiplayer_destroy(s);
}
static void invalid(void) {
    struct mng_multiplayer *s=make(4);struct mng_session_input base=snapshot(5);check(!mng_multiplayer_submit(s,&base,1005),"baseline");
    struct mng_session_input bad=base;check(mng_multiplayer_submit(s,&bad,1005)==MNG_MULTIPLAYER_STALE,"sequence replay");
    bad=snapshot(6);bad.timestamp_ns=1004;check(mng_multiplayer_submit(s,&bad,1006)==MNG_MULTIPLAYER_STALE,"timestamp replay");
    bad=snapshot(6);check(mng_multiplayer_submit(s,&bad,UINT64_C(250001007))==MNG_MULTIPLAYER_STALE,"stale age");
    bad=snapshot(6);check(mng_multiplayer_submit(s,&bad,1005)==MNG_MULTIPLAYER_STALE,"future");
    bad=snapshot(6);bad.players[1].device_id=bad.players[0].device_id;check(mng_multiplayer_submit(s,&bad,1006)==MNG_MULTIPLAYER_INVALID,"duplicate devices");
    bad=snapshot(6);bad.players[0].left_x=NAN;check(mng_multiplayer_submit(s,&bad,1006)==MNG_MULTIPLAYER_INVALID,"nan");
    bad=snapshot(6);bad.players[0].left_x=2;check(mng_multiplayer_submit(s,&bad,1006)==MNG_MULTIPLAYER_INVALID,"range");
    bad=snapshot(6);bad.players[0].buttons=UINT64_C(1)<<16;check(mng_multiplayer_submit(s,&bad,1006)==MNG_MULTIPLAYER_INVALID,"system button");
    bad=snapshot(6);bad.players[4]=bad.players[0];bad.players[4].device_id=999;check(mng_multiplayer_submit(s,&bad,1006)==MNG_MULTIPLAYER_INVALID,"unsupported seat");
    struct mng_npad_fullkey_state state;check(mng_multiplayer_states(s,&state,1,0)==1 && state.buttons==1 && state.sampling==2,"invalid update changed state");
    mng_multiplayer_destroy(s);
}
static void filters(void) {
    struct mng_multiplayer *s=make(4);struct mng_session_input input=snapshot(1);check(!mng_multiplayer_submit(s,&input,1001),"filter submit");
    uint32_t ids[]={1,3,0x20,7,0x10};check(!mng_multiplayer_supported_ids(s,ids,5),"known IDs filter");
    check(!mng_multiplayer_style(s,0) && mng_multiplayer_style(s,1)==1 && !mng_multiplayer_style(s,0x20),"filtered ID style");
    mng_multiplayer_supported_styles(s,2);struct mng_npad_fullkey_state state;
    check(!mng_multiplayer_style(s,1) && mng_multiplayer_states(s,&state,1,1)==1 && !state.buttons && !state.attributes,"unsupported style connected");
    mng_multiplayer_supported_styles(s,UINT32_MAX);check(mng_multiplayer_style(s,1)==1,"FullKey style not restored");
    ids[0]=99;check(mng_multiplayer_supported_ids(s,ids,1)==MNG_MULTIPLAYER_INVALID && mng_multiplayer_style(s,1)==1,"invalid filter mutated");
    check(!mng_multiplayer_bind(s),"bind filters");
    void (*set_ids)(const uint32_t *,uint64_t)=(void (*)(const uint32_t *,uint64_t))mng_multiplayer_override("_ZN2nn3hid22SetSupportedNpadIdTypeEPKjm");
    set_ids(NULL,11);check(!mng_multiplayer_style(s,1),"invalid guest filter not fail-closed");mng_multiplayer_destroy(s);
}
static void history(void) {
    struct mng_multiplayer *s=make(4);
    for(unsigned seq=1;seq<=20;seq++){struct mng_session_input input=snapshot(seq);check(!mng_multiplayer_submit(s,&input,input.timestamp_ns),"history submit");}
    struct mng_npad_fullkey_state states[16];check(mng_multiplayer_states(s,states,16,0)==16,"history cap");
    for(unsigned i=1;i<16;i++)check(states[i-1].sampling==states[i].sampling+1,"history chronology");
    mng_multiplayer_disconnect(s,0);check(mng_multiplayer_states(s,states,16,0)==1 && !states[0].buttons,"guest disconnect held state");
    struct mng_session_input input=snapshot(21);check(!mng_multiplayer_submit(s,&input,1021),"after disconnect");
    check(!mng_multiplayer_style(s,0),"same controller silently reattached");
    input=snapshot(22);input.players[0].device_id=999;input.players[0].buttons=8;check(!mng_multiplayer_submit(s,&input,1022),"replacement");
    check(mng_multiplayer_states(s,states,16,0)==16 && states[0].buttons==8 && states[0].attributes==1,"replacement absent");
    for(unsigned i=1;i<16;i++)check(!states[i].buttons && !states[i].attributes,"replacement replayed old device");
    struct mng_session_input neutral={0};check(!mng_multiplayer_submit(s,&neutral,1022),"owner cancellation");
    check(mng_multiplayer_states(s,states,16,0)==1 && !states[0].buttons,"cancel held state");
    check(mng_multiplayer_submit(s,&input,1022)==MNG_MULTIPLAYER_STALE,"neutral reset sequence");
    mng_multiplayer_destroy(s);
}
static void disconnected_pause(void) {
    struct mng_multiplayer *s=make(1);check(!mng_multiplayer_bind(s),"latch bind");
    struct mng_session_input input={.sequence=1,.timestamp_ns=100};
    input.players[0]=(struct mng_player_input){7,1,0,0,0,0,1};
    check(!mng_multiplayer_submit(s,&input,100),"latch input");
    uint32_t id=0;
    void (*disconnect_guest)(const uint32_t *)=(void (*)(const uint32_t *))mng_multiplayer_override("_ZN2nn3hid14DisconnectNpadERKj");
    disconnect_guest(&id);check(!guest_style()(&id),"guest disconnect latch");
    struct mng_session_input cancellation={0};check(!mng_multiplayer_submit(s,&cancellation,100),"latch cancellation");
    struct mng_npad_fullkey_state states[16];check(guest_states()(states,16,&id)==1 && !states[0].buttons,"latch cancellation held input");
    input.sequence=2;input.timestamp_ns=101;check(!mng_multiplayer_submit(s,&input,101),"same physical resume");
    check(!guest_style()(&id) && guest_states()(states,16,&id)==1 && !states[0].attributes && !states[0].buttons,"pause cleared guest disconnect latch");
    input.sequence=3;input.timestamp_ns=102;input.players[0].device_id=8;input.players[0].buttons=2;
    check(!mng_multiplayer_submit(s,&input,102) && guest_style()(&id)==1,"actual replacement did not reconnect");
    check(guest_states()(states,16,&id)>0 && states[0].buttons==2,"replacement input absent");
    for(unsigned i=1;i<4;i++)check(!states[i].buttons && !states[i].attributes,"replacement replayed disconnected input");
    disconnect_guest(&id);input.sequence=4;input.timestamp_ns=103;memset(input.players,0,sizeof(input.players));
    check(!mng_multiplayer_submit(s,&input,103),"physical disconnect");
    input.sequence=5;input.timestamp_ns=104;input.players[0]=(struct mng_player_input){8,4,0,0,0,0,1};
    check(!mng_multiplayer_submit(s,&input,104) && guest_style()(&id)==1,"explicit disconnect/reconnect latch");
    mng_multiplayer_destroy(s);
}
static void bind_lifetime(void) {
    struct mng_multiplayer *a=make(1),*b=make(4);check(!mng_multiplayer_bind(a),"bind a");
    check(mng_multiplayer_bind(b)==MNG_MULTIPLAYER_BUSY,"binding silently replaced");
    check(mng_multiplayer_unbind(b)==MNG_MULTIPLAYER_INVALID,"foreign unbind");mng_multiplayer_destroy(b);
    check(!mng_multiplayer_unbind(a),"unbind a");mng_multiplayer_destroy(a);
    struct mng_multiplayer *s=NULL;check(mng_multiplayer_create(0,&s)==MNG_MULTIPLAYER_INVALID && !s,"capacity zero");
    check(mng_multiplayer_create(5,&s)==MNG_MULTIPLAYER_INVALID && !s,"capacity five");
    s=make(1);struct mng_session_input input=snapshot(1);check(mng_multiplayer_submit(s,&input,1001)==MNG_MULTIPLAYER_INVALID,"single-player cap expanded");mng_multiplayer_destroy(s);
}
static void *read_thread(void *context) {
    (void)context;uint32_t id=0;
    for(unsigned i=0;i<20000;i++){struct mng_npad_fullkey_state state;int n=guest_states()(&state,1,&id);check(n==0 || (n==1 && state.buttons<=1),"concurrent guest state corruption");}
    return NULL;
}
static void concurrency(void) {
    struct mng_multiplayer *s=make(4);check(!mng_multiplayer_bind(s),"concurrent bind");pthread_t thread;
    check(!pthread_create(&thread,NULL,read_thread,NULL),"reader thread");
    for(unsigned i=1;i<=1000;i++){struct mng_session_input input=snapshot(i);check(!mng_multiplayer_submit(s,&input,input.timestamp_ns),"concurrent submit");}
    mng_multiplayer_destroy(s);check(!pthread_join(thread,NULL),"join reader");
}
static uint64_t now(void *context) {(void)context;return 1000000000;}
static unsigned leases,consumed;
static int retain(void *context,const char *root) {(void)context;(void)root;leases++;return 0;}
static void release(void *context,const char *root) {(void)context;(void)root;leases--;}
static void log_message(void *context,uint32_t level,const char *message) {(void)context;(void)level;if(!strcmp(message,"four-native-guest-hid-states-consumed"))consumed++;}
static void router_snapshot(struct mng_players *players,struct mng_session_input *input,uint64_t sequence) {
    memset(input,0,sizeof(*input));input->sequence=sequence;input->timestamp_ns=1000000000;
    for(unsigned i=0;i<4;i++) {
        uint64_t id=0;struct mng_input state;
        check(!mng_players_read(players,i,&id,&state),"router snapshot");
        input->players[i]=(struct mng_player_input){id,state.buttons,state.sticks[0],state.sticks[1],state.sticks[2],state.sticks[3],id!=0};
    }
}
static void session(int argc,char **argv) {
    check(argc==6,"session arguments");struct mng_session_manifest manifest={0};manifest.version=1;manifest.execution_capability=1;
    manifest.title_id=0x1234;manifest.title_version=9;manifest.prepared_root=argv[2];manifest.save_root=argv[2];manifest.profile_id="original-client";
    manifest.module_relative_path=argv[3];manifest.module_size=strtoull(argv[4],NULL,10);check(strlen(argv[5])==64,"hash length");
    for(unsigned i=0;i<32;i++){unsigned byte;check(sscanf(argv[5]+2*i,"%2x",&byte)==1,"hash parse");manifest.module_sha256[i]=(unsigned char)byte;}
    struct mng_session_host host={sizeof(host),NULL,now,log_message,NULL,retain,release};
    struct mng_session_settings settings={sizeof(settings),1280,720,30,0,0,1};struct mng_session *running=NULL;
    check(!mng_session_open(&manifest,&host,&settings,&running),"verified production native loader");check(leases==1,"generation pin absent");
    struct mng_players players;mng_players_init(&players);struct mng_session_input input={.sequence=1,.timestamp_ns=1000000000};
    for(unsigned i=0;i<4;i++) {
        uint64_t token=0;check(!mng_players_connect(&players,100+i) && !mng_players_assign(&players,i,100+i) && !mng_players_token(&players,100+i,&token),"actual router assign");
        struct mng_input state={.buttons=UINT64_C(1)<<i};check(!mng_players_update(&players,100+i,token,1,&state),"actual router update");
        uint64_t id=0;check(!mng_players_read(&players,i,&id,&state),"actual router read");
        input.players[i]=(struct mng_player_input){id,state.buttons,state.sticks[0],state.sticks[1],state.sticks[2],state.sticks[3],id!=0};
    }
    check(!mng_session_submit_input(running,&input) && consumed==1,"native four-player guest consumption");
    check(!mng_players_swap(&players,0,3),"router swap");
    for(unsigned i=0;i<4;i++) {
        uint64_t token=0;struct mng_input state={.buttons=UINT64_C(1)<<i};
        check(!mng_players_token(&players,100+i,&token) && !mng_players_update(&players,100+i,token,2,&state),"resample swapped controller");
    }
    router_snapshot(&players,&input,2);check(input.players[0].buttons==8 && input.players[3].buttons==1,"independent router swap");
    check(!mng_session_submit_input(running,&input) && consumed==2,"native guest swapped seats");
    check(!mng_players_disconnect(&players,101),"physical disconnect");router_snapshot(&players,&input,3);
    check(!input.players[1].connected && !mng_session_submit_input(running,&input) && consumed==2,"native guest disconnected seat");
    uint64_t token=0;struct mng_input reconnected={.buttons=2};
    check(!mng_players_connect(&players,101) && !mng_players_assign(&players,1,101) &&
        !mng_players_token(&players,101,&token) && !mng_players_update(&players,101,token,1,&reconnected),"physical reconnect");
    router_snapshot(&players,&input,4);check(!mng_session_submit_input(running,&input) && consumed==3,"native guest reconnect");
    check(!mng_session_pause(running,1) && !mng_session_pause(running,0),"native neutral cancellation");
    input.sequence=5;check(!mng_session_submit_input(running,&input) && consumed==4,"native four-player resume");
    mng_session_close(running);check(!leases,"generation lease leaked");
}
int main(int argc,char **argv) {
    check(argc>=2,"scenario");
    if(!strcmp(argv[1],"four"))four();else if(!strcmp(argv[1],"mapping"))mapping();else if(!strcmp(argv[1],"invalid"))invalid();
    else if(!strcmp(argv[1],"filters"))filters();else if(!strcmp(argv[1],"history"))history();
    else if(!strcmp(argv[1],"binding"))bind_lifetime();else if(!strcmp(argv[1],"latch"))disconnected_pause();else if(!strcmp(argv[1],"concurrency"))concurrency();
    else if(!strcmp(argv[1],"session"))session(argc,argv);else check(0,"unknown scenario");
    puts("{\"status\":\"pass\",\"scope\":\"original native guest HID client; no title gameplay claim\"}");return 0;
}
#endif
