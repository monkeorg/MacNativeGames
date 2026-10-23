#import "save_store.h"
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>

static BOOL failure(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"TOTKSaveStore" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}

/* Open the selected directory without requiring read access to its sandboxed ancestors. */
static int openDirectory(NSURL *url) {
    if (!url.isFileURL) { errno = EINVAL; return -1; }
    NSString *path = url.path;
    // Darwin exposes these system aliases. Do not resolve links inside the selected save tree.
    for (NSString *alias in @[@"/var",@"/tmp"]) {
        if ([path isEqual:alias] || [path hasPrefix:[alias stringByAppendingString:@"/"]]) {
            path = [@"/private" stringByAppendingString:path]; break;
        }
    }
    for (NSString *part in path.pathComponents) {
        if ([part isEqual:@".."] || [part isEqual:@"."]) { errno = EINVAL; return -1; }
    }
    return open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY);
}

typedef struct { uint64_t bytes; unsigned entries; } CopyBudget;
static BOOL copyDirectory(int source, int dest, unsigned depth, CopyBudget *budget, NSError **error) {
    if (depth > 12) return failure(error, @"The save has too many nested folders.");
    DIR *dir = fdopendir(dup(source));
    if (!dir) return failure(error, @"Cannot read the save folder.");
    BOOL ok = YES;
    struct dirent *entry;
    errno = 0;
    while ((entry = readdir(dir))) {
        const char *name = entry->d_name;
        if (!strcmp(name,".") || !strcmp(name,"..")) continue;
        if (++budget->entries > 10000) { ok = failure(error, @"The save contains too many files."); break; }
        struct stat st, opened;
        if (fstatat(source,name,&st,AT_SYMLINK_NOFOLLOW) ||
            (!S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode)) || (S_ISREG(st.st_mode) && st.st_nlink != 1)) {
            ok = failure(error, @"Only regular files and folders are allowed. Links are refused."); break;
        }
        int input = openat(source,name,O_RDONLY | O_NOFOLLOW | (S_ISDIR(st.st_mode)?O_DIRECTORY:O_NONBLOCK));
        if (input < 0 || fstat(input,&opened) || opened.st_dev != st.st_dev || opened.st_ino != st.st_ino ||
            (opened.st_mode & S_IFMT) != (st.st_mode & S_IFMT) || opened.st_nlink != st.st_nlink) {
            if (input >= 0) close(input);
            ok = failure(error, @"The selected save changed during the transfer."); break;
        }
        if (S_ISDIR(st.st_mode)) {
            int output = -1;
            if (!mkdirat(dest,name,0700)) output = openat(dest,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
            ok = output >= 0 && copyDirectory(input,output,depth+1,budget,error);
            if (output >= 0) { if (ok && fsync(output)) ok = NO; close(output); }
        } else {
            if (st.st_size < 0 || st.st_size > 64*1024*1024 ||
                (budget->bytes += (uint64_t)st.st_size) > 512*1024*1024) {
                close(input); ok = failure(error, @"The save exceeds the transfer size limit."); break;
            }
            int output = openat(dest,name,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,0600);
            ok = output >= 0;
            char buffer[65536]; ssize_t count; uint64_t copied = 0;
            while (ok && (count = read(input,buffer,sizeof buffer)) != 0) {
                if (count < 0) { if (errno == EINTR) continue; ok = NO; break; }
                copied += count;
                if (copied > (uint64_t)st.st_size) { ok = NO; break; }
                ssize_t offset = 0;
                while (offset < count) {
                    ssize_t written = write(output,buffer+offset,(size_t)(count-offset));
                    if (written < 0 && errno == EINTR) continue;
                    if (written <= 0) { ok = NO; break; }
                    offset += written;
                }
            }
            if (output >= 0) { if (fsync(output)) ok = NO; close(output); }
            if (copied != (uint64_t)st.st_size || fstat(input,&opened) || opened.st_size != st.st_size ||
                opened.st_mtimespec.tv_sec != st.st_mtimespec.tv_sec || opened.st_mtimespec.tv_nsec != st.st_mtimespec.tv_nsec) ok = NO;
        }
        close(input);
        if (!ok) { if (!error || !*error) failure(error, @"The save could not be copied completely."); break; }
        errno = 0;
    }
    if (!entry && errno) ok = failure(error, @"The save folder could not be read completely.");
    closedir(dir);
    return ok;
}

static BOOL copyTree(NSURL *source, NSURL *target, NSError **error) {
    int input = openDirectory(source);
    if (input < 0) return failure(error, @"Cannot open the save folder. Download it in Files and select it again.");
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtURL:target withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:error]) {
        close(input); return NO;
    }
    int output = openDirectory(target);
    CopyBudget budget = {0};
    BOOL ok = output >= 0 && copyDirectory(input,output,0,&budget,error);
    if (output >= 0) { if (ok && fsync(output)) ok = failure(error,@"Cannot finish the save copy."); close(output); }
    close(input);
    if (!ok) [fm removeItemAtURL:target error:nil];
    return ok;
}

