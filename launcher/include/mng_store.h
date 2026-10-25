#ifndef MNG_STORE_H
#define MNG_STORE_H
#include "mng_prepare.h"

#define MNG_STORE_RECIPE "canopy-assets-v1"
#define MNG_STORE_RECIPE_V2 "canopy-assets-v2"
#define MNG_STORE_RECIPE_V3 "canopy-assets-v3"
#define MNG_STORE_RECIPE_V4 "canopy-assets-v4"
#define MNG_STORE_MAX_ASSETS 128u
#define MNG_STORE_MAX_BYTES (UINT64_C(64) << 30)
struct mng_store;
/* root_fd is a caller-owned directory, owned by the current effective uid,
 * with no group/other permission bits (0700 or stricter). No ownership is transferred.
 * Holds an exclusive, nonblocking store lock until close. All paths below the
 * root are accessed descriptor-relative without following links. Calls are
 * caller-serialized except cancel, which may run on another thread. */
enum mng_prepare_status mng_store_open(int root_fd, struct mng_store **out);
void mng_store_close(struct mng_store *store);
/* Register before begin. Polled only in normal API context, including resume
 * and verification hash chunks and immediately before current publication.
 * Must not reenter store APIs. Nonzero requests sticky cancellation; NULL
 * removes the callback but does not clear an already requested cancellation. */
void mng_store_set_cancel_check(struct mng_store *store,
    int (*check)(void *context), void *context);
/* Begin or resume one lowercase 32-hex job. Complete assets are revalidated;
 * incomplete writes are discarded. Replayed assets are hashed, not rewritten.
 * Cancellation is never reset by begin; reopen to resume a cancelled job. */
enum mng_prepare_status mng_store_begin(struct mng_store *store, const char *job_id);
struct mng_asset_sink mng_store_sink(struct mng_store *store);
void mng_store_cancel(struct mng_store *store);
/* Commits a verified immutable generation then atomically changes current.
 * A cancelled/failed preparation must never be committed. Original source,
 * keys, profiles, accounts and saves are never stored here. Cancellation is
 * checked during rehashing and immediately before publishing current; once
 * that atomic publication begins, later cancellation does not undo it.
 * An IO error after rename but during directory fsync can leave the new,
 * complete generation current; reconcile current on IO. Previous is retained. */
enum mng_prepare_status mng_store_commit(struct mng_store *store,
    const struct mng_prepare_result *result, char generation_id[65]);
enum mng_prepare_status mng_store_current(struct mng_store *store,
    uint64_t title_id, char generation_id[65]);
/* Legacy v1 receipts retain their original fingerprint. Their application_id
 * is inferred from title_id; version_identified stays0 (not a CNMT assertion).
 * Identified base metadata uses v2 receipts/recipe; composed updates use v3,
 * binding the exact base and update container identities independently. Older
 * receipts have every update field zero. No immutable receipt is migrated.
 * Rehash every asset, recompute generation ID and compare the canonical JSON
 * manifest. Does not infer signature authenticity, execution or compatibility. */
enum mng_prepare_status mng_store_verify(struct mng_store *store, uint64_t title_id,
    const char *generation_id, struct mng_prepare_result *result);
/* Select a previously verified generation (including rollback). The displaced
 * current is retained as previous. No generations are implicitly deleted. */
enum mng_prepare_status mng_store_select(struct mng_store *store,
    uint64_t title_id, const char *generation_id);
/* Returns a caller-owned shared lease descriptor; close it to unpin. Kernel
 * releases the lease on process exit. Keep it open for a private session. */
enum mng_prepare_status mng_store_pin(struct mng_store *store,
    uint64_t title_id, const char *generation_id, int *lease_fd);
/* Bounded removal only within jobs or one title's generations. Generation
 * removal refuses both current and previous. Symlinked trees are refused. */
enum mng_prepare_status mng_store_discard_job(struct mng_store *store, const char *job_id);
enum mng_prepare_status mng_store_remove_generation(struct mng_store *store,
    uint64_t title_id, const char *generation_id);
#endif
