#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include "mng_prepare.h"
#include "mng_crypto.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Synthetic-key test harness, never used by the product or public app. */
static const char *mode, *root;
static unsigned read_calls, stat_calls, progress_calls, write_calls;
static int base_descriptor=-1,update_descriptor=-1,merge_progress,update_hash_progress;
static unsigned update_reads;
static FILE *asset;
static struct mng_sha256 *asset_hash;
static uint64_t asset_size, written;
ssize_t prepare_probe_pread(int fd,void *out,size_t length,off_t offset) {
    read_calls++;
    if (!strcmp(mode,"readfailure") && read_calls==5) { errno=EIO; return -1; }
    if (!strcmp(mode,"eintr") && read_calls==1) { errno=EINTR; return -1; }
    if (!strcmp(mode,"short") && length>7) length=7;
    if (!strcmp(mode,"mutate") && read_calls==1) {
        struct stat st;
        if (fstat(fd,&st) || ftruncate(fd,st.st_size+1)) return -1;
    }
    if (fd==update_descriptor && !strcmp(mode,"mutateupdate") && update_reads++==0) {
        struct stat st;if (fstat(fd,&st) || ftruncate(fd,st.st_size+1)) return -1;
    }
    return pread(fd,out,length,offset);
}
int prepare_probe_fstat(int fd,struct stat *out) {
    if (fstat(fd,out)) return -1;
    if (fd==base_descriptor && ++stat_calls==2) {
        if (!strcmp(mode,"statfailure")) { errno=EIO; return -1; }
        if (!strcmp(mode,"stat-size")) out->st_size++;
        if (!strcmp(mode,"stat-inode")) out->st_ino++;
        if (!strcmp(mode,"stat-device")) out->st_dev++;
#ifdef __APPLE__
        if (!strcmp(mode,"stat-mtime")) out->st_mtimespec.tv_nsec^=1;
        if (!strcmp(mode,"stat-ctime")) out->st_ctimespec.tv_nsec^=1;
#else
        if (!strcmp(mode,"stat-mtime")) out->st_mtim.tv_nsec^=1;
        if (!strcmp(mode,"stat-ctime")) out->st_ctim.tv_nsec^=1;
#endif
    }
    return 0;
}
static int lookup(void *context,const char *name,unsigned char *bytes,size_t size) {
    (void)context;
    if (!strcmp(mode,"missingkeys")) return -1;
    if (!strcmp(name,"header_key") && size==32) {
        for (size_t i=0;i<size;i++) bytes[i]=(unsigned char)i;
        if (!strcmp(mode,"wrongheader")) bytes[0]^=1;
        return 0;
    }
    unsigned base;
    if (!strcmp(name,"key_area_key_application_00") && size==16) base=32;
    else if (!strcmp(name,"titlekek_00") && size==16) base=48;
    else return -1;
    for (size_t i=0;i<size;i++) bytes[i]=(unsigned char)(base+i);
    if (!strcmp(mode,"wrongarea") || !strcmp(mode,"wrongtitlekek")) bytes[0]^=1;
    return 0;
}
static int begin(void *context,const char *path,uint64_t size) {
    (void)context;
    char output[4096];
    if (asset || strstr(path,"..") || (strncmp(path,"exefs/",6) && strcmp(path,"romfs.bin"))) return -1;
    int n=snprintf(output,sizeof(output),"%s/%s",root,path);
    if (n<0 || (size_t)n>=sizeof(output)) return -1;
    asset=fopen(output,"wbx");
    if (!asset || mng_sha256_init(&asset_hash)) return -1;
    asset_size=size; written=0; return 0;
}
static int write_asset(void *context,const void *bytes,size_t size) {
    (void)context; write_calls++;
    if (!strcmp(mode,"quota") || !strcmp(mode,"sinkwrite")) return -1;
    if (!asset || size>asset_size-written || fwrite(bytes,1,size,asset)!=size ||
        mng_sha256_update(asset_hash,bytes,size)) return -1;
    written+=size; return 0;
}
static int end(void *context,const unsigned char digest[32]) {
    (void)context; unsigned char actual[32];
    if (!asset || written!=asset_size || mng_sha256_final(asset_hash,actual) || memcmp(actual,digest,32)) return -1;
    mng_sha256_free(asset_hash); asset_hash=NULL;
    int status=fclose(asset); asset=NULL;
    return !strcmp(mode,"sinkend") ? -1:status;
}
static int is_cancelled(void *context) {
    (void)context;
    return (!strcmp(mode,"cancel") && progress_calls) ||
        (!strcmp(mode,"cancelwrite") && write_calls) || !strcmp(mode,"cancelinitial") ||
        (!strcmp(mode,"cancel-merge") && merge_progress) ||
        (!strcmp(mode,"cancel-updatehash") && update_hash_progress);
}
static void progress(void *context,const char *phase,uint64_t done,uint64_t total) {
    (void)context;
    if (done>total) abort();
    progress_calls++;
    if (!strncmp(phase,"verify-bktr",11)) merge_progress=1;
    if (!strcmp(phase,"hash-update-source")) update_hash_progress=1;
    if (!strcmp(mode,"mutateaftermerge") && !strcmp(phase,"verify-bktr-ivfc-5") && done==total) {
        struct stat st;if (fstat(update_descriptor,&st) || ftruncate(update_descriptor,st.st_size+1)) abort();
    }
}
static void hex(const unsigned char *bytes,size_t size) {
    for (size_t i=0;i<size;i++) printf("%02x",bytes[i]);
}
int main(int argc,char **argv) {
    if (argc!=4 && argc!=6) return 2;
    root=argv[2]; mode=argv[3];
    int fd=open(argv[1],O_RDWR);
    base_descriptor=fd;
    if (fd<0 || lseek(fd,3,SEEK_SET)!=3) return 3;
    char directory[4096];
    if (snprintf(directory,sizeof(directory),"%s/exefs",root)<0 || mkdir(directory,0700)) return 4;
    struct mng_key_provider keys={NULL,lookup};
    struct mng_asset_sink sink={NULL,begin,write_asset,end,is_cancelled,progress};
    struct mng_prepare_result result={0};
    if (!strcmp(mode,"dirty-updatefield")) result.update_source_size=1;
    enum mng_prepare_status status;
    if (argc==6) {
        update_descriptor=open(!strcmp(mode,"same-source") ? argv[1]:argv[4],O_RDWR);
        if (update_descriptor<0 || lseek(update_descriptor,5,SEEK_SET)!=5) return 5;
        if (!strcmp(argv[5],"latest")) status=mng_prepare_latest_update_fd(fd,update_descriptor,&keys,&sink,&result);
        else {
            unsigned long long target=strtoull(argv[5],NULL,10);if (target>UINT32_MAX) return 6;
            status=mng_prepare_update_fd(fd,update_descriptor,&keys,&sink,(uint32_t)target,&result);
        }
    } else status=mng_prepare_fd(fd,&keys,&sink,&result);
    unsigned char zero[sizeof(result)]; memset(zero,0,sizeof(zero));
    struct stat st;
    int preserved=lseek(fd,0,SEEK_CUR)==3 && !fstat(fd,&st);
    if (update_descriptor>=0) { preserved=preserved && lseek(update_descriptor,0,SEEK_CUR)==5;close(update_descriptor); }
    close(fd);
    if (asset) fclose(asset);
    mng_sha256_free(asset_hash);
    printf("{\"status\":\"%s\",\"result_empty\":%s,\"descriptor_preserved\":%s,"
           "\"title_id\":\"%016llx\",\"asset_count\":%llu,\"asset_bytes\":%llu,"
           "\"application_id\":\"%016llx\",\"title_version\":%u,\"version_identified\":%s,\"content_role\":%u,"
           "\"update_applied\":%s,\"update_source_size\":%llu,\"patch_title_id\":\"%016llx\",\"base_title_version\":%u,"
           "\"source_size\":%llu,\"exefs_verified\":%d,\"romfs_verified\":%d,\"source_sha256\":\"",
           mng_prepare_status_name(status),memcmp(&result,zero,sizeof(result)) ? "false":"true",
           preserved ? "true":"false",(unsigned long long)result.title_id,
           (unsigned long long)result.asset_count,(unsigned long long)result.asset_bytes,
           (unsigned long long)result.application_id,result.title_version,result.version_identified ? "true":"false",
           (unsigned)result.content_role,
           result.update_applied ? "true":"false",(unsigned long long)result.update_source_size,
           (unsigned long long)result.patch_title_id,result.base_title_version,
           (unsigned long long)result.source_size,result.exefs_verified,result.romfs_verified);
    hex(result.source_sha256,32);printf("\",\"update_source_sha256\":\"");hex(result.update_source_sha256,32);
    printf("\",\"progress_calls\":%u}\n",progress_calls);
    return 0;
}
