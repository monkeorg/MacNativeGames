#ifndef MNG_PREPARATION_SELECTION_H
#define MNG_PREPARATION_SELECTION_H
#include <stdint.h>
#include <string.h>

/* Main-thread picker ownership only. No URL, key, bookmark or source identity.
 * A requested job ID is a selection, never authority to resume different bytes.
 * The native preparation store verifies the selected inputs' fingerprint. */
enum mng_selection_stage { MNG_SELECT_IDLE, MNG_SELECT_SOURCE, MNG_SELECT_KEYS,
    MNG_SELECT_READY, MNG_SELECT_UPDATE, MNG_SELECT_MODE, MNG_SELECT_KEY_PROMPT, MNG_SELECT_REVISION };
enum mng_selection_mode { MNG_SELECT_BASE=1, MNG_SELECT_PAIRED,
    MNG_SELECT_NCA_FOLDER, MNG_SELECT_ASSET_FOLDER };
struct mng_preparation_selection {
    uint64_t epoch;
    uintptr_t picker;
    unsigned stage, mode;
    int latest_update;
    uint32_t target_version;
    char job[33];
    uintptr_t origin;
    char reuse_title[17],reuse_generation[65];
};
struct mng_preparation_request {
    unsigned mode;
    int latest_update;
    uint32_t target_version;
    char job[33],reuse_title[17],reuse_generation[65];
};
static inline int mng_selection_hex_valid(const char *value,unsigned length) {
    if(!value)return 0;
    for(unsigned i=0;i<length;i++)if(!((value[i]>='0'&&value[i]<='9')||(value[i]>='a'&&value[i]<='f')))return 0;
    return value[length]==0;
}
static inline int mng_selection_job_valid(const char *job) {
    if (!job) return 0;
    for (unsigned i=0;i<32;i++)
        if (!((job[i]>='0'&&job[i]<='9')||(job[i]>='a'&&job[i]<='f'))) return 0;
    return job[32]==0;
}
static inline void mng_selection_cancel(struct mng_preparation_selection *s) {
    if (s->epoch!=UINT64_MAX) s->epoch++;
    s->latest_update=1;s->target_version=0;
    s->picker=0;s->stage=MNG_SELECT_IDLE;s->mode=0;s->origin=0;memset(s->job,0,sizeof(s->job));
    memset(s->reuse_title,0,sizeof(s->reuse_title));memset(s->reuse_generation,0,sizeof(s->reuse_generation));
}
static inline int mng_selection_begin(struct mng_preparation_selection *s,const char *job) {
    if (s->stage!=MNG_SELECT_IDLE || s->epoch==UINT64_MAX || (job&&!mng_selection_job_valid(job))) return 0;
    s->latest_update=1;s->target_version=0;
    s->epoch++;s->stage=MNG_SELECT_MODE;s->picker=0;s->mode=0;
    s->origin=0;memset(s->reuse_title,0,sizeof(s->reuse_title));memset(s->reuse_generation,0,sizeof(s->reuse_generation));
    memset(s->job,0,sizeof(s->job));if(job)memcpy(s->job,job,32);return 1;
}
/* Exact selected library generation, not source/input fingerprint authority.
 * Origin is an opaque retained controller identity; no addresses enter JSON.
 * This route starts a NEW job and permits only original base+update inputs. */
