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

NSInteger TOTKLauncherMouseSensitivity(NSUserDefaults *defaults);
BOOL TOTKLauncherMouseInvertY(NSUserDefaults *defaults);
NSString *TOTKLauncherControllerType(NSUserDefaults *defaults);
NSArray<NSString *> *TOTKLauncherControlButtons(void);
NSArray<NSString *> *TOTKLauncherControlTargets(void);
NSString *TOTKLauncherControlBinding(NSUserDefaults *defaults, NSString *button);
NSString *TOTKLauncherControlBindingTitle(NSUserDefaults *defaults, NSString *button);
/* Prepare generated files before sealing saves. Apply only in the successful Play callback.
   Existing developer environment values always win. */
BOOL TOTKLauncherPrepareControls(NSUserDefaults *defaults, NSError **error);
void TOTKLauncherApplyControls(NSUserDefaults *defaults);
