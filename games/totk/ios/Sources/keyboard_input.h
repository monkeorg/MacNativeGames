#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

NSArray<NSString *> *TOTKKeyboardActions(void);
NSArray<NSNumber *> *TOTKKeyboardSupportedKeys(void);
NSString *TOTKKeyboardKeyTitle(unsigned key);
unsigned TOTKKeyboardBinding(NSUserDefaults *defaults, NSUInteger action);
BOOL TOTKKeyboardSetBinding(NSUserDefaults *defaults, NSUInteger action, unsigned key);
// Main thread only. Preferences apply to the next press; release all before edits.
void TOTKClearKeyboardInput(void);
#if TARGET_OS_IPHONE
void TOTKStartKeyboardInput(UIViewController *host);
void TOTKSetKeyboardInputEnabled(BOOL enabled);
BOOL TOTKKeyboardPress(UIPress *press, BOOL down);
#endif
