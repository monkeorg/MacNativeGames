#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#import "CanopyRomFS.h"
#include "mng_romfs.h"
#include "mng_store.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static const char *RFRecipe="romfs-folders-v1";
@interface CanopyRomFS ()
- (BOOL)stopped;
- (void)report:(NSString *)phase done:(uint64_t)done total:(uint64_t)total;
@end
struct rf_context {
    __unsafe_unretained CanopyRomFS *owner;
    __unsafe_unretained NSMutableDictionary<NSString *,NSNumber *> *expected;
    int image,cache;
    uint64_t done,total,last_report;
    const char *phase;
};
static int RFStopped(void *opaque) { return [((struct rf_context *)opaque)->owner stopped]; }
static int RFStoreStopped(void *opaque) { return [(__bridge CanopyRomFS *)opaque stopped]; }
static void RFProgress(void *opaque,uint64_t done,uint64_t total) {
    struct rf_context *c=opaque;struct timespec now={0};
    BOOL clockOK=clock_gettime(CLOCK_MONOTONIC,&now)==0;
    uint64_t tick=(uint64_t)now.tv_sec*UINT64_C(1000000000)+(uint64_t)now.tv_nsec;
    if (!c->last_report || done==total || (clockOK && tick>=c->last_report && tick-c->last_report>=UINT64_C(50000000))) {
        c->last_report=clockOK ? tick:1;
        [c->owner report:[NSString stringWithUTF8String:c->phase] done:done total:total];
    }
}
static BOOL RFPrivateDirectory(int fd) {
    struct stat st;
    return fd>=0 && !fstat(fd,&st) && S_ISDIR(st.st_mode) && st.st_uid==geteuid() && !(st.st_mode&077);
}
/* Open all components without following symlinks, optionally create only the
 * final private root. The caller supplies canonical app-owned parent paths. */
