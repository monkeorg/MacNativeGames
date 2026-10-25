#ifndef MNG_PREPARATION_SELECTION_H
#define MNG_PREPARATION_SELECTION_H
#include <stdint.h>
#include <string.h>

/* Main-thread picker ownership only. No URL, key, bookmark or source identity.
 * A requested job ID is a selection, never authority to resume different bytes.
 * The native preparation store verifies the selected inputs' fingerprint. */
enum mng_selection_stage { MNG_SELECT_IDLE, MNG_SELECT_SOURCE, MNG_SELECT_KEYS,
    MNG_SELECT_READY, MNG_SELECT_UPDATE, MNG_SELECT_MODE, MNG_SELECT_KEY_PROMPT };
enum mng_selection_mode { MNG_SELECT_BASE=1, MNG_SELECT_PAIRED,
    MNG_SELECT_NCA_FOLDER, MNG_SELECT_ASSET_FOLDER };
struct mng_preparation_selection {
    uint64_t epoch;
    uintptr_t picker;
    unsigned stage, mode;
    char job[33];
};
static inline int mng_selection_job_valid(const char *job) {
    if (!job) return 0;
    for (unsigned i=0;i<32;i++)
        if (!((job[i]>='0'&&job[i]<='9')||(job[i]>='a'&&job[i]<='f'))) return 0;
    return job[32]==0;
}
static inline void mng_selection_cancel(struct mng_preparation_selection *s) {
    if (s->epoch!=UINT64_MAX) s->epoch++;
    s->picker=0;s->stage=MNG_SELECT_IDLE;s->mode=0;memset(s->job,0,sizeof(s->job));
}
static inline int mng_selection_begin(struct mng_preparation_selection *s,const char *job) {
    if (s->stage!=MNG_SELECT_IDLE || s->epoch==UINT64_MAX || (job&&!mng_selection_job_valid(job))) return 0;
    s->epoch++;s->stage=MNG_SELECT_MODE;s->picker=0;s->mode=0;
    memset(s->job,0,sizeof(s->job));if(job)memcpy(s->job,job,32);return 1;
}
static inline int mng_selection_is(const struct mng_preparation_selection *s,uint64_t epoch,unsigned stage) {
    return epoch && s->epoch==epoch && s->stage==stage;
}
static inline int mng_selection_choose(struct mng_preparation_selection *s,uint64_t epoch,unsigned mode) {
    if (!mng_selection_is(s,epoch,MNG_SELECT_MODE)||mode<MNG_SELECT_BASE||mode>MNG_SELECT_ASSET_FOLDER) return 0;
    s->mode=mode;s->stage=MNG_SELECT_SOURCE;return 1;
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
static inline int mng_selection_take(struct mng_preparation_selection *s,uint64_t epoch,char job[33],unsigned *mode) {
    if(!job||!mode||!mng_selection_is(s,epoch,MNG_SELECT_READY))return 0;
    memcpy(job,s->job,33);*mode=s->mode;mng_selection_cancel(s);return 1;
}
#endif
