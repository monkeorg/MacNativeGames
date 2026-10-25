#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#include "mng_file.h"
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <sys/stat.h>
#include <unistd.h>

struct file_reader { int fd; uint64_t size; };
static int read_exact(void *context, uint64_t offset, void *bytes, size_t length) {
    struct file_reader *reader=context;
    if (offset>reader->size || length>reader->size-offset || offset>INT64_MAX) return -1;
    unsigned char *cursor=bytes;
    while (length) {
        size_t request=length>(size_t)SSIZE_MAX ? (size_t)SSIZE_MAX:length;
        ssize_t n=pread(reader->fd,cursor,request,(off_t)offset);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) return -1;
        cursor+=(size_t)n; offset+=(uint64_t)n; length-=(size_t)n;
    }
    return 0;
}
static int same_file(const struct stat *a, const struct stat *b) {
#ifdef __APPLE__
    const struct timespec am=a->st_mtimespec, bm=b->st_mtimespec;
    const struct timespec ac=a->st_ctimespec, bc=b->st_ctimespec;
#else
    const struct timespec am=a->st_mtim, bm=b->st_mtim;
    const struct timespec ac=a->st_ctim, bc=b->st_ctim;
#endif
    return S_ISREG(b->st_mode) && a->st_dev==b->st_dev && a->st_ino==b->st_ino &&
        a->st_size==b->st_size && am.tv_sec==bm.tv_sec && am.tv_nsec==bm.tv_nsec &&
        ac.tv_sec==bc.tv_sec && ac.tv_nsec==bc.tv_nsec;
}
enum mng_status mng_inspect_fd(int fd, struct mng_inventory *out) {
    if (!out || out->count || out->entries || out->names) return MNG_INVALID;
    struct stat before, after;
    if (fstat(fd,&before)) return MNG_IO;
    if (!S_ISREG(before.st_mode) || before.st_size<0) return MNG_INVALID;
    struct file_reader reader={fd,(uint64_t)before.st_size};
    enum mng_status status=mng_container_inspect(read_exact,&reader,reader.size,out);
    if (fstat(fd,&after) || !same_file(&before,&after)) {
        mng_inventory_free(out);
        return MNG_IO;
    }
    return status;
}
