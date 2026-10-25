#import "CanopyCatalog.h"
#include "mng_store.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static BOOL CatalogError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"CanopyCatalog" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static NSString *HexDigest(const unsigned char bytes[32]) {
    char text[65];
    for (unsigned i = 0; i < 32; ++i) snprintf(text + 2 * i, 3, "%02x", bytes[i]);
    text[64] = 0; return [NSString stringWithUTF8String:text];
}
@implementation CanopyCatalog {
    NSURL *_root;
    CanopySettings *_settings;
    NSArray *_entries;
    NSArray *_issues;
}
- (instancetype)initWithPreparedRootURL:(NSURL *)root settings:(CanopySettings *)settings {
    if ((self = [super init])) { _root = [root copy]; _settings = settings; _entries = @[]; _issues = @[]; }
    return self;
}
- (NSArray *)entries { return _entries; }
- (NSArray *)issues { return _issues; }
- (BOOL)reload:(NSError **)error {
    int root = open(_root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0 && errno == ENOENT) { _entries = @[]; _issues = @[]; return YES; }
    if (root < 0) return CatalogError(error, @"The prepared library directory is unavailable or is a link.");
    struct mng_store *store = NULL;
    enum mng_prepare_status status = mng_store_open(root, &store);
    if (status != MNG_PREPARE_OK) { close(root); return CatalogError(error, @"The preparation store is busy or unavailable. Retry after the current job finishes."); }
    int titles = openat(root, "titles", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (titles < 0) {
        int saved = errno; mng_store_close(store); close(root);
        if (saved == ENOENT) { _entries = @[]; _issues = @[]; return YES; }
        return CatalogError(error, @"The title directory is unavailable or is a link.");
    }
    DIR *directory = fdopendir(titles);
    if (!directory) { close(titles); mng_store_close(store); close(root); return CatalogError(error, @"The prepared library could not be enumerated."); }
    NSMutableArray *entries = [NSMutableArray array], *issues = [NSMutableArray array];
    NSUInteger scanned = 0;
    BOOL okay = YES;
    for (;;) {
        errno = 0;
        struct dirent *item = readdir(directory);
        if (!item) { if (errno) okay = NO; break; }
        if (!strcmp(item->d_name, ".") || !strcmp(item->d_name, "..")) continue;
        if (++scanned > 500) { okay = NO; break; }
        NSString *titleID = [NSString stringWithUTF8String:item->d_name];
        struct stat attributes;
        if (![CanopySettings isValidTitleID:titleID] || fstatat(titles, item->d_name, &attributes, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISDIR(attributes.st_mode)) {
            [issues addObject:@"An invalid or linked title entry was skipped."]; continue;
        }
        uint64_t title = strtoull(item->d_name, NULL, 16);
        char generation[65] = {0};
        struct mng_prepare_result result = {0};
        status = mng_store_current(store, title, generation);
        if (status == MNG_PREPARE_OK) status = mng_store_verify(store, title, generation, &result);
        if (status != MNG_PREPARE_OK) {
            [issues addObject:[NSString stringWithFormat:@"Title %@ has no valid verified current generation.", titleID]]; continue;
        }
        if (result.title_id != title) { [issues addObject:@"A verified generation returned an inconsistent title identity."]; continue; }
        NSDictionary *entry = @{@"titleID":titleID, @"generationID":[NSString stringWithUTF8String:generation],
            @"recipeID":@MNG_STORE_RECIPE, @"displayName":[_settings displayNameForTitleID:titleID] ?: titleID,
            @"sourceSHA256":HexDigest(result.source_sha256), @"sourceSize":@(result.source_size),
            @"assetCount":@(result.asset_count), @"assetBytes":@(result.asset_bytes),
            @"integrity":@{@"exefsVerified":@(result.exefs_verified != 0), @"romfsVerified":@(result.romfs_verified != 0), @"signatureVerified":@NO},
            @"preparationState":@"prepared", @"runtimeEligibility":@"unassessed"};
        [entries addObject:entry];
    }
    closedir(directory); mng_store_close(store); close(root);
    if (!okay) return CatalogError(error, @"The prepared library exceeds 500 entries or could not be read completely. Existing catalog state was retained.");
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSComparisonResult order = [left[@"displayName"] localizedCaseInsensitiveCompare:right[@"displayName"]];
        return order == NSOrderedSame ? [left[@"titleID"] compare:right[@"titleID"]] : order;
    }];
    _entries = [entries copy]; _issues = [issues copy]; return YES;
}
@end
