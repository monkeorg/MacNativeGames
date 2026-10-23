#import "launcher_settings.h"

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