static BOOL validate(NSURL *root, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *names = [fm contentsOfDirectoryAtPath:root.path error:error];
    if (!names) return NO;
    unsigned slots = 0;
    for (NSString *name in names) {
        if (![name hasPrefix:@"slot_"]) continue;
        if (name.length != 7 || [name characterAtIndex:5] != '0' || [name characterAtIndex:6] < '0' || [name characterAtIndex:6] > '5')
            return failure(error,@"The folder contains an unsupported save slot.");
        for (NSString *required in @[@"progress.sav",@"caption.sav",@"footprint.sav",@"direct_file_save_related.sav"]) {
            NSURL *file = [[root URLByAppendingPathComponent:name] URLByAppendingPathComponent:required];
            NSDictionary *attrs = [fm attributesOfItemAtPath:file.path error:error];
            if (![attrs[NSFileType] isEqual:NSFileTypeRegular] || ![attrs[NSFileSize] unsignedLongLongValue])
                return failure(error,@"Each slot needs progress.sav, caption.sav, footprint.sav, and direct_file_save_related.sav.");
        }
        slots++;
    }
    if (!slots) return failure(error,@"Select the save folder containing slot_00 through slot_05, not one slot or a profile folder.");
    if ([names containsObject:@"account.uid"]) return failure(error,@"Import the console save contents, not the account profile.");
    return YES;
}

@implementation TOTKSaveStore {
    NSURL *_active, *_backups;
    BOOL _sealed;
}
- (instancetype)initWithActiveURL:(NSURL *)active backupsURL:(NSURL *)backups {
    if ((self = [super init])) { _active = active; _backups = backups; }
    return self;
}
- (BOOL)available:(NSError **)error {
    return !_sealed || failure(error,@"Close and reopen TOTK before save transfers. The game has already started.");
}
- (BOOL)sealForPlay { @synchronized(self) { if (_sealed) return NO; _sealed = YES; return YES; } }
- (NSURL *)newBackup:(NSError **)error {
    if (![NSFileManager.defaultManager createDirectoryAtURL:_backups withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return nil;
    NSString *name = [NSString stringWithFormat:@"Save-%.0f-%@",NSDate.date.timeIntervalSince1970,NSUUID.UUID.UUIDString];
    NSURL *dest = [_backups URLByAppendingPathComponent:name isDirectory:YES];
    return copyTree(_active,dest,error) ? dest : nil;
}
- (NSURL *)backup:(NSError **)error { @synchronized(self) {
    if (![self available:error] || !validate(_active,error)) return nil;
    return [self newBackup:error];
} }
- (NSArray<NSURL *> *)backups:(NSError **)error { @synchronized(self) {
    if (![self available:error]) return nil;
    if (![NSFileManager.defaultManager fileExistsAtPath:_backups.path]) return @[];
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtURL:_backups includingPropertiesForKeys:nil options:0 error:error];
    return [names sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [b.lastPathComponent compare:a.lastPathComponent]; }];
} }
- (NSURL *)exportToDirectory:(NSURL *)directory error:(NSError **)error { @synchronized(self) {
    if (![self available:error] || !validate(_active,error)) return nil;
    NSURL *dest = [directory URLByAppendingPathComponent:@"TOTK Save" isDirectory:YES];
    return copyTree(_active,dest,error) ? dest : nil;
} }
- (BOOL)importDirectory:(NSURL *)source error:(NSError **)error { @synchronized(self) {
    if (![self available:error]) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *parent = [_active URLByDeletingLastPathComponent];
    if (![fm createDirectoryAtURL:parent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
    NSURL *stage = [parent URLByAppendingPathComponent:[@".import-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    BOOL ok = copyTree(source,stage,error);
    if (ok) ok = validate(stage,error);
    BOOL exists = [fm fileExistsAtPath:_active.path];
    if (ok && exists) ok = [self newBackup:error] != nil;
    if (ok) {
        /* Same-volume exchange has no missing-directory window; a failed exchange leaves the original untouched. */
        int result = exists ? renameatx_np(AT_FDCWD,stage.fileSystemRepresentation,AT_FDCWD,_active.fileSystemRepresentation,RENAME_SWAP)
                            : rename(stage.fileSystemRepresentation,_active.fileSystemRepresentation);
        if (result) ok = failure(error,@"Cannot publish the save. Your previous save is unchanged.");
        else { int fd = openDirectory(parent); if (fd >= 0) { fsync(fd); close(fd); } }
    }
    [fm removeItemAtURL:stage error:nil];
    return ok;
} }
- (BOOL)restore:(NSURL *)backup error:(NSError **)error { @synchronized(self) {
    if (![self available:error]) return NO;
    if (![[backup URLByDeletingLastPathComponent].URLByStandardizingPath.path isEqual:_backups.URLByStandardizingPath.path])
        return failure(error,@"Select one of this app's save backups.");
    return [self importDirectory:backup error:error];
} }
@end
