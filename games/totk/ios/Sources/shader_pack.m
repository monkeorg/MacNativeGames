#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#import "shader_pack.h"
#import <CoreFoundation/CoreFoundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <time.h>
#include <unistd.h>

#define SP_PART (UINT64_C(1)<<30)
#define SP_TOTAL (UINT64_C(16)<<30)
#define SP_FILE (UINT64_C(64)<<20)
#define SP_JSON (64u<<20)
#define SP_MEMBERS 262144u
#define SP_CHUNK 65536u
/* CommonCrypto is the platform digest provider; only its legacy SHA entry
 * points need the SDK deprecation suppression, not any filesystem checks. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static void SPInit(CC_SHA256_CTX *h){CC_SHA256_Init(h);}
static void SPUpdate(CC_SHA256_CTX *h,const void *p,size_t n){CC_SHA256_Update(h,p,(CC_LONG)n);}
static NSData *SPFinal(CC_SHA256_CTX *h){unsigned char bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(bytes,h);return [NSData dataWithBytes:bytes length:sizeof(bytes)];}
#pragma clang diagnostic pop
static NSString *SPHex(NSData *data){const unsigned char *p=data.bytes;char text[65];if(data.length!=32)return nil;for(unsigned i=0;i<32;i++)snprintf(text+2*i,3,"%02x",p[i]);return [NSString stringWithUTF8String:text];}
static NSString *SPDigest(NSData *data){CC_SHA256_CTX h;SPInit(&h);SPUpdate(&h,data.bytes,data.length);return SPHex(SPFinal(&h));}
static BOOL SPFail(NSError **error){if(error)*error=[NSError errorWithDomain:@"TOTKShaderPack" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The signed shader-pack metadata, complete parts or private snapshot could not be verified. Existing shader seeds and saves were preserved. Finish setup and reopen the app."}];return NO;}
static BOOL SPHexString(id value,NSUInteger n){return [value isKindOfClass:NSString.class]&&[value length]==n&&[value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;}
static BOOL SPNumber(id value,uint64_t minimum,uint64_t maximum){if(![value isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID())return NO;if(CFNumberIsFloatType((__bridge CFNumberRef)value))return NO;double n=[value doubleValue];return isfinite(n)&&n>=minimum&&n<=maximum&&floor(n)==n;}
static BOOL SPName(id value){if(![value isKindOfClass:NSString.class]||![value length]||[value length]>127||[value hasPrefix:@"."])return NO;const char *p=[value UTF8String];if(!p||strlen(p)!=[value length])return NO;for(;*p;p++)if(!((*p>='a'&&*p<='z')||(*p>='A'&&*p<='Z')||(*p>='0'&&*p<='9')||*p=='_'||*p=='-'||*p=='.'))return NO;return YES;}
static BOOL SPChain(id value){if(![value isKindOfClass:NSString.class]||![value length]||[value length]>128)return NO;const unsigned char *p=(const unsigned char *)[value UTF8String];if(!p||strlen((const char *)p)!=[value length])return NO;for(;*p;p++)if(*p<32||*p>126)return NO;return YES;}
static BOOL SPStable(const struct stat *a,const struct stat *b){return a->st_dev==b->st_dev&&a->st_ino==b->st_ino&&a->st_mode==b->st_mode&&a->st_nlink==b->st_nlink&&a->st_size==b->st_size&&a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec&&a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec&&a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;}
static BOOL SPRegular(int fd,uint64_t size,BOOL privateFile){struct stat st;return fd>=0&&!fstat(fd,&st)&&S_ISREG(st.st_mode)&&st.st_nlink==1&&st.st_size>=0&&(uint64_t)st.st_size==size&&(!privateFile||(st.st_uid==geteuid()&&!(st.st_mode&077)));}
static NSString *SPPhysical(NSURL *url){NSString *path=url.path;for(NSString *alias in @[@"/var",@"/tmp"])if([path hasPrefix:[alias stringByAppendingString:@"/"]])return [@"/private" stringByAppendingString:path];return path;}
static int SPOpenDirectory(NSURL *url){return open(SPPhysical(url).fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW_ANY|O_CLOEXEC);}
static int SPChild(int parent,const char *name,BOOL create){if(create&&mkdirat(parent,name,0700)&&errno!=EEXIST)return -1;int fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);struct stat st;if(fd>=0&&(fstat(fd,&st)||st.st_uid!=geteuid()||(st.st_mode&077))){close(fd);fd=-1;errno=EINVAL;}return fd;}
static int SPSupport(void){NSString *path=NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject;if(!path)return -1;NSURL *url=[NSURL fileURLWithPath:path isDirectory:YES];int support=SPOpenDirectory(url);if(support<0&&errno==ENOENT){int parent=SPOpenDirectory(url.URLByDeletingLastPathComponent);struct stat st;if(parent<0)return -1;BOOL ok=!fstat(parent,&st)&&st.st_uid==geteuid()&&!(st.st_mode&022)&&!mkdirat(parent,url.lastPathComponent.fileSystemRepresentation,0700)&&!fsync(parent);close(parent);if(!ok)return -1;support=SPOpenDirectory(url);}if(support<0)return -1;struct stat st;if(fstat(support,&st)||st.st_uid!=geteuid()||(st.st_mode&022)){close(support);return -1;}int root=SPChild(support,"TOTKShaderSeeds",YES);if(root>=0&&fsync(support)){close(root);root=-1;}close(support);return root;}
static BOOL SPEOF(int fd){unsigned char byte;ssize_t n;do{n=read(fd,&byte,1);}while(n<0&&errno==EINTR);return n==0;}
static NSData *SPRead(int directory,const char *name,NSUInteger limit,BOOL privateFile){int fd=openat(directory,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);if(fd<0)return nil;struct stat before={0},after={0};BOOL ok=!fstat(fd,&before)&&before.st_size>=0&&(uint64_t)before.st_size<=limit&&SPRegular(fd,(uint64_t)before.st_size,privateFile);NSMutableData *data=ok?[NSMutableData dataWithLength:(NSUInteger)before.st_size]:nil;size_t used=0;while(ok&&used<data.length){ssize_t n=read(fd,(unsigned char *)data.mutableBytes+used,data.length-used);if(n<0&&errno==EINTR)continue;if(n<=0){ok=NO;break;}used+=(size_t)n;}if(ok)ok=SPEOF(fd)&&!fstat(fd,&after)&&SPStable(&before,&after);close(fd);return ok?[data copy]:nil;}
static BOOL SPWrite(int fd,const void *p,size_t length){const unsigned char *bytes=p;while(length){ssize_t n=write(fd,bytes,length);if(n<0&&errno==EINTR)continue;if(n<=0)return NO;bytes+=n;length-=(size_t)n;}return YES;}
static BOOL SPStore(int parent,const char *name,NSData *data){int fd=openat(parent,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return NO;BOOL ok=SPWrite(fd,data.bytes,data.length)&&!fchmod(fd,0400)&&!fsync(fd);if(close(fd))ok=NO;return ok;}
static NSDictionary *SPMetadata(NSData *raw,NSString *chain){if(!raw.length||raw.length>SP_JSON)return nil;id parsed=[NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL];if(![parsed isKindOfClass:NSDictionary.class])return nil;NSDictionary *d=parsed;
    NSSet *keys=[NSSet setWithArray:@[@"schema",@"format",@"titleID",@"titleVersion",@"sourceRomFSSHA256",@"chain",@"manifestSHA256",@"streamSHA256",@"streamSize",@"partSize",@"parts",@"members"]];
    if(![[NSSet setWithArray:d.allKeys] isEqual:keys]||!SPNumber(d[@"schema"],1,1)||![d[@"format"] isEqual:@"TOTKPACK1"]||!SPHexString(d[@"titleID"],16)||[d[@"titleID"] isEqual:@"0000000000000000"]||!SPNumber(d[@"titleVersion"],0,UINT32_MAX)||!SPHexString(d[@"sourceRomFSSHA256"],64)||!SPChain(d[@"chain"])||![d[@"chain"] isEqual:chain]||!SPHexString(d[@"manifestSHA256"],64)||!SPHexString(d[@"streamSHA256"],64)||!SPNumber(d[@"streamSize"],11,SP_TOTAL)||!SPNumber(d[@"partSize"],SP_PART,SP_PART))return nil;
    NSArray *parts=d[@"parts"],*members=d[@"members"];uint64_t size=[d[@"streamSize"] unsignedLongLongValue];
    if(![parts isKindOfClass:NSArray.class]||parts.count!=(size+SP_PART-1)/SP_PART||parts.count>16||![members isKindOfClass:NSArray.class]||members.count<2||members.count>SP_MEMBERS)return nil;
    for(NSUInteger i=0;i<parts.count;i++){id row=parts[i];uint64_t expected=i+1<parts.count?SP_PART:size-(uint64_t)i*SP_PART;if(![row isKindOfClass:NSDictionary.class]||[row count]!=3||!SPNumber(row[@"index"],i,i)||!SPNumber(row[@"size"],expected,expected)||!SPHexString(row[@"sha256"],64))return nil;}
    uint64_t total=11;NSMutableSet *folded=[NSMutableSet new];NSString *previous=nil;BOOL manifest=NO,map=NO;
    for(id row in members){if(![row isKindOfClass:NSDictionary.class]||[row count]!=3||!SPName(row[@"name"])||!SPNumber(row[@"size"],0,SP_FILE)||!SPHexString(row[@"sha256"],64))return nil;NSString *name=row[@"name"];if((previous&&strcmp(previous.UTF8String,name.UTF8String)>=0)||[folded containsObject:name.lowercaseString])return nil;[folded addObject:name.lowercaseString];previous=name;uint64_t amount=[row[@"size"] unsignedLongLongValue]+10+name.length;if(amount>SP_TOTAL-total)return nil;total+=amount;if([name isEqual:@"seed-manifest.json"]){if(![row[@"sha256"] isEqual:d[@"manifestSHA256"]])return nil;manifest=YES;}if([name isEqual:@"shader_map.tsv"])map=YES;}
    return total==size&&manifest&&map?d:nil;
}
static BOOL SPExact(int fd,NSSet *names){int copy=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *d=copy<0?NULL:fdopendir(copy);if(!d){if(copy>=0)close(copy);return NO;}NSUInteger count=0;BOOL ok=YES;struct dirent *e;errno=0;while((e=readdir(d))){if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;NSString *name=[NSString stringWithUTF8String:e->d_name];if(!name||++count>names.count||![names containsObject:name]){ok=NO;break;}errno=0;}if(!e&&errno)ok=NO;closedir(d);return ok&&count==names.count;}
struct SPStream {int directory,fd;NSUInteger index;uint64_t left,used;struct stat before;CC_SHA256_CTX part,full;};
static BOOL SPPartEnd(struct SPStream *s,NSArray *parts){if(s->fd<0)return YES;struct stat after;BOOL ok=!s->left&&SPEOF(s->fd)&&!fstat(s->fd,&after)&&SPStable(&s->before,&after)&&[SPHex(SPFinal(&s->part)) isEqual:parts[s->index][@"sha256"]];close(s->fd);s->fd=-1;if(ok)s->index++;return ok;}
static BOOL SPTake(struct SPStream *s,NSArray *parts,void *out,size_t n){unsigned char *p=out;while(n){if(!s->left){if(!SPPartEnd(s,parts)||s->index>=parts.count)return NO;char name[4];snprintf(name,sizeof(name),"%03u",(unsigned)s->index);s->fd=openat(s->directory,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);s->left=[parts[s->index][@"size"] unsignedLongLongValue];if(s->fd<0||fstat(s->fd,&s->before)||!SPRegular(s->fd,s->left,NO)||s->before.st_uid!=geteuid())return NO;SPInit(&s->part);}
    size_t wanted=n;if((uint64_t)wanted>s->left)wanted=(size_t)s->left;ssize_t got=read(s->fd,p,wanted);if(got<0&&errno==EINTR)continue;if(got<=0||(size_t)got>wanted)return NO;SPUpdate(&s->part,p,(size_t)got);SPUpdate(&s->full,p,(size_t)got);p+=got;n-=(size_t)got;s->left-=(uint64_t)got;s->used+=(uint64_t)got;}return YES;}
static BOOL SPExtract(int partsFD,NSDictionary *metadata,int output,void (^progress)(uint64_t,uint64_t)) {
    NSArray *parts=metadata[@"parts"];NSMutableSet *names=[NSMutableSet new];for(NSUInteger i=0;i<parts.count;i++)[names addObject:[NSString stringWithFormat:@"%03u",(unsigned)i]];if(!SPExact(partsFD,names))return NO;
    struct stat directoryBefore,directoryAfter;if(fstat(partsFD,&directoryBefore))return NO;
    struct SPStream stream={.directory=partsFD,.fd=-1};SPInit(&stream.full);unsigned char magic[9]={0},lengthBytes[2]={0},sizeBytes[8]={0};unsigned char *buffer=malloc(SP_CHUNK);if(!buffer)return NO;
    BOOL ok=SPTake(&stream,parts,magic,9)&&!memcmp(magic,"TOTKPACK1",9);uint64_t last=0,lastTick=0,total=[metadata[@"streamSize"] unsignedLongLongValue];
    for(NSDictionary *member in metadata[@"members"]){if(!ok)break;ok=SPTake(&stream,parts,lengthBytes,2);unsigned length=(unsigned)lengthBytes[0]|(unsigned)lengthBytes[1]<<8;char name[128]={0};if(!ok||length!=[member[@"name"] length]||length>127){ok=NO;break;}ok=SPTake(&stream,parts,name,length)&&!memcmp(name,[member[@"name"] UTF8String],length)&&SPTake(&stream,parts,sizeBytes,8);uint64_t size=0;for(unsigned i=0;i<8;i++)size|=(uint64_t)sizeBytes[i]<<(8*i);if(!ok||size!=[member[@"size"] unsignedLongLongValue]){ok=NO;break;}
        int fd=output>=0?openat(output,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600):-1;CC_SHA256_CTX hash;SPInit(&hash);if(output>=0&&fd<0)ok=NO;
        for(uint64_t done=0;ok&&done<size;){size_t n=size-done>SP_CHUNK?SP_CHUNK:(size_t)(size-done);ok=SPTake(&stream,parts,buffer,n);if(ok){SPUpdate(&hash,buffer,n);if(fd>=0)ok=SPWrite(fd,buffer,n);done+=n;if(progress&&stream.used-last>=(UINT64_C(1)<<20)){struct timespec now={0};BOOL timed=!clock_gettime(CLOCK_MONOTONIC,&now);uint64_t tick=(uint64_t)now.tv_sec*UINT64_C(1000000000)+(uint64_t)now.tv_nsec;if(!lastTick||(timed&&tick>=lastTick&&tick-lastTick>=UINT64_C(50000000))){last=stream.used;lastTick=timed?tick:1;progress(stream.used,total);}}}}
        if(ok)ok=[SPHex(SPFinal(&hash)) isEqual:member[@"sha256"]];if(fd>=0){if(ok)ok=!fchmod(fd,0400)&&!fsync(fd);if(close(fd))ok=NO;}
    }
    if(ok)ok=SPTake(&stream,parts,lengthBytes,2)&&!lengthBytes[0]&&!lengthBytes[1]&&stream.used==total&&SPPartEnd(&stream,parts)&&stream.index==parts.count&&[SPHex(SPFinal(&stream.full)) isEqual:metadata[@"streamSHA256"]]&&!fstat(partsFD,&directoryAfter)&&SPStable(&directoryBefore,&directoryAfter);
    if(stream.fd>=0)close(stream.fd);memset(buffer,0,SP_CHUNK);free(buffer);if(ok&&progress)progress(total,total);return ok;
}
static BOOL SPVerify(int directory,NSDictionary *metadata,NSData *raw){NSMutableSet *names=[NSMutableSet setWithObjects:@".lease",@".metadata",nil];for(NSDictionary *row in metadata[@"members"])[names addObject:row[@"name"]];if(!SPExact(directory,names)||![SPRead(directory,".metadata",SP_JSON,YES) isEqual:raw])return NO;
    unsigned char *buffer=malloc(SP_CHUNK);if(!buffer)return NO;BOOL ok=YES;struct stat beforeDir,afterDir;if(fstat(directory,&beforeDir))ok=NO;
    for(NSDictionary *row in metadata[@"members"]){if(!ok)break;int fd=openat(directory,[row[@"name"] UTF8String],O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);struct stat before={0},after={0};uint64_t size=[row[@"size"] unsignedLongLongValue];ok=SPRegular(fd,size,YES)&&!fstat(fd,&before);CC_SHA256_CTX hash;SPInit(&hash);uint64_t used=0;while(ok&&used<size){size_t n=size-used>SP_CHUNK?SP_CHUNK:(size_t)(size-used);ssize_t got=read(fd,buffer,n);if(got<0&&errno==EINTR)continue;if(got<=0){ok=NO;break;}SPUpdate(&hash,buffer,(size_t)got);used+=(uint64_t)got;}if(ok)ok=SPEOF(fd)&&!fstat(fd,&after)&&SPStable(&before,&after)&&[SPHex(SPFinal(&hash)) isEqual:row[@"sha256"]];if(fd>=0)close(fd);}
    if(ok)ok=!fstat(directory,&afterDir)&&SPStable(&beforeDir,&afterDir);memset(buffer,0,SP_CHUNK);free(buffer);return ok;
}
static void SPDiscardStage(int root,NSString *stage){int fd=SPChild(root,stage.UTF8String,NO);if(fd<0)return;int copy=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *dir=copy<0?NULL:fdopendir(copy);BOOL ok=dir!=NULL;NSUInteger count=0;struct dirent *entry;while(dir&&(entry=readdir(dir))){if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;struct stat st;if(++count>SP_MEMBERS+2||fstatat(fd,entry->d_name,&st,AT_SYMLINK_NOFOLLOW)||!S_ISREG(st.st_mode)||st.st_nlink!=1||st.st_uid!=geteuid()||unlinkat(fd,entry->d_name,0)){ok=NO;break;}}if(dir)closedir(dir);else if(copy>=0)close(copy);close(fd);if(ok){(void)unlinkat(root,stage.UTF8String,AT_REMOVEDIR);(void)fsync(root);}}
@interface TOTKShaderSeedLease ()
@property(nonatomic,readwrite,copy) NSURL *seedURL;
@property(nonatomic,readwrite,copy) NSString *titleID;
@property(nonatomic,readwrite,copy) NSString *sourceRomFSSHA256;
@property(nonatomic,readwrite,copy) NSString *chain;
@property(nonatomic,readwrite,copy) NSString *streamSHA256;
@property(nonatomic,readwrite,copy) NSString *manifestSHA256;
@property(nonatomic,readwrite,copy) NSString *metadataSHA256;
@property(nonatomic,readwrite) uint32_t titleVersion;
@property(nonatomic,readwrite) int directoryFD;
- (instancetype)initDirectory:(int)directory lease:(int)lease metadata:(NSDictionary *)metadata raw:(NSData *)raw url:(NSURL *)url;
@end
@implementation TOTKShaderSeedLease {int _lease;}
- (instancetype)initDirectory:(int)directory lease:(int)lease metadata:(NSDictionary *)m raw:(NSData *)raw url:(NSURL *)url {if((self=[super init])){_directoryFD=directory;_lease=lease;_seedURL=[url copy];_titleID=[m[@"titleID"] copy];_titleVersion=[m[@"titleVersion"] unsignedIntValue];_sourceRomFSSHA256=[m[@"sourceRomFSSHA256"] copy];_chain=[m[@"chain"] copy];_streamSHA256=[m[@"streamSHA256"] copy];_manifestSHA256=[m[@"manifestSHA256"] copy];_metadataSHA256=SPDigest(raw);}return self;}
- (void)dealloc{if(_lease>=0)close(_lease);if(_directoryFD>=0)close(_directoryFD);}
@end
unsigned TOTKShaderPackReaderABI(void){return TOTK_SEED_PACK_READER_ABI;}
@implementation TOTKShaderPack
+ (TOTKShaderSeedLease *)prepareWithExpectedChain:(NSString *)chain progress:(void (^)(uint64_t,uint64_t))progress error:(NSError **)error {
    if(!SPChain(chain)){SPFail(error);return nil;}
    NSURL *game=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"GameData" isDirectory:YES];int bundle=SPOpenDirectory(game);NSData *raw=bundle>=0?SPRead(bundle,"shader-seed-pack.json",SP_JSON,NO):nil;if(bundle>=0)close(bundle);id pin=NSBundle.mainBundle.infoDictionary[@"TOTKShaderSeedPackMetadataSHA256"];NSDictionary *metadata=raw&&SPHexString(pin,64)&&[SPDigest(raw) isEqual:pin]?SPMetadata(raw,chain):nil;if(!metadata){SPFail(error);return nil;}
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSURL *partsURL=documents?[[NSURL fileURLWithPath:documents isDirectory:YES] URLByAppendingPathComponent:[NSString stringWithFormat:@"GameData/shader-packs/%@/parts",metadata[@"streamSHA256"]] isDirectory:YES]:nil;
    int parts=-1,root=-1,lock=-1,directory=-1,lease=-1;NSString *stage=nil;TOTKShaderSeedLease *result=nil;
    root=SPSupport();if(root<0)goto finish;
    lock=openat(root,".lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC,0600);if(!SPRegular(lock,0,YES)||flock(lock,LOCK_EX|LOCK_NB))goto finish;
    directory=SPChild(root,[metadata[@"streamSHA256"] UTF8String],NO);
    if(directory<0&&errno!=ENOENT)goto finish;
    // A fully rehashed private snapshot is sufficient after the transport
    // pieces have been removed. The pinned bundle metadata remains mandatory.
    if(directory>=0){if(!SPVerify(directory,metadata,raw))goto finish;}
    else {parts=partsURL?SPOpenDirectory(partsURL):-1;if(parts<0)goto finish;stage=[@".stage-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];if(mkdirat(root,stage.UTF8String,0700)){stage=nil;goto finish;}directory=SPChild(root,stage.UTF8String,NO);struct statvfs space;uint64_t need=[metadata[@"streamSize"] unsignedLongLongValue]+raw.length;if(directory<0||fstatvfs(directory,&space)||!space.f_frsize||need/space.f_frsize+(need%space.f_frsize!=0)>space.f_bavail||!SPExtract(parts,metadata,directory,progress)||!SPStore(directory,".metadata",raw)||!SPStore(directory,".lease",[NSData data])||fsync(directory)||!SPVerify(directory,metadata,raw))goto finish;
        if(renameatx_np(root,stage.UTF8String,root,[metadata[@"streamSHA256"] UTF8String],RENAME_EXCL))goto finish;stage=nil;if(fsync(root))goto finish;}
    {struct stat held={0},named={0};if(fstat(directory,&held)||fstatat(root,[metadata[@"streamSHA256"] UTF8String],&named,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(named.st_mode)||held.st_dev!=named.st_dev||held.st_ino!=named.st_ino)goto finish;}
    lease=openat(directory,".lease",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);if(!SPRegular(lease,0,YES)||flock(lease,LOCK_SH|LOCK_NB))goto finish;
    {NSString *support=NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject;NSURL *url=[[NSURL fileURLWithPath:support isDirectory:YES] URLByAppendingPathComponent:[NSString stringWithFormat:@"TOTKShaderSeeds/%@",metadata[@"streamSHA256"]] isDirectory:YES];
        result=[[TOTKShaderSeedLease alloc] initDirectory:directory lease:lease metadata:metadata raw:raw url:[NSURL fileURLWithPath:SPPhysical(url) isDirectory:YES]];if(result){directory=-1;lease=-1;}}
finish:
    if(lease>=0)close(lease);if(directory>=0)close(directory);if(stage&&root>=0)SPDiscardStage(root,stage);if(lock>=0)close(lock);if(root>=0)close(root);if(parts>=0)close(parts);if(!result)SPFail(error);return result;
}
@end
