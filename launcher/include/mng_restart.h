#ifndef MNG_RESTART_H
#define MNG_RESTART_H
#include <stdint.h>
#define MNG_RESTART_ABI 1u
/* Confirmation/control plane only. A provider must bind a real original engine
 * target-selection request and its verified guest-thread context. This module
 * neither discovers that request nor grants a title restart capability. */
enum mng_restart_status { MNG_RESTART_OK, MNG_RESTART_INVALID, MNG_RESTART_BUSY,
    MNG_RESTART_STALE, MNG_RESTART_BAD_STATE, MNG_RESTART_LIMIT, MNG_RESTART_NOMEM };
enum mng_restart_phase { MNG_RESTART_IDLE, MNG_RESTART_FIRST_CONFIRMATION,
    MNG_RESTART_SECOND_CONFIRMATION, MNG_RESTART_SUBMITTED, MNG_RESTART_FINISHED };
enum mng_restart_outcome { MNG_RESTART_NO_OUTCOME, MNG_RESTART_TITLE_REACHED,
    MNG_RESTART_GAME_RELOADED, MNG_RESTART_FAILED };
struct mng_restart;
struct mng_restart_provider {
    uint32_t abi,size;
    void *context;
    /* Called once only after the second affirmative action, without the
     * controller lock held. Return0 when queued; nonzero means refused.
     * The real provider owns guest-thread dispatch and completion observation.
     * Submission alone NEVER means title/reload completion. */
    int (*submit)(void *context,struct mng_restart *,uint64_t ticket);
};
struct mng_restart_snapshot {uint32_t abi,size,phase,outcome;uint64_t ticket,submissions;};
struct mng_restart_prompt {
    uint32_t abi,size,affirmative_destructive;
    const char *title,*message,*cancel_label,*affirmative_label;
};
/* No absent/default/no-op provider is supplied. The caller retains the real
 * provider context for this controller's lifetime. No filesystem/save/account,
 * input/focus, graphics or whole-runtime teardown API is used here. */
enum mng_restart_status mng_restart_create(const struct mng_restart_provider *,struct mng_restart **);
enum mng_restart_status mng_restart_begin(struct mng_restart *,uint64_t *ticket);
enum mng_restart_status mng_restart_continue(struct mng_restart *,uint64_t ticket);
enum mng_restart_status mng_restart_cancel(struct mng_restart *,uint64_t ticket);
enum mng_restart_status mng_restart_confirm(struct mng_restart *,uint64_t ticket);
/* Trusted engine observer only: report an ACTUALLY observed requested Title or
 * reload transition (or failure), not a lifecycle callback or submitted request.
 * May be called synchronously by submit or from the provider's engine thread.
 * FAILED must mean the request is definitively inactive, not an observation
 * timeout while an old transition could still arrive. */
enum mng_restart_status mng_restart_finish(struct mng_restart *,uint64_t ticket,enum mng_restart_outcome);
enum mng_restart_status mng_restart_snapshot(struct mng_restart *,struct mng_restart_snapshot *);
enum mng_restart_status mng_restart_prompt(struct mng_restart *,struct mng_restart_prompt *);
/* Refuses in-flight submission. Caller must also quiesce provider callbacks
 * and all other controller callers before destroying the CONTROL object. This is not a guest stop prerequisite
 * for requesting an experimental restart and never destroys a game/runtime. */
enum mng_restart_status mng_restart_destroy(struct mng_restart *);
#endif
