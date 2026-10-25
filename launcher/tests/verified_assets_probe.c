/* Original store-only fixture. Invented bytes do not assert NCA/game validity. */
#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include "mng_store.h"
#include "mng_crypto.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#define TITLE UINT64_C(0x0100123456780000)
#define MAIN_SIZE 131101u
#define ROMFS_SIZE 262181u
static struct stat main_identity,romfs_identity;
static uint64_t main_read,romfs_read;
static int tracking,fail_lease,cancel_flag,cancel_on_read,failed_lease=-1;
ssize_t verified_assets_read(int fd,void *bytes,size_t size) {
    ssize_t n=read(fd,bytes,size);struct stat st;
    if(tracking && n>0 && !fstat(fd,&st)) {
        if(st.st_dev==main_identity.st_dev && st.st_ino==main_identity.st_ino)main_read+=(uint64_t)n;
        if(st.st_dev==romfs_identity.st_dev && st.st_ino==romfs_identity.st_ino)romfs_read+=(uint64_t)n;
        if(cancel_on_read && main_read>=65536)cancel_flag=1;
    }
    return n;
}
int verified_assets_flock(int fd,int operation) {
    if(fail_lease && operation==(LOCK_SH|LOCK_NB)) {failed_lease=fd;errno=EWOULDBLOCK;return -1;}
    return flock(fd,operation);
}
static void check(int yes,const char *message) {if(!yes){fprintf(stderr,"FAIL:%s\n",message);exit(3);}}
static int cancelled(void *unused) {(void)unused;return cancel_flag;}
static void digest(const void *bytes,size_t size,unsigned char out[32]) {
    struct mng_sha256 *hash=NULL;check(!mng_sha256_init(&hash)&&!mng_sha256_update(hash,bytes,size)&&!mng_sha256_final(hash,out),"hash original bytes");mng_sha256_free(hash);
}
static unsigned char *pattern(size_t size,unsigned salt) {
    unsigned char *bytes=malloc(size ? size:1);check(bytes!=NULL,"allocate");for(size_t i=0;i<size;i++)bytes[i]=(unsigned char)(i*17+salt);return bytes;
}
static void asset(struct mng_asset_sink sink,const char *name,const void *bytes,size_t size) {
    unsigned char sha[32];digest(bytes,size,sha);
    check(!sink.begin(sink.context,name,size)&&!sink.write(sink.context,bytes,size)&&!sink.end(sink.context,sha),"actual store asset");
}
static struct mng_prepare_result commit(struct mng_store *store,unsigned sequence,int addon,int empty_main,char generation[65]) {
    char job[33];snprintf(job,sizeof(job),"%032x",sequence);check(!mng_store_begin(store,job),"begin");
    struct mng_asset_sink sink=mng_store_sink(store);struct mng_prepare_result result={0};
    unsigned char *main=pattern(MAIN_SIZE,sequence),*image=pattern(ROMFS_SIZE,sequence+7);
    if(!addon) {asset(sink,"exefs/main",main,empty_main ? 0:MAIN_SIZE);asset(sink,"exefs/main.npdm","invented metadata",17);}
    asset(sink,"romfs.bin",image,ROMFS_SIZE);
    if(addon) {unsigned char index[24]={0};memcpy(index,"TOTKRFS1",8);index[16]=24;asset(sink,"runtime-index.bin",index,sizeof(index));}
    result.title_id=TITLE;result.application_id=addon ? TITLE+1:TITLE;result.title_version=sequence;result.version_identified=1;
    result.content_role=addon ? 0x82:0x80;result.exefs_verified=!addon;result.romfs_verified=1;result.source_size=31;
    result.asset_count=addon ? 2:3;result.asset_bytes=ROMFS_SIZE+(addon ? 24:(empty_main ? 0:MAIN_SIZE)+17);
    digest(main,31,result.source_sha256);if(addon)digest("original synthetic CNMT",23,result.addon_cnmt_sha256);
    check(!mng_store_commit(store,&result,generation),"commit");free(main);free(image);return result;
}
static void generation_path(char out[4096],const char *root,const char *generation,const char *member) {
    int n=snprintf(out,4096,"%s/titles/%016llx/generations/%s/%s",root,(unsigned long long)TITLE,generation,member);check(n>0&&n<4096,"fixture path");
}
static void track_assets(const char *root,const char *generation) {
    char path[4096];generation_path(path,root,generation,"exefs/main");check(!stat(path,&main_identity),"main identity");
    generation_path(path,root,generation,"romfs.bin");check(!stat(path,&romfs_identity),"RomFS identity");
}
static void extra_consumer_hash(const char *root,const char *generation,const char *member) {
    char path[4096];generation_path(path,root,generation,member);int fd=open(path,O_RDONLY|O_NOFOLLOW);check(fd>=0,"consumer open");
    unsigned char bytes[65536],sha[32];struct mng_sha256 *hash=NULL;check(!mng_sha256_init(&hash),"consumer hash");ssize_t n;
    while((n=verified_assets_read(fd,bytes,sizeof(bytes)))>0)check(!mng_sha256_update(hash,bytes,(size_t)n),"consumer update");
    check(n==0&&!mng_sha256_final(hash,sha),"consumer final");mng_sha256_free(hash);close(fd);
}
int main(int argc,char **argv) {
    if(argc!=3)return 2;
    const char *mode=argv[1],*root=argv[2];
    int fd=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);check(fd>=0,"root");struct mng_store *store=NULL;
    check(!mng_store_open(fd,&store),"open store");char generation[65];int addon=!strcmp(mode,"addon"),empty=!strcmp(mode,"empty");
    struct mng_prepare_result expected=commit(store,1,addon,empty,generation);
    check(!mng_store_verify(store,TITLE,generation,&expected),"legacy verification identity");
    if(!addon)track_assets(root,generation);
    struct mng_store_verified_assets facts,before;memset(&facts,0xa5,sizeof(facts));before=facts;int lease=0x123456;
    if(strstr(mode,"corrupt")) {
        const char *member=!strcmp(mode,"main-corrupt") ? "exefs/main":!strcmp(mode,"romfs-corrupt") ? "romfs.bin":
            !strcmp(mode,"npdm-corrupt") ? "exefs/main.npdm":!strcmp(mode,"manifest-corrupt") ? "manifest.json":"receipt.bin";
        char path[4096];generation_path(path,root,generation,member);check(!chmod(path,0600),"allow fixture corruption");
        int changed=open(path,O_WRONLY|O_NOFOLLOW);check(changed>=0&&pwrite(changed,"X",1,0)==1,"fixture corruption");close(changed);
    }
    if(!strcmp(mode,"lease-error"))fail_lease=1;
    if(!strcmp(mode,"cancel")) {cancel_on_read=1;mng_store_set_cancel_check(store,cancelled,NULL);}
    if(!strcmp(mode,"invalid")) {
        check(mng_store_pin_verified_assets(store,TITLE,generation,NULL,&lease)==MNG_PREPARE_INVALID&&lease==0x123456,"null facts changed lease");
        check(mng_store_pin_verified_assets(store,TITLE,generation,&facts,NULL)==MNG_PREPARE_INVALID&&!memcmp(&facts,&before,sizeof(facts)),"null lease changed facts");
    }
    tracking=1;
    enum mng_prepare_status status=mng_store_pin_verified_assets(store,!strcmp(mode,"invalid") ? 0:TITLE,generation,&facts,&lease);
    uint64_t verified_main=main_read,verified_romfs=romfs_read;
    if(strstr(mode,"corrupt") || !strcmp(mode,"lease-error") || !strcmp(mode,"cancel") || !strcmp(mode,"invalid")) {
        check(status!=MNG_PREPARE_OK && !memcmp(&facts,&before,sizeof(facts))&&lease==0x123456,"failed pin changed outputs");
        if(!strcmp(mode,"lease-error"))check(failed_lease>=0&&fcntl(failed_lease,F_GETFD)<0&&errno==EBADF,"failed lease leaked fd");
        if(!strcmp(mode,"cancel"))check(status==MNG_PREPARE_CANCELLED,"hash cancellation lost");
    } else {
        check(!status&&lease>=0,"pin verified");check(!memcmp(&facts.preparation,&expected,sizeof(expected)),"preparation identity changed");
        unsigned char *original=pattern(MAIN_SIZE,1),*image=pattern(ROMFS_SIZE,8),sha[32];
        check(facts.main.present==!addon&&facts.romfs.present==1,"asset presence");
        if(!addon) {digest(original,empty ? 0:MAIN_SIZE,sha);check(facts.main.size==(empty ? 0:MAIN_SIZE)&&!memcmp(facts.main.sha256,sha,32),"main facts mismatch");}
        else {unsigned char zero[32]={0};check(!facts.main.size&&!memcmp(facts.main.sha256,zero,32),"absent main has invented facts");}
        digest(image,ROMFS_SIZE,sha);check(facts.romfs.size==ROMFS_SIZE&&!memcmp(facts.romfs.sha256,sha,32),"RomFS facts mismatch");free(original);free(image);
        if(!addon)check(main_read==(empty ? 0:MAIN_SIZE)&&romfs_read==ROMFS_SIZE,"verification did not read each payload exactly once");
        if(addon) {int old=-1;check(!mng_store_pin(store,TITLE,generation,&old)&&old>=0,"old API rejected add-on without main");close(old);}
        if(!strcmp(mode,"reads")) {
            close(lease);main_read=romfs_read=0;check(!mng_store_pin(store,TITLE,generation,&lease),"old API");
            check(main_read==MAIN_SIZE&&romfs_read==ROMFS_SIZE,"old pin verification changed");
            extra_consumer_hash(root,generation,"exefs/main");extra_consumer_hash(root,generation,"romfs.bin");
            check(main_read==2*MAIN_SIZE&&romfs_read==2*ROMFS_SIZE,"duplicate consumer accounting");
        }
        if(!strcmp(mode,"gc")) {
            tracking=0;mng_store_close(store);store=NULL;check(!mng_store_open(fd,&store),"reopen with independent lease");
            char second[65],third[65];(void)commit(store,2,0,0,second);(void)commit(store,3,0,0,third);
            check(mng_store_remove_generation(store,TITLE,generation)==MNG_PREPARE_IO,"genuine shared lease did not protect GC");
            close(lease);lease=-1;check(!mng_store_remove_generation(store,TITLE,generation),"lease release did not allow GC");
        }
        if(lease>=0)close(lease);
    }
    printf("{\"status\":%u,\"verifiedMainBytes\":%llu,\"verifiedRomfsBytes\":%llu,\"oldWithConsumerMainBytes\":%llu,\"oldWithConsumerRomfsBytes\":%llu}\n",
        (unsigned)status,(unsigned long long)verified_main,(unsigned long long)verified_romfs,(unsigned long long)main_read,(unsigned long long)romfs_read);
    mng_store_close(store);close(fd);return 0;
}
