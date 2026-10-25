#import "CanopySettings.h"
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>

static const NSUInteger CanopySettingsLimit = 1024 * 1024;
static const NSUInteger CanopyTitleLimit = 500;

static BOOL SettingsError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"CanopySettings" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static BOOL IsInteger(id value, NSUInteger low, NSUInteger high) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return isfinite(number) && floor(number) == number && number >= low && number <= high;
}
static BOOL IsBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}
static BOOL IsName(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= 200 &&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static BOOL ValidOption(NSString *key, id value) {
    if ([@[@"metalHUD", @"taa", @"touch", @"mouseInvertY"] containsObject:key]) return IsBoolean(value);
    if ([key isEqual:@"fpsLimit"]) return IsInteger(value, 30, 60) && [@[@30,@40,@60] containsObject:value];
    if ([key isEqual:@"renderHeight"]) return IsInteger(value, 720, 1080) && [@[@720,@1080] containsObject:value];
    if ([key isEqual:@"hud"]) return IsInteger(value, 0, 2);
    if ([key isEqual:@"mouseSensitivity"]) return IsInteger(value, 1, 100);
    if ([key isEqual:@"aspect"]) return [@[@"16:9", @"display"] containsObject:value];
    if ([key isEqual:@"controllerType"]) return [@[@"auto", @"xbox", @"playstation", @"switch"] containsObject:value];
    if ([key isEqual:@"language"]) return [@[@"",@"zh-Hant",@"zh-Hans",@"en-US",@"ja",@"de",@"es",@"fr",@"it",@"nl",@"ru",@"ko"] containsObject:value];
    if ([key isEqual:@"buttonMappings"]) {
        if (![value isKindOfClass:NSDictionary.class] || [value count] > 22) return NO;
        NSArray *buttons = @[@"south",@"east",@"west",@"north",@"l1",@"r1",@"l2",@"r2",@"l3",@"r3",@"menu",@"view",@"up",@"down",@"left",@"right",@"touchpad",@"mouse_left",@"mouse_right",@"mouse_middle",@"mouse4",@"mouse5"];
        NSArray *targets = @[@"default",@"none",@"a",@"b",@"x",@"y",@"lstick",@"rstick",@"l",@"r",@"zl",@"zr",@"plus",@"minus",@"left",@"up",@"right",@"down"];
        for (id button in value) if (![buttons containsObject:button] || ![targets containsObject:value[button]]) return NO;
        return YES;
    }
    return NO;
}
static BOOL ValidSettings(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    for (id key in value) if (![key isKindOfClass:NSString.class] || !ValidOption(key, value[key])) return NO;
    return YES;
}

@implementation CanopySettings {
    NSURL *_directory;
    NSDictionary *_titles;
    BOOL _recoveryRequired;
}
+ (NSDictionary *)defaults {
    return @{@"fpsLimit":@60, @"renderHeight":@720, @"aspect":@"16:9", @"hud":@1,
        @"metalHUD":@NO, @"taa":@NO, @"touch":@YES, @"mouseSensitivity":@50,
        @"mouseInvertY":@NO, @"controllerType":@"auto", @"language":@"", @"buttonMappings":@{}};
}
+ (BOOL)isValidTitleID:(NSString *)titleID {
    return [titleID isKindOfClass:NSString.class] && titleID.length == 16 &&
        [titleID rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}
- (instancetype)initWithDirectoryURL:(NSURL *)directory {
    if ((self = [super init])) { _directory = [directory copy]; _titles = @{}; _recoveryRequired = YES; }
    return self;
}
- (BOOL)recoveryRequired { return _recoveryRequired; }
- (NSURL *)metadataURL { return [_directory URLByAppendingPathComponent:@"titles.json"]; }
- (BOOL)load:(NSError **)error {
    int directory = open(_directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0 && errno == ENOENT) { _titles = @{}; _recoveryRequired = NO; return YES; }
    int descriptor = directory < 0 ? -1 : openat(directory, "titles.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    int openError = errno;
    if (directory >= 0) close(directory);
    if (directory >= 0 && descriptor < 0 && openError == ENOENT) { _titles = @{}; _recoveryRequired = NO; return YES; }
    struct stat before = {0}, after = {0};
    BOOL okay = descriptor >= 0 && fstat(descriptor, &before) == 0 && S_ISREG(before.st_mode) && before.st_size >= 0 && (uint64_t)before.st_size <= CanopySettingsLimit;
    NSMutableData *data = [NSMutableData data];
    while (okay && data.length <= CanopySettingsLimit) {
        unsigned char buffer[4096];
        ssize_t count = read(descriptor, buffer, MIN(sizeof(buffer), CanopySettingsLimit + 1 - data.length));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { okay = NO; break; }
        if (!count) break;
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    okay = okay && data.length <= CanopySettingsLimit && data.length == (NSUInteger)before.st_size &&
        fstat(descriptor, &after) == 0 && before.st_size == after.st_size &&
        before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
        before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec;
    if (descriptor >= 0) close(descriptor);
    id document = okay ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    BOOL valid = [document isKindOfClass:NSDictionary.class] &&
        [[NSSet setWithArray:[document allKeys]] isEqual:[NSSet setWithArray:@[@"schemaVersion",@"titles"]]] &&
        IsInteger(document[@"schemaVersion"], 1, 1) && [document[@"titles"] isKindOfClass:NSDictionary.class] &&
        [document[@"titles"] count] <= CanopyTitleLimit;
    if (valid) for (id title in document[@"titles"]) {
        id row = document[@"titles"][title];
        if (![CanopySettings isValidTitleID:title] || ![row isKindOfClass:NSDictionary.class] ||
            ![[NSSet setWithArray:[row allKeys]] isEqual:[NSSet setWithArray:@[@"displayName",@"settings"]]] ||
            !IsName(row[@"displayName"]) || !ValidSettings(row[@"settings"])) { valid = NO; break; }
    }
    if (!valid) { _recoveryRequired = YES; return SettingsError(error, @"Title settings metadata is unreadable, invalid or unsupported. It was not replaced. Explicitly reset metadata to recover."); }
    _titles = [document[@"titles"] copy]; _recoveryRequired = NO;
    return YES;
}
- (NSDictionary *)settingsForTitleID:(NSString *)titleID error:(NSError **)error {
    if (_recoveryRequired || ![CanopySettings isValidTitleID:titleID]) { SettingsError(error, @"Load valid title settings before reading this title."); return nil; }
    NSMutableDictionary *result = [[CanopySettings defaults] mutableCopy];
    [result addEntriesFromDictionary:_titles[titleID][@"settings"] ?: @{}];
    return [result copy];
}
- (NSString *)displayNameForTitleID:(NSString *)titleID { return _recoveryRequired ? nil : _titles[titleID][@"displayName"]; }
- (BOOL)writeTitles:(NSDictionary *)titles error:(NSError **)error {
    if (!_recoveryRequired) {
        CanopySettings *current = [[CanopySettings alloc] initWithDirectoryURL:_directory];
        NSError *readError = nil;
        if (![current load:&readError]) { _recoveryRequired = YES; if (error) *error = readError; return NO; }
        if (![current->_titles isEqual:_titles]) return SettingsError(error, @"Title metadata changed since it was loaded. Reload it before saving; no changes were written.");
    }
    if (titles.count > CanopyTitleLimit) return SettingsError(error, @"At most 500 titles may have custom metadata.");
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"schemaVersion":@1,@"titles":titles} options:NSJSONWritingSortedKeys error:error];
    if (!data) return NO;
    if (data.length > CanopySettingsLimit) return SettingsError(error, @"Title settings metadata exceeds its size limit.");
    if (![NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
    int directory = open(_directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) return SettingsError(error, @"The metadata directory is unavailable or is a link.");
    struct stat existing;
    BOOL safe = fstatat(directory, "titles.json", &existing, AT_SYMLINK_NOFOLLOW) == 0 ? S_ISREG(existing.st_mode) : errno == ENOENT;
    close(directory);
    if (!safe) return SettingsError(error, @"The metadata index is not a regular file. It has not been replaced.");
    if (![data writeToURL:[self metadataURL] options:NSDataWritingAtomic error:error]) return NO;
    _titles = [titles copy]; _recoveryRequired = NO; return YES;
}
- (BOOL)setValue:(id)value forSetting:(NSString *)key titleID:(NSString *)titleID error:(NSError **)error {
    if (_recoveryRequired || ![CanopySettings isValidTitleID:titleID] || !ValidOption(key, value)) return SettingsError(error, @"Invalid title setting, or metadata needs explicit recovery.");
    NSMutableDictionary *titles = [_titles mutableCopy];
    NSMutableDictionary *row = [_titles[titleID] mutableCopy] ?: [@{@"displayName":titleID,@"settings":@{}} mutableCopy];
    NSMutableDictionary *settings = [row[@"settings"] mutableCopy];
    // Serialization snapshots mutable caller objects before storing them.
    NSData *snapshot = [NSJSONSerialization dataWithJSONObject:@[value] options:0 error:NULL];
    if (!snapshot) return SettingsError(error, @"Invalid setting value.");
    settings[key] = [NSJSONSerialization JSONObjectWithData:snapshot options:0 error:NULL][0];
    row[@"settings"] = [settings copy]; titles[titleID] = [row copy];
    return [self writeTitles:titles error:error];
}
- (BOOL)setDisplayName:(NSString *)name forTitleID:(NSString *)titleID error:(NSError **)error {
    if (_recoveryRequired || ![CanopySettings isValidTitleID:titleID] || !IsName(name)) return SettingsError(error, @"Invalid title name, or metadata needs explicit recovery.");
    NSMutableDictionary *titles = [_titles mutableCopy];
    NSMutableDictionary *row = [_titles[titleID] mutableCopy] ?: [@{@"settings":@{}} mutableCopy];
    row[@"displayName"] = [name copy]; titles[titleID] = [row copy];
    return [self writeTitles:titles error:error];
}
- (BOOL)resetMetadata:(NSError **)error { return [self writeTitles:@{} error:error]; }
@end
