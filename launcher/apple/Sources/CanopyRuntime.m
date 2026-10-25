#import "CanopyRuntime.h"
#import <CoreFoundation/CoreFoundation.h>
#import "CanopyShaderCache.h"
#import <QuartzCore/CAMetalLayer.h>
#include "../../../games/totk/runtime/canopy_host.h"
#include "mng_store.h"
#include "mng_players.h"
#include "mng_crypto.h"
#include "mng_romfs_runtime.h"
#include <dirent.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#include <stdatomic.h>
/* Public builds link an explicit unavailable provider. A private host (or the
 * original-source fixture) supplies the strong definition at link time. Native
 * host builds require that strong provider; they do not invent a fallback. */
#if !defined(CANOPY_HOST_RUNTIME)
__attribute__((weak,noinline)) const struct canopy_totk_host *totk_canopy_host_v1(void) {return NULL;}
#endif
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
static NSString *CRDigest(const unsigned char digest[32]) {
    char hex[65];for(unsigned i=0;i<32;i++)snprintf(hex+2*i,3,"%02x",digest[i]);return CRString(hex);
}
static BOOL CRDisplayHost(const struct canopy_totk_host *h) {
    const struct canopy_totk_display *d=&h->display;
    uint32_t flags=d->profile.flags;
    if(d->abi_version!=MNG_DISPLAY_ABI || d->size!=sizeof(*d) ||
       d->profile.abi!=MNG_DISPLAY_ABI || d->profile.size!=sizeof(d->profile) ||
       (flags&~(MNG_DISPLAY_SCENE_1080|MNG_DISPLAY_FOUR_THREE)) ||
       ((flags&MNG_DISPLAY_FOUR_THREE) && !(flags&MNG_DISPLAY_SCENE_1080)) || !d->read_state)return NO;
    if(flags && ![CRString(h->game_version) isEqual:@"1.4.3"])return NO;
    if(flags&MNG_DISPLAY_SCENE_1080) {if(!CRHex(CRString(d->heap_manifest_sha256),64))return NO;}
    else if(d->heap_manifest_sha256)return NO;
    if(flags&MNG_DISPLAY_FOUR_THREE) {if(!CRHex(CRString(d->layout_manifest_sha256),64))return NO;}
    else if(d->layout_manifest_sha256)return NO;
    return YES;
}
@protocol CRViewGeometry
- (CGRect)bounds;
@end
static BOOL CRViewSize(id view,CGSize *size) {
#if TARGET_OS_IPHONE
    if(![view isKindOfClass:UIView.class])return NO;
#else
    if(![view respondsToSelector:@selector(bounds)])return NO;
#endif
    CGRect bounds=[(id<CRViewGeometry>)view bounds];
    if(!isfinite(bounds.size.width) || !isfinite(bounds.size.height) || bounds.size.width<=0 || bounds.size.height<=0 ||
       bounds.size.width>32768 || bounds.size.height>32768)return NO;
    *size=bounds.size;return YES;
}
static BOOL CRDisplayResolve(const struct canopy_totk_host *host,NSDictionary *settings,CGSize size,struct mng_display_resolution *out) {
    id height=settings[@"renderHeight"] ?: @720,aspect=settings[@"aspect"] ?: @"16:9";
    if(!CRNumber(height) || ![@[@720,@1080] containsObject:height] || ![aspect isKindOfClass:NSString.class])return NO;
    uint32_t requested=[aspect isEqual:@"display"]?MNG_DISPLAY_FULL:MNG_DISPLAY_16_9;
    if(mng_display_resolve(&host->display.profile,[height unsignedIntValue],requested,size.width,size.height,out))return NO;
    if(![aspect isEqual:@"display"] && ![aspect isEqual:@"16:9"])out->aspect_outcome=MNG_DISPLAY_UNSUPPORTED;
    return YES;
}
static BOOL CRDisplaySame(const struct mng_display_config *a,const struct mng_display_config *b) {
    return a->abi==b->abi && a->size==b->size && a->width==b->width && a->height==b->height && a->aspect==b->aspect &&
        a->experimental==b->experimental && a->fixed_resolution==b->fixed_resolution;
}
static const struct canopy_totk_host *CRHost(void) {
    const struct canopy_totk_host *h=totk_canopy_host_v1();
    if(!h || h->abi_version!=CANOPY_TOTK_HOST_ABI || h->size!=sizeof(*h) || !h->title_id ||
       !CRHex(CRString(h->original_main_sha256),64) || !CRHex(CRString(h->romfs_sha256),64) ||
       !CRHex(CRString(h->runtime_index_sha256),64) || !CRHex(CRString(h->shader_seed_manifest_sha256),64) ||
       !CRString(h->shader_chain).length || CRString(h->shader_chain).length>128 || !CRString(h->game_version).length ||
       !h->start || !h->fps_supported || !h->set_fps || !h->get_fps || !h->taa_supported || !h->set_taa || !h->get_taa ||
       !h->get_hud || !h->cycle_hud || !h->clear_input || !h->set_focus || !h->input || !CRDisplayHost(h) ||
       h->lifecycle.abi_version!=CANOPY_TOTK_LIFECYCLE_ABI || h->lifecycle.size!=sizeof(h->lifecycle) || !h->lifecycle.read_state)return NULL;
    return h;
}
static BOOL CRReadLifecycle(const struct canopy_totk_host *host,struct canopy_totk_lifecycle_state *out) {
    struct canopy_totk_lifecycle_state state={0};state.abi=CANOPY_TOTK_LIFECYCLE_ABI;state.size=sizeof(state);
    if(!host || host->lifecycle.read_state(&state) || state.abi!=CANOPY_TOTK_LIFECYCLE_ABI || state.size!=sizeof(state) ||
       state.phase>CANOPY_TOTK_MAIN_OBSERVATION_FAILED || state.main_returned>1 || state.main_joined>1 ||
       state.guest_admission_closed>1 || state.joining_guest_children>state.owned_guest_children ||
       (!state.main_returned && state.main_return_code) || (state.main_joined && state.join_error) ||
       (state.main_joined!=(state.phase==CANOPY_TOTK_MAIN_JOINED?1u:0u)) ||
       (state.phase<=CANOPY_TOTK_MAIN_RUNNING && (state.main_returned || state.main_joined || state.join_error)) ||
       ((state.phase==CANOPY_TOTK_MAIN_CLEANUP_OBSERVED || state.phase==CANOPY_TOTK_MAIN_JOINED) && !state.guest_admission_closed))return NO;
    *out=state;return YES;
}
static NSString *CRLifecyclePhase(uint32_t phase) {
    switch(phase) {
        case CANOPY_TOTK_MAIN_NOT_STARTED:return @"notStarted";
        case CANOPY_TOTK_MAIN_RUNNING:return @"running";
        case CANOPY_TOTK_MAIN_CLEANUP_OBSERVED:return @"cleanupObserved";
        case CANOPY_TOTK_MAIN_JOINED:return @"mainJoined";
        case CANOPY_TOTK_MAIN_OBSERVATION_FAILED:return @"observationFailed";
    }
    return @"unavailable";
}
static NSURL *CRTrustedDirectory(NSURL *url) {
    /* Foundation standardization may spell Darwin's physical /private/var
     * as /var again. Strict descriptor traversal needs the actual realpath.
     * Only trusted existing bases use this; derived final leaves do not. */
    char physical[PATH_MAX];
    if(!url.isFileURL || !realpath(url.fileSystemRepresentation,physical))return nil;
    return [NSURL fileURLWithFileSystemRepresentation:physical isDirectory:YES relativeToURL:nil];
}
static NSURL *CRResources(const struct canopy_totk_host *h) {
    NSURL *url=h->resource_directory ? [NSURL fileURLWithPath:CRString(h->resource_directory) isDirectory:YES]:
        [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"GameData" isDirectory:YES];
    return CRTrustedDirectory(url); /* Compiled trusted resource base. */
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
static BOOL CRRelative(NSString *path) {
    if(![path isKindOfClass:NSString.class] || !path.length || path.length>1024)return NO;
    NSArray *parts=[path componentsSeparatedByString:@"/"];if(parts.count>8)return NO;
    NSCharacterSet *bad=[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"] invertedSet];
    for(NSString *part in parts)if(!part.length || part.length>255 || [part isEqual:@"."] || [part isEqual:@".."] ||
        [part rangeOfCharacterFromSet:bad].location!=NSNotFound)return NO;
    return YES;
}
static int CROpenRelative(int root,NSString *path,BOOL directory) {
    if(!CRRelative(path))return -1;
    NSArray *parts=[path componentsSeparatedByString:@"/"];int fd=dup(root);
    for(NSUInteger i=0;fd>=0 && i<parts.count;i++) {
        BOOL dir=directory || i+1<parts.count;
        int child=openat(fd,[parts[i] UTF8String],O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC|(dir?O_DIRECTORY:0));
        close(fd);fd=child;
    }
    return fd;
}
static BOOL CRRangeHash(int fd,uint64_t offset,uint64_t size,NSString *expected,_Atomic int *cancelled) {
    struct stat before,after;struct mng_sha256 *sha=NULL;unsigned char data[65536],digest[32];
    BOOL valid=fd>=0 && !fstat(fd,&before) && S_ISREG(before.st_mode) && before.st_nlink==1 && before.st_size>=0 &&
        offset<=(uint64_t)before.st_size && size<=(uint64_t)before.st_size-offset && !mng_sha256_init(&sha);
    uint64_t done=0;
    while(valid && done<size) {
        if(CRCancelled(cancelled)){valid=NO;break;}
        size_t count=(size_t)MIN((uint64_t)sizeof(data),size-done);
        ssize_t n=pread(fd,data,count,(off_t)(offset+done));if(n<0 && errno==EINTR)continue;
        if(n<=0 || mng_sha256_update(sha,data,(size_t)n)){valid=NO;break;}done+=(uint64_t)n;
    }
    if(valid)valid=!mng_sha256_final(sha,digest) && !fstat(fd,&after) && CRStatEqual(&before,&after);
    mng_sha256_free(sha);if(!valid)return NO;
    char hex[65];for(unsigned i=0;i<32;i++)snprintf(hex+2*i,3,"%02x",digest[i]);return [expected isEqual:CRString(hex)];
}
static NSData *CRManifest(int directory,NSString *expected,_Atomic int *cancelled) {
    int fd=openat(directory,"manifest.tsv",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);struct stat before,after;
    NSData *result=nil;
    if(fd>=0 && !fstat(fd,&before) && S_ISREG(before.st_mode) && before.st_nlink==1 && before.st_size>0 && before.st_size<=(128<<10)) {
        NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)before.st_size];size_t done=0;BOOL valid=YES;
        while(done<data.length) {
            if(CRCancelled(cancelled)){valid=NO;break;}
            ssize_t n=pread(fd,(char *)data.mutableBytes+done,data.length-done,(off_t)done);
            if(n<0 && errno==EINTR)continue;if(n<=0){valid=NO;break;}done+=(size_t)n;
        }
        if(valid && CRRangeHash(fd,0,(uint64_t)before.st_size,expected,cancelled) && !fstat(fd,&after) && CRStatEqual(&before,&after))result=data;
    }
    if(fd>=0)close(fd);return result;
}
struct CROverlayContext {void *rows;_Atomic int *cancelled;};
static int CROverlayEntry(void *opaque,const char *path,uint64_t offset,uint64_t size) {
    struct CROverlayContext *context=opaque;NSMutableDictionary *rows=(__bridge NSMutableDictionary *)context->rows;
    NSMutableDictionary *row=rows[CRString(path)];if(row){row[@"offset"]=@(offset);row[@"originalSize"]=@(size);}return 0;
}
static int CROverlayCancelled(void *opaque) {return CRCancelled(((struct CROverlayContext *)opaque)->cancelled);}
static BOOL CROverlayTree(int directory,NSString *prefix,NSSet *expected,NSUInteger depth,NSUInteger *count) {
    if(depth>8)return NO;
    int copy=openat(directory,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *stream=copy<0?NULL:fdopendir(copy);
    if(!stream){if(copy>=0)close(copy);return NO;}BOOL valid=YES;struct dirent *entry;errno=0;
    while((entry=readdir(stream))) {
        if(!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")){errno=0;continue;}
        NSString *name=CRString(entry->d_name),*path=prefix.length?[prefix stringByAppendingFormat:@"/%@",name]:name;
        struct stat st;if(!name || !CRRelative(path) || ++*count>1280 || fstatat(directory,entry->d_name,&st,AT_SYMLINK_NOFOLLOW)){valid=NO;break;}
        if(S_ISDIR(st.st_mode)) {
            BOOL known=NO;for(NSString *file in expected)if([file hasPrefix:[path stringByAppendingString:@"/"]]){known=YES;break;}
            int child=known?openat(directory,entry->d_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):-1;
            valid=child>=0 && CROverlayTree(child,path,expected,depth+1,count);if(child>=0)close(child);
        } else valid=S_ISREG(st.st_mode) && st.st_nlink==1 && [expected containsObject:path];
        if(!valid)break;errno=0;
    }
    if(!entry && errno)valid=NO;closedir(stream);return valid;
}
static BOOL CROverlay(int resources,int image,const char *manifestPath,NSString *pin,_Atomic int *cancelled) {
    NSString *path=CRString(manifestPath);int directory=CROpenRelative(resources,path.stringByDeletingLastPathComponent,YES);
    NSData *data=directory<0?nil:CRManifest(directory,pin,cancelled);BOOL valid=data!=nil;
    const unsigned char *bytes=data.bytes;
    for(NSUInteger i=0;valid && i<data.length;i++)if(bytes[i]!=9 && bytes[i]!=10 && (bytes[i]<32 || bytes[i]>126))valid=NO;
    NSString *text=valid?[[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding]:nil;
    NSMutableDictionary *rows=[NSMutableDictionary new];NSMutableSet *aliases=[NSMutableSet new];uint64_t total=data.length;
    for(NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if(!valid || CRCancelled(cancelled)){valid=NO;break;}if(!line.length || [line hasPrefix:@"#"])continue;
        NSArray *fields=[line componentsSeparatedByString:@"\t"];
        if(fields.count!=4 || rows.count>=128){valid=NO;break;}
        NSString *name=fields[0],*amount=fields[1],*sha=fields[2],*original=fields[3];
        if(!CRRelative(name) || [name.lowercaseString isEqual:@"manifest.tsv"] || [aliases containsObject:name.lowercaseString] ||
           !amount.length || amount.length>9 || [amount rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location!=NSNotFound ||
           !CRHex(sha,64) || !CRHex(original,64)){valid=NO;break;}
        uint64_t size=amount.longLongValue;if(!size || size>(64u<<20) || total>(256u<<20)-size){valid=NO;break;}
        total+=size;[aliases addObject:name.lowercaseString];rows[name]=[@{@"size":@(size),@"sha":sha,@"original":original} mutableCopy];
    }
    if(!rows.count)valid=NO;
    struct CROverlayContext context={(__bridge void *)rows,cancelled};struct mng_romfs_callbacks callbacks={0};
    callbacks.context=&context;callbacks.entry=CROverlayEntry;callbacks.cancelled=CROverlayCancelled;callbacks.canonical_name=CRCanonical;
    struct mng_romfs_result indexed={0};if(valid)valid=mng_romfs_index_fd(image,&callbacks,&indexed)==MNG_ROMFS_OK;
    for(NSString *name in rows) {
        if(!valid || CRCancelled(cancelled)){valid=NO;break;}NSDictionary *row=rows[name];NSString *original=row[@"original"];
        if(!row[@"offset"] || [row[@"originalSize"] unsignedLongLongValue]>(64u<<20) ||
            !CRRangeHash(image,[row[@"offset"] unsignedLongLongValue],[row[@"originalSize"] unsignedLongLongValue],original,cancelled)){valid=NO;break;}
        int fd=CROpenRelative(directory,name,NO);struct stat st;
        valid=fd>=0 && !fstat(fd,&st) && st.st_size>=0 && (uint64_t)st.st_size==[row[@"size"] unsignedLongLongValue] &&
            CRRangeHash(fd,0,(uint64_t)st.st_size,row[@"sha"],cancelled);if(fd>=0)close(fd);
    }
    NSMutableSet *expected=[NSMutableSet setWithArray:rows.allKeys];[expected addObject:@"manifest.tsv"];NSUInteger count=0;
    if(valid)valid=CROverlayTree(directory,@"",expected,0,&count);
    if(directory>=0)close(directory);return valid;
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
@interface CanopyRuntime ()
- (NSString *)displayValidation;
- (BOOL)observeMainWorker:(NSError **)error;
- (void)captureFailedWorker;
- (NSDictionary *)displayOutcomeForKey:(NSString *)key value:(id)value;
@end
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
    struct mng_display_config _displayConfig;
    CGSize _displayViewSize;
    id _displayHostView,_graphicsSurface;
    id<MTLDevice> _graphicsDevice;
    NSDictionary *_displayDesired;
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
    struct canopy_totk_lifecycle_state lifecycle={0};
    BOOL observed=_nativeEntryInvoked && CRReadLifecycle(_host,&lifecycle);
    if(_nativeEntryInvoked && ([_state isEqual:@"active"] || [_state isEqual:@"inputCaptured"]) &&
       (!observed || lifecycle.phase!=CANOPY_TOTK_MAIN_RUNNING))[self captureFailedWorker];
    NSMutableDictionary *metrics=[NSMutableDictionary dictionaryWithDictionary:_shaderLease.metrics ?: @{}];
    metrics[@"nativeEntryInvoked"]=@(_nativeEntryInvoked);
    if(_nativeEntryInvoked && ([_state isEqual:@"active"] || [_state isEqual:@"inputCaptured"]))metrics[@"frameLimit"]=@(_host->get_fps());
    if(_nativeEntryInvoked && _displayConfig.abi==MNG_DISPLAY_ABI) {
        metrics[@"displayValidation"]=[self displayValidation];
        metrics[@"displaySelectedWidth"]=@(_displayConfig.width);metrics[@"displaySelectedHeight"]=@(_displayConfig.height);
        metrics[@"displayFixedResolution"]=_displayConfig.fixed_resolution?@YES:@NO;metrics[@"displayExperimental"]=_displayConfig.experimental?@YES:@NO;
    }
    if(_nativeEntryInvoked) {
        if(observed) {
            metrics[@"mainWorkerPhase"]=CRLifecyclePhase(lifecycle.phase);
            metrics[@"mainReturned"]=lifecycle.main_returned?@YES:@NO;metrics[@"mainJoined"]=lifecycle.main_joined?@YES:@NO;
            metrics[@"guestAdmissionClosed"]=lifecycle.guest_admission_closed?@YES:@NO;
            metrics[@"ownedGuestChildren"]=@(lifecycle.owned_guest_children);metrics[@"joiningGuestChildren"]=@(lifecycle.joining_guest_children);
            metrics[@"guestJoinFailures"]=@(lifecycle.guest_join_failures);metrics[@"mainJoinError"]=@(lifecycle.join_error);
            if(lifecycle.main_returned)metrics[@"mainReturnCode"]=@(lifecycle.main_return_code);
        } else metrics[@"mainWorkerPhase"]=@"unavailable";
    }
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
    const struct canopy_totk_host *host=CRHost();CGSize viewSize;struct mng_display_resolution display={0};
    if(!CRViewSize(view,&viewSize) || !CRDisplayResolve(host,settings,viewSize,&display)) {
        if(error)*error=CRError(4,@"Native display preferences or oriented game view bounds are invalid.");return NO;
    }
    CAMetalLayer *metalLayer=surface;
    id<MTLDevice> selectedDevice=metalLayer.device ?: MTLCreateSystemDefaultDevice();
    if(selectedDevice)metalLayer.device=selectedDevice;
    /* Resolve only the app-owned cache base; preserve the derived final leaf
     * so a symlink there is still refused by descriptor-relative validation. */
    cache=[CRTrustedDirectory(cache.URLByDeletingLastPathComponent)
        URLByAppendingPathComponent:cache.lastPathComponent isDirectory:YES];
    const char *savePath=saves.fileSystemRepresentation,*identityPath=identity.fileSystemRepresentation;
    if(!savePath || !identityPath || strnlen(savePath,1024)>=1024 || strnlen(identityPath,1024)>=1024) {
        if(error)*error=CRError(4,@"Native save or identity path exceeds the host limit.");return NO;
    }
    _host=CRHost();_titleID=[titleID copy];_state=@"preparing";
    NSMutableDictionary *startup=[settings mutableCopy];
    if(!startup[@"renderHeight"])startup[@"renderHeight"]=@720;if(!startup[@"aspect"])startup[@"aspect"]=@"16:9";
    _startupSettings=[[NSDictionary alloc] initWithDictionary:startup copyItems:YES];atomic_store(&_preflightCancelled,0);activeRuntime=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        int root=CROpenDirectory(self->_root,YES),lease=-1;struct mng_store *store=NULL;
        struct mng_store_verified_assets verified={0};
        NSString *preflightFailure=@"The prepared store could not be verified safely.";
        BOOL valid=root>=0 && mng_store_open(root,&store)==MNG_PREPARE_OK;
        if(valid) {
            mng_store_set_cancel_check(store,CRCancelled,&self->_preflightCancelled);
            preflightFailure=@"The prepared generation could not be verified or retained safely.";
            valid=mng_store_pin_verified_assets(store,self->_host->title_id,generationID.UTF8String,&verified,&lease)==MNG_PREPARE_OK;
        }
        mng_store_close(store);if(root>=0)close(root);
        NSURL *generation=[[[[self->_root URLByAppendingPathComponent:@"titles"] URLByAppendingPathComponent:titleID]
            URLByAppendingPathComponent:@"generations"] URLByAppendingPathComponent:generationID];
        int gen=CROpenDirectory(generation,YES),exefs=gen<0?-1:openat(gen,"exefs",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        int resources=CROpenDirectory(assets,NO);
        if(valid) {
            preflightFailure=@"Prepared asset or trusted resource directories could not be opened safely.";
            valid=gen>=0 && exefs>=0 && resources>=0;
        }
        /* Facts are emitted only after the store fully hashes the generation and
         * acquires its real shared lease. They are not a cross-launch cache. */
        if(valid) {
            preflightFailure=@"The original executable does not match the approved native profile.";
            valid=verified.main.present==1 && [CRDigest(verified.main.sha256) isEqual:CRString(self->_host->original_main_sha256)];
        }
        if(valid) {
            preflightFailure=@"The RomFS image does not match the approved native profile.";
            valid=verified.romfs.present==1 && [CRDigest(verified.romfs.sha256) isEqual:CRString(self->_host->romfs_sha256)];
        }
        if(valid && self->_host->display.profile.flags) {
            preflightFailure=@"Compiled native display overlays do not match their pinned resources or source RomFS.";
            int image=openat(gen,"romfs.bin",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
            valid=image>=0;
            if(valid && (self->_host->display.profile.flags&MNG_DISPLAY_SCENE_1080))valid=CROverlay(resources,image,MNG_DISPLAY_HEAP_MANIFEST,
                CRString(self->_host->display.heap_manifest_sha256),&self->_preflightCancelled);
            if(valid && (self->_host->display.profile.flags&MNG_DISPLAY_FOUR_THREE))valid=CROverlay(resources,image,MNG_DISPLAY_LAYOUT_MANIFEST,
                CRString(self->_host->display.layout_manifest_sha256),&self->_preflightCancelled);
            if(image>=0)close(image);
        }
        int saveFD=CROpenDirectory(saves,YES),identityFD=CROpenDirectory(identity,YES),cacheFD=CROpenDirectory(cache,YES);
        if(saveFD<0 || identityFD<0 || cacheFD<0 || CRSameDirectory(saveFD,identityFD) ||
           CRSameDirectory(saveFD,cacheFD) || CRSameDirectory(identityFD,cacheFD) ||
           CRRelated(saves,identity) || CRRelated(saves,cache) || CRRelated(identity,cache) ||
           CRRelated(generation,saves) || CRRelated(generation,identity) || CRRelated(generation,cache)) {
            if(valid)preflightFailure=@"Private save, identity or cache directories are unsafe or overlap.";valid=NO;
        }
        if(valid)preflightFailure=@"The native RomFS index could not be verified or produced safely.";
        NSURL *indexDirectory=valid?CRIndex(gen,cache,CRString(self->_host->runtime_index_sha256),&self->_preflightCancelled):nil;
        if(!indexDirectory)valid=NO;
        CanopyShaderCacheLease *shaderLease=nil;
        BOOL deviceUnavailable=valid && !selectedDevice;
        if(valid && !atomic_load(&self->_preflightCancelled)) {
            preflightFailure=@"The native graphics device identity could not be verified safely.";
            NSDictionary *deviceIdentity=selectedDevice?[CanopyShaderCache deviceIdentityForDevice:selectedDevice error:NULL]:nil;
            CanopyShaderCache *shaderCache=[[CanopyShaderCache alloc] initWithRootURL:[cache URLByAppendingPathComponent:@"shader-identities" isDirectory:YES]];
            if(deviceIdentity) {
                preflightFailure=@"The private shader seed or cache does not match the approved native profile.";
                NSError *shaderError=nil;
                shaderLease=[shaderCache prepareSeedURL:[assets URLByAppendingPathComponent:@"shader-seed" isDirectory:YES]
                titleID:titleID sourceRomFSSHA256:CRString(self->_host->romfs_sha256)
                expectedManifestSHA256:CRString(self->_host->shader_seed_manifest_sha256) expectedChain:CRString(self->_host->shader_chain)
                deviceIdentity:deviceIdentity cancelled:^BOOL{return atomic_load(&self->_preflightCancelled)!=0;}
                progress:nil error:&shaderError];
                NSNumber *stage=shaderError.userInfo[@"verificationStage"];
                if(!shaderLease && [stage isKindOfClass:NSNumber.class] && stage.unsignedIntegerValue>=1 && stage.unsignedIntegerValue<=21)
                    preflightFailure=[NSString stringWithFormat:@"The private shader seed or cache could not be verified safely (stage %lu).",(unsigned long)stage.unsignedIntegerValue];
            }
            if(!shaderLease)valid=NO;
        }
        if(saveFD>=0)close(saveFD);if(identityFD>=0)close(identityFD);if(cacheFD>=0)close(cacheFD);
        if(gen>=0)close(gen);if(exefs>=0)close(exefs);if(resources>=0)close(resources);
        dispatch_async(dispatch_get_main_queue(),^{
            if(!valid || atomic_load(&self->_preflightCancelled)){if(lease>=0)close(lease);self->_state=@"idle";self->_titleID=nil;activeRuntime=nil;
                completion(NO,atomic_load(&self->_preflightCancelled)?CRError(7,@"Native startup preparation cancelled."):
                    deviceUnavailable?CRError(3,@"No native Metal device is available."):CRError(4,preflightFailure));return;}
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
            CGSize currentViewSize;struct mng_display_resolution selected={0};
            if(!CRViewSize(view,&currentViewSize) || !CRDisplayResolve(self->_host,desired,currentViewSize,&selected)) {
                close(self->_lease);self->_lease=-1;self->_shaderLease=nil;self->_state=@"idle";self->_titleID=nil;activeRuntime=nil;
                completion(NO,CRError(4,@"The native game view bounds are unavailable. Retry startup."));return;
            }
            self->_displayConfig=selected.config;self->_displayViewSize=currentViewSize;self->_displayHostView=view;
            self->_graphicsSurface=surface;self->_graphicsDevice=selectedDevice;
            self->_displayDesired=@{@"renderHeight":desired[@"renderHeight"],@"aspect":desired[@"aspect"]};
            struct canopy_totk_start start={assets.fileSystemRepresentation,assets.fileSystemRepresentation,
                indexDirectory.fileSystemRepresentation,generation.fileSystemRepresentation,saves.fileSystemRepresentation,
                identity.fileSystemRepresentation,cache.fileSystemRepresentation,shaderLease.seedURL.fileSystemRepresentation,shaderLease.cacheURL.fileSystemRepresentation,
                language.UTF8String,fps,taa,hud,
                (__bridge void *)surface,(__bridge void *)view,(__bridge void *)selectedDevice,selected.config};
            self->_nativeEntryInvoked=YES;self->_state=@"starting";
            if(self->_host->start(&start)){[self captureFailedWorker];completion(NO,CRError(5,@"Native startup failed; this single-use process cannot safely relaunch."));return;}
            NSError *lifecycleError=nil;
            if(![self observeMainWorker:&lifecycleError]) {completion(NO,lifecycleError);return;}
            NSString *validation=[self displayValidation];
            if(![validation isEqual:@"pending"] && ![validation isEqual:@"patchesValidated"]) {
                [self captureFailedWorker];completion(NO,CRError(5,@"Native startup did not acknowledge its display configuration; safe teardown is unavailable."));return;
            }
            self->_state=@"inputCaptured";[self applyDesiredSettings:desired];
            if([self->_state isEqual:@"failed"]) {completion(NO,CRError(5,@"The native main worker ended before startup completed; session protections remain owned."));return;}
            completion(YES,nil);
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
- (void)captureFailedWorker {
    _host->clear_input();_host->set_focus(0);_deviceID=0;_state=@"failed";
    /* The main worker is only one owner. No lease, device, view, module or save
     * protection is released; cleanup observation is not a stop or join ACK. */
}
- (BOOL)observeMainWorker:(NSError **)error {
    struct canopy_totk_lifecycle_state lifecycle={0};
    if(_nativeEntryInvoked && CRReadLifecycle(_host,&lifecycle) && lifecycle.phase==CANOPY_TOTK_MAIN_RUNNING)return YES;
    if(_nativeEntryInvoked)[self captureFailedWorker];
    if(error)*error=CRError(5,@"The native main worker ended or its lifecycle could not be observed; session protections remain owned until process exit.");
    return NO;
}
- (NSString *)displayValidation {
    struct mng_display_state state={0};state.abi=MNG_DISPLAY_ABI;state.size=sizeof(state);
    if(!_host || !_nativeEntryInvoked || _host->display.read_state(&state) || state.abi!=MNG_DISPLAY_ABI || state.size!=sizeof(state) ||
       state.validation>MNG_DISPLAY_PATCHES_VALIDATED)return @"unavailable";
    if(state.validation==MNG_DISPLAY_NOT_CONFIGURED)return @"notConfigured";
    if(!CRDisplaySame(&state.config,&_displayConfig) || mng_display_check(&_host->display.profile,&state.config,
        _displayViewSize.width,_displayViewSize.height))return @"unavailable";
    return state.validation==MNG_DISPLAY_PATCHES_VALIDATED?@"patchesValidated":@"pending";
}
- (NSDictionary *)displayOutcomeForKey:(NSString *)key value:(id)value {
    BOOL height=[key isEqual:@"renderHeight"];id effective=height?@(_displayConfig.height):(_displayConfig.aspect==MNG_DISPLAY_FULL?@"4:3":@"16:9");
    NSString *validation=[self displayValidation];CGSize size;struct mng_display_resolution desired={0};
    if(!CRViewSize(_displayHostView,&size) || !CRDisplayResolve(_host,_displayDesired,size,&desired))
        return CROutcome(@"rejected",value,effective,@"Invalid display request or game view bounds; the existing native target remains configured.");
    uint32_t unsupported=height?desired.height_outcome:desired.aspect_outcome;
    BOOL changed=height?desired.config.height!=_displayConfig.height:desired.config.aspect!=_displayConfig.aspect;
    NSString *state=unsupported==MNG_DISPLAY_UNSUPPORTED?@"unsupported":changed?@"restartRequired":@"applied";
    if([validation isEqual:@"unavailable"] || [validation isEqual:@"notConfigured"])state=@"rejected";
    NSString *proof=[validation isEqual:@"patchesValidated"]?@"The native loader completed its checked patch path; no rendered-frame claim.":
        [validation isEqual:@"pending"]?@"Native checked patches are pending; this is configuration only.":@"The native host has not acknowledged a matching display configuration.";
    NSString *timing=[state isEqual:@"restartRequired"]?@"A different target requires a new process. ":
        [state isEqual:@"unsupported"]?@"The requested setting is unavailable; the selected supported target remains in use. ":@"";
    NSString *detail=_displayConfig.experimental?@" Experimental 4:3 retains the existing Vert+ UI/effect limitations.":
        !_displayConfig.fixed_resolution?@" The stock scene may dynamically scale below the selected 720 target.":@"";
    NSMutableDictionary *outcome=[CROutcome(state,value,effective,[NSString stringWithFormat:@"%@Selected scene/canvas target %ux%u. %@%@",timing,
        _displayConfig.width,_displayConfig.height,proof,detail]) mutableCopy];
    outcome[@"validation"]=validation;outcome[@"experimental"]=_displayConfig.experimental?@YES:@NO;return outcome;
}
- (NSDictionary *)applyDesiredSettings:(NSDictionary *)settings {
    NSAssert(NSThread.isMainThread,@"Runtime settings belong on main thread");
    if(_nativeEntryInvoked && ([_state isEqual:@"active"] || [_state isEqual:@"inputCaptured"]))[self observeMainWorker:NULL];
    NSMutableDictionary *states=[NSMutableDictionary dictionary];
    NSMutableDictionary *displayDesired=[(_displayDesired ?: @{}) mutableCopy];
    for(NSString *key in @[@"renderHeight",@"aspect"])if(settings[key])displayDesired[key]=settings[key];
    _displayDesired=[displayDesired copy];
    BOOL active=_nativeEntryInvoked && ([_state isEqual:@"active"] || [_state isEqual:@"inputCaptured"]);
    for(NSString *key in settings) {
        id value=settings[key];NSDictionary *outcome=CROutcome(@"unsupported",value,nil,@"The native host has no application hook for this setting.");
        if(_nativeEntryInvoked && !active) {
            outcome=CROutcome(@"rejected",value,_settingStates[key][@"effectiveValue"],@"The native main worker is unavailable; session protections remain owned.");
        } else if(active && ([key isEqual:@"renderHeight"] || [key isEqual:@"aspect"])) {
            outcome=[self displayOutcomeForKey:key value:value];
        } else if(active && [key isEqual:@"fpsLimit"]) {
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
    if(_nativeEntryInvoked && ![self observeMainWorker:error])return NO;
    if(!_nativeEntryInvoked || (![_state isEqual:@"active"] && ![_state isEqual:@"inputCaptured"])) {
        if(error)*error=CRError(3,@"No active native input target is available.");return NO;}
    _host->clear_input();_host->set_focus(0);_state=@"inputCaptured";return YES;
}
- (BOOL)restoreInput:(NSError **)error {
    NSAssert(NSThread.isMainThread,@"Runtime input belongs on main thread");
    if(_nativeEntryInvoked && ![self observeMainWorker:error])return NO;
    if(![_state isEqual:@"inputCaptured"]){if(error)*error=CRError(3,@"Native input was not captured.");return NO;}
    _host->clear_input();_host->set_focus(1);_state=@"active";return YES;
}
- (BOOL)submitInput:(const struct mng_session_input *)input error:(NSError **)error {
    NSAssert(NSThread.isMainThread,@"Runtime input belongs on main thread");
    if(_nativeEntryInvoked && ![self observeMainWorker:error])return NO;
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
    if([_state isEqual:@"active"] || [_state isEqual:@"inputCaptured"]) {
        if(![self observeMainWorker:error])return NO;
        NSMutableDictionary *states=[_settingStates mutableCopy];
        for(NSString *key in @[@"renderHeight",@"aspect"])if(_displayDesired[key])states[key]=[self displayOutcomeForKey:key value:_displayDesired[key]];
        _settingStates=[states copy];
        if(![@[@"pending",@"patchesValidated"] containsObject:[self displayValidation]]) {if(error)*error=CRError(4,@"The native host returned an invalid display state.");return NO;}
        return YES;
    }
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
