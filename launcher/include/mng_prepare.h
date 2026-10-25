#ifndef MNG_PREPARE_H
#define MNG_PREPARE_H
#include <stddef.h>
#include <stdint.h>
/* Native private preparation. No key material or private input paths are
 * serialized. The caller owns descriptors, keys, staging and rollback. */
enum mng_prepare_status {
    MNG_PREPARE_OK, MNG_PREPARE_INVALID, MNG_PREPARE_IO,
    MNG_PREPARE_UNSUPPORTED, MNG_PREPARE_KEY, MNG_PREPARE_INTEGRITY,
    MNG_PREPARE_CANCELLED, MNG_PREPARE_LIMIT, MNG_PREPARE_NOMEM
};
struct mng_key_provider {
    void *context;
    /* Supply exactly length bytes for the named key; zero on success. */
    int (*lookup)(void *context, const char *name, unsigned char *bytes, size_t length);
};
struct mng_asset_sink {
    void *context;
    /* One asset at a time; paths are relative, validated, controlled names.
     * Return nonzero to abort. Partial output remains unpublished staging. */
    int (*begin)(void *context, const char *path, uint64_t size);
    int (*write)(void *context, const void *bytes, size_t length);
    int (*end)(void *context, const unsigned char sha256[32]);
    int (*cancelled)(void *context);
    void (*progress)(void *context, const char *phase, uint64_t done, uint64_t total);
};
struct mng_prepare_result {
    uint64_t title_id, source_size, asset_count, asset_bytes;
    unsigned char source_sha256[32];
    /* Signature authenticity is separate from section/hash-chain integrity. */
    int exefs_verified, romfs_verified;
    /* Verified CNMT identity when present; unknown is explicit, never a
     * filename-derived compatibility claim. Base preparation keeps base version. */
    uint64_t application_id;
    uint32_t title_version;
    int version_identified;
    unsigned char content_role; /* CNMT0x80 application;0 legacy-unidentified */
};
/* Native NCA3/key-area or common-ticket AES-CTR, checked ExeFS and IVFC.
 * No game compatibility/execution is inferred. Caller passes empty result. */
enum mng_prepare_status mng_prepare_fd(int source_fd,
    const struct mng_key_provider *keys, const struct mng_asset_sink *sink,
    struct mng_prepare_result *result);
const char *mng_prepare_status_name(enum mng_prepare_status status);
#endif
