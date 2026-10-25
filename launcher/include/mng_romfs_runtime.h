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
#endif
