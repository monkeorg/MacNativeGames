#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#import "canopy_mk8dx.h"
#include "mk8dx_pins.h"
#include "mng_crypto.h"
#include "mng_romfs.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#define MK_FILE (UINT64_C(64)<<20)
#define MK_TOTAL (UINT64_C(16)<<30)
struct mng_apple_prepared {void *object;};
static BOOL safe_dir(int fd){struct stat st;return fd>=0&&!fstat(fd,&st)&&S_ISDIR(st.st_mode)&&st.st_uid==geteuid()&&!(st.st_mode&077);}
static BOOL stable(const struct stat *a,const struct stat *b){return a->st_dev==b->st_dev&&a->st_ino==b->st_ino&&a->st_mode==b->st_mode&&a->st_uid==b->st_uid&&a->st_nlink==b->st_nlink&&a->st_size==b->st_size&&a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec&&a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec&&a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;}
/* Storage recovery owns this fixed namespace. Producers never interpret or
 * delete its records. Under the same parent EX lock, only durable absence or
 * an exact empty private directory permits any cache reuse/publication. */
static BOOL MKJournalClear(int parent,const char *name){
    struct stat named,opened,after;
    if(fstatat(parent,name,&named,AT_SYMLINK_NOFOLLOW)){
        if(errno!=ENOENT||fsync(parent))return NO;
        return fstatat(parent,name,&named,AT_SYMLINK_NOFOLLOW)<0&&errno==ENOENT;
    }
    if(!S_ISDIR(named.st_mode)||named.st_uid!=geteuid()||(named.st_mode&077))return NO;
    int fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(fd<0)return NO;
    BOOL ok=!fstat(fd,&opened)&&stable(&named,&opened);
    int scan=ok?openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):-1;
    DIR *stream=scan<0?NULL:fdopendir(scan);
    if(!stream){if(scan>=0)close(scan);ok=NO;}
    if(stream){
        struct dirent *entry;unsigned seen=0;errno=0;
        while((entry=readdir(stream))){
            if(++seen>2){ok=NO;break;}
            if(strcmp(entry->d_name,".")&&strcmp(entry->d_name,"..")){ok=NO;break;}
            errno=0;
        }
        if(!entry&&errno)ok=NO;
        if(closedir(stream))ok=NO;
    }
    if(ok)ok=!fstat(fd,&after)&&stable(&opened,&after)&&!fsync(fd)&&!fsync(parent)&&
        !fstat(fd,&after)&&stable(&opened,&after)&&
        !fstatat(parent,name,&named,AT_SYMLINK_NOFOLLOW)&&stable(&after,&named);
    if(close(fd))ok=NO;
    return ok;
}
static NSString *hex(const unsigned char d[32]){char value[65];for(unsigned i=0;i<32;i++)snprintf(value+2*i,3,"%02x",d[i]);return [NSString stringWithUTF8String:value];}
static NSString *digest(NSData *data){struct mng_sha256 *h=NULL;unsigned char d[32];BOOL ok=data&&!mng_sha256_init(&h)&&!mng_sha256_update(h,data.bytes,data.length)&&!mng_sha256_final(h,d);mng_sha256_free(h);return ok?hex(d):nil;}
static BOOL size_number(id n){return [n isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)n)!=CFBooleanGetTypeID()&&strchr("CSILQcsilq",[n objCType][0])&&[n compare:@0]!=NSOrderedAscending;}
static BOOL hash_name(id value){return [value isKindOfClass:NSString.class]&&[value length]==64&&[value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;}
static int root(const char *path,BOOL private){if(!path||path[0]!='/')return -1;NSString *s=[NSString stringWithUTF8String:path];for(NSString *alias in @[@"/var",@"/tmp"])if([s hasPrefix:[alias stringByAppendingString:@"/"]]){s=[@"/private" stringByAppendingString:s];break;}int fd=open(s.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW_ANY|O_CLOEXEC);if(fd>=0&&private&&!safe_dir(fd)){close(fd);return -1;}return fd;}
static int child(int parent,const char *name,BOOL create){
    BOOL made=NO;
    if(create){if(!mkdirat(parent,name,0700))made=YES;else if(errno!=EEXIST)return -1;}
    int fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(!safe_dir(fd)||(made&&(fsync(fd)||fsync(parent)))){if(fd>=0)close(fd);return -1;}
    return fd;
}
static int relative(int parent,NSString *name,BOOL create,BOOL directory){NSArray *parts=[name componentsSeparatedByString:@"/"];if(!parts.count||parts.count>8||name.length>512)return -1;int fd=fcntl(parent,F_DUPFD_CLOEXEC,0);for(NSUInteger i=0;i<parts.count&&fd>=0;i++){NSString *part=parts[i];if(!part.length||[part isEqual:@"."]||[part isEqual:@".."]){close(fd);return -1;}BOOL dir=directory||i+1<parts.count;int next;if(dir){if(create)next=child(fd,part.UTF8String,YES);else next=openat(fd,part.UTF8String,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);}else next=openat(fd,part.UTF8String,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);close(fd);fd=next;}return fd;}
static NSData *read_data(int parent,NSString *name,size_t limit){int fd=relative(parent,name,NO,NO);struct stat a,b;BOOL ok=fd>=0&&!fstat(fd,&a)&&S_ISREG(a.st_mode)&&a.st_nlink==1&&a.st_size>=0&&(uint64_t)a.st_size<=limit;NSMutableData *data=ok?[NSMutableData dataWithLength:(NSUInteger)a.st_size]:nil;size_t used=0;while(ok&&used<data.length){ssize_t n=read(fd,(unsigned char *)data.mutableBytes+used,data.length-used);if(n<0&&errno==EINTR)continue;if(n<=0){ok=NO;break;}used+=(size_t)n;}unsigned char extra;if(ok)ok=read(fd,&extra,1)==0&&!fstat(fd,&b)&&stable(&a,&b);if(fd>=0)close(fd);return ok?[data copy]:nil;}
static BOOL write_new_mode(int parent,const char *name,NSData *data,mode_t mode){
    int fd=openat(parent,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return NO;
    BOOL ok=YES;size_t at=0;
    while(at<data.length){ssize_t n=write(fd,(const unsigned char *)data.bytes+at,data.length-at);if(n<0&&errno==EINTR)continue;if(n<=0){ok=NO;break;}at+=(size_t)n;}
    if(ok)ok=!fchmod(fd,mode)&&!fsync(fd);
    if(close(fd))ok=NO;
    if(ok)ok=!fsync(parent);
    return ok;
}
static BOOL write_new(int parent,const char *name,NSData *data){return write_new_mode(parent,name,data,0600);}

static BOOL copy_hash(int input,NSString *name,int output,NSString *expected,uint64_t size,const struct mng_apple_prepare *request){
    int fd=relative(input,name,NO,NO),out=-1,outputParent=-1;struct stat a,b;struct mng_sha256 *h=NULL;unsigned char buffer[65536],d[32];BOOL ok=fd>=0&&!fstat(fd,&a)&&S_ISREG(a.st_mode)&&a.st_nlink==1&&a.st_size>=0&&(uint64_t)a.st_size==size&&size<=MK_FILE&&!mng_sha256_init(&h);
    if(ok&&output>=0){NSString *parent=name.stringByDeletingLastPathComponent;outputParent=[parent isEqual:@"."]?fcntl(output,F_DUPFD_CLOEXEC,0):relative(output,parent,YES,YES);if(outputParent>=0)out=openat(outputParent,name.lastPathComponent.UTF8String,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);ok=out>=0;}
    uint64_t total=0;while(ok){if(request->cancelled&&request->cancelled(request->cancel_context)){ok=NO;break;}ssize_t n=read(fd,buffer,sizeof(buffer));if(n<0&&errno==EINTR)continue;if(n<0){ok=NO;break;}if(!n)break;if((uint64_t)n>size-total||mng_sha256_update(h,buffer,(size_t)n)){ok=NO;break;}total+=(uint64_t)n;if(out>=0){ssize_t at=0;while(at<n){ssize_t wrote=write(out,buffer+at,(size_t)(n-at));if(wrote<0&&errno==EINTR)continue;if(wrote<=0){ok=NO;break;}at+=wrote;}}}
    if(ok)ok=total==size&&!fstat(fd,&b)&&stable(&a,&b)&&!mng_sha256_final(h,d)&&[hex(d) isEqual:expected];if(out>=0){if(ok)ok=!fchmod(out,0400)&&!fsync(out);if(close(out))ok=NO;}if(outputParent>=0){if(ok)ok=!fsync(outputParent);if(close(outputParent))ok=NO;}if(fd>=0)close(fd);mng_sha256_free(h);mng_secure_clear(buffer,sizeof(buffer));return ok;}
static BOOL shape(int directory,NSString *prefix,NSSet *files,NSSet *dirs,unsigned depth,NSUInteger *count,BOOL private){if(depth>8)return NO;int copy=openat(directory,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *stream=copy<0?NULL:fdopendir(copy);if(!stream){if(copy>=0)close(copy);return NO;}BOOL ok=YES;struct dirent *e;errno=0;while((e=readdir(stream))){if(!strcmp(e->d_name,".")||!strcmp(e->d_name,"..")){errno=0;continue;}NSString *name=[NSString stringWithUTF8String:e->d_name];NSString *path=prefix.length?[prefix stringByAppendingFormat:@"/%@",name]:name;struct stat st;if(!name||++*count>100008||fstatat(directory,e->d_name,&st,AT_SYMLINK_NOFOLLOW)){ok=NO;break;}if(S_ISDIR(st.st_mode)){if(![dirs containsObject:path]){ok=NO;break;}int fd=private?child(directory,e->d_name,NO):openat(directory,e->d_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);ok=fd>=0&&shape(fd,path,files,dirs,depth+1,count,private);if(fd>=0)close(fd);}else ok=S_ISREG(st.st_mode)&&st.st_nlink==1&&(!private||(st.st_uid==geteuid()&&!(st.st_mode&0222)&&!(st.st_mode&077)))&&[files containsObject:path];if(!ok)break;errno=0;}if(!e&&errno)ok=NO;closedir(stream);return ok;}
static BOOL remove_owned(int directory,unsigned depth,NSUInteger *count){if(depth>64||!safe_dir(directory))return NO;int copy=openat(directory,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *stream=copy<0?NULL:fdopendir(copy);if(!stream){if(copy>=0)close(copy);return NO;}BOOL ok=YES;struct dirent *e;errno=0;while((e=readdir(stream))){if(!strcmp(e->d_name,".")||!strcmp(e->d_name,"..")){errno=0;continue;}struct stat st;if(++*count>100000||fstatat(directory,e->d_name,&st,AT_SYMLINK_NOFOLLOW)||st.st_uid!=geteuid()){ok=NO;break;}if(S_ISDIR(st.st_mode)){int fd=child(directory,e->d_name,NO);ok=fd>=0&&remove_owned(fd,depth+1,count);if(fd>=0)close(fd);if(ok)ok=!unlinkat(directory,e->d_name,AT_REMOVEDIR);}else ok=S_ISREG(st.st_mode)&&st.st_nlink==1&&!unlinkat(directory,e->d_name,0);if(!ok)break;errno=0;}if(!e&&errno)ok=NO;closedir(stream);return ok;}
@implementation MKPrepared
- (instancetype)init{if((self=[super init])){_namespaceFD=-1;_leaseFD=-1;}return self;}
- (void)dealloc{if(_leaseFD>=0)close(_leaseFD);if(_namespaceFD>=0)close(_namespaceFD);}
@end
MKPrepared *MKPreparedObject(struct mng_apple_prepared *p){return p?(__bridge MKPrepared *)p->object:nil;}
void MKReleasePrepared(struct mng_apple_prepared *p){
    if(!p)return;
    // Releasing before native entry drops genuine generation/cache users. The
    // shared immutable folder stays published for exact verified reuse.
    MKPrepared *object=CFBridgingRelease(p->object);(void)object;free(p);
}
static int cancelled(void *context){const struct mng_apple_prepare *r=context;return r->cancelled&&r->cancelled(r->cancel_context);}

static NSString *language_code(NSString *desired){
    NSString *value=desired.length?desired:(NSLocale.preferredLanguages.firstObject?:@"en-US");
    NSDictionary *parts=[NSLocale componentsFromLocaleIdentifier:value];NSString *lang=[parts[NSLocaleLanguageCode] lowercaseString],*script=[parts[NSLocaleScriptCode] lowercaseString],*region=[parts[NSLocaleCountryCode] uppercaseString];
    if([lang isEqual:@"zh"]){if([script isEqual:@"hant"]||(!script.length&&[@[@"TW",@"HK",@"MO"] containsObject:region]))return @"zh-Hant";return @"zh-Hans";}
    if([lang isEqual:@"en"])return @"en-US";
    if([@[@"ja",@"de",@"es",@"fr",@"it",@"nl",@"ru",@"ko"] containsObject:lang])return lang;
    return @"en-US";
}
static BOOL uid_file(const struct stat *st){
    return S_ISREG(st->st_mode)&&st->st_uid==geteuid()&&!(st->st_mode&077)&&st->st_nlink==1;
}
static BOOL identity_uid(int directory,uint64_t uid[2]){
    /* Only this successful exclusive creation authorizes a new identity. An
     * existing empty/partial file may be a failed earlier write and is retained
     * for recovery rather than silently replacing the account. */
    BOOL created=NO;
    int fd=openat(directory,"account.uid",O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC,0600);
    if(fd>=0)created=YES;
    else if(errno==EEXIST)fd=openat(directory,"account.uid",O_RDWR|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(fd<0)return NO;
    struct stat before,after,named;
    BOOL ok=!fstat(fd,&before)&&uid_file(&before)&&!flock(fd,LOCK_EX|LOCK_NB)&&
        !fstat(fd,&before)&&uid_file(&before)&&
        !fstatat(directory,"account.uid",&named,AT_SYMLINK_NOFOLLOW)&&stable(&before,&named)&&
        before.st_size==(created?0:16);
    if(ok&&created){
        do{arc4random_buf(uid,16);}while(!uid[0]&&!uid[1]);
        size_t used=0;
        while(ok&&used<16){ssize_t n=pwrite(fd,(const unsigned char *)uid+used,16-used,(off_t)used);if(n<0&&errno==EINTR)continue;if(n<=0)ok=NO;else used+=(size_t)n;}
    }else if(ok){
        size_t used=0;
        while(ok&&used<16){ssize_t n=pread(fd,(unsigned char *)uid+used,16-used,(off_t)used);if(n<0&&errno==EINTR)continue;if(n<=0)ok=NO;else used+=(size_t)n;}
        ok=ok&&(uid[0]||uid[1]);
    }
    if(ok)ok=!fstat(fd,&after)&&uid_file(&after)&&after.st_size==16&&
        (created||stable(&before,&after));
    /* Every successful retry establishes file AND parent durability again. A
     * previous preflight may have written all bytes but failed either fsync. */
    if(ok)ok=!fsync(fd)&&!fsync(directory)&&
        !fstat(fd,&before)&&stable(&after,&before)&&
        !fstatat(directory,"account.uid",&named,AT_SYMLINK_NOFOLLOW)&&stable(&before,&named);
    if(close(fd))ok=NO;
    return ok;
}
static BOOL verify_native(int resources,const struct mng_apple_prepare *r){NSData *raw=read_data(resources,@"native/native-manifest.json",1u<<20);if(![digest(raw) isEqual:@MK_NATIVE_MANIFEST_SHA256])return NO;id m=[NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL];NSDictionary *files=[m isKindOfClass:NSDictionary.class]?m[@"files"]:nil;if(![files isKindOfClass:NSDictionary.class]||files.count!=15||![m[@"sourceRecipeSHA256"] isEqual:@MK_SOURCE_RECIPE_SHA256])return NO;int native=relative(resources,@"native",NO,YES);if(native<0)return NO;BOOL ok=YES;for(NSString *module in @[@"main",@"subsdk0",@"sdk"])for(NSString *ext in @[@"patched.bin",@"fixups.tsv",@"gates.tsv",@"cuts.tsv",@"obs.tsv"]){NSString *name=[module stringByAppendingFormat:@".%@",ext];id row=files[name];if(![row isKindOfClass:NSDictionary.class]||!hash_name(row[@"sha256"])||!size_number(row[@"size"])||[row count]!=2||!copy_hash(native,name,-1,row[@"sha256"],[row[@"size"] unsignedLongLongValue],r))ok=NO;}NSMutableSet *expected=[NSMutableSet setWithArray:files.allKeys];[expected addObject:@"native-manifest.json"];NSUInteger count=0;if(ok)ok=shape(native,@"",expected,[NSSet set],0,&count,NO);close(native);return ok;}
int MKPrepare(const struct mng_apple_prepare *r,struct mng_apple_prepared **out){
    if(!r||!out||r->abi!=MNG_APPLE_HOST_ABI||r->size!=sizeof(*r)||!r->metal_device)return MNG_APPLE_INVALID;
    int gen=root(r->generation,YES),assets=root(r->resources,NO),save=root(r->active_saves,YES),account=root(r->identity,YES),cache=root(r->cache,YES),exefs=-1,lock=-1,namespaces=-1,ns=-1,seed=-1;
    struct mng_apple_prepared *prepared=calloc(1,sizeof(*prepared));
    MKPrepared *object=[MKPrepared new];if(prepared)prepared->object=(__bridge_retained void *)object;BOOL ok=prepared&&gen>=0&&assets>=0&&save>=0&&account>=0&&cache>=0&&!cancelled((void *)r);
    const struct mng_apple_host *host=canopy_mk8dx_host_v1();
    if(ok)ok=verify_native(assets,r);if(ok){exefs=child(gen,"exefs",NO);ok=exefs>=0;}
    for(unsigned i=0;ok&&i<3;i++){NSString *name=[NSString stringWithUTF8String:host->modules[i].name];int fd=relative(exefs,name,NO,NO);struct stat st;unsigned char header[80]={0};ok=fd>=0&&!fstat(fd,&st)&&st.st_size>=80&&pread(fd,header,sizeof(header),0)==sizeof(header)&&!memcmp(header,"NSO0",4);if(fd>=0)close(fd);NSString *build=nil;if(ok){char value[33];for(unsigned j=0;j<16;j++)snprintf(value+2*j,3,"%02x",header[64+j]);build=[NSString stringWithUTF8String:value];ok=[build isEqual:[NSString stringWithUTF8String:host->modules[i].build_id]]&&copy_hash(exefs,name,-1,[NSString stringWithUTF8String:host->modules[i].original_sha256],(uint64_t)st.st_size,r);}}
    NSData *raw=ok?read_data(assets,@"shader-seed/seed-manifest.json",32u<<20):nil;id manifest=raw?[NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL]:nil;NSDictionary *files=[manifest isKindOfClass:NSDictionary.class]?manifest[@"files"]:nil;
    ok=ok&&[digest(raw) isEqual:@MK_SHADER_MANIFEST_SHA256]&&[files isKindOfClass:NSDictionary.class]&&files.count>0&&files.count<=100000&&[manifest[@"titleID"] isEqual:@"0100152000022000"]&&[manifest[@"chain"] isEqual:@MK_SHADER_CHAIN]&&[manifest[@"sourceRomFSSHA256"] isEqual:@MK_ROMFS_SHA256]&&[manifest[@"sourceRecipeSHA256"] isEqual:@MK_SOURCE_RECIPE_SHA256];
    id<MTLDevice> device=(__bridge id<MTLDevice>)r->metal_device;NSDictionary *identity=@{@"schema":@1,@"titleID":@"0100152000022000",@"revision":@1441792,@"romfs":@MK_ROMFS_SHA256,@"seed":@MK_SHADER_MANIFEST_SHA256,@"recipe":@MK_SOURCE_RECIPE_SHA256,@"chain":@MK_SHADER_CHAIN,@"deviceRegistry":[NSString stringWithFormat:@"%016llx",(unsigned long long)device.registryID],@"device":device.name?:@"",@"os":NSProcessInfo.processInfo.operatingSystemVersionString};NSData *receipt=[NSJSONSerialization dataWithJSONObject:identity options:NSJSONWritingSortedKeys error:NULL];NSString *key=digest(receipt);
    if(ok){namespaces=child(cache,"mk8dx-identities-v1",YES);ok=namespaces>=0;}
    if(ok){lock=openat(namespaces,".lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC,0600);struct stat st;ok=lock>=0&&!fstat(lock,&st)&&S_ISREG(st.st_mode)&&st.st_uid==geteuid()&&!(st.st_mode&077)&&st.st_nlink==1&&!st.st_size&&!flock(lock,LOCK_EX|LOCK_NB);}
    if(ok)ok=MKJournalClear(namespaces,".mk-removal")&&MKJournalClear(namespaces,".mk-runtime-removal");
    BOOL fresh=NO;NSString *stage=nil;
    if(ok){ns=child(namespaces,key.UTF8String,NO);if(ns<0&&errno==ENOENT){stage=[@".stage-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];fresh=!mkdirat(namespaces,stage.UTF8String,0700);if(!fresh)stage=nil;ns=fresh?child(namespaces,stage.UTF8String,NO):-1;}ok=ns>=0;}
    if(ok){if(fresh)ok=write_new(ns,"identity.json",receipt);else ok=[read_data(ns,@"identity.json",16384) isEqual:receipt];}
    if(ok){seed=child(ns,"seed",fresh);ok=seed>=0;}
    int source=ok?relative(assets,@"shader-seed",NO,YES):-1;
    NSRegularExpression *pattern=[NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"^(?:shader_map\\.tsv|pso_manifest\\.tsv|shader_pairs\\.tsv|shader_facts\\.tsv|bf_want\\.tsv|c1_full\\.tsv|cb_extent\\.tsv|b-%@/(?:inputs\\.tsv|[0-9a-f]{64}_b\\.(?:metallib|json)))$",[NSRegularExpression escapedPatternForString:@MK_SHADER_CHAIN]] options:0 error:NULL];NSMutableSet *expected=[NSMutableSet setWithObject:@"seed-manifest.json"],*dirs=[NSMutableSet set];uint64_t total=raw.length;
    for(id name in files){if(!ok)break;id row=files[name];NSTextCheckingResult *match=[name isKindOfClass:NSString.class]?[pattern firstMatchInString:name options:0 range:NSMakeRange(0,[name length])]:nil;ok=match&&NSEqualRanges(match.range,NSMakeRange(0,[name length]))&&[row isKindOfClass:NSDictionary.class]&&hash_name(row[@"sha256"])&&size_number(row[@"size"])&&[row count]==2;uint64_t size=ok?[row[@"size"] unsignedLongLongValue]:0;if(size>MK_FILE||size>MK_TOTAL-total)ok=NO;if(ok){total+=size;ok=copy_hash(fresh?source:seed,name,fresh?seed:-1,row[@"sha256"],size,r);[expected addObject:name];NSString *parent=[name stringByDeletingLastPathComponent];if(![parent isEqual:@"."])[dirs addObject:parent];}}
    ok=ok&&files[@"shader_map.tsv"]&&files[@"pso_manifest.tsv"];
    if(ok&&fresh)ok=write_new_mode(seed,"seed-manifest.json",raw,0400);
    if(ok){NSUInteger count=0;ok=[read_data(seed,@"seed-manifest.json",32u<<20) isEqual:raw]&&shape(seed,@"",expected,dirs,0,&count,YES);count=0;ok=ok&&shape(source,@"",expected,dirs,0,&count,NO);}
    if(ok&&fresh)ok=write_new(ns,".lease",[NSData data])&&!fsync(seed)&&!fsync(ns)&&!fsync(namespaces);
    if(ok){object.leaseFD=openat(ns,".lease",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);struct stat st;ok=object.leaseFD>=0&&!fstat(object.leaseFD,&st)&&S_ISREG(st.st_mode)&&st.st_uid==geteuid()&&!(st.st_mode&077)&&st.st_nlink==1&&!st.st_size&&!flock(object.leaseFD,LOCK_SH|LOCK_NB);}
    NSString *runtimeName=@"runtime";int runtime=ok?child(ns,runtimeName.UTF8String,YES):-1;if(ok)ok=runtime>=0;
    if(ok){int temp=child(runtime,"temp",YES);ok=temp>=0;if(temp>=0)close(temp);}
    if(ok&&fresh){if(renameatx_np(namespaces,stage.UTF8String,namespaces,key.UTF8String,RENAME_EXCL))ok=NO;else{stage=nil;ok=!fsync(namespaces);}}
    int image=-1;
    if(ok){
        int derived=child(cache,"romfs-derived",YES);
        image=openat(gen,"romfs.bin",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
        char physical[PATH_MAX];struct stat held,named;
        NSString *cachePath=[NSString stringWithUTF8String:r->cache];
        ok=derived>=0&&image>=0&&realpath(cachePath.fileSystemRepresentation,physical)!=NULL&&
            !fstat(cache,&held)&&!lstat(physical,&named)&&held.st_dev==named.st_dev&&held.st_ino==named.st_ino;
        if(ok){
            NSURL *derivedURL=[[NSURL fileURLWithFileSystemRepresentation:physical isDirectory:YES relativeToURL:nil]
                URLByAppendingPathComponent:@"romfs-derived" isDirectory:YES];
            NSString *generation=[[NSString stringWithUTF8String:r->generation] lastPathComponent];
            object.romfsLease=[CanopyRomFS materializeVerifiedImageFD:image titleID:host->title_id generationID:generation
                derivedRootURL:derivedURL cancelled:^BOOL{return cancelled((void *)r)!=0;} progress:nil error:NULL];
            ok=object.romfsLease!=nil;
        }
        if(derived>=0)close(derived);
    }
    uint64_t uid[2]={0};if(ok)ok=identity_uid(account,uid)&&!cancelled((void *)r);
    if(ok){char physical[PATH_MAX];NSString *base=[NSString stringWithUTF8String:r->cache];NSURL *url=[[NSURL fileURLWithPath:base isDirectory:YES] URLByAppendingPathComponent:[NSString stringWithFormat:@"mk8dx-identities-v1/%@",key] isDirectory:YES];struct stat held,named;ok=realpath(url.fileSystemRepresentation,physical)!=NULL&&!fstat(ns,&held)&&!lstat(physical,&named)&&held.st_dev==named.st_dev&&held.st_ino==named.st_ino&&S_ISDIR(named.st_mode);if(ok){NSString *path=[NSString stringWithUTF8String:physical];object.modules=[[NSString stringWithUTF8String:r->resources] stringByAppendingPathComponent:@"native"];object.romfs=object.romfsLease.folderURL.path;object.seed=[path stringByAppendingPathComponent:@"seed"];object.runtime=[path stringByAppendingPathComponent:@"runtime"];object.active=[NSString stringWithUTF8String:r->active_saves];object.identity=[NSString stringWithUTF8String:r->identity];object.language=language_code(r->language?[NSString stringWithUTF8String:r->language]:@"");object.uidLow=uid[0];object.uidHigh=uid[1];object.device=device;object.namespaceFD=fcntl(ns,F_DUPFD_CLOEXEC,0);ok=object.namespaceFD>=0;}}
    if(!ok&&prepared){if(object.namespaceFD<0&&ns>=0)object.namespaceFD=fcntl(ns,F_DUPFD_CLOEXEC,0);MKReleasePrepared(prepared);prepared=NULL;}
    if(image>=0)close(image);if(runtime>=0)close(runtime);if(source>=0)close(source);if(seed>=0)close(seed);if(stage&&ns>=0){NSUInteger count=0;if(remove_owned(ns,0,&count))(void)unlinkat(namespaces,stage.UTF8String,AT_REMOVEDIR);}if(ns>=0)close(ns);if(lock>=0)close(lock);if(namespaces>=0)close(namespaces);if(exefs>=0)close(exefs);if(cache>=0)close(cache);if(account>=0)close(account);if(save>=0)close(save);if(assets>=0)close(assets);if(gen>=0)close(gen);
    if(!ok)return cancelled((void *)r)?MNG_APPLE_CANCELLED:MNG_APPLE_IO;*out=prepared;return MNG_APPLE_OK;
}
