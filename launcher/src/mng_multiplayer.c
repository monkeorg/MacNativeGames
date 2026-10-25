#include "mng_multiplayer.h"
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
_Static_assert(sizeof(struct mng_npad_fullkey_state)==40,"FullKey state ABI");
_Static_assert(offsetof(struct mng_npad_fullkey_state,attributes)==32,"FullKey attributes ABI");
struct mng_multiplayer {
    pthread_mutex_t lock;
    unsigned capacity,count;
    uint32_t allowed,styles,disconnected;
    int initialized;
    int64_t sample;
    uint64_t sequence,timestamp,devices[MNG_MULTIPLAYER_MAX];
    struct mng_npad_fullkey_state history[MNG_MULTIPLAYER_MAX][MNG_MULTIPLAYER_HISTORY];
};
static pthread_mutex_t binding_lock=PTHREAD_MUTEX_INITIALIZER;
static struct mng_multiplayer *bound;
int mng_multiplayer_create(unsigned capacity,struct mng_multiplayer **out) {
    if(!out || !capacity || capacity>MNG_MULTIPLAYER_MAX)return MNG_MULTIPLAYER_INVALID;
    struct mng_multiplayer *s=calloc(1,sizeof(*s));if(!s)return MNG_MULTIPLAYER_LIMIT;
    if(pthread_mutex_init(&s->lock,NULL)){free(s);return MNG_MULTIPLAYER_LIMIT;}
    s->capacity=capacity;s->allowed=(1u<<capacity)-1;s->styles=1;s->count=1;s->sample=1;
    for(unsigned i=0;i<capacity;i++)s->history[i][0].sampling=1;
    *out=s;return MNG_MULTIPLAYER_OK;
}
int mng_multiplayer_bind(struct mng_multiplayer *s) {
    if(!s)return MNG_MULTIPLAYER_INVALID;
    pthread_mutex_lock(&binding_lock);int rc=bound && bound!=s ? MNG_MULTIPLAYER_BUSY:MNG_MULTIPLAYER_OK;
    if(!rc)bound=s;
    pthread_mutex_unlock(&binding_lock);return rc;
}
int mng_multiplayer_unbind(struct mng_multiplayer *s) {
    if(!s)return MNG_MULTIPLAYER_INVALID;
    pthread_mutex_lock(&binding_lock);int rc=bound==s ? MNG_MULTIPLAYER_OK:MNG_MULTIPLAYER_INVALID;
    if(!rc)bound=NULL;
    pthread_mutex_unlock(&binding_lock);return rc;
}
void mng_multiplayer_destroy(struct mng_multiplayer *s) {
    if(!s)return;
    pthread_mutex_lock(&binding_lock);if(bound==s)bound=NULL;
    pthread_mutex_unlock(&binding_lock);
    pthread_mutex_destroy(&s->lock);free(s);
}
static uint64_t native_buttons(uint64_t portable) {
    static const unsigned bits[16]={0,1,2,3,6,7,8,9,10,11,4,5,13,15,12,14};
    uint64_t result=0;for(unsigned i=0;i<16;i++)if(portable&(UINT64_C(1)<<i))result|=UINT64_C(1)<<bits[i];
    return result;
}
static int neutral(const struct mng_player_input *p) {
    return !p->device_id && !p->buttons && !p->connected && !p->left_x && !p->left_y && !p->right_x && !p->right_y;
}
int mng_multiplayer_submit(struct mng_multiplayer *s,const struct mng_session_input *input,uint64_t now) {
    if(!s || !input)return MNG_MULTIPLAYER_INVALID;
    int cancellation=!input->sequence && !input->timestamp_ns;
    if(!cancellation && (!input->sequence || !input->timestamp_ns || input->timestamp_ns>now || now-input->timestamp_ns>UINT64_C(250000000)))return MNG_MULTIPLAYER_STALE;
    for(unsigned i=0;i<MNG_SESSION_PLAYERS;i++) {
        const struct mng_player_input *p=input->players+i;float axes[]={p->left_x,p->left_y,p->right_x,p->right_y};
        if((p->buttons&~UINT64_C(0xffff)) || p->connected>1 || (p->connected && (!p->device_id || i>=s->capacity)) ||
            (!p->connected && (p->device_id || p->buttons || p->left_x || p->left_y || p->right_x || p->right_y)) ||
            (cancellation && !neutral(p)))return MNG_MULTIPLAYER_INVALID;
        for(unsigned a=0;a<4;a++)if(!isfinite(axes[a]) || axes[a]<-1 || axes[a]>1)return MNG_MULTIPLAYER_INVALID;
        if(p->connected)for(unsigned j=0;j<i;j++)if(input->players[j].connected && input->players[j].device_id==p->device_id)return MNG_MULTIPLAYER_INVALID;
    }
    pthread_mutex_lock(&s->lock);
    if(!cancellation && (input->sequence<=s->sequence || input->timestamp_ns<s->timestamp)){
        pthread_mutex_unlock(&s->lock);return MNG_MULTIPLAYER_STALE;
    }
    if(s->sample==INT64_MAX){pthread_mutex_unlock(&s->lock);return MNG_MULTIPLAYER_LIMIT;}
    s->sample++;
    for(unsigned i=0;i<s->capacity;i++) {
        const struct mng_player_input *p=input->players+i;
        if(cancellation || s->devices[i]!=p->device_id) {
            if(!cancellation)s->disconnected&=~(1u<<i);
            /* Historical presses belong to the prior physical device. Preserve
             * sample chronology, never replay them into a replacement seat. */
            for(unsigned h=0;h<MNG_MULTIPLAYER_HISTORY;h++) {
                int64_t sampling=s->history[i][h].sampling;
                s->history[i][h]=(struct mng_npad_fullkey_state){.sampling=sampling};
            }
        }
        if(!cancellation)s->devices[i]=p->device_id;
        memmove(s->history[i]+1,s->history[i],(MNG_MULTIPLAYER_HISTORY-1)*sizeof(s->history[i][0]));
        s->history[i][0]=(struct mng_npad_fullkey_state){s->sample,native_buttons(p->buttons),
            (int32_t)lrintf(p->left_x*32767),(int32_t)lrintf(p->left_y*32767),
            (int32_t)lrintf(p->right_x*32767),(int32_t)lrintf(p->right_y*32767),p->connected,0};
    }
    if(s->count<MNG_MULTIPLAYER_HISTORY)s->count++;
    if(!cancellation){s->sequence=input->sequence;s->timestamp=input->timestamp_ns;}
    pthread_mutex_unlock(&s->lock);return MNG_MULTIPLAYER_OK;
}
void mng_multiplayer_initialize(struct mng_multiplayer *s) {
    if(!s)return;
    pthread_mutex_lock(&s->lock);s->initialized=1;pthread_mutex_unlock(&s->lock);
}
int mng_multiplayer_supported_ids(struct mng_multiplayer *s,const uint32_t *ids,size_t n) {
    if(!s || n>10 || (n && !ids))return MNG_MULTIPLAYER_INVALID;
    uint32_t mask=0;
    for(size_t i=0;i<n;i++) {
        if(ids[i]>7 && ids[i]!=0x20 && ids[i]!=0x10)return MNG_MULTIPLAYER_INVALID;
        for(size_t j=0;j<i;j++)if(ids[i]==ids[j])return MNG_MULTIPLAYER_INVALID;
        if(ids[i]<s->capacity)mask|=1u<<ids[i];
    }
    pthread_mutex_lock(&s->lock);s->allowed=mask;pthread_mutex_unlock(&s->lock);return MNG_MULTIPLAYER_OK;
}
void mng_multiplayer_supported_styles(struct mng_multiplayer *s,uint32_t styles) {
    if(!s)return;
    pthread_mutex_lock(&s->lock);s->styles=styles&1u;pthread_mutex_unlock(&s->lock);
}
static int connected(const struct mng_multiplayer *s,uint32_t id) {
    return id<s->capacity && s->initialized && s->styles && (s->allowed&(1u<<id)) &&
        !(s->disconnected&(1u<<id)) && s->history[id][0].attributes;
}
uint32_t mng_multiplayer_style(struct mng_multiplayer *s,uint32_t id) {
    if(!s)return 0;
    pthread_mutex_lock(&s->lock);uint32_t result=connected(s,id)?1:0;pthread_mutex_unlock(&s->lock);return result;
}
int mng_multiplayer_states(struct mng_multiplayer *s,struct mng_npad_fullkey_state *out,int maximum,uint32_t id) {
    if(!s || !out || maximum<=0)return 0;
    pthread_mutex_lock(&s->lock);
    int n=1;
    if(connected(s,id)) {
        n=maximum<(int)s->count?maximum:(int)s->count;memcpy(out,s->history[id],(size_t)n*sizeof(*out));
    } else *out=(struct mng_npad_fullkey_state){.sampling=s->sample};
    pthread_mutex_unlock(&s->lock);return n;
}
void mng_multiplayer_disconnect(struct mng_multiplayer *s,uint32_t id) {
    if(!s)return;
    pthread_mutex_lock(&s->lock);if(id<s->capacity)s->disconnected|=1u<<id;pthread_mutex_unlock(&s->lock);
}
/* Global bridge lock encloses each typed guest call and detachment, so a
 * resolved function pointer cannot retain a freed title service instance. */
