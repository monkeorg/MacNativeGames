#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#import "CanopyProviderCache.h"
#import "CanopyCacheFS.h"
#import <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>

static NSError *PCError(void){return [NSError errorWithDomain:@"CanopyProviderCache" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The cache is active, unsafe, unsupported or awaiting recorded recovery. Existing unrecorded data was preserved. Reload before retrying; recorded removal may have progressed."}];}
static BOOL PCNumber(id value,uint64_t maximum){if(![value isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID())return NO;double n=[value doubleValue];return isfinite(n)&&n>=0&&n<=maximum&&floor(n)==n;}
static BOOL PCText(id value,NSUInteger maximum){return [value isKindOfClass:NSString.class]&&[value length]>0&&[value length]<=maximum&&[value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound;}
static BOOL PCTitle(id title){return CCFHex(title,16)&&![title isEqual:@"0000000000000000"];}
static NSArray *PCNames(int fd){
    int copy=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *d=copy<0?NULL:fdopendir(copy);if(!d){if(copy>=0)close(copy);return nil;}
    NSMutableArray *names=[NSMutableArray new];BOOL ok=YES;unsigned count=0;struct dirent *e;errno=0;
    while((e=readdir(d))){if(!strcmp(e->d_name,".")||!strcmp(e->d_name,"..")){errno=0;continue;}
        if(++count>128){ok=NO;break;}NSString *name=[NSString stringWithUTF8String:e->d_name];if(!name){ok=NO;break;}[names addObject:name];errno=0;}
    if(!e&&errno)ok=NO;closedir(d);return ok?[names sortedArrayUsingSelector:@selector(compare:)]:nil;
}
static BOOL PCExact(int fd,NSArray<NSString *> *names){NSArray *actual=PCNames(fd);return actual&&[[NSSet setWithArray:actual] isEqual:[NSSet setWithArray:names]];}
static BOOL PCMKReceipt(int folder,NSString *identifier){
    NSData *raw=CCFData(folder,"identity.json",16384);if(![CCFDigest(raw) isEqual:identifier])return NO;
    id value=[NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL];
    if(![value isKindOfClass:NSDictionary.class]||[value count]!=10)return NO;NSDictionary *identity=value;
    NSData *canonical=[NSJSONSerialization dataWithJSONObject:identity options:NSJSONWritingSortedKeys error:NULL];
    return [canonical isEqual:raw]&&PCNumber(identity[@"schema"],1)&&[identity[@"schema"] unsignedIntValue]==1&&
        [identity[@"titleID"] isEqual:@"0100152000022000"]&&PCNumber(identity[@"revision"],UINT32_MAX)&&
        CCFHex(identity[@"romfs"],64)&&CCFHex(identity[@"seed"],64)&&CCFHex(identity[@"recipe"],64)&&
        PCText(identity[@"chain"],128)&&CCFHex(identity[@"deviceRegistry"],16)&&PCText(identity[@"device"],256)&&PCText(identity[@"os"],256);
}
static BOOL PCMKShape(int folder,NSString *identifier){
    if(!PCMKReceipt(folder,identifier)||!PCExact(folder,@[@"identity.json",@".lease",@"seed",@"runtime"]))return NO;
    int seed=CCFChild(folder,"seed"),runtime=CCFChild(folder,"runtime");BOOL ok=seed>=0&&runtime>=0;
    if(seed>=0)close(seed);if(runtime>=0)close(runtime);return ok;
}
static BOOL PCFolder(int parent,int target,NSString *identifier,CCFFamily family,NSString *title){
    if(family==CCFMKIdentity)return PCMKShape(target,identifier);
    if(family==CCFMKRuntime)return PCMKShape(parent,identifier);
    NSString *prefix=[NSString stringWithFormat:@"romfs-folders-v1-%@-",title];
    return [identifier hasPrefix:prefix]&&CCFHex([identifier substringFromIndex:prefix.length],64)&&CCFPrivate(target,YES);
}
static int PCLock(int root,const char *leaf){
    int fd=openat(root,leaf,O_RDWR|O_CREAT|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC,0600);struct stat st={0},named={0};
    if(!CCFPrivate(fd,NO)||fstat(fd,&st)||st.st_size||flock(fd,LOCK_EX|LOCK_NB)||fstatat(root,leaf,&named,AT_SYMLINK_NOFOLLOW)||!CCFStable(&st,&named)){if(fd>=0)close(fd);return -1;}return fd;
}
@implementation CanopyProviderCache {NSURL *_root;}
- (instancetype)initWithCacheRootURL:(NSURL *)root {if((self=[super init]))_root=[root copy];return self;}
- (int)openFamily:(CCFFamily)family title:(NSString *)title missing:(BOOL *)missing {
    *missing=NO;if(!PCTitle(title)||(family!=CCFRomFS&&![title isEqual:@"0100152000022000"])||!_root.isFileURL)return -1;
    int global=open(_root.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW_ANY|O_CLOEXEC);
    if(global<0){*missing=errno==ENOENT;return -1;}if(!CCFPrivate(global,YES)){close(global);return -1;}
    int owner=CCFChild(global,title.UTF8String);int saved=errno;close(global);
    if(owner<0){*missing=saved==ENOENT;return -1;}
    int root=CCFChild(owner,family==CCFRomFS?"romfs-derived":"mk8dx-identities-v1");saved=errno;close(owner);
    if(root<0)*missing=saved==ENOENT;return root;
}
- (BOOL)recoverRoot:(int)root family:(CCFFamily)family title:(NSString *)title {
    CCFValidation validate=^BOOL(int parent,int target,NSString *identifier){return PCFolder(parent,target,identifier,family,title);};
    return CCFRecover(root,family,title,validate,NULL);
}
- (BOOL)recoverPendingRemovalsForTitleID:(NSString *)title error:(NSError **)error {
    if(!PCTitle(title)){if(error)*error=PCError();return NO;}
    for(unsigned index=0;index<2;index++){
        CCFFamily family=index?CCFRomFS:CCFMKIdentity;if(!index&&![title isEqual:@"0100152000022000"])continue;
        BOOL missing=NO;int root=[self openFamily:family title:title missing:&missing];if(root<0){if(missing)continue;if(error)*error=PCError();return NO;}
        int lock=PCLock(root,index?".romfs.lock":".lock");BOOL ok=lock>=0&&[self recoverRoot:root family:family title:title];
        if(ok&&!index)ok=[self recoverRoot:root family:CCFMKRuntime title:title];
        if(lock>=0)close(lock);close(root);if(!ok){if(error)*error=PCError();return NO;}
    }return YES;
}
- (NSArray *)entriesForTitleID:(NSString *)title error:(NSError **)error {
    if(![self recoverPendingRemovalsForTitleID:title error:error])return nil;
    NSMutableArray *rows=[NSMutableArray new];
    for(unsigned index=0;index<2;index++){
        if(!index&&![title isEqual:@"0100152000022000"])continue;CCFFamily family=index?CCFRomFS:CCFMKIdentity;
        BOOL missing=NO;int root=[self openFamily:family title:title missing:&missing];if(root<0){if(missing)continue;if(error)*error=PCError();return nil;}
        int lock=PCLock(root,index?".romfs.lock":".lock");NSArray *names=lock>=0?PCNames(root):nil;BOOL ok=names!=nil;
        NSString *prefix=[NSString stringWithFormat:@"romfs-folders-v1-%@-",title];
        for(NSString *name in names){
            if([(index?@[@".romfs.lock",@".romfs-removal"]:@[@".lock",@".mk-removal",@".mk-runtime-removal"]) containsObject:name])continue;
            if(index&&[name hasPrefix:@"."]&&[name hasSuffix:@".lease"]){
                NSString *folder=[name substringWithRange:NSMakeRange(1,name.length-7)];
                if([folder hasPrefix:prefix]&&CCFHex([folder substringFromIndex:prefix.length],64)){
                    int held=openat(root,name.UTF8String,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC),item=CCFChild(root,folder.UTF8String);struct stat st={0};
                    if(!CCFPrivate(held,NO)||fstat(held,&st)||st.st_size||item<0)ok=NO;
                    if(held>=0)close(held);if(item>=0)close(item);continue;
                }
            }
            BOOL valid=index?[name hasPrefix:prefix]&&CCFHex([name substringFromIndex:prefix.length],64):CCFHex(name,64);
            if(!valid){ok=NO;continue;}
            int folder=CCFChild(root,name.UTF8String);NSString *leaseName=index?[NSString stringWithFormat:@".%@.lease",name]:@".lease";
            int leaseParent=index?root:folder,lease=openat(leaseParent,leaseName.UTF8String,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);struct stat st={0},named={0};
            BOOL safe=folder>=0&&PCFolder(root,folder,name,family,title)&&CCFPrivate(lease,NO)&&!fstat(lease,&st)&&!st.st_size&&
                !fstatat(leaseParent,leaseName.UTF8String,&named,AT_SYMLINK_NOFOLLOW)&&CCFStable(&st,&named);
            uint64_t bytes=0,count=0;BOOL active=NO;
            if(safe){if(flock(lease,LOCK_EX|LOCK_NB)){if(errno==EWOULDBLOCK||errno==EAGAIN)active=YES;else safe=NO;}}
            if(safe&&active){/* Mutable active caches have no stable usage scan. */}
            else if(safe)safe=CCFWalkExcept(folder,&bytes,&count,NO,index?nil:@".lease");
            if(rows.count==128)ok=NO;
            else [rows addObject:@{@"kind":index?@"romfsDerived":@"mkShader",@"titleID":title,@"identifier":name,@"cacheIdentity":index?[name substringFromIndex:prefix.length]:name,
                @"usageState":safe?@"available":@"unavailable",@"active":active?@YES:@NO,@"verification":@"notChecked",
                @"logicalBytes":safe&&!active?@(bytes):NSNull.null,@"filesAndDirectories":safe&&!active?@(count):NSNull.null}];
            if(!safe)ok=NO;if(lease>=0)close(lease);if(folder>=0)close(folder);
        }
        if(lock>=0)close(lock);close(root);if(!ok){if(error)*error=PCError();}
        if(!names)return nil;
    }return [rows copy];
}
- (BOOL)mutate:(CCFFamily)family identifier:(NSString *)identifier title:(NSString *)title error:(NSError **)error {
    BOOL missing=NO;int root=[self openFamily:family title:title missing:&missing];int lock=root<0?-1:PCLock(root,family==CCFRomFS?".romfs.lock":".lock");
    BOOL ok=NO;if(lock>=0){
        CCFValidation validate=^BOOL(int parent,int target,NSString *identity){return PCFolder(parent,target,identity,family,title);};
        /* Reconcile both MK transactions under the actual provider lock. */
        ok=(family==CCFRomFS||[self recoverRoot:root family:(family==CCFMKIdentity?CCFMKRuntime:CCFMKIdentity) title:title])&&CCFRetire(root,family,title,identifier,validate);
    }
    if(lock>=0)close(lock);if(root>=0)close(root);if(!ok&&error)*error=PCError();return ok;
}
- (BOOL)clearRuntimeForTitleID:(NSString *)title identity:(NSString *)identity error:(NSError **)error {return [self mutate:CCFMKRuntime identifier:identity title:title error:error];}
- (BOOL)removeKind:(CanopyProviderCacheKind)kind identifier:(NSString *)identifier titleID:(NSString *)title error:(NSError **)error {
    if(kind!=CanopyProviderCacheMKShader&&kind!=CanopyProviderCacheRomFS){if(error)*error=PCError();return NO;}
    return [self mutate:kind==CanopyProviderCacheMKShader?CCFMKIdentity:CCFRomFS identifier:identifier title:title error:error];
}
@end
