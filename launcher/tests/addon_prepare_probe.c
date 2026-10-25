#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#include "mng_addon.h"
#include "mng_crypto.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static const char *mode,*output;
static int source_fd,stop_flag;
static unsigned reads,emitted,progress_calls;
static FILE *asset;
static struct mng_sha256 *hash;
static uint64_t expected,written;
ssize_t addon_prepare_pread(int fd,void *p,size_t n,off_t at){
    reads++;
    if(!strcmp(mode,"readerror")&&reads==2){errno=EIO;return -1;}
    if(!strcmp(mode,"eintr")&&reads==1){errno=EINTR;return -1;}
    if(!strcmp(mode,"short")&&n>7)n=7;
    return pread(fd,p,n,at);
}
static int key(void *context,const char *name,unsigned char *p,size_t n){
    (void)context;unsigned start;
    if(!strcmp(mode,"missingkey"))return -1;
    if(!strcmp(name,"header_key")&&n==32)start=0;
    else if(!strcmp(name,"key_area_key_application_00")&&n==16)start=32;
    else if(!strcmp(name,"titlekek_00")&&n==16)start=48;else return -1;
    for(size_t i=0;i<n;i++)p[i]=(unsigned char)(start+i);
    if(!strcmp(mode,"wrongkey"))p[0]^=1;
    return 0;
}
static int begin(void *context,const char *name,uint64_t size){
    (void)context;if(asset||strcmp(name,"romfs.bin"))return -1;
    char path[4096];int n=snprintf(path,sizeof(path),"%s/%s",output,name);if(n<0||(size_t)n>=sizeof(path))return -1;
    asset=fopen(path,"wbx");expected=size;written=0;emitted++;
    return !asset||mng_sha256_init(&hash);
}
static int write_asset(void *context,const void *p,size_t n){
    (void)context;if(!strcmp(mode,"sinkerror"))return -1;
    if(!asset||n>expected-written||fwrite(p,1,n,asset)!=n||mng_sha256_update(hash,p,n))return -1;
    written+=n;if(!strcmp(mode,"cancelwrite"))stop_flag=1;return 0;
}
static int end(void *context,const unsigned char expected_sha[32]){
    (void)context;unsigned char sha[32];if(!asset||written!=expected||mng_sha256_final(hash,sha)||memcmp(sha,expected_sha,32))return -1;
    mng_sha256_free(hash);hash=NULL;int status=fclose(asset);asset=NULL;return !strcmp(mode,"enderror")?-1:status;
}
static int stop(void *context){(void)context;return stop_flag||!strcmp(mode,"cancelinitial");}
static void progress(void *context,const char *phase,uint64_t done,uint64_t total){
    (void)context;if(done>total)abort();progress_calls++;
    if((!strcmp(mode,"cancelivfc")&&!strcmp(phase,"verify-ivfc"))||(!strcmp(mode,"cancelsource")&&!strcmp(phase,"hash-addon-source")))stop_flag=1;
    if(!strcmp(mode,"mutate")&&!strcmp(phase,"hash-addon-source")&&done==0){struct stat st;if(fstat(source_fd,&st)||ftruncate(source_fd,st.st_size+1))abort();}
}
static void hex(const unsigned char p[32]){for(unsigned i=0;i<32;i++)printf("%02x",p[i]);}
int main(int argc,char **argv){
    if(argc!=7)return 2;
    mode=argv[3];output=argv[2];source_fd=open(argv[1],!strcmp(mode,"mutate")?O_RDWR:O_RDONLY);
    if(source_fd<0||lseek(source_fd,7,SEEK_SET)!=7)return 2;
    struct mng_addon_base base={strtoull(argv[5],NULL,16),(uint32_t)strtoul(argv[4],NULL,10),1};
    if(!strcmp(mode,"unknownbase"))base.version_verified=0;
    struct mng_addon_result result={0};
    if(!strcmp(mode,"dirtyversion"))result.version=1;
    if(!strcmp(mode,"dirtyhash"))result.cnmt_sha256[0]=1;
    struct mng_key_provider provider={NULL,key};struct mng_asset_sink sink={NULL,begin,write_asset,end,stop,progress};
    enum mng_prepare_status status;
    if(!strncmp(mode,"legacy-dirty-",13)){
        struct mng_prepare_result legacy={0};
        if(!strcmp(mode,"legacy-dirty-required"))legacy.addon_required_application_version=1;
        else legacy.addon_cnmt_sha256[0]=1;
        status=mng_prepare_fd(source_fd,&provider,&sink,&legacy);
        if(!strcmp(mode,"legacy-dirty-required")){if(legacy.addon_required_application_version!=1)return 4;}
        else if(legacy.addon_cnmt_sha256[0]!=1)return 4;
    }else status=mng_prepare_addon_fd(source_fd,&provider,&sink,&base,strtoull(argv[6],NULL,16),&result);
    int preserved=lseek(source_fd,0,SEEK_CUR)==7;close(source_fd);if(asset)fclose(asset);mng_sha256_free(hash);
    unsigned char zero[sizeof(result)]={0};
    printf("{\"status\":\"%s\",\"empty\":%s,\"positionPreserved\":%s,\"version\":%u,\"required\":%u,\"application\":\"%016llx\",\"addon\":\"%016llx\",\"size\":%llu,\"romfsSize\":%llu,\"verified\":%d,\"emitted\":%u,\"progress\":%u,\"sourceSHA\":\"",
        mng_prepare_status_name(status),memcmp(&result,zero,sizeof(result))?"false":"true",preserved?"true":"false",result.version,result.required_application_version,
        (unsigned long long)result.application_id,(unsigned long long)result.title_id,(unsigned long long)result.source_size,(unsigned long long)result.romfs_size,result.romfs_verified,emitted,progress_calls);
    hex(result.source_sha256);printf("\",\"cnmtSHA\":\"");hex(result.cnmt_sha256);printf("\",\"romfsSHA\":\"");hex(result.romfs_sha256);puts("\"}");return 0;
}