static void guest_initialize(void) {
    pthread_mutex_lock(&binding_lock);mng_multiplayer_initialize(bound);pthread_mutex_unlock(&binding_lock);
}
static void guest_ids(const uint32_t *ids,uint64_t n) {
    pthread_mutex_lock(&binding_lock);
    if(n>10 || mng_multiplayer_supported_ids(bound,ids,(size_t)n)) (void)mng_multiplayer_supported_ids(bound,NULL,0);
    pthread_mutex_unlock(&binding_lock);
}
static void guest_styles(uint32_t styles) {
    pthread_mutex_lock(&binding_lock);mng_multiplayer_supported_styles(bound,styles);pthread_mutex_unlock(&binding_lock);
}
static uint32_t guest_style(const uint32_t *id) {
    pthread_mutex_lock(&binding_lock);uint32_t result=id?mng_multiplayer_style(bound,*id):0;
    pthread_mutex_unlock(&binding_lock);return result;
}
static int guest_states(struct mng_npad_fullkey_state *out,int maximum,const uint32_t *id) {
    pthread_mutex_lock(&binding_lock);int result=id?mng_multiplayer_states(bound,out,maximum,*id):0;
    pthread_mutex_unlock(&binding_lock);return result;
}
static void guest_disconnect(const uint32_t *id) {
    pthread_mutex_lock(&binding_lock);if(id)mng_multiplayer_disconnect(bound,*id);pthread_mutex_unlock(&binding_lock);
}
mng_multiplayer_guest_fn mng_multiplayer_override(const char *name) {
    if(!name)return NULL;
    size_t length=0;while(length<160 && name[length])length++;
    if(length==160)return NULL;
#define MATCH(symbol,fn) if(!strcmp(name,symbol))return (mng_multiplayer_guest_fn)(fn)
    MATCH("_ZN2nn3hid14InitializeNpadEv",guest_initialize);
    MATCH("_ZN2nn3hid22SetSupportedNpadIdTypeEPKjm",guest_ids);
    MATCH("_ZN2nn3hid24SetSupportedNpadStyleSetENS_4util10BitFlagSetILi32ENS0_12NpadStyleTagEEE",guest_styles);
    MATCH("_ZN2nn3hid15GetNpadStyleSetERKj",guest_style);
    MATCH("_ZN2nn3hid13GetNpadStatesEPNS0_16NpadFullKeyStateEiRKj",guest_states);
    MATCH("_ZN2nn3hid14DisconnectNpadERKj",guest_disconnect);
#undef MATCH
    return NULL;
}
