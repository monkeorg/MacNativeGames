/* Original-source host consumer: verifies production adapter calls and paths.
 * This fixture is not evidence that commercial TOTK code ran. */
#import <Foundation/Foundation.h>
#import "CanopyRuntime.h"
#import "CanopyShaderCache.h"
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#include "../games/totk/runtime/canopy_host.h"
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static void Check(BOOL value,const char *message) {if(!value){fprintf(stderr,"FAIL: %s\n",message);exit(1);}}
static const char *resourcePath,*romfsHash,*indexHash,*manifestHash,*mode;
static unsigned starts,fps=60,clears,inputs;
static uint64_t expectedButtons=1;
static int32_t expectedLX=16384;
static int expectedConnected=1;
static int taa,hud=1,focus=1;
static const char *mainHash="304100cd4db5f85f0804e00866a37143a7ca214d5b4c09d99fef829cb8b0a344";
static BOOL PhysicalDirectory(const char *path) {
    if(!path || path[0]!='/' || strlen(path)>=4096)return NO;
    char copy[4096];strcpy(copy,path);char *part=copy+1;
    int fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    while(fd>=0 && *part) {
        char *slash=strchr(part,'/');if(slash)*slash=0;
        if(*part) {int child=openat(fd,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);close(fd);fd=child;}
        if(!slash)break;part=slash+1;
    }
    BOOL valid=fd>=0;if(fd>=0)close(fd);return valid;
}
static int start(const struct canopy_totk_start *s) {
    Check(NSThread.isMainThread,"native attach thread");
    Check(s->metal_layer && s->host_view && s->metal_device,"native graphics target");
    Check(((__bridge CAMetalLayer *)s->metal_layer).device==(__bridge id<MTLDevice>)s->metal_device,"exact cache/renderer device handoff");
    Check(!strcmp(s->resources,resourcePath),"trusted resource path");
    NSString *index=[@(s->index_directory) stringByAppendingPathComponent:@"runtime-index.bin"];
    Check([NSFileManager.defaultManager fileExistsAtPath:index],"actual derived runtime index");
    Check(strstr(s->active_saves,"active") && strstr(s->identity,"identity"),"separate native save paths");
    Check([NSFileManager.defaultManager fileExistsAtPath:[@(s->shader_seed) stringByAppendingPathComponent:@"shader_map.tsv"]],"verified shader seed binding");
    Check([NSFileManager.defaultManager fileExistsAtPath:@(s->shader_cache)],"separate mutable shader cache");
    Check(PhysicalDirectory(s->shader_cache) && PhysicalDirectory(s->shader_seed),"native shader paths contain no linked components");
    fps=s->fps_limit;taa=s->taa_enabled;hud=s->hud_mode;focus=0;starts++;
    return !strcmp(mode,"entry-failure") ? -1:0;
}
static int fps_supported(unsigned n) {return n==30 || n==60;}
static void set_fps(unsigned n) {fps=n;}
static unsigned get_fps(void) {return fps;}
static int taa_supported(void) {return 1;}
static void set_taa(int value) {taa=value;}
static int get_taa(void) {return taa;}
static int get_hud(void) {return hud;}
static int cycle_hud(void) {hud=(hud+1)%3;return hud;}
static void clear(void) {clears++;}
static void set_focus(int value) {focus=value;}
static void input(uint64_t buttons,int32_t lx,int32_t ly,int32_t rx,int32_t ry,int connected) {
    Check(buttons==expectedButtons && lx==expectedLX && !ly && !rx && !ry && connected==expectedConnected,"native player input");inputs++;
}
const struct canopy_totk_host *totk_canopy_host_v1(void) {
    static struct canopy_totk_host host;
    if(!strcmp(mode,"unavailable"))return NULL;
    host=(struct canopy_totk_host){1,sizeof(host),UINT64_C(0x0100123456780000),"original-fixture",
        !strcmp(mode,"wrong-main")?"0000000000000000000000000000000000000000000000000000000000000000":mainHash,
        romfsHash,!strcmp(mode,"wrong-index")?"0000000000000000000000000000000000000000000000000000000000000000":indexHash,
        resourcePath,manifestHash,"original-fixture-chain",start,fps_supported,set_fps,get_fps,taa_supported,set_taa,get_taa,get_hud,cycle_hud,clear,set_focus,input};
    return &host;
}
int main(int argc,char **argv) {
    @autoreleasepool {
        Check(argc==10,"arguments");mode=argv[1];resourcePath=argv[4];romfsHash=argv[7];indexHash=argv[8];manifestHash=argv[9];
        NSURL *root=[NSURL fileURLWithPath:@(argv[2]) isDirectory:YES];NSString *generation=@(argv[3]);
        NSURL *resources=[NSURL fileURLWithPath:@(resourcePath) isDirectory:YES];
        NSURL *profiles=[NSURL fileURLWithPath:@(argv[5]) isDirectory:YES];
        NSURL *saves=[profiles URLByAppendingPathComponent:@"active"],*identity=[profiles URLByAppendingPathComponent:@"identity"];
        NSURL *cache=[NSURL fileURLWithPath:@(argv[6]) isDirectory:YES];
        for(NSURL *url in @[saves,identity,cache])Check([NSFileManager.defaultManager createDirectoryAtURL:url
            withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL],"private directories");
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        BOOL deviceDependent=!strcmp(mode,"success") || !strcmp(mode,"entry-failure") || !strcmp(mode,"cache-reuse") || !strcmp(mode,"actual-shader-device") || !strcmp(mode,"cache-parent-alias");
        if(!device && deviceDependent){puts("{\"status\":\"skip\",\"reason\":\"No actual native Metal device is available\"}");return 0;}
        if(!strcmp(mode,"actual-shader-device")) {
            NSError *shaderError=nil;
            NSDictionary *deviceIdentity=[CanopyShaderCache deviceIdentityForDevice:device error:&shaderError];
            Check(deviceIdentity!=nil,"actual shader device identity");
            CanopyShaderCache *shaderCache=[[CanopyShaderCache alloc] initWithRootURL:[cache URLByAppendingPathComponent:@"actual-device" isDirectory:YES]];
            CanopyShaderCacheLease *lease=[shaderCache prepareSeedURL:[resources URLByAppendingPathComponent:@"shader-seed" isDirectory:YES]
                titleID:@"0100123456780000" sourceRomFSSHA256:@(romfsHash) expectedManifestSHA256:@(manifestHash)
                expectedChain:@"original-fixture-chain" deviceIdentity:deviceIdentity cancelled:nil progress:nil error:&shaderError];
            if(!lease)fprintf(stderr,"Actual-device shader verification refused: stage=%lu\n",(unsigned long)[shaderError.userInfo[@"verificationStage"] unsignedIntegerValue]);
            Check(lease!=nil,"actual device shader seed import");
            Check(lease.metrics[@"seedCopiedBytes"]!=nil,"actual device shader seed metrics");
            puts("{\"status\":\"pass\",\"starts\":0,\"nativeEntryInvoked\":false}");return 0;
        }
        CAMetalLayer *layer=CAMetalLayer.layer;layer.device=device;
        CanopyRuntime *runtime=[[CanopyRuntime alloc] initWithPreparedRootURL:root];NSError *error=nil;
        NSDictionary *settings=@{@"fpsLimit":@60,@"taa":@NO,@"hud":@1,@"language":@"en-US",@"aspect":@"16:9"};
        __block BOOL completed=NO,started=NO;__block NSError *failure=nil;
        BOOL accepted=[runtime startTitleID:@"0100123456780000" generationID:generation hostAssetsURL:resources
            activeSavesURL:saves identityURL:identity cacheURL:cache settings:settings graphicsSurface:layer hostView:NSObject.new
            error:&error completion:^(BOOL nativeStarted,NSError *e) {Check(NSThread.isMainThread,"completion owner");started=nativeStarted;failure=e;completed=YES;}];
        if(!strcmp(mode,"unavailable")) {
            Check(!accepted && !runtime.nativeEntryInvoked && error!=nil,"unavailable host refusal");
        } else {
            Check(accepted && [runtime.state isEqual:@"preparing"],"async native preflight");
            if(!strcmp(mode,"cancel"))Check([runtime cancelPreparation:&error],"preflight cancellation request");
            NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20];
            while(!completed && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            Check(completed,"native completion timeout");
            if(deviceDependent && !runtime.nativeEntryInvoked && failure)
                fprintf(stderr,"Native preflight refused: code=%ld message=%s\n",(long)failure.code,failure.localizedDescription.UTF8String);
            if(!strcmp(mode,"wrong-main") || !strcmp(mode,"wrong-index") || !strcmp(mode,"corrupt-cache") || !strcmp(mode,"public-cache") || !strcmp(mode,"cache-leaf-symlink") || !strcmp(mode,"cancel")) {
                Check(!started && failure && !runtime.nativeEntryInvoked && starts==0,"pin mismatch reaches no native entry");
                Check([runtime close:&error],"preflight refusal permits seal release");
            } else if(!strcmp(mode,"entry-failure")) {
                Check(!started && failure && runtime.nativeEntryInvoked && starts==1,"native failure lifetime");
                Check(![runtime close:&error],"failed entry does not promise teardown");
            } else {
                Check(started && !failure && runtime.nativeEntryInvoked && starts==1,"actual native callback");
                Check([runtime.state isEqual:@"inputCaptured"],"startup begins with input captured");
                NSDictionary *outcomes=[runtime applyDesiredSettings:@{@"fpsLimit":@30,@"taa":@YES,@"hud":@2,@"language":@"de",@"renderHeight":@1080}];
                Check(fps==30 && taa==1 && hud==2,"actual native settings callbacks");
                Check([runtime.diagnosticMetrics[@"nativeEntryInvoked"] boolValue] &&
                    [runtime.diagnosticMetrics[@"frameLimit"] unsignedIntValue]==30 &&
                    runtime.diagnosticMetrics[@"seedCopiedBytes"]!=nil,"actual configuration/import diagnostics");
                Check([outcomes[@"language"][@"state"] isEqual:@"restartRequired"] && [outcomes[@"renderHeight"][@"state"] isEqual:@"unsupported"],"honest setting timing");
                Check([runtime captureInput:&error] && clears>0 && !focus,"native input capture");
                Check([runtime restoreInput:&error] && focus,"native input restoration");
                struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);
                struct mng_session_input snapshot={0};snapshot.sequence=1;snapshot.timestamp_ns=(uint64_t)t.tv_sec*1000000000+(uint64_t)t.tv_nsec;
                snapshot.players[0]=(struct mng_player_input){101,1,0.5f,0,0,0,1};
                Check([runtime submitInput:&snapshot error:&error] && inputs==1,"actual native input callback");
                Check(![runtime submitInput:&snapshot error:&error],"stale input refused");
                const unsigned native_bits[16]={0,1,2,3,6,7,8,9,10,11,4,5,13,15,12,14};
                snapshot.players[0].left_x=0;expectedLX=0;
                for(unsigned bit=0;bit<16;bit++) {
                    snapshot.sequence++;snapshot.players[0].buttons=UINT64_C(1)<<bit;
                    expectedButtons=UINT64_C(1)<<native_bits[bit];
                    Check([runtime submitInput:&snapshot error:&error],"portable button conversion");
                }
                for(unsigned bit=16;bit<18;bit++) {
                    snapshot.sequence++;snapshot.players[0].buttons=UINT64_C(1)<<bit;
                    Check(![runtime submitInput:&snapshot error:&error],"unsupported Home/Capture refusal");
                }
                Check(inputs==17,"individual native button callback count");
                unsigned beforeDisconnect=clears;
                snapshot.sequence++;snapshot.players[0]=(struct mng_player_input){0};
                expectedButtons=0;expectedConnected=0;
                Check([runtime submitInput:&snapshot error:&error] && clears>beforeDisconnect,"disconnect clears queued native edges");
                Check(![runtime pause:YES error:&error] && ![runtime close:&error],"unsupported CPU pause and teardown honest");
            }
        }
        NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"status":@"pass",@"starts":@(starts),@"nativeEntryInvoked":@(runtime.nativeEntryInvoked)} options:0 error:NULL];
        fwrite(json.bytes,1,json.length,stdout);putchar('\n');
    }
    return 0;
}
