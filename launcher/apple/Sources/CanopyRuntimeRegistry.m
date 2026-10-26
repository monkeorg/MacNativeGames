#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#import "CanopyRuntimeRegistry.h"
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#include "mng_apple_host.h"
#include "mng_store.h"
#include <CoreFoundation/CoreFoundation.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#if !defined(CANOPY_MK8DX_HOST)
__attribute__((weak,noinline)) const struct mng_apple_host *canopy_mk8dx_host_v1(void){return NULL;}
#endif
/* Shared by the unchanged TOTK ABI3 path and this additive backend. A consumed
 * owner is intentionally retained for the rest of the process lifetime. */
static CanopyRuntime *processOwner;
BOOL CanopyRuntimeProcessOccupied(void){NSCAssert(NSThread.isMainThread,@"Native ownership belongs on main");return processOwner!=nil;}
BOOL CanopyRuntimeClaimProcess(CanopyRuntime *owner){NSCAssert(NSThread.isMainThread,@"Native ownership belongs on main");if(![owner isKindOfClass:CanopyRuntime.class]||owner.nativeEntryInvoked||processOwner)return NO;processOwner=owner;return YES;}
void CanopyRuntimeReleaseBeforeEntry(CanopyRuntime *owner){NSCAssert(NSThread.isMainThread,@"Native ownership belongs on main");if(processOwner==owner&&!owner.nativeEntryInvoked)processOwner=nil;}
static NSString *ARString(const char *s){return s?[NSString stringWithUTF8String:s]:nil;}
static BOOL ARHex(NSString *s,NSUInteger length){return [s isKindOfClass:NSString.class]&&s.length==length&&[s rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;}
static BOOL ARPin(const char *s){NSString *v=ARString(s);return ARHex(v,64)&&![v isEqual:[@"" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0]];}
static NSError *ARError(NSInteger code){return [NSError errorWithDomain:@"CanopyRuntime" code:code userInfo:@{NSLocalizedDescriptionKey:code==7?@"Native preparation was cancelled before entry.":code==6?@"This native host retains its session protections and cannot stop or relaunch.":@"The compiled native host, private inputs or session state could not be verified."}];}
static const struct mng_apple_host *ARHost(void){
    const struct mng_apple_host *h=canopy_mk8dx_host_v1();
    const char *names[]={"main","subsdk0","sdk"};
    const char *builds[]={"2c336a9bcf79c3040ce506cdd391b578","d9de423efc1512328c3c05378c7cb031","ba520906609c503227871a314a94fb5f"};
    if(!h||h->abi!=MNG_APPLE_HOST_ABI||h->size!=sizeof(*h)||h->title_id!=UINT64_C(0x0100152000022000)||h->title_version!=1441792||
        ![ARString(h->game_version) isEqual:@"4.0.0"]||h->max_players!=4||h->module_count!=3||!h->romfs_size||h->romfs_size>MNG_STORE_MAX_BYTES||
        !ARPin(h->romfs_sha256)||!ARPin(h->source_recipe_sha256)||!ARPin(h->native_manifest_sha256)||!ARPin(h->shader_manifest_sha256)||!ARString(h->shader_chain).length||ARString(h->shader_chain).length>128||
        !h->prepare||!h->release_prepared||!h->start||!h->read_lifecycle||!h->clear_input||!h->set_focus||!h->submit_players||!h->update_layout)return NULL;
    for(unsigned i=0;i<3;i++)if(!h->modules[i].name||strcmp(h->modules[i].name,names[i])||!ARPin(h->modules[i].original_sha256)||
        !h->modules[i].build_id||strcmp(h->modules[i].build_id,builds[i]))return NULL;
    return h;
}
static NSURL *ARPhysical(NSURL *url){char physical[PATH_MAX];if(!url.isFileURL||!realpath(url.fileSystemRepresentation,physical))return nil;return [NSURL fileURLWithFileSystemRepresentation:physical isDirectory:YES relativeToURL:nil];}
static NSURL *ARResources(const struct mng_apple_host *h){return ARPhysical(h->resource_directory?[NSURL fileURLWithPath:ARString(h->resource_directory) isDirectory:YES]:[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"GameData/MK8DX" isDirectory:YES]);}
static NSDictionary *ARCapabilities(BOOL available){return @{@"available":available?@YES:@NO,@"singleUse":@YES,@"canStop":@NO,@"canPauseCPU":@NO,@"canCaptureInput":available?@YES:@NO,@"maxPlayers":@(available?4:0),@"hostOwnsRenderLoop":@YES,@"localFullKey":available?@YES:@NO,@"networkMultiplayer":@NO,@"cacheManagementAvailable":@NO,@"cacheManagementMessage":@"MK8DX provider cache management is not yet available."};}
NSDictionary *CanopyAppleTrustedProfile(NSString *titleID){const struct mng_apple_host *h=ARHost();if(!h||![titleID isEqual:@"0100152000022000"])return nil;NSURL *assets=ARResources(h);if(!assets)return nil;NSMutableDictionary *p=[ARCapabilities(YES) mutableCopy];p[@"titleID"]=titleID;p[@"version"]=@"4.0.0";p[@"hostAssetsURL"]=assets;return p;}
static int AROpenPrivate(NSURL *url){if(!url.isFileURL)return -1;NSString *path=url.path;for(NSString *alias in @[@"/var",@"/tmp"])if([path hasPrefix:[alias stringByAppendingString:@"/"]]){path=[@"/private" stringByAppendingString:path];break;}int fd=open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW_ANY|O_CLOEXEC);struct stat st;if(fd>=0&&(fstat(fd,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=geteuid()||(st.st_mode&077))){close(fd);return -1;}return fd;}
static BOOL ARRelated(NSURL *a,NSURL *b){NSString *x=a.path,*y=b.path;return [x isEqual:y]||[x hasPrefix:[y stringByAppendingString:@"/"]]||[y hasPrefix:[x stringByAppendingString:@"/"]];}
static NSString *ARDigest(const unsigned char d[32]){char hex[65];for(unsigned i=0;i<32;i++)snprintf(hex+2*i,3,"%02x",d[i]);return ARString(hex);}
static int ARCancelled(void *p){return atomic_load((_Atomic int *)p)!=0;}
@protocol ARGeometry
- (CGRect)bounds;
@end
@implementation CanopyAppleRuntime {
    NSURL *_appleRoot;
    const struct mng_apple_host *_appleHost;
    struct mng_apple_prepared *_prepared;
    NSString *_appleState,*_appleTitle;
    NSDictionary *_appleSettings;
    NSString *_startupLanguage;
    int _generationLease;
    BOOL _entered,_languageApplied;
    _Atomic int _cancel;
    uint64_t _inputSequence,_inputTime;
    id _surface,_view;
    id<MTLDevice> _device;
}
- (instancetype)initWithPreparedRootURL:(NSURL *)root {if((self=[super initWithPreparedRootURL:root])){_appleRoot=ARPhysical(root);_appleState=@"idle";_generationLease=-1;_appleSettings=@{};atomic_init(&_cancel,0);}return self;}
- (NSString *)state{return _appleState;}
- (NSString *)titleID{return _appleTitle;}
- (BOOL)nativeEntryInvoked{return _entered;}
- (NSDictionary *)capabilities{return ARCapabilities(ARHost()!=NULL);}
- (NSDictionary *)settingStates{return _appleSettings;}
- (void)failed {
    if(_entered){_appleHost->clear_input();(void)_appleHost->set_focus(0);}
    _appleState=@"failed";
    if(_appleSettings[@"language"]){
        NSMutableDictionary *states=[_appleSettings mutableCopy],*language=[states[@"language"] mutableCopy];
        language[@"state"]=@"rejected";language[@"message"]=@"The native session failed; its retained startup language policy cannot be changed.";
        states[@"language"]=language;_appleSettings=[states copy];
    }
}
- (BOOL)observe {
    struct mng_apple_lifecycle s={MNG_APPLE_HOST_ABI,sizeof(s),0,0,0,0,0,0};
    BOOL valid=_entered&&!_appleHost->read_lifecycle(&s)&&s.abi==MNG_APPLE_HOST_ABI&&s.size==sizeof(s)&&s.phase<=MNG_APPLE_PROVIDER_FAILED&&s.provider_error<=MNG_APPLE_PROVIDER_CONTROLLER_UNAVAILABLE&&(!s.provider_error||s.phase==MNG_APPLE_PROVIDER_FAILED)&&s.main_returned<=1&&s.main_joined<=1&&
        (!s.main_return_code||s.main_returned)&&(!s.main_joined||s.phase==MNG_APPLE_JOINED||s.phase==MNG_APPLE_PROVIDER_FAILED)&&(!s.join_error||s.phase==MNG_APPLE_OBSERVATION_FAILED||s.phase==MNG_APPLE_PROVIDER_FAILED);
    if(!valid||s.phase!=MNG_APPLE_RUNNING){[self failed];return NO;}return YES;
}
- (NSDictionary *)diagnosticMetrics {NSAssert(NSThread.isMainThread,@"Native state belongs on main");if(_entered)(void)[self observe];return @{@"nativeEntryInvoked":_entered?@YES:@NO};}
- (BOOL)startTitleID:(NSString *)title generationID:(NSString *)generation hostAssetsURL:(NSURL *)assets activeSavesURL:(NSURL *)saves identityURL:(NSURL *)identity cacheURL:(NSURL *)cache settings:(NSDictionary *)settings graphicsSurface:(id)surface hostView:(id)view error:(NSError **)error completion:(void (^)(BOOL,NSError * _Nullable))completion {
    NSAssert(NSThread.isMainThread,@"Native startup belongs on main");
    // Freeze validated request identities before admission or asynchronous work.
    // The same generation bytes must select both the lease and the later path.
    title=[title isKindOfClass:NSString.class]?[title copy]:nil;
    generation=[generation isKindOfClass:NSString.class]?[generation copy]:nil;
    assets=[assets isKindOfClass:NSURL.class]?[assets copy]:nil;
    saves=[saves isKindOfClass:NSURL.class]?[saves copy]:nil;
    identity=[identity isKindOfClass:NSURL.class]?[identity copy]:nil;
    cache=[cache isKindOfClass:NSURL.class]?[cache copy]:nil;
    NSDictionary *profile=CanopyAppleTrustedProfile(title);const struct mng_apple_host *host=ARHost();
    if(![settings isKindOfClass:NSDictionary.class]){if(error)*error=ARError(4);return NO;}
    NSString *language=[settings[@"language"] isKindOfClass:NSString.class]?[settings[@"language"] copy]:@"";
    if(!profile||!host||![_appleState isEqual:@"idle"]||!ARHex(generation,64)||!completion||![settings isKindOfClass:NSDictionary.class]||
        ![@[@"",@"zh-Hant",@"zh-Hans",@"en-US",@"ja",@"de",@"es",@"fr",@"it",@"nl",@"ru",@"ko"] containsObject:language]||
        ![surface isKindOfClass:CAMetalLayer.class]||![view respondsToSelector:@selector(bounds)]||![ARPhysical(assets) isEqual:profile[@"hostAssetsURL"]]||
        !saves.isFileURL||!identity.isFileURL||!cache.isFileURL||!CanopyRuntimeClaimProcess(self)){if(error)*error=ARError(3);return NO;}
    CAMetalLayer *layer=surface;id<MTLDevice> device=layer.device?:MTLCreateSystemDefaultDevice();if(device)layer.device=device;
    _appleHost=host;_appleTitle=[title copy];_appleState=@"preparing";atomic_store(&_cancel,0);
    NSDictionary *desired=[[NSDictionary alloc] initWithDictionary:settings copyItems:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
        struct mng_store *store=NULL;struct mng_store_verified_assets facts={0};int lease=-1,root=AROpenPrivate(self->_appleRoot);
        BOOL ok=device&&root>=0&&mng_store_open(root,&store)==MNG_PREPARE_OK;
        if(ok){mng_store_set_cancel_check(store,ARCancelled,&self->_cancel);ok=mng_store_pin_verified_assets(store,host->title_id,generation.UTF8String,&facts,&lease)==MNG_PREPARE_OK;}
        mng_store_close(store);if(root>=0)close(root);
        NSURL *gen=[[[[self->_appleRoot URLByAppendingPathComponent:@"titles"] URLByAppendingPathComponent:title] URLByAppendingPathComponent:@"generations"] URLByAppendingPathComponent:generation];
        NSURL *paths[]={saves,identity,cache,gen};
        for(unsigned i=0;i<4;i++){int fd=AROpenPrivate(paths[i]);if(fd<0)ok=NO;if(fd>=0)close(fd);for(unsigned j=0;j<i;j++)if(ARRelated(paths[i],paths[j]))ok=NO;}
        ok=ok&&facts.preparation.version_identified==1&&facts.preparation.title_version==host->title_version&&facts.main.present==1&&facts.romfs.present==1&&facts.romfs.size==host->romfs_size&&
            [ARDigest(facts.main.sha256) isEqual:ARString(host->modules[0].original_sha256)]&&[ARDigest(facts.romfs.sha256) isEqual:ARString(host->romfs_sha256)];
        struct mng_apple_prepared *prepared=NULL;
        struct mng_apple_prepare request={MNG_APPLE_HOST_ABI,sizeof(request),gen.fileSystemRepresentation,assets.fileSystemRepresentation,saves.fileSystemRepresentation,identity.fileSystemRepresentation,cache.fileSystemRepresentation,language.UTF8String,(__bridge void *)device,ARCancelled,&self->_cancel};
        if(ok&&!ARCancelled(&self->_cancel))ok=host->prepare(&request,&prepared)==MNG_APPLE_OK&&prepared;
        dispatch_async(dispatch_get_main_queue(),^{
            if(!ok||ARCancelled(&self->_cancel)||layer.device!=device){if(prepared)host->release_prepared(prepared);if(lease>=0)close(lease);self->_appleState=@"idle";self->_appleTitle=nil;CanopyRuntimeReleaseBeforeEntry(self);completion(NO,ARError(ARCancelled(&self->_cancel)?7:4));return;}
            self->_prepared=prepared;self->_generationLease=lease;self->_surface=surface;self->_view=view;self->_device=device;
            struct mng_apple_start start={MNG_APPLE_HOST_ABI,sizeof(start),prepared,(__bridge void *)device,(__bridge void *)surface,(__bridge void *)view};
            self->_startupLanguage=[language copy];self->_entered=YES;self->_appleState=@"starting";
            if(host->start(&start)||![self observe]){[self failed];completion(NO,ARError(5));return;}
            self->_appleState=@"inputCaptured";
            if(![[self updatePresentationLayout][@"state"] isEqual:@"applied"]){[self failed];completion(NO,ARError(5));return;}
            self->_languageApplied=YES;[self applyDesiredSettings:desired];
            if([self->_appleState isEqual:@"failed"]){completion(NO,ARError(5));return;}
            completion(YES,nil);
        });
    }});return YES;
}
- (BOOL)cancelPreparation:(NSError **)error {NSAssert(NSThread.isMainThread,@"Native cancellation belongs on main");if(![@[@"preparing",@"cancelling"] containsObject:_appleState]){if(error)*error=ARError(3);return NO;}atomic_store(&_cancel,1);_appleState=@"cancelling";return YES;}
- (NSDictionary *)applyDesiredSettings:(NSDictionary *)settings {
    NSAssert(NSThread.isMainThread,@"Native settings belong on main");
    if(_entered)(void)[self observe];
    BOOL live=_languageApplied&&[@[@"active",@"inputCaptured"] containsObject:_appleState];
    NSMutableDictionary *result=[NSMutableDictionary new];
    for(NSString *key in settings){
        id value=settings[key];
        if([key isEqual:@"language"]){
            BOOL valid=[value isKindOfClass:NSString.class]&&[@[@"",@"zh-Hant",@"zh-Hans",@"en-US",@"ja",@"de",@"es",@"fr",@"it",@"nl",@"ru",@"ko"] containsObject:value];
            NSString *state=live&&valid?([value isEqual:_startupLanguage]?@"applied":@"restartRequired"):@"rejected";
            NSString *message=live&&valid?@"Language policy was bound before native startup. System resolves once at startup; the resolved code is not queried here. A changed policy requires a new process.":@"No active native session can apply this requested language policy.";
            result[key]=@{@"state":state,@"desiredValue":value,@"effectiveValue":_languageApplied?_startupLanguage:NSNull.null,@"message":message};
        }else result[key]=@{@"state":@"unsupported",@"desiredValue":value,@"effectiveValue":NSNull.null,@"message":@"This native provider has no approved runtime setter for this preference. Original game settings remain in effect."};
    }
    _appleSettings=[result copy];return _appleSettings;
}
- (NSDictionary *)updatePresentationLayout {NSAssert(NSThread.isMainThread,@"Native layout belongs on main");CGRect bounds=[(id<ARGeometry>)_view bounds];double scale=1;
#if TARGET_OS_IPHONE
    if([_view isKindOfClass:UIView.class])scale=((UIView *)_view).window.screen.scale;
#endif
    BOOL ok=_entered&&isfinite(bounds.size.width)&&isfinite(bounds.size.height)&&bounds.size.width>0&&bounds.size.height>0&&bounds.size.width<=32768&&bounds.size.height<=32768&&isfinite(scale)&&scale>0&&scale<=16&&
        !_appleHost->update_layout(bounds.size.width,bounds.size.height,scale);
    if(!ok&&_entered&&![_appleState isEqual:@"failed"]){_appleHost->clear_input();(void)_appleHost->set_focus(0);_appleState=@"inputCaptured";}
    return @{@"state":ok?@"applied":@"rejected",@"message":@"Original 16:9 game projection; this updates presentation only and does not measure scene pixels."};}