static inline int mng_selection_begin_reuse(struct mng_preparation_selection *s,
    const char *title,const char *generation,uintptr_t origin) {
    if(!origin||!mng_selection_hex_valid(title,16)||!strcmp(title,"0000000000000000")||
        !mng_selection_hex_valid(generation,64)||!mng_selection_begin(s,NULL))return 0;
    s->origin=origin;memcpy(s->reuse_title,title,17);memcpy(s->reuse_generation,generation,65);return 1;
}
static inline int mng_selection_origin_is(const struct mng_preparation_selection *s,uint64_t epoch,uintptr_t origin) {
    return epoch && s->epoch==epoch && s->stage!=MNG_SELECT_IDLE && origin && s->origin==origin;
}
static inline int mng_selection_is(const struct mng_preparation_selection *s,uint64_t epoch,unsigned stage) {
    return epoch && s->epoch==epoch && s->stage==stage;
}
static inline int mng_selection_choose(struct mng_preparation_selection *s,uint64_t epoch,unsigned mode) {
    if (!mng_selection_is(s,epoch,MNG_SELECT_MODE)||mode<MNG_SELECT_BASE||mode>MNG_SELECT_ASSET_FOLDER||
        (s->origin&&mode!=MNG_SELECT_PAIRED)) return 0;
    s->mode=mode;s->stage=MNG_SELECT_SOURCE;return 1;
}
/* Additive UI route; ordinary choose(PAIRED) keeps its default-latest contract. */
static inline int mng_selection_choose_revision(struct mng_preparation_selection *s,uint64_t epoch) {
    if(!mng_selection_choose(s,epoch,MNG_SELECT_PAIRED))return 0;
    s->stage=MNG_SELECT_REVISION;return 1;
}
/* Decimal metadata revision, not a semantic game version or capability claim. */
static inline int mng_selection_revision_decimal(const char *text,uint32_t *out) {
    if(!text||!out)return 0;
    uint32_t value=0;unsigned count=0;
    while(*text) {
        unsigned char ch=(unsigned char)*text++;
        if(++count>10||ch<'0'||ch>'9')return 0;
        uint32_t digit=(uint32_t)(ch-'0');
        if(value>(UINT32_MAX-digit)/10)return 0;
        value=value*10+digit;
    }
    if(!count)return 0;
    *out=value;return 1;
}
static inline int mng_selection_revision(struct mng_preparation_selection *s,uint64_t epoch,int latest,uint32_t target) {
    if(!mng_selection_is(s,epoch,MNG_SELECT_REVISION)||(latest!=0&&latest!=1)||(latest&&target))return 0;
    s->latest_update=latest;s->target_version=target;s->stage=MNG_SELECT_SOURCE;return 1;
}
static inline int mng_selection_bind(struct mng_preparation_selection *s,uint64_t epoch,uintptr_t picker) {
    if (!epoch||s->epoch!=epoch||!picker||s->picker ||
        (s->stage!=MNG_SELECT_SOURCE&&s->stage!=MNG_SELECT_UPDATE&&s->stage!=MNG_SELECT_KEYS)) return 0;
    s->picker=picker;return 1;
}
static inline int mng_selection_owns(const struct mng_preparation_selection *s,uintptr_t picker) {
    return picker && s->picker==picker && (s->stage==MNG_SELECT_SOURCE||s->stage==MNG_SELECT_UPDATE||s->stage==MNG_SELECT_KEYS);
}
static inline int mng_selection_picked(struct mng_preparation_selection *s,uintptr_t picker) {
    if (!mng_selection_owns(s,picker)) return 0;
    if(s->stage==MNG_SELECT_SOURCE)
        s->stage=s->mode==MNG_SELECT_PAIRED?MNG_SELECT_UPDATE:s->mode==MNG_SELECT_ASSET_FOLDER?MNG_SELECT_READY:MNG_SELECT_KEY_PROMPT;
    else s->stage=s->stage==MNG_SELECT_UPDATE?MNG_SELECT_KEY_PROMPT:MNG_SELECT_READY;
    s->picker=0;return 1;
}
/* Consume the explanatory alert before dismissal/picker presentation, so its
 * duplicate or delayed Cancel/Choose actions cannot affect the newer picker. */
static inline int mng_selection_request_keys(struct mng_preparation_selection *s,uint64_t epoch) {
    if(!mng_selection_is(s,epoch,MNG_SELECT_KEY_PROMPT))return 0;
    s->stage=MNG_SELECT_KEYS;return 1;
}
/* Successful consume invalidates every delayed action from this flow. */
static inline int mng_selection_take_request(struct mng_preparation_selection *s,uint64_t epoch,
    uintptr_t origin,struct mng_preparation_request *out) {
    if(!out||!mng_selection_is(s,epoch,MNG_SELECT_READY)||s->origin!=origin)return 0;
    if(origin && (s->mode!=MNG_SELECT_PAIRED||!mng_selection_hex_valid(s->reuse_title,16)||
        !mng_selection_hex_valid(s->reuse_generation,64)))return 0;
    if(!origin && (s->reuse_title[0]||s->reuse_generation[0]))return 0;
    if((s->latest_update!=0&&s->latest_update!=1)||(s->latest_update&&s->target_version)||
        (s->mode!=MNG_SELECT_PAIRED&&(!s->latest_update||s->target_version)))return 0;
    struct mng_preparation_request request;memset(&request,0,sizeof(request));request.mode=s->mode;
    request.latest_update=s->latest_update;request.target_version=s->target_version;
    memcpy(request.job,s->job,sizeof(request.job));memcpy(request.reuse_title,s->reuse_title,sizeof(request.reuse_title));
    memcpy(request.reuse_generation,s->reuse_generation,sizeof(request.reuse_generation));
    *out=request;mng_selection_cancel(s);return 1;
}
static inline int mng_selection_take(struct mng_preparation_selection *s,uint64_t epoch,char job[33],unsigned *mode) {
    if(!job||!mode||s->origin)return 0;
    struct mng_preparation_request request;if(!mng_selection_take_request(s,epoch,0,&request))return 0;
    memcpy(job,request.job,33);*mode=request.mode;return 1;
}
#endif
