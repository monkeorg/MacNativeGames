#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include "mng_romfs_runtime.h"
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

static const char *mode;
static const char *image_path;
static int stop;
static unsigned writes;
ssize_t index_probe_pwrite(int fd, const void *bytes, size_t length, off_t offset) {
    if (!strcmp(mode,"write-error")) return -1;
    ssize_t result = pwrite(fd,bytes,length,offset);
    ++writes;
    if (!strcmp(mode,"cancel-write")) stop = 1;
    if (!strcmp(mode,"cancel-final") && writes == 5) stop = 1;
    if (!strcmp(mode,"mutate-image") && writes == 1) {
        int image = open(image_path,O_WRONLY);
        if (image < 0 || pwrite(image,"X",1,0) != 1) _exit(92);
        close(image);
    }
    return result;
}
static int cancelled(void *context) { (void)context; return stop; }
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    mode = argv[3]; image_path = argv[1];
    unsigned flags = !strncmp(mode,"empty-",6) ? MNG_ROMFS_RUNTIME_ALLOW_EMPTY : !strcmp(mode,"badflags") ? 2u : 0u;
    int extended = flags || !strcmp(mode,"extended");
    if (flags == MNG_ROMFS_RUNTIME_ALLOW_EMPTY) mode += 6;
    stop = !strcmp(mode,"cancel");
    int image = open(argv[1],O_RDONLY | O_NOFOLLOW);
    int output = open(argv[2],O_RDWR | O_CREAT | O_NOFOLLOW,0600);
    if (image < 0 || output < 0) return 3;
    if (lseek(image,3,SEEK_SET) != 3 || lseek(output,7,SEEK_SET) != 7) return 4;
    struct mng_romfs_callbacks callbacks = {0}; callbacks.cancelled = cancelled;
    struct mng_romfs_runtime_result result = {0};
    enum mng_romfs_status status = extended ? mng_romfs_runtime_index_fd_ex(image,output,&callbacks,flags,&result) :
        mng_romfs_runtime_index_fd(image,output,&callbacks,&result);
    int preserved = lseek(image,0,SEEK_CUR) == 3 && lseek(output,0,SEEK_CUR) == 7;
    close(image); close(output);
    printf("{\"status\":\"%s\",\"files\":%llu,\"size\":%llu,\"sha256\":\"",
        mng_romfs_status_name(status),(unsigned long long)result.file_count,(unsigned long long)result.index_size);
    for (size_t i=0;i<32;i++) printf("%02x",result.index_sha256[i]);
    printf("\",\"positionsPreserved\":%s}\n",preserved ? "true":"false");
    return 0;
}
