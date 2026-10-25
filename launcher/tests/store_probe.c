#define _GNU_SOURCE
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L
#include "mng_store.h"
#include "mng_crypto.h"
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/statvfs.h>
#include <unistd.h>
#include <errno.h>
#include <stdarg.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif

static struct mng_store *cancel_target;
static int cancel_requested;
static int cancel_check(void *context) { return *(int *)context; }
static int fail_next_sync;
static int fault(const char *name) {
    const char *selected=getenv("CANOPY_TEST_FAULT"); return selected && !strcmp(selected,name);
}
ssize_t probe_read(int fd,void *bytes,size_t count) {
    ssize_t result=read(fd,bytes,count);
    if (cancel_target && fault("cancel_hash")) mng_store_cancel(cancel_target);
    if (cancel_target && (fault("hook_hash") || (fault("hook_resume") && count==28))) cancel_requested=1;
    return result;
}
int probe_fsync(int fd) {
    if (fail_next_sync) { fail_next_sync=0; errno=EIO; return -1; }
    return fsync(fd);
}
int probe_renameat(int from,const char *source,int to,const char *destination) {
    if ((!strcmp(destination,"current") && fault("current_rename")) ||
        (!strcmp(destination,"previous") && fault("previous_rename"))) { errno=EIO; return -1; }
    int result=renameat(from,source,to,destination);
    if (!result && ((!strcmp(destination,"current") && fault("current_sync")) ||
        (!strcmp(destination,"previous") && fault("previous_sync")))) fail_next_sync=1;
    if (!result && cancel_target && ((!strcmp(destination,"previous") && fault("cancel_before_current")) ||
        (!strcmp(destination,"current") && fault("cancel_after_current")))) mng_store_cancel(cancel_target);
    if (!result && ((!strcmp(destination,"previous") && fault("hook_before_current")) ||
        (!strcmp(destination,"current") && fault("hook_after_current")))) cancel_requested=1;
    return result;
}
static void before_exclusive(const char *source) {
    if (!strcmp(source,".asset.tmp") && fault("before_asset_rename")) _exit(24);
}
static void after_exclusive(const char *source,int result) {
    if (result) return;
    if (!strcmp(source,".asset.tmp") && fault("after_asset_rename")) _exit(25);
    if (strlen(source)==32 && fault("after_generation_rename")) _exit(26);
    if (strlen(source)==32 && fault("generation_sync")) fail_next_sync=1;
}
#ifdef __linux__
long probe_syscall(long number,...) {
    if (number!=SYS_renameat2) { errno=ENOSYS; return -1; }
    va_list args; va_start(args,number);
    int from=va_arg(args,int); const char *source=va_arg(args,const char *);
    int to=va_arg(args,int); const char *destination=va_arg(args,const char *);
    unsigned flags=va_arg(args,unsigned); va_end(args);
    before_exclusive(source);
    long result=syscall(number,from,source,to,destination,flags);
    after_exclusive(source,(int)result); return result;
}
#elif defined(__APPLE__)
int probe_renameatx_np(int from,const char *source,int to,const char *destination,unsigned flags) {
    before_exclusive(source);
    int result=renameatx_np(from,source,to,destination,flags);
    after_exclusive(source,result); return result;
}
#endif

/* Only the test translation unit uses this hook. Production storage calls the
 * actual fstatvfs; tests supply a deterministic low-space response. */
