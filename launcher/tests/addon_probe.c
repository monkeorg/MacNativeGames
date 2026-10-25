#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#include "mng_addon.h"
#include "mng_crypto.h"
#include "mng_romfs_runtime.h"
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
static int cancel_flag,cancel_count;
static int cancel(void *p){(void)p;return cancel_flag==2?++cancel_count>=3:cancel_flag;}
static void check(int condition){if(!condition){fprintf(stderr,"addon probe check failed\n");exit(3);}}
static void digest(int fd,unsigned char out[32]){
    struct mng_sha256 *hash=NULL;unsigned char bytes[4096];off_t at=0;ssize_t n;
    check(!mng_sha256_init(&hash));while((n=pread(fd,bytes,sizeof(bytes),at))>0){check(!mng_sha256_update(hash,bytes,(size_t)n));at+=n;}
    check(n==0&&!mng_sha256_final(hash,out));mng_sha256_free(hash);
}
static void planner(const char *mode){
    struct mng_content_record records[2]={0};struct mng_content_candidate candidates[2]={0};
    struct mng_content metadata[3]={0};const struct mng_content *list[3]={metadata,metadata+1,metadata+2};
    for(unsigned i=0;i<2;i++){records[i].sha256[0]=(unsigned char)(i+1);memcpy(records[i].id,records[i].sha256,16);records[i].size=100;records[i].role=2;
        memcpy(candidates[i].sha256,records[i].sha256,32);memcpy(candidates[i].id,records[i].id,16);candidates[i].size=100;candidates[i].nca_type=5;}
    for(unsigned i=0;i<3;i++){metadata[i].title_id=i==1?12:11;metadata[i].application_id=10;metadata[i].version=i+1;metadata[i].type=MNG_CONTENT_ADDON;
        metadata[i].contents=records+(i==1);metadata[i].content_count=1;metadata[i].required_application_version=4;}
    struct mng_addon_base base={10,4,1};struct mng_addon_plan result={0};size_t count=3;
    if(!strcmp(mode,"plan-owner"))metadata[2].application_id=20;
    if(!strcmp(mode,"plan-requires"))metadata[2].required_application_version=5;
    if(!strcmp(mode,"plan-unknown-base"))base.version_verified=0;
    if(!strcmp(mode,"plan-duplicate"))metadata[2].version=1;
    if(!strcmp(mode,"plan-dependency"))metadata[2].dependency_count=1;
    if(!strcmp(mode,"plan-role"))records[0].role=1;
    if(!strcmp(mode,"plan-missing-highest")){metadata[2].contents=records+1;candidates[1].sha256[1]=1;}
    enum mng_prepare_status status=mng_addon_plan(list,count,candidates,2,&base,&result);
    if(!status)check(result.count==2&&result.metadata_indices[0]==2&&result.metadata_indices[1]==1);
    else check(result.count==0);
    printf("{\"status\":%d,\"count\":%zu}\n",status,result.count);
}
struct reader {struct mng_addon_volume *volume;uint64_t handle;};
static void *read_thread(void *context){
    struct reader *r=context;for(unsigned i=0;i<100;i++){char bytes[16];size_t n=0;check(!mng_addon_read(r->volume,r->handle,0,bytes,sizeof(bytes),&n)&&n==16&&!memcmp(bytes,"original payload",16));}return NULL;
}
int main(int argc,char **argv){
    if(argc==2){planner(argv[1]);return 0;}if(argc!=5&&argc!=7)return 2;
    const char *mode=argv[4];int image=open(argv[1],O_RDONLY),index=open(argv[2],O_RDWR),pin=open(argv[3],O_RDWR);
    check(image>=0&&index>=0&&pin>=0&&!flock(pin,LOCK_SH|LOCK_NB));
    struct stat st;check(!fstat(index,&st));
    if(!st.st_size){struct mng_romfs_runtime_result indexed={0};check((!strcmp(mode,"empty") ? mng_romfs_runtime_index_fd_ex(image,index,NULL,MNG_ROMFS_RUNTIME_ALLOW_EMPTY,&indexed) :
        mng_romfs_runtime_index_fd(image,index,NULL,&indexed))==MNG_ROMFS_OK);}
    close(index);index=open(argv[2],O_RDONLY);check(index>=0);
    struct mng_addon_result result={0};result.application_id=10;result.title_id=11;result.version=2;result.required_application_version=4;
    result.source_size=100;result.source_sha256[0]=1;result.cnmt_sha256[0]=2;result.romfs_verified=1;
    check(!fstat(image,&st));result.romfs_size=(uint64_t)st.st_size;digest(image,result.romfs_sha256);
    check(!fstat(index,&st));uint64_t index_size=(uint64_t)st.st_size;unsigned char sha[32];digest(index,sha);
    struct mng_addon_binding binding={10,11,17};struct mng_addon_base base={10,4,1};
    if(!strcmp(mode,"wrong-hash"))sha[0]^=1;
    if(!strcmp(mode,"wrong-owner"))binding.application_id=20;
    if(!strcmp(mode,"wrong-addon"))binding.addon_title_id=12;
    if(!strcmp(mode,"requires"))base.version=3;
    if(!strcmp(mode,"unverified"))result.romfs_verified=0;
    if(!strcmp(mode,"cancel"))cancel_flag=1;
    if(!strcmp(mode,"cancel-hash"))cancel_flag=2;
    struct mng_addon_callbacks callbacks={NULL,cancel};struct mng_addon_volume *v=NULL;
    enum mng_prepare_status status=mng_addon_mount(image,index,pin,&binding,&base,&result,index_size,sha,&callbacks,&v);
    check(lseek(image,0,SEEK_CUR)==0&&lseek(index,0,SEEK_CUR)==0);
    close(image);close(index);close(pin);
    if(!status&&!strcmp(mode,"empty")){
        uint64_t h=0,size=0;size_t n=9;char byte=0;
        check(mng_addon_open(v,"anything",&h)==MNG_PREPARE_INVALID&&h==0);
        check(mng_addon_size(v,1,&size)==MNG_PREPARE_INVALID);
        check(mng_addon_read(v,1,0,&byte,1,&n)==MNG_PREPARE_INVALID&&n==0);
        mng_addon_unmount(v);printf("{\"status\":0}\n");return 0;
    }
    if(!status){
        uint64_t h=0,size=0;check(mng_addon_open(v,"nested/data.bin",&h)==MNG_PREPARE_OK&&h);
        check(mng_addon_size(v,h,&size)==MNG_PREPARE_OK&&size==16);
        size_t n=999;char bytes[32]={0};check(mng_addon_read(v,h,3,bytes,5,&n)==MNG_PREPARE_OK&&n==5&&!memcmp(bytes,"ginal",5));
        check(mng_addon_read(v,h,size,bytes,sizeof(bytes),&n)==MNG_PREPARE_OK&&n==0);
        check(mng_addon_read(v,h,size+1,bytes,1,&n)!=MNG_PREPARE_OK&&n==0);
        for(unsigned i=0;i<6;i++){const char *bad[]={"../data","/nested/data.bin","nested//data.bin","nested/./data.bin","nested/data.bin/","nested\\data.bin"};check(mng_addon_open(v,bad[i],&size)!=MNG_PREPARE_OK);}
        if(!strcmp(mode,"concurrent")){pthread_t threads[4];struct reader reader={v,h};
            for(unsigned i=0;i<4;i++)check(!pthread_create(threads+i,NULL,read_thread,&reader));
            for(unsigned i=0;i<4;i++)check(!pthread_join(threads[i],NULL));}
        if(!strcmp(mode,"isolation")){
            check(argc==7);int image2=open(argv[5],O_RDONLY),index2=open(argv[6],O_RDWR),pin2=open(argv[3],O_RDWR);
            check(image2>=0&&index2>=0&&pin2>=0&&!flock(pin2,LOCK_SH|LOCK_NB));
            struct mng_romfs_runtime_result generated={0};check(!mng_romfs_runtime_index_fd(image2,index2,NULL,&generated));
            close(index2);index2=open(argv[6],O_RDONLY);check(index2>=0);
            struct mng_addon_result result2=result;result2.title_id=12;check(!fstat(image2,&st));result2.romfs_size=(uint64_t)st.st_size;digest(image2,result2.romfs_sha256);
            struct mng_addon_binding binding2={10,12,21};struct mng_addon_volume *v2=NULL;
            check(!mng_addon_mount(image2,index2,pin2,&binding2,&base,&result2,generated.index_size,generated.index_sha256,NULL,&v2));
            close(image2);close(index2);close(pin2);uint64_t h2=0;check(!mng_addon_open(v2,"nested/data.bin",&h2));
            check(!mng_addon_read(v2,h2,0,bytes,16,&n)&&n==16&&!memcmp(bytes,"separate payload",16));
            check(!mng_addon_read(v,h,0,bytes,16,&n)&&n==16&&!memcmp(bytes,"original payload",16));
            check(!mng_addon_close(v2,h2));mng_addon_unmount(v2);
        }
        if(!strcmp(mode,"capacity")){uint64_t handles[255];for(unsigned i=0;i<255;i++)check(!mng_addon_open(v,"nested/data.bin",handles+i));
            check(mng_addon_open(v,"nested/data.bin",&size)==MNG_PREPARE_LIMIT);for(unsigned i=0;i<255;i++)check(!mng_addon_close(v,handles[i]));}
        if(!strcmp(mode,"cancel-read")){cancel_flag=1;check(mng_addon_read(v,h,0,bytes,1,&n)==MNG_PREPARE_CANCELLED&&n==0);cancel_flag=0;}
        if(!strcmp(mode,"mutate")){int fd=open(argv[1],O_WRONLY);check(fd>=0&&pwrite(fd,"X",1,0)==1);close(fd);check(mng_addon_read(v,h,0,bytes,1,&n)==MNG_PREPARE_IO&&n==0);}
        check(!mng_addon_close(v,h));check(mng_addon_close(v,h)==MNG_PREPARE_INVALID);
        check(mng_addon_read(v,h,0,bytes,1,&n)==MNG_PREPARE_INVALID&&n==0);
        int competing=open(argv[3],O_RDWR);check(competing>=0&&flock(competing,LOCK_EX|LOCK_NB)!=0);mng_addon_unmount(v);
        check(!flock(competing,LOCK_EX|LOCK_NB));close(competing);
    }else check(v==NULL);
    printf("{\"status\":%d}\n",status);return 0;
}