- (BOOL)captureInput:(NSError **)error {NSAssert(NSThread.isMainThread,@"Native focus belongs on main");if(!_entered||![self observe]){if(error)*error=ARError(5);return NO;}_appleHost->clear_input();if(_appleHost->set_focus(0)){if(error)*error=ARError(5);return NO;}_appleState=@"inputCaptured";return YES;}
- (BOOL)restoreInput:(NSError **)error {NSAssert(NSThread.isMainThread,@"Native focus belongs on main");if(!_entered||![self observe]||![[self updatePresentationLayout][@"state"] isEqual:@"applied"]){if(error)*error=ARError(5);return NO;}_appleHost->clear_input();if(_appleHost->set_focus(1)){if(error)*error=ARError(5);return NO;}_appleState=@"active";return YES;}
- (BOOL)submitInput:(const struct mng_session_input *)input error:(NSError **)error {NSAssert(NSThread.isMainThread,@"Native input belongs on main");struct timespec t={0};BOOL clock=clock_gettime(CLOCK_MONOTONIC,&t)==0;uint64_t now=(uint64_t)t.tv_sec*UINT64_C(1000000000)+(uint64_t)t.tv_nsec;
    BOOL valid=clock&&_entered&&[_appleState isEqual:@"active"]&&[self observe]&&input&&input->sequence&&input->sequence>_inputSequence&&input->timestamp_ns&&input->timestamp_ns>=_inputTime&&input->timestamp_ns<=now&&now-input->timestamp_ns<=UINT64_C(250000000);
    if(valid)for(unsigned i=0;i<MNG_SESSION_PLAYERS;i++){const struct mng_player_input *p=input->players+i;float axes[]={p->left_x,p->left_y,p->right_x,p->right_y};if((i>=4&&(p->connected||p->device_id||p->buttons||p->left_x||p->left_y||p->right_x||p->right_y))||p->connected>1||(p->buttons&~UINT64_C(0xffff))||(p->connected&&!p->device_id)||(!p->connected&&(p->device_id||p->buttons||p->left_x||p->left_y||p->right_x||p->right_y)))valid=NO;for(unsigned a=0;a<4;a++)if(!isfinite(axes[a])||axes[a]<-1||axes[a]>1)valid=NO;for(unsigned j=0;j<i;j++)if(p->connected&&input->players[j].connected&&p->device_id==input->players[j].device_id)valid=NO;}
    if(!valid||_appleHost->submit_players(input,now)){if(error)*error=ARError(4);return NO;}_inputSequence=input->sequence;_inputTime=input->timestamp_ns;return YES;}
- (BOOL)tick:(NSError **)error {NSAssert(NSThread.isMainThread,@"Native state belongs on main");if(!_entered||![@[@"active",@"inputCaptured"] containsObject:_appleState]||![self observe]){if(error)*error=ARError(5);return NO;}return [[self updatePresentationLayout][@"state"] isEqual:@"applied"];}
- (BOOL)pause:(BOOL)paused error:(NSError **)error {(void)paused;if(error)*error=ARError(6);return NO;}
- (BOOL)close:(NSError **)error {if(!_entered&&[_appleState isEqual:@"idle"])return YES;if(error)*error=ARError(6);return NO;}
- (void)dealloc {if(!_entered){if(_prepared)_appleHost->release_prepared(_prepared);if(_generationLease>=0)close(_generationLease);}}
@end
