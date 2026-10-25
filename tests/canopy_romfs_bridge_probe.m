#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#import <Foundation/Foundation.h>
#import "CanopyRomFS.h"
#include "mng_crypto.h"
#include "mng_keys.h"
#include "mng_prepare.h"
#include "mng_store.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void Check(BOOL condition,const char *label) {
    if (!condition) { fprintf(stderr,"FAIL: %s\n",label);exit(1); }
}
/* Only fixture seeding uses source/keys; CanopyRomFS consumes the real native
 * store's verified immutable generation, never an arbitrary input-file flag. */
static void Seed(const char *source,const char *keyfile,const char *root,
    struct mng_prepare_result *prepared,char generation[65]) {
    Check(!mkdir(root,0700) || errno==EEXIST,"private store root");
    int directory=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    struct mng_store *store=NULL;
    Check(directory>=0 && mng_store_open(directory,&store)==MNG_PREPARE_OK,"store open");close(directory);
    FILE *file=fopen(keyfile,"rb");Check(file!=NULL,"invented keys");
    unsigned char bytes[4096];size_t size=fread(bytes,1,sizeof(bytes),file);Check(!ferror(file) && feof(file),"key read");fclose(file);
    struct mng_keys *keys=NULL;Check(mng_keys_parse(bytes,size,&keys)==0,"key parse");mng_secure_clear(bytes,sizeof(bytes));
    Check(mng_store_begin(store,"abababababababababababababababab")==MNG_PREPARE_OK,"begin seed");
    struct mng_key_provider provider=mng_keys_provider(keys);struct mng_asset_sink sink=mng_store_sink(store);
    int fd=open(source,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);Check(fd>=0,"source open");
    Check(mng_prepare_fd(fd,&provider,&sink,prepared)==MNG_PREPARE_OK,"real native prepare");close(fd);mng_keys_free(keys);
    Check(mng_store_commit(store,prepared,generation)==MNG_PREPARE_OK,"seed commit");mng_store_close(store);
}
int main(int argc,char **argv) {
    @autoreleasepool {
        Check(argc==6,"arguments");
        NSString *mode=@(argv[5]);struct mng_prepare_result prepared={0};char generation[65]={0};
        Seed(argv[1],argv[2],argv[3],&prepared,generation);
        if ([mode isEqual:@"sourcecorrupt"]) {
            char path[4096];snprintf(path,sizeof(path),"%s/titles/%016llx/generations/%s/romfs.bin",argv[3],
                (unsigned long long)prepared.title_id,generation);
            int fd=open(path,O_RDONLY|O_NOFOLLOW);Check(fd>=0 && !fchmod(fd,0600),"fixture write permission");close(fd);
            fd=open(path,O_RDWR|O_NOFOLLOW);Check(fd>=0,"fixture corrupt source open");
            unsigned char byte;Check(pread(fd,&byte,1,100)==1,"fixture byte");byte^=1;
            Check(pwrite(fd,&byte,1,100)==1 && !fchmod(fd,0400),"fixture corruption");close(fd);
        }
        CanopyRomFS *bridge=[[CanopyRomFS alloc]
            initWithPreparedRootURL:[NSURL fileURLWithPath:@(argv[3]) isDirectory:YES]
            derivedRootURL:[NSURL fileURLWithPath:@(argv[4]) isDirectory:YES]];
        __block BOOL done=NO,cancelled=NO;
        __block NSUInteger reports=0;__block NSURL *folder=nil;__block NSError *error=nil;
        __weak CanopyRomFS *weakBridge=bridge;
        bridge.progress=^(NSString *phase,uint64_t count,uint64_t total) {
            Check(NSThread.isMainThread && count<=total && phase.length>0,"progress contract");reports++;
            if (!cancelled && (([mode isEqual:@"cancel"] && [phase isEqual:@"materialize-private-folder"] && count>0) ||
                              ([mode isEqual:@"cancelverify"] && [phase isEqual:@"verify-private-folder"]))) {
                cancelled=YES;[weakBridge cancel];
            }
        };
        BOOL accepted=[bridge materializeTitleID:prepared.title_id generationID:@(generation)
            completion:^(NSURL *value,NSError *failure) {
                Check(NSThread.isMainThread && !done && !weakBridge.busy,"completion contract");
                folder=value;error=failure;done=YES;
            }];
        Check(accepted && bridge.busy,"start");
        if ([mode isEqual:@"busy"]) Check(![bridge materializeTitleID:prepared.title_id generationID:@(generation)
            completion:^(NSURL *unused,NSError *failure) { (void)unused;(void)failure;Check(NO,"rejected callback"); }],"busy refusal");
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20];
        while (!done && deadline.timeIntervalSinceNow>0) {
            @autoreleasepool { [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]]; }
        }
        Check(done,"completion deadline");
        if ([mode isEqual:@"success"] || [mode isEqual:@"busy"]) Check(folder && !error,"successful folder");
        else Check(!folder && error,"expected safe refusal");
        if ([mode isEqual:@"cancel"] || [mode isEqual:@"cancelverify"]) Check(cancelled,"deterministic cancellation");
        NSMutableDictionary *output=[@{@"status":@"pass",@"generation":@(generation),
            @"title":[NSString stringWithFormat:@"%016llx",(unsigned long long)prepared.title_id],
            @"progress_calls":@(reports),@"cancel_sent":@(cancelled)} mutableCopy];
        if (folder) output[@"folder"]=folder.path;
        if (error) output[@"error"]=@{@"code":@(error.code),@"description":error.localizedDescription};
        NSData *json=[NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingSortedKeys error:NULL];
        Check(json!=nil,"JSON");fwrite(json.bytes,1,json.length,stdout);putchar('\n');
    }
    return 0;
}
