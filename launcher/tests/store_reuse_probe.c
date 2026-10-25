#define _GNU_SOURCE
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include "mng_store.h"
#include "mng_crypto.h"
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/ioctl.h>
int reuse_ioctl(int fd,unsigned long request,...) {
    va_list args;va_start(args,request);int source=va_arg(args,int);va_end(args);
    if(getenv("REUSE_FORCE_FALLBACK")){errno=EOPNOTSUPP;return -1;}return ioctl(fd,request,source);
}
#elif defined(__APPLE__)
#include <sys/clonefile.h>
int reuse_fclonefileat(int source,int dir,const char *name,uint32_t flags) {
    if(getenv("REUSE_FORCE_FALLBACK")){errno=ENOTSUP;return -1;}return fclonefileat(source,dir,name,flags);
}
#endif
static struct mng_store *cancel_store;
static uint64_t compared_reads;
static unsigned zero_extension_checked;
ssize_t reuse_pread(int fd,void *p,size_t n,off_t at) {
    if(getenv("REUSE_COMPARE_FAIL")){errno=EIO;return -1;}
    ssize_t result=pread(fd,p,n,at);if(result>0)compared_reads+=(uint64_t)result;return result;
}
int reuse_ftruncate(int fd,off_t length) {
    if(getenv("REUSE_TRUNCATE_FAIL")){errno=ENOSPC;return -1;}
    struct stat before;if(fstat(fd,&before))return -1;
    int result=ftruncate(fd,length);
    if(!result&&getenv("REUSE_CHECK_ZERO_EXTENSION")&&length>before.st_size) {
        unsigned char buffer[65536];off_t at=before.st_size;
        while(at<length) {
            size_t wanted=(uint64_t)(length-at)>sizeof(buffer)?sizeof(buffer):(size_t)(length-at);
            ssize_t got=pread(fd,buffer,wanted,at);if(got<=0){errno=EIO;return -1;}
            for(ssize_t i=0;i<got;i++)if(buffer[i]){errno=EIO;return -1;}
            at+=got;
        }
        zero_extension_checked++;
    }
    if(!result&&getenv("REUSE_CANCEL_TRUNCATE"))mng_store_cancel(cancel_store);
    if(!result&&getenv("REUSE_CRASH_TRUNCATE"))_exit(29);
    return result;
}
ssize_t reuse_pwrite(int fd,const void *p,size_t n,off_t at) {
    if(getenv("REUSE_WRITE_FAIL")){errno=ENOSPC;return -1;}
    if(getenv("REUSE_SHORT_WRITE")&&n>7)n=7;
    ssize_t result=pwrite(fd,p,n,at);
    if(result>0&&getenv("REUSE_CANCEL_WRITE"))mng_store_cancel(cancel_store);
    if(result>0&&getenv("REUSE_CRASH_WRITE"))_exit(27);
    return result;
}
int reuse_statvfs(int fd,struct statvfs *out) {int result=fstatvfs(fd,out);if(!result&&getenv("REUSE_LOW_SPACE"))out->f_bavail=0;return result;}
static int digest(const void *p,size_t n,unsigned char out[32]) {
    struct mng_sha256 *hash=NULL;int bad=mng_sha256_init(&hash)||mng_sha256_update(hash,p,n)||mng_sha256_final(hash,out);
    mng_sha256_free(hash);return bad;
}
static int asset(struct mng_asset_sink *sink,const char *path,const void *p,size_t n) {
    unsigned char hash[32];return digest(p,n,hash)||sink->begin(sink->context,path,n)||sink->write(sink->context,p,n)||sink->end(sink->context,hash);
}
int main(int argc,char **argv) {
    if(argc!=7)return 2;
    const char *mode=argv[1];int root=open(argv[2],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(root<0)return 3;
    struct mng_store *store=NULL;enum mng_prepare_status status=mng_store_open(root,&store);close(root);if(status)return 4;
    uint64_t title=strtoull(argv[5],NULL,16);char generation[65]={0};struct mng_prepare_result verified={0};verified.title_id=0x1234;
    if(strncmp(mode,"seed",4))status=mng_store_set_reuse_generation(store,title,argv[3],&verified);
    if(!status&&!strcmp(mode,"hold")) {
        puts("ready");fflush(stdout);(void)getchar();mng_store_close(store);return 0;
    }
    if(!status&&!strcmp(mode,"lease")) {
        enum mng_prepare_status held=mng_store_remove_generation(store,title,argv[3]);
        status=mng_store_set_reuse_generation(store,0,NULL,NULL);
        enum mng_prepare_status released=status?status:mng_store_remove_generation(store,title,argv[3]);
        printf("{\"held\":%u,\"released\":%u}\n",(unsigned)held,(unsigned)released);
        mng_store_close(store);return 0;
    }
    if(!status)status=mng_store_begin(store,argv[4]);
    if(!status&&!strcmp(mode,"configure-active"))status=mng_store_set_reuse_generation(store,title,argv[3],&verified);
    struct mng_prepare_result result={0};
    size_t length=3*65536+17;
    if(!strcmp(mode,"different-size")||!strcmp(mode,"grow")||!strcmp(mode,"grow-changed"))length++;
    if(!strcmp(mode,"grow-boundary")||!strcmp(mode,"grow-zero"))length+=65536+7;
    if(!strcmp(mode,"shrink"))length--;
    if(!strcmp(mode,"shrink-boundary"))length=65536-1;
    if(!strcmp(mode,"shrink-zero")||!strcmp(mode,"seed-empty"))length=0;
    unsigned char *image=malloc(length?length:1);if(!image)return 5;memset(image,'r',length);
    if(!strcmp(mode,"grow-zero"))memset(image+3*65536+17,0,65536+7);
    if(!strcmp(mode,"changed")||!strcmp(mode,"crash")||!strcmp(mode,"cancel")||!strcmp(mode,"grow-changed"))image[65536+5]='s';
    if(!status&&(!strcmp(mode,"limit")||!strcmp(mode,"exefs-limit"))) {
        struct mng_asset_sink sink=mng_store_sink(store);cancel_store=store;
        int refused=sink.begin(sink.context,!strcmp(mode,"limit")?"romfs.bin":"exefs/main",
            !strcmp(mode,"limit")?MNG_STORE_MAX_BYTES+1:(UINT64_C(512)<<20)+1);
        status=refused?MNG_PREPARE_INVALID:MNG_PREPARE_INTEGRITY;
    }
    if(!status){struct mng_asset_sink sink=mng_store_sink(store);cancel_store=store;
        if(asset(&sink,"exefs/main","original main fixture",21)||asset(&sink,"exefs/main.npdm","original npdm fixture",21)||asset(&sink,"romfs.bin",image,length))
            status=sink.cancelled(sink.context)?MNG_PREPARE_CANCELLED:MNG_PREPARE_IO;
        else {result.title_id=title;result.source_size=1000;result.asset_count=3;result.asset_bytes=42+length;
            result.exefs_verified=result.romfs_verified=1;
            if(digest(argv[6],strlen(argv[6]),result.source_sha256))return 6;
            if(!strcmp(mode,"cross-title"))result.title_id++;
            if(!strcmp(mode,"cancel-after-assets"))mng_store_cancel(store);
            status=mng_store_commit(store,&result,generation);
        }
    }
    struct mng_store_io_metrics metrics;mng_store_get_io_metrics(store,&metrics);
    printf("{\"status\":%u,\"generation\":\"%s\",\"streamed\":%" PRIu64 ",\"written\":%" PRIu64 ",\"cloned\":%" PRIu64
        ",\"equal\":%" PRIu64 ",\"resumed\":%" PRIu64 ",\"cloneAssets\":%" PRIu64 ",\"fallbackAssets\":%" PRIu64 ",\"verifiedTitle\":\"%016" PRIx64 "\",\"comparedReads\":%" PRIu64 ",\"zeroExtensionChecked\":%u}\n",
        (unsigned)status,generation,metrics.streamed_bytes,metrics.written_bytes,metrics.cloned_logical_bytes,
        metrics.compared_equal_bytes,metrics.resumed_bytes,metrics.cloned_assets,metrics.clone_fallback_assets,verified.title_id,compared_reads,zero_extension_checked);
    free(image);mng_store_close(store);return 0;
}
