#import <Foundation/Foundation.h>

NSArray<NSString *> *TOTKLanguages(void);
NSString *TOTKLauncherLanguage(NSUserDefaults *defaults);
NSInteger TOTKLauncherHUD(NSUserDefaults *defaults);
BOOL TOTKLauncherTouch(NSUserDefaults *defaults);
BOOL TOTKLauncherMetalHUD(NSUserDefaults *defaults);
NSInteger TOTKLauncherFPSLimit(NSUserDefaults *defaults);
BOOL TOTKLauncherTAA(NSUserDefaults *defaults);
NSInteger TOTKLauncherRenderHeight(NSUserDefaults *defaults);
NSInteger TOTKLauncherSceneScale(NSUserDefaults *defaults);
NSInteger TOTKLauncherCustomSceneHeight(NSUserDefaults *defaults);
BOOL TOTKLauncherSpatialUpscaling(NSUserDefaults *defaults);
NSArray<NSString *> *TOTKLauncherScalerStages(void);
NSString *TOTKLauncherScalerStage(NSUserDefaults *defaults);
BOOL TOTKLauncherOutputUpscaling(NSUserDefaults *defaults);
NSInteger TOTKLauncherCustomOutputHeight(NSUserDefaults *defaults);
NSInteger TOTKLauncherGameCanvasHeight(NSUserDefaults *defaults);
NSArray<NSString *> *TOTKLauncherPresentationModes(void);
NSString *TOTKLauncherPresentationMode(NSUserDefaults *defaults);
typedef struct {
    unsigned inputWidth, inputHeight, canvasWidth, canvasHeight, displayWidth, displayHeight;
    BOOL fullDisplay;
} TOTKGraphicsPlan;
NSArray<NSString *> *TOTKLauncherResolutionModes(void);
NSString *TOTKLauncherResolutionMode(NSUserDefaults *defaults);
double TOTKLauncherUpscaleFactor(NSUserDefaults *defaults);
NSDictionary *TOTKLauncherGraphicsPreferences(NSUserDefaults *defaults);
BOOL TOTKLauncherGraphicsPlan(NSUserDefaults *defaults, NSDictionary *info, double viewWidth, double viewHeight,
                              double nativeScale, TOTKGraphicsPlan *plan);
BOOL TOTKLauncherPresentationSize(NSUserDefaults *defaults, double viewWidth, double viewHeight, double nativeScale,
                                  unsigned canvasWidth, unsigned canvasHeight, unsigned *width, unsigned *height);
BOOL TOTKLauncherSceneSize(NSUserDefaults *defaults, unsigned outputWidth, unsigned outputHeight,
                           unsigned *width, unsigned *height);
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
