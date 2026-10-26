/* Original whole-snapshot bridge. Its consumers are the pinned original HLE
 * dm_pad_* functions, adapted only under CANOPY_MK8DX_HOST by the builder. */
#include "canopy_mk8dx.h"
#include "dm_input.h"
#include <pthread.h>
#include <math.h>
#include <string.h>
static pthread_mutex_t input_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t input_changed=PTHREAD_COND_INITIALIZER;
extern uint32_t dm_canopy_reported_mask(void);
static uint64_t devices[4],sequence,timestamp;
static int focused,terminal;
static uint64_t native_buttons(uint64_t p){static const unsigned b[16]={0,1,2,3,6,7,8,9,10,11,4,5,13,15,12,14};uint64_t n=0;for(unsigned i=0;i<16;i++)if(p&(UINT64_C(1)<<i))n|=UINT64_C(1)<<b[i];return n;}
static void clear_locked(void){for(unsigned p=0;p<4;p++){MKInputResetSeat(p);dm_pad_set_player((int)p,0,0,0,0,0);}dm_input_set(0,0,0,0,0);dm_pad_players(0);pthread_cond_broadcast(&input_changed);}
void MKClearInput(void){pthread_mutex_lock(&input_lock);clear_locked();pthread_mutex_unlock(&input_lock);}
void MKInputFocus(int active){pthread_mutex_lock(&input_lock);focused=active&&!terminal;clear_locked();pthread_mutex_unlock(&input_lock);}
void MKInputTerminal(void){pthread_mutex_lock(&input_lock);terminal=1;focused=0;clear_locked();pthread_mutex_unlock(&input_lock);}
int MKSubmit(const struct mng_session_input *in,uint64_t now){
    if(!in||!in->sequence||!in->timestamp_ns||in->timestamp_ns>now||now-in->timestamp_ns>UINT64_C(250000000))return MNG_APPLE_INVALID;
    for(unsigned i=4;i<MNG_SESSION_PLAYERS;i++){const struct mng_player_input *p=&in->players[i];if(p->connected||p->device_id||p->buttons||p->left_x||p->left_y||p->right_x||p->right_y)return MNG_APPLE_INVALID;}
    for(unsigned i=0;i<4;i++){const struct mng_player_input *p=&in->players[i];float a[]={p->left_x,p->left_y,p->right_x,p->right_y};if(p->connected>1||(p->buttons&~UINT64_C(0xffff))||(p->connected&&!p->device_id)||(!p->connected&&(p->device_id||p->buttons||p->left_x||p->left_y||p->right_x||p->right_y)))return MNG_APPLE_INVALID;for(unsigned j=0;j<4;j++)if(!isfinite(a[j])||a[j]<-1||a[j]>1)return MNG_APPLE_INVALID;for(unsigned j=0;j<i;j++)if(p->connected&&in->players[j].connected&&p->device_id==in->players[j].device_id)return MNG_APPLE_INVALID;}
    pthread_mutex_lock(&input_lock);
    if(!focused||terminal||in->sequence<=sequence||in->timestamp_ns<timestamp){pthread_mutex_unlock(&input_lock);return MNG_APPLE_INVALID;}
    uint32_t mask=0;
    for(unsigned i=0;i<4;i++){const struct mng_player_input *p=&in->players[i];if(!p->connected||devices[i]!=p->device_id)MKInputResetSeat(i);devices[i]=p->connected?p->device_id:0;dm_pad_set_player((int)i,native_buttons(p->buttons),(int32_t)lrintf(p->left_x*32767),(int32_t)lrintf(p->left_y*32767),(int32_t)lrintf(p->right_x*32767),(int32_t)lrintf(p->right_y*32767));if(p->connected)mask|=1u<<i;}
    dm_pad_players(mask);sequence=in->sequence;timestamp=in->timestamp_ns;pthread_cond_broadcast(&input_changed);pthread_mutex_unlock(&input_lock);return MNG_APPLE_OK;
}

/* Bounded direct-SDK adapter: only the two original count bytes are read.
 * Full/single-mode argument-layout equivalence and an SDK cancel Result are not
 * established by the public applet ABI. Unsupported requests terminate this
 * calling native thread with a typed HOST failure, never a fabricated Result.
 * Positive success writes s8 count + three zero padding bytes + u32 selectedID. */
uint32_t MKControllerSupport(int32_t *out,const int8_t *args){
    if(!args)MKControllerUnavailable();
    int minimum=args[0],maximum=args[1];
    if(minimum<1||minimum>4||maximum<minimum||maximum>4)MKControllerUnavailable();
    pthread_mutex_lock(&input_lock);
    for(;;){
        if(terminal){pthread_mutex_unlock(&input_lock);MKControllerUnavailable();}
        uint32_t mask=focused?dm_canopy_reported_mask()&15u:0;
        unsigned count=0,first=0;
        for(unsigned i=0;i<4;i++)if(mask&(1u<<i)){if(!count)first=i;count++;}
        if(count>=(unsigned)minimum){
            if(count>(unsigned)maximum)count=(unsigned)maximum;
            if(out){unsigned char *bytes=(unsigned char *)out;memset(bytes,0,4);bytes[0]=(unsigned char)count;uint32_t selected=first;memcpy(bytes+4,&selected,4);}
            pthread_mutex_unlock(&input_lock);return 0;
        }
        pthread_cond_wait(&input_changed,&input_lock);
    }
}
