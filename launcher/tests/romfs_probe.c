#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include "mng_romfs.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static const char *mode;
static int image_fd=-1;
static unsigned reads,stats,entries,progress_calls;
static unsigned directory_entries;
static uint64_t last_done;
static uint64_t data_boundary;
ssize_t romfs_probe_pread(int fd,void *out,size_t length,off_t at) {
    reads++;
    if (!strcmp(mode,"io") && reads==2) { errno=EIO;return -1; }
    if (!strcmp(mode,"eintr") && reads==1) { errno=EINTR;return -1; }
    if (!strcmp(mode,"short") && length>3) length=3;
    if (!strcmp(mode,"metadataonly") && ((uint64_t)at>data_boundary || length>data_boundary-(uint64_t)at)) { errno=EIO;return -1; }
    if (!strcmp(mode,"mutate") && reads==1) {
        struct stat st;
        if (fstat(fd,&st) || ftruncate(fd,st.st_size+1)) return -1;
    }
    return pread(fd,out,length,at);
}
int romfs_probe_fstat(int fd,struct stat *st) {
    if (fstat(fd,st)) return -1;
    if (fd==image_fd && ++stats==2) {
        if (!strcmp(mode,"statio")) { errno=EIO;return -1; }
        if (!strcmp(mode,"statinode")) st->st_ino++;
        if (!strcmp(mode,"statsize")) st->st_size++;
        if (!strcmp(mode,"statdevice")) st->st_dev++;
#ifdef __APPLE__
        if (!strcmp(mode,"statmtime")) st->st_mtimespec.tv_nsec^=1;
        if (!strcmp(mode,"statctime")) st->st_ctimespec.tv_nsec^=1;
#else
        if (!strcmp(mode,"statmtime")) st->st_mtim.tv_nsec^=1;
        if (!strcmp(mode,"statctime")) st->st_ctim.tv_nsec^=1;
#endif
    }
    return 0;
}
static void string(const char *s) {
    putchar('"');
    for (;*s;s++) {
        unsigned char b=(unsigned char)*s;
        if (b=='"' || b=='\\') putchar('\\');
        if (b<32) printf("\\u%04x",b); else putchar(b);
    }
    putchar('"');
}
static int entry(void *context,const char *path,uint64_t offset,uint64_t size) {
    (void)context;
    if (entries++) putchar(',');
    printf("{\"path\":");string(path);
    printf(",\"offset\":%llu,\"size\":%llu}",(unsigned long long)offset,(unsigned long long)size);
    return !strcmp(mode,"callbackfail");
}
static int directory(void *context,const char *path) {
    (void)context;
    if (!path || !*path) _exit(91);
    directory_entries++;
    return !strcmp(mode,"directoryfail");
}
static int cancelled(void *context) {
    (void)context;
    return !strcmp(mode,"cancelinitial") ||
        (!strcmp(mode,"cancel") && (last_done || entries));
}
static void progress(void *context,uint64_t done,uint64_t total) {
    (void)context;
    if (done>total || done<last_done) _exit(90);
    last_done=done;progress_calls++;
}
/* Partial, invented-name canonicalizer is a test double for the documented
 * trusted host normalization hook, not a general Unicode implementation. */
static int canonical(void *context,const char *name,char *out,size_t capacity) {
    (void)context;
    const char *key=NULL;
    if (!strcmp(name,"\xc3\xa9.txt") || !strcmp(name,"e\xcc\x81.txt") || !strcmp(name,"\xc3\x89.txt")) key="accent.txt";
    if (!strcmp(name,"\xc3\xa9") || !strcmp(name,"e\xcc\x81")) key="accent";
    if (!key || strlen(key)>=capacity) return -1;
    strcpy(out,key);return 0;
}
int main(int argc,char **argv) {
    if (argc!=5) return 2;
    mode=argv[4];image_fd=open(argv[1],O_RDWR|O_CLOEXEC|O_NOFOLLOW);
    if (image_fd<0 || lseek(image_fd,7,SEEK_SET)!=7) return 3;
    unsigned char boundary[8];
    if (pread(image_fd,boundary,8,72)==8) for (unsigned i=0;i<8;i++) data_boundary|=(uint64_t)boundary[i]<<(i*8);
    struct mng_romfs_callbacks callbacks={NULL,entry,cancelled,progress,NULL,directory};
    if (!strcmp(mode,"unicode")) callbacks.canonical_name=canonical;
    struct mng_romfs_result result={0};
    printf("{\"entries\":[");
    enum mng_romfs_status status;
    int output=-1;
    if (!strcmp(argv[3],"extract")) {
        output=open(argv[2],O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
        if (output<0) return 4;
        status=mng_romfs_extract_fd(image_fd,output,&callbacks,&result);
    } else status=mng_romfs_index_fd(image_fd,&callbacks,&result);
    int preserved=lseek(image_fd,0,SEEK_CUR)==7;
    struct stat st;
    preserved=preserved && !fstat(image_fd,&st);
    close(image_fd);if (output>=0) close(output);
    printf("],\"status\":\"%s\",\"files\":%llu,\"directories\":%llu,\"bytes\":%llu,"
           "\"descriptor_preserved\":%s,\"progress_calls\":%u,\"directory_entries\":%u}\n",mng_romfs_status_name(status),
           (unsigned long long)result.files,(unsigned long long)result.directories,
           (unsigned long long)result.bytes,preserved ? "true":"false",progress_calls,directory_entries);
    return 0;
}
