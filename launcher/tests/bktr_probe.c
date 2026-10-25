#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "mng_bktr.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
/* Synthetic test source adapters only. No product key/filesystem ownership. */
struct inputs;
struct source { struct inputs *inputs;int fd;struct stat before; };
struct inputs { struct source base,patch;const char *mode;unsigned reads,progress;int opened,changed,cancel; };
static int stable(struct source *s) {
    struct stat now;if (fstat(s->fd,&now)) return 0;
#ifdef __APPLE__
    return now.st_size==s->before.st_size && now.st_ino==s->before.st_ino && now.st_dev==s->before.st_dev &&
        now.st_mtimespec.tv_sec==s->before.st_mtimespec.tv_sec && now.st_mtimespec.tv_nsec==s->before.st_mtimespec.tv_nsec &&
        now.st_ctimespec.tv_sec==s->before.st_ctimespec.tv_sec && now.st_ctimespec.tv_nsec==s->before.st_ctimespec.tv_nsec;
#else
    return now.st_size==s->before.st_size && now.st_ino==s->before.st_ino && now.st_dev==s->before.st_dev &&
        now.st_mtim.tv_sec==s->before.st_mtim.tv_sec && now.st_mtim.tv_nsec==s->before.st_mtim.tv_nsec &&
        now.st_ctim.tv_sec==s->before.st_ctim.tv_sec && now.st_ctim.tv_nsec==s->before.st_ctim.tv_nsec;
#endif
}
static int read_source(void *context,uint64_t offset,void *bytes,size_t length) {
    struct source *s=context;struct inputs *i=s->inputs;
    i->reads++;
    if (!strcmp(i->mode,"io") && i->opened) return -1;
    if (!strcmp(i->mode,"mutate") && i->opened && !i->changed) {
        unsigned char byte=0xa5;i->changed=1;
        if (pwrite(s->fd,&byte,1,0)!=1) return -1;
    }
    unsigned char *p=bytes;
    while (length) {
        size_t n=!strcmp(i->mode,"short") && length>3 ? 3:length;
        ssize_t got=pread(s->fd,p,n,(off_t)offset);
        if (got<0 && errno==EINTR) continue;
        if (got<=0) return -1;
        offset+=(uint64_t)got;p+=(size_t)got;length-=(size_t)got;
    }
    return 0;
}
static int cancelled(void *context) {
    struct inputs *i=context;
    return i->cancel || !strcmp(i->mode,"cancel-initial") ||
        (!strcmp(i->mode,"cancel-tables") && i->progress);
}
static int check_sources(void *context) {
    struct inputs *i=context;return !stable(&i->base) || !stable(&i->patch);
}
static void progress(void *context,const char *phase,uint64_t done,uint64_t total) {
    struct inputs *i=context;
    if (done>total) _exit(90);
    i->progress++;
    if (!strcmp(i->mode,"cancel-verify") && !strncmp(phase,"verify-bktr",11)) i->cancel=1;
}
int main(int argc,char **argv) {
    if (argc!=6) return 2;
    struct inputs i={0};i.mode=argv[5];i.base.inputs=i.patch.inputs=&i;
    i.base.fd=open(argv[1],O_RDWR|O_CLOEXEC|O_NOFOLLOW);
    i.patch.fd=open(argv[2],O_RDWR|O_CLOEXEC|O_NOFOLLOW);
    int fsfd=open(argv[3],O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    unsigned char fs[512];
    if (i.base.fd<0 || i.patch.fd<0 || fsfd<0 || fstat(i.base.fd,&i.base.before) || fstat(i.patch.fd,&i.patch.before) ||
        read(fsfd,fs,512)!=512 || lseek(i.base.fd,7,SEEK_SET)!=7 || lseek(i.patch.fd,9,SEEK_SET)!=9) return 3;
    close(fsfd);
    struct mng_bktr_config config={0};
    config.base=(struct mng_bktr_source){&i.base,(uint64_t)i.base.before.st_size,read_source};
    config.patch_nca=(struct mng_bktr_source){&i.patch,(uint64_t)i.patch.before.st_size,read_source};
    config.section_offset=0xc00;config.section_size=(uint64_t)i.patch.before.st_size-0xc00;config.fs_header=fs;
    for (unsigned n=0;n<16;n++) config.key[n]=(unsigned char)n;
    if (!strcmp(i.mode,"wrong-key")) config.key[0]^=1;
    struct mng_bktr_callbacks callbacks={&i,cancelled,check_sources,progress};
    struct mng_bktr *reader=NULL;
    enum mng_bktr_status status=mng_bktr_open(&config,&callbacks,&reader);
    uint64_t offset=0,size=0,virtual_size=mng_bktr_size(reader);
    int preverify=status==MNG_BKTR_OK ? mng_bktr_romfs_range(reader,&offset,&size):status;
    if (!status) {
        i.opened=1;
        if (!strcmp(i.mode,"bounds")) {
            unsigned char byte=0x5a;
            if (!mng_bktr_read_at(reader,virtual_size,&byte,1) || byte!=0x5a) return 4;
            status=mng_bktr_status(reader);
        } else {
            status=mng_bktr_verify_ivfc(reader);
            if (!status) status=mng_bktr_romfs_range(reader,&offset,&size);
            if (!status) {
                int output=open(argv[4],O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
                if (output<0) return 5;
                unsigned char buffer[65513];
                for (uint64_t at=0;at<virtual_size;) {
                    size_t n=virtual_size-at>sizeof(buffer) ? sizeof(buffer):(size_t)(virtual_size-at);
                    if (mng_bktr_read_at(reader,at,buffer,n)) { status=mng_bktr_status(reader);break; }
                    if (write(output,buffer,n)!=(ssize_t)n) return 6;
                    at+=n;
                }
                close(output);
            }
        }
    }
    int preserved=lseek(i.base.fd,0,SEEK_CUR)==7 && lseek(i.patch.fd,0,SEEK_CUR)==9;
    mng_bktr_close(reader);close(i.base.fd);close(i.patch.fd);
    printf("{\"status\":\"%s\",\"preverify\":%d,\"virtualSize\":%llu,\"romfsOffset\":%llu,\"romfsSize\":%llu,\"reads\":%u,\"progress\":%u,\"preserved\":%s}\n",
        mng_bktr_status_name(status),preverify,(unsigned long long)virtual_size,(unsigned long long)offset,
        (unsigned long long)size,i.reads,i.progress,preserved ? "true":"false");return 0;
}
