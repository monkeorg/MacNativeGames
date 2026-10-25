#import "CanopySaveStore.h"
#include "mng_crypto.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

/* Own transfer format only. Reuses the existing save_store.m transaction
 * principles: pre-session exclusion, verified private copies, backup before
 * replacement and same-volume directory exchange. No title-format guesses. */
static const uint64_t CSFileLimit=UINT64_C(64)<<20, CSTotalLimit=UINT64_C(512)<<20;
static const NSUInteger CSEntryLimit=10000, CSManifestLimit=4*1024*1024, CSBackupLimit=16;
#define CS_CHUNK 65536u
static BOOL CSFail(NSError **error, NSString *message, BOOL ambiguous) {
    if(error)*error=[NSError errorWithDomain:@"CanopySaveStore" code:1 userInfo:@{
        NSLocalizedDescriptionKey:message,@"publicationMayHaveCompleted":@(ambiguous)}];
    return NO;
}
static BOOL CSTitle(NSString *value) {
    return [value isKindOfClass:NSString.class] && value.length==16 &&
        ![value isEqual:@"0000000000000000"] &&
        [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
static BOOL CSProfile(NSString *value) {
    return [value isKindOfClass:NSString.class] && value.length>0 && value.length<=64 &&
        [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"] invertedSet]].location==NSNotFound;
}
static BOOL CSIdentifier(NSString *value) {
    return [value isKindOfClass:NSString.class] && value.length==36 &&
        [[NSUUID alloc] initWithUUIDString:value]!=nil && [value isEqual:value.lowercaseString];
}
static NSString *CSID(void) { return NSUUID.UUID.UUIDString.lowercaseString; }
static BOOL CSLeaf(const char *name) {
    size_t n=strlen(name);
    if(!n || n>128 || !strcmp(name,".") || !strcmp(name,".."))return NO;
    for(size_t i=0;i<n;i++)if(!((name[i]>='a'&&name[i]<='z') || (name[i]>='A'&&name[i]<='Z') ||
        (name[i]>='0'&&name[i]<='9') || name[i]=='_' || name[i]=='-' || name[i]=='.'))return NO;
    return YES;
}
static BOOL CSStable(const struct stat *a,const struct stat *b) {
    return a->st_dev==b->st_dev && a->st_ino==b->st_ino && a->st_size==b->st_size &&
        a->st_mode==b->st_mode && a->st_nlink==b->st_nlink &&
        a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
}
static int CSOpen(NSURL *url) {
    if(!url.isFileURL)return -1;
    NSString *path=url.path;
    for(NSString *alias in @[@"/tmp",@"/var"])if([path isEqual:alias] || [path hasPrefix:[alias stringByAppendingString:@"/"]]) {
        path=[@"/private" stringByAppendingString:path];break;
    }
    for(NSString *part in path.pathComponents)if([part isEqual:@"."] || [part isEqual:@".."])return -1;
    return open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW_ANY|O_CLOEXEC);
}
static int CSRoot(NSURL *url) {
    int root=CSOpen(url);
    if(root>=0||errno!=ENOENT)return root;
    NSString *name=url.lastPathComponent;
    if(!CSLeaf(name.UTF8String))return -1;
    int parent=CSOpen(url.URLByDeletingLastPathComponent);struct stat st;
    // Never ask Foundation to create intermediate paths before validating
    // ancestry: even a later O_NOFOLLOW_ANY refusal cannot undo outside writes.
    if(parent<0)return -1;
    if(fstat(parent,&st)||st.st_uid!=geteuid()||(st.st_mode&077)){close(parent);return -1;}
    if(mkdirat(parent,name.UTF8String,0700)&&errno!=EEXIST){close(parent);return -1;}
    root=openat(parent,name.UTF8String,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(root>=0&&fsync(parent)){close(root);root=-1;}
    close(parent);return root;
}
static int CSDir(int parent,const char *name,BOOL create) {
    if(create){if(!mkdirat(parent,name,0700)){if(fsync(parent))return -1;}else if(errno!=EEXIST)return -1;}
    int fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    struct stat st;
    if(fd>=0 && (fstat(fd,&st) || !S_ISDIR(st.st_mode) || st.st_uid!=geteuid() || (st.st_mode&077))) {close(fd);return -1;}
    return fd;
}
static BOOL CSWrite(int fd,const void *bytes,size_t length) {
    const unsigned char *cursor=bytes;
    while(length){ssize_t n=write(fd,cursor,length);if(n<0&&errno==EINTR)continue;if(n<=0)return NO;cursor+=n;length-=(size_t)n;}
    return YES;
}
static BOOL CSRemoveInner(int parent,const char *name,unsigned depth,NSUInteger *remaining) {
    if(depth>13)return NO;
    int fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0)return NO;
    int iteration=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    DIR *dir=iteration<0 ? NULL:fdopendir(iteration);
    if(!dir){if(iteration>=0)close(iteration);close(fd);return NO;}
    BOOL ok=YES;struct dirent *entry;errno=0;
    while((entry=readdir(dir))){
        const char *child=entry->d_name;
        if(!strcmp(child,".")||!strcmp(child,".."))continue;
        struct stat st;
        if(!*remaining || !CSLeaf(child) || fstatat(fd,child,&st,AT_SYMLINK_NOFOLLOW)){ok=NO;break;}
        --*remaining;
        if(S_ISDIR(st.st_mode))ok=CSRemoveInner(fd,child,depth+1,remaining);
        else ok=S_ISREG(st.st_mode)&&st.st_nlink==1&&!unlinkat(fd,child,0);
        if(!ok)break;
        errno=0;
    }
    if(!entry&&errno)ok=NO;
    closedir(dir);close(fd);
    return ok&&!unlinkat(parent,name,AT_REMOVEDIR);
}
static BOOL CSRemove(int parent,const char *name,unsigned depth) {
    NSUInteger remaining=CSEntryLimit+4;
    return CSRemoveInner(parent,name,depth,&remaining);
}
static BOOL CSCleanStages(int parent,NSString *prefix) {
    int iteration=openat(parent,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *dir=iteration<0?NULL:fdopendir(iteration);
    if(!dir){if(iteration>=0)close(iteration);return NO;}
    NSMutableArray *names=[NSMutableArray array];BOOL ok=YES;struct dirent *entry;NSUInteger count=0,seen=0;errno=0;
    while((entry=readdir(dir))){
        if(++seen>128){ok=NO;break;}
        NSString *name=[NSString stringWithUTF8String:entry->d_name];
        if([name hasPrefix:prefix]){
            if(++count>32||!CSIdentifier([name substringFromIndex:prefix.length])){ok=NO;break;}
            [names addObject:name];
        }
        errno=0;
    }
    if(!entry&&errno)ok=NO;closedir(dir);
    if(ok)for(NSString *name in names){
        if([prefix isEqual:@".journal-"]){
            struct stat st;
            if(fstatat(parent,name.UTF8String,&st,AT_SYMLINK_NOFOLLOW)||!S_ISREG(st.st_mode)||st.st_nlink!=1||unlinkat(parent,name.UTF8String,0)){ok=NO;break;}
        }else if(!CSRemove(parent,name.UTF8String,0)){ok=NO;break;}
    }
    return ok&&!fsync(parent);
}
static NSString *CSHex(const unsigned char bytes[32]) {
    char text[65];for(unsigned i=0;i<32;i++)snprintf(text+2*i,3,"%02x",bytes[i]);
    return [NSString stringWithUTF8String:text];
}
struct CSCopy { uint64_t total;NSUInteger entries;dev_t destinationDevice;ino_t destinationInode;unsigned char *buffer; };
static BOOL CSWalk(int source,int output,NSString *prefix,unsigned depth,struct CSCopy *budget,
                   NSMutableArray *files,NSMutableArray *directories) {
    if(depth>12)return NO;
    struct stat before,after;
    if(fstat(source,&before) || !S_ISDIR(before.st_mode) ||
       (before.st_dev==budget->destinationDevice && before.st_ino==budget->destinationInode))return NO;
    int iteration=openat(source,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    DIR *dir=iteration<0?NULL:fdopendir(iteration);
    if(!dir){if(iteration>=0)close(iteration);return NO;}
    NSMutableSet *names=[NSMutableSet set];BOOL ok=YES;struct dirent *entry;errno=0;
    while((entry=readdir(dir))){
        const char *name=entry->d_name;
        if(!strcmp(name,".")||!strcmp(name,".."))continue;
        if(++budget->entries>CSEntryLimit || !CSLeaf(name)){ok=NO;break;}
        NSString *leaf=[NSString stringWithUTF8String:name],*folded=leaf.lowercaseString;
        if([names containsObject:folded] || [folded isEqual:@"account.uid"]){ok=NO;break;}
        [names addObject:folded];
        NSString *path=prefix.length?[prefix stringByAppendingFormat:@"/%@",leaf]:leaf;
        if(path.length>1024){ok=NO;break;}
        struct stat st,opened;
        if(fstatat(source,name,&st,AT_SYMLINK_NOFOLLOW) || (!S_ISREG(st.st_mode)&&!S_ISDIR(st.st_mode)) ||
           (S_ISREG(st.st_mode)&&st.st_nlink!=1)){ok=NO;break;}
        int input=openat(source,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|(S_ISDIR(st.st_mode)?O_DIRECTORY:O_NONBLOCK));
        if(input<0 || fstat(input,&opened) || !CSStable(&st,&opened)){if(input>=0)close(input);ok=NO;break;}
        if(S_ISDIR(st.st_mode)){
            [directories addObject:path];int destination=-1;
            if(output>=0){if(mkdirat(output,name,0700)){close(input);ok=NO;break;}destination=CSDir(output,name,NO);}
            ok=(output<0||destination>=0)&&CSWalk(input,destination,path,depth+1,budget,files,directories);
            if(destination>=0){if(ok&&fsync(destination))ok=NO;close(destination);}
        }else{
            if(st.st_size<0 || (uint64_t)st.st_size>CSFileLimit || (uint64_t)st.st_size>CSTotalLimit-budget->total){close(input);ok=NO;break;}
            budget->total+=(uint64_t)st.st_size;
            int destination=output<0?-1:openat(output,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
            struct mng_sha256 *hash=NULL;unsigned char *bytes=budget->buffer,digest[32];uint64_t copied=0;
            ok=(output<0||destination>=0)&&!mng_sha256_init(&hash);
            while(ok){
                ssize_t n=read(input,bytes,CS_CHUNK);
                if(n<0&&errno==EINTR)continue;
                if(n<0){ok=NO;break;}if(!n)break;
                if((uint64_t)n>(uint64_t)st.st_size-copied){ok=NO;break;}
                copied+=(uint64_t)n;
                ok=!mng_sha256_update(hash,bytes,(size_t)n)&&(destination<0||CSWrite(destination,bytes,(size_t)n));
            }
            if(ok)ok=copied==(uint64_t)st.st_size&&!fstat(input,&opened)&&CSStable(&st,&opened)&&!mng_sha256_final(hash,digest);
            if(destination>=0){if(ok&&fsync(destination))ok=NO;close(destination);}
            if(ok)[files addObject:@{@"path":path,@"size":@(copied),@"sha256":CSHex(digest)}];
            mng_secure_clear(bytes,CS_CHUNK);mng_secure_clear(digest,sizeof(digest));mng_sha256_free(hash);
        }
        close(input);if(!ok)break;errno=0;
    }
    if(!entry&&errno)ok=NO;
    if(ok&&(fstat(source,&after)||!CSStable(&before,&after)))ok=NO;
    closedir(dir);return ok;
}
static NSDictionary *CSManifest(int source,int output,NSString *title,NSString *profile) {
    NSMutableArray *files=[NSMutableArray array],*directories=[NSMutableArray array];
    struct CSCopy budget={0};
    if(output>=0){struct stat st;if(fstat(output,&st))return nil;budget.destinationDevice=st.st_dev;budget.destinationInode=st.st_ino;}
    budget.buffer=malloc(CS_CHUNK);if(!budget.buffer)return nil;
    BOOL copied=CSWalk(source,output,@"",0,&budget,files,directories);
    mng_secure_clear(budget.buffer,CS_CHUNK);free(budget.buffer);
    if(!copied)return nil;
    [files sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"path"] compare:b[@"path"] options:NSLiteralSearch];}];
    [directories sortUsingSelector:@selector(compare:)];
    return @{@"schema":@"canopy-save-v1",@"titleID":title,@"profileID":profile,@"files":files,@"directories":directories};
}
static BOOL CSWriteJSON(int directory,const char *name,NSDictionary *document) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:document options:NSJSONWritingSortedKeys error:NULL];
    if(!data||data.length>CSManifestLimit)return NO;
    int fd=openat(directory,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)return NO;
    BOOL ok=CSWrite(fd,data.bytes,data.length)&&!fsync(fd);if(close(fd))ok=NO;
    return ok&&!fsync(directory);
}
static NSDictionary *CSReadJSON(int directory,const char *name) {
    int fd=openat(directory,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    struct stat before,after;
    if(fd<0)return nil;
    if(fstat(fd,&before)||!S_ISREG(before.st_mode)||before.st_nlink!=1||before.st_size<2||before.st_size>(off_t)CSManifestLimit){close(fd);return nil;}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)before.st_size];size_t used=0;BOOL ok=YES;
    while(used<data.length){ssize_t n=read(fd,(unsigned char *)data.mutableBytes+used,data.length-used);if(n<0&&errno==EINTR)continue;if(n<=0){ok=NO;break;}used+=(size_t)n;}
    unsigned char extra;if(ok&&(read(fd,&extra,1)!=0||fstat(fd,&after)||!CSStable(&before,&after)))ok=NO;
    close(fd);if(!ok)return nil;
    id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [value isKindOfClass:NSDictionary.class]?value:nil;
}
static BOOL CSExportShape(int fd) {
    int iteration=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *dir=iteration<0?NULL:fdopendir(iteration);
    if(!dir){if(iteration>=0)close(iteration);return NO;}
    BOOL ok=YES;NSUInteger count=0;struct dirent *entry;errno=0;
    while((entry=readdir(dir))){const char *name=entry->d_name;if(!strcmp(name,".")||!strcmp(name,".."))continue;
        struct stat st;if(++count>2||fstatat(fd,name,&st,AT_SYMLINK_NOFOLLOW)){ok=NO;break;}
        if(!strcmp(name,"data"))ok=S_ISDIR(st.st_mode);
        else if(!strcmp(name,"manifest.json"))ok=S_ISREG(st.st_mode)&&st.st_nlink==1;
        else ok=NO;
        if(!ok)break;errno=0;
    }
    if(!entry&&errno)ok=NO;closedir(dir);return ok&&count==2;
}
static BOOL CSManifestsEqual(NSDictionary *left,NSDictionary *right) {
    // Foundation object equality treats NSNumber YES and integer 1 as equal;
    // their JSON types must remain distinct in this own transfer format.
    NSData *a=[NSJSONSerialization dataWithJSONObject:left options:NSJSONWritingSortedKeys error:NULL];
    NSData *b=[NSJSONSerialization dataWithJSONObject:right options:NSJSONWritingSortedKeys error:NULL];
    return a&&b&&[a isEqual:b];
}
static NSString *CSManifestDigest(NSDictionary *manifest) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingSortedKeys error:NULL];
    struct mng_sha256 *hash=NULL;unsigned char digest[32];
    BOOL ok=data&&data.length<=CSManifestLimit&&!mng_sha256_init(&hash)&&
        !mng_sha256_update(hash,data.bytes,data.length)&&!mng_sha256_final(hash,digest);
    NSString *result=ok?CSHex(digest):nil;mng_secure_clear(digest,sizeof(digest));mng_sha256_free(hash);return result;
}
static BOOL CSDigestValid(NSString *value) {
    return [value isKindOfClass:NSString.class]&&value.length==64&&
        [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
static BOOL CSIntent(int directory,NSDictionary *document,BOOL replace) {
    NSString *temporary=[@".journal-" stringByAppendingString:CSID()];
    BOOL ok=CSWriteJSON(directory,temporary.UTF8String,document);
    if(ok)ok=replace?!renameat(directory,temporary.UTF8String,directory,"transaction.json"):
        !renameatx_np(directory,temporary.UTF8String,directory,"transaction.json",RENAME_EXCL);
    if(ok)ok=!fsync(directory);
    if(!ok)(void)unlinkat(directory,temporary.UTF8String,0);
    return ok;
}

@implementation CanopySaveStore {
    NSURL *_profileURL;
    NSString *_title,*_profile,*_sessionToken;
    NSDictionary *_committedIntent;
    CanopySaveValidator _externalValidator;
    int _profileFD,_backupsFD,_lockFD;
    BOOL _recoveryRequired;
    _Atomic int _sealedStatus,_recoveryStatus;
}
- (instancetype)initWithRootURL:(NSURL *)root titleID:(NSString *)titleID profileID:(NSString *)profileID error:(NSError **)error {
    return [self initWithRootURL:root titleID:titleID profileID:profileID externalValidator:nil error:error];
}
- (instancetype)initWithRootURL:(NSURL *)root titleID:(NSString *)titleID profileID:(NSString *)profileID
    externalValidator:(CanopySaveValidator)validator error:(NSError **)error {
    if(!(self=[super init]))return nil;
    _profileFD=_backupsFD=_lockFD=-1;
    atomic_init(&_sealedStatus,0);atomic_init(&_recoveryStatus,0);
    if(!CSTitle(titleID)||!CSProfile(profileID)||!root.isFileURL){CSFail(error,@"The save title or profile is invalid.",NO);return nil;}
    _title=[titleID copy];_profile=[profileID copy];
    _externalValidator=[validator copy];
    // Profile IDs are case-sensitive logical identities even on a
    // case-insensitive Apple filesystem. Hash their UTF-8 bytes for the folder.
    NSData *profileBytes=[_profile dataUsingEncoding:NSUTF8StringEncoding];
    struct mng_sha256 *profileHash=NULL;unsigned char profileDigest[32];
    BOOL hashed=!mng_sha256_init(&profileHash)&&!mng_sha256_update(profileHash,profileBytes.bytes,profileBytes.length)&&!mng_sha256_final(profileHash,profileDigest);
    mng_sha256_free(profileHash);
    if(!hashed){CSFail(error,@"The save profile identity could not be prepared.",NO);return nil;}
    NSString *profileDirectory=CSHex(profileDigest);mng_secure_clear(profileDigest,sizeof(profileDigest));
    int rootFD=CSRoot(root);struct stat st;
    if(rootFD<0||fstat(rootFD,&st)||st.st_uid!=geteuid()||(st.st_mode&077)){if(rootFD>=0)close(rootFD);CSFail(error,@"Save storage must be a private owned directory.",NO);return nil;}
    int title=CSDir(rootFD,_title.UTF8String,YES);close(rootFD);
    if(title>=0){_profileFD=CSDir(title,profileDirectory.UTF8String,YES);close(title);}
    if(_profileFD<0){CSFail(error,@"The private save profile could not be opened.",NO);return nil;}
    _profileURL=[[root URLByAppendingPathComponent:_title isDirectory:YES] URLByAppendingPathComponent:profileDirectory isDirectory:YES];
    _lockFD=openat(_profileFD,".lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC,0600);
    if(_lockFD<0||fstat(_lockFD,&st)||!S_ISREG(st.st_mode)||st.st_size||st.st_nlink!=1||flock(_lockFD,LOCK_EX|LOCK_NB)){CSFail(error,@"This save profile is already in use or its lock is invalid.",NO);return nil;}
    int active=CSDir(_profileFD,"active",YES),identity=CSDir(_profileFD,"identity",YES);
    _backupsFD=CSDir(_profileFD,"backups",YES);
    BOOL ready=active>=0&&identity>=0&&_backupsFD>=0&&!fsync(_profileFD);
    if(active>=0)close(active);if(identity>=0)close(identity);
    if(!ready){CSFail(error,@"The private save layout could not be prepared.",NO);return nil;}
    if(!fstatat(_profileFD,"transaction.json",&st,AT_SYMLINK_NOFOLLOW))[self markRecovery:YES];
    else if(errno!=ENOENT){CSFail(error,@"The save recovery state could not be read.",NO);return nil;}
    if(!CSCleanStages(_backupsFD,@".pending-") || !CSCleanStages(_profileFD,@".journal-") || (!_recoveryRequired && !CSCleanStages(_profileFD,@".stage-"))){CSFail(error,@"Interrupted save staging could not be cleaned safely. Preserve the profile for recovery.",NO);return nil;}
    return self;
}
- (void)dealloc {if(_backupsFD>=0)close(_backupsFD);if(_lockFD>=0)close(_lockFD);if(_profileFD>=0)close(_profileFD);}
- (NSURL *)activeDirectoryURL {return [_profileURL URLByAppendingPathComponent:@"active" isDirectory:YES];}
- (NSURL *)accountIdentityDirectoryURL {return [_profileURL URLByAppendingPathComponent:@"identity" isDirectory:YES];}
- (BOOL)sealed {return atomic_load(&_sealedStatus)!=0;}
- (BOOL)recoveryRequired {return atomic_load(&_recoveryStatus)!=0;}
- (void)markRecovery:(BOOL)required {
    // Actual transaction gates remain protected by the existing monitor;
    // these mirrors let UI inspect status without waiting for a large copy.
    _recoveryRequired=required;atomic_store(&_recoveryStatus,required?1:0);
}
- (BOOL)externalImportSupported {return _externalValidator!=nil;}
- (BOOL)available:(NSError **)error {
    return (!_sessionToken&&!_recoveryRequired)||CSFail(error,_sessionToken?@"Save transfers are unavailable while a native session owns the profile.":@"Recover the unfinished save transaction before continuing.",NO);
}
- (NSString *)sealForSession:(NSError **)error {@synchronized(self){
    if(![self available:error])return nil;
    int active=CSDir(_profileFD,"active",NO);if(active<0){CSFail(error,@"The active save folder is unavailable.",NO);return nil;}close(active);
    _sessionToken=CSID();atomic_store(&_sealedStatus,1);return _sessionToken;
}}
- (BOOL)finishSessionWithToken:(NSString *)token error:(NSError **)error {@synchronized(self){
    if(!_sessionToken||![_sessionToken isEqual:token])return CSFail(error,@"The session ownership token does not match.",NO);
    _sessionToken=nil;atomic_store(&_sealedStatus,0);return YES;
}}
- (BOOL)createExportAtFD:(int)parent name:(NSString *)name source:(int)source error:(NSError **)error {
    NSString *pending=[@".pending-" stringByAppendingString:CSID()];
    if(mkdirat(parent,pending.UTF8String,0700))return CSFail(error,@"The save copy could not be created.",NO);
    int bundle=CSDir(parent,pending.UTF8String,NO),data=-1;BOOL ok=bundle>=0;
    if(ok){data=CSDir(bundle,"data",YES);ok=data>=0;}
    NSDictionary *manifest=ok?CSManifest(source,data,_title,_profile):nil;
    ok=manifest&&CSWriteJSON(bundle,"manifest.json",manifest)&&!fsync(data)&&!fsync(bundle)&&!fsync(parent);
    if(data>=0)close(data);if(bundle>=0)close(bundle);
    BOOL renamed=NO;
    if(ok){renamed=!renameatx_np(parent,pending.UTF8String,parent,name.UTF8String,RENAME_EXCL);ok=renamed&&!fsync(parent);}
    if(!ok){(void)CSRemove(parent,pending.UTF8String,0);return CSFail(error,renamed?@"A complete save copy may exist, but final directory confirmation failed. Reconcile the destination before retrying.":@"The save copy failed validation or exceeded transfer limits.",renamed);}
    return YES;
}
- (NSURL *)exportToDirectory:(NSURL *)directory error:(NSError **)error {@synchronized(self){
    if(![self available:error])return nil;
    int parent=CSOpen(directory),source=CSDir(_profileFD,"active",NO);
    if(parent<0||source<0){if(parent>=0)close(parent);if(source>=0)close(source);CSFail(error,@"Select an available destination folder.",NO);return nil;}
    NSString *name=[@"Canopy-Save-" stringByAppendingString:CSID()];
    BOOL ok=[self createExportAtFD:parent name:name source:source error:error];close(parent);close(source);
    return ok?[directory URLByAppendingPathComponent:name isDirectory:YES]:nil;
}}
- (NSArray<NSDictionary<NSString *,id> *> *)backups:(NSError **)error {@synchronized(self){
    if(_sessionToken){CSFail(error,@"Save transfers are unavailable while a session owns the profile.",NO);return nil;}
    int iteration=openat(_backupsFD,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *dir=iteration<0?NULL:fdopendir(iteration);
    if(!dir){if(iteration>=0)close(iteration);CSFail(error,@"Backups could not be read.",NO);return nil;}
    NSMutableArray *records=[NSMutableArray array];BOOL ok=YES;struct dirent *entry;errno=0;
    while((entry=readdir(dir))){const char *name=entry->d_name;if(!strcmp(name,".")||!strcmp(name,".."))continue;
        NSString *identifier=[NSString stringWithUTF8String:name];
        if(records.count>=CSBackupLimit||!CSIdentifier(identifier)){ok=NO;break;}
        int fd=CSDir(_backupsFD,name,NO);NSDictionary *manifest=fd<0?nil:CSReadJSON(fd,"manifest.json");
        if(fd>=0)close(fd);
        if(!manifest){ok=NO;break;}[records addObject:@{@"identifier":identifier}];errno=0;
    }
    if(!entry&&errno)ok=NO;closedir(dir);
    if(!ok){CSFail(error,@"The backup catalog is invalid or exceeds its limit.",NO);return nil;}
    [records sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"identifier"] compare:b[@"identifier"]];}];return records;
}}
- (NSString *)backup:(NSError **)error {@synchronized(self){
    if(![self available:error])return nil;
    NSArray *existing=[self backups:error];if(!existing)return nil;
    if(existing.count>=CSBackupLimit){CSFail(error,@"The profile already has 16 backups. Explicitly remove one before adding another.",NO);return nil;}
    int active=CSDir(_profileFD,"active",NO);if(active<0){CSFail(error,@"The active save folder is unavailable.",NO);return nil;}
    NSString *identifier=CSID();BOOL ok=[self createExportAtFD:_backupsFD name:identifier source:active error:error];close(active);return ok?identifier:nil;
}}
- (BOOL)copyExport:(int)source toStage:(NSString *)stage digest:(NSString **)digest error:(NSError **)error {
    struct stat before,after;
    if(fstat(source,&before)||!S_ISDIR(before.st_mode))return CSFail(error,@"The selected export is unavailable.",NO);
    NSDictionary *expected=CSReadJSON(source,"manifest.json");
    if(!expected||!CSExportShape(source)||![expected[@"schema"] isEqual:@"canopy-save-v1"]||
       ![expected[@"titleID"] isEqual:_title]||![expected[@"profileID"] isEqual:_profile])return CSFail(error,@"Choose a Canopy save export for this exact title and profile. Raw save folders are unsupported.",NO);
    int input=openat(source,"data",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(input<0||mkdirat(_profileFD,stage.UTF8String,0700)){if(input>=0)close(input);return CSFail(error,@"The replacement save could not be staged.",NO);}
    int output=CSDir(_profileFD,stage.UTF8String,NO);
    NSDictionary *actual=output<0?nil:CSManifest(input,output,_title,_profile);
    NSString *actualDigest=actual?CSManifestDigest(actual):nil;
    BOOL ok=actualDigest&&CSManifestsEqual(expected,actual)&&!fstat(source,&after)&&CSStable(&before,&after)&&!fsync(output);
    if(output>=0)close(output);close(input);
    if(!ok){(void)CSRemove(_profileFD,stage.UTF8String,0);return CSFail(error,@"The export contents, paths or hashes failed verification.",NO);}
    *digest=actualDigest;return YES;
}
- (BOOL)clearCommittedIntent:(NSError **)error {
    if(unlinkat(_profileFD,"transaction.json",0)&&errno!=ENOENT)return CSFail(error,@"The committed save needs final recovery confirmation.",YES);
    if(fsync(_profileFD))return CSFail(error,@"The committed save needs final recovery confirmation. Reopen and reconcile before continuing.",YES);
    [self markRecovery:NO];_committedIntent=nil;(void)CSCleanStages(_profileFD,@".stage-");return YES;
}
- (BOOL)publishStage:(NSString *)stage backup:(NSString *)backup digest:(NSString *)digest error:(NSError **)error {
    NSDictionary *journal=@{@"schema":@"canopy-save-transaction-v1",@"state":@"prepared",@"stage":stage,@"backupID":backup,@"activeDigest":digest};
    if(!CSIntent(_profileFD,journal,NO)){
        struct stat st;[self markRecovery:!fstatat(_profileFD,"transaction.json",&st,AT_SYMLINK_NOFOLLOW)];
        if(!_recoveryRequired)(void)CSRemove(_profileFD,stage.UTF8String,0);
        return CSFail(error,@"The save transaction could not be recorded. The active save was not replaced.",NO);
    }
    [self markRecovery:YES];
    if(renameatx_np(_profileFD,stage.UTF8String,_profileFD,"active",RENAME_SWAP))return CSFail(error,@"The save replacement was not confirmed. Recover before retrying.",NO);
    if(fsync(_profileFD))return CSFail(error,@"The save replacement may have completed. Recover before continuing.",YES);
    NSMutableDictionary *committed=[journal mutableCopy];committed[@"state"]=@"committed";
    if(!CSIntent(_profileFD,committed,YES))return CSFail(error,@"The save commit was not fully confirmed. Recover before continuing.",YES);
    _committedIntent=[committed copy];return [self clearCommittedIntent:error];
}
- (BOOL)importExportURL:(NSURL *)source error:(NSError **)error {@synchronized(self){
    if(![self available:error])return NO;
    if(!_externalValidator)return CSFail(error,@"No trusted save-format validator is available for this title. External replacement is unavailable.",NO);
    int input=CSOpen(source);if(input<0)return CSFail(error,@"The selected export could not be opened safely.",NO);
    NSString *stage=[@".stage-" stringByAppendingString:CSID()];
    NSString *digest=nil;BOOL ok=[self copyExport:input toStage:stage digest:&digest error:error];close(input);if(!ok)return NO;
    NSError *validationError=nil;
    BOOL accepted=_externalValidator([_profileURL URLByAppendingPathComponent:stage isDirectory:YES],&validationError);
    int staged=CSDir(_profileFD,stage.UTF8String,NO);
    NSDictionary *checked=accepted&&staged>=0?CSManifest(staged,-1,_title,_profile):nil;
    if(staged>=0)close(staged);
    if(!checked||![CSManifestDigest(checked) isEqual:digest]){
        (void)CSRemove(_profileFD,stage.UTF8String,0);
        return CSFail(error,@"The replacement does not pass this title's trusted save-format validation.",NO);
    }
    NSString *backup=[self backup:error];
    if(!backup){(void)CSRemove(_profileFD,stage.UTF8String,0);return NO;}
    return [self publishStage:stage backup:backup digest:digest error:error];
}}
- (BOOL)restoreBackup:(NSString *)identifier error:(NSError **)error {@synchronized(self){
    if(![self available:error]||!CSIdentifier(identifier))return CSFail(error,@"Select a valid backup before restoring.",NO);
    int source=CSDir(_backupsFD,identifier.UTF8String,NO);if(source<0)return CSFail(error,@"The selected backup is unavailable.",NO);
    NSString *stage=[@".stage-" stringByAppendingString:CSID()],*digest=nil;BOOL ok=[self copyExport:source toStage:stage digest:&digest error:error];close(source);if(!ok)return NO;
    NSString *previous=[self backup:error];if(!previous){(void)CSRemove(_profileFD,stage.UTF8String,0);return NO;}
    return [self publishStage:stage backup:previous digest:digest error:error];
}}
- (BOOL)removeBackup:(NSString *)identifier error:(NSError **)error {@synchronized(self){
    if(![self available:error]||!CSIdentifier(identifier))return CSFail(error,@"Select a valid backup before removing it.",NO);
    return (CSRemove(_backupsFD,identifier.UTF8String,0)&&!fsync(_backupsFD))||CSFail(error,@"The backup could not be removed safely.",NO);
}}
- (BOOL)recover:(NSError **)error {@synchronized(self){
    if(_sessionToken)return CSFail(error,@"Recovery is unavailable while a session owns the profile.",NO);
    if(!_recoveryRequired)return YES;
    NSDictionary *journal=CSReadJSON(_profileFD,"transaction.json");
    if(!journal){struct stat st;if(fstatat(_profileFD,"transaction.json",&st,AT_SYMLINK_NOFOLLOW)&&errno==ENOENT)journal=_committedIntent;}
    NSString *stage=journal[@"stage"],*backup=journal[@"backupID"];
    NSSet *keys=[NSSet setWithArray:@[@"schema",@"state",@"stage",@"backupID",@"activeDigest"]];
    if(!journal||![[NSSet setWithArray:journal.allKeys] isEqual:keys]||![journal[@"schema"] isEqual:@"canopy-save-transaction-v1"]||
       ![@[@"prepared",@"committed"] containsObject:journal[@"state"]]||!CSDigestValid(journal[@"activeDigest"])||
       ![stage isKindOfClass:NSString.class]||![stage hasPrefix:@".stage-"]||!CSIdentifier([stage substringFromIndex:7])||!CSIdentifier(backup))return CSFail(error,@"The transaction journal is invalid. Preserve the profile for manual recovery.",NO);
    if([journal[@"state"] isEqual:@"committed"]){
        int active=CSDir(_profileFD,"active",NO);NSDictionary *actual=active<0?nil:CSManifest(active,-1,_title,_profile);if(active>=0)close(active);
        if(!actual||![CSManifestDigest(actual) isEqual:journal[@"activeDigest"]])return CSFail(error,@"The committed active save failed recovery verification. Preserve the profile.",YES);
        _committedIntent=journal;return [self clearCommittedIntent:error];
    }
    int source=CSDir(_backupsFD,backup.UTF8String,NO);if(source<0)return CSFail(error,@"The rollback backup is unavailable. Preserve the profile for manual recovery.",NO);
    NSString *recovery=[@".stage-" stringByAppendingString:CSID()],*digest=nil;BOOL ok=[self copyExport:source toStage:recovery digest:&digest error:error];close(source);if(!ok)return NO;
    if(renameatx_np(_profileFD,recovery.UTF8String,_profileFD,"active",RENAME_SWAP)||fsync(_profileFD))return CSFail(error,@"Rollback was not confirmed. Preserve the profile and retry recovery.",YES);
    NSMutableDictionary *committed=[journal mutableCopy];committed[@"state"]=@"committed";committed[@"activeDigest"]=digest;
    if(!CSIntent(_profileFD,committed,YES))return CSFail(error,@"Rollback confirmation failed. Reopen and reconcile the profile.",YES);
    _committedIntent=[committed copy];return [self clearCommittedIntent:error];
}}
@end
