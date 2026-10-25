#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include "mng_install.h"
#include "mng_store.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#define APP UINT64_C(0x0100123456780000)
#define DLC UINT64_C(0x0100123456781001)
static const char *mode;
static int cancel_flag,fail_sync;
static unsigned progress_calls;
int install_probe_fsync(int fd){if(fail_sync){fail_sync=0;errno=EIO;return -1;}return fsync(fd);}
int install_probe_renameat(int from,const char *src,int to,const char *dest){int r=renameat(from,src,to,dest);if(!r&&!strcmp(dest,"current")&&getenv("CANOPY_INSTALL_FAIL_CURRENT_SYNC"))fail_sync=1;return r;}
ssize_t install_probe_pwrite(int fd,const void *p,size_t n,off_t at){if(!strcmp(mode,"index-error")){errno=EIO;return -1;}ssize_t result=pwrite(fd,p,n,at);if(result>0&&!strcmp(mode,"cancel-index-write"))cancel_flag=1;return result;}
static void check(int yes){if(!yes){fprintf(stderr,"install probe check failed\n");exit(3);}}
static int lookup(void *context,const char *name,unsigned char *bytes,size_t n){
    (void)context;unsigned start;
    if(!strcmp(mode,"missing-key"))return -1;
    if(!strcmp(name,"header_key")&&n==32)start=0;
    else if(!strcmp(name,"key_area_key_application_00")&&n==16)start=32;
    else if(!strcmp(name,"titlekek_00")&&n==16)start=48;else return -1;
    for(size_t i=0;i<n;i++)bytes[i]=(unsigned char)(start+i);
    return 0;
}
static int stopped(void *p){(void)p;return cancel_flag;}
static void progress(void *p,const char *phase,uint64_t done,uint64_t total){
    (void)p;check(done<=total);progress_calls++;
    if((!strcmp(mode,"cancel-source")&&!strcmp(phase,"hash-addon-source"))||
       (!strcmp(mode,"cancel-index")&&!strcmp(phase,"index-addon-romfs"))||
       (!strcmp(mode,"cancel-commit")&&!strcmp(phase,"commit-addon")))cancel_flag=1;
}
static int child(int fd,const char *name){return openat(fd,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);}
int main(int argc,char **argv){
    if(argc!=6)return 2;
    mode=argv[1];int root=open(argv[2],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC),source=open(argv[3],O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    check(root>=0&&source>=0&&lseek(source,7,SEEK_SET)==7);off_t root_position=lseek(root,0,SEEK_CUR);
    struct mng_key_provider keys={NULL,lookup};
    if(!strcmp(mode,"base")||!strcmp(mode,"base-update")){
        struct mng_store *store=NULL;check(!mng_store_open(root,&store));check(!mng_store_begin(store,"11111111111111111111111111111111"));
        struct mng_asset_sink sink=mng_store_sink(store);struct mng_prepare_result result={0};char generation[65]={0};
        enum mng_prepare_status status;
        if(!strcmp(mode,"base-update")){int update=open(argv[4],O_RDONLY|O_NOFOLLOW|O_CLOEXEC);check(update>=0);
            status=mng_prepare_latest_update_fd(source,update,&keys,&sink,&result);close(update);
        }else status=mng_prepare_fd(source,&keys,&sink,&result);
        if(!status)status=mng_store_commit(store,&result,generation);
        mng_store_close(store);printf("{\"status\":%d,\"generation\":\"%s\"}\n",status,generation);
    }else{
        struct mng_install_control control={NULL,stopped,progress,NULL};struct mng_install_report report;
        if(!strcmp(mode,"cancel-initial"))cancel_flag=1;
        enum mng_prepare_status status=mng_install_addon_fd(root,source,&keys,APP,argv[4],DLC,!strcmp(argv[5],"-")?NULL:argv[5],&control,&report);
        int mounted=0,read_ok=0;
        if(!status||(report.publication_uncertain&&report.current_readable)){
            const char *gen=!status?report.generation_id:report.current_generation_id;
            struct mng_store *store=NULL;check(!mng_store_open(root,&store));struct mng_prepare_result result={0};int lease=-1;
            check(!mng_store_verify(store,DLC,gen,&result)&&!mng_store_pin(store,DLC,gen,&lease));mng_store_close(store);
            check(result.content_role==0x82&&result.application_id==APP&&result.title_id==DLC&&result.exefs_verified==0&&result.romfs_verified==1);
            int titles=child(root,"titles"),title=child(titles,"0100123456781001"),generations=child(title,"generations"),generation=child(generations,gen);
            check(titles>=0&&title>=0&&generations>=0&&generation>=0);
            int image=openat(generation,"romfs.bin",O_RDONLY|O_NOFOLLOW|O_CLOEXEC),index=openat(generation,"runtime-index.bin",O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
            struct mng_addon_binding binding={APP,DLC,23};struct mng_addon_base base={APP,report.verified_base_version,1};struct mng_addon_volume *volume=NULL;
            check(!mng_addon_mount(image,index,lease,&binding,&base,&report.addon,report.index.index_size,report.index.index_sha256,NULL,&volume));mounted=1;
            close(image);close(index);close(lease);close(generation);close(generations);close(title);close(titles);
            uint64_t handle=0;
            if(!strcmp(mode,"empty")){check(mng_addon_open(volume,"missing",&handle)==MNG_PREPARE_INVALID);read_ok=1;}
            else {check(!mng_addon_open(volume,"icon_AmericanEnglish.dat",&handle));char bytes[64]={0};size_t n=0;
                check(!mng_addon_read(volume,handle,0,bytes,sizeof(bytes),&n)&&n==strlen("synthetic icon payload")&&!memcmp(bytes,"synthetic icon payload",n));
                check(!mng_addon_close(volume,handle));read_ok=1;}
            mng_addon_unmount(volume);
        }
        printf("{\"status\":%d,\"job\":\"%s\",\"generation\":\"%s\",\"current\":\"%s\",\"currentReadable\":%d,\"commitAttempted\":%d,\"uncertain\":%d,\"reload\":%d,\"baseVersion\":%u,\"version\":%u,\"indexFiles\":%llu,\"mounted\":%d,\"read\":%d,\"progress\":%u,\"positionsPreserved\":%d}\n",
            status,report.job_id,report.generation_id,report.current_generation_id,report.current_readable,report.commit_attempted,report.publication_uncertain,report.reload_required,
            report.verified_base_version,report.addon.version,(unsigned long long)report.index.file_count,mounted,read_ok,progress_calls,lseek(source,0,SEEK_CUR)==7&&lseek(root,0,SEEK_CUR)==root_position);
    }
    close(source);close(root);return 0;
}
