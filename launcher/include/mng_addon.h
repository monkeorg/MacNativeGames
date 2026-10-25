#ifndef MNG_ADDON_H
#define MNG_ADDON_H
#include "mng_prepare.h"
#include "mng_content.h"
#define MNG_ADDON_MAX_VOLUMES 64u
/* Verified native base-generation facts; no imported JSON grants authority.
 * Initial full-install subset has no external meta dependencies/data patches. */
struct mng_addon_base { uint64_t application_id; uint32_t version; int version_verified; };
struct mng_addon_result {
    uint64_t application_id, title_id, source_size, romfs_size;
    uint32_t version, required_application_version;
    unsigned char source_sha256[32], cnmt_sha256[32], romfs_sha256[32];
    int romfs_verified; /* All NCA IVFC levels; not signature authenticity. */
};
/* Root-owned prepare bridge: exact owner/add-on ID, highest declared revision,
 * all content hashes/roles/raw owners bound; emit only romfs.bin into staging.
 * Result must be field-wise empty; unchanged on failure. */
enum mng_prepare_status mng_prepare_addon_fd(int source_fd,
    const struct mng_key_provider *, const struct mng_asset_sink *,
    const struct mng_addon_base *, uint64_t addon_title_id, struct mng_addon_result *);
struct mng_addon_plan { size_t count, metadata_indices[MNG_ADDON_MAX_VOLUMES]; };
/* Metadata must be parsed/hash-chain verified; candidate hashes and raw NCA
 * ownership must come from actual preparation. No external dependencies in
 * this subset. Every revision is bound; highest missing/corrupt never falls back.
 * Output unchanged on failure. At most256 metadata/16384 candidates/64 titles. */
enum mng_prepare_status mng_addon_plan(const struct mng_content *const *, size_t,
    const struct mng_content_candidate *, size_t, const struct mng_addon_base *, struct mng_addon_plan *);
/* Binding comes from compiled/reviewed host policy, never title-ID arithmetic
 * or a user report. This does not activate any game's nn::aoc service. */
struct mng_addon_binding { uint64_t application_id, addon_title_id; uint32_t mount_index; };
struct mng_addon_volume;
struct mng_addon_callbacks { void *context; int (*cancelled)(void *); };
/* Caller supplies verified V5 receipt facts and existing-store generation pin.
 * Duplicates all three descriptors (regular, private single-link owned files).
 * Pin must already hold the authentic generation lease; duplicate retains it.
 * Images <=64GiB; TOTKRFS1 index <=34MiB/65536 files, UTF8 paths <=4095/depth64, no file/directory ancestor collisions.
 * Canonical empty index is exactly24 bytes/count0/strings24.
 * Hashes and every index range/order/path checked before success; never copies
 * an image, changes file positions, writes, mounts host paths or infers gameplay.
 * Callbacks must not mutate/reenter. API calls serialized internally; destroy
 * requires all callers joined. On failure *out remains NULL. */
enum mng_prepare_status mng_addon_mount(int image_fd, int index_fd, int generation_pin_fd,
    const struct mng_addon_binding *, const struct mng_addon_base *, const struct mng_addon_result *,
    uint64_t index_size, const unsigned char index_sha256[32],
    const struct mng_addon_callbacks *, struct mng_addon_volume **out);
void mng_addon_unmount(struct mng_addon_volume *);
/* Relative UTF8 path only; no leading/trailing '/', '.', '..', backslash, colon,
 * controls or empty components. Exact-byte lookup, no case/Unicode guessing.
 * Handles are monotonic per-volume, never reused; 256 simultaneous opens. */
enum mng_prepare_status mng_addon_open(struct mng_addon_volume *, const char *, uint64_t *handle);
enum mng_prepare_status mng_addon_size(struct mng_addon_volume *, uint64_t handle, uint64_t *size);
/* Read clamps to EOF; offset beyond EOF refuses. *read_size zero on failure.
 * Failure may leave partial output, which caller must discard. */
enum mng_prepare_status mng_addon_read(struct mng_addon_volume *, uint64_t handle,
    uint64_t offset, void *bytes, size_t capacity, size_t *read_size);
enum mng_prepare_status mng_addon_close(struct mng_addon_volume *, uint64_t handle);
#endif
