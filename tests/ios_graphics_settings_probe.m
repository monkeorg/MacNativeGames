#import "launcher_settings.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
int main(int argc,const char **argv) {
    @autoreleasepool {
        assert(argc==3);
        NSString *suite=@(argv[2]);
        NSUserDefaults *defaults=[[NSUserDefaults alloc] initWithSuiteName:suite];
        NSString *test=@(argv[1]);
        if ([test isEqual:@"defaults"]) {
            [defaults removePersistentDomainForName:suite];
            assert(TOTKLauncherFPSLimit(defaults)==60 && !TOTKLauncherTAA(defaults));
            assert(TOTKLauncherSceneScale(defaults)==100 && !TOTKLauncherSpatialUpscaling(defaults));
            assert(TOTKLauncherCustomSceneHeight(defaults)==0);
            for (id invalid in @[@YES,@0,@49,@101,@67.5,@"67",@[],@{},@(NAN),@(INFINITY)]) {
                [defaults setObject:invalid forKey:@"TOTK_LAUNCHER_SCENE_SCALE"];
                assert(TOTKLauncherSceneScale(defaults)==100);
                assert(![defaults objectForKey:@"TOTK_LAUNCHER_SCENE_SCALE"]);
            }
            for (NSString *key in @[@"TOTK_LAUNCHER_CUSTOM_HEIGHT",@"TOTK_LAUNCHER_CUSTOM_SCENE_HEIGHT"]) {
                for (id invalid in @[@YES,@0,@179,@361,@1082,@720.5,@"720",@[],@{},@(NAN),@(INFINITY)]) {
                    [defaults setObject:invalid forKey:key];
                    assert(TOTKLauncherRenderHeight(defaults)==720 && TOTKLauncherCustomSceneHeight(defaults)==0);
                    assert(![defaults objectForKey:key]);
                }
            }
            for (id invalid in @[@2,@(-1),@0.5,@"1",@[],@{},@(NAN),@(INFINITY)]) {
                [defaults setObject:invalid forKey:@"TOTK_LAUNCHER_SPATIAL_UPSCALING"];
                assert(!TOTKLauncherSpatialUpscaling(defaults));
                assert(![defaults objectForKey:@"TOTK_LAUNCHER_SPATIAL_UPSCALING"]);
            }
            for (id invalid in @[@YES,@0,@29,@45,@120,@(-30),@30.5,@"40",@[],@{},@(NAN),@(INFINITY)]) {
                [defaults setObject:invalid forKey:@"TOTK_LAUNCHER_FPS_LIMIT"];
                assert(TOTKLauncherFPSLimit(defaults)==60);
                assert([defaults objectForKey:@"TOTK_LAUNCHER_FPS_LIMIT"]==nil);
            }
            for (NSNumber *rate in @[@30,@40,@60]) {
                [defaults setObject:rate forKey:@"TOTK_LAUNCHER_FPS_LIMIT"];
                assert(TOTKLauncherFPSLimit(defaults)==rate.integerValue);
            }
            for (id invalid in @[@2,@(-1),@0.5,@"1",@[],@{},@(NAN),@(INFINITY)]) {
                [defaults setObject:invalid forKey:@"TOTK_LAUNCHER_TAA"];
                assert(!TOTKLauncherTAA(defaults));
                assert([defaults objectForKey:@"TOTK_LAUNCHER_TAA"]==nil);
            }
            for (NSNumber *enabled in @[@YES,@NO,@1,@0]) {
                [defaults setObject:enabled forKey:@"TOTK_LAUNCHER_TAA"];
                assert(TOTKLauncherTAA(defaults)==enabled.boolValue);
            }
            [defaults removePersistentDomainForName:suite];
        } else if ([test isEqual:@"dimensions"]) {
            [defaults removePersistentDomainForName:suite];
            unsigned w=99,h=77;
            assert(!TOTKLauncherSceneSize(defaults,1922,1080,&w,&h) && w==99 && h==77);
            assert(!TOTKLauncherSceneSize(defaults,1920,1082,&w,&h) && w==99 && h==77);
            assert(!TOTKLauncherSceneSize(defaults,1440,1080,NULL,&h));
            for (unsigned outW=1440;outW<=1920;outW+=480) {
                for (NSInteger scale=50;scale<=100;scale++) {
                    [defaults setInteger:scale forKey:@"TOTK_LAUNCHER_SCENE_SCALE"];
                    assert(TOTKLauncherSceneScale(defaults)==scale);
                    assert(TOTKLauncherSceneSize(defaults,outW,1080,&w,&h));
                    assert(!(w%2) && !(h%2) && w<=outW && h<=1080);
                    assert(fabs(w-outW*scale/100.0)<=1.001 && fabs(h-1080*scale/100.0)<=1.001);
                }
            }
            [defaults setInteger:50 forKey:@"TOTK_LAUNCHER_SCENE_SCALE"];
            assert(TOTKLauncherSceneSize(defaults,1440,1080,&w,&h) && w==720 && h==540);
            [defaults setInteger:720 forKey:@"TOTK_LAUNCHER_CUSTOM_SCENE_HEIGHT"];
            assert(TOTKLauncherSceneSize(defaults,1440,1080,&w,&h) && w==960 && h==720);
            [defaults setInteger:1080 forKey:@"TOTK_LAUNCHER_CUSTOM_SCENE_HEIGHT"];
            assert(TOTKLauncherSceneSize(defaults,1280,720,&w,&h) && w==1280 && h==720);
            [defaults setInteger:900 forKey:@"TOTK_LAUNCHER_CUSTOM_HEIGHT"];
            assert(TOTKLauncherRenderHeight(defaults)==900);
            BOOL full=NO;
            assert(TOTKLauncherDisplaySize(defaults,@{@"TOTKIOSDisplaySettingsVersion":@1},1366,1024,&w,&h,&full));
            assert(w==1600 && h==900 && !full);
            [defaults setObject:@"display" forKey:@"TOTK_LAUNCHER_ASPECT"];
            assert(TOTKLauncherDisplaySize(defaults,@{@"TOTKIOSDisplaySettingsVersion":@1},1366,1024,&w,&h,&full));
            assert(w==1200 && h==900 && full);
            [defaults removePersistentDomainForName:suite];
        } else if ([test isEqual:@"write"]) {
            [defaults setInteger:40 forKey:@"TOTK_LAUNCHER_FPS_LIMIT"];
            [defaults setBool:YES forKey:@"TOTK_LAUNCHER_TAA"];
            [defaults setInteger:67 forKey:@"TOTK_LAUNCHER_SCENE_SCALE"];
            [defaults setInteger:900 forKey:@"TOTK_LAUNCHER_CUSTOM_HEIGHT"];
            [defaults setInteger:600 forKey:@"TOTK_LAUNCHER_CUSTOM_SCENE_HEIGHT"];
            [defaults setBool:YES forKey:@"TOTK_LAUNCHER_SPATIAL_UPSCALING"];
            assert([defaults synchronize]);
        } else if ([test isEqual:@"read"]) {
            assert(TOTKLauncherFPSLimit(defaults)==40 && TOTKLauncherTAA(defaults));
            assert(TOTKLauncherSceneScale(defaults)==67 && TOTKLauncherSpatialUpscaling(defaults));
            assert(TOTKLauncherRenderHeight(defaults)==900 && TOTKLauncherCustomSceneHeight(defaults)==600);
            [defaults removePersistentDomainForName:suite];
            assert([defaults synchronize]);
        } else assert(!"unknown test");
        puts("PASS");
    }
}
