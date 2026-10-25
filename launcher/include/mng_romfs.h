#ifndef MNG_ROMFS_H
#define MNG_ROMFS_H
#include <stddef.h>
#include <stdint.h>

/* A verified private plaintext RomFS descriptor is a caller precondition. This
 * parser validates filesystem structure, not the NCA hash chain or authorship.
 * Caller owns descriptors and isolated unpublished staging; discard staging on
 * every non-OK result. No callbacks may mutate the source or reenter the API. */
enum mng_romfs_status {
    MNG_ROMFS_OK, MNG_ROMFS_INVALID, MNG_ROMFS_IO, MNG_ROMFS_UNSUPPORTED,
    MNG_ROMFS_CANCELLED, MNG_ROMFS_LIMIT, MNG_ROMFS_NOMEM
};
struct mng_romfs_callbacks {
    void *context;
    /* Optional file index callback. Offsets are absolute in romfs.bin. */
    int (*entry)(void *context, const char *path, uint64_t offset, uint64_t size);
    int (*cancelled)(void *context);
    void (*progress)(void *context, uint64_t bytes_done, uint64_t bytes_total);
    /* ASCII names use built-in lowercase alias keys. Non-ASCII names require
     * this trusted host callback to return a NUL-terminated NFC+Unicode-casefold
     * canonical component. It must preserve equivalence across normalized/case
     * aliases. Missing callback refuses non-ASCII with UNSUPPORTED. All names
     * must be valid UTF-8; output component bytes remain the original UTF-8. */
    int (*canonical_name)(void *context, const char *utf8, char *canonical, size_t capacity);
    /* Optional directory index, including empty directories, excluding root.
     * Invoked after complete metadata validation. Extraction invokes it after
     * creating each directory; callback failure leaves unpublished staging. */
    int (*directory)(void *context, const char *path);
};
/* directories counts materialized subdirectories, excluding the output root. */
struct mng_romfs_result { uint64_t files, directories, bytes; };
/* Index only: bounded metadata allocations and no image/payload copy. Limits:
 * metadata32MiB, stored path bytes32MiB, path4095/name1024 bytes, depth64,
 * directories16384/files65536, total materialized bytes64GiB. Source must be
 * a regular, single-link file and stay stat-stable for the operation. */
enum mng_romfs_status mng_romfs_index_fd(int image_fd,
    const struct mng_romfs_callbacks *, struct mng_romfs_result *);
/* Materialize all indexed files into a caller-owned empty directory descriptor.
 * Uses mkdirat/openat, O_NOFOLLOW and exclusive new regular files, mode0700/0600.
 * Does not publish, rename, remove, sign or execute anything. */
enum mng_romfs_status mng_romfs_extract_fd(int image_fd, int empty_directory_fd,
    const struct mng_romfs_callbacks *, struct mng_romfs_result *);
const char *mng_romfs_status_name(enum mng_romfs_status);
#endif
