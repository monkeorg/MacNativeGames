#import <UIKit/UIKit.h>

// Main thread only. Start after Play; disable before menus and enable after dismissal.
void TOTKStartMouseInput(UIViewController *gameController);
// Refresh attachment after viewDidLoad, when the host has joined its window.
void TOTKMouseInputHostDidAppear(void);
void TOTKSetMouseInputEnabled(BOOL enabled);
BOOL TOTKMouseInputEnabled(void);

// Current capture eligibility; the saved request above survives focus and text entry.
BOOL TOTKMouseInputWantsPointerLock(void);

// Main thread only. Aggregate session counts and current capture state; no input coordinates or device identifiers.
NSDictionary<NSString *, NSNumber *> *TOTKMouseInputDiagnostics(void);
