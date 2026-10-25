#import "CanopyProfiles.h"
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static const size_t PPLimit=65536;
static BOOL PPFail(NSError **error,BOOL uncertain) {
    if(error) {
        *error=[NSError errorWithDomain:@"CanopyProfiles" code:1 userInfo:@{
        NSLocalizedDescriptionKey:uncertain?@"Profile metadata publication was not fully confirmed. The previous snapshot and live profile are preserved. Reload before Play.":@"Profile metadata is busy, invalid, unsupported or unavailable. Existing profile data was preserved.",
        @"publicationUncertain":uncertain?@YES:@NO}];
    }
    return NO;
}
static BOOL PPHex(id value,NSUInteger n) {
    return [value isKindOfClass:NSString.class]&&[value length]==n&&
        [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
static BOOL PPTitle(id title){return PPHex(title,16)&&![title isEqual:@"0000000000000000"];}
static BOOL PPID(id value){return [value isEqual:@"default"]||PPHex(value,32);}
static BOOL PPName(id value){return [value isKindOfClass:NSString.class]&&[value length]>0&&[value length]<=64&&
    [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound;}
static NSDictionary *PPDefault(void){return @{@"selectedID":@"default",@"profiles":@[@{@"identifier":@"default",@"displayName":@"Default"}]};}
static BOOL PPSafe(const struct stat *s){return S_ISREG(s->st_mode)&&s->st_uid==geteuid()&&!(s->st_mode&077)&&s->st_nlink==1&&s->st_size>=0&&(uint64_t)s->st_size<=PPLimit;}
static BOOL PPStable(const struct stat *a,const struct stat *b){return a->st_dev==b->st_dev&&a->st_ino==b->st_ino&&a->st_mode==b->st_mode&&a->st_uid==b->st_uid&&a->st_nlink==b->st_nlink&&a->st_size==b->st_size&&
    a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec&&a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec&&a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;}
/* Open the known app-private path once. Traversing with readable descriptors
 * for every system ancestor is denied by the iOS sandbox. O_NOFOLLOW_ANY still
 * refuses links anywhere in the path; only Darwin's fixed /var alias changes. */
static int PPOpen(NSURL *url,BOOL create) {
    if(!url.isFileURL){errno=EINVAL;return -1;}
    NSString *path=url.path;
    if([path hasPrefix:@"/var/"])path=[@"/private" stringByAppendingString:path];
    if(![path hasPrefix:@"/"]||path.length>4096||[path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound){errno=EINVAL;return -1;}
    NSArray *parts=[path componentsSeparatedByString:@"/"];if(parts.count>64){errno=EINVAL;return -1;}
    for(NSUInteger i=1;i<parts.count;i++)if(![parts[i] length]||[parts[i] isEqual:@"."]||[parts[i] isEqual:@".."]) {errno=EINVAL;return -1;}
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW_ANY|O_CLOEXEC);
    if(fd<0&&errno==ENOENT&&create) {
        NSString *parentPath=path.stringByDeletingLastPathComponent,*leaf=path.lastPathComponent;
        int parent=open(parentPath.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW_ANY|O_CLOEXEC);struct stat owner;
        if(parent<0)return -1;
        if(fstat(parent,&owner)||owner.st_uid!=geteuid()||(owner.st_mode&077)){close(parent);errno=EPERM;return -1;}
        if(mkdirat(parent,leaf.fileSystemRepresentation,0700)&&errno!=EEXIST){close(parent);return -1;}
        fd=openat(parent,leaf.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(fd>=0&&fsync(parent)){close(fd);fd=-1;}
        int saved=errno;close(parent);errno=saved;
    }
    if(fd<0)return -1;
    struct stat st;if(fstat(fd,&st)||st.st_uid!=geteuid()||(st.st_mode&077)){close(fd);errno=EPERM;return -1;}return fd;
}
static NSData *PPRead(int directory,const char *name,BOOL *missing) {
    *missing=NO;int fd=openat(directory,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(fd<0){*missing=errno==ENOENT;return nil;}
    struct stat before,after;BOOL ok=!fstat(fd,&before)&&PPSafe(&before);
    NSMutableData *data=[NSMutableData new];unsigned char bytes[4096];
    while(ok&&data.length<(NSUInteger)before.st_size){ssize_t n=read(fd,bytes,MIN(sizeof(bytes),(NSUInteger)before.st_size-data.length));
        if(n<0&&errno==EINTR)continue;if(n<=0){ok=NO;break;}[data appendBytes:bytes length:(NSUInteger)n];}
    unsigned char extra;if(ok&&(read(fd,&extra,1)!=0||fstat(fd,&after)||!PPStable(&before,&after)))ok=NO;
    close(fd);return ok?data:nil;
}
static BOOL PPRow(id row) {
    if(![row isKindOfClass:NSDictionary.class]||![[NSSet setWithArray:[row allKeys]] isEqual:[NSSet setWithArray:@[@"selectedID",@"profiles"]]]||
        !PPID(row[@"selectedID"])||![row[@"profiles"] isKindOfClass:NSArray.class]||[row[@"profiles"] count]<1||[row[@"profiles"] count]>16)return NO;
    NSMutableSet *ids=[NSMutableSet new];
    for(id item in row[@"profiles"]) {
        if(![item isKindOfClass:NSDictionary.class]||![[NSSet setWithArray:[item allKeys]] isEqual:[NSSet setWithArray:@[@"identifier",@"displayName"]]]||
            !PPID(item[@"identifier"])||!PPName(item[@"displayName"])||[ids containsObject:item[@"identifier"]])return NO;
        [ids addObject:item[@"identifier"]];
    }
    return [ids containsObject:@"default"]&&[ids containsObject:row[@"selectedID"]];
}
static NSDictionary *PPDocument(NSData *data) {
    id doc=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    id version=[doc isKindOfClass:NSDictionary.class]?doc[@"schemaVersion"]:nil;
    if(![doc isKindOfClass:NSDictionary.class]||![[NSSet setWithArray:[doc allKeys]] isEqual:[NSSet setWithArray:@[@"schemaVersion",@"titles"]]]||
        ![version isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)version)==CFBooleanGetTypeID()||
        [version doubleValue]!=1||![doc[@"titles"] isKindOfClass:NSDictionary.class]||[doc[@"titles"] count]>500)return nil;
    for(id title in doc[@"titles"])if(!PPTitle(title)||!PPRow(doc[@"titles"][title]))return nil;
    return doc;
}
static NSDictionary *PPLoad(int fd,NSData **original) {
    BOOL missing=NO;NSData *data=PPRead(fd,"save-profiles.json",&missing);
    if(missing){struct stat old;if(!fstatat(fd,"save-profiles.previous.json",&old,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT)return nil;
        return @{@"schemaVersion":@1,@"titles":@{}};}
    if(!data)return nil;NSDictionary *doc=PPDocument(data);if(doc&&original)*original=data;return doc;
}
static int PPLock(int fd) {
    int lock=openat(fd,".save-profiles.lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC,0600);struct stat st;
    if(lock<0)return -1;
    if(fstat(lock,&st)||!PPSafe(&st)||st.st_size||flock(lock,LOCK_EX|LOCK_NB)){close(lock);return -1;}return lock;
}
/* Bounded bytes, not bounded filesystem latency. Caller owns the operation
 * lock. Never traverses Profiles/ or any save/account directory. */
static BOOL PPWrite(int fd,const char *name,NSData *data,BOOL *published) {
    *published=NO;if(data.length>PPLimit)return NO;
    struct stat target;if(!fstatat(fd,name,&target,AT_SYMLINK_NOFOLLOW)){if(!PPSafe(&target))return NO;}else if(errno!=ENOENT)return NO;
    NSString *temp=[@".save-profiles-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    int out=openat(fd,temp.UTF8String,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(out<0)return NO;
    const unsigned char *bytes=data.bytes;size_t offset=0;BOOL ok=YES;
    while(offset<data.length){ssize_t n=write(out,bytes+offset,data.length-offset);if(n<0&&errno==EINTR)continue;if(n<=0){ok=NO;break;}offset+=(size_t)n;}
    if(ok)ok=!fsync(out);if(close(out))ok=NO;
    if(ok){ok=!renameat(fd,temp.UTF8String,fd,name);*published=ok;if(ok)ok=!fsync(fd);}
    if(!*published)(void)unlinkat(fd,temp.UTF8String,0);return ok;
}
@implementation CanopyProfiles {NSURL *_directory;}
- (instancetype)initWithDirectoryURL:(NSURL *)directory {if((self=[super init]))_directory=[directory copy];return self;}
- (NSDictionary *)snapshotForTitleID:(NSString *)title error:(NSError **)error {
    if(!PPTitle(title)){PPFail(error,NO);return nil;}int fd=PPOpen(_directory,NO);
    if(fd<0&&errno==ENOENT)return PPDefault();
    if(fd<0){PPFail(error,NO);return nil;}
    NSDictionary *doc=PPLoad(fd,NULL);close(fd);if(!doc){PPFail(error,NO);return nil;}
    return doc[@"titles"][title]?:PPDefault();
}
- (BOOL)writeDocument:(NSDictionary *)doc original:(NSData *)original directory:(int)fd error:(NSError **)error {
    NSData *data=[NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingSortedKeys error:NULL];
    if(!data||data.length>PPLimit)return PPFail(error,NO);
    BOOL published=NO;
    if(original&&!PPWrite(fd,"save-profiles.previous.json",original,&published))return PPFail(error,NO);
    if(!PPWrite(fd,"save-profiles.json",data,&published))return PPFail(error,published);
    return YES;
}
- (NSString *)createProfileWithName:(NSString *)name titleID:(NSString *)title error:(NSError **)error {
    if(!PPTitle(title)||!PPName(name)){PPFail(error,NO);return nil;}int fd=PPOpen(_directory,YES),lock=fd<0?-1:PPLock(fd);
    if(lock<0){if(fd>=0)close(fd);PPFail(error,NO);return nil;}
    NSData *original=nil;NSDictionary *doc=PPLoad(fd,&original);NSDictionary *row=doc[@"titles"][title]?:PPDefault();NSString *identifier=nil;
    if(doc&&[row[@"profiles"] count]<16) {
        NSMutableSet *ids=[NSMutableSet new];for(NSDictionary *item in row[@"profiles"])[ids addObject:item[@"identifier"]];
        for(unsigned attempt=0;attempt<16;attempt++){NSString *candidate=[[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];if(![ids containsObject:candidate]){identifier=candidate;break;}}
        if(!identifier){close(lock);close(fd);PPFail(error,NO);return nil;}
        NSMutableDictionary *titles=[doc[@"titles"] mutableCopy],*next=[row mutableCopy];
        next[@"profiles"]=[row[@"profiles"] arrayByAddingObject:@{@"identifier":identifier,@"displayName":[name copy]}];titles[title]=next;
        if(titles.count>500){identifier=nil;PPFail(error,NO);}
        else if(![self writeDocument:@{@"schemaVersion":@1,@"titles":titles} original:original directory:fd error:error])identifier=nil;
    }else PPFail(error,NO);
    close(lock);close(fd);return identifier;
}
- (BOOL)selectProfileID:(NSString *)identifier titleID:(NSString *)title expectedSelection:(NSString *)expected error:(NSError **)error {
    if(!PPTitle(title)||!PPID(identifier)||!PPID(expected))return PPFail(error,NO);
    if([identifier isEqual:expected]) {
        NSDictionary *snapshot=[self snapshotForTitleID:title error:error];
        return snapshot&&[snapshot[@"selectedID"] isEqual:expected] ? YES : PPFail(error,NO);
    }
    int fd=PPOpen(_directory,YES),lock=fd<0?-1:PPLock(fd);if(lock<0){if(fd>=0)close(fd);return PPFail(error,NO);}
    NSData *original=nil;NSDictionary *doc=PPLoad(fd,&original);NSDictionary *row=doc[@"titles"][title]?:PPDefault();BOOL found=NO;
    for(NSDictionary *profile in row[@"profiles"])if([profile[@"identifier"] isEqual:identifier])found=YES;
    BOOL ok=doc&&found&&[row[@"selectedID"] isEqual:expected];
    if(ok&&![identifier isEqual:expected]) {
        NSMutableDictionary *titles=[doc[@"titles"] mutableCopy],*next=[row mutableCopy];next[@"selectedID"]=identifier;titles[title]=next;
        ok=titles.count<=500&&[self writeDocument:@{@"schemaVersion":@1,@"titles":titles} original:original directory:fd error:error];
    }else if(!ok)PPFail(error,NO);
    close(lock);close(fd);return ok;
}
@end
