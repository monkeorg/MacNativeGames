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
        } else if ([test isEqual:@"write"]) {
            [defaults setInteger:40 forKey:@"TOTK_LAUNCHER_FPS_LIMIT"];
            [defaults setBool:YES forKey:@"TOTK_LAUNCHER_TAA"];
            assert([defaults synchronize]);
        } else if ([test isEqual:@"read"]) {
            assert(TOTKLauncherFPSLimit(defaults)==40 && TOTKLauncherTAA(defaults));
            [defaults removePersistentDomainForName:suite];
            assert([defaults synchronize]);
        } else assert(!"unknown test");
        puts("PASS");
    }
}
