#import <UIKit/UIKit.h>
#import "CanopySettings.h"
#import "CanopyControllers.h"

typedef NSDictionary<NSString *, NSDictionary *> * _Nonnull (^CanopySettingsApply)(NSDictionary<NSString *, id> * _Nonnull desired);
typedef NSDictionary<NSString *, NSDictionary *> * _Nonnull (^CanopySettingsStateProvider)(void);

UIViewController *CanopyMakeGamesController(void);
UIViewController *CanopyMakeInspectionHistoryController(void);
UIViewController *CanopyMakeSettingsController(NSDictionary *entry, CanopySettings *settings,
    CanopySettingsApply _Nullable apply, CanopySettingsStateProvider _Nullable states,
    CanopyControllers *controllers);
