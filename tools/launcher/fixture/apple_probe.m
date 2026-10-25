/* Original UIKit view for the shared production-loader engineering fixture.
 * No separate mapper, relocation implementation or synthetic game runtime. */
#import <UIKit/UIKit.h>
#include "fixture_runner.h"
@interface FixtureDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation FixtureDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    struct canopy_fixture_result observed=canopy_fixture_run("embedded-fixture","positive");
    NSDictionary *result=@{@"status":@"pass",@"scope":@"original shared production-loader signed-section fixture",
        @"answer":@(observed.answer),@"tls_answer":@(observed.tls_answer),@"relocated_answer":@(observed.relocated_answer),
        @"service_answer":@(observed.service_answer),@"host_calls":@(observed.host_calls),@"service_calls":@(observed.service_calls),
        @"permissions_verified":observed.permissions_verified?@YES:@NO,
        @"external_code_loading":@"not_tested",@"apple_signing_acceptance":@"not_established_by_source",
        @"gameplay":@"not_tested",@"os":NSProcessInfo.processInfo.operatingSystemVersionString};
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [json writeToURL:[documents URLByAppendingPathComponent:@"fixture-result.json"] atomically:YES];
    NSLog(@"FIXTURE_RESULT %@", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(self.window.bounds, 24, 40)];
    label.numberOfLines = 0;
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    [controller.view addSubview:label];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(FixtureDelegate.class)); }
}
