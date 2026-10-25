#import <Foundation/Foundation.h>
#import "CanopyCatalog.h"
#include "mng_store.h"
#include "mng_crypto.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const A = @"0100000000000001";
static NSString *const B = @"0100000000000002";
static void Check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static NSURL *Child(NSURL *url, NSString *name) { return [url URLByAppendingPathComponent:name]; }
static void Directory(NSURL *url) { Check([NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:NULL], "mkdir"); }
static NSData *JSON(id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
    Check(data != nil, "encode JSON"); return data;
}
static void Write(NSData *data, NSURL *url) { Check([data writeToURL:url options:NSDataWritingAtomic error:NULL], "write"); }
static NSData *Read(NSURL *url) { return [NSData dataWithContentsOfURL:url]; }
static CanopySettings *Settings(NSURL *directory) {
    CanopySettings *settings = [[CanopySettings alloc] initWithDirectoryURL:directory];
    NSError *error = nil; Check([settings load:&error], "load settings"); return settings;
}
static NSDictionary *Values(CanopySettings *settings, NSString *title) {
    NSError *error = nil; NSDictionary *values = [settings settingsForTitleID:title error:&error];
    Check(values != nil, "read settings"); return values;
}
static NSDictionary *Document(id titles) { return @{@"schemaVersion":@1, @"titles":titles}; }
static NSDictionary *Row(id settings) { return @{@"displayName":@"Synthetic", @"settings":settings}; }
static void SettingsRoundtrip(NSURL *root) {
    CanopySettings *settings = Settings(root); NSError *error = nil;
    Check([Values(settings, A)[@"fpsLimit"] isEqual:@60], "default FPS");
    Check([settings setValue:@40 forSetting:@"fpsLimit" titleID:A error:&error], "set FPS");
    Check([settings setDisplayName:@"First prepared title" forTitleID:A error:&error], "set name");
    Check([Values(settings, B)[@"fpsLimit"] isEqual:@60], "title isolation");
    Check([settings setValue:@NO forSetting:@"touch" titleID:B error:&error], "set touch");
    CanopySettings *reopened = Settings(root);
    Check([Values(reopened, A)[@"fpsLimit"] isEqual:@40] && [Values(reopened, B)[@"touch"] isEqual:@NO], "settings persistence");
    Check([[reopened displayNameForTitleID:A] isEqual:@"First prepared title"], "name persistence");
    Check([reopened resetMetadata:&error], "explicit reset");
    Check([Values(Settings(root), A)[@"fpsLimit"] isEqual:@60], "reset defaults");
}
static void Options(NSURL *root) {
    CanopySettings *settings = Settings(root); NSError *error = nil;
    NSArray *bad = @[@[@"fpsLimit",@YES], @[@"fpsLimit",@50], @[@"renderHeight",@900], @[@"hud",@3],
        @[@"mouseSensitivity",@1.5], @[@"mouseSensitivity",@0], @[@"touch",@1], @[@"language",@"invented"],
        @[@"aspect",@"wide"], @[@"controllerType",@"unknown"], @[@"unknown",@1], @[@"buttonMappings",@{@"south":@"invalid"}]];
    for (NSArray *pair in bad) Check(![settings setValue:pair[1] forSetting:pair[0] titleID:A error:&error], "invalid setting accepted");
    Check(![settings setValue:@30 forSetting:@"fpsLimit" titleID:@"../escape" error:&error], "unsafe title accepted");
    NSMutableDictionary *mapping = [@{@"south":@"a"} mutableCopy];
    Check([settings setValue:mapping forSetting:@"buttonMappings" titleID:A error:&error], "mapping write");
    mapping[@"south"] = @"b";
    Check([Values(settings,A)[@"buttonMappings"][@"south"] isEqual:@"a"], "caller mutation changed settings");
}
static void Invalid(NSURL *root, NSString *scenario) {
    Directory(root); NSURL *index = Child(root,@"titles.json");
    NSData *data = JSON(Document(@{A:Row(@{})}));
    if ([scenario isEqual:@"malformed"]) data = [@"{" dataUsingEncoding:NSUTF8StringEncoding];
    else if ([scenario isEqual:@"version"]) data = JSON(@{@"schemaVersion":@2,@"titles":@{}});
    else if ([scenario isEqual:@"boolean_version"]) data = JSON(@{@"schemaVersion":@YES,@"titles":@{}});
    else if ([scenario isEqual:@"unknown_key"]) data = JSON(@{@"schemaVersion":@1,@"titles":@{},@"keys":@[]});
    else if ([scenario isEqual:@"invalid_title"]) data = JSON(Document(@{@"../bad":Row(@{})}));
    else if ([scenario isEqual:@"invalid_option"]) data = JSON(Document(@{A:Row(@{@"fpsLimit":@50})}));
    else if ([scenario isEqual:@"oversize"]) { NSMutableData *large = [data mutableCopy]; [large increaseLengthBy:1024*1024+1]; data = large; }
    else if ([scenario isEqual:@"title_limit"]) {
        NSMutableDictionary *titles = [NSMutableDictionary dictionary];
        for (unsigned i = 0; i < 501; ++i) titles[[NSString stringWithFormat:@"%016x",i]] = Row(@{});
        data = JSON(Document(titles));
    }
    Write(data,index);
    if ([scenario isEqual:@"symlink"]) {
        NSURL *target = Child(root,@"original.json");
        Check([NSFileManager.defaultManager moveItemAtURL:index toURL:target error:NULL], "move index");
        Check(symlink(target.fileSystemRepresentation,index.fileSystemRepresentation)==0,"link fixture");
    }
    CanopySettings *settings = [[CanopySettings alloc] initWithDirectoryURL:root]; NSError *error = nil;
    Check(![settings load:&error] && settings.recoveryRequired, "invalid index accepted");
    Check(![settings setValue:@30 forSetting:@"fpsLimit" titleID:A error:&error], "corrupt metadata overwritten");
    Check([Read(index) isEqual:data], "corrupt bytes changed");
    if (![scenario isEqual:@"symlink"]) {
        Check([settings resetMetadata:&error] && !settings.recoveryRequired, "recovery reset failed");
        Check([Values(Settings(root),A)[@"fpsLimit"] isEqual:@60], "recovered defaults");
    } else Check(![settings resetMetadata:&error] && [Read(index) isEqual:data], "reset followed symlink");
}
static void Partial(NSURL *root) {
    Directory(root); NSURL *index=Child(root,@"titles.json"); NSData *original=JSON(Document(@{A:Row(@{@"fpsLimit":@30})}));
    Write(original,index); CanopySettings *settings=Settings(root);
    Check([Values(settings,A)[@"fpsLimit"] isEqual:@30] && [Values(settings,A)[@"renderHeight"] isEqual:@720],"partial defaults");
    Check([Read(index) isEqual:original],"read silently migrated metadata");
}
static void Failure(NSURL *root, BOOL lateCorruption) {
    CanopySettings *settings=Settings(root); NSError *error=nil;
    Check([settings setValue:@30 forSetting:@"fpsLimit" titleID:A error:&error],"initial setting");
    NSURL *index=Child(root,@"titles.json");
    if (lateCorruption) {
        NSData *corrupt=[@"broken" dataUsingEncoding:NSUTF8StringEncoding]; Write(corrupt,index);
        Check(![settings setValue:@40 forSetting:@"fpsLimit" titleID:A error:&error],"late corruption overwritten");
        Check([Read(index) isEqual:corrupt],"late corruption changed");
    } else {
        Check([NSFileManager.defaultManager removeItemAtURL:index error:NULL],"remove index"); Directory(index);
        Write([@"keep" dataUsingEncoding:NSUTF8StringEncoding],Child(index,@"sentinel"));
        Check(![settings setDisplayName:@"Changed" forTitleID:A error:&error],"nonregular index overwritten");
        Check([Read(Child(index,@"sentinel")) isEqual:[@"keep" dataUsingEncoding:NSUTF8StringEncoding]],"failure removed sentinel");
    }
}
static void Digest(NSData *bytes, unsigned char digest[32]) {
    struct mng_sha256 *hash=NULL;
    Check(!mng_sha256_init(&hash) && !mng_sha256_update(hash,bytes.bytes,bytes.length) && !mng_sha256_final(hash,digest),"hash fixture");
    mng_sha256_free(hash);
}
static NSString *Commit(NSURL *root, uint64_t title, unsigned sequence) {
    Directory(root); Check(chmod(root.fileSystemRepresentation,0700)==0,"private prepared root mode");
    int descriptor=open(root.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    Check(descriptor>=0,"open root"); struct mng_store *store=NULL;
    Check(mng_store_open(descriptor,&store)==MNG_PREPARE_OK,"open store");
    char job[33]; snprintf(job,sizeof(job),"%032x",sequence);
    Check(mng_store_begin(store,job)==MNG_PREPARE_OK,"begin store");
    struct mng_asset_sink sink=mng_store_sink(store);
    NSData *bytes=[[NSString stringWithFormat:@"original-source-fixture-%u",sequence] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[32]; Digest(bytes,digest);
    const char *paths[]={"exefs/main","exefs/main.npdm","romfs.bin"};
    for (unsigned i=0;i<3;++i) Check(!sink.begin(sink.context,paths[i],bytes.length) &&
        !sink.write(sink.context,bytes.bytes,bytes.length) && !sink.end(sink.context,digest),"publish synthetic asset");
    struct mng_prepare_result result={0}; result.title_id=title; result.source_size=bytes.length;
    result.asset_count=3; result.asset_bytes=3*bytes.length; result.exefs_verified=1; result.romfs_verified=1;
    memcpy(result.source_sha256,digest,32); char generation[65]={0};
    Check(mng_store_commit(store,&result,generation)==MNG_PREPARE_OK,"commit store");
    mng_store_close(store); close(descriptor);
    return [NSString stringWithUTF8String:generation];
}
static CanopyCatalog *Catalog(NSURL *root, CanopySettings *settings) {
    CanopyCatalog *catalog=[[CanopyCatalog alloc] initWithPreparedRootURL:root settings:settings];
    NSError *error=nil; Check([catalog reload:&error],"reload catalog"); return catalog;
}
static void CatalogScenario(NSURL *directory, NSString *scenario) {
    NSURL *root=Child(directory,@"prepared"), *metadata=Child(directory,@"metadata");
    CanopySettings *settings=Settings(metadata); NSError *error=nil;
    CanopyCatalog *empty=Catalog(root,settings); Check(empty.entries.count==0,"fabricated empty title");
    NSString *generation=Commit(root,UINT64_C(0x0100000000000001),1);
    (void)Commit(root,UINT64_C(0x0100000000000002),2);
    Check([settings setDisplayName:@"First" forTitleID:A error:&error],"custom title name");
    CanopyCatalog *catalog=Catalog(root,settings); Check(catalog.entries.count==2,"prepared titles missing");
    NSDictionary *first=nil;
    for (NSDictionary *entry in catalog.entries) if ([entry[@"titleID"] isEqual:A]) first=entry;
    Check(first && [first[@"generationID"] isEqual:generation] && [first[@"displayName"] isEqual:@"First"],"catalog identity/name");
    Check([first[@"runtimeEligibility"] isEqual:@"unassessed"] && [first[@"preparationState"] isEqual:@"prepared"],"preparation inferred runtime compatibility");
    if ([scenario isEqual:@"busy"]) {
        int descriptor=open(root.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_CLOEXEC); struct mng_store *store=NULL;
        Check(descriptor>=0 && mng_store_open(descriptor,&store)==MNG_PREPARE_OK,"hold store lock");
        NSArray *before=catalog.entries;
        Check(![catalog reload:&error] && [catalog.entries isEqual:before],"busy replaced catalog");
        mng_store_close(store); close(descriptor); Check([catalog reload:&error],"reload after busy");
    } else if ([scenario isEqual:@"catalog_limit"]) {
        NSArray *before=catalog.entries;
        for (unsigned i=0;i<501;++i) Directory(Child(root,[NSString stringWithFormat:@"titles/%016x",i]));
        Check(![catalog reload:&error] && [catalog.entries isEqual:before],"catalog bound missing");
    } else if ([scenario isEqual:@"catalog_link"]) {
        NSURL *link=Child(directory,@"linked"); Check(symlink(root.fileSystemRepresentation,link.fileSystemRepresentation)==0,"root link");
        CanopyCatalog *linked=[[CanopyCatalog alloc] initWithPreparedRootURL:link settings:settings];
        Check(![linked reload:&error],"linked root accepted");
    } else {
        NSURL *asset=Child(root,[NSString stringWithFormat:@"titles/%@/generations/%@/exefs/main",A,generation]);
        Write([@"changed" dataUsingEncoding:NSUTF8StringEncoding],asset);
        Check([catalog reload:&error] && catalog.entries.count==1 && catalog.issues.count>0,"corrupt generation accepted or hid healthy title");
        Check([catalog.entries[0][@"titleID"] isEqual:B],"wrong surviving title");
        Check(symlink("../",Child(root,@"titles/0100000000000003").fileSystemRepresentation)==0,"linked title fixture");
        Check([catalog reload:&error] && catalog.entries.count==1 && catalog.issues.count>1,"linked title accepted");
        Check([settings resetMetadata:&error],"reset metadata");
        Check([catalog reload:&error] && catalog.entries.count==1,"metadata reset removed generations");
    }
}
static void FolderCatalogScenario(NSURL *directory) {
    CanopySettings *settings=Settings(Child(directory,@"metadata"));
    CanopyCatalog *catalog=Catalog(Child(directory,@"prepared"),settings);
    Check(catalog.entries.count==2 && !catalog.issues.count,"actual folder generations missing");
    for(NSDictionary *entry in catalog.entries) {
        BOOL raw=[entry[@"sourceKind"] isEqual:@"asset-folder"];
        Check(raw || [entry[@"sourceKind"] isEqual:@"nca-folder"],"folder source kind");
        Check([entry[@"recipeID"] isEqual:@MNG_STORE_RECIPE_V4],"folder recipe");
        Check(!entry[@"sourceSHA256"] && !entry[@"sourceSize"],"fake physical folder identity");
        Check([entry[@"memberInventorySHA256"] length]==64 && [entry[@"sourceMemberCount"] unsignedIntValue]>0 &&
            [entry[@"sourceMemberBytes"] unsignedLongLongValue]>0,"folder inventory identity");
        Check([entry[@"runtimeEligibility"] isEqual:@"unassessed"] && [entry[@"preparationState"] isEqual:@"prepared"],"folder execution claim");
        NSDictionary *integrity=entry[@"integrity"];
        Check([integrity[@"assetHashesVerified"] isEqual:@YES] && [integrity[@"signatureVerified"] isEqual:@NO],"folder hash/auth distinction");
        Check([integrity[@"exefsVerified"] isEqual:(raw ? @NO:@YES)] &&
            [integrity[@"romfsVerified"] isEqual:(raw ? @NO:@YES)] &&
            [integrity[@"romfsStructureVerified"] isEqual:(raw ? @YES:@NO)],"folder integrity distinction");
    }
    NSData *json=JSON(@{@"status":@"pass",@"entries":catalog.entries});
    fwrite(json.bytes,1,json.length,stdout);putchar('\n');
}
int main(int argc, char **argv) {
    @autoreleasepool {
        Check(argc==3,"arguments"); NSString *scenario=[NSString stringWithUTF8String:argv[1]];
        NSURL *root=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]] isDirectory:YES];
        if ([scenario isEqual:@"folder"]) { FolderCatalogScenario(root);return 0; }
        if ([scenario isEqual:@"settings"]) SettingsRoundtrip(root);
        else if ([scenario isEqual:@"options"]) Options(root);
        else if ([scenario isEqual:@"partial"]) Partial(root);
        else if ([scenario isEqual:@"late_corruption"] || [scenario isEqual:@"write_failure"]) Failure(root,[scenario isEqual:@"late_corruption"]);
        else if ([@[@"catalog",@"busy",@"catalog_limit",@"catalog_link"] containsObject:scenario]) CatalogScenario(root,scenario);
        else Invalid(root,scenario);
        puts("{\"status\":\"pass\"}"); return 0;
    }
}
