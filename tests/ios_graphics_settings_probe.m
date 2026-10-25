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
            assert(TOTKLauncherDrawableCount(defaults)==3);
            for (id invalid in @[@YES,@0,@1,@4,@2.5,@"2",@[],@{},@(NAN),@(INFINITY)]) {
                [defaults setObject:invalid forKey:@"TOTK_LAUNCHER_DRAWABLE_COUNT"];
                assert(TOTKLauncherDrawableCount(defaults)==3);
                assert(![defaults objectForKey:@"TOTK_LAUNCHER_DRAWABLE_COUNT"]);
            }
            for (NSNumber *count in @[@2,@3]) {
                [defaults setObject:count forKey:@"TOTK_LAUNCHER_DRAWABLE_COUNT"];
                assert(TOTKLauncherDrawableCount(defaults)==count.integerValue);
            }
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
            for (NSNumber *rate in TOTKLauncherFPSLimits()) {
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
        } else if ([test isEqual:@"plans"]) {
            [defaults removePersistentDomainForName:suite];
            NSDictionary *info=@{@"TOTKIOSDisplaySettingsVersion":@1};
            [defaults setObject:@"display" forKey:@"TOTK_LAUNCHER_ASPECT"];
            [defaults setObject:@"1440" forKey:@"TOTK_LAUNCHER_DISPLAY_OUTPUT"];
            TOTKGraphicsPlan plan;
            assert(TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan));
            assert(plan.inputWidth==960 && plan.inputHeight==720 && plan.displayWidth==1920 && plan.displayHeight==1440);
            [defaults setObject:@"native" forKey:@"TOTK_LAUNCHER_DISPLAY_OUTPUT"];
            [defaults setInteger:1080 forKey:@"TOTK_LAUNCHER_RENDER_HEIGHT"];
            assert(TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan));
            assert(plan.inputWidth==1440 && plan.inputHeight==1080 && plan.displayWidth==2752 && plan.displayHeight==2064);
            [defaults setObject:@"input-scale" forKey:@"TOTK_LAUNCHER_RESOLUTION_MODE"];
            [defaults setInteger:720 forKey:@"TOTK_LAUNCHER_RENDER_HEIGHT"];
            [defaults setDouble:2 forKey:@"TOTK_LAUNCHER_UPSCALE_FACTOR"];
            assert(TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan));
            assert(plan.inputWidth==960 && plan.inputHeight==720 && plan.displayWidth==1920 && plan.displayHeight==1440);
            [defaults setObject:@"output-scale" forKey:@"TOTK_LAUNCHER_RESOLUTION_MODE"];
            assert(TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan));
            assert(plan.inputWidth==1376 && plan.inputHeight==1032 && plan.displayWidth==2752 && plan.displayHeight==2064);
            [defaults setDouble:1 forKey:@"TOTK_LAUNCHER_UPSCALE_FACTOR"];
            plan.inputWidth=123;
            assert(!TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan) && plan.inputWidth==123);
            [defaults setDouble:2 forKey:@"TOTK_LAUNCHER_UPSCALE_FACTOR"];
            [defaults setObject:@"16:9" forKey:@"TOTK_LAUNCHER_ASPECT"];
            assert(TOTKLauncherGraphicsPlan(defaults,info,1920,1080,2,&plan));
            assert(plan.inputWidth==1920 && plan.inputHeight==1080 && plan.displayWidth==3840 && plan.displayHeight==2160);
            [defaults setObject:@"display" forKey:@"TOTK_LAUNCHER_ASPECT"];
            [defaults setObject:@"2160" forKey:@"TOTK_LAUNCHER_DISPLAY_OUTPUT"];
            assert(TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan));
            assert(plan.inputWidth==1440 && plan.inputHeight==1080 && plan.displayWidth==2880 && plan.displayHeight==2160);
            [defaults setObject:@"native75" forKey:@"TOTK_LAUNCHER_DISPLAY_OUTPUT"];
            [defaults setObject:@"input-output" forKey:@"TOTK_LAUNCHER_RESOLUTION_MODE"];
            assert(TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan));
            assert(plan.displayWidth==2064 && plan.displayHeight==1548);
            assert(!TOTKLauncherGraphicsPlan(defaults,info,NAN,1032,2,&plan));
            assert(!TOTKLauncherGraphicsPlan(defaults,info,1376,1032,INFINITY,&plan));
            assert(!TOTKLauncherGraphicsPlan(defaults,@{},1376,1032,2,&plan));
            for (id invalid in @[@YES,@0,@0.5,@4.01,@"2",@[],@{},@(NAN),@(INFINITY)]) {
                [defaults setObject:invalid forKey:@"TOTK_LAUNCHER_UPSCALE_FACTOR"];
                assert(TOTKLauncherUpscaleFactor(defaults)==2 && ![defaults objectForKey:@"TOTK_LAUNCHER_UPSCALE_FACTOR"]);
            }
            for (NSString *key in @[@"TOTK_LAUNCHER_RESOLUTION_MODE",@"TOTK_LAUNCHER_DISPLAY_OUTPUT"]) {
                [defaults setObject:@"invalid" forKey:key];
                assert([TOTKLauncherResolutionMode(defaults) isEqual:@"input-output"]);
                assert([TOTKLauncherPresentationMode(defaults) isEqual:@"game"] || [key isEqual:@"TOTK_LAUNCHER_RESOLUTION_MODE"]);
                assert(![defaults objectForKey:key]);
            }
            [defaults removePersistentDomainForName:suite];
        } else if ([test isEqual:@"game-canvas"]) {
            [defaults removePersistentDomainForName:suite];
            assert(TOTKLauncherGameCanvasHeight(defaults)==0);
            for (id invalid in @[@YES,@720,@901,@1082,@900.5,@"1080",@[],@{}]) {
                [defaults setObject:invalid forKey:@"TOTK_LAUNCHER_GAME_CANVAS_HEIGHT"];
                assert(TOTKLauncherGameCanvasHeight(defaults)==0 && ![defaults objectForKey:@"TOTK_LAUNCHER_GAME_CANVAS_HEIGHT"]);
            }
            NSDictionary *info=@{@"TOTKIOSDisplaySettingsVersion":@1};
            TOTKGraphicsPlan plan;
            [defaults setObject:@"display" forKey:@"TOTK_LAUNCHER_ASPECT"];
            [defaults setObject:@"native" forKey:@"TOTK_LAUNCHER_DISPLAY_OUTPUT"];
            [defaults setObject:@"game-output" forKey:@"TOTK_LAUNCHER_SCALER_STAGE"];
            [defaults setInteger:1080 forKey:@"TOTK_LAUNCHER_GAME_CANVAS_HEIGHT"];
            assert(TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan));
            assert(plan.inputWidth==960 && plan.inputHeight==720);
            assert(plan.canvasWidth==1440 && plan.canvasHeight==1080);
            assert(plan.displayWidth==2752 && plan.displayHeight==2064);
            assert(!TOTKLauncherSpatialUpscaling(defaults) && TOTKLauncherOutputUpscaling(defaults));
            [defaults setObject:@"input-scale" forKey:@"TOTK_LAUNCHER_RESOLUTION_MODE"];
            [defaults setDouble:3 forKey:@"TOTK_LAUNCHER_UPSCALE_FACTOR"];
            assert(TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan));
            assert(plan.inputHeight==720 && plan.canvasHeight==1080 && plan.displayHeight==2160);
            [defaults setObject:@"output-scale" forKey:@"TOTK_LAUNCHER_RESOLUTION_MODE"];
            [defaults setDouble:2 forKey:@"TOTK_LAUNCHER_UPSCALE_FACTOR"];
            assert(TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan));
            assert(plan.inputHeight==1032 && plan.canvasHeight==1080 && plan.displayHeight==2064);
            [defaults setInteger:900 forKey:@"TOTK_LAUNCHER_GAME_CANVAS_HEIGHT"];
            plan.inputWidth=123;
            assert(!TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan) && plan.inputWidth==123);
            [defaults setObject:@"scene-output" forKey:@"TOTK_LAUNCHER_SCALER_STAGE"];
            assert(TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan));
            assert(plan.canvasHeight==plan.inputHeight && plan.inputHeight==1032);
            [defaults setObject:@"game-output" forKey:@"TOTK_LAUNCHER_SCALER_STAGE"];
            [defaults setInteger:1080 forKey:@"TOTK_LAUNCHER_GAME_CANVAS_HEIGHT"];
            [defaults setObject:@"input-output" forKey:@"TOTK_LAUNCHER_RESOLUTION_MODE"];
            [defaults setObject:@"game" forKey:@"TOTK_LAUNCHER_DISPLAY_OUTPUT"];
            assert(TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan));
            assert(plan.inputHeight==720 && plan.canvasHeight==1080 && plan.displayHeight==1080);
            [defaults setObject:@"16:9" forKey:@"TOTK_LAUNCHER_ASPECT"];
            for (NSNumber *inputHeight in @[@366,@372,@384]) {
                [defaults setObject:inputHeight forKey:@"TOTK_LAUNCHER_CUSTOM_HEIGHT"];
                assert(TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan));
                assert(plan.inputHeight==inputHeight.unsignedIntValue);
                assert(plan.inputWidth==(unsigned)(2 * round(inputHeight.doubleValue * 16.0 / 9.0 / 2)));
                assert(plan.canvasWidth==1920 && plan.canvasHeight==1080);
            }
            [defaults removePersistentDomainForName:suite];
        } else if ([test isEqual:@"stages-custom"]) {
            [defaults removePersistentDomainForName:suite];
            assert([TOTKLauncherScalerStage(defaults) isEqual:@"game"] && !TOTKLauncherOutputUpscaling(defaults));
            [defaults setBool:YES forKey:@"TOTK_LAUNCHER_SPATIAL_UPSCALING"];
            assert([TOTKLauncherScalerStage(defaults) isEqual:@"scene-output"]);
            assert(TOTKLauncherSpatialUpscaling(defaults) && TOTKLauncherOutputUpscaling(defaults));
            [defaults setObject:@"game-output" forKey:@"TOTK_LAUNCHER_SCALER_STAGE"];
            assert(!TOTKLauncherSpatialUpscaling(defaults) && TOTKLauncherOutputUpscaling(defaults));
            [defaults setObject:@"game" forKey:@"TOTK_LAUNCHER_SCALER_STAGE"];
            assert(!TOTKLauncherSpatialUpscaling(defaults) && !TOTKLauncherOutputUpscaling(defaults));
            for (id invalid in @[@YES,@1,@"both",@[],@{}]) {
                [defaults setObject:invalid forKey:@"TOTK_LAUNCHER_SCALER_STAGE"];
                assert([TOTKLauncherScalerStage(defaults) isEqual:@"scene-output"]);
                assert(![defaults objectForKey:@"TOTK_LAUNCHER_SCALER_STAGE"]);
            }
            for (id invalid in @[@YES,@0,@63,@8194,@720.5,@721,@"1440",@[],@{},@(NAN),@(INFINITY)]) {
                [defaults setObject:invalid forKey:@"TOTK_LAUNCHER_CUSTOM_OUTPUT_HEIGHT"];
                assert(TOTKLauncherCustomOutputHeight(defaults)==1440);
                assert(![defaults objectForKey:@"TOTK_LAUNCHER_CUSTOM_OUTPUT_HEIGHT"]);
            }
            NSDictionary *info=@{@"TOTKIOSDisplaySettingsVersion":@1};
            [defaults setObject:@"custom" forKey:@"TOTK_LAUNCHER_DISPLAY_OUTPUT"];
            [defaults setInteger:1800 forKey:@"TOTK_LAUNCHER_CUSTOM_OUTPUT_HEIGHT"];
            TOTKGraphicsPlan plan;
            assert(TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan));
            assert(plan.displayWidth==3200 && plan.displayHeight==2400);
            assert(plan.inputWidth==1280 && plan.inputHeight==720);
            [defaults setObject:@"display" forKey:@"TOTK_LAUNCHER_ASPECT"];
            assert(TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan));
            assert(plan.displayWidth==2400 && plan.displayHeight==1800);
            [defaults setObject:@"output-scale" forKey:@"TOTK_LAUNCHER_RESOLUTION_MODE"];
            [defaults setDouble:2 forKey:@"TOTK_LAUNCHER_UPSCALE_FACTOR"];
            assert(TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan));
            assert(plan.inputWidth==1200 && plan.inputHeight==900);
            [defaults setInteger:8192 forKey:@"TOTK_LAUNCHER_CUSTOM_OUTPUT_HEIGHT"];
            plan.inputWidth=123;
            assert(!TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan) && plan.inputWidth==123);
            [defaults setInteger:2160 forKey:@"TOTK_LAUNCHER_CUSTOM_OUTPUT_HEIGHT"];
            [defaults setDouble:1 forKey:@"TOTK_LAUNCHER_UPSCALE_FACTOR"];
            assert(!TOTKLauncherGraphicsPlan(defaults,info,1376,1032,2,&plan));
            [defaults removePersistentDomainForName:suite];
        } else if ([test isEqual:@"write"]) {
            [defaults setInteger:40 forKey:@"TOTK_LAUNCHER_FPS_LIMIT"];
            [defaults setInteger:2 forKey:@"TOTK_LAUNCHER_DRAWABLE_COUNT"];
            [defaults setBool:YES forKey:@"TOTK_LAUNCHER_TAA"];
            [defaults setInteger:67 forKey:@"TOTK_LAUNCHER_SCENE_SCALE"];
            [defaults setInteger:900 forKey:@"TOTK_LAUNCHER_CUSTOM_HEIGHT"];
            [defaults setInteger:600 forKey:@"TOTK_LAUNCHER_CUSTOM_SCENE_HEIGHT"];
            [defaults setBool:YES forKey:@"TOTK_LAUNCHER_SPATIAL_UPSCALING"];
            [defaults setObject:@"native" forKey:@"TOTK_LAUNCHER_DISPLAY_OUTPUT"];
            [defaults setObject:@"input-scale" forKey:@"TOTK_LAUNCHER_RESOLUTION_MODE"];
            [defaults setDouble:1.5 forKey:@"TOTK_LAUNCHER_UPSCALE_FACTOR"];
            [defaults setObject:@"game-output" forKey:@"TOTK_LAUNCHER_SCALER_STAGE"];
            [defaults setInteger:1800 forKey:@"TOTK_LAUNCHER_CUSTOM_OUTPUT_HEIGHT"];
            [defaults setInteger:1080 forKey:@"TOTK_LAUNCHER_GAME_CANVAS_HEIGHT"];
            assert([defaults synchronize]);
        } else if ([test isEqual:@"read"]) {
            assert(TOTKLauncherFPSLimit(defaults)==40 && TOTKLauncherTAA(defaults));
            assert(TOTKLauncherDrawableCount(defaults)==2);
            assert(TOTKLauncherSceneScale(defaults)==67 && !TOTKLauncherSpatialUpscaling(defaults));
            assert(TOTKLauncherOutputUpscaling(defaults) && [TOTKLauncherScalerStage(defaults) isEqual:@"game-output"]);
            assert(TOTKLauncherCustomOutputHeight(defaults)==1800 && TOTKLauncherGameCanvasHeight(defaults)==1080);
            assert(TOTKLauncherRenderHeight(defaults)==900 && TOTKLauncherCustomSceneHeight(defaults)==600);
            assert([TOTKLauncherPresentationMode(defaults) isEqual:@"native"] && [TOTKLauncherResolutionMode(defaults) isEqual:@"input-scale"]);
            assert(TOTKLauncherUpscaleFactor(defaults)==1.5);
            [defaults removePersistentDomainForName:suite];
            assert([defaults synchronize]);
        } else assert(!"unknown test");
        puts("PASS");
    }
}
