#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#import "CanopyStorage.h"
#import "CanopyShaderCache.h"
#include "mng_store.h"
#include "mng_crypto.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failSync;
int storage_probe_fsync(int fd) {if(failSync){failSync=0;errno=EIO;return -1;}return fsync(fd);}
int storage_probe_renameat(int from,const char *source,int to,const char *destination) {
    int result=renameat(from,source,to,destination);
    if(!result&&!strcmp(destination,"current")&&getenv("CANOPY_STORAGE_FAIL_CURRENT_SYNC"))failSync=1;
    return result;
}
static BOOL digest(const void *data,size_t n,unsigned char out[32]) {
    struct mng_sha256 *hash=NULL;BOOL ok=!mng_sha256_init(&hash)&&!mng_sha256_update(hash,data,n)&&!mng_sha256_final(hash,out);
    mng_sha256_free(hash);return ok;
}
static BOOL asset(struct mng_asset_sink *sink,const char *path,const char *bytes) {
    size_t n=strlen(bytes);unsigned char sha[32];return digest(bytes,n,sha)&&!sink->begin(sink->context,path,n)&&
        !sink->write(sink->context,bytes,n)&&!sink->end(sink->context,sha);
}
static struct mng_store *openStore(NSString *path) {
    int root=open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    struct mng_store *store=NULL;if(root>=0){(void)mng_store_open(root,&store);close(root);}return store;
}
static NSDictionary *seed(NSString *path) {
    struct mng_store *store=openStore(path);if(!store)return @{@"seeded":@NO};
    NSMutableArray *ids=[NSMutableArray new];BOOL ok=YES;
    for(unsigned i=1;i<=3&&ok;i++) {
        char job[33],payload[40],generation[65]={0};snprintf(job,sizeof(job),"%032x",i);snprintf(payload,sizeof(payload),"original synthetic fixture %u",i);
        ok=mng_store_begin(store,job)==MNG_PREPARE_OK;struct mng_asset_sink sink=mng_store_sink(store);
        struct mng_prepare_result result={0};result.title_id=UINT64_C(0x0100123456780000);result.source_size=1000;
        result.asset_count=3;result.asset_bytes=strlen(payload)+strlen("metadata")+strlen("romfs fixture");
        result.exefs_verified=1;result.romfs_verified=1;
        ok=ok&&digest(payload,strlen(payload),result.source_sha256)&&asset(&sink,"exefs/main",payload)&&
            asset(&sink,"exefs/main.npdm","metadata")&&asset(&sink,"romfs.bin","romfs fixture")&&
            mng_store_commit(store,&result,generation)==MNG_PREPARE_OK;
        if(ok)[ids addObject:[NSString stringWithUTF8String:generation]];
    }
    if(ok)ok=mng_store_begin(store,"ffffffffffffffffffffffffffffffff")==MNG_PREPARE_OK;
    mng_store_close(store);return @{@"seeded":ok?@YES:@NO,@"ids":ids};
}
static NSDictionary *waitFor(CanopyStorage *storage,BOOL action,CanopyStorageAction kind,NSString *identifier,NSString *title) {
    __block BOOL done=NO;__block NSDictionary *answer=nil;
    CanopyStorageCompletion completion=^(NSDictionary *snapshot,NSError *error){
        answer=@{@"snapshot":snapshot,@"error":error?@(error.code):@0,@"mainThread":NSThread.isMainThread?@YES:@NO,
            @"busyAtCompletion":storage.busy?@YES:@NO};done=YES;
    };
    BOOL accepted=action?[storage performAction:kind identifier:identifier titleID:title completion:completion]:[storage reloadWithCompletion:completion];
    if(!accepted)return @{@"accepted":@NO,@"busy":storage.busy?@YES:@NO};
    BOOL busy=storage.busy,second=[storage reloadWithCompletion:^(NSDictionary *s,NSError *e){(void)s;(void)e;}];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20];
    while(!done&&deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    if(!done)return @{@"timeout":@YES};
    NSMutableDictionary *report=[answer mutableCopy];report[@"accepted"]=@YES;report[@"busyDuringOperation"]=busy?@YES:@NO;report[@"secondAccepted"]=second?@YES:@NO;return report;
}
int main(int argc,const char **argv) {@autoreleasepool {
    if(argc<4)return 2;
    NSString *(^arg)(int)=^NSString *(int i){return [NSString stringWithUTF8String:argv[i]];};
    NSString *mode=arg(1),*prepared=arg(2),*caches=arg(3);NSDictionary *report=nil;
    CanopyStorage *storage=[[CanopyStorage alloc] initWithPreparedRootURL:[NSURL fileURLWithPath:prepared] cacheRootURL:[NSURL fileURLWithPath:caches]];
    if([mode isEqual:@"seed"])report=seed(prepared);
    else if([mode isEqual:@"reload"])report=waitFor(storage,NO,0,nil,nil);
    else if([mode isEqual:@"shaderSeed"]||[mode isEqual:@"shaderActive"]){
        if(argc!=7)return 2;
        NSURL *url=[NSURL fileURLWithPath:[caches stringByAppendingPathComponent:@"0100123456780000/shader-identities"]];
        CanopyShaderCache *cache=[[CanopyShaderCache alloc] initWithRootURL:url];NSError *error=nil;
        NSDictionary *device=@{@"schema":@1,@"platform":@"macos",@"os":@"original fixture OS",@"device":@"original fixture GPU",
            @"registry":@"0000000000000001",@"families":@[@1001],@"mathMode":@"safe",@"mslVersion":@"20300"};
        CanopyShaderCacheLease *lease=[cache prepareSeedURL:[NSURL fileURLWithPath:arg(4)] titleID:@"0100123456780000"
            sourceRomFSSHA256:arg(6) expectedManifestSHA256:arg(5) expectedChain:@"totk-native-v7-unverified" deviceIdentity:device cancelled:nil progress:nil error:&error];
        if(!lease)report=@{@"seeded":@NO,@"error":@(error.code)};
        else {
            NSMutableDictionary *result=[@{@"seeded":@YES,@"identity":lease.identityHash} mutableCopy];
            if([mode isEqual:@"shaderActive"]){result[@"clear"]=waitFor(storage,YES,CanopyStorageClearShaderRuntime,lease.identityHash,@"0100123456780000");
                result[@"remove"]=waitFor(storage,YES,CanopyStorageRemoveShaderIdentity,lease.identityHash,@"0100123456780000");
                result[@"heldIdentity"]=lease.identityHash;}
            report=result;
        }
    } else if([mode isEqual:@"locked"]){struct mng_store *held=openStore(prepared);report=waitFor(storage,NO,0,nil,nil);mng_store_close(held);}
    else if([mode isEqual:@"pinned"]){
        if(argc!=5)return 2;struct mng_store *held=openStore(prepared);int lease=-1;
        enum mng_prepare_status status=mng_store_pin(held,UINT64_C(0x0100123456780000),arg(4).UTF8String,&lease);mng_store_close(held);
        if(status!=MNG_PREPARE_OK)return 3;
        report=waitFor(storage,YES,CanopyStorageRemoveGeneration,arg(4),@"0100123456780000");close(lease);
    } else {
        if(argc!=6)return 2;
        NSArray *actions=@[@"verify",@"select",@"remove",@"discard",@"clearShader",@"removeShader"];
        NSUInteger action=[actions indexOfObject:mode];if(action==NSNotFound)return 2;
        report=waitFor(storage,YES,(CanopyStorageAction)action,arg(4),[arg(5) isEqual:@"-"]?nil:arg(5));
    }
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];
    if(!json)return 4;fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);return 0;
}}