static int RFRoot(NSURL *url,BOOL create) {
    const char *path=url.fileSystemRepresentation;
    if (!url.isFileURL || !path || path[0]!='/' || strnlen(path,4096)>=4096) return -1;
    char copy[4096];strcpy(copy,path);
    size_t length=strlen(copy);
    if (length>1 && copy[length-1]=='/') copy[length-1]=0; /* NSURL directory spelling */
    int fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);char *p=copy+1;
    while (fd>=0 && *p) {
        char *slash=strchr(p,'/');if (slash) *slash=0;
        if (!*p || !strcmp(p,".") || !strcmp(p,"..")) { close(fd);return -1; }
        if (!slash && create && mkdirat(fd,p,0700) && errno!=EEXIST) { close(fd);return -1; }
        int child=openat(fd,p,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);close(fd);fd=child;
        if (!slash) break;
        p=slash+1;if (!*p) { close(fd);return -1; }
    }
    if (!RFPrivateDirectory(fd)) { if (fd>=0) close(fd);return -1; }
    return fd;
}
static int RFRelative(int root,const char *path,int flags) {
    if (!path || !*path || *path=='/' || strnlen(path,4096)>=4096) return -1;
    char copy[4096];strcpy(copy,path);char *p=copy;
    int fd=openat(root,".",O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
    while (fd>=0) {
        char *slash=strchr(p,'/');if (slash) *slash=0;
        if (!*p || !strcmp(p,".") || !strcmp(p,"..")) { close(fd);return -1; }
        int child=openat(fd,p,(slash ? O_RDONLY|O_DIRECTORY:flags)|O_CLOEXEC|O_NOFOLLOW);close(fd);fd=child;
        if (!slash) break;
        p=slash+1;
    }
    return fd;
}
static BOOL RFStable(const struct stat *a,const struct stat *b) {
    return a->st_dev==b->st_dev && a->st_ino==b->st_ino && a->st_size==b->st_size &&
        a->st_mode==b->st_mode && a->st_nlink==b->st_nlink &&
        a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
}
static int RFRead(int fd,uint64_t at,void *bytes,size_t size) {
    unsigned char *p=bytes;
    while (size) {
        ssize_t n=pread(fd,p,size,(off_t)at);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) return -1;
        p+=(size_t)n;at+=(uint64_t)n;size-=(size_t)n;
    }
    return 0;
}
static int RFCanonical(void *opaque,const char *name,char *output,size_t capacity) {
    (void)opaque;
    NSString *value=[NSString stringWithUTF8String:name];
    if (!value) return -1;
    value=[[value precomposedStringWithCanonicalMapping]
        stringByFoldingWithOptions:NSCaseInsensitiveSearch locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
    NSData *bytes=[[value precomposedStringWithCanonicalMapping] dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes.length || bytes.length>=capacity) return -1;
    memcpy(output,bytes.bytes,bytes.length);output[bytes.length]=0;return 0;
}
static int RFDirectory(void *opaque,const char *path) {
    struct rf_context *c=opaque;
    if (RFStopped(c)) return -1;
    NSString *key=[[NSString stringWithUTF8String:path] precomposedStringWithCanonicalMapping];if (!key || c->expected[key]) return -1;
    if (c->cache>=0) {
        int fd=RFRelative(c->cache,path,O_RDONLY|O_DIRECTORY);
        BOOL valid=RFPrivateDirectory(fd);if (fd>=0) close(fd);if (!valid) return -1;
    }
    c->expected[key]=@(UINT64_MAX);return 0;
}
static int RFEntry(void *opaque,const char *path,uint64_t offset,uint64_t size) {
    struct rf_context *c=opaque;
    if (RFStopped(c)) return -1;
    NSString *key=[[NSString stringWithUTF8String:path] precomposedStringWithCanonicalMapping];if (!key || c->expected[key]) return -1;
    c->expected[key]=@(size);
    if (c->cache<0) return 0;
    int fd=RFRelative(c->cache,path,O_RDONLY|O_NONBLOCK);if (fd<0) return -1;
    struct stat before,after;int result=-1;
    if (fstat(fd,&before) || !S_ISREG(before.st_mode) || before.st_nlink!=1 || before.st_uid!=geteuid() ||
        (before.st_mode&077) || before.st_size<0 || (uint64_t)before.st_size!=size) goto done;
    unsigned char original[65536],actual[65536];
    for (uint64_t at=0;at<size;) {
        if (RFStopped(c)) goto done;
        size_t n=size-at>sizeof(original) ? sizeof(original):(size_t)(size-at);
        if (RFRead(c->image,offset+at,original,n) || RFRead(fd,at,actual,n) || memcmp(original,actual,n)) goto done;
        at+=n;c->done+=n;RFProgress(c,c->done,c->total);
    }
    if (fstat(fd,&after) || !RFStable(&before,&after)) goto done;
    result=0;
done:
    close(fd);return result;
}
/* Tree validation uses the native index's complete file+directory callback
 * set, including empty directories. It never interprets RomFS metadata again. */
static int RFTree(int directory,NSString *prefix,NSDictionary<NSString *,NSNumber *> *expected,
    NSUInteger *count,unsigned depth,BOOL sync,struct rf_context *context) {
    if (depth>64 || RFStopped(context)) return -1;
    int scan=openat(directory,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (scan<0) return -1;
    DIR *iterator=fdopendir(scan);if (!iterator) { close(scan);return -1; }
    int result=0;struct dirent *entry;errno=0;
    while ((entry=readdir(iterator))!=NULL) {
        if (!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")) continue;
        if (RFStopped(context) || ++*count>81920) { result=-1;break; }
        NSString *name=[NSString stringWithUTF8String:entry->d_name];
        NSString *path=prefix.length ? [prefix stringByAppendingFormat:@"/%@",name]:name;
        NSNumber *value=name ? expected[[path precomposedStringWithCanonicalMapping]]:nil;struct stat st;
        if (!value || fstatat(directory,entry->d_name,&st,AT_SYMLINK_NOFOLLOW) || st.st_uid!=geteuid() || (st.st_mode&077)) { result=-1;break; }
        if (value.unsignedLongLongValue==UINT64_MAX) {
            int child=openat(directory,entry->d_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            if (!S_ISDIR(st.st_mode) || child<0) { if (child>=0)close(child);result=-1;break; }
            result=RFTree(child,path,expected,count,depth+1,sync,context);close(child);if (result)break;
        } else if (!S_ISREG(st.st_mode) || st.st_nlink!=1 || st.st_size<0 || (uint64_t)st.st_size!=value.unsignedLongLongValue) { result=-1;break; }
        errno=0;
    }
    if (!entry && errno) result=-1;
    closedir(iterator);
    if (!result && sync && fsync(directory)) result=-1;
    return result;
}
/* Cleanup is confined to the exclusive random staging directory created by
 * this operation. Existing published caches are never recursively removed. */
static int RFRemoveStaging(int directory,unsigned depth,NSUInteger *count) {
    if (depth>64) return -1;
    int scan=openat(directory,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (scan<0) return -1;
    DIR *iterator=fdopendir(scan);if (!iterator) { close(scan);return -1; }
    struct dirent *entry;int result=0;errno=0;
    while ((entry=readdir(iterator))!=NULL) {
        if (!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")) continue;
        struct stat st;if (++*count>81920 || fstatat(directory,entry->d_name,&st,AT_SYMLINK_NOFOLLOW)) { result=-1;break; }
        if (S_ISDIR(st.st_mode)) {
            int child=openat(directory,entry->d_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            if (child<0) { result=-1;break; }
            result=RFRemoveStaging(child,depth+1,count);close(child);
            if (!result) result=unlinkat(directory,entry->d_name,AT_REMOVEDIR);
        } else result=unlinkat(directory,entry->d_name,0);
        if (result)break;
        errno=0;
    }
    if (!entry && errno) result=-1;
    closedir(iterator);return result;
}
static NSError *RFError(NSInteger code,BOOL published) {
    NSString *message=code==MNG_ROMFS_CANCELLED ? @"Folder preparation was cancelled. It can be retried safely.":
        published ? @"The verified folder may have been published, but filesystem confirmation failed. Retry to verify its state.":
        @"The private generation or derived folder could not be verified safely. Existing folders were preserved.";
    return [NSError errorWithDomain:@"CanopyRomFS" code:code userInfo:@{NSLocalizedDescriptionKey:message,
        @"publishedFolderMayExist":@(published)}];
}

@implementation CanopyRomFS {
    NSURL *_prepared,*_derived;
    dispatch_queue_t _queue;
    _Atomic int _cancelled;
    BOOL _busy;
}
- (instancetype)initWithPreparedRootURL:(NSURL *)prepared derivedRootURL:(NSURL *)derived {
    if ((self=[super init])) { _prepared=[prepared copy];_derived=[derived copy];
        _queue=dispatch_queue_create("org.monkeorg.canopy.romfs",DISPATCH_QUEUE_SERIAL);atomic_init(&_cancelled,0); }
    return self;
}
- (BOOL)busy { return _busy; }
- (BOOL)stopped { return atomic_load(&_cancelled)==1; }
- (void)cancel {
    NSAssert(NSThread.isMainThread,@"CanopyRomFS main-thread owner");
    if (_busy) { int active=0;(void)atomic_compare_exchange_strong(&_cancelled,&active,1); }
}
- (void)report:(NSString *)phase done:(uint64_t)done total:(uint64_t)total {
    dispatch_sync(dispatch_get_main_queue(),^{ if (self->_busy && self.progress)self.progress(phase,done,total); });
}
- (BOOL)materializeTitleID:(uint64_t)title generationID:(NSString *)generation completion:(void (^)(NSURL * _Nullable,NSError * _Nullable))completion {
    NSAssert(NSThread.isMainThread,@"CanopyRomFS main-thread owner");
    NSCharacterSet *bad=[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    if (_busy || !title || !completion || generation.length!=64 || [generation rangeOfCharacterFromSet:bad].location!=NSNotFound) return NO;
    _busy=YES;atomic_store(&_cancelled,0);
    NSString *identity=[generation copy];
    dispatch_async(_queue,^{ @autoreleasepool {
        int prepared=-1,derived=-1,lock=-1,lease=-1,image=-1,folder=-1,stage=-1;
        struct mng_store *store=NULL;enum mng_romfs_status status=MNG_ROMFS_IO;
        BOOL published=NO;char final[128]={0},staging[64]={0};NSURL *result=nil;
        NSString *uuid=nil;
        NSMutableDictionary<NSString *,NSNumber *> *expected=[NSMutableDictionary new];
        struct rf_context context={self,expected,-1,-1,0,0,0,"materialize-private-folder"};
        prepared=RFRoot(self->_prepared,NO);derived=RFRoot(self->_derived,YES);
        if (prepared<0 || derived<0) goto finish;
        lock=openat(derived,".romfs.lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK,0600);
        struct stat lock_stat;
        if (lock<0 || fstat(lock,&lock_stat) || !S_ISREG(lock_stat.st_mode) || lock_stat.st_nlink!=1 ||
            lock_stat.st_uid!=geteuid() || (lock_stat.st_mode&077) || flock(lock,LOCK_EX|LOCK_NB)) goto finish;
        [self report:@"verify-prepared-generation" done:0 total:0];
        if ([self stopped]) { status=MNG_ROMFS_CANCELLED;goto finish; }
        if (mng_store_open(prepared,&store)!=MNG_PREPARE_OK) goto finish;
        mng_store_set_cancel_check(store,RFStoreStopped,(__bridge void *)self);
        enum mng_prepare_status pinned=mng_store_pin(store,title,identity.UTF8String,&lease);
        if (pinned!=MNG_PREPARE_OK) { status=pinned==MNG_PREPARE_CANCELLED ? MNG_ROMFS_CANCELLED:MNG_ROMFS_INVALID;goto finish; }
        mng_store_close(store);store=NULL;
        char relative[160];snprintf(relative,sizeof(relative),"titles/%016llx/generations/%s/romfs.bin",(unsigned long long)title,identity.UTF8String);
        image=RFRelative(prepared,relative,O_RDONLY|O_NONBLOCK);
        struct stat source_stat;if (image<0 || fstat(image,&source_stat) || !S_ISREG(source_stat.st_mode)) goto finish;
        context.image=image;context.total=(uint64_t)source_stat.st_size;
        snprintf(final,sizeof(final),"%s-%016llx-%s",RFRecipe,(unsigned long long)title,identity.UTF8String);
        struct mng_romfs_callbacks callbacks={&context,RFEntry,RFStopped,RFProgress,RFCanonical,RFDirectory};
        folder=openat(derived,final,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if (folder>=0) {
            if (!RFPrivateDirectory(folder)) goto finish;
            context.cache=folder;context.phase="verify-private-folder";
            RFProgress(&context,0,context.total);
            struct mng_romfs_result indexed={0};status=mng_romfs_index_fd(image,&callbacks,&indexed);
            if (status!=MNG_ROMFS_OK) goto finish;
            NSUInteger count=0;
            if (RFTree(folder,@"",expected,&count,0,NO,&context) || count!=expected.count) { status=MNG_ROMFS_INVALID;goto finish; }
            if ([self stopped]) { status=MNG_ROMFS_CANCELLED;goto finish; }
            RFProgress(&context,indexed.bytes,indexed.bytes);
            result=[self->_derived URLByAppendingPathComponent:[NSString stringWithUTF8String:final] isDirectory:YES];
            goto finish;
        }
        if (errno!=ENOENT) goto finish;
        uuid=[[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
        snprintf(staging,sizeof(staging),".romfs-stage-%s",uuid.UTF8String);
        if (mkdirat(derived,staging,0700)) { staging[0]=0;goto finish; }
        stage=openat(derived,staging,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if (stage<0) goto finish;
        struct mng_romfs_result extracted={0};status=mng_romfs_extract_fd(image,stage,&callbacks,&extracted);
        if (status!=MNG_ROMFS_OK) goto finish;
        NSUInteger count=0;
        if (RFTree(stage,@"",expected,&count,0,YES,&context) || count!=expected.count) { status=MNG_ROMFS_IO;goto finish; }
        [self report:@"publish-private-folder" done:extracted.bytes total:extracted.bytes];
        int active=0;
        if (!atomic_compare_exchange_strong(&self->_cancelled,&active,2)) { status=MNG_ROMFS_CANCELLED;goto finish; }
        if (renameatx_np(derived,staging,derived,final,RENAME_EXCL)) { status=MNG_ROMFS_IO;goto finish; }
        staging[0]=0;published=YES;
        if (fsync(derived)) { status=MNG_ROMFS_IO;goto finish; }
        result=[self->_derived URLByAppendingPathComponent:[NSString stringWithUTF8String:final] isDirectory:YES];
    finish:
        if (stage>=0 && staging[0]) { NSUInteger count=0;(void)RFRemoveStaging(stage,0,&count); }
        if (stage>=0)close(stage);
        if (staging[0] && derived>=0)(void)unlinkat(derived,staging,AT_REMOVEDIR);
        if (folder>=0)close(folder);if (image>=0)close(image);if (lease>=0)close(lease);
        mng_store_close(store);if (lock>=0)close(lock);if (derived>=0)close(derived);if (prepared>=0)close(prepared);
        if (!result && [self stopped] && !published) status=MNG_ROMFS_CANCELLED;
        NSError *error=result ? nil:RFError(status,published);
        dispatch_async(dispatch_get_main_queue(),^{ self->_busy=NO;completion(result,error); });
    }});
    return YES;
}
@end
