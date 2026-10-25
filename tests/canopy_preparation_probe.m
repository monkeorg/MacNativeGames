#import <Foundation/Foundation.h>
#import "CanopyPreparation.h"
#include <stdio.h>
#include <errno.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

static int failSync,lateCancelSync,lateCancelTriggered;
static __weak CanopyPreparation *activeJob;
int preparation_probe_fsync(int fd) {
    if(lateCancelSync){lateCancelSync=0;dispatch_sync(dispatch_get_main_queue(),^{[activeJob cancel];lateCancelTriggered=1;});}
    if(failSync){failSync=0;errno=EIO;return -1;}
    return fsync(fd);
}
int preparation_probe_renameat(int from,const char *source,int to,const char *destination) {
    int result=renameat(from,source,to,destination);
    if(!result&&!strcmp(destination,"current")){
        if(getenv("CANOPY_PREPARATION_FAIL_CURRENT_SYNC"))failSync=1;
        if(getenv("CANOPY_PREPARATION_CANCEL_AFTER_CURRENT"))lateCancelSync=1;
    }
    return result;
}
static void Check(BOOL condition,const char *message) {
    if(!condition){fprintf(stderr,"FAIL: %s\n",message);exit(1);}
}
int main(int argc,char **argv) {
    @autoreleasepool {
        Check(argc==6 || argc==7 || argc==9,"arguments");
        Check(NSThread.isMainThread,"main owner");
        NSString *mode=@(argv[1]);
        BOOL addon=[mode hasPrefix:@"addon-"];if(addon)mode=[mode substringFromIndex:6];
        BOOL folder=[mode hasPrefix:@"folder-"];
        if(folder)mode=[mode substringFromIndex:7];
        NSURL *source=[NSURL fileURLWithPath:@(argv[2])];
        NSURL *keys=strcmp(argv[3],"-") ? [NSURL fileURLWithPath:@(argv[3])]:nil;
        NSURL *store=[NSURL fileURLWithPath:@(argv[4]) isDirectory:YES];
        NSString *identifier=strcmp(argv[5],"-") ? @(argv[5]):nil;
        NSURL *update=argc==7 ? [NSURL fileURLWithPath:@(argv[6])]:nil;
        CanopyPreparation *job=[[CanopyPreparation alloc] initWithPreparedRootURL:store];
        Check(!job.busy,"initial busy");activeJob=job;
        __block BOOL completed=NO,cancelSent=NO;
        __block NSUInteger progressCalls=0,copyFinishes=0;
        __block NSDictionary *result=nil;
        __block NSError *failure=nil;
        __weak CanopyPreparation *weakJob=job;
        job.progress=^(NSString *phase,uint64_t done,uint64_t total) {
            Check(NSThread.isMainThread,"progress thread");
            Check(phase.length>0 && done<=total,"progress values");
            progressCalls++;
            /* ExeFS assets are already complete when IVFC verification starts;
             * cancellation leaves a resumable job with real completed files. */
            if(folder && [phase isEqual:@"copy-plaintext-assets"] && done==total)copyFinishes++;
            BOOL cancelPhase=[phase isEqual:(addon ? @"hash-addon-source" : update ? @"hash-update-source":@"verify-ivfc")] ||
                (folder && [phase isEqual:@"copy-plaintext-assets"] && copyFinishes>=2);
            if([mode isEqual:@"cancel"] && !cancelSent && cancelPhase) {
                cancelSent=YES;[weakJob cancel];
            }
        };
        void (^completion)(NSDictionary<NSString *,id> * _Nullable,NSError * _Nullable)=^(NSDictionary<NSString *,id> *value,NSError *error) {
                Check(NSThread.isMainThread,"completion thread");
                Check(!completed,"duplicate completion");
                Check(!weakJob.busy,"completion busy");
                result=value;failure=error;completed=YES;
            };
        BOOL started=addon ? [job startAddonURL:source keysURL:keys applicationID:@(argv[6]) baseGenerationID:@(argv[7]) addonTitleID:@(argv[8]) jobIdentifier:identifier completion:completion] : folder ? [job startFolderURL:source keysURL:keys jobIdentifier:identifier completion:completion] :
            [job startSourceURL:source updateURL:update keysURL:keys jobIdentifier:identifier completion:completion];
        if([mode isEqual:@"invalid"]){Check(!started&&!job.busy&&!completed,"invalid add-on accepted");puts("{\"status\":\"pass\",\"rejected\":true}");return 0;}
        Check(started,"job rejected");
        Check(job.busy,"accepted job busy");
        if([mode isEqual:@"cancel-immediate"]) {cancelSent=YES;[job cancel];}
        Check(job.jobIdentifier.length==32,"assigned job identity");
        if(identifier)Check([job.jobIdentifier isEqual:identifier],"explicit job identity");
        if([mode isEqual:@"busy"]) {
            Check(![job startSourceURL:source keysURL:keys jobIdentifier:nil
                completion:^(NSDictionary<NSString *,id> *unused,NSError *error) {
                    (void)unused;(void)error;Check(NO,"rejected job completion");
                }],"concurrent job accepted");
        }
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20];
        while(!completed && deadline.timeIntervalSinceNow>0) {
            @autoreleasepool {
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            }
        }
        Check(completed,"completion deadline");
        if([mode isEqual:@"success"] || [mode isEqual:@"busy"]) {
            Check(result!=nil && failure==nil,"successful preparation");
            Check(progressCalls>0,"native progress absent");
        } else {
            Check(result==nil && failure!=nil,"failure publication");
            if([mode isEqual:@"cancel"])Check(cancelSent,"cancellation progress absent");
        }
        NSMutableDictionary *report=[@{@"status":@"pass",@"progress_calls":@(progressCalls),
            @"cancel_sent":@(cancelSent),@"late_cancel":lateCancelTriggered ? @YES : @NO,@"job":job.jobIdentifier ?: @""} mutableCopy];
        if(result)report[@"result"]=result;
        if(failure){NSMutableDictionary *error=[@{@"domain":failure.domain,@"code":@(failure.code),@"description":failure.localizedDescription} mutableCopy];
            for(NSString *key in @[@"jobID",@"commitAttempted",@"publicationUncertain",@"reloadRequired",@"currentReadable",@"currentGenerationID"]){
                if(failure.userInfo[key])error[key]=failure.userInfo[key];
            }
            report[@"error"]=error;
        }
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
        Check(json!=nil,"JSON serialization");
        fwrite(json.bytes,1,json.length,stdout);putchar('\n');
    }
    return 0;
}
