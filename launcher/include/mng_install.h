#ifndef MNG_INSTALL_H
#define MNG_INSTALL_H
#include "mng_addon.h"
#include "mng_romfs_runtime.h"
struct mng_install_control {
    void *context;
    /* Normal worker context, nonreentrant; never mutate inputs/store. */
    int (*cancelled)(void *);
    void (*progress)(void *,const char *phase,uint64_t done,uint64_t total);
    /* NFC+casefold component canonicalizer, required for non-ASCII RomFS. */
    int (*canonical_name)(void *,const char *,char *,size_t);
};
struct mng_install_report {
    char job_id[33],generation_id[65],current_generation_id[65];
    uint32_t verified_base_version;
    int commit_attempted,publication_uncertain,reload_required,current_readable;
    struct mng_addon_result addon;
    struct mng_romfs_runtime_result index;
};
/* Synchronous real installer, no extra publication authority. Under the existing
 * native store lock, verifies EXACT base generation + derives its version, then
 * invokes actual full-install DLC preparation, indexes its staged RomFS and
 * streams index through the same store sink before existing V5 commit.
 * Base must be identified full base/composed update (not folder/add-on/legacy).
 * Optional job is exact lowercase32hex; NULL creates a random ID for resumption.
 * Root/source/key provider stay caller-owned, positions preserved. Keys remain
 * transient; no source paths or key values are returned/stored. Isolated jobs
 * remain on failure/cancel and must never be treated as published assets.
 * Report is cleared/furnished on every return. Success fills generation_id;
 * commit IO sets publication_uncertain/reload_required and rereads current on
 * the same locked handle. Such failure must NOT be interpreted as rollback.
 * Never changes base selection, saves/accounts/identity or opens source paths. */
enum mng_prepare_status mng_install_addon_fd(int root_fd,int source_fd,
    const struct mng_key_provider *,uint64_t application_id,const char *base_generation_id,
    uint64_t addon_title_id,const char *optional_job_id,const struct mng_install_control *,
    struct mng_install_report *);
#endif
