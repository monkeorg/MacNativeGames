#import "CanopyRuntime.h"
#import <CoreFoundation/CoreFoundation.h>
#import "CanopyShaderCache.h"
#import <QuartzCore/CAMetalLayer.h>
#include "../../../games/totk/runtime/canopy_host.h"
#include "mng_store.h"
#include "mng_players.h"
#include "mng_crypto.h"
#include "mng_romfs_runtime.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#include <stdatomic.h>
extern const struct canopy_totk_host *totk_canopy_host_v1(void) __attribute__((weak_import));
static CanopyRuntime *activeRuntime;
static NSError *CRError(NSInteger code,NSString *message) {
    return [NSError errorWithDomain:@"CanopyRuntime" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL CRHex(NSString *s,NSUInteger length) {
    return [s isKindOfClass:NSString.class] && s.length==length &&
        [s rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
static BOOL CRNumber(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID();
}
static BOOL CRBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID();
}
static NSString *CRString(const char *s) {return s ? [NSString stringWithUTF8String:s]:nil;}
static const struct canopy_totk_host *CRHost(void) {
    if(!totk_canopy_host_v1)return NULL;
    const struct canopy_totk_host *h=totk_canopy_host_v1();
    if(!h || h->abi_version!=CANOPY_TOTK_HOST_ABI || h->size!=sizeof(*h) || !h->title_id ||
       !CRHex(CRString(h->original_main_sha256),64) || !CRHex(CRString(h->romfs_sha256),64) ||
       !CRHex(CRString(h->runtime_index_sha256),64) || !CRHex(CRString(h->shader_seed_manifest_sha256),64) ||
       !CRString(h->shader_chain).length || CRString(h->shader_chain).length>128 || !CRString(h->game_version).length ||
       !h->start || !h->fps_supported || !h->set_fps || !h->get_fps || !h->taa_supported || !h->set_taa || !h->get_taa ||
       !h->get_hud || !h->cycle_hud || !h->clear_input || !h->set_focus || !h->input)return NULL;
    return h;
}
static NSURL *CRResources(const struct canopy_totk_host *h) {
    NSURL *url=h->resource_directory ? [NSURL fileURLWithPath:CRString(h->resource_directory) isDirectory:YES]:
        [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"GameData" isDirectory:YES];
    return url.URLByResolvingSymlinksInPath; /* Compiled trusted resource base. */
}
static NSDictionary *CRCapabilities(BOOL available) {
    return @{@"available":@(available),@"singleUse":@YES,@"canStop":@NO,@"canPauseCPU":@NO,
        @"canCaptureInput":@(available),@"maxPlayers":@(available?1:0),@"hostOwnsRenderLoop":@YES};
}
static int CROpenDirectory(NSURL *url,BOOL private) {
    if(!url.isFileURL)return -1;
    int fd=open(url.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    struct stat st;
    if(fd>=0 && (fstat(fd,&st) || !S_ISDIR(st.st_mode) || (private && (st.st_uid!=geteuid() || (st.st_mode&077))))) {close(fd);fd=-1;}
    return fd;
}
static BOOL CRStatEqual(const struct stat *a,const struct stat *b) {
    return a->st_dev==b->st_dev && a->st_ino==b->st_ino && a->st_mode==b->st_mode && a->st_nlink==b->st_nlink &&
        a->st_size==b->st_size && a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
}
static BOOL CRRelated(NSURL *a,NSURL *b) {
    NSString *left=a.URLByStandardizingPath.path,*right=b.URLByStandardizingPath.path;
    return [left isEqual:right] || [left hasPrefix:[right stringByAppendingString:@"/"]] ||
        [right hasPrefix:[left stringByAppendingString:@"/"]];
}
static BOOL CRSameDirectory(int a,int b) {
    struct stat first,second;
    return a>=0 && b>=0 && !fstat(a,&first) && !fstat(b,&second) && first.st_dev==second.st_dev && first.st_ino==second.st_ino;
}
static int CRCancelled(void *context) {return context && atomic_load((_Atomic int *)context)!=0;}
static BOOL CRHash(int parent,const char *name,NSString *expected,_Atomic int *cancelled) {
    int fd=openat(parent,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    struct stat before,after;struct mng_sha256 *sha=NULL;unsigned char buffer[65536],digest[32];
    BOOL valid=fd>=0 && !fstat(fd,&before) && S_ISREG(before.st_mode) && before.st_nlink==1 && before.st_size>=0 &&
        (uint64_t)before.st_size<=(UINT64_C(64)<<30) && !mng_sha256_init(&sha);
    uint64_t total=0;
    while(valid) {if(CRCancelled(cancelled)){valid=NO;break;}ssize_t n=read(fd,buffer,sizeof(buffer));if(n<0 && errno==EINTR)continue;if(n<0){valid=NO;break;}if(!n)break;
        total+=(uint64_t)n;if(total>(uint64_t)before.st_size || mng_sha256_update(sha,buffer,(size_t)n)){valid=NO;break;}}
    if(valid)valid=total==(uint64_t)before.st_size && !mng_sha256_final(sha,digest) && !fstat(fd,&after) && CRStatEqual(&before,&after);
    if(fd>=0)close(fd);mng_sha256_free(sha);
    if(!valid)return NO;
    char hex[65];for(unsigned i=0;i<32;i++)snprintf(hex+2*i,3,"%02x",digest[i]);
    return [expected isEqual:CRString(hex)];
}
static int CRCanonical(void *context,const char *utf8,char *canonical,size_t capacity) {
    (void)context;
    NSString *name=CRString(utf8);if(!name)return -1;
    NSString *folded=[[name precomposedStringWithCanonicalMapping]
        stringByFoldingWithOptions:NSCaseInsensitiveSearch locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
    NSData *data=[[folded precomposedStringWithCanonicalMapping] dataUsingEncoding:NSUTF8StringEncoding];
    if(!data || data.length>=capacity)return -1;
    memcpy(canonical,data.bytes,data.length);canonical[data.length]=0;return 0;
}
static int CRPrivateChild(int root,const char *name) {
    if(mkdirat(root,name,0700) && errno!=EEXIST)return -1;
    int child=openat(root,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);struct stat st;
    if(child>=0 && (fstat(child,&st) || st.st_uid!=geteuid() || (st.st_mode&077))) {close(child);return -1;}
    return child;
}
static NSURL *CRIndex(int generation,NSURL *cache,NSString *expected,_Atomic int *cancelled) {
    int root=CROpenDirectory(cache,YES);if(root<0)return nil;
    int recipe=CRPrivateChild(root,"totk-runtime-index-v1");close(root);if(recipe<0)return nil;
    int directory=CRPrivateChild(recipe,expected.UTF8String);close(recipe);if(directory<0)return nil;
    NSURL *url=[[cache URLByAppendingPathComponent:@"totk-runtime-index-v1" isDirectory:YES]
        URLByAppendingPathComponent:expected isDirectory:YES];
    struct stat existing;
    if(!fstatat(directory,"runtime-index.bin",&existing,AT_SYMLINK_NOFOLLOW)) {
        BOOL valid=CRHash(directory,"runtime-index.bin",expected,cancelled);close(directory);return valid?url:nil;
    }
    if(errno!=ENOENT){close(directory);return nil;}
    NSString *temporary=[@".index-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int output=openat(directory,temporary.UTF8String,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    int image=openat(generation,"romfs.bin",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    struct mng_romfs_runtime_result result={0};
    struct mng_romfs_callbacks callbacks={0};callbacks.canonical_name=CRCanonical;callbacks.context=cancelled;callbacks.cancelled=CRCancelled;
    BOOL valid=output>=0 && image>=0 && mng_romfs_runtime_index_fd(image,output,&callbacks,&result)==MNG_ROMFS_OK;
    char hex[65]={0};if(valid)for(unsigned i=0;i<32;i++)snprintf(hex+2*i,3,"%02x",result.index_sha256[i]);
    if(valid)valid=[expected isEqual:CRString(hex)] && !fsync(output);
    if(valid && linkat(directory,temporary.UTF8String,directory,"runtime-index.bin",0)) {
        valid=errno==EEXIST && CRHash(directory,"runtime-index.bin",expected,cancelled);
    }
    if(image>=0)close(image);if(output>=0)close(output);
    if(unlinkat(directory,temporary.UTF8String,0) && errno!=ENOENT)valid=NO;
    if(valid && fsync(directory))valid=NO;
    close(directory);return valid?url:nil;
}
static uint64_t CRNativeButtons(uint64_t portable) {
    /* Portable: A B X Y L R ZL ZR plus minus Lstick Rstick up down left right.
     * Existing Npad: A B X Y Lstick Rstick L R ZL ZR plus minus left up right down. */
    static const unsigned native_bits[16]={0,1,2,3,6,7,8,9,10,11,4,5,13,15,12,14};
    uint64_t native=0;
    for(unsigned i=0;i<16;i++)if(portable&(UINT64_C(1)<<i))native|=UINT64_C(1)<<native_bits[i];
    return native;
}
static NSDictionary *CROutcome(NSString *state,id desired,id effective,NSString *message) {
    return @{@"state":state,@"desiredValue":desired ?: NSNull.null,@"effectiveValue":effective ?: NSNull.null,@"message":message};
}
@implementation CanopyRuntime {
    NSURL *_root;
    NSString *_state,*_titleID;
    NSDictionary *_settingStates,*_startupSettings;
    CanopyShaderCacheLease *_shaderLease;
    const struct canopy_totk_host *_host;
    int _lease;
    BOOL _nativeEntryInvoked;
    _Atomic int _preflightCancelled;
    uint64_t _sequence,_timestamp,_deviceID;
}
- (instancetype)initWithPreparedRootURL:(NSURL *)root {
    if((self=[super init])){_root=[root.URLByResolvingSymlinksInPath copy];_state=@"idle";_lease=-1;_settingStates=@{};atomic_init(&_preflightCancelled,0);}return self;
}
- (NSString *)state{return _state;}
- (NSString *)titleID{return _titleID;}
- (BOOL)nativeEntryInvoked{return _nativeEntryInvoked;}
- (NSDictionary *)capabilities{return CRCapabilities(CRHost()!=NULL);}
- (NSDictionary *)settingStates{return _settingStates;}
- (NSDictionary *)diagnosticMetrics {
    NSAssert(NSThread.isMainThread,@"Runtime owner must be main thread");
    NSMutableDictionary *metrics=[NSMutableDictionary dictionaryWithDictionary:_shaderLease.metrics ?: @{}];
    metrics[@"nativeEntryInvoked"]=@(_nativeEntryInvoked);
    if(_nativeEntryInvoked && ([_state isEqual:@"active"] || [_state isEqual:@"inputCaptured"]))metrics[@"frameLimit"]=@(_host->get_fps());
    return [metrics copy];
}
+ (NSDictionary *)trustedProfileForTitleID:(NSString *)titleID {
    const struct canopy_totk_host *h=CRHost();
    if(!h || ![titleID isEqual:[NSString stringWithFormat:@"%016llx",(unsigned long long)h->title_id]])return nil;
    NSMutableDictionary *profile=[CRCapabilities(YES) mutableCopy];
    profile[@"titleID"]=titleID;profile[@"version"]=CRString(h->game_version);profile[@"hostAssetsURL"]=CRResources(h);
    return profile;
}
- (BOOL)startTitleID:(NSString *)titleID generationID:(NSString *)generationID hostAssetsURL:(NSURL *)assets
       activeSavesURL:(NSURL *)saves identityURL:(NSURL *)identity cacheURL:(NSURL *)cache
            settings:(NSDictionary *)settings graphicsSurface:(id)surface hostView:(id)view error:(NSError **)error
          completion:(void (^)(BOOL,NSError * _Nullable))completion {
    NSAssert(NSThread.isMainThread,@"Runtime owner must be main thread");
    NSDictionary *profile=[CanopyRuntime trustedProfileForTitleID:titleID];
    if(activeRuntime || ![_state isEqual:@"idle"] || !profile || !CRHex(generationID,64) || !completion || !surface || !view ||
       !saves.isFileURL || !identity.isFileURL || !cache.isFileURL ||
       ![assets.URLByStandardizingPath isEqual:[profile[@"hostAssetsURL"] URLByStandardizingPath]]) {
        if(error)*error=CRError(3,@"No approved native host is available for this session.");return NO;
    }
    if(![settings isKindOfClass:NSDictionary.class] || !CRNumber(settings[@"fpsLimit"]) ||
       !CRBoolean(settings[@"taa"]) || !CRNumber(settings[@"hud"]) || ![settings[@"language"] isKindOfClass:NSString.class]) {
        if(error)*error=CRError(4,@"Invalid native startup settings.");return NO;
    }
    if(![surface isKindOfClass:CAMetalLayer.class]) {
        if(error)*error=CRError(4,@"A native Metal presentation layer is required.");return NO;
    }
    CAMetalLayer *metalLayer=surface;
    id<MTLDevice> selectedDevice=metalLayer.device ?: MTLCreateSystemDefaultDevice();
    if(selectedDevice)metalLayer.device=selectedDevice;
    /* Resolve only the app-owned cache base; preserve the derived final leaf
     * so a symlink there is still refused by descriptor-relative validation. */
    cache=[[cache.URLByDeletingLastPathComponent URLByResolvingSymlinksInPath]
        URLByAppendingPathComponent:cache.lastPathComponent isDirectory:YES];
    const char *savePath=saves.fileSystemRepresentation,*identityPath=identity.fileSystemRepresentation;
    if(!savePath || !identityPath || strnlen(savePath,1024)>=1024 || strnlen(identityPath,1024)>=1024) {
        if(error)*error=CRError(4,@"Native save or identity path exceeds the host limit.");return NO;
    }
    _host=CRHost();_titleID=[titleID copy];_state=@"preparing";
    _startupSettings=[[NSDictionary alloc] initWithDictionary:settings copyItems:YES];atomic_store(&_preflightCancelled,0);activeRuntime=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        int root=CROpenDirectory(self->_root,YES),lease=-1;struct mng_store *store=NULL;
        BOOL valid=root>=0 && mng_store_open(root,&store)==MNG_PREPARE_OK;
        if(valid) {
            mng_store_set_cancel_check(store,CRCancelled,&self->_preflightCancelled);
            valid=mng_store_pin(store,self->_host->title_id,generationID.UTF8String,&lease)==MNG_PREPARE_OK;
        }
        mng_store_close(store);if(root>=0)close(root);
        NSURL *generation=[[[[self->_root URLByAppendingPathComponent:@"titles"] URLByAppendingPathComponent:titleID]
            URLByAppendingPathComponent:@"generations"] URLByAppendingPathComponent:generationID];
        int gen=CROpenDirectory(generation,YES),exefs=gen<0?-1:openat(gen,"exefs",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        int resources=CROpenDirectory(assets,NO);
        if(valid)valid=gen>=0 && exefs>=0 && resources>=0 &&
            CRHash(exefs,"main",CRString(self->_host->original_main_sha256),&self->_preflightCancelled) &&
            CRHash(gen,"romfs.bin",CRString(self->_host->romfs_sha256),&self->_preflightCancelled);
        int saveFD=CROpenDirectory(saves,YES),identityFD=CROpenDirectory(identity,YES),cacheFD=CROpenDirectory(cache,YES);
        if(saveFD<0 || identityFD<0 || cacheFD<0 || CRSameDirectory(saveFD,identityFD) ||
           CRSameDirectory(saveFD,cacheFD) || CRSameDirectory(identityFD,cacheFD) ||
           CRRelated(saves,identity) || CRRelated(saves,cache) || CRRelated(identity,cache) ||
           CRRelated(generation,saves) || CRRelated(generation,identity) || CRRelated(generation,cache))valid=NO;
        NSURL *indexDirectory=valid?CRIndex(gen,cache,CRString(self->_host->runtime_index_sha256),&self->_preflightCancelled):nil;
        if(!indexDirectory)valid=NO;
        CanopyShaderCacheLease *shaderLease=nil;
        BOOL deviceUnavailable=valid && !selectedDevice;
        if(valid && !atomic_load(&self->_preflightCancelled)) {
            NSDictionary *deviceIdentity=selectedDevice?[CanopyShaderCache deviceIdentityForDevice:selectedDevice error:NULL]:nil;
            CanopyShaderCache *shaderCache=[[CanopyShaderCache alloc] initWithRootURL:[cache URLByAppendingPathComponent:@"shader-identities" isDirectory:YES]];
            if(deviceIdentity)shaderLease=[shaderCache prepareSeedURL:[assets URLByAppendingPathComponent:@"shader-seed" isDirectory:YES]
                titleID:titleID sourceRomFSSHA256:CRString(self->_host->romfs_sha256)
                expectedManifestSHA256:CRString(self->_host->shader_seed_manifest_sha256) expectedChain:CRString(self->_host->shader_chain)
                deviceIdentity:deviceIdentity cancelled:^BOOL{return atomic_load(&self->_preflightCancelled)!=0;}
                progress:nil error:NULL];
            if(!shaderLease)valid=NO;
        }
        if(saveFD>=0)close(saveFD);if(identityFD>=0)close(identityFD);if(cacheFD>=0)close(cacheFD);
        if(gen>=0)close(gen);if(exefs>=0)close(exefs);if(resources>=0)close(resources);
        dispatch_async(dispatch_get_main_queue(),^{
            if(!valid || atomic_load(&self->_preflightCancelled)){if(lease>=0)close(lease);self->_state=@"idle";self->_titleID=nil;activeRuntime=nil;
                completion(NO,atomic_load(&self->_preflightCancelled)?CRError(7,@"Native startup preparation cancelled."):
                    deviceUnavailable?CRError(3,@"No native Metal device is available."):CRError(4,@"Verified prepared assets or private host resources do not match the approved profile."));return;}
            self->_lease=lease;
            self->_shaderLease=shaderLease;
            NSDictionary *desired=self->_startupSettings;
            NSString *language=[desired[@"language"] isKindOfClass:NSString.class]?desired[@"language"]:@"";
            unsigned fps=[desired[@"fpsLimit"] unsignedIntValue];BOOL taa=[desired[@"taa"] boolValue];int hud=[desired[@"hud"] intValue];
            if(![@[@30,@40,@60] containsObject:desired[@"fpsLimit"]] || !self->_host->fps_supported(fps) ||
               (taa && !self->_host->taa_supported()) || ![@[@0,@1,@2] containsObject:desired[@"hud"]] ||
               ![@[@"",@"zh-Hant",@"zh-Hans",@"en-US",@"ja",@"de",@"es",@"fr",@"it",@"nl",@"ru",@"ko"] containsObject:language]) {
                close(self->_lease);self->_lease=-1;self->_shaderLease=nil;self->_state=@"idle";self->_titleID=nil;activeRuntime=nil;
                completion(NO,CRError(4,@"Requested startup settings are unsupported by the native host."));return;
            }
            if(metalLayer.device!=selectedDevice) {
                close(self->_lease);self->_lease=-1;self->_shaderLease=nil;self->_state=@"idle";self->_titleID=nil;activeRuntime=nil;
                completion(NO,CRError(4,@"The native graphics device changed during preparation. Retry startup."));return;
            }
            struct canopy_totk_start start={assets.fileSystemRepresentation,assets.fileSystemRepresentation,
                indexDirectory.fileSystemRepresentation,generation.fileSystemRepresentation,saves.fileSystemRepresentation,
                identity.fileSystemRepresentation,cache.fileSystemRepresentation,shaderLease.seedURL.fileSystemRepresentation,shaderLease.cacheURL.fileSystemRepresentation,
                language.UTF8String,fps,taa,hud,
                (__bridge void *)surface,(__bridge void *)view,(__bridge void *)selectedDevice};
            self->_nativeEntryInvoked=YES;self->_state=@"starting";
            if(self->_host->start(&start)){self->_state=@"failed";completion(NO,CRError(5,@"Native startup failed; this single-use process cannot safely relaunch."));return;}
            self->_state=@"inputCaptured";[self applyDesiredSettings:desired];completion(YES,nil);
        });
    });
    return YES;
}
- (BOOL)cancelPreparation:(NSError **)error {
    NSAssert(NSThread.isMainThread,@"Runtime owner must be main thread");
    if(![_state isEqual:@"preparing"] && ![_state isEqual:@"cancelling"]) {
        if(error)*error=CRError(3,@"Native startup preparation is not pending.");return NO;
    }
    atomic_store(&_preflightCancelled,1);_state=@"cancelling";return YES;
}
- (NSDictionary *)applyDesiredSettings:(NSDictionary *)settings {
    NSAssert(NSThread.isMainThread,@"Runtime settings belong on main thread");
    NSMutableDictionary *states=[NSMutableDictionary dictionary];
    BOOL active=_nativeEntryInvoked && ([_state isEqual:@"active"] || [_state isEqual:@"inputCaptured"]);
    for(NSString *key in settings) {
        id value=settings[key];NSDictionary *outcome=CROutcome(@"unsupported",value,nil,@"The native host has no application hook for this setting.");
        if(active && [key isEqual:@"fpsLimit"]) {
            if(!CRNumber(value) || ![@[@30,@40,@60] containsObject:value] || !_host->fps_supported([value unsignedIntValue]))outcome=CROutcome(@"rejected",value,@(_host->get_fps()),@"This frame limit is unavailable on the active native display profile.");
            else {_host->set_fps([value unsignedIntValue]);outcome=CROutcome(@"applied",value,@(_host->get_fps()),@"Native frame ceiling applied; this is not measured FPS.");}
        } else if(active && [key isEqual:@"taa"]) {
            if(![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID() || ([value boolValue] && !_host->taa_supported()))outcome=CROutcome(@"rejected",value,@(_host->get_taa()!=0),@"Temporal anti-aliasing is unavailable on this native device.");
            else {_host->set_taa([value boolValue]);outcome=CROutcome(@"applied",value,@(_host->get_taa()!=0),@"Native temporal anti-aliasing setting applied.");}
        } else if(active && [key isEqual:@"hud"]) {
            if(!CRNumber(value) || ![@[@0,@1,@2] containsObject:value])outcome=CROutcome(@"rejected",value,@(_host->get_hud()),@"Invalid native HUD mode.");
            else {for(unsigned i=0;i<3 && _host->get_hud()!=[value intValue];i++)_host->cycle_hud();
                outcome=CROutcome(_host->get_hud()==[value intValue]?@"applied":@"rejected",value,@(_host->get_hud()),@"Native diagnostic HUD mode.");}
        } else if(active && [key isEqual:@"language"]) {
            id initial=_startupSettings[@"language"] ?: @"";
            outcome=CROutcome([value isEqual:initial]?@"applied":@"restartRequired",value,initial,@"Language is bound before native service initialization; relaunch requires a new process.");
        }
        states[key]=outcome;
    }
    _settingStates=[states copy];return _settingStates;
}
- (BOOL)captureInput:(NSError **)error {
    NSAssert(NSThread.isMainThread,@"Runtime input belongs on main thread");
    if(!_nativeEntryInvoked || (![_state isEqual:@"active"] && ![_state isEqual:@"inputCaptured"])) {
        if(error)*error=CRError(3,@"No active native input target is available.");return NO;}
    _host->clear_input();_host->set_focus(0);_state=@"inputCaptured";return YES;
}
- (BOOL)restoreInput:(NSError **)error {
    NSAssert(NSThread.isMainThread,@"Runtime input belongs on main thread");
    if(![_state isEqual:@"inputCaptured"]){if(error)*error=CRError(3,@"Native input was not captured.");return NO;}
    _host->clear_input();_host->set_focus(1);_state=@"active";return YES;
}
- (BOOL)submitInput:(const struct mng_session_input *)input error:(NSError **)error {
    NSAssert(NSThread.isMainThread,@"Runtime input belongs on main thread");
    struct timespec time={0};clock_gettime(CLOCK_MONOTONIC,&time);
    uint64_t now=(uint64_t)time.tv_sec*UINT64_C(1000000000)+(uint64_t)time.tv_nsec;
    BOOL valid=input && [_state isEqual:@"active"] && input->sequence && input->sequence>_sequence && input->timestamp_ns &&
        input->timestamp_ns>=_timestamp && input->timestamp_ns<=now && now-input->timestamp_ns<=UINT64_C(250000000);
    if(valid)for(unsigned i=0;i<MNG_SESSION_PLAYERS;i++) {
        const struct mng_player_input *p=input->players+i;
        float axes[]={p->left_x,p->left_y,p->right_x,p->right_y};
        if((p->buttons&~UINT64_C(0xffff)) || p->connected>1 || (p->connected && (!p->device_id || i!=0)) ||
           (!p->connected && (p->buttons || p->left_x || p->left_y || p->right_x || p->right_y)))valid=NO;
        for(unsigned a=0;a<4;a++)if(!isfinite(axes[a]) || axes[a]<-1 || axes[a]>1)valid=NO;
    }
    if(!valid){if(error)*error=CRError(4,@"Input snapshot is stale, invalid, or requires an unsupported native player.");return NO;}
    const struct mng_player_input *p=input->players;
    if(!p->connected || (_deviceID && _deviceID!=p->device_id))_host->clear_input();
    _deviceID=p->connected?p->device_id:0;
    _host->input(CRNativeButtons(p->buttons),(int32_t)lrintf(p->left_x*32767),(int32_t)lrintf(p->left_y*32767),
        (int32_t)lrintf(p->right_x*32767),(int32_t)lrintf(p->right_y*32767),p->connected!=0);
    _sequence=input->sequence;_timestamp=input->timestamp_ns;return YES;
}
- (BOOL)tick:(NSError **)error {
    NSAssert(NSThread.isMainThread,@"Runtime owner must be main thread");
    if([_state isEqual:@"active"] || [_state isEqual:@"inputCaptured"])return YES;
    if(error)*error=CRError(3,@"The native host has not started.");return NO;
}
- (BOOL)pause:(BOOL)paused error:(NSError **)error {
    NSAssert(NSThread.isMainThread,@"Runtime owner must be main thread");
    (void)paused;if(error)*error=CRError(6,@"This single-use native host cannot promise guest CPU pause.");return NO;
}
- (BOOL)close:(NSError **)error {
    NSAssert(NSThread.isMainThread,@"Runtime owner must be main thread");
    if(!_nativeEntryInvoked && [_state isEqual:@"idle"])return YES;
    if(error)*error=CRError(6,@"Safe native thread teardown is unavailable. Keep this session sealed until the application exits.");return NO;
}
- (void)dealloc {if(!_nativeEntryInvoked && _lease>=0)close(_lease);}
@end
