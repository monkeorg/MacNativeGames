#import "launcher_settings.h"
#include <math.h>
#include <stdlib.h>
#include "../../runtime/controller_map.h"

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
NSInteger TOTKLauncherFPSLimit(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"TOTK_LAUNCHER_FPS_LIMIT"];
    if ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        [@[@30,@40,@60] containsObject:value]) return [value integerValue];
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_FPS_LIMIT"]; return 60;
}
BOOL TOTKLauncherTAA(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"TOTK_LAUNCHER_TAA"];
    if ([value isKindOfClass:NSNumber.class] && [@[@0,@1] containsObject:value]) return [value boolValue];
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_TAA"]; return NO;
}
NSInteger TOTKLauncherRenderHeight(NSUserDefaults *defaults) {
    id custom = [defaults objectForKey:@"TOTK_LAUNCHER_CUSTOM_HEIGHT"];
    if ([custom isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)custom) != CFBooleanGetTypeID() &&
        isfinite([custom doubleValue]) && [custom doubleValue] == [custom integerValue] &&
        [custom integerValue] >= 360 && [custom integerValue] <= 1080 && [custom integerValue] % 6 == 0) return [custom integerValue];
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_CUSTOM_HEIGHT"];
    id value = [defaults objectForKey:@"TOTK_LAUNCHER_RENDER_HEIGHT"];
    if ([value isKindOfClass:NSNumber.class] && [@[@720,@1080] containsObject:value]) return [value integerValue];
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_RENDER_HEIGHT"]; return 720;
}
NSString *TOTKLauncherAspect(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"TOTK_LAUNCHER_ASPECT"];
    if ([value isKindOfClass:NSString.class] && [@[@"16:9",@"display"] containsObject:value]) return value;
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_ASPECT"]; return @"16:9";
}
NSInteger TOTKLauncherSceneScale(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"TOTK_LAUNCHER_SCENE_SCALE"];
    if ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [value doubleValue] == [value integerValue] &&
        [value integerValue] >= 50 && [value integerValue] <= 100) return [value integerValue];
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_SCENE_SCALE"]; return 100;
}
BOOL TOTKLauncherSpatialUpscaling(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"TOTK_LAUNCHER_SPATIAL_UPSCALING"];
    if ([value isKindOfClass:NSNumber.class] && [@[@0,@1] containsObject:value]) return [value boolValue];
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_SPATIAL_UPSCALING"]; return NO;
}
NSArray<NSString *> *TOTKLauncherPresentationModes(void) {
    return @[@"game",@"720",@"900",@"1080",@"1440",@"2160",@"native50",@"native75",@"native"];
}
NSString *TOTKLauncherPresentationMode(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"TOTK_LAUNCHER_DISPLAY_OUTPUT"];
    if ([value isKindOfClass:NSString.class] && [TOTKLauncherPresentationModes() containsObject:value]) return value;
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_DISPLAY_OUTPUT"]; return @"game";
}
BOOL TOTKLauncherPresentationSize(NSUserDefaults *defaults, double viewWidth, double viewHeight, double nativeScale,
                                  unsigned canvasWidth, unsigned canvasHeight, unsigned *width, unsigned *height) {
    if (!width || !height || !isfinite(viewWidth) || !isfinite(viewHeight) || !isfinite(nativeScale) ||
        viewWidth <= 0 || viewHeight <= 0 || nativeScale <= 0 || !canvasWidth || !canvasHeight) return NO;
    NSString *mode = TOTKLauncherPresentationMode(defaults);
    double ratio = viewWidth / viewHeight, w, h;
    if ([mode hasPrefix:@"native"]) {
        double scale = [mode isEqual:@"native50"] ? 0.5 : [mode isEqual:@"native75"] ? 0.75 : 1.0;
        w = viewWidth * nativeScale * scale; h = viewHeight * nativeScale * scale;
    } else if ([mode isEqual:@"game"]) {
        w = canvasWidth; h = canvasWidth / ratio;
    } else {
        h = mode.doubleValue * fmax(1.0,((double)canvasWidth / canvasHeight) / ratio);
        w = h * ratio;
    }
    if (!isfinite(w) || !isfinite(h) || w < 64 || h < 64 || w > 8192 || h > 8192) return NO;
    *width = (unsigned)(2 * round(w / 2)); *height = (unsigned)(2 * round(h / 2));
    return YES;
}
NSInteger TOTKLauncherCustomSceneHeight(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"TOTK_LAUNCHER_CUSTOM_SCENE_HEIGHT"];
    if ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [value doubleValue] == [value integerValue] &&
        [value integerValue] >= 180 && [value integerValue] <= 1080 && [value integerValue] % 2 == 0) return [value integerValue];
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_CUSTOM_SCENE_HEIGHT"]; return 0;
}
BOOL TOTKLauncherSceneSize(NSUserDefaults *defaults, unsigned outputWidth, unsigned outputHeight,
                           unsigned *width, unsigned *height) {
    if (!width || !height || outputWidth < 128 || outputHeight < 128 || outputWidth > 1920 || outputHeight > 1080) return NO;
    double scale = TOTKLauncherSceneScale(defaults) / 100.0;
    NSInteger custom = TOTKLauncherCustomSceneHeight(defaults);
    if (custom) scale = fmin((double)custom / outputHeight,1.0);
    *width = (unsigned)(2 * round(outputWidth * scale / 2));
    *height = (unsigned)(2 * round(outputHeight * scale / 2));
    return YES;
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
NSArray<NSString *> *TOTKLauncherResolutionModes(void) {
    return @[@"input-output",@"input-scale",@"output-scale"];
}
NSString *TOTKLauncherResolutionMode(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"TOTK_LAUNCHER_RESOLUTION_MODE"];
    if ([value isKindOfClass:NSString.class] && [TOTKLauncherResolutionModes() containsObject:value]) return value;
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_RESOLUTION_MODE"]; return @"input-output";
}
double TOTKLauncherUpscaleFactor(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"TOTK_LAUNCHER_UPSCALE_FACTOR"];
    if ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [value doubleValue] >= 1 && [value doubleValue] <= 4) return [value doubleValue];
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_UPSCALE_FACTOR"]; return 2;
}
NSDictionary *TOTKLauncherGraphicsPreferences(NSUserDefaults *defaults) {
    return @{@"height":@(TOTKLauncherRenderHeight(defaults)),@"aspect":TOTKLauncherAspect(defaults),
        @"scene":@(TOTKLauncherCustomSceneHeight(defaults)),@"scale":@(TOTKLauncherSceneScale(defaults)),
        @"spatial":@(TOTKLauncherSpatialUpscaling(defaults)),@"display":TOTKLauncherPresentationMode(defaults),
        @"mode":TOTKLauncherResolutionMode(defaults),@"factor":@(TOTKLauncherUpscaleFactor(defaults))};
}
BOOL TOTKLauncherGraphicsPlan(NSUserDefaults *defaults, NSDictionary *info, double viewWidth, double viewHeight,
                              double nativeScale, TOTKGraphicsPlan *plan) {
    if (!plan) return NO;
    TOTKGraphicsPlan result = {0};
    if (!TOTKLauncherDisplaySize(defaults,info,viewWidth,viewHeight,&result.canvasWidth,&result.canvasHeight,&result.fullDisplay) ||
        !TOTKLauncherSceneSize(defaults,result.canvasWidth,result.canvasHeight,&result.inputWidth,&result.inputHeight)) return NO;
    NSString *mode = TOTKLauncherResolutionMode(defaults);
    double factor = TOTKLauncherUpscaleFactor(defaults);
    if ([mode isEqual:@"input-scale"]) {
        double ratio = viewWidth / viewHeight;
        double h = result.inputHeight * factor * fmax(1.0,((double)result.inputWidth / result.inputHeight)/ratio);
        double w = h * ratio;
        if (!isfinite(w) || !isfinite(h) || w < 64 || h < 64 || w > 8192 || h > 8192) return NO;
        result.displayWidth = (unsigned)(2 * round(w / 2)); result.displayHeight = (unsigned)(2 * round(h / 2));
    } else {
        if (!TOTKLauncherPresentationSize(defaults,viewWidth,viewHeight,nativeScale,result.canvasWidth,result.canvasHeight,
                                          &result.displayWidth,&result.displayHeight)) return NO;
        if ([mode isEqual:@"output-scale"]) {
            if ([TOTKLauncherPresentationMode(defaults) isEqual:@"game"]) return NO;
            double size = fmin((double)result.displayWidth/result.canvasWidth,(double)result.displayHeight/result.canvasHeight);
            double height = result.canvasHeight * size / factor;
            if (!isfinite(height) || height < 357 || height > 1083) return NO;
            unsigned h = (unsigned)(6 * round(height / 6));
            if (h < 360 || h > 1080) return NO;
            unsigned w = (unsigned)(2 * round((double)result.canvasWidth / result.canvasHeight * h / 2));
            if (w > 1920) return NO;
            result.canvasWidth=result.inputWidth=w; result.canvasHeight=result.inputHeight=h;
        }
    }
    *plan = result; return YES;
}

