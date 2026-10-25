#import "CanopyLibrary.h"
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static const NSUInteger CanopyMaximumRecords = 500;
static const NSUInteger CanopyMaximumIndexBytes = 1024 * 1024;
static NSString *const CanopyLibraryErrorDomain = @"CanopyLibrary";

static BOOL CanopyFail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:CanopyLibraryErrorDomain code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}

static BOOL CanopyUnsignedNumber(id value, uint64_t maximum) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return isfinite(number) && number >= 0 && floor(number) == number &&
        number <= (double)maximum && [value unsignedLongLongValue] <= maximum;
}

static BOOL CanopyNameValid(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 &&
        [value length] <= 200 && [value rangeOfCharacterFromSet:
        NSCharacterSet.controlCharacterSet].location == NSNotFound;
}

static NSISO8601DateFormatter *CanopyDateFormatter(void) {
    return [NSISO8601DateFormatter new];
}

static BOOL CanopyRecordValid(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *record = value;
    NSSet *keys = [NSSet setWithArray:@[@"id", @"displayName", @"format", @"sourceSize", @"entryCount", @"date"]];
    if (![[NSSet setWithArray:record.allKeys] isEqual:keys]) return NO;
    NSString *identifier = record[@"id"];
    if (![identifier isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:identifier]) return NO;
    if (!CanopyNameValid(record[@"displayName"]) ||
        ![@[@"NSP", @"XCI"] containsObject:record[@"format"]] ||
        !CanopyUnsignedNumber(record[@"sourceSize"], INT64_MAX) ||
        !CanopyUnsignedNumber(record[@"entryCount"], 4096)) return NO;
    id date = record[@"date"];
    return [date isKindOfClass:NSString.class] && [date length] <= 40 &&
        [CanopyDateFormatter() dateFromString:date] != nil;
}

@implementation CanopyLibrary {
    NSURL *_directory;
    NSArray<NSDictionary<NSString *, id> *> *_records;
    BOOL _recoveryRequired;
}
- (instancetype)initWithDirectoryURL:(NSURL *)directory {
    if ((self = [super init])) { _directory = [directory copy]; _records = @[]; _recoveryRequired = YES; }
    return self;
}
- (NSArray *)records { return _records; }
- (BOOL)recoveryRequired { return _recoveryRequired; }
- (NSURL *)indexURL { return [_directory URLByAppendingPathComponent:@"library.json"]; }
- (BOOL)load:(NSError **)error {
    _records = @[];
    _recoveryRequired = NO;
    NSURL *url = [self indexURL];
    int descriptor = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (descriptor < 0 && errno == ENOENT) return YES;
    struct stat before = {0}, after = {0};
    BOOL readable = descriptor >= 0 && fstat(descriptor, &before) == 0 && S_ISREG(before.st_mode) &&
        before.st_size >= 0 && (uint64_t)before.st_size <= CanopyMaximumIndexBytes;
    NSMutableData *data = [NSMutableData data];
    if (readable) {
        unsigned char buffer[4096];
        while (data.length <= CanopyMaximumIndexBytes) {
            size_t available = MIN(sizeof(buffer), CanopyMaximumIndexBytes + 1 - data.length);
            ssize_t count = read(descriptor, buffer, available);
            if (count < 0 && errno == EINTR) continue;
            if (count < 0) { readable = NO; break; }
            if (count == 0) break;
            [data appendBytes:buffer length:(NSUInteger)count];
        }
        readable = readable && data.length <= CanopyMaximumIndexBytes && data.length == (NSUInteger)before.st_size &&
            fstat(descriptor, &after) == 0 && before.st_size == after.st_size &&
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec &&
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec;
    }
    if (descriptor >= 0) close(descriptor);
    if (!readable) {
        _recoveryRequired = YES;
        return CanopyFail(error, @"The library index could not be read safely. It has not been replaced. Reset the library metadata to continue.");
    }
    id document = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    BOOL valid = [document isKindOfClass:NSDictionary.class];
    if (valid) {
        valid = [[NSSet setWithArray:[document allKeys]] isEqual:[NSSet setWithArray:@[@"schemaVersion", @"records"]]] &&
            CanopyUnsignedNumber(document[@"schemaVersion"], 1) && [document[@"schemaVersion"] unsignedIntegerValue] == 1 &&
            [document[@"records"] isKindOfClass:NSArray.class] && [document[@"records"] count] <= CanopyMaximumRecords;
    }
    NSMutableSet *identifiers = [NSMutableSet set];
    if (valid) for (id record in document[@"records"]) {
        if (!CanopyRecordValid(record) || [identifiers containsObject:[record[@"id"] uppercaseString]]) { valid = NO; break; }
        [identifiers addObject:[record[@"id"] uppercaseString]];
    }
    if (!valid) {
        _recoveryRequired = YES;
        return CanopyFail(error, @"The library index is invalid or uses an unsupported version. It has not been replaced. Reset only its metadata to continue.");
    }
    _records = [document[@"records"] copy];
    return YES;
}
- (BOOL)writeRecords:(NSArray *)records error:(NSError **)error {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"schemaVersion":@1, @"records":records} options:NSJSONWritingSortedKeys error:error];
    if (!data) return NO;
    if (data.length > CanopyMaximumIndexBytes) return CanopyFail(error, @"The library metadata limit has been reached.");
    if (![NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
    if (![data writeToURL:[self indexURL] options:NSDataWritingAtomic error:error]) return NO;
    _records = [records copy];
    _recoveryRequired = NO;
    return YES;
}
- (BOOL)addDisplayName:(NSString *)name format:(NSString *)format sourceSize:(uint64_t)size
            entryCount:(NSUInteger)count error:(NSError **)error {
    if (_recoveryRequired) return CanopyFail(error, @"Reset the unreadable library metadata before inspecting another file.");
    if (_records.count >= CanopyMaximumRecords) return CanopyFail(error, @"The library holds at most 500 inspected containers. Remove a metadata record before adding another.");
    NSDictionary *record = @{@"id":NSUUID.UUID.UUIDString, @"displayName":[name copy], @"format":[format copy],
        @"sourceSize":@(size), @"entryCount":@(count), @"date":[CanopyDateFormatter() stringFromDate:NSDate.date]};
    if (!CanopyRecordValid(record)) return CanopyFail(error, @"This container's metadata cannot be stored safely.");
    return [self writeRecords:[@[record] arrayByAddingObjectsFromArray:_records] error:error];
}
- (BOOL)removeIdentifier:(NSString *)identifier error:(NSError **)error {
    if (_recoveryRequired) return CanopyFail(error, @"The library metadata needs recovery.");
    NSMutableArray *remaining = [_records mutableCopy];
    NSUInteger index = [remaining indexOfObjectPassingTest:^BOOL(NSDictionary *record, NSUInteger position, BOOL *stop) {
        (void)position; (void)stop; return [record[@"id"] isEqual:identifier];
    }];
    if (index == NSNotFound) return CanopyFail(error, @"This record is no longer in the library.");
    [remaining removeObjectAtIndex:index];
    return [self writeRecords:remaining error:error];
}
- (BOOL)reset:(NSError **)error { return [self writeRecords:@[] error:error]; }
@end
