#include "mng_restart.h"
#include <pthread.h>
#include <stdlib.h>
struct mng_restart {
    pthread_mutex_t lock;
    struct mng_restart_provider provider;
    uint64_t ticket,submissions;
    uint32_t phase,outcome,submitting;
};
enum mng_restart_status mng_restart_create(const struct mng_restart_provider *provider,struct mng_restart **out) {
    if(!provider || provider->abi!=MNG_RESTART_ABI || provider->size!=sizeof(*provider) || !provider->submit || !out || *out)return MNG_RESTART_INVALID;
    struct mng_restart *state=calloc(1,sizeof(*state));if(!state)return MNG_RESTART_NOMEM;
    if(pthread_mutex_init(&state->lock,NULL)){free(state);return MNG_RESTART_NOMEM;}
    state->provider=*provider;*out=state;return MNG_RESTART_OK;
}
enum mng_restart_status mng_restart_begin(struct mng_restart *state,uint64_t *ticket) {
    if(!state || !ticket)return MNG_RESTART_INVALID;
    pthread_mutex_lock(&state->lock);enum mng_restart_status status=MNG_RESTART_OK;
    if(state->submitting || (state->phase!=MNG_RESTART_IDLE && state->phase!=MNG_RESTART_FINISHED))status=MNG_RESTART_BUSY;
    else if(state->ticket==UINT64_MAX)status=MNG_RESTART_LIMIT;
    else {state->ticket++;state->phase=MNG_RESTART_FIRST_CONFIRMATION;state->outcome=MNG_RESTART_NO_OUTCOME;*ticket=state->ticket;}
    pthread_mutex_unlock(&state->lock);return status;
}
static enum mng_restart_status confirmation(struct mng_restart *state,uint64_t ticket,int cancel) {
    if(!state || !ticket)return MNG_RESTART_INVALID;
    pthread_mutex_lock(&state->lock);enum mng_restart_status status=MNG_RESTART_OK;
    if(ticket!=state->ticket)status=MNG_RESTART_STALE;
    else if(cancel && (state->phase==MNG_RESTART_FIRST_CONFIRMATION || state->phase==MNG_RESTART_SECOND_CONFIRMATION))state->phase=MNG_RESTART_IDLE;
    else if(!cancel && state->phase==MNG_RESTART_FIRST_CONFIRMATION)state->phase=MNG_RESTART_SECOND_CONFIRMATION;
    else status=MNG_RESTART_BAD_STATE;
    pthread_mutex_unlock(&state->lock);return status;
}
enum mng_restart_status mng_restart_continue(struct mng_restart *state,uint64_t ticket) {return confirmation(state,ticket,0);}
enum mng_restart_status mng_restart_cancel(struct mng_restart *state,uint64_t ticket) {return confirmation(state,ticket,1);}
enum mng_restart_status mng_restart_confirm(struct mng_restart *state,uint64_t ticket) {
    if(!state || !ticket)return MNG_RESTART_INVALID;
    pthread_mutex_lock(&state->lock);
    if(ticket!=state->ticket){pthread_mutex_unlock(&state->lock);return MNG_RESTART_STALE;}
    if(state->phase!=MNG_RESTART_SECOND_CONFIRMATION){pthread_mutex_unlock(&state->lock);return MNG_RESTART_BAD_STATE;}
    state->phase=MNG_RESTART_SUBMITTED;state->submitting=1;state->submissions++;
    pthread_mutex_unlock(&state->lock);
    int refused=state->provider.submit(state->provider.context,state,ticket);
    pthread_mutex_lock(&state->lock);
    /* A genuine synchronous completion wins over a contradictory refusal;
     * never relabel an actually observed transition as still pending. */
    state->submitting=0;
    if(refused && state->ticket==ticket && state->phase==MNG_RESTART_SUBMITTED){state->phase=MNG_RESTART_FINISHED;state->outcome=MNG_RESTART_FAILED;}
    pthread_mutex_unlock(&state->lock);return MNG_RESTART_OK;
}
enum mng_restart_status mng_restart_finish(struct mng_restart *state,uint64_t ticket,enum mng_restart_outcome outcome) {
    if(!state || !ticket || (outcome!=MNG_RESTART_TITLE_REACHED && outcome!=MNG_RESTART_GAME_RELOADED && outcome!=MNG_RESTART_FAILED))return MNG_RESTART_INVALID;
    pthread_mutex_lock(&state->lock);enum mng_restart_status status=MNG_RESTART_OK;
    if(ticket!=state->ticket)status=MNG_RESTART_STALE;
    else if(state->phase!=MNG_RESTART_SUBMITTED)status=MNG_RESTART_BAD_STATE;
    else {state->phase=MNG_RESTART_FINISHED;state->outcome=(uint32_t)outcome;}
    pthread_mutex_unlock(&state->lock);return status;
}
enum mng_restart_status mng_restart_snapshot(struct mng_restart *state,struct mng_restart_snapshot *out) {
    if(!state || !out || out->abi!=MNG_RESTART_ABI || out->size!=sizeof(*out))return MNG_RESTART_INVALID;
    pthread_mutex_lock(&state->lock);
    *out=(struct mng_restart_snapshot){MNG_RESTART_ABI,sizeof(*out),state->phase,state->outcome,state->ticket,state->submissions};
    pthread_mutex_unlock(&state->lock);return MNG_RESTART_OK;
}
enum mng_restart_status mng_restart_prompt(struct mng_restart *state,struct mng_restart_prompt *out) {
    if(!state || !out || out->abi!=MNG_RESTART_ABI || out->size!=sizeof(*out))return MNG_RESTART_INVALID;
    pthread_mutex_lock(&state->lock);uint32_t phase=state->phase;pthread_mutex_unlock(&state->lock);
    if(phase!=MNG_RESTART_FIRST_CONFIRMATION && phase!=MNG_RESTART_SECOND_CONFIRMATION)return MNG_RESTART_BAD_STATE;
    *out=(struct mng_restart_prompt){MNG_RESTART_ABI,sizeof(*out),1,"Restart game?",
        phase==MNG_RESTART_FIRST_CONFIRMATION?"Unsaved progress may be lost. Experimental restart can crash.":"Restart this game now?",
        "Cancel",phase==MNG_RESTART_FIRST_CONFIRMATION?"Continue":"Restart game"};return MNG_RESTART_OK;
}
enum mng_restart_status mng_restart_destroy(struct mng_restart *state) {
    if(!state)return MNG_RESTART_INVALID;
    pthread_mutex_lock(&state->lock);int busy=state->submitting || state->phase==MNG_RESTART_SUBMITTED;pthread_mutex_unlock(&state->lock);
    if(busy)return MNG_RESTART_BUSY;
    if(pthread_mutex_destroy(&state->lock))return MNG_RESTART_BUSY;
    free(state);return MNG_RESTART_OK;
}
