#import "launcher_settings.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
int main(void) {
    @autoreleasepool {
        NSString *suite = [@"TOTKMetalHUDProbe." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        NSDictionary *properties = TOTKLauncherMetalHUDProperties(defaults);
        assert([properties[@"mode"] isEqual:@"disabled"]);
        assert([properties[@"logging"] isEqual:@"disabled"]);
        assert([properties[@"MTL_HUD_ALIGNMENT"] isEqual:@"topright"]);
        assert([properties[@"MTL_HUD_SCALE"] isEqual:@0.2]);
        assert([properties[@"MTL_HUD_OPACITY"] isEqual:@1]);
        assert(![properties[@"MTL_HUD_ENCODER_TIMING_ENABLED"] boolValue]);
        assert(![properties[@"MTL_HUD_INSIGHTS_ENABLED"] boolValue]);
        assert(![properties[@"MTL_HUD_SHOW_METRICS_RANGE"] boolValue]);
        assert(![TOTKLauncherMetalHUDMetricOptions() containsObject:@"thermal"]);
        assert(TOTKLauncherMetalHUDAlignments().count == 9);
        for (NSString *alignment in TOTKLauncherMetalHUDAlignments()) {
            [defaults setObject:alignment forKey:@"TOTK_LAUNCHER_METAL_HUD_ALIGNMENT"];
            assert([TOTKLauncherMetalHUDProperties(defaults)[@"MTL_HUD_ALIGNMENT"] isEqual:alignment]);
        }
        [defaults setObject:@"invalid" forKey:@"TOTK_LAUNCHER_METAL_HUD_ALIGNMENT"];
        assert([TOTKLauncherMetalHUDAlignment(defaults) isEqual:@"topright"]);
        assert(![defaults objectForKey:@"TOTK_LAUNCHER_METAL_HUD_ALIGNMENT"]);
        for (NSString *key in @[@"TOTK_LAUNCHER_METAL_HUD_SCALE",@"TOTK_LAUNCHER_METAL_HUD_OPACITY"]) {
            for (id invalid in @[@YES,@(-0.01),@1.01,@"0.5",@[],@{},@(NAN),@(INFINITY)]) {
                [defaults setObject:invalid forKey:key];
                assert(TOTKLauncherMetalHUDScale(defaults) == 0.2);
                assert(TOTKLauncherMetalHUDOpacity(defaults) == 1.0);
                assert(![defaults objectForKey:key]);
            }
            for (NSNumber *valid in @[@0,@0.3,@1]) {
                [defaults setObject:valid forKey:key];
                properties = TOTKLauncherMetalHUDProperties(defaults);
                NSString *property = [key hasSuffix:@"SCALE"] ? @"MTL_HUD_SCALE" : @"MTL_HUD_OPACITY";
                assert([properties[property] isEqual:valid]);
            }
            [defaults removeObjectForKey:key];
        }
        for (id invalid in @[@"fps",@[],@[@"thermal"],@[@"fps",@"fps"],@[@1],@[@"fps",@"unknown"]]) {
            [defaults setObject:invalid forKey:@"TOTK_LAUNCHER_METAL_HUD_METRICS"];
            assert(TOTKLauncherMetalHUDMetrics(defaults).count == 6);
            assert(![defaults objectForKey:@"TOTK_LAUNCHER_METAL_HUD_METRICS"]);
        }
        [defaults setObject:TOTKLauncherMetalHUDMetricOptions() forKey:@"TOTK_LAUNCHER_METAL_HUD_METRICS"];
        assert([TOTKLauncherMetalHUDProperties(defaults)[@"MTL_HUD_ELEMENTS"] isEqual:
            [TOTKLauncherMetalHUDMetricOptions() componentsJoinedByString:@","]]);
        NSArray *flagKeys = @[@"TOTK_LAUNCHER_METAL_HUD_ENCODER_TIMING",@"TOTK_LAUNCHER_METAL_HUD_INSIGHTS",@"TOTK_LAUNCHER_METAL_HUD_RANGE"];
        NSArray *propertyKeys = @[@"MTL_HUD_ENCODER_TIMING_ENABLED",@"MTL_HUD_INSIGHTS_ENABLED",@"MTL_HUD_SHOW_METRICS_RANGE"];
        for (NSUInteger index = 0; index < flagKeys.count; index++) {
            for (id invalid in @[@2,@(-1),@0.5,@"1",@[],@{},@(NAN),@(INFINITY)]) {
                [defaults setObject:invalid forKey:flagKeys[index]];
                assert(![TOTKLauncherMetalHUDProperties(defaults)[propertyKeys[index]] boolValue]);
                assert(![defaults objectForKey:flagKeys[index]]);
            }
            [defaults setBool:YES forKey:flagKeys[index]];
            assert([TOTKLauncherMetalHUDProperties(defaults)[propertyKeys[index]] boolValue]);
        }
        [defaults setBool:YES forKey:@"TOTK_LAUNCHER_METAL_HUD"];
        [defaults setObject:@[@"fps",@"gputime"] forKey:@"TOTK_LAUNCHER_METAL_HUD_METRICS"];
        [defaults setDouble:0.4 forKey:@"TOTK_LAUNCHER_METAL_HUD_SCALE"];
        [defaults setDouble:0.75 forKey:@"TOTK_LAUNCHER_METAL_HUD_OPACITY"];
        [defaults synchronize];
        NSUserDefaults *fresh = [[NSUserDefaults alloc] initWithSuiteName:suite];
        properties = TOTKLauncherMetalHUDProperties(fresh);
        assert([properties[@"mode"] isEqual:@"default"]);
        assert([properties[@"MTL_HUD_ELEMENTS"] isEqual:@"fps,gputime"]);
        assert([properties[@"MTL_HUD_SCALE"] isEqual:@0.4]);
        assert([properties[@"MTL_HUD_OPACITY"] isEqual:@0.75]);
        assert([properties[@"logging"] isEqual:@"disabled"]);
        [defaults setBool:NO forKey:@"TOTK_LAUNCHER_METAL_HUD"];
        assert([TOTKLauncherMetalHUDProperties(defaults)[@"mode"] isEqual:@"disabled"]);
        [defaults removePersistentDomainForName:suite];
        puts("PASS: Metal HUD defaults, malformed recovery, mapping, and persistence");
    }
}
