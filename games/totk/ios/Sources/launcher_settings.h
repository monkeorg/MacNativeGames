#import <Foundation/Foundation.h>

NSArray<NSString *> *TOTKLanguages(void);
NSString *TOTKLauncherLanguage(NSUserDefaults *defaults);
NSInteger TOTKLauncherHUD(NSUserDefaults *defaults);
BOOL TOTKLauncherTouch(NSUserDefaults *defaults);
BOOL TOTKLauncherMetalHUD(NSUserDefaults *defaults);
NSInteger TOTKLauncherRenderHeight(NSUserDefaults *defaults);
NSString *TOTKLauncherAspect(NSUserDefaults *defaults);
BOOL TOTKLauncherDisplaySettingsAvailable(NSDictionary *info);
/* Width and height are required; fullDisplay is optional. NO leaves outputs unchanged. */
BOOL TOTKLauncherDisplaySize(NSUserDefaults *defaults, NSDictionary *info, double viewWidth, double viewHeight,
                             unsigned *width, unsigned *height, BOOL *fullDisplay);
