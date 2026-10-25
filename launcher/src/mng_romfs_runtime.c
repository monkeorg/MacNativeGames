#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include "mng_romfs_runtime.h"
#include "mng_crypto.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_FILES 65536u
#define MAX_NAMES (32u * 1024u * 1024u)
struct runtime_entry { char *path; uint64_t offset, size; };
struct runtime_index {
    struct runtime_entry *entries;
    size_t count, names;
    struct mng_romfs_callbacks host;
    enum mng_romfs_status failure;
};
static int stopped(struct runtime_index *index) {
    return index->host.cancelled && index->host.cancelled(index->host.context);
}
static int collect(void *opaque, const char *path, uint64_t offset, uint64_t size) {
    struct runtime_index *index = opaque;
    size_t length = strlen(path) + 1;
    if (index->count == MAX_FILES || length > MAX_NAMES - index->names) {
        index->failure = MNG_ROMFS_LIMIT; return -1;
    }
    char *copy = malloc(length);
    if (!copy) { index->failure = MNG_ROMFS_NOMEM; return -1; }
    memcpy(copy, path, length);
    index->entries[index->count++] = (struct runtime_entry){copy, offset, size};
    index->names += length;
    return index->host.entry ? index->host.entry(index->host.context, path, offset, size) : 0;
}
static int cancelled(void *opaque) { return stopped(opaque); }
static void progress(void *opaque, uint64_t done, uint64_t total) {
    struct runtime_index *index = opaque;
    if (index->host.progress) index->host.progress(index->host.context, done, total);
}
static int canonical(void *opaque, const char *path, char *out, size_t capacity) {
    struct runtime_index *index = opaque;
    return index->host.canonical_name(index->host.context, path, out, capacity);
}
static int directory(void *opaque, const char *path) {
    struct runtime_index *index = opaque;
    return index->host.directory ? index->host.directory(index->host.context, path) : 0;
}
static int compare(const void *a, const void *b) {
    return strcmp(((const struct runtime_entry *)a)->path, ((const struct runtime_entry *)b)->path);
}
static int same_image(const struct stat *a, const struct stat *b) {
    if (a->st_dev != b->st_dev || a->st_ino != b->st_ino || a->st_size != b->st_size ||
        a->st_mode != b->st_mode || a->st_nlink != b->st_nlink) return 0;
#ifdef __APPLE__
    return a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec == b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec == b->st_ctimespec.tv_nsec;
#else
    return a->st_mtim.tv_sec == b->st_mtim.tv_sec && a->st_mtim.tv_nsec == b->st_mtim.tv_nsec &&
        a->st_ctim.tv_sec == b->st_ctim.tv_sec && a->st_ctim.tv_nsec == b->st_ctim.tv_nsec;
#endif
}
static void put64(unsigned char *out, uint64_t value) {
    for (unsigned i = 0; i < 8; ++i) out[i] = (unsigned char)(value >> (8*i));
}
static void put32(unsigned char *out, uint32_t value) {
    for (unsigned i = 0; i < 4; ++i) out[i] = (unsigned char)(value >> (8*i));
}
static enum mng_romfs_status emit(int fd, struct runtime_index *index,
    struct mng_sha256 *hash, uint64_t *offset, const void *bytes, size_t count) {
    const unsigned char *input = bytes;
    size_t used = 0;
    while (used < count) {
        if (stopped(index)) return MNG_ROMFS_CANCELLED;
        ssize_t written = pwrite(fd, input + used, count - used, (off_t)(*offset + used));
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return MNG_ROMFS_IO;
        used += (size_t)written;
    }
    if (mng_sha256_update(hash, bytes, count)) return MNG_ROMFS_IO;
    *offset += count;
    return MNG_ROMFS_OK;
}
enum mng_romfs_status mng_romfs_runtime_index_fd_ex(int image_fd, int output_fd,
    const struct mng_romfs_callbacks *callbacks, unsigned flags, struct mng_romfs_runtime_result *out) {
    struct stat before, after, image_before, image_after;
    static const unsigned char zero[32];
    if ((flags & ~MNG_ROMFS_RUNTIME_ALLOW_EMPTY) || !out || out->file_count || out->index_size || memcmp(out->index_sha256, zero, 32) ||
        fstat(output_fd, &before) || !S_ISREG(before.st_mode) || before.st_size ||
        before.st_uid != geteuid() || before.st_nlink != 1 || (before.st_mode & 077)) return MNG_ROMFS_INVALID;
    if (fstat(image_fd, &image_before)) return MNG_ROMFS_IO;
    struct runtime_index index = {0};
    if (callbacks) index.host = *callbacks;
    index.entries = calloc(MAX_FILES, sizeof(*index.entries));
    if (!index.entries) return MNG_ROMFS_NOMEM;
    struct mng_romfs_callbacks bridge = {&index, collect, cancelled, progress,
        index.host.canonical_name ? canonical : NULL, directory};
    struct mng_romfs_result indexed = {0};
    enum mng_romfs_status status = mng_romfs_index_fd(image_fd, &bridge, &indexed);
    if (index.failure) status = index.failure;
    struct mng_sha256 *hash = NULL;
    uint64_t at = 0;
    if (status) goto done;
    if (!index.count && !(flags & MNG_ROMFS_RUNTIME_ALLOW_EMPTY)) { status = MNG_ROMFS_INVALID; goto done; }
    if (stopped(&index)) { status = MNG_ROMFS_CANCELLED; goto done; }
    qsort(index.entries, index.count, sizeof(*index.entries), compare);
    if (mng_sha256_init(&hash)) { status = MNG_ROMFS_NOMEM; goto done; }
    unsigned char row[24] = {0};
    memcpy(row, "TOTKRFS1", 8); put64(row+8, index.count); put64(row+16, 24 + index.count*24);
    status = emit(output_fd, &index, hash, &at, row, sizeof(row));
    uint32_t name = 0;
    for (size_t i = 0; !status && i < index.count; ++i) {
        struct runtime_entry *entry = index.entries + i;
        size_t length = strlen(entry->path) + 1;
        put64(row, entry->offset); put64(row+8, entry->size);
        put32(row+16, name); put32(row+20, (uint32_t)length);
        status = emit(output_fd, &index, hash, &at, row, sizeof(row));
        name += (uint32_t)length;
    }
    for (size_t i = 0; !status && i < index.count; ++i)
        status = emit(output_fd, &index, hash, &at, index.entries[i].path, strlen(index.entries[i].path)+1);
    unsigned char digest[32];
    if (!status && mng_sha256_final(hash, digest)) status = MNG_ROMFS_IO;
    if (!status && (fsync(output_fd) || fstat(output_fd, &after) ||
        before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
        before.st_mode != after.st_mode || after.st_nlink != 1 || (uint64_t)after.st_size != at)) status = MNG_ROMFS_IO;
    if (!status && (fstat(image_fd, &image_after) || !same_image(&image_before, &image_after))) status = MNG_ROMFS_IO;
    if (!status && stopped(&index)) status = MNG_ROMFS_CANCELLED;
    if (!status) { out->file_count = index.count; out->index_size = at; memcpy(out->index_sha256, digest, 32); }
done:
    mng_sha256_free(hash);
    for (size_t i = 0; i < index.count; ++i) free(index.entries[i].path);
    free(index.entries);
    return status;
}

enum mng_romfs_status mng_romfs_runtime_index_fd(int image_fd, int output_fd,
    const struct mng_romfs_callbacks *callbacks, struct mng_romfs_runtime_result *out) {
    return mng_romfs_runtime_index_fd_ex(image_fd,output_fd,callbacks,0,out);
}
