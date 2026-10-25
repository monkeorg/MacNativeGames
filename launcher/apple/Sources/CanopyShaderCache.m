#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#import "CanopyShaderCache.h"
#import <CoreFoundation/CoreFoundation.h>
#include "mng_crypto.h"
#include <TargetConditionals.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define SCFiles 100000u
#define SCFileBytes (UINT64_C(64)<<20)
#define SCTotalBytes (UINT64_C(16)<<30)
#define SCManifestBytes (32u<<20)
static NSError *SCError(NSInteger code) {
    NSString *message=code==2 ? @"Shader preparation was cancelled; private staging was discarded.":
        code==3 ? @"The shader cache is in use; retry after the native session ends.":
        @"The private shader seed, identity or cache could not be verified safely.";
    return [NSError errorWithDomain:@"CanopyShaderCache" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static void SCReport(void (^progress)(NSString *,uint64_t,uint64_t),NSString *phase,uint64_t done,uint64_t total,uint64_t *last) {
    if(!progress)return;struct timespec now={0};BOOL clock=clock_gettime(CLOCK_MONOTONIC,&now)==0;
    uint64_t tick=(uint64_t)now.tv_sec*UINT64_C(1000000000)+(uint64_t)now.tv_nsec;
    if(!*last || done==total || (clock && tick>=*last && tick-*last>=UINT64_C(50000000))) {
        *last=clock ? tick:1;progress(phase,done,total);
    }
}
static BOOL SCHex(id value,NSUInteger length) {
    return [value isKindOfClass:NSString.class] && [value length]==length &&
        [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
static BOOL SCNumber(id value,uint64_t minimum,uint64_t maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double n=[value doubleValue];return isfinite(n) && n>=minimum && n<=maximum && floor(n)==n;
}
static BOOL SCText(id value,NSUInteger maximum) {
    return [value isKindOfClass:NSString.class] && [value length]>0 && [value length]<=maximum &&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound;
}
static BOOL SCStable(const struct stat *a,const struct stat *b) {
    return a->st_dev==b->st_dev && a->st_ino==b->st_ino && a->st_mode==b->st_mode && a->st_nlink==b->st_nlink &&
        a->st_size==b->st_size && a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec &&
        a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec && a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec &&
        a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
}
static BOOL SCPrivate(int fd,BOOL directory) {
    struct stat s;return fd>=0 && !fstat(fd,&s) && (directory ? S_ISDIR(s.st_mode):S_ISREG(s.st_mode)) &&
        s.st_uid==geteuid() && !(s.st_mode&077) && (directory || s.st_nlink==1);
}
static int SCRoot(NSURL *url,BOOL create,BOOL private) {
    const char *path=url.fileSystemRepresentation;
    if (!url.isFileURL || !path || path[0]!='/' || strnlen(path,4096)>=4096) return -1;
    char copy[4096];strcpy(copy,path);size_t n=strlen(copy);
    if (n>1 && copy[n-1]=='/') copy[n-1]=0;
    int fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);char *p=copy+1;
    while (fd>=0 && *p) {
        char *slash=strchr(p,'/');if (slash)*slash=0;
        if (!*p || !strcmp(p,".") || !strcmp(p,"..")) {close(fd);return -1;}
        if (!slash && create && mkdirat(fd,p,0700) && errno!=EEXIST) {close(fd);return -1;}
        int child=openat(fd,p,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);close(fd);fd=child;
        if (!slash)break;p=slash+1;
    }
    if (private && !SCPrivate(fd,YES)) {if(fd>=0)close(fd);return -1;}return fd;
}
static int SCChild(int parent,const char *name,BOOL create) {
    if (create && mkdirat(parent,name,0700) && errno!=EEXIST)return -1;
    int fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (!SCPrivate(fd,YES)) {if(fd>=0)close(fd);return -1;}return fd;
}
static int SCLock(int root) {
    int fd=openat(root,".shader.lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC,0600);struct stat s;
    if (!SCPrivate(fd,NO) || fstat(fd,&s) || s.st_size || flock(fd,LOCK_EX|LOCK_NB)) {if(fd>=0)close(fd);return -1;}return fd;
}
static NSData *SCData(int parent,NSString *name,size_t limit,BOOL private) {
    int fd=openat(parent,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);struct stat a,b;
    if (fd<0)return nil;
    if (fstat(fd,&a) || !S_ISREG(a.st_mode) || a.st_nlink<1 || a.st_size<0 || (uint64_t)a.st_size>limit ||
        (private && !SCPrivate(fd,NO))) {close(fd);return nil;}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)a.st_size];size_t at=0;
    while(at<data.length) {ssize_t n=read(fd,(unsigned char *)data.mutableBytes+at,data.length-at);
        if(n<0 && errno==EINTR)continue;if(n<=0){close(fd);return nil;}at+=(size_t)n;}
    BOOL stable=!fstat(fd,&b) && SCStable(&a,&b);close(fd);return stable ? data:nil;
}
static NSString *SCDigest(NSData *data) {
    struct mng_sha256 *s=NULL;unsigned char digest[32];
    BOOL ok=!mng_sha256_init(&s) && !mng_sha256_update(s,data.bytes,data.length) && !mng_sha256_final(s,digest);
    mng_sha256_free(s);if(!ok)return nil;
    char text[65];for(unsigned i=0;i<32;i++)snprintf(text+2*i,3,"%02x",digest[i]);return [NSString stringWithUTF8String:text];
}
static NSData *SCJSON(id object) {return [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];}
static id SCParse(NSData *data) {return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;}
static BOOL SCWrite(int parent,const char *name,NSData *data) {
    if(!data)return NO;
    int fd=openat(parent,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return NO;
    const unsigned char *p=data.bytes;size_t left=data.length;BOOL ok=YES;
    while(left) {ssize_t n=write(fd,p,left);if(n<0 && errno==EINTR)continue;if(n<=0){ok=NO;break;}p+=(size_t)n;left-=(size_t)n;}
    if(ok && (fchmod(fd,0400) || fsync(fd)))ok=NO;if(close(fd))ok=NO;return ok;
}
static BOOL SCFile(int from,NSString *name,int destination,NSString *expected,BOOL private,
    BOOL (^cancel)(void),void (^progress)(uint64_t),uint64_t *length) {
    int input=openat(from,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC),output=-1;
    struct stat before,after;struct mng_sha256 *hash=NULL;BOOL ok=NO;unsigned char bytes[65536],digest[32];
    if(input<0 || fstat(input,&before) || !S_ISREG(before.st_mode) || before.st_nlink<1 || before.st_size<0 ||
        (uint64_t)before.st_size>SCFileBytes || (private && !SCPrivate(input,NO)) || mng_sha256_init(&hash))goto done;
    if(destination>=0) {output=openat(destination,name.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(output<0)goto done;}
    uint64_t total=0;
    for(;;) {
        if(cancel && cancel())goto done;
        ssize_t n=read(input,bytes,sizeof(bytes));if(n<0 && errno==EINTR)continue;if(n<0)goto done;if(!n)break;
        if((uint64_t)n>(uint64_t)before.st_size-total || mng_sha256_update(hash,bytes,(size_t)n))goto done;
        if(output>=0) {size_t at=0;while(at<(size_t)n) {ssize_t wrote=write(output,bytes+at,(size_t)n-at);
            if(wrote<0 && errno==EINTR)continue;if(wrote<=0)goto done;at+=(size_t)wrote;}}
        total+=(uint64_t)n;if(progress)progress((uint64_t)n);
    }
    if(total!=(uint64_t)before.st_size || fstat(input,&after) || !SCStable(&before,&after) || mng_sha256_final(hash,digest))goto done;
    char hex[65];for(unsigned i=0;i<32;i++)snprintf(hex+2*i,3,"%02x",digest[i]);
    if(![expected isEqualToString:[NSString stringWithUTF8String:hex]])goto done;
    if(output>=0 && (fchmod(output,0400) || fsync(output)))goto done;
    *length=total;ok=YES;
done:
    mng_sha256_free(hash);mng_secure_clear(bytes,sizeof(bytes));if(input>=0)close(input);if(output>=0 && close(output))ok=NO;return ok;
}
static BOOL SCName(NSString *name) {
    static NSRegularExpression *pattern;static dispatch_once_t once;
    dispatch_once(&once,^{pattern=[NSRegularExpression regularExpressionWithPattern:
        @"^(?:[0-9a-f]{64}\\.variants|[0-9a-f]{64}-[0-9a-f]{12}_b\\.(?:metal|json|metallib)|pso_(?:manifest|list|title)\\.tsv|shader-keys\\.json)$" options:0 error:nil];});
    if(![name isKindOfClass:NSString.class] || name.length>=128)return NO;
    NSTextCheckingResult *match=[pattern firstMatchInString:name options:0 range:NSMakeRange(0,name.length)];
    return match && NSEqualRanges(match.range,NSMakeRange(0,name.length));
}
static BOOL SCShape(int directory,NSSet<NSString *> *expected,BOOL (^cancel)(void)) {
    int fd=openat(directory,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return NO;
    DIR *d=fdopendir(fd);if(!d){close(fd);return NO;}size_t count=0;BOOL ok=YES;struct dirent *e;errno=0;
    while((e=readdir(d))) {if(!strcmp(e->d_name,".") || !strcmp(e->d_name,".."))continue;
        NSString *name=[NSString stringWithUTF8String:e->d_name];struct stat s;
        if((cancel && cancel()) || ++count>SCFiles+4 || !name || ![expected containsObject:name] || fstatat(directory,e->d_name,&s,AT_SYMLINK_NOFOLLOW) ||
            !S_ISREG(s.st_mode) || s.st_nlink!=1 || s.st_uid!=geteuid() || (s.st_mode&077)){ok=NO;break;}errno=0;}
    if(!e && errno)ok=NO;closedir(d);return ok && count==expected.count;
}
static BOOL SCDeps(id deps) {
    if(![deps isKindOfClass:NSDictionary.class] || [deps count]>4)return NO;
    for(id kind in deps) {
        if(![@[@"tex",@"img",@"attr",@"fout"] containsObject:kind] || ![deps[kind] isKindOfClass:NSDictionary.class] || [deps[kind] count]>1024)return NO;
        for(NSString *slot in deps[kind]) {if(slot.length>5 || !slot.length || [slot rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location!=NSNotFound)return NO;
            id value=deps[kind][slot];if([kind isEqual:@"img"]) {
                if(![value isKindOfClass:NSDictionary.class] || [value count]>2)return NO;
                for(id key in value)if(![@[@"type",@"fmt"] containsObject:key] || !SCText(value[key],64))return NO;
            }
            else if(!SCText(value,64))return NO;
        }
    }
    return YES;
}
static BOOL SCSeedStructure(int seed,NSDictionary *manifest,NSArray<NSString *> *names,BOOL (^cancel)(void)) {
    NSDictionary *files=manifest[@"files"];NSMutableSet *variants=[NSMutableSet new],*indexed=[NSMutableSet new];NSMutableDictionary *dependencies=[NSMutableDictionary new];
    for(NSString *name in names) if([name hasSuffix:@"_b.metal"]) {
        if(cancel && cancel())return NO;
        NSString *variant=[name substringToIndex:name.length-8];[variants addObject:variant];
        if(!files[[variant stringByAppendingString:@"_b.json"]])return NO;
    }
    if(variants.count!=[manifest[@"shaders"] unsignedLongLongValue])return NO;
    for(NSString *name in names) {@autoreleasepool {
        if(cancel && cancel())return NO;
        if([name hasSuffix:@"_b.json"] || [name hasSuffix:@"_b.metallib"]) {
            NSString *variant=[name substringToIndex:name.length-([name hasSuffix:@".json"]?7:11)];
            if(![variants containsObject:variant])return NO;
        }
        if([name hasSuffix:@"_b.json"]) {
            NSDictionary *reflection=SCParse(SCData(seed,name,16u<<20,YES));
            NSString *variant=[name substringToIndex:name.length-7];
            if(![reflection isKindOfClass:NSDictionary.class] || ![reflection[@"chain"] isEqual:manifest[@"chain"]] ||
                ![reflection[@"key"] isEqual:[variant stringByAppendingString:@"_b"]] ||
                ![@[@"vs",@"ps",@"cs"] containsObject:reflection[@"stage"]] || !SCDeps(reflection[@"deps"]) || !SCText(reflection[@"entry"],128))return NO;
            dependencies[variant]=SCDigest(SCJSON(reflection[@"deps"]));
        }
        if([name hasSuffix:@".variants"]) {
            NSArray *rows=SCParse(SCData(seed,name,16u<<20,YES));if(![rows isKindOfClass:NSArray.class] || !rows.count || rows.count>4096)return NO;
            NSString *prefix=[[name substringToIndex:64] stringByAppendingString:@"-"];
            for(NSDictionary *row in rows) {if((cancel && cancel()) || ![row isKindOfClass:NSDictionary.class] || ![row[@"variant"] isKindOfClass:NSString.class] ||
                ![row[@"variant"] hasPrefix:prefix] || ![variants containsObject:row[@"variant"]] ||
                [indexed containsObject:row[@"variant"]] || !SCDeps(row[@"deps"])) {
                    return NO;
                }
                [indexed addObject:row[@"variant"]];
            }
        }
        if([name isEqual:@"shader-keys.json"]) {
            NSDictionary *scope=SCParse(SCData(seed,name,16u<<20,YES));if(![scope isKindOfClass:NSDictionary.class])return NO;id keys=scope[@"keys"];
            if(!SCNumber(scope[@"schema"],1,1) || ![scope[@"chain"] isEqual:manifest[@"chain"]] ||
                ![scope[@"version"] isEqual:manifest[@"version"]] || ![scope[@"source_romfs_sha256"] isEqual:manifest[@"source_romfs_sha256"]] ||
                ![keys isKindOfClass:NSArray.class] || ![keys count] || [keys count]>SCFiles)return NO;
            NSMutableSet *unique=[NSMutableSet new];for(id key in keys) {if(!SCHex(key,64) || [unique containsObject:key])return NO;[unique addObject:key];}
        }
    }}
    /* All reflection dependencies must exist before comparing index rows;
     * filename order is deliberately not a prerequisite. */
    for(NSString *name in names)if([name hasSuffix:@".variants"]) {@autoreleasepool {
        if(cancel && cancel())return NO;
        NSArray *rows=SCParse(SCData(seed,name,16u<<20,YES));
        if(![rows isKindOfClass:NSArray.class] || !rows.count || rows.count>4096)return NO;
        for(NSDictionary *row in rows)if((cancel && cancel()) || ![row isKindOfClass:NSDictionary.class] ||
            ![row[@"variant"] isKindOfClass:NSString.class] || !SCDeps(row[@"deps"]) ||
            ![dependencies[row[@"variant"]] isEqual:SCDigest(SCJSON(row[@"deps"]))])return NO;
    }}
    return [variants isEqualToSet:indexed];
}
/* Bounded descriptor-relative metadata walk. Only private regular single-link
 * files and directories are accepted; no symlink traversal or outside deletes. */
static BOOL SCWalk(int directory,unsigned depth,uint64_t *bytes,uint64_t *count,BOOL remove,BOOL strict,BOOL (^cancel)(void)) {
    struct stat owner;
    if(depth>8 || fstat(directory,&owner) || !S_ISDIR(owner.st_mode) || owner.st_uid!=geteuid() || (strict && (owner.st_mode&077)))return NO;
    int fd=openat(directory,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return NO;
    DIR *d=fdopendir(fd);if(!d){close(fd);return NO;}BOOL ok=YES;struct dirent *e;errno=0;
    while((e=readdir(d))) {if(!strcmp(e->d_name,".") || !strcmp(e->d_name,".."))continue;struct stat s;
        if((cancel && cancel()) || ++*count>200010 || fstatat(directory,e->d_name,&s,AT_SYMLINK_NOFOLLOW) || s.st_uid!=geteuid() || (strict && (s.st_mode&077))){ok=NO;break;}
        if(S_ISDIR(s.st_mode)) {int child=openat(directory,e->d_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);ok=child>=0 && SCWalk(child,depth+1,bytes,count,remove,strict,cancel);if(child>=0)close(child);
            if(ok && remove && unlinkat(directory,e->d_name,AT_REMOVEDIR))ok=NO;
        } else {if(!S_ISREG(s.st_mode) || s.st_nlink!=1 || s.st_size<0 || (uint64_t)s.st_size>(UINT64_C(128)<<30)-*bytes)ok=NO;
            else {*bytes+=(uint64_t)s.st_size;if(remove && unlinkat(directory,e->d_name,0))ok=NO;}}
        if(!ok)break;errno=0;
    }
    if(!e && errno)ok=NO;closedir(d);return ok;
}
static BOOL SCDevice(NSDictionary *device) {
    if(![device isKindOfClass:NSDictionary.class] || device.count!=8 || !SCNumber(device[@"schema"],1,1) ||
        ![@[@"iphoneos",@"macos"] containsObject:device[@"platform"]] || !SCText(device[@"os"],256) || !SCText(device[@"device"],256) ||
        !SCHex(device[@"registry"],16) || ![device[@"mathMode"] isEqual:@"safe"] || ![device[@"mslVersion"] isEqual:@"20300"])return NO;
    NSArray *families=device[@"families"];if(![families isKindOfClass:NSArray.class] || !families.count || families.count>32)return NO;
    NSNumber *previous=nil;for(id family in families) {if(!SCNumber(family,1,10000) || (previous && [previous compare:family]!=NSOrderedAscending))return NO;previous=family;}return YES;
}
static BOOL SCIdentityShape(int folder) {
    int fd=openat(folder,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return NO;
    DIR *d=fdopendir(fd);if(!d){close(fd);return NO;}BOOL ok=YES;unsigned count=0;struct dirent *e;errno=0;
    while((e=readdir(d))) {if(!strcmp(e->d_name,".") || !strcmp(e->d_name,".."))continue;struct stat s;
        BOOL directory=!strcmp(e->d_name,"seed") || !strcmp(e->d_name,"runtime");
        BOOL file=!strcmp(e->d_name,"identity.json") || !strcmp(e->d_name,".lease");
        if(++count>4 || (!directory && !file) || fstatat(folder,e->d_name,&s,AT_SYMLINK_NOFOLLOW) || s.st_uid!=geteuid() ||
            (s.st_mode&077) || (directory ? !S_ISDIR(s.st_mode):(!S_ISREG(s.st_mode) || s.st_nlink!=1))){ok=NO;break;}errno=0;
    }
    if(!e && errno)ok=NO;closedir(d);return ok && count==4;
}
static BOOL SCIdentity(NSDictionary *identity) {
    return [identity isKindOfClass:NSDictionary.class] && identity.count==9 && SCNumber(identity[@"schema"],1,1) &&
        SCHex(identity[@"titleID"],16) && SCHex(identity[@"sourceRomFSSHA256"],64) && SCHex(identity[@"manifestSHA256"],64) &&
        SCHex(identity[@"translatorSHA256"],64) && SCHex(identity[@"spirvCrossSHA256"],64) && SCHex(identity[@"preparationSHA256"],64) &&
        SCText(identity[@"chain"],128) && SCDevice(identity[@"device"]);
}
@interface CanopyShaderCacheLease ()
- (instancetype)initWithRoot:(NSURL *)root identity:(NSString *)identity fd:(int)fd metrics:(NSDictionary *)metrics;
@end
@implementation CanopyShaderCacheLease {int _lease;}
- (instancetype)initWithRoot:(NSURL *)root identity:(NSString *)identity fd:(int)fd metrics:(NSDictionary *)metrics {
    if((self=[super init])) {_lease=fd;_identityHash=[identity copy];_metrics=[metrics copy];
        _seedURL=[root URLByAppendingPathComponent:@"seed" isDirectory:YES];_cacheURL=[root URLByAppendingPathComponent:@"runtime" isDirectory:YES];}return self;
}
- (void)dealloc {if(_lease>=0)close(_lease);}
@end
@implementation CanopyShaderCache {NSURL *_root;}
- (instancetype)initWithRootURL:(NSURL *)root {if((self=[super init]))_root=[root copy];return self;}
+ (NSDictionary *)deviceIdentityForDevice:(id<MTLDevice>)device error:(NSError **)error {
    if(!device){if(error)*error=SCError(1);return nil;}
    NSMutableArray *families=[NSMutableArray new];
    for(NSNumber *family in @[@1001,@1002,@1003,@1004,@1005,@1006,@1007,@1008,@1009,@2001,@2002,@3001,@3002,@3003,@5001])
        if([device supportsFamily:(MTLGPUFamily)family.unsignedIntegerValue])[families addObject:family];
#if TARGET_OS_IPHONE
    NSString *platform=@"iphoneos";
#else
    NSString *platform=@"macos";
#endif
    NSDictionary *identity=@{@"schema":@1,@"platform":platform,@"os":NSProcessInfo.processInfo.operatingSystemVersionString,
        @"device":device.name ?: @"",@"registry":[NSString stringWithFormat:@"%016llx",(unsigned long long)device.registryID],
        @"families":families,@"mathMode":@"safe",@"mslVersion":@"20300"};
    if(!SCDevice(identity)){if(error)*error=SCError(1);return nil;}return identity;
}
- (CanopyShaderCacheLease *)prepareSeedURL:(NSURL *)source titleID:(NSString *)title sourceRomFSSHA256:(NSString *)romfs
    expectedManifestSHA256:(NSString *)manifestSHA expectedChain:(NSString *)chain deviceIdentity:(NSDictionary *)device
    cancelled:(BOOL (^)(void))cancel progress:(void (^)(NSString *,uint64_t,uint64_t))progress error:(NSError **)error {
    CanopyShaderCacheLease *result=nil;int root=-1,lock=-1,input=-1,folder=-1,seed=-1,runtime=-1,lease=-1,stage=-1;
    NSString *stageName=nil,*identityHash=nil;NSData *raw=nil,*receipt=nil;NSDictionary *manifest=nil,*identity=nil;NSArray *names=nil;NSURL *owned=nil;
    NSUInteger verificationStage=1; /* Fixed redacted stage IDs, never input-derived text. */
    NSMutableDictionary *files=nil;NSMutableSet *expected=nil;uint64_t copied=0,reused=0,total=0;__block uint64_t done=0,lastProgress=0;BOOL fresh=NO,published=NO;
    if(!SCHex(title,16) || !SCHex(romfs,64) || !SCHex(manifestSHA,64) || !SCText(chain,128) || !SCDevice(device))goto finish;
    if(cancel && cancel())goto finish;
    verificationStage=2;device=SCParse(SCJSON(device));if(!SCDevice(device))goto finish;
    verificationStage=3;root=SCRoot(_root,YES,YES);if(root<0)goto finish;lock=SCLock(root);if(lock<0)goto finish;
    verificationStage=4;input=SCRoot(source,NO,NO);if(input<0)goto finish;
    verificationStage=5;raw=SCData(input,@"seed-manifest.json",SCManifestBytes,NO);
    if(![SCDigest(raw) isEqual:manifestSHA])goto finish;
    verificationStage=6;manifest=SCParse(raw);
    if(![manifest isKindOfClass:NSDictionary.class] || !SCNumber(manifest[@"schema"],1,1) || !SCNumber(manifest[@"shaders"],1,SCFiles) ||
        ![manifest[@"chain"] isEqual:chain] || ![manifest[@"source_romfs_sha256"] isEqual:romfs] ||
        !SCText(manifest[@"game"],64) || !SCText(manifest[@"version"],64) || !SCHex(manifest[@"translator_sha256"],64) ||
        !SCHex(manifest[@"spirv_cross_sha256"],64) || !SCHex(manifest[@"preparation_sha256"],64) ||
        !SCHex(manifest[@"shader_map_sha256"],64) || ![manifest[@"files"] isKindOfClass:NSDictionary.class] ||
        ![manifest[@"files"] count] || [manifest[@"files"] count]>SCFiles)goto finish;
    verificationStage=7;files=[manifest[@"files"] mutableCopy];
    for(id name in files)if((cancel && cancel()) || !SCName(name) || !SCHex(files[name],64))goto finish;
    files[@"shader_map.tsv"]=manifest[@"shader_map_sha256"];names=[files.allKeys sortedArrayUsingSelector:@selector(compare:)];
    identity=@{@"schema":@1,@"titleID":title,@"sourceRomFSSHA256":romfs,@"manifestSHA256":manifestSHA,@"chain":chain,
        @"translatorSHA256":manifest[@"translator_sha256"],@"spirvCrossSHA256":manifest[@"spirv_cross_sha256"],
        @"preparationSHA256":manifest[@"preparation_sha256"],@"device":device};
    verificationStage=8;identityHash=SCDigest(SCJSON(identity));if(!identityHash)goto finish;
    receipt=SCJSON(@{@"schema":@1,@"identityHash":identityHash,@"identity":identity});
    verificationStage=9;folder=openat(root,identityHash.UTF8String,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(folder<0 && errno!=ENOENT)goto finish;
    fresh=folder<0;
    if(!fresh && (!SCPrivate(folder,YES) || ![SCData(folder,@"identity.json",16384,YES) isEqual:receipt]))goto finish;
    verificationStage=10;if(fresh) {
        stageName=[@".shader-stage-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
        if(mkdirat(root,stageName.UTF8String,0700)){stageName=nil;goto finish;}
        stage=SCChild(root,stageName.UTF8String,NO);if(stage<0)goto finish;folder=dup(stage);if(folder<0)goto finish;
    }
    verificationStage=11;seed=SCChild(folder,"seed",fresh);runtime=SCChild(folder,"runtime",YES);if(seed<0 || runtime<0)goto finish;
    /* Keep the legacy renderer on its existing per-file import path. Its
     * empty-folder clone path chmods the mutable cache0755. This private marker
     * is ignored by shader filename filters and prevents that path entirely. */
    verificationStage=12;struct stat marker;
    if(fstatat(runtime,".canopy-private-cache",&marker,AT_SYMLINK_NOFOLLOW)) {
        if(errno!=ENOENT || !SCWrite(runtime,".canopy-private-cache",[NSData data]))goto finish;
    } else {int fd=openat(runtime,".canopy-private-cache",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
        BOOL valid=SCPrivate(fd,NO) && !fstat(fd,&marker) && marker.st_size==0;if(fd>=0)close(fd);if(!valid)goto finish;}
    verificationStage=13;total=raw.length;
    for(NSString *name in names) {struct stat s;if(cancel && cancel())goto finish;
        if(fstatat(fresh ? input:seed,name.fileSystemRepresentation,&s,AT_SYMLINK_NOFOLLOW) || !S_ISREG(s.st_mode) ||
            s.st_size<0 || (uint64_t)s.st_size>SCFileBytes || (uint64_t)s.st_size>SCTotalBytes-total) {
                goto finish;
            }
        total+=(uint64_t)s.st_size;
    }
    verificationStage=14;for(NSString *name in names) {@autoreleasepool {uint64_t bytes=0;
        if(!SCFile(fresh ? input:seed,name,fresh ? seed:-1,files[name],!fresh,cancel,^(uint64_t n){
            done+=n;SCReport(progress,fresh ? @"copy-private-shader-seed":@"verify-private-shader-seed",done,total,&lastProgress);
        },&bytes))goto finish;
        if(fresh)copied+=bytes;else reused+=bytes;
    }}
    verificationStage=15;if(fresh && (!SCWrite(seed,"seed-manifest.json",raw) || !SCWrite(folder,"identity.json",receipt)))goto finish;
    verificationStage=16;if(![SCData(seed,@"seed-manifest.json",SCManifestBytes,YES) isEqual:raw] ||
        !SCSeedStructure(seed,manifest,[manifest[@"files"] allKeys],cancel))goto finish;
    done+=raw.length;if(fresh)copied+=raw.length;else reused+=raw.length;
    SCReport(progress,fresh ? @"copy-private-shader-seed":@"verify-private-shader-seed",done,total,&lastProgress);
    expected=[NSMutableSet setWithArray:names];[expected addObject:@"seed-manifest.json"];
    verificationStage=17;if(!SCShape(seed,expected,cancel))goto finish;
    verificationStage=18;uint64_t runtimeBytes=0,runtimeCount=0;
    if(!SCWalk(runtime,0,&runtimeBytes,&runtimeCount,NO,NO,cancel))goto finish;
    if(cancel && cancel())goto finish;
    verificationStage=19;if(fresh) {lease=openat(folder,".lease",O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
        if(lease<0 || fchmod(lease,0400) || fsync(lease) || fsync(seed) || fsync(runtime) || fsync(folder))goto finish;
    } else lease=openat(folder,".lease",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    verificationStage=20;struct stat st;if(!SCPrivate(lease,NO) || fstat(lease,&st) || st.st_size || flock(lease,LOCK_SH|LOCK_NB) || !SCIdentityShape(folder))goto finish;
    verificationStage=21;if(fresh) {if(cancel && cancel())goto finish;
        if(renameatx_np(root,stageName.UTF8String,root,identityHash.UTF8String,RENAME_EXCL))goto finish;
        stageName=nil;published=YES;if(fsync(root))goto finish;
    }
    owned=[_root URLByAppendingPathComponent:identityHash isDirectory:YES];
    result=[[CanopyShaderCacheLease alloc] initWithRoot:owned identity:identityHash fd:lease
        metrics:@{@"seedCopiedBytes":@(copied),@"seedReusedBytes":@(reused),@"seedFiles":@(names.count+1),@"cacheReused":(fresh ? @NO:@YES),@"metadataWrittenBytes":@(fresh ? receipt.length:0)}];if(result)lease=-1;
finish:
    if(lease>=0)close(lease);if(runtime>=0)close(runtime);if(seed>=0)close(seed);if(folder>=0)close(folder);
    if(stage>=0 && stageName){uint64_t bytes=0,count=0;(void)SCWalk(stage,0,&bytes,&count,YES,YES,nil);}if(stage>=0)close(stage);
    if(stageName && root>=0)(void)unlinkat(root,stageName.UTF8String,AT_REMOVEDIR);
    if(input>=0)close(input);if(lock>=0)close(lock);if(root>=0)close(root);
    if(!result && error) {
        NSError *base=SCError(!published && cancel && cancel() ? 2:1);
        NSMutableDictionary *info=[base.userInfo mutableCopy];info[@"verificationStage"]=@(verificationStage);
        *error=[NSError errorWithDomain:base.domain code:base.code userInfo:info];
    }return result;
}
/* Storage controls validate the class-owned identity receipt before walking.
 * No actual device details or caller/source paths appear in returned metrics. */
- (NSDictionary *)receiptAt:(int)folder identity:(NSString *)hash title:(NSString *)title {
    NSDictionary *receipt=SCParse(SCData(folder,@"identity.json",16384,YES));
    if(![receipt isKindOfClass:NSDictionary.class] || receipt.count!=3 || !SCNumber(receipt[@"schema"],1,1) ||
        ![receipt[@"identityHash"] isEqual:hash] || ![receipt[@"identity"] isKindOfClass:NSDictionary.class] ||
        !SCIdentity(receipt[@"identity"]) || ![receipt[@"identity"][@"titleID"] isEqual:title] ||
        ![SCDigest(SCJSON(receipt[@"identity"])) isEqual:hash]) {
        return nil;
    }
    return receipt;
}
- (NSArray *)identitiesForTitleID:(NSString *)title error:(NSError **)error {
    if(!SCHex(title,16)){if(error)*error=SCError(1);return nil;}int root=SCRoot(_root,NO,YES),lock=root<0 ? -1:SCLock(root);
    if(lock<0){if(root>=0)close(root);if(error)*error=SCError(1);return nil;}
    NSMutableArray *result=[NSMutableArray new];int fd=openat(root,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *d=fd>=0 ? fdopendir(fd):NULL;
    if(!d){if(fd>=0)close(fd);close(lock);close(root);if(error)*error=SCError(1);return nil;}
    BOOL ok=YES;NSUInteger count=0;struct dirent *e;errno=0;
    while((e=readdir(d))) {
        if(!strcmp(e->d_name,".") || !strcmp(e->d_name,"..")){errno=0;continue;}
        if(++count>4096){ok=NO;break;}
        NSString *name=[NSString stringWithUTF8String:e->d_name];if(!SCHex(name,64)){errno=0;continue;}
        int folder=SCChild(root,e->d_name,NO);
        if(folder<0){ok=NO;break;}if([self receiptAt:folder identity:name title:title])[result addObject:name];close(folder);errno=0;}
    if(!e && errno)ok=NO;closedir(d);close(lock);close(root);if(!ok){if(error)*error=SCError(1);return nil;}return [result sortedArrayUsingSelector:@selector(compare:)];
}
- (NSDictionary *)controlIdentity:(NSString *)hash title:(NSString *)title action:(unsigned)action error:(NSError **)error {
    int root=-1,lock=-1,folder=-1,lease=-1,seed=-1,runtime=-1;NSDictionary *result=nil;BOOL busy=NO;
    if(!SCHex(hash,64) || !SCHex(title,16))goto done;
    root=SCRoot(_root,NO,YES);if(root<0)goto done;lock=SCLock(root);if(lock<0){busy=YES;goto done;}
    folder=SCChild(root,hash.UTF8String,NO);if(folder<0 || ![self receiptAt:folder identity:hash title:title] || !SCIdentityShape(folder))goto done;
    seed=SCChild(folder,"seed",NO);runtime=SCChild(folder,"runtime",NO);if(seed<0 || runtime<0)goto done;
    lease=openat(folder,".lease",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);struct stat s;
    if(!SCPrivate(lease,NO) || fstat(lease,&s) || s.st_size)goto done;
    if(action && flock(lease,LOCK_EX|LOCK_NB)){busy=YES;goto done;}
    uint64_t seedBytes=0,runtimeBytes=0,count=0;
    if(!SCWalk(seed,0,&seedBytes,&count,NO,YES,nil) || !SCWalk(runtime,0,&runtimeBytes,&count,NO,NO,nil))goto done;
    if(action==1) {uint64_t bytes=0,n=0;if(!SCWalk(runtime,0,&bytes,&n,YES,NO,nil) ||
        !SCWrite(runtime,".canopy-private-cache",[NSData data]) || fsync(runtime))goto done;}
    if(action==2) {uint64_t bytes=0,n=0;if(!SCWalk(seed,0,&bytes,&n,YES,YES,nil) || !SCWalk(runtime,0,&bytes,&n,YES,NO,nil))goto done;
        if(unlinkat(folder,"seed",AT_REMOVEDIR) || unlinkat(folder,"runtime",AT_REMOVEDIR) || unlinkat(folder,"identity.json",0) ||
            unlinkat(folder,".lease",0) || unlinkat(root,hash.UTF8String,AT_REMOVEDIR) || fsync(root))goto done;}
    result=@{@"seedBytes":@(seedBytes),@"runtimeBytes":@(runtimeBytes),@"filesAndDirectories":@(count),@"clearedBytes":@(action ? (action==1 ? runtimeBytes:seedBytes+runtimeBytes):0)};
done:
    if(runtime>=0)close(runtime);if(seed>=0)close(seed);if(lease>=0)close(lease);if(folder>=0)close(folder);if(lock>=0)close(lock);if(root>=0)close(root);
    if(!result && error)*error=SCError(busy ? 3:1);return result;
}
- (NSDictionary *)usageForIdentityHash:(NSString *)hash titleID:(NSString *)title error:(NSError **)error {return [self controlIdentity:hash title:title action:0 error:error];}
- (BOOL)clearRuntimeForIdentityHash:(NSString *)hash titleID:(NSString *)title error:(NSError **)error {return [self controlIdentity:hash title:title action:1 error:error]!=nil;}
- (BOOL)removeIdentityHash:(NSString *)hash titleID:(NSString *)title error:(NSError **)error {return [self controlIdentity:hash title:title action:2 error:error]!=nil;}
@end
