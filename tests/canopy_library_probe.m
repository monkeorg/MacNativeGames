#import <Foundation/Foundation.h>
#import "CanopyLibrary.h"
#include <stdio.h>
#include <stdlib.h>

static void Check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr,"FAIL: %s\n",message); exit(1); }
}
static NSURL *Child(NSURL *directory, NSString *name) {
    return [directory URLByAppendingPathComponent:name];
}
static NSData *Read(NSURL *url) {
    return [NSData dataWithContentsOfURL:url];
}
static void Write(NSData *data, NSURL *url) {
    Check([data writeToURL:url options:NSDataWritingAtomic error:NULL],"fixture write failed");
}
static NSData *JSON(id value) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
    Check(data!=nil,"fixture JSON encoding failed"); return data;
}
static NSDictionary *Record(NSString *identifier) {
    return @{@"id":identifier,@"displayName":@"Synthetic container",@"format":@"NSP",
             @"sourceSize":@123,@"entryCount":@2,@"date":@"2026-10-25T12:00:00Z"};
}
static NSData *Document(NSArray *records) {
    return JSON(@{@"schemaVersion":@1,@"records":records});
}
static BOOL Add(CanopyLibrary *library, NSString *name, NSError **error) {
    if (error) return [library addDisplayName:name format:@"NSP" sourceSize:123 entryCount:2 error:error];
    NSError *ignored=nil;
    return [library addDisplayName:name format:@"NSP" sourceSize:123 entryCount:2 error:&ignored];
}
static BOOL Load(CanopyLibrary *library) { NSError *error=nil; return [library load:&error]; }
static BOOL Reset(CanopyLibrary *library) { NSError *error=nil; return [library reset:&error]; }
static BOOL Remove(CanopyLibrary *library, NSString *identifier) {
    NSError *error=nil; return [library removeIdentifier:identifier error:&error];
}
static void Unchanged(NSURL *index, NSData *before) {
    Check([Read(index) isEqual:before],"index changed on rejected operation");
}
static void Roundtrip(NSURL *directory) {
    NSURL *index=Child(directory,@"library.json");
    CanopyLibrary *first=[[CanopyLibrary alloc] initWithDirectoryURL:directory];
    Check(first.recoveryRequired,"new instance must require load");
    NSError *error=nil;
    Check(!Add(first,@"Before load",&error) && error!=nil,"mutation before load accepted");
    Check(Load(first) && !first.recoveryRequired && first.records.count==0,"new library load failed");
    Check(Add(first,@"One",NULL) && Add(first,@"Two",NULL),"valid add failed");
    NSArray *expected=[first.records copy];
    Check(expected.count==2,"record count mismatch");
    Check([expected[0][@"displayName"] isEqual:@"Two"],"newest-first ordering changed");
    Check(![expected[0][@"id"] isEqual:expected[1][@"id"]],"identifiers are not unique");
    CanopyLibrary *reopened=[[CanopyLibrary alloc] initWithDirectoryURL:directory];
    Check(Load(reopened) && [reopened.records isEqual:expected],"persisted roundtrip differs");
    NSData *before=Read(index);
    Check(!Remove(reopened,@"not-present"),"unknown removal accepted");
    Unchanged(index,before);
    Check([reopened.records isEqual:expected],"unknown removal changed memory");
    Check(Remove(reopened,expected[0][@"id"]),"valid removal failed");
    CanopyLibrary *removed=[[CanopyLibrary alloc] initWithDirectoryURL:directory];
    Check(Load(removed) && removed.records.count==1 &&
          [removed.records[0] isEqual:expected[1]],"removal not persisted");
    Check(Reset(removed) && !removed.recoveryRequired && removed.records.count==0,"reset failed");
    CanopyLibrary *empty=[[CanopyLibrary alloc] initWithDirectoryURL:directory];
    Check(Load(empty) && empty.records.count==0 && !empty.recoveryRequired,"reset not persisted");
}
static NSData *InvalidDocument(NSString *scenario) {
    NSString *identifier=@"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE";
    NSDictionary *record=Record(identifier);
    if ([scenario isEqual:@"malformed"]) return [@"{broken JSON" dataUsingEncoding:NSUTF8StringEncoding];
    if ([scenario isEqual:@"unknown_schema"]) return JSON(@{@"schemaVersion":@2,@"records":@[]});
    if ([scenario isEqual:@"oversize"]) {
        NSMutableData *data=[Document(@[]) mutableCopy];
        [data increaseLengthBy:1024*1024+1]; return data;
    }
    if ([scenario isEqual:@"duplicate_uuid"]) return Document(@[record,Record(identifier.lowercaseString)]);
    if ([scenario isEqual:@"too_many_records"]) {
        NSMutableArray *records=[NSMutableArray array];
        for (NSUInteger i=0;i<501;i++) [records addObject:Record(NSUUID.UUID.UUIDString)];
        return Document(records);
    }
    if ([scenario isEqual:@"boolean_schema"]) return JSON(@{@"schemaVersion":@YES,@"records":@[]});
    if ([scenario isEqual:@"unknown_key"]) return JSON(@{@"schemaVersion":@1,@"records":@[],@"extra":@1});
    NSMutableDictionary *changed=[record mutableCopy];
    if ([scenario isEqual:@"invalid_uuid"]) changed[@"id"]=@"invalid";
    else if ([scenario isEqual:@"invalid_name"]) changed[@"displayName"]=@"newline\nname";
    else if ([scenario isEqual:@"invalid_format"]) changed[@"format"]=@"EXECUTABLE";
    else if ([scenario isEqual:@"invalid_date"]) changed[@"date"]=@"not a date";
    else if ([scenario isEqual:@"boolean_size"]) changed[@"sourceSize"]=@YES;
    else if ([scenario isEqual:@"negative_size"]) changed[@"sourceSize"]=@(-1);
    else if ([scenario isEqual:@"fractional_count"]) changed[@"entryCount"]=@1.5;
    else if ([scenario isEqual:@"oversize_count"]) changed[@"entryCount"]=@4097;
    else Check(NO,"unknown invalid fixture");
    return Document(@[changed]);
}
static void Corrupt(NSURL *directory, NSString *scenario) {
    NSURL *index=Child(directory,@"library.json");
    NSData *before=InvalidDocument(scenario); Write(before,index);
    CanopyLibrary *library=[[CanopyLibrary alloc] initWithDirectoryURL:directory];
    NSError *error=nil;
    Check(![library load:&error] && error!=nil,"invalid document accepted");
    Check(library.recoveryRequired && library.records.count==0,"invalid library state");
    Unchanged(index,before);
    error=nil;
    Check(!Add(library,@"Must not persist",&error) && error!=nil,"add during recovery accepted");
    Unchanged(index,before);
    error=nil;
    Check(![library removeIdentifier:@"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE" error:&error] && error!=nil,
          "remove during recovery accepted");
    Unchanged(index,before);
    Check(library.records.count==0 && library.recoveryRequired,"rejected mutation changed recovery state");
}
static void RecoveryReset(NSURL *directory) {
    NSURL *index=Child(directory,@"library.json");
    Write(InvalidDocument(@"malformed"),index);
    CanopyLibrary *library=[[CanopyLibrary alloc] initWithDirectoryURL:directory];
    Check(!Load(library) && library.recoveryRequired,"corruption did not require recovery");
    /* This direct reset call represents the explicit confirmation required by
     * the model contract; the Foundation harness does not exercise UIKit. */
    Check(Reset(library) && !library.recoveryRequired,"confirmed reset failed");
    Check(Add(library,@"After reset",NULL),"post-reset add failed");
    CanopyLibrary *reopened=[[CanopyLibrary alloc] initWithDirectoryURL:directory];
    Check(Load(reopened) && reopened.records.count==1,"post-reset persistence failed");
}
static void FailedPersistence(NSURL *directory) {
    NSURL *index=Child(directory,@"library.json");
    CanopyLibrary *library=[[CanopyLibrary alloc] initWithDirectoryURL:directory];
    Check(Load(library) && Add(library,@"Existing",NULL),"initial persistence failed");
    NSArray *expected=[library.records copy];
    NSData *original=Read(index);
    NSFileManager *fm=NSFileManager.defaultManager;
    Check([fm removeItemAtURL:index error:NULL],"fixture remove failed");
    Check([fm createDirectoryAtURL:index withIntermediateDirectories:NO attributes:nil error:NULL],"fixture directory failed");
    NSURL *blocker=Child(index,@"blocker");
    NSData *sentinel=[@"retain failed-write fixture" dataUsingEncoding:NSUTF8StringEncoding]; Write(sentinel,blocker);
    NSError *error=nil;
    Check(!Add(library,@"New",&error) && error!=nil,"failed add reported success");
    Check([library.records isEqual:expected] && !library.recoveryRequired,"failed add changed memory");
    error=nil;
    Check(![library removeIdentifier:expected[0][@"id"] error:&error] && error!=nil,"failed remove reported success");
    Check([library.records isEqual:expected],"failed remove changed memory");
    error=nil;
    Check(![library reset:&error] && error!=nil,"failed reset reported success");
    Check([library.records isEqual:expected] && !library.recoveryRequired,"failed reset changed memory");
    Check([Read(blocker) isEqual:sentinel],"failed write changed destination contents");
    Check([fm removeItemAtURL:index error:NULL],"fixture cleanup failed"); Write(original,index);
    CanopyLibrary *reopened=[[CanopyLibrary alloc] initWithDirectoryURL:directory];
    Check(Load(reopened) && [reopened.records isEqual:expected],"previous persisted records lost");
}
static void RecordLimit(NSURL *directory) {
    NSMutableArray *records=[NSMutableArray array];
    for (NSUInteger i=0;i<500;i++) [records addObject:Record(NSUUID.UUID.UUIDString)];
    NSURL *index=Child(directory,@"library.json"); NSData *before=Document(records); Write(before,index);
    CanopyLibrary *library=[[CanopyLibrary alloc] initWithDirectoryURL:directory];
    Check(Load(library) && library.records.count==500,"record boundary rejected");
    Check(!Add(library,@"Overflow",NULL),"record limit exceeded");
    Check([library.records isEqual:records],"limit failure changed memory"); Unchanged(index,before);
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Check(argc==3,"usage");
        NSString *scenario=[NSString stringWithUTF8String:argv[1]];
        NSURL *root=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]] isDirectory:YES];
        NSURL *directory=Child(root,@"metadata");
        Check([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES
            attributes:nil error:NULL],"cannot create fixture directory");
        NSURL *source=Child(root,@"original-source.nsp");
        NSData *sourceBytes=[@"Synthetic source bytes: metadata operations must not touch these."
                            dataUsingEncoding:NSUTF8StringEncoding]; Write(sourceBytes,source);
        if ([scenario isEqual:@"roundtrip"]) Roundtrip(directory);
        else if ([scenario isEqual:@"recovery_reset"]) RecoveryReset(directory);
        else if ([scenario isEqual:@"failed_persistence"]) FailedPersistence(directory);
        else if ([scenario isEqual:@"record_limit"]) RecordLimit(directory);
        else Corrupt(directory,scenario);
        Check([Read(source) isEqual:sourceBytes],"original source changed");
        puts("{\"status\":\"pass\"}");
    }
    return 0;
}
