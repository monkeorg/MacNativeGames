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
#include <errno.h>
#include <sys/file.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static void Check(BOOL value,const char *message) {if(!value){fprintf(stderr,"FAIL: %s\n",message);exit(1);}}
@interface FixtureGameView : NSObject
@property(nonatomic) CGRect bounds;
@end
@implementation FixtureGameView
@end
static const char *resourcePath,*romfsHash,*indexHash,*manifestHash,*heapHash,*layoutHash,*mode;
static uint32_t displayFlags;
static struct mng_display_config selectedDisplay;
static uint32_t displayValidation=MNG_DISPLAY_NOT_CONFIGURED;
static CGRect gameBounds;
static BOOL malformedDisplayState,malformedLifecycle;
static struct canopy_totk_lifecycle_state mainLifecycle;
static NSString *shaderLeasePath;
static void LeaseHeld(NSString *path) {
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    Check(fd>=0,"retained lease file exists");
    int locked=flock(fd,LOCK_EX|LOCK_NB),saved=errno;close(fd);
    Check(locked<0 && (saved==EWOULDBLOCK || saved==EAGAIN),"native attempt retains actual shared lease");
}
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
    struct mng_display_profile profile={MNG_DISPLAY_ABI,sizeof(profile),displayFlags};
    Check(!mng_display_check(&profile,&s->display,gameBounds.size.width,gameBounds.size.height),"actual native display config binding");
    selectedDisplay=s->display;displayValidation=MNG_DISPLAY_PENDING;
    shaderLeasePath=[[@(s->shader_cache) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@".lease"];
    mainLifecycle=(struct canopy_totk_lifecycle_state){CANOPY_TOTK_LIFECYCLE_ABI,sizeof(mainLifecycle),CANOPY_TOTK_MAIN_RUNNING,0,0,0,2,0,0,0,0};
    if(!strcmp(mode,"lifecycle-start-ended")) {
        mainLifecycle.phase=CANOPY_TOTK_MAIN_CLEANUP_OBSERVED;mainLifecycle.main_returned=1;
        mainLifecycle.main_return_code=17;mainLifecycle.guest_admission_closed=1;
    }
    if(!strcmp(mode,"lifecycle-start-invalid"))malformedLifecycle=YES;
    if(!strcmp(mode,"lifecycle-not-started"))mainLifecycle.phase=CANOPY_TOTK_MAIN_NOT_STARTED;
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
static int read_display(struct mng_display_state *state) {
    Check(NSThread.isMainThread,"native display state thread");
    if(!state || state->abi!=MNG_DISPLAY_ABI || state->size!=sizeof(*state))return -1;
    *state=(struct mng_display_state){MNG_DISPLAY_ABI,sizeof(*state),displayValidation,selectedDisplay};
    if(malformedDisplayState || !strcmp(mode,"display-bad-start-state"))state->size--;return 0;
}
/* Contract records exercise the consumer boundary. Actual pthread cleanup,
 * TLS completion, joins and owned child accounting have separate host probes. */
static int read_lifecycle(struct canopy_totk_lifecycle_state *state) {
    Check(NSThread.isMainThread,"native lifecycle query thread");
    if(!state || state->abi!=CANOPY_TOTK_LIFECYCLE_ABI || state->size!=sizeof(*state))return -1;
    *state=mainLifecycle;if(malformedLifecycle)state->size--;return 0;
}
const struct canopy_totk_host *totk_canopy_host_v1(void) {
    static struct canopy_totk_host host;
    if(!strcmp(mode,"unavailable"))return NULL;
    const char *version=displayFlags?"1.4.3":"original-fixture";
    if(!strcmp(mode,"display-v121-flags"))version="1.2.1";
    host=(struct canopy_totk_host){!strcmp(mode,"abi1")?1:CANOPY_TOTK_HOST_ABI,sizeof(host),UINT64_C(0x0100123456780000),version,
        !strcmp(mode,"wrong-main")?"0000000000000000000000000000000000000000000000000000000000000000":mainHash,
        !strcmp(mode,"wrong-romfs")?"0000000000000000000000000000000000000000000000000000000000000000":romfsHash,!strcmp(mode,"wrong-index")?"0000000000000000000000000000000000000000000000000000000000000000":indexHash,
        resourcePath,manifestHash,"original-fixture-chain",start,fps_supported,set_fps,get_fps,taa_supported,set_taa,get_taa,get_hud,cycle_hud,clear,set_focus,input,
        {MNG_DISPLAY_ABI,sizeof(struct canopy_totk_display),{MNG_DISPLAY_ABI,sizeof(struct mng_display_profile),displayFlags},
         displayFlags&MNG_DISPLAY_SCENE_1080?heapHash:NULL,displayFlags&MNG_DISPLAY_FOUR_THREE?layoutHash:NULL,read_display},
        {CANOPY_TOTK_LIFECYCLE_ABI,sizeof(struct canopy_totk_lifecycle),read_lifecycle}};
    if(!strcmp(mode,"lifecycle-bad-record"))host.lifecycle.size--;
    if(!strcmp(mode,"lifecycle-abi2"))host.abi_version=2;
    if(!strcmp(mode,"display-bad-record"))host.display.size--;
    if(!strcmp(mode,"display-bad-pin"))host.display.heap_manifest_sha256=NULL;
    return &host;
}
int main(int argc,char **argv) {
    @autoreleasepool {
        Check(argc==12,"arguments");mode=argv[1];resourcePath=argv[4];romfsHash=argv[7];indexHash=argv[8];manifestHash=argv[9];heapHash=argv[10];layoutHash=argv[11];
        if(!strncmp(mode,"overlay-",8) || !strcmp(mode,"display-1080") || !strcmp(mode,"display-unknown-aspect") || !strcmp(mode,"display-bad-pin") || !strcmp(mode,"display-v121-flags"))displayFlags=MNG_DISPLAY_SCENE_1080;
        if(!strncmp(mode,"display-full",12) || !strcmp(mode,"display-live"))displayFlags=MNG_DISPLAY_SCENE_1080|MNG_DISPLAY_FOUR_THREE;
        if(!strcmp(mode,"display-bad-flags"))displayFlags=8;
        gameBounds=CGRectMake(0,0,1024,576);
        if(!strcmp(mode,"display-full") || !strcmp(mode,"display-live") || !strcmp(mode,"display-stock-fallback"))gameBounds=CGRectMake(0,0,1024,768);
        if(!strcmp(mode,"display-full-fallback"))gameBounds=CGRectMake(0,0,1194,834);
        NSURL *root=[NSURL fileURLWithPath:@(argv[2]) isDirectory:YES];NSString *generation=@(argv[3]);
        NSURL *resources=[NSURL fileURLWithPath:@(resourcePath) isDirectory:YES];
        NSURL *profiles=[NSURL fileURLWithPath:@(argv[5]) isDirectory:YES];
        NSURL *saves=[profiles URLByAppendingPathComponent:@"active"],*identity=[profiles URLByAppendingPathComponent:@"identity"];
        NSURL *cache=[NSURL fileURLWithPath:@(argv[6]) isDirectory:YES];
        for(NSURL *url in @[saves,identity,cache])Check([NSFileManager.defaultManager createDirectoryAtURL:url
            withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL],"private directories");
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        BOOL deviceDependent=!strcmp(mode,"success") || !strcmp(mode,"entry-failure") || !strcmp(mode,"cache-reuse") || !strcmp(mode,"actual-shader-device") || !strcmp(mode,"cache-parent-alias") || !strcmp(mode,"display-1080") || !strcmp(mode,"display-full") ||
            !strcmp(mode,"display-full-fallback") || !strcmp(mode,"display-stock-fallback") || !strcmp(mode,"display-live") || !strcmp(mode,"display-bad-state") || !strcmp(mode,"display-bad-start-state") || !strcmp(mode,"display-unknown-aspect") || (!strncmp(mode,"lifecycle-",10) && strcmp(mode,"lifecycle-bad-record") && strcmp(mode,"lifecycle-abi2"));
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
        BOOL high=!strcmp(mode,"display-1080") || !strcmp(mode,"display-full") || !strcmp(mode,"display-full-fallback") || !strcmp(mode,"display-stock-fallback");
        BOOL full=!strcmp(mode,"display-full") || !strcmp(mode,"display-full-fallback") || !strcmp(mode,"display-stock-fallback");
        NSDictionary *settings=@{@"fpsLimit":@60,@"taa":@NO,@"hud":@1,@"language":@"en-US",@"renderHeight":high?@1080:@720,@"aspect":!strcmp(mode,"display-unknown-aspect")?@"21:9":full?@"display":@"16:9"};
        FixtureGameView *gameView=FixtureGameView.new;gameView.bounds=gameBounds;layer.bounds=gameBounds;
        __block BOOL completed=NO,started=NO;__block NSError *failure=nil;
        BOOL accepted=[runtime startTitleID:@"0100123456780000" generationID:generation hostAssetsURL:resources
            activeSavesURL:saves identityURL:identity cacheURL:cache settings:settings graphicsSurface:layer hostView:gameView
            error:&error completion:^(BOOL nativeStarted,NSError *e) {Check(NSThread.isMainThread,"completion owner");started=nativeStarted;failure=e;completed=YES;}];
        if(!strcmp(mode,"unavailable") || !strcmp(mode,"abi1") || !strcmp(mode,"display-bad-record") || !strcmp(mode,"display-bad-flags") ||
           !strcmp(mode,"display-bad-pin") || !strcmp(mode,"display-v121-flags") || !strcmp(mode,"lifecycle-bad-record") || !strcmp(mode,"lifecycle-abi2")) {
            Check(!accepted && !runtime.nativeEntryInvoked && error!=nil,"unavailable host refusal");
        } else {
            Check(accepted && [runtime.state isEqual:@"preparing"],"async native preflight");
            if(!strcmp(mode,"cancel"))Check([runtime cancelPreparation:&error],"preflight cancellation request");
            NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20];
            while(!completed && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            Check(completed,"native completion timeout");
            if(deviceDependent && !runtime.nativeEntryInvoked && failure)
                fprintf(stderr,"Native preflight refused: code=%ld message=%s\n",(long)failure.code,failure.localizedDescription.UTF8String);
            if(!strncmp(mode,"overlay-",8) || !strcmp(mode,"wrong-romfs") || !strcmp(mode,"corrupt-main") || !strcmp(mode,"corrupt-romfs") || !strcmp(mode,"wrong-main") || !strcmp(mode,"wrong-index") || !strcmp(mode,"corrupt-cache") || !strcmp(mode,"public-cache") || !strcmp(mode,"cache-leaf-symlink") || !strcmp(mode,"cancel")) {
                Check(!started && failure && !runtime.nativeEntryInvoked && starts==0,"pin mismatch reaches no native entry");
                Check([runtime close:&error],"preflight refusal permits seal release");
            } else if(!strcmp(mode,"entry-failure") || !strcmp(mode,"display-bad-start-state") ||
                      !strcmp(mode,"lifecycle-start-ended") || !strcmp(mode,"lifecycle-start-invalid") || !strcmp(mode,"lifecycle-not-started")) {
                Check(!started && failure && runtime.nativeEntryInvoked && starts==1,"native failure lifetime");
                Check(![runtime close:&error],"failed entry does not promise teardown");
                NSString *generationLease=[[[[root.path stringByAppendingPathComponent:@"titles/0100123456780000/generations"]
                    stringByAppendingPathComponent:generation] stringByAppendingPathComponent:@".lease"] copy];
                LeaseHeld(generationLease);LeaseHeld(shaderLeasePath);
                Check(!focus,"failed startup keeps native focus captured");
            } else if(!strncmp(mode,"lifecycle-",10)) {
                Check(started && !failure && runtime.nativeEntryInvoked && starts==1,"actual lifecycle-capable native startup");
                Check([runtime.diagnosticMetrics[@"mainWorkerPhase"] isEqual:@"running"],"main worker running evidence");
                Check([runtime restoreInput:&error] && focus,"live worker can receive focus");unsigned before=clears;
                mainLifecycle.phase=CANOPY_TOTK_MAIN_CLEANUP_OBSERVED;mainLifecycle.guest_admission_closed=1;
                mainLifecycle.owned_guest_children=2;mainLifecycle.joining_guest_children=1;
                if(!strcmp(mode,"lifecycle-returned")){mainLifecycle.main_returned=1;mainLifecycle.main_return_code=17;}
                if(!strcmp(mode,"lifecycle-joined")){mainLifecycle.phase=CANOPY_TOTK_MAIN_JOINED;mainLifecycle.main_joined=1;mainLifecycle.owned_guest_children=0;mainLifecycle.joining_guest_children=0;}
                if(!strcmp(mode,"lifecycle-join-error")){mainLifecycle.phase=CANOPY_TOTK_MAIN_OBSERVATION_FAILED;mainLifecycle.join_error=EINVAL;}
                if(!strcmp(mode,"lifecycle-invalid-state"))malformedLifecycle=YES;
                Check(![runtime tick:&error] && [runtime.state isEqual:@"failed"] && !focus && clears>before,"ended worker fails and captures real input/focus");
                Check(![runtime restoreInput:&error] && ![runtime close:&error] && !focus,"worker end never grants restore or teardown");
                NSDictionary *metrics=runtime.diagnosticMetrics;
                if(!strcmp(mode,"lifecycle-ended"))Check([metrics[@"mainWorkerPhase"] isEqual:@"cleanupObserved"] && ![metrics[@"mainJoined"] boolValue] &&
                    ![metrics[@"mainReturned"] boolValue] && [metrics[@"ownedGuestChildren"] unsignedIntValue]==2 && [metrics[@"joiningGuestChildren"] unsignedIntValue]==1,"cleanup is not TLS join or all-child completion");
                if(!strcmp(mode,"lifecycle-returned"))Check([metrics[@"mainReturned"] boolValue] && [metrics[@"mainReturnCode"] intValue]==17,"native function return status is distinct");
                if(!strcmp(mode,"lifecycle-joined"))Check([metrics[@"mainWorkerPhase"] isEqual:@"mainJoined"] && [metrics[@"mainJoined"] boolValue] && ![runtime close:&error],"real main join plus zero child subset is not full stop");
                if(!strcmp(mode,"lifecycle-join-error"))Check([metrics[@"mainWorkerPhase"] isEqual:@"observationFailed"] && ![metrics[@"mainJoined"] boolValue] && [metrics[@"mainJoinError"] unsignedIntValue]==EINVAL,"join failure is not join completion");
                if(!strcmp(mode,"lifecycle-invalid-state"))Check([metrics[@"mainWorkerPhase"] isEqual:@"unavailable"],"malformed lifecycle record not trusted");
                NSDictionary *refused=[runtime applyDesiredSettings:@{@"fpsLimit":@30}];
                Check([refused[@"fpsLimit"][@"state"] isEqual:@"rejected"] && fps==60,"ended worker settings are not applied");
                NSString *generationLease=[[[root.path stringByAppendingPathComponent:@"titles/0100123456780000/generations"]
                    stringByAppendingPathComponent:generation] stringByAppendingPathComponent:@".lease"];
                LeaseHeld(generationLease);LeaseHeld(shaderLeasePath);
            } else if(!strncmp(mode,"display-",8)) {
                Check(started && !failure && runtime.nativeEntryInvoked && starts==1,"actual native display callback");
                if(!strcmp(mode,"display-bad-state")) {
                    malformedDisplayState=YES;
                    Check(![runtime tick:&error] && error!=nil,"malformed native display state refusal");
                    Check([runtime.settingStates[@"renderHeight"][@"state"] isEqual:@"rejected"],"malformed display state not applied");
                } else {
                    Check([runtime.settingStates[@"renderHeight"][@"validation"] isEqual:@"pending"],"startup configuration is not checked patch evidence");
                    if(!strcmp(mode,"display-full"))Check(selectedDisplay.width==1440 && selectedDisplay.height==1080 && selectedDisplay.experimental,"experimental exact4:3 target");
                    if(!strcmp(mode,"display-1080"))Check(selectedDisplay.width==1920 && selectedDisplay.height==1080 && !selectedDisplay.experimental,"1080 16:9 selected target");
                    if(!strcmp(mode,"display-unknown-aspect"))Check([runtime.settingStates[@"aspect"][@"state"] isEqual:@"unsupported"] && selectedDisplay.aspect==MNG_DISPLAY_16_9,"unknown aspect explicit fallback");
                    if(!strcmp(mode,"display-full-fallback"))Check([runtime.settingStates[@"aspect"][@"state"] isEqual:@"unsupported"] && selectedDisplay.width==1920 && selectedDisplay.aspect==MNG_DISPLAY_16_9,"non4:3 full aspect explicit fallback");
                    if(!strcmp(mode,"display-stock-fallback"))Check([runtime.settingStates[@"renderHeight"][@"state"] isEqual:@"unsupported"] && [runtime.settingStates[@"aspect"][@"state"] isEqual:@"unsupported"] && selectedDisplay.height==720 && !selectedDisplay.fixed_resolution,"stock explicit fallback and dynamic scene distinction");
                    if(!strcmp(mode,"display-live")) {
                        NSDictionary *outcomes=[runtime applyDesiredSettings:@{@"renderHeight":@1080,@"aspect":@"display"}];
                        Check([outcomes[@"renderHeight"][@"state"] isEqual:@"restartRequired"] && [outcomes[@"aspect"][@"state"] isEqual:@"restartRequired"],"live display target needs new process");
                        Check([outcomes[@"renderHeight"][@"effectiveValue"] isEqual:@720] && [outcomes[@"aspect"][@"effectiveValue"] isEqual:@"16:9"] && selectedDisplay.width==1280 && selectedDisplay.height==720,"live display preserves selected target");
                    }
                    displayValidation=MNG_DISPLAY_PATCHES_VALIDATED;
                    Check([runtime tick:&error] && [runtime.settingStates[@"renderHeight"][@"validation"] isEqual:@"patchesValidated"],"only native callback reports checked patches");
                    Check([runtime.diagnosticMetrics[@"displayValidation"] isEqual:@"patchesValidated"],"display evidence diagnostics");
                }
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
