#import <Foundation/Foundation.h>
#import "CanopyPreparation.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void Check(BOOL condition,const char *message) {
    if(!condition){fprintf(stderr,"FAIL: %s\n",message);exit(1);}
}
int main(int argc,char **argv) {
    @autoreleasepool {
        Check(argc==6 || argc==7,"arguments");
        Check(NSThread.isMainThread,"main owner");
        NSString *mode=@(argv[1]);
        NSURL *source=[NSURL fileURLWithPath:@(argv[2])];
        NSURL *keys=[NSURL fileURLWithPath:@(argv[3])];
        NSURL *store=[NSURL fileURLWithPath:@(argv[4]) isDirectory:YES];
        NSString *identifier=strcmp(argv[5],"-") ? @(argv[5]):nil;
        NSURL *update=argc==7 ? [NSURL fileURLWithPath:@(argv[6])]:nil;
        CanopyPreparation *job=[[CanopyPreparation alloc] initWithPreparedRootURL:store];
        Check(!job.busy,"initial busy");
        __block BOOL completed=NO,cancelSent=NO;
        __block NSUInteger progressCalls=0;
        __block NSDictionary *result=nil;
        __block NSError *failure=nil;
        __weak CanopyPreparation *weakJob=job;
        job.progress=^(NSString *phase,uint64_t done,uint64_t total) {
            Check(NSThread.isMainThread,"progress thread");
            Check(phase.length>0 && done<=total,"progress values");
            progressCalls++;
            /* ExeFS assets are already complete when IVFC verification starts;
             * cancellation leaves a resumable job with real completed files. */
            if([mode isEqual:@"cancel"] && !cancelSent && [phase isEqual:(update ? @"hash-update-source":@"verify-ivfc")]) {
                cancelSent=YES;[weakJob cancel];
            }
        };
        BOOL started=[job startSourceURL:source updateURL:update keysURL:keys jobIdentifier:identifier
            completion:^(NSDictionary<NSString *,id> *value,NSError *error) {
                Check(NSThread.isMainThread,"completion thread");
                Check(!completed,"duplicate completion");
                Check(!weakJob.busy,"completion busy");
                result=value;failure=error;completed=YES;
            }];
        Check(started,"job rejected");
        Check(job.busy,"accepted job busy");
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
            @"cancel_sent":@(cancelSent),@"job":job.jobIdentifier ?: @""} mutableCopy];
        if(result)report[@"result"]=result;
        if(failure)report[@"error"]=@{@"domain":failure.domain,@"code":@(failure.code),
            @"description":failure.localizedDescription};
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
        Check(json!=nil,"JSON serialization");
        fwrite(json.bytes,1,json.length,stdout);putchar('\n');
    }
    return 0;
}
