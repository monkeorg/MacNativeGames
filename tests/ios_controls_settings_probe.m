#import "launcher_settings.h"
#import "save_store.h"
#include "../games/totk/runtime/controller_map.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NSString *supportRoot;
NSArray<NSString *> *TOTKControlsProbeSearchPath(NSSearchPathDirectory directory,
                                                NSSearchPathDomainMask mask, BOOL expand) {
    assert(directory==NSApplicationSupportDirectory && mask==NSUserDomainMask && expand);
    return @[supportRoot];
}
static NSURL *child(NSURL *root, NSString *name) { return [root URLByAppendingPathComponent:name]; }
static void directory(NSURL *url) {
    assert([NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:NULL]);
}
static void writeText(NSURL *url, NSString *text) {
    assert([text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
}
static NSString *readText(NSURL *url) {
    NSString *text=[NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL];
    assert(text); return text;
}
static void absentEnvironment(void) {
    assert(!getenv("TOTK_CONTROLS") && !getenv("TOTK_MOUSE_SENSITIVITY") && !getenv("TOTK_MOUSE_INVERT_Y"));
}
static void parse(NSURL *url,uint16_t map[CONTROLLER_BUTTONS],uint8_t modes[CONTROLLER_BUTTONS]) {
    controller_map_default(map,modes); const char *problem=NULL;
    assert(controller_map_parse(readText(url).UTF8String,map,modes,&problem)==0);
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        assert(argc==4); NSString *scenario=@(argv[1]);
        supportRoot=@(argv[2]); NSURL *root=[NSURL fileURLWithPath:supportRoot isDirectory:YES];
        NSString *suite=@(argv[3]); NSUserDefaults *d=[[NSUserDefaults alloc] initWithSuiteName:suite];
        [d removePersistentDomainForName:suite]; absentEnvironment();
        NSURL *controlsDirectory=child(root,@"LauncherControls");
        NSURL *controls=child(controlsDirectory,@"controls.txt");
        NSURL *type=child(controlsDirectory,@"controller-type.txt");
        if ([scenario isEqual:@"values"]) {
            assert(TOTKLauncherMouseSensitivity(d)==50 && !TOTKLauncherMouseInvertY(d));
            for (NSNumber *value in @[@1,@50,@100]) {
                [d setObject:value forKey:@"TOTK_LAUNCHER_MOUSE_SENSITIVITY"];
                assert(TOTKLauncherMouseSensitivity(d)==value.integerValue);
            }
            for (id value in @[@YES,@0,@101,@(-1),@1.5,@"50",@[],@{},@(NAN),@(INFINITY)]) {
                [d setObject:value forKey:@"TOTK_LAUNCHER_MOUSE_SENSITIVITY"];
                assert(TOTKLauncherMouseSensitivity(d)==50);
                assert(![d objectForKey:@"TOTK_LAUNCHER_MOUSE_SENSITIVITY"]);
            }
            for (id value in @[@2,@(-1),@0.5,@"1",@[],@{},@(NAN),@(INFINITY)]) {
                [d setObject:value forKey:@"TOTK_LAUNCHER_MOUSE_INVERT_Y"];
                assert(!TOTKLauncherMouseInvertY(d)); assert(![d objectForKey:@"TOTK_LAUNCHER_MOUSE_INVERT_Y"]);
            }
            for (NSNumber *value in @[@YES,@NO,@1,@0]) {
                [d setObject:value forKey:@"TOTK_LAUNCHER_MOUSE_INVERT_Y"];
                assert(TOTKLauncherMouseInvertY(d)==value.boolValue);
            }
            [d setInteger:73 forKey:@"TOTK_LAUNCHER_MOUSE_SENSITIVITY"];
            [d setBool:YES forKey:@"TOTK_LAUNCHER_MOUSE_INVERT_Y"];
            assert(TOTKLauncherPrepareControls(d,NULL)); absentEnvironment();
            TOTKLauncherApplyControls(d);
            assert(!strcmp(getenv("TOTK_MOUSE_SENSITIVITY"),"73"));
            assert(!strcmp(getenv("TOTK_MOUSE_INVERT_Y"),"1")); assert(!getenv("TOTK_CONTROLS"));
        } else if ([scenario isEqual:@"types"]) {
            for (NSString *value in @[@"auto",@"xbox",@"playstation",@"switch"]) {
                [d setObject:value forKey:@"TOTK_LAUNCHER_CONTROLLER_TYPE"];
                assert([TOTKLauncherControllerType(d) isEqual:value]);
            }
            for (id value in @[@"Xbox",@"",@1,@[],@{}]) {
                [d setObject:value forKey:@"TOTK_LAUNCHER_CONTROLLER_TYPE"];
                assert([TOTKLauncherControllerType(d) isEqual:@"auto"]);
                assert(![d objectForKey:@"TOTK_LAUNCHER_CONTROLLER_TYPE"]);
            }
            for (id value in @[@"A",@"south",@"a\nmouse_left = b",@1,@[],@{}]) {
                [d setObject:value forKey:@"TOTK_LAUNCHER_BIND_south"];
                assert([TOTKLauncherControlBinding(d,@"south") isEqual:@"default"]);
                assert(![d objectForKey:@"TOTK_LAUNCHER_BIND_south"]);
            }
            assert([TOTKLauncherControlBinding(d,@"unknown") isEqual:@"default"]);
        } else if ([scenario isEqual:@"defaults"]) {
            assert(TOTKLauncherPrepareControls(d,NULL)); absentEnvironment();
            assert(![NSFileManager.defaultManager fileExistsAtPath:controlsDirectory.path]);
            TOTKLauncherApplyControls(d); assert(!getenv("TOTK_CONTROLS"));
            assert(!strcmp(getenv("TOTK_MOUSE_SENSITIVITY"),"50") && !strcmp(getenv("TOTK_MOUSE_INVERT_Y"),"0"));
            assert([TOTKLauncherControlBindingTitle(d,@"south") isEqual:@"Default: B"]);
            assert([TOTKLauncherControlBindingTitle(d,@"mouse_right") isEqual:@"Default: ZR (aim/fire)"]);
        } else if ([scenario isEqual:@"mapping"]) {
            [d setObject:@"default" forKey:@"TOTK_LAUNCHER_BIND_south"];
            [d setObject:@"none" forKey:@"TOTK_LAUNCHER_BIND_east"];
            [d setObject:@"a" forKey:@"TOTK_LAUNCHER_BIND_mouse_left"];
            [d setObject:@"plus" forKey:@"TOTK_LAUNCHER_BIND_mouse5"];
            [d setObject:@"playstation" forKey:@"TOTK_LAUNCHER_CONTROLLER_TYPE"];
            assert(TOTKLauncherPrepareControls(d,NULL)); absentEnvironment();
            uint16_t map[CONTROLLER_BUTTONS]; uint8_t modes[CONTROLLER_BUTTONS]; parse(controls,map,modes);
            assert(map[0]==(1u<<1) && modes[0]==CONTROLLER_HOLD && map[1]==0);
            assert(map[17]==1 && modes[17]==CONTROLLER_HOLD && map[21]==(1u<<10));
            assert(map[18]==(1u<<9) && controller_mode_kind(modes[18])==CONTROLLER_AIM && controller_mode_fire(modes[18])==17);
            assert(controller_map_apply(map,(UINT64_C(1)<<1)|(UINT64_C(1)<<17))==1);
            assert([TOTKLauncherControlBindingTitle(d,@"east") isEqual:@"None"]);
            assert([TOTKLauncherControlBindingTitle(d,@"mouse5") isEqual:@"PLUS"]);
            assert([readText(type) isEqual:@"playstation\n"]);
            TOTKLauncherApplyControls(d); assert(!strcmp(getenv("TOTK_CONTROLS"),controls.path.fileSystemRepresentation));
        } else if ([scenario isEqual:@"type-only"]) {
            for (NSString *value in @[@"xbox",@"playstation",@"switch"]) {
                [d setObject:value forKey:@"TOTK_LAUNCHER_CONTROLLER_TYPE"];
                assert(TOTKLauncherPrepareControls(d,NULL)); assert([readText(controls) isEqual:@""]);
                assert([readText(type) isEqual:[value stringByAppendingString:@"\n"]]);
            }
            [d setObject:@"auto" forKey:@"TOTK_LAUNCHER_CONTROLLER_TYPE"];
            assert(TOTKLauncherPrepareControls(d,NULL)); TOTKLauncherApplyControls(d);
            assert(!getenv("TOTK_CONTROLS")); // Stale files are not selected on the next launch.
        } else if ([scenario isEqual:@"override"]) {
            NSURL *external=child(root,@"developer.txt"); writeText(external,@"mouse_right = zr aim mouse_left\n");
            NSData *before=[NSData dataWithContentsOfURL:external];
            assert(setenv("TOTK_CONTROLS",external.path.fileSystemRepresentation,1)==0);
            assert(setenv("TOTK_MOUSE_SENSITIVITY","19",1)==0 && setenv("TOTK_MOUSE_INVERT_Y","0",1)==0);
            [d setObject:@"none" forKey:@"TOTK_LAUNCHER_BIND_mouse_right"];
            [d setInteger:90 forKey:@"TOTK_LAUNCHER_MOUSE_SENSITIVITY"];
            [d setBool:YES forKey:@"TOTK_LAUNCHER_MOUSE_INVERT_Y"];
            assert(TOTKLauncherPrepareControls(d,NULL)); TOTKLauncherApplyControls(d);
            assert(!strcmp(getenv("TOTK_CONTROLS"),external.path.fileSystemRepresentation));
            assert(!strcmp(getenv("TOTK_MOUSE_SENSITIVITY"),"19") && !strcmp(getenv("TOTK_MOUSE_INVERT_Y"),"0"));
            assert([[NSData dataWithContentsOfURL:external] isEqual:before]);
            assert(![NSFileManager.defaultManager fileExistsAtPath:controlsDirectory.path]);
        } else {
            BOOL companion=[scenario isEqual:@"companion-failure"];
            assert(companion || [scenario isEqual:@"directory-failure"]);
            TOTKSaveStore *store=[[TOTKSaveStore alloc] initWithActiveURL:child(root,@"NoSave") backupsURL:child(root,@"NoBackups")];
            [d setObject:@"none" forKey:@"TOTK_LAUNCHER_BIND_south"];
            if (companion) { directory(controlsDirectory); directory(type); }
            else writeText(controlsDirectory,@"blocked directory\n");
            NSError *error=nil;
            assert(!TOTKLauncherPrepareControls(d,&error) && error); absentEnvironment();
            assert([store backups:NULL]!=nil); // Preparation failure leaves the actual save store unsealed.
            NSURL *blocker=companion ? type : controlsDirectory;
            assert([NSFileManager.defaultManager removeItemAtURL:blocker error:NULL]);
            error=nil; assert(TOTKLauncherPrepareControls(d,&error)); absentEnvironment();
            uint16_t map[CONTROLLER_BUTTONS]; uint8_t modes[CONTROLLER_BUTTONS]; parse(controls,map,modes); assert(map[0]==0);
            assert([readText(type) isEqual:@"auto\n"]);
            assert([store sealForPlay]); TOTKLauncherApplyControls(d);
            assert(![store sealForPlay] && [store backups:NULL]==nil);
            assert(!strcmp(getenv("TOTK_CONTROLS"),controls.path.fileSystemRepresentation));
            assert(![NSFileManager.defaultManager fileExistsAtPath:child(root,@"NoSave").path]);
            assert(![NSFileManager.defaultManager fileExistsAtPath:child(root,@"NoBackups").path]);
        }
        [d removePersistentDomainForName:suite]; puts("PASS");
    }
}
