#import "launcher_settings.h"
#include <math.h>

NSArray<NSString *> *TOTKLanguages(void) {
    return @[@"",@"zh-Hant",@"zh-Hans",@"en-US",@"ja",@"de",@"es",@"fr",@"it",@"nl",@"ru",@"ko"];
}
NSString *TOTKLauncherLanguage(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"TOTK_LANG"];
    if ([value isKindOfClass:NSString.class] && [TOTKLanguages() containsObject:value]) return value;
    [defaults removeObjectForKey:@"TOTK_LANG"]; return @"";
}
NSInteger TOTKLauncherHUD(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"TOTK_LAUNCHER_HUD"];
    if ([value isKindOfClass:NSNumber.class] && [@[@0,@1,@2] containsObject:value]) return [value integerValue];
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_HUD"]; return 1;
}
BOOL TOTKLauncherTouch(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"TOTK_LAUNCHER_TOUCH"];
    if ([value isKindOfClass:NSNumber.class] && [@[@0,@1] containsObject:value]) return [value boolValue];
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_TOUCH"]; return YES;
}
BOOL TOTKLauncherMetalHUD(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"TOTK_LAUNCHER_METAL_HUD"];
    if ([value isKindOfClass:NSNumber.class] && [@[@0,@1] containsObject:value]) return [value boolValue];
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_METAL_HUD"]; return NO;
}
NSInteger TOTKLauncherRenderHeight(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"TOTK_LAUNCHER_RENDER_HEIGHT"];
    if ([value isKindOfClass:NSNumber.class] && [@[@720,@1080] containsObject:value]) return [value integerValue];
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_RENDER_HEIGHT"]; return 720;
}
NSString *TOTKLauncherAspect(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"TOTK_LAUNCHER_ASPECT"];
    if ([value isKindOfClass:NSString.class] && [@[@"16:9",@"display"] containsObject:value]) return value;
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_ASPECT"]; return @"16:9";
}
BOOL TOTKLauncherDisplaySettingsAvailable(NSDictionary *info) {
    id value = info[@"TOTKIOSDisplaySettingsVersion"];
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() && [value isEqual:@1];
}
BOOL TOTKLauncherDisplaySize(NSUserDefaults *defaults, NSDictionary *info, double viewWidth, double viewHeight,
                             unsigned *width, unsigned *height, BOOL *fullDisplay) {
    if (!TOTKLauncherDisplaySettingsAvailable(info) || !width || !height ||
        !isfinite(viewWidth) || !isfinite(viewHeight) || viewWidth <= 0 || viewHeight <= 0) return NO;
    double ratio = fmax(viewWidth,viewHeight) / fmin(viewWidth,viewHeight);
    BOOL useDisplay = [TOTKLauncherAspect(defaults) isEqual:@"display"] && ratio <= 16.0 / 9.0;
    unsigned h = (unsigned)TOTKLauncherRenderHeight(defaults);
    unsigned w = (unsigned)(2 * round(h * (useDisplay ? ratio : 16.0 / 9.0) / 2));
    if (w > 1920 || h > 1080) return NO;
    *width = w; *height = h;
    if (fullDisplay) *fullDisplay = useDisplay;
    return YES;
}