int probe_fstatvfs(int fd, struct statvfs *space) {
    int status=fstatvfs(fd,space);
    if (!status && getenv("CANOPY_TEST_NO_SPACE")) space->f_bavail=0;
    return status;
}
static int digest(const void *data,size_t size,unsigned char out[32]) {
    struct mng_sha256 *hash=NULL;
    int bad=mng_sha256_init(&hash) || mng_sha256_update(hash,data,size) || mng_sha256_final(hash,out);
    mng_sha256_free(hash); return bad;
}
static int asset(struct mng_asset_sink *sink,const char *path,const char *data) {
    unsigned char sha[32]; size_t n=strlen(data);
    return digest(data,n,sha) || sink->begin(sink->context,path,n) ||
        sink->write(sink->context,data,n) || sink->end(sink->context,sha);
}
static int fill(struct mng_asset_sink *sink,const char *variant,struct mng_prepare_result *r) {
    char main_bytes[96];
    (void)snprintf(main_bytes,sizeof(main_bytes),"nonproprietary main fixture %s",variant);
    const char *metadata="nonproprietary metadata fixture", *romfs="nonproprietary romfs fixture";
    if (asset(sink,"exefs/main",main_bytes) || asset(sink,"exefs/main.npdm",metadata) || asset(sink,"romfs.bin",romfs)) return -1;
    r->source_size=1000; r->asset_count=3;
    r->asset_bytes=strlen(main_bytes)+strlen(metadata)+strlen(romfs);
    r->exefs_verified=1; r->romfs_verified=1;
    return digest(variant,strlen(variant),r->source_sha256);
}
int main(int argc,char **argv) {
    if (argc<3) return 2;
    int root=open(argv[2],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (root<0) return 3;
    struct mng_store *store=NULL;
    enum mng_prepare_status status=mng_store_open(root,&store); close(root);
    if (status!=MNG_PREPARE_OK) { printf("{\"status\":%u}\n",(unsigned)status); return 0; }
    mng_store_set_cancel_check(store,cancel_check,&cancel_requested);
    if (fault("hook_before_begin")) cancel_requested=1;
    if (fault("atomic_before_begin")) mng_store_cancel(store);
    if (fault("hook_clear")) {
        struct mng_asset_sink sink=mng_store_sink(store);
        cancel_requested=1;
        if (!sink.cancelled(sink.context)) return 4;
        mng_store_set_cancel_check(store,NULL,NULL);
        cancel_requested=0;
    }
    char generation[65]={0}; struct mng_prepare_result result={0};
    if (!strcmp(argv[1],"hold")) {
        puts("ready"); fflush(stdout); (void)getchar(); mng_store_close(store); return 0;
    }
    if (!strcmp(argv[1],"commit") || !strcmp(argv[1],"cancel") || !strcmp(argv[1],"badcount") ||
        !strcmp(argv[1],"badbytes") || !strcmp(argv[1],"badflags") || !strcmp(argv[1],"inject") ||
        !strncmp(argv[1],"reuse_",6)) {
        if (argc!=6) return 2;
        result.title_id=strtoull(argv[4],NULL,16);
        if (fault("hook_resume")) cancel_target=store;
        status=mng_store_begin(store,argv[3]);
        cancel_target=NULL;
        if (status==MNG_PREPARE_OK) {
            struct mng_asset_sink sink=mng_store_sink(store);
            if (fill(&sink,argv[5],&result)) status=MNG_PREPARE_IO;
            else {
                if (!strcmp(argv[1],"inject")) {
                    char path[4096];
                    int length=snprintf(path,sizeof(path),"%s/jobs/%s/untracked",argv[2],argv[3]);
                    if (length<0 || (size_t)length>=sizeof(path)) return 4;
                    int extra=open(path,O_CREAT|O_EXCL|O_WRONLY,0600); if (extra<0) return 4;
                    close(extra);
                }
                if (!strcmp(argv[1],"cancel")) mng_store_cancel(store);
                if (!strcmp(argv[1],"badcount")) result.asset_count++;
                if (!strcmp(argv[1],"badbytes")) result.asset_bytes++;
                if (!strcmp(argv[1],"badflags")) result.romfs_verified=0;
                cancel_target=store;
                status=mng_store_commit(store,&result,generation);
                cancel_target=NULL;
                if (!strcmp(argv[1],"reuse_after_io")) {
                    if (status!=MNG_PREPARE_IO || mng_store_current(store,result.title_id,generation)!=MNG_PREPARE_OK) return 5;
                    cancel_requested=1;
                    status=mng_store_verify(store,result.title_id,generation,&result);
                } else if (status==MNG_PREPARE_OK) {
                    if (!strcmp(argv[1],"reuse_verify")) {
                        cancel_requested=1; status=mng_store_verify(store,result.title_id,generation,&result);
                    } else if (!strcmp(argv[1],"reuse_select")) {
                        cancel_requested=1; status=mng_store_select(store,result.title_id,generation);
                    } else if (!strcmp(argv[1],"reuse_begin")) {
                        mng_store_cancel(store);
                        status=mng_store_begin(store,"ffffffffffffffffffffffffffffffff");
                    } else if (!strcmp(argv[1],"reuse_prepare")) {
                        status=mng_store_begin(store,"ffffffffffffffffffffffffffffffff");
                        if (status==MNG_PREPARE_OK) {
                            if (fill(&sink,"B",&result)) status=MNG_PREPARE_IO;
                            else status=mng_store_commit(store,&result,generation);
                        }
                    }
                }
            }
        }
    } else if (!strcmp(argv[1],"crash")) {
        if (argc!=4) return 2;
        status=mng_store_begin(store,argv[3]);
        if (status==MNG_PREPARE_OK) {
            struct mng_asset_sink sink=mng_store_sink(store);
            if (asset(&sink,"exefs/main","nonproprietary main fixture A") || sink.begin(sink.context,"romfs.bin",27) ||
                sink.write(sink.context,"partial",7)) return 4;
            _exit(23); /* real process exit: no store cleanup or user callback */
        }
    } else if (!strcmp(argv[1],"path") || !strcmp(argv[1],"writer_failure")) {
        if (argc!=5 && argc!=6) return 2;
        status=mng_store_begin(store,argv[3]);
        if (status==MNG_PREPARE_OK) {
            struct mng_asset_sink sink=mng_store_sink(store);
            uint64_t requested=argc==6 ? strtoull(argv[5],NULL,10):8;
            int bad=sink.begin(sink.context,argv[4],requested);
            if (!bad && !strcmp(argv[1],"writer_failure")) {
                struct rlimit saved, limited;
                if (getrlimit(RLIMIT_FSIZE,&saved)) return 4;
                limited=saved; limited.rlim_cur=0;
                (void)signal(SIGXFSZ,SIG_IGN);
                if (setrlimit(RLIMIT_FSIZE,&limited)) return 4;
                bad=sink.write(sink.context,"fixture!",8);
                if (setrlimit(RLIMIT_FSIZE,&saved)) return 4;
                if (!bad) return 5;
            }
            status=bad ? MNG_PREPARE_IO:MNG_PREPARE_OK;
        }
    } else if (!strcmp(argv[1],"verify") || !strcmp(argv[1],"select") || !strcmp(argv[1],"prune") || !strcmp(argv[1],"pin")) {
        if (argc!=5) return 2;
        uint64_t title=strtoull(argv[3],NULL,16);
        if (!strcmp(argv[1],"verify")) status=mng_store_verify(store,title,argv[4],&result);
        else if (!strcmp(argv[1],"select")) status=mng_store_select(store,title,argv[4]);
        else if (!strcmp(argv[1],"prune")) status=mng_store_remove_generation(store,title,argv[4]);
        else {
            int lease=-1; status=mng_store_pin(store,title,argv[4],&lease);
            mng_store_close(store); store=NULL;
            if (status==MNG_PREPARE_OK) { puts("ready"); fflush(stdout); (void)getchar(); close(lease); return 0; }
        }
    } else if (!strcmp(argv[1],"current")) {
        if (argc!=4) return 2;
        status=mng_store_current(store,strtoull(argv[3],NULL,16),generation);
    } else if (!strcmp(argv[1],"discard")) {
        if (argc!=4) return 2;
        status=mng_store_discard_job(store,argv[3]);
    } else { mng_store_close(store); return 2; }
    printf("{\"status\":%u,\"generation\":\"%s\",\"assetCount\":%" PRIu64 ",\"assetBytes\":%" PRIu64 "}\n",
        (unsigned)status,generation,result.asset_count,result.asset_bytes);
    mng_store_close(store); return 0;
}