NSInteger TOTKLauncherMouseSensitivity(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"TOTK_LAUNCHER_MOUSE_SENSITIVITY"];
    if ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [value doubleValue] == [value integerValue] &&
        [value integerValue] >= 1 && [value integerValue] <= 100) return [value integerValue];
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_MOUSE_SENSITIVITY"]; return 50;
}
BOOL TOTKLauncherMouseInvertY(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"TOTK_LAUNCHER_MOUSE_INVERT_Y"];
    if ([value isKindOfClass:NSNumber.class] && [@[@0,@1] containsObject:value]) return [value boolValue];
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_MOUSE_INVERT_Y"]; return NO;
}
NSString *TOTKLauncherControllerType(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"TOTK_LAUNCHER_CONTROLLER_TYPE"];
    if ([value isKindOfClass:NSString.class] && [@[@"auto",@"xbox",@"playstation",@"switch"] containsObject:value]) return value;
    [defaults removeObjectForKey:@"TOTK_LAUNCHER_CONTROLLER_TYPE"]; return @"auto";
}
NSArray<NSString *> *TOTKLauncherControlButtons(void) {
    NSMutableArray *buttons = [NSMutableArray array];
    for (unsigned i=0; i<CONTROLLER_BUTTONS; i++) [buttons addObject:@(controller_physical_names[i])];
    return buttons;
}
NSArray<NSString *> *TOTKLauncherControlTargets(void) {
    NSMutableArray *targets = [NSMutableArray arrayWithObject:@"default"];
    for (unsigned i=0; i<CONTROLLER_SWITCH_BUTTONS; i++) [targets addObject:@(controller_switch_names[i])];
    [targets addObject:@"none"]; return targets;
}
NSString *TOTKLauncherControlBinding(NSUserDefaults *defaults, NSString *button) {
    if (![TOTKLauncherControlButtons() containsObject:button]) return @"default";
    NSString *key = [@"TOTK_LAUNCHER_BIND_" stringByAppendingString:button];
    id value = [defaults objectForKey:key];
    if ([value isKindOfClass:NSString.class] && [TOTKLauncherControlTargets() containsObject:value]) return value;
    [defaults removeObjectForKey:key]; return @"default";
}
NSString *TOTKLauncherControlBindingTitle(NSUserDefaults *defaults, NSString *button) {
    NSString *binding = TOTKLauncherControlBinding(defaults, button);
    if (![binding isEqual:@"default"]) return [binding isEqual:@"none"] ? @"None" : binding.uppercaseString;
    NSUInteger index = [TOTKLauncherControlButtons() indexOfObject:button];
    if (index == NSNotFound) return @"Default";
    uint16_t map[CONTROLLER_BUTTONS]; uint8_t modes[CONTROLLER_BUTTONS]; controller_map_default(map,modes);
    NSString *target = @"None";
    for (unsigned i=0; i<CONTROLLER_SWITCH_BUTTONS; i++) if (map[index] == (1u << i)) target = [@(controller_switch_names[i]) uppercaseString];
    return [NSString stringWithFormat:@"Default: %@%@",target, controller_mode_kind(modes[index]) == CONTROLLER_AIM ? @" (aim/fire)" : @""];
}
static NSURL *launcher_controls_url(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject;
    return support.length ? [[NSURL fileURLWithPath:support isDirectory:YES] URLByAppendingPathComponent:@"LauncherControls/controls.txt"] : nil;
}
static NSString *launcher_controls_text(NSUserDefaults *defaults) {
    NSMutableString *text = [NSMutableString string];
    for (NSString *button in TOTKLauncherControlButtons()) {
        NSString *target = TOTKLauncherControlBinding(defaults,button);
        if (![target isEqual:@"default"]) [text appendFormat:@"%@ = %@\n",button,target];
    }
    // No file/environment on untouched defaults: retain the runtime's own defaults.
    return (text.length || ![TOTKLauncherControllerType(defaults) isEqual:@"auto"]) ? text : nil;
}
BOOL TOTKLauncherPrepareControls(NSUserDefaults *defaults, NSError **error) {
    if (getenv("TOTK_CONTROLS")) return YES;
    NSString *text = launcher_controls_text(defaults);
    if (!text) return YES;
    uint16_t map[CONTROLLER_BUTTONS]; uint8_t modes[CONTROLLER_BUTTONS]; controller_map_default(map,modes);
    const char *problem = NULL;
    int line = controller_map_parse(text.UTF8String,map,modes,&problem);
    NSURL *url = launcher_controls_url();
    if (line || !url) {
        if (error) *error = [NSError errorWithDomain:@"TOTKLauncherControls" code:1 userInfo:@{NSLocalizedDescriptionKey:
            line ? [NSString stringWithFormat:@"Button mapping line %d: %s",line,problem] : @"Cannot locate the controls preferences folder."}];
        return NO;
    }
    if (![NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    if (![text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:error]) return NO;
    // The existing backend reads the selected controller type next to TOTK_CONTROLS.
    return [[TOTKLauncherControllerType(defaults) stringByAppendingString:@"\n"]
        writeToURL:[url.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"controller-type.txt"]
        atomically:YES encoding:NSUTF8StringEncoding error:error];
}
void TOTKLauncherApplyControls(NSUserDefaults *defaults) {
    NSString *sensitivity = [NSString stringWithFormat:@"%ld",(long)TOTKLauncherMouseSensitivity(defaults)];
    setenv("TOTK_MOUSE_SENSITIVITY",sensitivity.UTF8String,0);
    setenv("TOTK_MOUSE_INVERT_Y",TOTKLauncherMouseInvertY(defaults) ? "1" : "0",0);
    if (!getenv("TOTK_CONTROLS") && launcher_controls_text(defaults)) {
        setenv("TOTK_CONTROLS",[launcher_controls_url() path].fileSystemRepresentation,0);
    }
}
