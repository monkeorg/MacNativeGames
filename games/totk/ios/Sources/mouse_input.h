#import <UIKit/UIKit.h>

// Main thread only. Start after Play; disable before menus and enable after dismissal.
void TOTKStartMouseInput(UIViewController *gameController);
void TOTKSetMouseInputEnabled(BOOL enabled);
BOOL TOTKMouseInputEnabled(void);
