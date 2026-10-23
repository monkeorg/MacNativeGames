#import <UIKit/UIKit.h>
#import "launcher.h"
#import "launcher_settings.h"

@interface HarnessScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation HarnessScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    NSArray *args = NSProcessInfo.processInfo.arguments;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *root = [[fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"SyntheticSaves"];
    if ([args containsObject:@"--reset"]) {
        [fm removeItemAtURL:root error:nil];
        for (NSString *key in @[@"TOTK_LANG", @"TOTK_LAUNCHER_HUD", @"TOTK_LAUNCHER_TOUCH"]) [defaults removeObjectForKey:key];
    }
    NSURL *active = [root URLByAppendingPathComponent:@"active"];
    for (unsigned slot = 0; slot < 6; slot++) {
        NSURL *folder = [active URLByAppendingPathComponent:[NSString stringWithFormat:@"slot_%02u",slot]];
        [fm createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString *name in @[@"progress.sav", @"caption.sav", @"footprint.sav", @"direct_file_save_related.sav"]) {
            NSURL *file = [folder URLByAppendingPathComponent:name];
            if (![fm fileExistsAtPath:file.path]) [@"fixture-original" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
    NSURL *progress = [active URLByAppendingPathComponent:@"slot_00/progress.sav"];
    if ([args containsObject:@"--mutate-save"]) [@"fixture-changed" writeToURL:progress atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if ([args containsObject:@"--invalid-preferences"]) {
        [defaults setObject:@[@"invalid"] forKey:@"TOTK_LANG"];
        [defaults setInteger:77 forKey:@"TOTK_LAUNCHER_HUD"];
        [defaults setObject:@"invalid" forKey:@"TOTK_LAUNCHER_TOUCH"];
    }
    TOTKSaveStore *store = [[TOTKSaveStore alloc] initWithActiveURL:active backupsURL:[root URLByAppendingPathComponent:@"backups"]];
    __block unsigned starts = 0;
    __block __weak TOTKLauncher *weakLauncher;
    TOTKLauncher *launcher = [[TOTKLauncher alloc] initWithStore:store unavailable:nil play:^{
        NSString *contents = [NSString stringWithContentsOfURL:progress encoding:NSUTF8StringEncoding error:nil];
        weakLauncher.navigationItem.prompt = [NSString stringWithFormat:@"Starts: %u; %@; HUD %ld; %@", ++starts,
            TOTKLauncherLanguage(defaults), (long)TOTKLauncherHUD(defaults), contents];
    }];
    // The byref weak reference lets the callback observe the launcher without a retain cycle.
    weakLauncher = launcher;
    launcher.navigationItem.prompt = @"Starts: 0";
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:launcher];
    [self.window makeKeyAndVisible];
}
@end

@interface HarnessApp : UIResponder <UIApplicationDelegate> @end
@implementation HarnessApp
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)app; (void)options;
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    configuration.delegateClass = HarnessScene.class;
    return configuration;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(HarnessApp.class)); }
}
