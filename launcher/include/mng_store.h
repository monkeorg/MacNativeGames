#ifndef MNG_STORE_H
#define MNG_STORE_H
#include "mng_prepare.h"

#define MNG_STORE_RECIPE "canopy-assets-v1"
#define MNG_STORE_RECIPE_V2 "canopy-assets-v2"
#define MNG_STORE_RECIPE_V3 "canopy-assets-v3"
#define MNG_STORE_RECIPE_V4 "canopy-assets-v4"
#define MNG_STORE_RECIPE_V5 "canopy-assets-v5"
#define MNG_STORE_MAX_ASSETS 128u
#define MNG_STORE_MAX_BYTES (UINT64_C(64) << 30)
struct mng_store;
#define MNG_STORE_MAX_JOB_INTENTS 128u
#define MNG_STORE_JOB_ADDON 1u
struct mng_store_job_intent {
    unsigned mode;
    uint64_t application_id,addon_title_id;
    char base_generation_id[65];
};
/* Closed, checksummed private resume routing metadata, never source/key paths or
 * publication authority. Absent metadata is legacy; unknown/corrupt metadata is
 * an error, never treated as absence. Requires an existing exact private job.
 * On failure both outputs remain unchanged; on absent success only present=0. */
enum mng_prepare_status mng_store_read_job_intent(struct mng_store *,const char *job_id,
    struct mng_store_job_intent *out,int *present);
/* Verify the exact identified base ONCE under this retained native store lock,
 * begin/resume the job, then persist/confirm its exact tuple before any asset
 * write. Existing tuple conflicts refuse. Ordinary begin may inspect a typed
 * job but its sink/commit refuses until this method confirms the intent.
 * verified_base is optional and unchanged on failure. Pending valid intents
 * protect the exact base generation from removal until commit/discard. */
enum mng_prepare_status mng_store_begin_addon(struct mng_store *,const char *job_id,
    uint64_t application_id,const char *base_generation_id,uint64_t addon_title_id,
    struct mng_prepare_result *verified_base);
struct mng_store_io_metrics {
    uint64_t streamed_bytes,written_bytes,cloned_logical_bytes,compared_equal_bytes,resumed_bytes;
    uint64_t cloned_assets,clone_fallback_assets;
};
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
/* Optional optimization, configured before begin. Fully verifies and pins the
 * exact immutable source generation; errors never select an unverified source.
 * (title0,generationNULL) clears it. Retained until clear/close. New commits must
 * have the same title and canonical application owner. Missing candidates must
 * be distinguished by callers from invalid existing candidates, never silently
 * treating an integrity failure as absence. Same-path assets may use platform
 * COW clone of their old size into NEW staging only, then resize that private
 * descriptor to the checked target size. Only the retained overlap is compared;
 * every appended byte (including zeros) streams normally. Resize failures are
 * terminal for the job, never a post-clone fallback. Unsupported clones stream normally;
 * all incoming bytes and final staged assets are still hashed and verified. */
/* Optional verified_source is furnished from the same complete verification
 * that holds the retained lease; unchanged on failure. Calls are serialized. */
enum mng_prepare_status mng_store_set_reuse_generation(struct mng_store *,uint64_t title_id,const char *generation_id,
    struct mng_prepare_result *verified_source);
/* Reset on begin; payload counters only, excluding metadata writes. Streamed
 * counts successful sink writes; written counts actual successful write/pwrite
 * bytes, including partial writes before failure. Cloned is logical snapshot
 * OLD snapshot length before resizing (and may exceed a smaller target);
 * compared_equal counts matching retained spans whose writes were skipped.
 * Zero extension earns no reuse credit. A verified clone is counted even if a
 * later resize/stream/commit fails. Counters never imply successful publication.
 * Resumed counts verified completed-job replay, not cross-generation reuse.
 * None measures physical allocation, saved disk space or successful publication. */
void mng_store_get_io_metrics(const struct mng_store *,struct mng_store_io_metrics *);
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
/* Facts from the same complete receipt/assets/generation/manifest verification
 * that acquires the genuine shared generation lease. Every call still rehashes
 * every asset; this is not a trust cache. Compare present identities with the
 * compiled host pins before use; no execution or compatibility is approved.
 * V5 add-ons have main.present0; zero-byte present assets remain distinguishable.
 * Both outputs are unchanged on failure and assigned only after lease success.
 * All calls retain the existing caller-serialized store-lock/lifetime contract. */
struct mng_store_asset_identity {
    uint64_t size;
    unsigned char sha256[32];
    int present;
};
struct mng_store_verified_assets {
    struct mng_prepare_result preparation;
    struct mng_store_asset_identity main,romfs;
};
enum mng_prepare_status mng_store_pin_verified_assets(struct mng_store *store,
    uint64_t title_id, const char *generation_id,
    struct mng_store_verified_assets *verified, int *lease_fd);
/* Returns a caller-owned shared lease descriptor; close it to unpin. Kernel
 * releases the lease on process exit. Keep it open for a private session. */
enum mng_prepare_status mng_store_pin(struct mng_store *store,
    uint64_t title_id, const char *generation_id, int *lease_fd);
/* Bounded removal only within jobs or one title's generations. Generation
 * removal refuses both current and previous. Symlinked trees are refused. */
enum mng_prepare_status mng_store_discard_job(struct mng_store *store, const char *job_id);
/* Recoverable removal under the existing store lock: a durable checksummed
 * intent binds directory/lease identities before exclusive retirement. Current,
 * previous and genuinely pinned generations remain protected. Open resumes at
 * most one recorded retirement; absent .retirement is not created for reads.
 * IO may mean retirement already began; retry/close-and-reopen to reconcile.
 * Missing-lease canonical directories and unknown/mismatched retired entries
 * are preserved, never inferred to be disposable. No receipt identity changes. */
enum mng_prepare_status mng_store_remove_generation(struct mng_store *store,
    uint64_t title_id, const char *generation_id);
#endif
