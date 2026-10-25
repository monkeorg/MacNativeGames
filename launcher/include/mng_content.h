#ifndef MNG_CONTENT_H
#define MNG_CONTENT_H
#include <stddef.h>
#include <stdint.h>
/* Pure packaged-CNMT parsing and identity planning. Caller supplies decrypted,
 * hash-chain-verified metadata and independently hashed NCA candidates. This
 * checks self-digests/relationships, not signatures, authorship or gameplay. */
enum mng_content_status {
    MNG_CONTENT_OK, MNG_CONTENT_INVALID, MNG_CONTENT_UNSUPPORTED,
    MNG_CONTENT_LIMIT, MNG_CONTENT_NOMEM, MNG_CONTENT_INTEGRITY,
    MNG_CONTENT_MISSING, MNG_CONTENT_MISMATCH, MNG_CONTENT_DEPENDENCY
};
enum mng_content_type { MNG_CONTENT_APPLICATION=0x80, MNG_CONTENT_PATCH=0x81,
    MNG_CONTENT_ADDON=0x82 };
struct mng_content_record {
    unsigned char sha256[32], id[16];
    uint64_t size;
    unsigned char role, id_offset;
};
struct mng_content_dependency { uint64_t title_id; uint32_t version; unsigned char type, attributes; };
struct mng_content {
    uint64_t title_id, application_id, patch_id;
    uint32_t version, required_system_version, required_application_version;
    uint32_t required_download_system_version;
    unsigned char type, attributes, storage_id;
    size_t content_count, dependency_count;
    struct mng_content_record *contents;
    struct mng_content_dependency *dependencies;
};
/* member_name must be Application/Patch/AddOnContent_<16hex>.cnmt and agree
 * with the parsed type/title. Name never supplies identity. Exact length and
 * trailing SHA256 are checked. Limits1MiB/4096content/256dependencies.
 * Delta/DeltaFragment, non-NX/full-install, content attributes and AddOn data
 * patches are explicitly unsupported. Patch extended-data bytes are bounded
 * opaque metadata, not a claim that delta/BKTR composition is implemented. */
enum mng_content_status mng_content_parse(const char *member_name,
    const void *bytes, size_t length, struct mng_content **out);
void mng_content_free(struct mng_content *content);
/* Observed from real NCA bytes, never a filename. id must equal SHA256[:16].
 * nca_type is the raw decrypted NCA type (0Program,1Meta,2Control,3Manual,
 * 4Data,5PublicData), mapped separately to the CNMT record's role. */
struct mng_content_candidate {
    unsigned char id[16], sha256[32];
    uint64_t size;
    unsigned char nca_type;
};
/* Bind every declared record, including metadata not selected for installation.
 * Candidate validation/limits are the same as plan. Metadata must be parsed. */
enum mng_content_status mng_content_bind(const struct mng_content *,
    const struct mng_content_candidate *, size_t candidate_count);
#define MNG_CONTENT_MAX_DLC 64u
struct mng_content_plan {
    uint64_t application_id;
    size_t base_index, patch_index; /* patch_index=SIZE_MAX when absent */
    uint32_t version;
    size_t dlc_count, dlc_indices[MNG_CONTENT_MAX_DLC];
};
/* Metadata objects must be successful parse results. Select the highest base
 * and matching patch <=max_supported_version; 0 is a literal version cap.
 * A selected highest version with missing/bad content does not fall back.
 * All supplied metadata must belong to the requested application; duplicate
 * title/version/type tuples and ambiguous content candidates are refused.
 * Each DLC's highest version is selected independently, then application/meta
 * dependencies and every selected content hash/size/raw role are checked.
 * Catalog<=256/candidates<=16384. Output is unchanged on failure. One sorted
 * candidate index is shared by all selected metadata: O(n log n) construction,
 * O(log n) full16-byte ID lookups; no hash-prefix-only identity decisions. */
enum mng_content_status mng_content_plan(const struct mng_content *const *metadata,
    size_t count, const struct mng_content_candidate *candidates, size_t candidate_count,
    uint64_t application_id, uint32_t max_supported_version, struct mng_content_plan *out);
const char *mng_content_status_name(enum mng_content_status status);
#endif
