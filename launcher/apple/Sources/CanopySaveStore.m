#import "CanopySaveStore.h"
#import <CoreFoundation/CoreFoundation.h>
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
/* Backup retirement is separate from replacement's rollback journal. Its
 * immutable record authorizes only an exact, preflighted private tree. Never
 * use the generic staging remover on a canonical or partially retired backup. */
static const NSUInteger CSRetirementLimit=16*1024*1024;
static BOOL CSKeys(NSDictionary *value,NSArray *keys) {
    return [value isKindOfClass:NSDictionary.class]&&
        [[NSSet setWithArray:value.allKeys] isEqual:[NSSet setWithArray:keys]];
}
static BOOL CSUInt(id value,uint64_t *out) {
    if(![value isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID())return NO;
    const char *text=[value stringValue].UTF8String;
    if(!text||!*text)return NO;uint64_t n=0;
    for(const char *p=text;*p;p++){if(*p<'0'||*p>'9'||n>(UINT64_MAX-(unsigned)(*p-'0'))/10)return NO;n=n*10+(unsigned)(*p-'0');}
    *out=n;return YES;
}
static BOOL CSRetirementPath(NSString *path) {
    if(![path isKindOfClass:NSString.class]||!path.length)return NO;
    BOOL payload=[path hasPrefix:@"data/"];
    if(payload?path.length>1024+5:(![path isEqual:@"data"]&&![path isEqual:@"manifest.json"]))return NO;
    NSArray *parts=path.pathComponents;if(parts.count>14||![[parts componentsJoinedByString:@"/"] isEqual:path])return NO;
    for(NSString *part in parts)if(!CSLeaf(part.UTF8String)||[part.lowercaseString isEqual:@"account.uid"])return NO;
    return [path isEqual:@"manifest.json"]||[path isEqual:@"data"]||[path hasPrefix:@"data/"];
}
static BOOL CSRetirementIdentity(int fd,NSDictionary *entry,BOOL directory) {
    uint64_t device,inode;struct stat st={0};
    return CSUInt(entry[@"device"],&device)&&CSUInt(entry[@"inode"],&inode)&&
        !fstat(fd,&st)&&st.st_uid==geteuid()&&!(st.st_mode&077)&&
        (directory?S_ISDIR(st.st_mode):(S_ISREG(st.st_mode)&&st.st_nlink==1))&&
        (uint64_t)st.st_dev==device&&(uint64_t)st.st_ino==inode;
}
static NSString *CSRetirementHash(int fd,uint64_t *size,unsigned char *buffer) {
    struct stat before={0},after={0};struct mng_sha256 *hash=NULL;unsigned char digest[32];uint64_t used=0;
    BOOL ok=!fstat(fd,&before)&&S_ISREG(before.st_mode)&&before.st_nlink==1&&
        before.st_uid==geteuid()&&!(before.st_mode&077)&&before.st_size>=0&&(uint64_t)before.st_size<=CSFileLimit&&
        !mng_sha256_init(&hash);
    while(ok){ssize_t n=read(fd,buffer,CS_CHUNK);if(n<0&&errno==EINTR)continue;
        if(n<0){ok=NO;break;}if(!n)break;
        if((uint64_t)n>(uint64_t)before.st_size-used){ok=NO;break;}used+=(uint64_t)n;
        ok=!mng_sha256_update(hash,buffer,(size_t)n);
    }
    if(ok)ok=used==(uint64_t)before.st_size&&!fstat(fd,&after)&&CSStable(&before,&after)&&!mng_sha256_final(hash,digest);
    NSString *result=ok?CSHex(digest):nil;if(ok)*size=used;
    mng_secure_clear(digest,sizeof(digest));mng_sha256_free(hash);return result;
}
static BOOL CSRetirementScan(int fd,NSString *prefix,unsigned depth,NSMutableArray *rows,
    uint64_t *total,unsigned char *buffer) {
    if(depth>13)return NO;struct stat before={0},after={0};
    if(fstat(fd,&before)||!S_ISDIR(before.st_mode)||before.st_uid!=geteuid()||(before.st_mode&077))return NO;
    int iteration=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    DIR *dir=iteration<0?NULL:fdopendir(iteration);if(!dir){if(iteration>=0)close(iteration);return NO;}
    BOOL ok=YES;NSMutableSet *names=[NSMutableSet set];struct dirent *ent;errno=0;
    while((ent=readdir(dir))){const char *name=ent->d_name;if(!strcmp(name,".")||!strcmp(name,".."))continue;
        if(rows.count>=CSEntryLimit+2||!CSLeaf(name)){ok=NO;break;}
        NSString *leaf=[NSString stringWithUTF8String:name],*path=prefix.length?[prefix stringByAppendingFormat:@"/%@",leaf]:leaf;
        if(!CSRetirementPath(path)||[names containsObject:leaf.lowercaseString]){ok=NO;break;}[names addObject:leaf.lowercaseString];
        struct stat st={0},opened={0};
        if(fstatat(fd,name,&st,AT_SYMLINK_NOFOLLOW)||(!S_ISDIR(st.st_mode)&&!S_ISREG(st.st_mode))){ok=NO;break;}
        BOOL directory=S_ISDIR(st.st_mode);int child=openat(fd,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|(directory?O_DIRECTORY:O_NONBLOCK));
        if(child<0||fstat(child,&opened)||!CSStable(&st,&opened)||st.st_uid!=geteuid()||(st.st_mode&077)||(!directory&&st.st_nlink!=1)){
            if(child>=0)close(child);ok=NO;break;}
        NSMutableDictionary *row=[@{@"path":path,@"kind":directory?@"directory":@"file",@"device":@((uint64_t)st.st_dev),@"inode":@((uint64_t)st.st_ino)} mutableCopy];
        [rows addObject:row];
        if(directory)ok=CSRetirementScan(child,path,depth+1,rows,total,buffer);
        else {uint64_t size=0;NSString *hash=CSRetirementHash(child,&size,buffer);
            ok=hash&&size<=CSTotalLimit+CSManifestLimit-*total;
            if(ok){*total+=size;row[@"size"]=@(size);row[@"sha256"]=hash;}}
        close(child);if(!ok)break;errno=0;
    }
    if(!ent&&errno)ok=NO;
    if(ok&&(fstat(fd,&after)||!CSStable(&before,&after)))ok=NO;
    closedir(dir);return ok;
}
static NSArray *CSRetirementInventory(int fd) {
    unsigned char *buffer=malloc(CS_CHUNK);if(!buffer)return nil;
    NSMutableArray *rows=[NSMutableArray array];uint64_t total=0;
    BOOL ok=CSRetirementScan(fd,@"",0,rows,&total,buffer);
    mng_secure_clear(buffer,CS_CHUNK);free(buffer);
    if(!ok)return nil;
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"path"] compare:b[@"path"] options:NSLiteralSearch];}];return rows;
}
static NSData *CSRetirementBytes(NSDictionary *record) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL];
    return data.length&&data.length<=CSRetirementLimit?data:nil;
}
static NSString *CSRetirementDigest(NSData *data) {
    struct mng_sha256 *hash=NULL;unsigned char digest[32];
    BOOL ok=data&&!mng_sha256_init(&hash)&&!mng_sha256_update(hash,data.bytes,data.length)&&!mng_sha256_final(hash,digest);
    mng_sha256_free(hash);NSString *result=ok?CSHex(digest):nil;mng_secure_clear(digest,sizeof(digest));return result;
}
static NSDictionary *CSRetirementRead(int fd,const char *name) {
    int input=openat(fd,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);struct stat before={0},after={0};
    if(input<0)return nil;
    BOOL ok=!fstat(input,&before)&&S_ISREG(before.st_mode)&&before.st_nlink==1&&before.st_uid==geteuid()&&
        !(before.st_mode&077)&&before.st_size>=2&&(uint64_t)before.st_size<=CSRetirementLimit;
    NSMutableData *data=ok?[NSMutableData dataWithLength:(NSUInteger)before.st_size]:nil;size_t used=0;
    while(ok&&used<data.length){ssize_t n=read(input,(unsigned char *)data.mutableBytes+used,data.length-used);
        if(n<0&&errno==EINTR)continue;if(n<=0){ok=NO;break;}used+=(size_t)n;}
    unsigned char extra;if(ok&&(read(input,&extra,1)!=0||fstat(input,&after)||!CSStable(&before,&after)))ok=NO;close(input);
    id value=ok?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
    if(!CSKeys(value,@[@"record",@"sha256"])||!CSDigestValid(value[@"sha256"])||
        ![value[@"record"] isKindOfClass:NSDictionary.class]||
        ![CSRetirementDigest(CSRetirementBytes(value[@"record"])) isEqual:value[@"sha256"]])return nil;
    return value[@"record"];
}
static BOOL CSRetirementWrite(int fd,NSDictionary *record) {
    NSString *digest=CSRetirementDigest(CSRetirementBytes(record));
    NSData *bytes=digest?CSRetirementBytes(@{@"record":record,@"sha256":digest}):nil;if(!bytes)return NO;
    int output=openat(fd,"intent.json",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(output<0)return NO;
    BOOL ok=CSWrite(output,bytes.bytes,bytes.length)&&!fsync(output);if(close(output))ok=NO;return ok&&!fsync(fd);
}
static BOOL CSRetirementSyncFile(int directory,const char *name,BOOL empty) {
    int fd=openat(directory,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);if(fd<0)return NO;
    struct stat before={0},after={0},named={0};
    BOOL ok=!fstat(fd,&before)&&S_ISREG(before.st_mode)&&before.st_nlink==1&&before.st_uid==geteuid()&&
        !(before.st_mode&077)&&(!empty||!before.st_size)&&!fsync(fd)&&!fstat(fd,&after)&&CSStable(&before,&after)&&
        !fstatat(directory,name,&named,AT_SYMLINK_NOFOLLOW)&&CSStable(&after,&named);
    if(close(fd))ok=NO;return ok;
}
static BOOL CSRetirementRecord(NSDictionary *record,NSString *title,NSString *profile) {
    uint64_t device,inode;
    if(!CSKeys(record,@[@"schema",@"titleID",@"profileID",@"backupID",@"device",@"inode",@"manifestSHA256",@"entries"])||
        ![record[@"schema"] isEqual:@"canopy-backup-retirement-v1"]||![record[@"titleID"] isEqual:title]||
        ![record[@"profileID"] isEqual:profile]||!CSIdentifier(record[@"backupID"])||
        !CSUInt(record[@"device"],&device)||!CSUInt(record[@"inode"],&inode)||!inode||
        !CSDigestValid(record[@"manifestSHA256"])||![record[@"entries"] isKindOfClass:NSArray.class])return NO;
    NSArray *entries=record[@"entries"];if(entries.count<2||entries.count>CSEntryLimit+2)return NO;
    NSMutableDictionary *seen=[NSMutableDictionary dictionary];NSMutableSet *folded=[NSMutableSet set];uint64_t total=0;NSString *previous=nil;
    for(NSDictionary *row in entries){if(![row isKindOfClass:NSDictionary.class])return NO;
        uint64_t size=0;NSString *path=row[@"path"],*kind=row[@"kind"];
        BOOL directory=[kind isEqual:@"directory"];
        if(!CSKeys(row,directory?@[@"path",@"kind",@"device",@"inode"]:@[@"path",@"kind",@"device",@"inode",@"size",@"sha256"])||
            (!directory&&![kind isEqual:@"file"])||!CSRetirementPath(path)||!CSUInt(row[@"device"],&device)||
            !CSUInt(row[@"inode"],&inode)||!inode||[folded containsObject:path.lowercaseString]||
            (previous&&[previous compare:path options:NSLiteralSearch]!=NSOrderedAscending))return NO;
        NSString *parent=path.stringByDeletingLastPathComponent;
        if(parent.length&&![seen[parent][@"kind"] isEqual:@"directory"])return NO;
        if(!directory&&(!CSUInt(row[@"size"],&size)||size>CSFileLimit||size>CSTotalLimit+CSManifestLimit-total||!CSDigestValid(row[@"sha256"])))return NO;
        total+=size;seen[path]=row;[folded addObject:path.lowercaseString];previous=path;
    }
    return [seen[@"data"][@"kind"] isEqual:@"directory"]&&[seen[@"manifest.json"][@"kind"] isEqual:@"file"]&&
        [seen[@"manifest.json"][@"sha256"] isEqual:record[@"manifestSHA256"]];
}
static BOOL CSRetirementShape(int fd,BOOL *intent,BOOL *completed,BOOL *deleting,BOOL *target) {
    *intent=*completed=*deleting=*target=NO;
    int iteration=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *dir=iteration<0?NULL:fdopendir(iteration);
    if(!dir){if(iteration>=0)close(iteration);return NO;}BOOL ok=YES;unsigned count=0;struct dirent *ent;errno=0;
    while((ent=readdir(dir))){const char *name=ent->d_name;if(!strcmp(name,".")||!strcmp(name,".."))continue;
        struct stat st={0};if(++count>4||fstatat(fd,name,&st,AT_SYMLINK_NOFOLLOW)||st.st_uid!=geteuid()||(st.st_mode&077)){ok=NO;break;}
        if(!strcmp(name,"retired")){ok=S_ISDIR(st.st_mode);*target=YES;}
        else {ok=S_ISREG(st.st_mode)&&st.st_nlink==1;
            if(!strcmp(name,"intent.json"))*intent=YES;
            else if(!strcmp(name,"completed.json"))*completed=YES;
            else if(!strcmp(name,"deleting")){*deleting=YES;ok=ok&&!st.st_size;}
            else ok=NO;}
        if(!ok)break;errno=0;
    }
    if(!ent&&errno)ok=NO;closedir(dir);return ok&&!(*intent&&*completed);
}
static int CSRetirementParent(int root,NSString *path,NSDictionary *expected,NSString **leaf) {
    NSArray *parts=path.pathComponents;int fd=dup(root);if(fd<0)return -1;
    NSString *prefix=@"";
    for(NSUInteger i=0;i+1<parts.count;i++){
        prefix=prefix.length?[prefix stringByAppendingFormat:@"/%@",parts[i]]:parts[i];
        int next=CSDir(fd,[parts[i] UTF8String],NO);close(fd);
        if(next<0)return -1;
        if(!expected[prefix]||!CSRetirementIdentity(next,expected[prefix],YES)){close(next);return -1;}fd=next;
    }
    *leaf=parts.lastObject;return fd;
}
static BOOL CSRetirementEmpty(int fd) {
    int iteration=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *dir=iteration<0?NULL:fdopendir(iteration);
    if(!dir){if(iteration>=0)close(iteration);return NO;}BOOL empty=YES;struct dirent *ent;errno=0;
    while((ent=readdir(dir))){if(strcmp(ent->d_name,".")&&strcmp(ent->d_name,"..")){empty=NO;break;}errno=0;}
    if(!ent&&errno)empty=NO;closedir(dir);return empty;
}
static BOOL CSRetirementSubset(int target,NSDictionary *record,BOOL complete,NSArray **survivors) {
    if(!CSRetirementIdentity(target,record,YES))return NO;
    NSArray *actual=CSRetirementInventory(target);if(!actual)return NO;
    NSArray *expected=record[@"entries"];NSMutableDictionary *byPath=[NSMutableDictionary dictionary];
    for(NSDictionary *row in expected)byPath[row[@"path"]]=row;
    for(NSDictionary *row in actual)if(!byPath[row[@"path"]]||!CSManifestsEqual(row,byPath[row[@"path"]]))return NO;
    if(complete&&actual.count!=expected.count)return NO;
    *survivors=actual;return YES;
}
static BOOL CSRetirementMatchesManifest(NSArray *entries,NSDictionary *manifest) {
    NSMutableDictionary *files=[NSMutableDictionary dictionary];NSMutableSet *directories=[NSMutableSet set];
    for(NSDictionary *row in manifest[@"files"])files[row[@"path"]]=row;
    for(NSString *path in manifest[@"directories"])[directories addObject:path];
    NSUInteger fileCount=0,directoryCount=0;
    for(NSDictionary *row in entries){NSString *path=row[@"path"];
        if([path isEqual:@"data"]||[path isEqual:@"manifest.json"])continue;
        if(![path hasPrefix:@"data/"])return NO;NSString *relative=[path substringFromIndex:5];
        if([row[@"kind"] isEqual:@"directory"]){if(![directories containsObject:relative])return NO;directoryCount++;}
        else {NSDictionary *file=files[relative];
            if(!file||![row[@"size"] isEqual:file[@"size"]]||![row[@"sha256"] isEqual:file[@"sha256"]])return NO;fileCount++;}
    }
    return fileCount==files.count&&directoryCount==directories.count;
}
static BOOL CSRetirementDelete(int target,NSArray *survivors) {
    /* Full surviving-subset preflight already succeeded. Recheck each opened
     * inode, then delete deepest paths first, retaining the manifest until last. */
    NSArray *ordered=[survivors sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
        NSString *pa=a[@"path"],*pb=b[@"path"];
        if([pa isEqual:pb])return NSOrderedSame;
        if([pa isEqual:@"manifest.json"])return NSOrderedDescending;
        if([pb isEqual:@"manifest.json"])return NSOrderedAscending;
        NSUInteger da=pa.pathComponents.count,db=pb.pathComponents.count;
        return da==db?[pb compare:pa options:NSLiteralSearch]:(da>db?NSOrderedAscending:NSOrderedDescending);
    }];
    NSMutableDictionary *expected=[NSMutableDictionary dictionary];for(NSDictionary *row in survivors)expected[row[@"path"]]=row;
    unsigned char *buffer=malloc(CS_CHUNK);if(!buffer)return NO;BOOL removed=YES;
    for(NSDictionary *row in ordered){NSString *leaf=nil;int parent=CSRetirementParent(target,row[@"path"],expected,&leaf);
        BOOL directory=[row[@"kind"] isEqual:@"directory"];
        int child=parent<0?-1:openat(parent,leaf.UTF8String,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|(directory?O_DIRECTORY:O_NONBLOCK));
        BOOL ok=child>=0&&CSRetirementIdentity(child,row,directory)&&(!directory||CSRetirementEmpty(child));
        if(ok&&!directory){uint64_t size=0;NSString *hash=CSRetirementHash(child,&size,buffer);
            ok=hash&&[hash isEqual:row[@"sha256"]]&&[row[@"size"] unsignedLongLongValue]==size;}
        struct stat named={0};uint64_t device=0,inode=0;
        if(ok)ok=CSUInt(row[@"device"],&device)&&CSUInt(row[@"inode"],&inode)&&
            !fstatat(parent,leaf.UTF8String,&named,AT_SYMLINK_NOFOLLOW)&&
            (uint64_t)named.st_dev==device&&(uint64_t)named.st_ino==inode;
        if(ok)ok=!unlinkat(parent,leaf.UTF8String,directory?AT_REMOVEDIR:0)&&!fsync(parent);
        if(child>=0)close(child);if(parent>=0)close(parent);if(!ok){removed=NO;break;}
    }
    mng_secure_clear(buffer,CS_CHUNK);free(buffer);
    return removed&&CSRetirementEmpty(target)&&!fsync(target);
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

@interface CanopySaveEditPreview ()
@property(nonatomic,readwrite,copy) NSString *relativePath;
@property(nonatomic,readwrite,copy) NSData *originalData;
@property(nonatomic,copy) NSString *stage;
@property(nonatomic,copy) NSString *digest;
@property(nonatomic,copy) NSString *slot;
@property(nonatomic,copy) NSDictionary *manifest;
@property(nonatomic) BOOL valid;
- (instancetype)initPrivate;
@end
@implementation CanopySaveEditPreview
- (instancetype)initPrivate {return [super init];}
@end
static BOOL CSEditSlot(NSString *slot) {
    return [slot isKindOfClass:NSString.class]&&slot.length==7&&[slot hasPrefix:@"slot_0"]&&
        [slot characterAtIndex:6]>='0'&&[slot characterAtIndex:6]<='5';
}
static NSData *CSEditRead(int parent) {
    int fd=openat(parent,"progress.sav",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(fd<0)return nil;struct stat before={0},after={0};
    BOOL ok=!fstat(fd,&before)&&S_ISREG(before.st_mode)&&before.st_nlink==1&&before.st_uid==geteuid()&&
        !(before.st_mode&077)&&before.st_size>=0&&(uint64_t)before.st_size<=CSFileLimit;
    NSMutableData *data=ok?[NSMutableData dataWithLength:(NSUInteger)before.st_size]:nil;size_t used=0;
    while(ok&&used<data.length){ssize_t n=read(fd,(unsigned char *)data.mutableBytes+used,data.length-used);
        if(n<0&&errno==EINTR)continue;if(n<=0){ok=NO;break;}used+=(size_t)n;}
    unsigned char extra;if(ok&&(read(fd,&extra,1)!=0||fstat(fd,&after)||!CSStable(&before,&after)))ok=NO;
    close(fd);return ok?[data copy]:nil;
}
static NSString *CSEditDigest(NSData *data) {
    struct mng_sha256 *hash=NULL;unsigned char digest[32];
    BOOL ok=!mng_sha256_init(&hash)&&!mng_sha256_update(hash,data.bytes,data.length)&&!mng_sha256_final(hash,digest);
    mng_sha256_free(hash);NSString *result=ok?CSHex(digest):nil;mng_secure_clear(digest,sizeof(digest));return result;
}

@implementation CanopySaveStore {
    NSURL *_profileURL;
    NSString *_title,*_profile,*_sessionToken;
    NSDictionary *_committedIntent;
    CanopySaveValidator _externalValidator;
    CanopySaveEditValidator _editValidator;
    CanopySaveEditPreview *_editPreview;
    int _profileFD,_backupsFD,_lockFD;
    BOOL _recoveryRequired,_transactionRecoveryRequired,_backupRecoveryRequired;
    _Atomic int _sealedStatus,_recoveryStatus;
}
- (instancetype)initWithRootURL:(NSURL *)root titleID:(NSString *)titleID profileID:(NSString *)profileID error:(NSError **)error {
    return [self initWithRootURL:root titleID:titleID profileID:profileID externalValidator:nil error:error];
}
- (instancetype)initWithRootURL:(NSURL *)root titleID:(NSString *)titleID profileID:(NSString *)profileID
    externalValidator:(CanopySaveValidator)validator error:(NSError **)error {
    return [self initWithRootURL:root titleID:titleID profileID:profileID externalValidator:validator editValidator:nil error:error];
}
- (instancetype)initWithRootURL:(NSURL *)root titleID:(NSString *)titleID profileID:(NSString *)profileID
    externalValidator:(CanopySaveValidator)validator editValidator:(CanopySaveEditValidator)editValidator error:(NSError **)error {
    if(!(self=[super init]))return nil;
    _profileFD=_backupsFD=_lockFD=-1;
    atomic_init(&_sealedStatus,0);atomic_init(&_recoveryStatus,0);
    if(!CSTitle(titleID)||!CSProfile(profileID)||!root.isFileURL){CSFail(error,@"The save title or profile is invalid.",NO);return nil;}
    _title=[titleID copy];_profile=[profileID copy];
    _externalValidator=[validator copy];_editValidator=[editValidator copy];
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
    if(!fstatat(_profileFD,".backup-retirement",&st,AT_SYMLINK_NOFOLLOW)){
        int retirement=CSDir(_profileFD,".backup-retirement",NO);BOOL intent=NO,completed=NO,deleting=NO,target=NO;
        BOOL empty=retirement>=0&&CSRetirementShape(retirement,&intent,&completed,&deleting,&target)&&!intent&&!completed&&!deleting&&!target&&
            !fsync(retirement)&&!fsync(_backupsFD)&&!fsync(_profileFD);
        if(retirement>=0)close(retirement);[self markBackupRecovery:!empty];
    }else if(errno!=ENOENT){CSFail(error,@"Backup retirement state could not be inspected. Preserve the profile.",NO);return nil;}
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
    _transactionRecoveryRequired=required;
    _recoveryRequired=required||_backupRecoveryRequired;atomic_store(&_recoveryStatus,_recoveryRequired?1:0);
}
- (void)markBackupRecovery:(BOOL)required {
    _backupRecoveryRequired=required;
    _recoveryRequired=required||_transactionRecoveryRequired;atomic_store(&_recoveryStatus,_recoveryRequired?1:0);
}
- (BOOL)externalImportSupported {return _externalValidator!=nil;}
- (BOOL)editingSupported {return _externalValidator!=nil&&_editValidator!=nil;}
- (BOOL)available:(NSError **)error {
    return (!_sessionToken&&!_recoveryRequired)||CSFail(error,_sessionToken?@"Save transfers are unavailable while a native session owns the profile.":@"Recover the unfinished save transaction before continuing.",NO);
}
- (NSString *)sealForSession:(NSError **)error {@synchronized(self){
    if(![self available:error])return nil;
    int active=CSDir(_profileFD,"active",NO);if(active<0){CSFail(error,@"The active save folder is unavailable.",NO);return nil;}close(active);
    _editPreview.valid=NO; // A preview never survives a native-writer session.
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
       ![expected[@"titleID"] isEqual:_title]||![expected[@"profileID"] isEqual:_profile])return CSFail(error,@"Choose a Canopy export for this exact title and profile. Supported raw saves use the separate title-validated folder import.",NO);
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
- (BOOL)copyRaw:(int)source toStage:(NSString *)stage digest:(NSString **)digest error:(NSError **)error {
    if(mkdirat(_profileFD,stage.UTF8String,0700))return CSFail(error,@"The raw save replacement could not be staged.",NO);
    int output=CSDir(_profileFD,stage.UTF8String,NO);
    NSDictionary *actual=output<0?nil:CSManifest(source,output,_title,_profile);
    NSString *actualDigest=actual?CSManifestDigest(actual):nil;
    BOOL ok=actualDigest&&!fsync(output);if(output>=0)close(output);
    if(!ok){(void)CSRemove(_profileFD,stage.UTF8String,0);return CSFail(error,@"The selected raw folder changed, contains unsupported paths or links, or exceeds save-transfer limits.",NO);}
    *digest=actualDigest;return YES;
}
- (BOOL)validateExternalStage:(NSString *)stage digest:(NSString *)digest error:(NSError **)error {
    NSError *validationError=nil;
    BOOL accepted=_externalValidator&&_externalValidator([_profileURL URLByAppendingPathComponent:stage isDirectory:YES],&validationError);
    int staged=CSDir(_profileFD,stage.UTF8String,NO);
    NSDictionary *checked=accepted&&staged>=0?CSManifest(staged,-1,_title,_profile):nil;
    if(staged>=0)close(staged);
    if(!checked||![CSManifestDigest(checked) isEqual:digest]){
        (void)CSRemove(_profileFD,stage.UTF8String,0);
        return CSFail(error,@"The replacement does not pass this title's trusted save-format validation.",NO);
    }
    return YES;
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
- (BOOL)discardEditPreview:(CanopySaveEditPreview *)preview error:(NSError **)error {@synchronized(self){
    if(!preview||preview!=_editPreview)return CSFail(error,@"The edit preview belongs to another or expired save operation.",NO);
    preview.valid=NO;
    struct stat st;
    if(fstatat(_profileFD,preview.stage.UTF8String,&st,AT_SYMLINK_NOFOLLOW)) {
        if(errno!=ENOENT)return CSFail(error,@"The private edit preview could not be inspected safely.",NO);
    } else if(!CSRemove(_profileFD,preview.stage.UTF8String,0))return CSFail(error,@"The private edit preview could not be discarded safely.",NO);
    _editPreview=nil;return YES;
}}
- (CanopySaveEditPreview *)previewEditForSlot:(NSString *)slot error:(NSError **)error {@synchronized(self){
    if(![self available:error]||!CSEditSlot(slot)){CSFail(error,@"Select a supported slot before previewing an edit.",NO);return nil;}
    slot=[slot copy];
    if(_editPreview&&![self discardEditPreview:_editPreview error:error])return nil;
    int active=CSDir(_profileFD,"active",NO);if(active<0){CSFail(error,@"The active save is unavailable.",NO);return nil;}
    NSString *stage=[@".stage-" stringByAppendingString:CSID()],*digest=nil;
    BOOL copied=[self copyRaw:active toStage:stage digest:&digest error:error];
    NSDictionary *current=copied?CSManifest(active,-1,_title,_profile):nil;close(active);
    int snapshot=copied?CSDir(_profileFD,stage.UTF8String,NO):-1;
    NSDictionary *manifest=snapshot>=0?CSManifest(snapshot,-1,_title,_profile):nil;
    int selected=snapshot>=0?CSDir(snapshot,slot.UTF8String,NO):-1;NSData *data=selected>=0?CSEditRead(selected):nil;
    if(selected>=0)close(selected);if(snapshot>=0)close(snapshot);
    if(!data||!manifest||!current||![CSManifestDigest(manifest) isEqual:digest]||![CSManifestDigest(current) isEqual:digest]) {
        if(copied)(void)CSRemove(_profileFD,stage.UTF8String,0);
        CSFail(error,@"The save changed or its selected slot could not be previewed safely.",NO);return nil;
    }
    CanopySaveEditPreview *preview=[[CanopySaveEditPreview alloc] initPrivate];
    preview.slot=slot;preview.relativePath=[slot stringByAppendingString:@"/progress.sav"];preview.originalData=data;
    preview.stage=stage;preview.digest=digest;preview.manifest=manifest;preview.valid=YES;_editPreview=preview;return preview;
}}
- (BOOL)applyEditPreview:(CanopySaveEditPreview *)preview replacementData:(NSData *)data error:(NSError **)error {@synchronized(self){
    if(![self available:error])return NO;
    if(!self.editingSupported)return CSFail(error,@"No trusted format and integrity edit contract is available. Active save editing is unavailable.",NO);
    if(!preview||preview!=_editPreview||!preview.valid||![data isKindOfClass:NSData.class]||data.length>CSFileLimit)
        return CSFail(error,@"The edit preview or replacement is invalid or expired.",NO);
    NSData *replacement=[data copy];int active=CSDir(_profileFD,"active",NO),stage=CSDir(_profileFD,preview.stage.UTF8String,NO);
    NSDictionary *current=active>=0?CSManifest(active,-1,_title,_profile):nil;
    NSDictionary *snapshot=stage>=0?CSManifest(stage,-1,_title,_profile):nil;
    if(active>=0)close(active);
    if(!current||!snapshot||![CSManifestDigest(current) isEqual:preview.digest]||![CSManifestDigest(snapshot) isEqual:preview.digest]) {
        if(stage>=0)close(stage);preview.valid=NO;return CSFail(error,@"The active save or private preview changed. Create a new preview.",NO);
    }
    NSError *validationError=nil;
    if(!_editValidator(preview.relativePath,preview.originalData,replacement,&validationError)) {
        close(stage);return CSFail(error,@"The edit does not pass the trusted field and integrity contract.",NO);
    }
    int selected=CSDir(stage,preview.slot.UTF8String,NO);NSString *temporary=[@".edit-" stringByAppendingString:CSID()];
    int output=selected>=0?openat(selected,temporary.UTF8String,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600):-1;
    BOOL ok=output>=0&&CSWrite(output,replacement.bytes,replacement.length)&&!fsync(output);
    if(output>=0&&close(output))ok=NO;
    if(ok)ok=!renameat(selected,temporary.UTF8String,selected,"progress.sav")&&!fsync(selected);
    if(!ok&&selected>=0)(void)unlinkat(selected,temporary.UTF8String,0);
    if(selected>=0)close(selected);if(ok)ok=!fsync(stage);
    NSMutableDictionary *expected=[preview.manifest mutableCopy];NSMutableArray *files=[expected[@"files"] mutableCopy];
    NSString *newHash=CSEditDigest(replacement);BOOL found=NO;
    for(NSUInteger i=0;i<files.count;i++)if([files[i][@"path"] isEqual:preview.relativePath]) {
        files[i]=@{@"path":preview.relativePath,@"size":@(replacement.length),@"sha256":newHash?:@""};found=YES;break;
    }
    expected[@"files"]=files;
    NSDictionary *actual=ok&&found&&newHash?CSManifest(stage,-1,_title,_profile):nil;close(stage);
    ok=actual&&CSManifestsEqual(expected,actual);
    if(ok)ok=[self validateExternalStage:preview.stage digest:CSManifestDigest(actual) error:error];
    if(!ok){preview.valid=NO;_editPreview=nil;(void)CSRemove(_profileFD,preview.stage.UTF8String,0);
        return CSFail(error,@"The staged edit failed byte-preservation, format validation or persistence.",NO);}
    active=CSDir(_profileFD,"active",NO);current=active>=0?CSManifest(active,-1,_title,_profile):nil;if(active>=0)close(active);
    if(!current||![CSManifestDigest(current) isEqual:preview.digest]){preview.valid=NO;return CSFail(error,@"The active save changed before the edit could be published.",NO);}
    NSString *backup=[self backup:error];
    if(!backup){preview.valid=NO;_editPreview=nil;(void)CSRemove(_profileFD,preview.stage.UTF8String,0);return NO;}
    active=CSDir(_profileFD,"active",NO);current=active>=0?CSManifest(active,-1,_title,_profile):nil;if(active>=0)close(active);
    if(!current||![CSManifestDigest(current) isEqual:preview.digest]) {
        preview.valid=NO;_editPreview=nil;(void)CSRemove(_profileFD,preview.stage.UTF8String,0);
        return CSFail(error,@"The active save changed during backup. The edit was not published.",NO);
    }
    preview.valid=NO;_editPreview=nil;
    return [self publishStage:preview.stage backup:backup digest:CSManifestDigest(actual) error:error];
}}
- (BOOL)importExportURL:(NSURL *)source error:(NSError **)error {@synchronized(self){
    if(![self available:error])return NO;
    if(!_externalValidator)return CSFail(error,@"No trusted save-format validator is available for this title. External replacement is unavailable.",NO);
    int input=CSOpen(source);if(input<0)return CSFail(error,@"The selected export could not be opened safely.",NO);
    NSString *stage=[@".stage-" stringByAppendingString:CSID()];
    NSString *digest=nil;BOOL ok=[self copyExport:input toStage:stage digest:&digest error:error];close(input);if(!ok)return NO;
    if(![self validateExternalStage:stage digest:digest error:error])return NO;
    NSString *backup=[self backup:error];
    if(!backup){(void)CSRemove(_profileFD,stage.UTF8String,0);return NO;}
    return [self publishStage:stage backup:backup digest:digest error:error];
}}
- (BOOL)importRawDirectoryURL:(NSURL *)source error:(NSError **)error {@synchronized(self){
    if(![self available:error])return NO;
    if(!_externalValidator)return CSFail(error,@"No trusted save-format validator is available for this title. Raw save replacement is unavailable.",NO);
    int input=CSOpen(source);if(input<0)return CSFail(error,@"The selected raw folder could not be opened safely.",NO);
    NSString *stage=[@".stage-" stringByAppendingString:CSID()],*digest=nil;
    BOOL ok=[self copyRaw:input toStage:stage digest:&digest error:error];close(input);if(!ok)return NO;
    if(![self validateExternalStage:stage digest:digest error:error])return NO;
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
    int source=CSDir(_backupsFD,identifier.UTF8String,NO);struct stat before={0},after={0};
    BOOL opened=source>=0&&!fstat(source,&before);
    NSDictionary *manifest=source<0?nil:CSReadJSON(source,"manifest.json");
    int data=source<0?-1:CSDir(source,"data",NO);
    NSDictionary *actual=data<0?nil:CSManifest(data,-1,_title,_profile);if(data>=0)close(data);
    BOOL valid=opened&&manifest&&actual&&CSExportShape(source)&&CSManifestsEqual(manifest,actual);
    NSArray *entries=valid?CSRetirementInventory(source):nil;
    valid=entries&&CSRetirementMatchesManifest(entries,actual)&&!fstat(source,&after)&&CSStable(&before,&after);
    NSString *manifestHash=nil;for(NSDictionary *row in entries)if([row[@"path"] isEqual:@"manifest.json"])manifestHash=row[@"sha256"];
    NSDictionary *record=valid&&manifestHash?@{@"schema":@"canopy-backup-retirement-v1",@"titleID":_title,@"profileID":_profile,
        @"backupID":identifier,@"device":@((uint64_t)before.st_dev),@"inode":@((uint64_t)before.st_ino),
        @"manifestSHA256":manifestHash,@"entries":entries}:nil;
    if(source>=0)close(source);
    if(!record||!CSRetirementRecord(record,_title,_profile)||!CSRetirementBytes(@{@"record":record,@"sha256":CSRetirementDigest(CSRetirementBytes(record))?:@""}))
        return CSFail(error,@"The selected backup failed complete verification. It was not moved or removed.",NO);
    int retirement=CSDir(_profileFD,".backup-retirement",YES);BOOL intent=NO,completed=NO,deleting=NO,target=NO;
    if(retirement<0||!CSRetirementShape(retirement,&intent,&completed,&deleting,&target)||intent||completed||deleting||target){
        if(retirement>=0)close(retirement);[self markBackupRecovery:YES];
        return CSFail(error,@"Backup retirement needs recovery. Existing entries were preserved.",NO);}
    [self markBackupRecovery:YES];BOOL written=CSRetirementWrite(retirement,record);close(retirement);
    if(!written)return CSFail(error,@"The backup deletion intent was not confirmed. Preserve the profile and reconcile before retrying.",YES);
    return [self recoverBackupRetirement:error];
}}
- (BOOL)recoverBackupRetirement:(NSError **)error {
    /* Called only under the process/profile lock and monitor, after any save
     * replacement recovery. A transaction's rollback backup cannot be retired. */
    if(_sessionToken||_transactionRecoveryRequired)return CSFail(error,@"Finish save transaction recovery before backup retirement.",NO);
    int retirement=CSDir(_profileFD,".backup-retirement",NO);
    if(retirement<0){if(errno==ENOENT&&!_backupRecoveryRequired){[self markBackupRecovery:NO];return YES;}
        return CSFail(error,@"Backup retirement is unavailable. Preserve the profile.",NO);}
    BOOL intent=NO,completed=NO,deleting=NO,target=NO;
    BOOL ok=CSRetirementShape(retirement,&intent,&completed,&deleting,&target);
    if(ok&&!intent&&!completed&&!deleting&&!target){
        BOOL durable=!fsync(retirement)&&!fsync(_backupsFD)&&!fsync(_profileFD);close(retirement);
        if(!durable){[self markBackupRecovery:YES];return CSFail(error,@"Backup retirement cleanup needs durable confirmation. Retry recovery.",YES);}
        [self markBackupRecovery:NO];return YES;
    }
    [self markBackupRecovery:YES];
    NSDictionary *record=ok&&(intent||completed)?CSRetirementRead(retirement,completed?"completed.json":"intent.json"):nil;
    ok=record&&CSRetirementRecord(record,_title,_profile)&&
        CSRetirementSyncFile(retirement,completed?"completed.json":"intent.json",NO)&&!fsync(retirement);
    struct stat canonical={0};BOOL present=NO;
    if(ok){int status=fstatat(_backupsFD,[record[@"backupID"] UTF8String],&canonical,AT_SYMLINK_NOFOLLOW);
        present=status==0;if(status&&errno!=ENOENT)ok=NO;}
    int root=-1;NSArray *survivors=nil;
    if(ok&&completed){
        /* Completion is durable only after the authorized tree became empty.
         * Never accept a new canonical backup or a populated retired tree. */
        ok=!present;
        if(ok&&target){root=CSDir(retirement,"retired",NO);ok=root>=0&&CSRetirementIdentity(root,record,YES)&&CSRetirementEmpty(root);}
    }else if(ok){
        if(present&&target)ok=NO;
        else if(present){
            ok=!deleting;root=ok?CSDir(_backupsFD,[record[@"backupID"] UTF8String],NO):-1;
            if(ok)ok=root>=0&&CSRetirementSubset(root,record,YES,&survivors);
            struct stat named={0};uint64_t device=0,inode=0;
            if(ok)ok=CSUInt(record[@"device"],&device)&&CSUInt(record[@"inode"],&inode)&&
                !fstatat(_backupsFD,[record[@"backupID"] UTF8String],&named,AT_SYMLINK_NOFOLLOW)&&
                (uint64_t)named.st_dev==device&&(uint64_t)named.st_ino==inode;
            if(ok)ok=!renameatx_np(_backupsFD,[record[@"backupID"] UTF8String],retirement,"retired",RENAME_EXCL)&&
                !fsync(_backupsFD)&&!fsync(retirement);
            if(ok)target=YES;
        }else if(target){root=CSDir(retirement,"retired",NO);ok=root>=0;}
        else ok=NO; // Prepared intent + both absent is ambiguous, never success.
        if(ok)ok=CSRetirementSubset(root,record,!deleting,&survivors);
        if(ok&&!deleting){int marker=openat(retirement,"deleting",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
            ok=marker>=0&&!fsync(marker);if(marker>=0&&close(marker))ok=NO;
            if(ok)ok=!fsync(retirement);}
        /* An earlier fsync failure may leave a visible but nondurable marker
         * or move in this process. Confirm both on EVERY pass before deleting. */
        if(ok)ok=CSRetirementSyncFile(retirement,"deleting",YES)&&!fsync(retirement)&&!fsync(_backupsFD)&&!fsync(_profileFD);
        if(ok)ok=CSRetirementDelete(root,survivors);
        if(ok)ok=!renameatx_np(retirement,"intent.json",retirement,"completed.json",RENAME_EXCL)&&!fsync(retirement);
        if(ok)completed=YES;
    }
    if(ok&&completed){
        if(target){struct stat named={0};uint64_t device=0,inode=0;
            ok=root>=0&&CSRetirementIdentity(root,record,YES)&&CSRetirementEmpty(root)&&
                CSUInt(record[@"device"],&device)&&CSUInt(record[@"inode"],&inode)&&
                !fstatat(retirement,"retired",&named,AT_SYMLINK_NOFOLLOW)&&
                (uint64_t)named.st_dev==device&&(uint64_t)named.st_ino==inode&&
                !unlinkat(retirement,"retired",AT_REMOVEDIR)&&!fsync(retirement);}
        if(ok&&unlinkat(retirement,"deleting",0)&&errno!=ENOENT)ok=NO;
        if(ok)ok=!fsync(retirement);
        if(ok)ok=!unlinkat(retirement,"completed.json",0)&&!fsync(retirement);
        if(ok)ok=!fsync(_backupsFD)&&!fsync(_profileFD);
    }
    if(root>=0)close(root);close(retirement);
    if(!ok)return CSFail(error,@"Backup retirement was not fully confirmed. Preserve the profile and retry recovery; unknown or changed entries are never removed.",YES);
    [self markBackupRecovery:NO];return YES;
}
- (BOOL)recover:(NSError **)error {@synchronized(self){
    if(_sessionToken)return CSFail(error,@"Recovery is unavailable while a session owns the profile.",NO);
    if(!_recoveryRequired)return YES;
    if(!_transactionRecoveryRequired)return [self recoverBackupRetirement:error];
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
        _committedIntent=journal;return [self clearCommittedIntent:error]&&[self recoverBackupRetirement:error];
    }
    int source=CSDir(_backupsFD,backup.UTF8String,NO);if(source<0)return CSFail(error,@"The rollback backup is unavailable. Preserve the profile for manual recovery.",NO);
    NSString *recovery=[@".stage-" stringByAppendingString:CSID()],*digest=nil;BOOL ok=[self copyExport:source toStage:recovery digest:&digest error:error];close(source);if(!ok)return NO;
    if(renameatx_np(_profileFD,recovery.UTF8String,_profileFD,"active",RENAME_SWAP)||fsync(_profileFD))return CSFail(error,@"Rollback was not confirmed. Preserve the profile and retry recovery.",YES);
    NSMutableDictionary *committed=[journal mutableCopy];committed[@"state"]=@"committed";committed[@"activeDigest"]=digest;
    if(!CSIntent(_profileFD,committed,YES))return CSFail(error,@"Rollback confirmation failed. Reopen and reconcile the profile.",YES);
    _committedIntent=[committed copy];return [self clearCommittedIntent:error]&&[self recoverBackupRetirement:error];
}}
@end
