#import "CanopyPreparation.h"
#include "mng_prepare.h"
#include "mng_store.h"
#include "mng_crypto.h"
#include "mng_keys.h"
#include <stdatomic.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

@interface CanopyPreparation ()
- (BOOL)cancellationRequested;
- (void)reportPhase:(NSString *)phase done:(uint64_t)done total:(uint64_t)total epoch:(NSUInteger)epoch;
@end

struct preparation_context {
    __unsafe_unretained CanopyPreparation *owner;
    struct mng_store *store;
    struct mng_asset_sink sink;
    NSUInteger epoch;
    uint64_t last_report;
    char last_phase[64];
};
static int CPStoreStopped(void *opaque) {
    CanopyPreparation *owner = (__bridge CanopyPreparation *)opaque;
    return [owner cancellationRequested] ? 1 : 0;
}
static int CPStopped(void *opaque) {
    struct preparation_context *c = opaque;
    if ([c->owner cancellationRequested]) mng_store_cancel(c->store);
    return [c->owner cancellationRequested] || (c->sink.cancelled && c->sink.cancelled(c->sink.context));
}
static int CPBegin(void *opaque, const char *path, uint64_t size) {
    struct preparation_context *c = opaque;
    return CPStopped(c) ? -1 : c->sink.begin(c->sink.context, path, size);
}
static int CPWrite(void *opaque, const void *bytes, size_t size) {
    struct preparation_context *c = opaque;
    return CPStopped(c) ? -1 : c->sink.write(c->sink.context, bytes, size);
}
static int CPEnd(void *opaque, const unsigned char digest[32]) {
    struct preparation_context *c = opaque;
    return CPStopped(c) ? -1 : c->sink.end(c->sink.context, digest);
}
static void CPProgress(void *opaque, const char *phase, uint64_t done, uint64_t total) {
    struct preparation_context *c = opaque;
    struct timespec now = {0};
    clock_gettime(CLOCK_MONOTONIC, &now);
    uint64_t time = (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
    BOOL changed = strcmp(c->last_phase, phase) != 0;
    if (changed || done == total || time - c->last_report >= UINT64_C(50000000)) {
        snprintf(c->last_phase, sizeof(c->last_phase), "%s", phase);
        c->last_report = time;
        NSString *label = [NSString stringWithUTF8String:phase] ?: @"preparing";
        // Phase boundaries synchronously acknowledge cancellation from the UI.
        // Ordinary progress is throttled, avoiding a main-queue task per chunk.
        [c->owner reportPhase:label done:done total:total epoch:c->epoch];
    }
    (void)CPStopped(c);
}
static BOOL CPStable(const struct stat *a, const struct stat *b) {
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino && a->st_size == b->st_size &&
        a->st_mode == b->st_mode && a->st_nlink == b->st_nlink &&
        a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec == b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec == b->st_ctimespec.tv_nsec;
}
static NSString *CPHex(const unsigned char *bytes, size_t count) {
    static const char digits[] = "0123456789abcdef";
    char output[65];
    if (count > 32) return @"";
    for (size_t i = 0; i < count; ++i) { output[2*i] = digits[bytes[i] >> 4]; output[2*i+1] = digits[bytes[i] & 15]; }
    output[2*count] = 0;
    return [NSString stringWithUTF8String:output];
}
static BOOL CPJobID(NSString *identifier) {
    if (identifier.length != 32) return NO;
    return [identifier rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}
static NSError *CPError(enum mng_prepare_status status, BOOL published) {
    NSString *message;
    switch (status) {
        case MNG_PREPARE_CANCELLED: message = @"Preparation was cancelled. Unpublished verified work is retained for an explicit resume."; break;
        case MNG_PREPARE_KEY: message = @"The selected keys are missing, malformed or do not match this supported input."; break;
        case MNG_PREPARE_INTEGRITY: message = @"The input or staged assets failed an integrity check. No unverified generation is activated."; break;
        case MNG_PREPARE_UNSUPPORTED: message = @"This container uses a format or update layout that preparation does not yet support."; break;
        case MNG_PREPARE_LIMIT: message = @"The input exceeds preparation limits or available private storage."; break;
        case MNG_PREPARE_NOMEM: message = @"There is not enough memory to prepare this input."; break;
        case MNG_PREPARE_INVALID: message = @"The input or preparation metadata is invalid."; break;
        default: message = published ? @"A verified generation may have been published, but final filesystem confirmation failed. Reopen the library and verify its state before retrying." : @"Preparation could not read or safely publish the private assets. Check local availability and storage, then retry or resume.";
    }
    return [NSError errorWithDomain:@"CanopyPreparation" code:status userInfo:@{NSLocalizedDescriptionKey:message, @"publishedGenerationMayExist":@(published)}];
}

@implementation CanopyPreparation {
    NSURL *_directory;
    dispatch_queue_t _queue;
    NSLock *_lock;
    NSFileCoordinator *_coordinator;
    struct mng_store *_nativeStore;
    _Atomic int _cancelled;
    BOOL _busy;
    NSUInteger _epoch;
    NSString *_jobIdentifier;
}
- (instancetype)initWithPreparedRootURL:(NSURL *)directory {
    if ((self = [super init])) {
        _directory = [directory copy]; _lock = [NSLock new];
        _queue = dispatch_queue_create("org.monkeorg.canopy.preparation", DISPATCH_QUEUE_SERIAL);
        atomic_init(&_cancelled, 0);
    }
    return self;
}
- (BOOL)busy { return _busy; }
- (NSString *)jobIdentifier { return _jobIdentifier; }
- (BOOL)cancellationRequested { return atomic_load(&_cancelled) != 0; }
- (void)cancel {
    NSAssert(NSThread.isMainThread, @"Canopy preparation is owned by the main thread");
    if (!_busy) return;
    atomic_store(&_cancelled, 1);
    [_lock lock];
    if (_nativeStore) mng_store_cancel(_nativeStore);
    NSFileCoordinator *coordinator = _coordinator;
    [_lock unlock];
    [coordinator cancel];
}
- (void)useCoordinator:(NSFileCoordinator *)coordinator {
    [_lock lock]; _coordinator = coordinator; [_lock unlock];
}
- (void)reportPhase:(NSString *)phase done:(uint64_t)done total:(uint64_t)total epoch:(NSUInteger)epoch {
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (self->_busy && self->_epoch == epoch && self.progress) self.progress(phase, done, total);
    });
}
- (struct mng_keys *)readKeys:(NSURL *)url status:(enum mng_prepare_status *)status {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    __block struct mng_keys *keys = NULL;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [self useCoordinator:coordinator];
    NSError *error = nil;
    if (![self cancellationRequested]) [coordinator coordinateReadingItemAtURL:url options:0 error:&error byAccessor:^(NSURL *readURL) {
        int fd = open(readURL.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
        struct stat before, after;
        unsigned char *bytes = NULL, extra = 0; size_t used = 0, size = 0;
        if (fd < 0 || fstat(fd, &before) || !S_ISREG(before.st_mode) || before.st_size < 1 || before.st_size > 1048576) goto done;
        size = (size_t)before.st_size; bytes = malloc(size);
        if (!bytes) { *status = MNG_PREPARE_NOMEM; goto done; }
        while (used < size) {
            ssize_t n = read(fd, bytes + used, size - used);
            if (n < 0 && errno == EINTR && ![self cancellationRequested]) continue;
            if (n <= 0 || [self cancellationRequested]) goto done;
            used += (size_t)n;
        }
        if (read(fd, &extra, 1) != 0 || fstat(fd, &after) || !CPStable(&before, &after)) goto done;
        if (mng_keys_parse(bytes, size, &keys)) *status = MNG_PREPARE_KEY;
        else *status = MNG_PREPARE_OK;
    done:
        if (bytes) { mng_secure_clear(bytes, size); free(bytes); }
        mng_secure_clear(&extra, sizeof(extra));
        if (fd >= 0) close(fd);
    }];
    [self useCoordinator:nil];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (error || [self cancellationRequested]) { mng_keys_free(keys); keys = NULL; *status = [self cancellationRequested] ? MNG_PREPARE_CANCELLED : MNG_PREPARE_IO; }
    return keys;
}
- (BOOL)startSourceURL:(NSURL *)source keysURL:(NSURL *)keysURL jobIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary<NSString *, id> * _Nullable, NSError * _Nullable))completion {
    NSAssert(NSThread.isMainThread, @"Canopy preparation is owned by the main thread");
    if (_busy || !source.isFileURL || !keysURL.isFileURL || !completion || (identifier && !CPJobID(identifier))) return NO;
    _busy = YES; ++_epoch; NSUInteger epoch = _epoch;
    _jobIdentifier = identifier ?: [[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
    NSString *job = [_jobIdentifier copy];
    atomic_store(&_cancelled, 0);
    dispatch_async(_queue, ^{
        @autoreleasepool {
            enum mng_prepare_status status = MNG_PREPARE_KEY;
            struct mng_keys *keys = [self readKeys:keysURL status:&status];
            __block struct mng_prepare_result prepared = {0};
            __block struct mng_store *store = NULL;
            char generation[65] = {0};
            BOOL published = NO;
            BOOL commitAttempted = NO;
            __block enum mng_prepare_status operation = status;
            if (keys && ![self cancellationRequested]) {
                NSError *directoryError = nil;
                if (![NSFileManager.defaultManager createDirectoryAtURL:self->_directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&directoryError]) operation = MNG_PREPARE_IO;
                else {
                    int root = open(self->_directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                    struct stat rootInfo;
                    if (root < 0 || fstat(root, &rootInfo) || !S_ISDIR(rootInfo.st_mode) ||
                        rootInfo.st_uid != geteuid() || (rootInfo.st_mode & 077)) operation = MNG_PREPARE_IO;
                    else operation = mng_store_open(root, &store);
                    if (root >= 0) close(root);
                }
                if (operation == MNG_PREPARE_OK) {
                    [self->_lock lock]; self->_nativeStore = store; [self->_lock unlock];
                    mng_store_set_cancel_check(store, CPStoreStopped, (__bridge void *)self);
                    if ([self cancellationRequested]) mng_store_cancel(store);
                    operation = mng_store_begin(store, job.UTF8String);
                }
                if (operation == MNG_PREPARE_OK) {
                    BOOL scoped = [source startAccessingSecurityScopedResource];
                    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
                    [self useCoordinator:coordinator]; NSError *coordinationError = nil;
                    if (![self cancellationRequested]) [coordinator coordinateReadingItemAtURL:source options:0 error:&coordinationError byAccessor:^(NSURL *readURL) {
                        int fd = open(readURL.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
                        if (fd < 0) { operation = MNG_PREPARE_IO; return; }
                        struct preparation_context context = { self, store, mng_store_sink(store), epoch, 0, {0} };
                        struct mng_asset_sink sink = { &context, CPBegin, CPWrite, CPEnd, CPStopped, CPProgress };
                        struct mng_key_provider provider = mng_keys_provider(keys);
                        operation = mng_prepare_fd(fd, &provider, &sink, &prepared);
                        close(fd);
                    }];
                    if (scoped) [source stopAccessingSecurityScopedResource];
                    [self useCoordinator:nil];
                    if (coordinationError) operation = MNG_PREPARE_IO;
                    if ([self cancellationRequested]) operation = MNG_PREPARE_CANCELLED;
                    if (operation == MNG_PREPARE_OK) {
                        [self reportPhase:@"verify-and-publish" done:0 total:0 epoch:epoch];
                        commitAttempted = YES;
                        operation = mng_store_commit(store, &prepared, generation);
                        if (operation != MNG_PREPARE_OK && prepared.title_id) {
                            char current[65]; struct mng_prepare_result actual = {0};
                            // Rename can succeed before the final fsync fails. Report the
                            // authoritative verified current rather than promising rollback.
                            if (mng_store_current(store, prepared.title_id, current) == MNG_PREPARE_OK &&
                                mng_store_verify(store, prepared.title_id, current, &actual) == MNG_PREPARE_OK &&
                                !memcmp(actual.source_sha256, prepared.source_sha256, 32)) published = YES;
                        }
                    }
                }
            }
            if (!commitAttempted && operation != MNG_PREPARE_OK && [self cancellationRequested]) operation = MNG_PREPARE_CANCELLED;
            [self->_lock lock]; self->_nativeStore = NULL; self->_coordinator = nil; [self->_lock unlock];
            mng_keys_free(keys); mng_store_close(store);
            NSDictionary *result = operation == MNG_PREPARE_OK ? @{
                @"titleID":[NSString stringWithFormat:@"%016llx", (unsigned long long)prepared.title_id],
                @"applicationID":[NSString stringWithFormat:@"%016llx", (unsigned long long)prepared.application_id],
                @"titleVersion":@(prepared.title_version), @"versionIdentified":@(prepared.version_identified != 0),
                @"contentRole":@(prepared.content_role),
                @"generationID":[NSString stringWithUTF8String:generation], @"jobID":job,
                @"sourceSHA256":CPHex(prepared.source_sha256, 32), @"assetCount":@(prepared.asset_count), @"assetBytes":@(prepared.asset_bytes),
                @"exefsVerified":@(prepared.exefs_verified != 0), @"romfsVerified":@(prepared.romfs_verified != 0),
                @"signatureVerified":@NO, @"executionVerified":@NO } : nil;
            NSError *error = operation == MNG_PREPARE_OK ? nil : CPError(operation, published || (commitAttempted && operation == MNG_PREPARE_IO));
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self->_epoch != epoch) return;
                self->_busy = NO; completion(result, error);
            });
        }
    });
    return YES;
}
@end
