#import <Foundation/Foundation.h>
#import "save_store.h"
#import "launcher_settings.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sandbox.h>
#include <errno.h>
#include <pthread.h>
#include <math.h>
#include <dirent.h>

/* save_store.o alone redirects readdir here. Remove an optional file between
 * its directory fstat and enumeration, so a missing entry cannot look complete. */
static BOOL changeDirectory, changedDirectory;
static dev_t changingDevice;
static ino_t changingInode;
struct dirent *TOTKProbeReadDirectory(DIR *directory) {
    struct stat st;
    if (changeDirectory && !fstat(dirfd(directory),&st) &&
        st.st_dev == changingDevice && st.st_ino == changingInode) {
        changeDirectory = NO;
        changedDirectory = unlinkat(dirfd(directory),"binary.bin",0) == 0;
        /* Ensure a distinct timestamp even on a coarse-resolution volume. */
        struct timespec times[2] = {st.st_atimespec, st.st_mtimespec};
        times[1].tv_sec++;
        if (futimens(dirfd(directory),times)) changedDirectory = NO;
    }
    return readdir(directory);
}

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr,"%s:%d: %s\n",__FILE__,__LINE__,#condition); return 1; } } while (0)

static NSURL *child(NSURL *root, NSString *name) {
    return [root URLByAppendingPathComponent:name];
}
static void writeFile(NSURL *url, NSString *value) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL] ||
        ![[value dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url options:NSDataWritingAtomic error:NULL]) abort();
}
/* These are synthetic byte strings, never game save content. */
static void makeSave(NSURL *root, NSString *tag) {
    for (NSString *slot in @[@"slot_00",@"slot_03",@"slot_05"]) {
        for (NSString *file in @[@"progress.sav",@"caption.sav",@"footprint.sav",@"direct_file_save_related.sav",@"extra.bin"]) {
            writeFile(child(child(root,slot),file),[NSString stringWithFormat:@"%@:%@:%@",tag,slot,file]);
        }
    }
    writeFile(child(root,@"system/nested/extra.bin"),tag);
    writeFile(child(root,@"empty.bin"),@"");
    const unsigned char bytes[] = {0, 1, 127, 128, 254, 255, 0};
    if (![[NSData dataWithBytes:bytes length:sizeof bytes] writeToURL:child(root,@"binary.bin") options:0 error:NULL]) abort();
}
static NSDictionary *snapshot(NSURL *root) {
    root = root.URLByResolvingSymlinksInPath;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    NSDirectoryEnumerator *walk = [fm enumeratorAtPath:root.path];
    for (NSString *relative in walk) {
        NSURL *url = child(root,relative);
        BOOL directory = NO;
        [fm fileExistsAtPath:url.path isDirectory:&directory];
        files[relative] = directory ? (id)@"directory" : [NSData dataWithContentsOfURL:url];
    }
    return files;
}
static int displaySizes(NSUserDefaults *defaults) {
    NSDictionary *capable = @{@"TOTKIOSDisplaySettingsVersion":@1};
    unsigned width = 7, height = 9;
    BOOL full = YES;
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_RENDER_HEIGHT"];
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_ASPECT"];
    CHECK(TOTKLauncherDisplaySize(defaults,capable,4,3,&width,&height,&full));
    CHECK(width == 1280 && height == 720 && !full);
    const struct { double viewW,viewH; NSInteger height; BOOL requestedFull; unsigned w,h; BOOL full; } cases[] = {
        {4,3,1080,YES,1440,1080,YES},
        {3,4,1080,YES,1440,1080,YES},
        {2360,1640,1080,YES,1554,1080,YES},
        {4,3,720,YES,960,720,YES},
        {1920,1080,1080,YES,1920,1080,YES},
        {2532,1170,1080,YES,1920,1080,NO},
        {1170,2532,720,YES,1280,720,NO},
        {1920,1080,720,NO,1280,720,NO},
        {4,3,1080,NO,1920,1080,NO},
        {1,1,1080,YES,1080,1080,YES}
    };
    for (unsigned i=0; i<sizeof cases/sizeof *cases; i++) {
        [defaults setInteger:cases[i].height forKey:@"TOTK_LAUNCHER_RENDER_HEIGHT"];
        [defaults setObject:cases[i].requestedFull ? @"display" : @"16:9" forKey:@"TOTK_LAUNCHER_ASPECT"];
        CHECK(TOTKLauncherDisplaySize(defaults,capable,cases[i].viewW,cases[i].viewH,&width,&height,&full));
        CHECK(width == cases[i].w && height == cases[i].h && full == cases[i].full);
        CHECK(width % 2 == 0 && height % 2 == 0 && width <= 1920 && height <= 1080);
    }
    width = 7; height = 9; full = YES;
    CHECK(!TOTKLauncherDisplaySize(defaults,@{},4,3,&width,&height,&full));
    CHECK(width == 7 && height == 9 && full);
    const double invalid[] = {0,-1,NAN,INFINITY,-INFINITY};
    for (unsigned i=0; i<sizeof invalid/sizeof *invalid; i++) {
        CHECK(!TOTKLauncherDisplaySize(defaults,capable,invalid[i],3,&width,&height,&full));
        CHECK(!TOTKLauncherDisplaySize(defaults,capable,4,invalid[i],&width,&height,&full));
        CHECK(width == 7 && height == 9 && full);
    }
    CHECK(!TOTKLauncherDisplaySize(defaults,capable,4,3,NULL,&height,&full));
    CHECK(!TOTKLauncherDisplaySize(defaults,capable,4,3,&width,NULL,&full));
    CHECK(width == 7 && height == 9 && full);
    CHECK(TOTKLauncherDisplaySize(defaults,capable,4,3,&width,&height,NULL));
    CHECK(width == 1440 && height == 1080);
    [defaults setObject:@"invalid" forKey:@"TOTK_LAUNCHER_RENDER_HEIGHT"];
    [defaults setObject:@"invalid" forKey:@"TOTK_LAUNCHER_ASPECT"];
    CHECK(TOTKLauncherDisplaySize(defaults,capable,4,3,&width,&height,&full));
    CHECK(width == 1280 && height == 720 && !full);
    CHECK(![defaults objectForKey:@"TOTK_LAUNCHER_RENDER_HEIGHT"]);
    CHECK(![defaults objectForKey:@"TOTK_LAUNCHER_ASPECT"]);
    return 0;
}
static int settings(NSString *scenario, NSURL *root) {
    NSString *suite = [@"org.macnativegames.save-probe." stringByAppendingString:[NSString stringWithFormat:@"%@.%@",root.URLByDeletingLastPathComponent.lastPathComponent,root.lastPathComponent]];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    if ([scenario isEqual:@"settings_clean"]) {
        [defaults removePersistentDomainForName:suite];
        CHECK([defaults synchronize]);
        return 0;
    }
    if ([scenario isEqual:@"settings_write"]) {
        [defaults setObject:@"de" forKey:@"TOTK_LANG"];
        [defaults setInteger:2 forKey:@"TOTK_LAUNCHER_HUD"];
        [defaults setBool:NO forKey:@"TOTK_LAUNCHER_TOUCH"];
        [defaults setBool:YES forKey:@"TOTK_LAUNCHER_METAL_HUD"];
        [defaults setInteger:1080 forKey:@"TOTK_LAUNCHER_RENDER_HEIGHT"];
        [defaults setObject:@"display" forKey:@"TOTK_LAUNCHER_ASPECT"];
        CHECK([defaults synchronize]);
    } else if ([scenario isEqual:@"settings_read"]) {
        CHECK([TOTKLauncherLanguage(defaults) isEqual:@"de"]);
        CHECK(TOTKLauncherHUD(defaults) == 2);
        CHECK(!TOTKLauncherTouch(defaults));
        CHECK(TOTKLauncherMetalHUD(defaults));
        CHECK(TOTKLauncherRenderHeight(defaults) == 1080);
        CHECK([TOTKLauncherAspect(defaults) isEqual:@"display"]);
        unsigned width = 0, height = 0; BOOL full = NO;
        CHECK(TOTKLauncherDisplaySize(defaults,@{@"TOTKIOSDisplaySettingsVersion":@1},4,3,&width,&height,&full));
        CHECK(width == 1440 && height == 1080 && full);
    } else {
        [defaults removePersistentDomainForName:suite];
        CHECK([TOTKLauncherLanguage(defaults) isEqual:@""]);
        CHECK(TOTKLauncherHUD(defaults) == 1);
        CHECK(TOTKLauncherTouch(defaults));
        CHECK(!TOTKLauncherMetalHUD(defaults));
        CHECK(TOTKLauncherRenderHeight(defaults) == 720);
        CHECK([TOTKLauncherAspect(defaults) isEqual:@"16:9"]);
        for (id value in @[@"invalid",@42,@[],@{},@0.5]) {
            [defaults setObject:value forKey:@"TOTK_LANG"];
            CHECK([TOTKLauncherLanguage(defaults) isEqual:@""]);
            CHECK(![defaults objectForKey:@"TOTK_LANG"]);
            [defaults setObject:value forKey:@"TOTK_LAUNCHER_HUD"];
            CHECK(TOTKLauncherHUD(defaults) == 1);
            CHECK(![defaults objectForKey:@"TOTK_LAUNCHER_HUD"]);
            [defaults setObject:value forKey:@"TOTK_LAUNCHER_TOUCH"];
            CHECK(TOTKLauncherTouch(defaults));
            CHECK(![defaults objectForKey:@"TOTK_LAUNCHER_TOUCH"]);
            [defaults setObject:value forKey:@"TOTK_LAUNCHER_METAL_HUD"];
            CHECK(!TOTKLauncherMetalHUD(defaults));
            CHECK(![defaults objectForKey:@"TOTK_LAUNCHER_METAL_HUD"]);
            [defaults setObject:value forKey:@"TOTK_LAUNCHER_RENDER_HEIGHT"];
            CHECK(TOTKLauncherRenderHeight(defaults) == 720);
            CHECK(![defaults objectForKey:@"TOTK_LAUNCHER_RENDER_HEIGHT"]);
            [defaults setObject:value forKey:@"TOTK_LAUNCHER_ASPECT"];
            CHECK([TOTKLauncherAspect(defaults) isEqual:@"16:9"]);
            CHECK(![defaults objectForKey:@"TOTK_LAUNCHER_ASPECT"]);
        }
        for (NSString *language in TOTKLanguages()) {
            [defaults setObject:language forKey:@"TOTK_LANG"];
            CHECK([TOTKLauncherLanguage(defaults) isEqual:language]);
        }
        for (NSNumber *hud in @[@0,@1,@2]) {
            [defaults setObject:hud forKey:@"TOTK_LAUNCHER_HUD"];
            CHECK(TOTKLauncherHUD(defaults) == hud.integerValue);
        }
        for (NSNumber *enabled in @[@NO,@YES]) {
            [defaults setObject:enabled forKey:@"TOTK_LAUNCHER_METAL_HUD"];
            CHECK(TOTKLauncherMetalHUD(defaults) == enabled.boolValue);
        }
        for (NSNumber *height in @[@720,@1080]) {
            [defaults setObject:height forKey:@"TOTK_LAUNCHER_RENDER_HEIGHT"];
            CHECK(TOTKLauncherRenderHeight(defaults) == height.integerValue);
        }
        for (NSString *aspect in @[@"16:9",@"display"]) {
            [defaults setObject:aspect forKey:@"TOTK_LAUNCHER_ASPECT"];
            CHECK([TOTKLauncherAspect(defaults) isEqual:aspect]);
        }
        for (id height in @[@0,@719,@721,@1081,@720.5,@"1080",@YES,@NO]) {
            [defaults setObject:height forKey:@"TOTK_LAUNCHER_RENDER_HEIGHT"];
            CHECK(TOTKLauncherRenderHeight(defaults) == 720);
            CHECK(![defaults objectForKey:@"TOTK_LAUNCHER_RENDER_HEIGHT"]);
        }
        for (NSString *aspect in @[@"4:3",@"auto",@"DISPLAY",@""]) {
            [defaults setObject:aspect forKey:@"TOTK_LAUNCHER_ASPECT"];
            CHECK([TOTKLauncherAspect(defaults) isEqual:@"16:9"]);
            CHECK(![defaults objectForKey:@"TOTK_LAUNCHER_ASPECT"]);
        }
        CHECK(!TOTKLauncherDisplaySettingsAvailable(@{}));
        CHECK(TOTKLauncherDisplaySettingsAvailable(@{@"TOTKIOSDisplaySettingsVersion":@1}));
        for (id version in @[@0,@2,@1.5,@YES,@NO,@"1",@[],@{},NSNull.null]) {
            CHECK(!TOTKLauncherDisplaySettingsAvailable(@{@"TOTKIOSDisplaySettingsVersion":version}));
        }
        CHECK(displaySizes(defaults) == 0);
        [defaults removePersistentDomainForName:suite];
        CHECK([defaults synchronize]);
    }
    return 0;
}
static BOOL applySandbox(const char *profile) {
    char *error = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    int result = sandbox_init(profile,0,&error);
    if (result) fprintf(stderr,"sandbox_init: %s\n",error ?: "unknown error");
    if (error) sandbox_free_error(error);
#pragma clang diagnostic pop
    return result == 0;
}
static int probe(NSString *scenario, NSURL *root) {
    if ([scenario hasPrefix:@"settings_"]) return settings(scenario,root);
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *profile = child(root,@"profile");
    NSURL *active = child(profile,@"save");
    NSURL *backups = child(root,@"backups");
    NSURL *source = child(root,@"source");
    NSURL *output = child(root,@"output");
    makeSave(active,@"original");
    makeSave(source,@"replacement");
    writeFile(child(profile,@"account.uid"),@"keep-account-identity");
    CHECK([fm createDirectoryAtURL:output withIntermediateDirectories:YES attributes:nil error:NULL]);
    TOTKSaveStore *store = [[TOTKSaveStore alloc] initWithActiveURL:active backupsURL:backups];
    NSDictionary *original = snapshot(active);
    NSError *error = nil;
    CHECK([store backups:&error].count == 0);
    if ([scenario isEqual:@"sandbox_roundtrip"]) {
        // Apply after Foundation loads; a launch-time restriction prevents dyld from loading.
        CHECK(applySandbox("(version 1)(allow default)(deny file-read-data (literal \"/\"))"));
        errno = 0;
        int ancestor = open("/",O_RDONLY | O_DIRECTORY);
        CHECK(ancestor < 0 && errno == EPERM);
        int selected = open(active.fileSystemRepresentation,O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY);
        CHECK(selected >= 0);
        close(selected);
        scenario = @"roundtrip";
    }
    if ([scenario isEqual:@"provider_read_refused"] || [scenario isEqual:@"export_read_refused"]) {
        BOOL exporting = [scenario isEqual:@"export_read_refused"];
        NSURL *restricted = child(exporting ? active : source,@"slot_03/caption.sav");
        NSString *policy = [NSString stringWithFormat:@"(version 1)(allow default)(deny file-read-data (literal \"%@\"))",restricted.path];
        CHECK(applySandbox(policy.UTF8String));
        if (exporting) {
            CHECK(![store exportToDirectory:output error:&error]);
            CHECK(![fm fileExistsAtPath:child(output,@"TOTK Save").path]);
        } else CHECK(![store importDirectory:source error:&error]);
        CHECK(error);
        /* Metadata remains readable; no active bytes are changed by either operation. */
        CHECK([fm fileExistsAtPath:restricted.path]);
        if (!exporting) CHECK([snapshot(active) isEqual:original]);
        CHECK([store backups:NULL].count == 0);
        for (NSString *name in [fm contentsOfDirectoryAtPath:profile.path error:NULL]) CHECK(![name hasPrefix:@".import-"]);
    } else if ([scenario isEqual:@"backup_refused"] || [scenario isEqual:@"publish_refused"]) {
        BOOL publish = [scenario isEqual:@"publish_refused"];
        NSURL *restricted = publish ? active : backups;
        NSString *policy = [NSString stringWithFormat:@"(version 1)(allow default)(deny %@ (%@ \"%@\"))",
            publish ? @"file-write-unlink" : @"file-write-create",publish ? @"literal" : @"subpath",restricted.path];
        CHECK(applySandbox(policy.UTF8String));
        CHECK(![store importDirectory:source error:&error]);
        CHECK(error);
        CHECK([snapshot(active) isEqual:original]);
        NSArray<NSURL *> *saved = [store backups:NULL];
        CHECK(saved.count == (publish ? 1u : 0u));
        if (publish) {
            CHECK([error.localizedDescription isEqual:@"Cannot publish the save. Your previous save is unchanged."]);
            CHECK([snapshot(saved.firstObject) isEqual:original]);
        }
        for (NSString *name in [fm contentsOfDirectoryAtPath:profile.path error:NULL]) CHECK(![name hasPrefix:@".import-"]);
    } else if ([scenario isEqual:@"first_import"]) {
        CHECK([fm removeItemAtURL:active error:NULL]);
        CHECK([store importDirectory:source error:&error]);
        CHECK([snapshot(active) isEqual:snapshot(source)]);
        CHECK([store backups:&error].count == 0);
    } else if ([scenario isEqual:@"roundtrip"]) {
        NSURL *backup = [store backup:&error];
        CHECK(backup && !error);
        CHECK([snapshot(backup) isEqual:original]);
        CHECK([store importDirectory:source error:&error]);
        CHECK([snapshot(active) isEqual:snapshot(source)]);
        CHECK([store backups:&error].count == 2);
        NSURL *exported = [store exportToDirectory:output error:&error];
        CHECK(exported && [snapshot(exported) isEqual:snapshot(source)]);
        CHECK(![store exportToDirectory:output error:&error]);
        CHECK([snapshot(exported) isEqual:snapshot(source)]);
        error = nil;
        BOOL restored = [store restore:backup error:&error];
        if (!restored) fprintf(stderr,"restore: %s\n",error.localizedDescription.UTF8String);
        CHECK(restored);
        CHECK([snapshot(active) isEqual:original]);
        CHECK([store backups:&error].count == 3);
        CHECK(![snapshot(exported).allKeys containsObject:@"account.uid"]);
    } else if ([scenario isEqual:@"sealed"]) {
        NSURL *backup = [store backup:&error];
        CHECK(backup);
        CHECK([store sealForPlay]);
        CHECK(![store sealForPlay]);
        error = nil; CHECK(![store backup:&error] && error);
        error = nil; CHECK(![store backups:&error] && error);
        error = nil; CHECK(![store exportToDirectory:output error:&error] && error);
        error = nil; CHECK(![store importDirectory:source error:&error] && error);
        error = nil; CHECK(![store restore:backup error:&error] && error);
        CHECK([snapshot(active) isEqual:original]);
    } else if ([scenario isEqual:@"external_restore"]) {
        CHECK(![store restore:source error:&error] && error);
        CHECK([snapshot(active) isEqual:original]);
    } else {
        if ([scenario isEqual:@"ancestor_source"]) {
            source = profile;
        } else if ([scenario isEqual:@"directory_changed"]) {
            struct stat st;
            CHECK(stat(source.fileSystemRepresentation,&st) == 0);
            changingDevice = st.st_dev;
            changingInode = st.st_ino;
            changeDirectory = YES;
        } else if ([scenario isEqual:@"empty"]) {
            CHECK([fm removeItemAtURL:source error:NULL]);
            CHECK([fm createDirectoryAtURL:source withIntermediateDirectories:NO attributes:nil error:NULL]);
        } else if ([scenario isEqual:@"incomplete"]) {
            CHECK([fm removeItemAtURL:child(source,@"slot_03/caption.sav") error:NULL]);
        } else if ([scenario isEqual:@"invalid_slot"]) {
            writeFile(child(source,@"slot_06/progress.sav"),@"invalid");
        } else if ([scenario isEqual:@"account"]) {
            writeFile(child(source,@"account.uid"),@"refused");
        } else if ([scenario isEqual:@"zero_required"]) {
            writeFile(child(source,@"slot_00/progress.sav"),@"");
        } else if ([scenario isEqual:@"oversize"]) {
            int fd = open(child(source,@"oversize.bin").fileSystemRepresentation,O_WRONLY|O_CREAT,0600);
            CHECK(fd >= 0);
            CHECK(ftruncate(fd,64LL*1024*1024+1) == 0);
            close(fd);
        } else if ([scenario isEqual:@"deep"]) {
            NSURL *nested = source;
            for (int n = 0; n < 14; n++) nested = child(nested,@"nested");
            writeFile(child(nested,@"extra.bin"),@"too-deep");
        } else if ([scenario isEqual:@"symlink"]) {
            CHECK(symlink(child(profile,@"account.uid").fileSystemRepresentation,child(source,@"linked.bin").fileSystemRepresentation) == 0);
        } else if ([scenario isEqual:@"hardlink"]) {
            CHECK(link(child(profile,@"account.uid").fileSystemRepresentation,child(source,@"linked.bin").fileSystemRepresentation) == 0);
        } else if ([scenario isEqual:@"root_symlink"]) {
            NSURL *alias = child(root,@"alias");
            CHECK(symlink(source.fileSystemRepresentation,alias.fileSystemRepresentation) == 0);
            source = alias;
        } else if ([scenario isEqual:@"ancestor_symlink"]) {
            NSURL *alias = child(root,@"alias");
            CHECK(symlink(root.fileSystemRepresentation,alias.fileSystemRepresentation) == 0);
            source = child(alias,@"source");
        } else if ([scenario isEqual:@"fifo"]) {
            CHECK(mkfifo(child(source,@"pipe").fileSystemRepresentation,0600) == 0);
        } else CHECK(NO);
        CHECK(![store importDirectory:source error:&error]);
        CHECK(error);
        if ([scenario isEqual:@"directory_changed"]) CHECK(changedDirectory);
        if ([scenario isEqual:@"ancestor_source"]) {
            CHECK([error.localizedDescription isEqual:@"Select the console save folder, not a folder containing this app's save storage."]);
        }
        CHECK([snapshot(active) isEqual:original]);
        CHECK([store backups:NULL].count == 0);
        for (NSString *name in [fm contentsOfDirectoryAtPath:profile.path error:NULL]) CHECK(![name hasPrefix:@".import-"]);
    }
    CHECK([[NSData dataWithContentsOfURL:child(profile,@"account.uid")] isEqual:[@"keep-account-identity" dataUsingEncoding:NSUTF8StringEncoding]]);
    return 0;
}
typedef struct { const char *root; int result; } SmallStackProbe;
static void *smallStackRoundtrip(void *context) {
    SmallStackProbe *run = context;
    @autoreleasepool {
        run->result = probe(@"roundtrip",[NSURL fileURLWithPath:[NSString stringWithUTF8String:run->root]]);
    }
    return NULL;
}
static int runSmallStackRoundtrip(const char *root) {
    pthread_attr_t attributes;
    pthread_t thread;
    SmallStackProbe run = {root,1};
    CHECK(pthread_attr_init(&attributes) == 0);
    CHECK(pthread_attr_setstacksize(&attributes,128 * 1024) == 0);
    fprintf(stderr,"roundtrip pthread stack: 131072 bytes\n");
    CHECK(pthread_create(&thread,&attributes,smallStackRoundtrip,&run) == 0);
    CHECK(pthread_attr_destroy(&attributes) == 0);
    CHECK(pthread_join(thread,NULL) == 0);
    return run.result;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        int result = !strcmp(argv[1],"small_stack_roundtrip") ? runSmallStackRoundtrip(argv[2]) :
            probe([NSString stringWithUTF8String:argv[1]], [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]]);
        if (!result) puts("{\"status\":\"pass\"}");
        return result;
    }
}
