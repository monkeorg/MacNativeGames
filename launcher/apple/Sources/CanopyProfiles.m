#import "CanopyProfiles.h"
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <dirent.h>
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
static NSData *PPReadObserved(int directory,const char *name,BOOL *missing,struct stat *identity) {
    *missing=NO;int fd=openat(directory,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(fd<0){*missing=errno==ENOENT;return nil;}
    struct stat before,after;BOOL ok=!fstat(fd,&before)&&PPSafe(&before);
    NSMutableData *data=[NSMutableData new];unsigned char bytes[4096];
    while(ok&&data.length<(NSUInteger)before.st_size){ssize_t n=read(fd,bytes,MIN(sizeof(bytes),(NSUInteger)before.st_size-data.length));
        if(n<0&&errno==EINTR)continue;if(n<=0){ok=NO;break;}[data appendBytes:bytes length:(NSUInteger)n];}
    unsigned char extra;if(ok&&(read(fd,&extra,1)!=0||fstat(fd,&after)||!PPStable(&before,&after)))ok=NO;
    close(fd);if(ok&&identity)*identity=before;return ok?data:nil;
}
static NSData *PPRead(int directory,const char *name,BOOL *missing) {return PPReadObserved(directory,name,missing,NULL);}
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
static BOOL PPEnvelope(id doc) {
    id version=[doc isKindOfClass:NSDictionary.class]?doc[@"schemaVersion"]:nil;
    return [doc isKindOfClass:NSDictionary.class]&&[[NSSet setWithArray:[doc allKeys]] isEqual:[NSSet setWithArray:@[@"schemaVersion",@"titles"]]]&&
        [version isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)version)!=CFBooleanGetTypeID()&&
        [version doubleValue]==1&&[doc[@"titles"] isKindOfClass:NSDictionary.class]&&[doc[@"titles"] count]<=500;
}
static NSDictionary *PPDocument(NSData *data) {
    id doc=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if(!PPEnvelope(doc))return nil;
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
/* Recovery accepts the exact native JSON representation as a deliberately
 * narrow subset. Duplicate keys/noncanonical ambiguous encodings cannot be
 * silently normalized into a different schema or selected identity. */
static BOOL PPNativeJSON(NSData *data,id document) {
    NSData *encoded=[NSJSONSerialization dataWithJSONObject:document options:NSJSONWritingSortedKeys error:NULL];
    return encoded&&[encoded isEqual:data];
}
static NSData *PPLabelCandidate(NSData *current,NSData *previous,NSString *title,NSUInteger *repaired) {
    id doc=[NSJSONSerialization JSONObjectWithData:current options:0 error:NULL];
    NSDictionary *old=PPDocument(previous);
    if(!PPEnvelope(doc)||!old)return nil;
    for(id key in doc[@"titles"])if(!PPTitle(key)||(![key isEqual:title]&&!PPRow(doc[@"titles"][key])))return nil;
    id row=doc[@"titles"][title];NSDictionary *prior=old[@"titles"][title];
    if(![row isKindOfClass:NSDictionary.class]||!prior||
        ![[NSSet setWithArray:[row allKeys]] isEqual:[NSSet setWithArray:@[@"selectedID",@"profiles"]]]||
        !PPID(row[@"selectedID"])||![row[@"profiles"] isKindOfClass:NSArray.class]||
        [row[@"profiles"] count]<1||[row[@"profiles"] count]>16)return nil;
    NSMutableDictionary *oldRecords=[NSMutableDictionary new];
    for(NSDictionary *item in prior[@"profiles"])oldRecords[item[@"identifier"]]=item;
    NSMutableSet *ids=[NSMutableSet new];NSMutableArray *records=[NSMutableArray new];NSUInteger count=0;
    for(id item in row[@"profiles"]) {
        if(![item isKindOfClass:NSDictionary.class]||
            ![[NSSet setWithArray:[item allKeys]] isEqual:[NSSet setWithArray:@[@"identifier",@"displayName"]]]||
            !PPID(item[@"identifier"])||[ids containsObject:item[@"identifier"]]||
            ![item[@"displayName"] isKindOfClass:NSString.class])return nil;
        NSString *identifier=item[@"identifier"],*name=item[@"displayName"];
        [ids addObject:identifier];
        if(PPName(name))[records addObject:item];
        else {
            NSString *replacement=oldRecords[identifier][@"displayName"];
            if(!PPName(replacement))return nil;
            [records addObject:@{@"identifier":identifier,@"displayName":replacement}];count++;
        }
    }
    if(!count||![ids containsObject:@"default"]||![ids containsObject:row[@"selectedID"]]||
        !PPNativeJSON(current,doc)||!PPNativeJSON(previous,old))return nil;
    NSMutableDictionary *titles=[doc[@"titles"] mutableCopy];
    titles[title]=@{@"selectedID":row[@"selectedID"],@"profiles":[records copy]};
    NSData *candidate=[NSJSONSerialization dataWithJSONObject:@{@"schemaVersion":@1,@"titles":titles}
        options:NSJSONWritingSortedKeys error:NULL];
    if(!candidate||candidate.length>PPLimit||!PPDocument(candidate))return nil;
    if(repaired)*repaired=count;
    return candidate;
}
static BOOL PPQuarantine(int fd,NSData *original) {
    if(!original.length||original.length>PPLimit)return NO;
    NSString *prefix=@".save-profiles-quarantine-";
    int scan=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    DIR *stream=scan<0?NULL:fdopendir(scan);if(!stream){if(scan>=0)close(scan);return NO;}
    unsigned entries=0,archives=0;BOOL ok=YES;struct dirent *entry;errno=0;
    while((entry=readdir(stream))) {
        if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,"..")){errno=0;continue;}
        if(++entries>128){ok=NO;break;}
        if(!strncmp(entry->d_name,prefix.UTF8String,strlen(prefix.UTF8String))) {
            NSString *name=[NSString stringWithUTF8String:entry->d_name];struct stat st;
            if(name.length!=prefix.length+32+5||![name hasSuffix:@".json"]||
                !PPHex([name substringWithRange:NSMakeRange(prefix.length,32)],32)||
                fstatat(fd,entry->d_name,&st,AT_SYMLINK_NOFOLLOW)||!PPSafe(&st)){ok=NO;break;}
            archives++;
        }
        errno=0;
    }
    if(!entry&&errno)ok=NO;
    closedir(stream);if(!ok||archives>=8)return NO;
    int out=-1;NSString *archiveName=nil;
    for(unsigned attempt=0;attempt<16;attempt++) {
        NSString *identifier=[[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
        NSString *name=[NSString stringWithFormat:@"%@%@.json",prefix,identifier];
        out=openat(fd,name.UTF8String,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
        if(out>=0){archiveName=name;break;}
        if(errno!=EEXIST)return NO;
    }
    if(out<0)return NO;
    const unsigned char *bytes=original.bytes;size_t offset=0;
    while(offset<original.length) {
        ssize_t n=write(out,bytes+offset,original.length-offset);
        if(n<0&&errno==EINTR)continue;
        if(n<=0){ok=NO;break;}offset+=(size_t)n;
    }
    if(ok)ok=!fsync(out);
    struct stat archived={0},named={0};
    if(ok)ok=!fstat(out,&archived)&&PPSafe(&archived)&&(uint64_t)archived.st_size==original.length&&
        !fstatat(fd,archiveName.UTF8String,&named,AT_SYMLINK_NOFOLLOW)&&PPStable(&archived,&named);
    if(close(out))ok=NO;
    /* Failed/partial archives remain bounded evidence; never erase a prior
     * quarantine or publish current when its preservation was not confirmed. */
    return ok&&!fsync(fd);
}

@interface CanopyProfileLabelRepair ()
@property(nonatomic, readwrite, copy) NSString *titleID;
@property(nonatomic, readwrite, copy) NSString *selectedID;
@property(nonatomic, readwrite, copy) NSDictionary<NSString *,id> *candidateSnapshot;
@property(nonatomic, readwrite) NSUInteger repairedLabelCount;
@property(nonatomic, strong) NSObject *ownerIdentity;
@property(nonatomic, copy) NSData *currentBytes;
@property(nonatomic, copy) NSData *previousBytes;
@property(nonatomic, copy) NSData *candidateBytes;
@property(nonatomic) struct stat directoryIdentity;
@property(nonatomic) struct stat currentIdentity;
@property(nonatomic) struct stat previousIdentity;
- (instancetype)initWithOwner:(NSObject *)owner;
@end
@implementation CanopyProfileLabelRepair
- (instancetype)initWithOwner:(NSObject *)owner {if((self=[super init]))_ownerIdentity=owner;return self;}
@end

static BOOL PPRepairMatches(int fd,CanopyProfileLabelRepair *repair) {
    struct stat directory={0},current={0},previous={0},observed=repair.directoryIdentity;
    if(fstat(fd,&directory)||!S_ISDIR(directory.st_mode)||directory.st_dev!=observed.st_dev||directory.st_ino!=observed.st_ino||
        directory.st_uid!=observed.st_uid||directory.st_mode!=observed.st_mode)return NO;
    BOOL missing=NO;NSData *now=PPReadObserved(fd,"save-profiles.json",&missing,&current);
    NSData *old=PPReadObserved(fd,"save-profiles.previous.json",&missing,&previous);
    struct stat expectedCurrent=repair.currentIdentity,expectedPrevious=repair.previousIdentity;
    return now&&old&&[now isEqual:repair.currentBytes]&&[old isEqual:repair.previousBytes]&&
        PPStable(&current,&expectedCurrent)&&PPStable(&previous,&expectedPrevious);
}

@implementation CanopyProfiles {NSURL *_directory;NSObject *_repairIdentity;}
- (instancetype)initWithDirectoryURL:(NSURL *)directory {if((self=[super init])){_directory=[directory copy];_repairIdentity=[NSObject new];}return self;}
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
- (CanopyProfileLabelRepair *)prepareLabelRepairForTitleID:(NSString *)title error:(NSError **)error {
    if(!PPTitle(title)){PPFail(error,NO);return nil;}
    int fd=PPOpen(_directory,NO),lock=fd<0?-1:PPLock(fd);
    if(lock<0){if(fd>=0)close(fd);PPFail(error,NO);return nil;}
    struct stat directory={0},currentIdentity={0},previousIdentity={0};BOOL missing=NO;
    NSData *current=PPReadObserved(fd,"save-profiles.json",&missing,&currentIdentity);
    NSData *previous=PPReadObserved(fd,"save-profiles.previous.json",&missing,&previousIdentity);
    NSUInteger count=0;NSData *candidate=current&&previous?PPLabelCandidate(current,previous,title,&count):nil;
    CanopyProfileLabelRepair *repair=nil;
    if(candidate&&!fstat(fd,&directory)&&S_ISDIR(directory.st_mode)&&directory.st_uid==geteuid()&&!(directory.st_mode&077)) {
        NSDictionary *doc=PPDocument(candidate);
        repair=[[CanopyProfileLabelRepair alloc] initWithOwner:_repairIdentity];
        repair.titleID=title;repair.selectedID=doc[@"titles"][title][@"selectedID"];
        repair.candidateSnapshot=doc[@"titles"][title];repair.repairedLabelCount=count;
        repair.currentBytes=current;repair.previousBytes=previous;repair.candidateBytes=candidate;
        repair.directoryIdentity=directory;repair.currentIdentity=currentIdentity;repair.previousIdentity=previousIdentity;
    }
    close(lock);close(fd);
    if(!repair)PPFail(error,NO);
    return repair;
}
- (BOOL)applyLabelRepair:(CanopyProfileLabelRepair *)repair expectedSelection:(NSString *)expected error:(NSError **)error {
    if(![repair isMemberOfClass:CanopyProfileLabelRepair.class]||repair.ownerIdentity!=_repairIdentity||
        !PPID(expected)||![expected isEqual:repair.selectedID])return PPFail(error,NO);
    int fd=PPOpen(_directory,NO),lock=fd<0?-1:PPLock(fd);
    if(lock<0){if(fd>=0)close(fd);return PPFail(error,NO);}
    NSUInteger count=0;BOOL published=NO;
    NSData *candidate=PPLabelCandidate(repair.currentBytes,repair.previousBytes,repair.titleID,&count);
    BOOL ok=candidate&&[candidate isEqual:repair.candidateBytes]&&count==repair.repairedLabelCount&&PPRepairMatches(fd,repair);
    if(ok)ok=PPQuarantine(fd,repair.currentBytes);
    // Preserve both-file CAS even across slow archive fsync. This never backs
    // corrupt current bytes over the valid previous snapshot.
    if(ok)ok=PPRepairMatches(fd,repair)&&PPWrite(fd,"save-profiles.json",candidate,&published);
    close(lock);close(fd);return ok?YES:PPFail(error,published);
}
@end
