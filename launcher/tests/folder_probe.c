#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include "mng_folder.h"
#include "mng_crypto.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static const char *mode,*input,*output;
static enum mng_folder_kind kind;
static int cancelled,changed;
static unsigned reads,progress_calls;
static FILE *asset;
static struct mng_sha256 *hash;
static uint64_t expected,written;
ssize_t folder_probe_pread(int fd,void *bytes,size_t size,off_t at) {
    reads++;
    if (!strcmp(mode,"read-error") && reads==2) { errno=EIO;return -1; }
    if (!strcmp(mode,"eintr") && reads==1) { errno=EINTR;return -1; }
    if (!strcmp(mode,"short") && size>7) size=7;
    return pread(fd,bytes,size,at);
}
static int lookup(void *opaque,const char *name,unsigned char *bytes,size_t size) {
    (void)opaque;
    unsigned start;
    if (!strcmp(mode,"missing-key")) return -1;
    if (!strcmp(name,"header_key") && size==32) start=0;
    else if (!strcmp(name,"key_area_key_application_00") && size==16) start=32;
    else if (!strcmp(name,"titlekek_00") && size==16) start=48;
    else return -1;
    for (size_t i=0;i<size;i++) bytes[i]=(unsigned char)(start+i);
    if (!strcmp(mode,"wrong-key")) bytes[0]^=1;
    return 0;
}
static int begin(void *opaque,const char *path,uint64_t size) {
    (void)opaque;char file[4096];
    if (asset || strstr(path,"..") || (strncmp(path,"exefs/",6) && strcmp(path,"romfs.bin") && strcmp(path,"input-members.json"))) return -1;
    int n=snprintf(file,sizeof(file),"%s/%s",output,path);if (n<0 || (size_t)n>=sizeof(file))return -1;
    asset=fopen(file,"wbx");if (!asset || mng_sha256_init(&hash))return -1;
    expected=size;written=0;
    if (!strcmp(mode,"cancel-metadata") && !strcmp(path,"input-members.json")) cancelled=1;
    return 0;
}
static int write_asset(void *opaque,const void *bytes,size_t size) {
    (void)opaque;
    if (!asset || !strcmp(mode,"quota") || cancelled || size>expected-written ||
        fwrite(bytes,1,size,asset)!=size || mng_sha256_update(hash,bytes,size))return -1;
    written+=size;return 0;
}
static int end(void *opaque,const unsigned char digest[32]) {
    (void)opaque;unsigned char actual[32];
    if (!asset || written!=expected || mng_sha256_final(hash,actual) || memcmp(actual,digest,32))return -1;
    mng_sha256_free(hash);hash=NULL;int result=fclose(asset);asset=NULL;return result;
}
static int stop(void *opaque) { (void)opaque;return cancelled; }
static void mutate_source(void) {
    char path[4096];
    if (kind==MNG_FOLDER_ASSETS) snprintf(path,sizeof(path),"%s/exefs/main",input);
    else {
        DIR *d=opendir(input);if (!d)abort();struct dirent *e;int found=0;
        while ((e=readdir(d))!=NULL) if (strstr(e->d_name,".nca")) {
            snprintf(path,sizeof(path),"%s/%s",input,e->d_name);found=1;break;
        }
        closedir(d);if (!found)abort();
    }
    int fd=open(path,O_RDWR|O_NOFOLLOW);unsigned char byte;
    if (fd<0 || pread(fd,&byte,1,0)!=1)abort();
    byte^=1;
    if (pwrite(fd,&byte,1,0)!=1)abort();
    close(fd);changed=1;
}
static void progress(void *opaque,const char *phase,uint64_t done,uint64_t total) {
    (void)opaque;if (done>total)abort();progress_calls++;
    if (!strcmp(mode,"cancel-prehash") || (!strcmp(mode,"cancel-core") && !strcmp(phase,"verify-exefs"))) cancelled=1;
    if (!changed && ((!strcmp(mode,"mutate-after-hash") && !strcmp(phase,"fingerprint-folder-members") && done==total) ||
        (!strcmp(mode,"mutate-copy") && !strcmp(phase,"copy-plaintext-assets") && done))) mutate_source();
}
/* Deliberately small fixture host normalizer, not a general Unicode engine. */
static int canonical(void *opaque,const char *name,char *out,size_t capacity) {
    (void)opaque;
    const char *value=(!strcmp(name,"\xc3\xa9") || !strcmp(name,"e\xcc\x81")) ? "accent":NULL;
    if (!value || strlen(value)>=capacity)return -1;
    strcpy(out,value);return 0;
}
static void hex(const unsigned char bytes[32]) { for(unsigned i=0;i<32;i++)printf("%02x",bytes[i]); }
int main(int argc,char **argv) {
    if (argc!=5)return 2;
    input=argv[1];output=argv[2];mode=argv[3];kind=(enum mng_folder_kind)strtoul(argv[4],NULL,10);
    int root=open(input,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(root<0)return 3;
    off_t position=lseek(root,0,SEEK_CUR);
    char directory[4096];snprintf(directory,sizeof(directory),"%s/exefs",output);if(mkdir(directory,0700))return 4;
    struct mng_key_provider keys={NULL,lookup};struct mng_asset_sink sink={NULL,begin,write_asset,end,stop,progress};
    struct mng_folder_callbacks callbacks={NULL,!strcmp(mode,"unicode") ? canonical:NULL};
    struct mng_prepare_result result={0};
    enum mng_prepare_status status=kind ? MNG_PREPARE_OK:mng_folder_kind_fd(root,&kind);
    if (!status) status=mng_prepare_folder_fd(root,kind,kind==MNG_FOLDER_ASSETS ? NULL:&keys,&callbacks,&sink,&result);
    struct stat st;int preserved=lseek(root,0,SEEK_CUR)==position && !fstat(root,&st);close(root);
    if (asset)fclose(asset);
    mng_sha256_free(hash);
    unsigned char zero[sizeof(result)];memset(zero,0,sizeof(zero));
    printf("{\"status\":\"%s\",\"sourceKind\":%u,\"detectedKind\":%u,\"resultEmpty\":%s,\"descriptorPreserved\":%s,"
        "\"titleID\":\"%016llx\",\"assetCount\":%llu,\"assetBytes\":%llu,\"memberBytes\":%llu,\"memberCount\":%u,"
        "\"sourceSize\":%llu,\"exefsVerified\":%d,\"romfsVerified\":%d,\"assetHashesVerified\":%d,\"romfsStructureVerified\":%d,"
        "\"versionIdentified\":%s,\"titleVersion\":%u,\"sourceSHA256\":\"",
        mng_prepare_status_name(status),(unsigned)result.source_kind,(unsigned)kind,memcmp(&result,zero,sizeof(result)) ? "false":"true",
        preserved ? "true":"false",(unsigned long long)result.title_id,(unsigned long long)result.asset_count,
        (unsigned long long)result.asset_bytes,(unsigned long long)result.source_member_bytes,result.source_member_count,
        (unsigned long long)result.source_size,result.exefs_verified,result.romfs_verified,result.asset_hashes_verified,result.romfs_structure_verified,
        result.version_identified ? "true":"false",result.title_version);
    hex(result.source_sha256);printf("\",\"inventorySHA256\":\"");hex(result.member_inventory_sha256);
    printf("\",\"progressCalls\":%u,\"reads\":%u}\n",progress_calls,reads);return 0;
}
