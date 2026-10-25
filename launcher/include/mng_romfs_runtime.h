#ifndef MNG_ROMFS_RUNTIME_H
#define MNG_ROMFS_RUNTIME_H
#include "mng_romfs.h"
/* Produce the existing TOTKRFS1 runtime index from a verified plaintext image.
 * index_fd must be an empty, caller-owned private regular file. On failure it
 * may contain partial bytes and must remain unpublished. Neither fd is closed
 * or repositioned. Empty images are refused: the runtime requires at least one
 * file/string. This does not approve execution or change trusted hashes. */
struct mng_romfs_runtime_result {
    uint64_t file_count, index_size;
    unsigned char index_sha256[32];
};
enum mng_romfs_status mng_romfs_runtime_index_fd(int image_fd, int index_fd,
    const struct mng_romfs_callbacks *, struct mng_romfs_runtime_result *);
/* Explicit separate-volume option. Unknown flags refuse before any output.
 * ALLOW_EMPTY emits canonical TOTKRFS1 header(count0/strings24), but only after
 * actual complete RomFS validation. The legacy entrypoint always uses flags0. */
#define MNG_ROMFS_RUNTIME_ALLOW_EMPTY 1u
enum mng_romfs_status mng_romfs_runtime_index_fd_ex(int image_fd, int index_fd,
    const struct mng_romfs_callbacks *, unsigned flags, struct mng_romfs_runtime_result *);
#endif
