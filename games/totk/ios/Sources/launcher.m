#import "launcher.h"
#import "launcher_settings.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <GameController/GameController.h>
#include <stdlib.h>

static NSString *control_button_title(NSString *button) {
    return @{@"south":@"South face button",@"east":@"East face button",@"west":@"West face button",@"north":@"North face button",
        @"l3":@"Left stick press",@"r3":@"Right stick press",@"l1":@"Left shoulder",@"r1":@"Right shoulder",
        @"l2":@"Left trigger",@"r2":@"Right trigger",@"menu":@"Menu",@"view":@"View / Options",
        @"left":@"D-pad left",@"up":@"D-pad up",@"right":@"D-pad right",@"down":@"D-pad down",@"touchpad":@"Touchpad click",
        @"mouse_left":@"Mouse left",@"mouse_right":@"Mouse right",@"mouse_middle":@"Mouse middle",
        @"mouse4":@"Mouse extra 1",@"mouse5":@"Mouse extra 2"}[button] ?: button;
}

@interface TOTKButtonMappings : UITableViewController @end
@implementation TOTKButtonMappings
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = @"Button mappings";
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.allowsFocus = YES;
    self.tableView.remembersLastFocusedIndexPath = YES;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; return section == 0 ? 17 : 5;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; return section == 0 ? @"Controller" : @"Mouse";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? @"Choose a Switch button or None. Custom mappings hold while pressed. Default restores the standard mapping. Applies at Play; reopen the app to change it later."
        : @"Default right click draws the bow; left click shoots while aiming. Extra buttons require a mouse that exposes them to iPadOS. Touch controls keep their standard layout.";
}
- (NSString *)buttonAtPath:(NSIndexPath *)path { return TOTKLauncherControlButtons()[path.section == 0 ? path.row : 17 + path.row]; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSString *button = [self buttonAtPath:path];
    cell.textLabel.text = control_button_title(button);
    cell.detailTextLabel.text = TOTKLauncherControlBindingTitle(NSUserDefaults.standardUserDefaults,button);
    cell.accessibilityLabel = cell.textLabel.text;
    cell.accessibilityValue = cell.detailTextLabel.text;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (getenv("TOTK_CONTROLS")) return;
    NSString *button = [self buttonAtPath:path];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:control_button_title(button) message:@"Choose the Switch button to hold." preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *target in TOTKLauncherControlTargets()) {
        NSString *title = [target isEqual:@"default"] ? @"Default" : [target isEqual:@"none"] ? @"None" : target.uppercaseString;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action;
            [NSUserDefaults.standardUserDefaults setObject:target forKey:[@"TOTK_LAUNCHER_BIND_" stringByAppendingString:button]];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = tableView;
    sheet.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:path];
    [self presentViewController:sheet animated:YES completion:nil];
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

static BOOL valid_mouse_sensitivity(NSString *text) {
    return text.length > 0 && text.length <= 3 &&
        [text rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location == NSNotFound &&
        text.integerValue >= 1 && text.integerValue <= 100;
}

@interface TOTKLauncher () <UIDocumentPickerDelegate, UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UITableView *tableView;
@end
@implementation TOTKLauncher {
    TOTKSaveStore *_store;
    NSString *_unavailable;
    void (^_play)(void);
    BOOL _busy, _started;
    NSURL *_exportDirectory;
}
- (instancetype)initWithStore:(TOTKSaveStore *)store unavailable:(NSString *)reason play:(void (^)(void))play {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _store = store; _unavailable = reason; _play = [play copy]; self.title = @"Tears of the Kingdom";
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:[UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular]];
    card.accessibilityIdentifier = @"TOTKPrelaunchCard";
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 28;
    card.clipsToBounds = YES;
    [self.view addSubview:card];
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [card.contentView addSubview:self.tableView];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *width = [card.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-24];
    width.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *height = [card.heightAnchor constraintEqualToAnchor:safe.heightAnchor constant:-24];
    height.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [card.topAnchor constraintGreaterThanOrEqualToAnchor:safe.topAnchor constant:12],
        [card.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor constant:-12],
        [card.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:12],
        [card.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-12],
        [card.widthAnchor constraintLessThanOrEqualToConstant:500], width,
        [card.heightAnchor constraintLessThanOrEqualToConstant:760], height,
        [self.tableView.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
    ]];
    self.tableView.allowsFocus = YES;
    self.tableView.remembersLastFocusedIndexPath = YES;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationController.navigationBar.prefersLargeTitles = NO;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 5; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; return (NSInteger[]){1,4,5,4,1}[section];
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; return @[@"",@"Graphics",@"Controls",@"Saves",@"Language"][section];
}
- (BOOL)fullDisplayAvailable {
    CGSize size = self.view.window ? self.view.window.bounds.size : self.view.bounds.size;
    double shortSide = MIN(size.width,size.height), longSide = MAX(size.width,size.height);
    return shortSide > 0 && longSide <= shortSide * 16.0 / 9.0;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return _unavailable ?: @"Choose settings and manage saves before Play. Reopen the app to return here.";
    if (section == 1) return TOTKLauncherDisplaySettingsAvailable(NSBundle.mainBundle.infoDictionary)
        ? ([self fullDisplayAvailable] ? @"Changes apply at Play. Full display uses your screen’s aspect ratio." : @"Changes apply at Play. This display uses 16:9.")
        : @"This build supports 1280 × 720 at 16:9.";
    if (section == 2) return @"Controls apply at Play. Reopen the app to change them during a later session. Automatic hides touch buttons with a controller; Off requires one. Developer overrides take precedence.";
    if (section == 3) return @"Select a folder containing complete slot_00–slot_05 saves. Imports and restores create a backup first.";
    return @"Language follows the existing Settings app preference. Changes apply when you press Play.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.backgroundColor = [UIColor.secondarySystemGroupedBackgroundColor colorWithAlphaComponent:0.65];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSArray *titles = @[@[@"Play"],@[@"Render resolution",@"Aspect ratio",@"Performance overlay",@"Apple Metal HUD"],@[@"Touch controls",@"Controller type",@"Mouse sensitivity",@"Invert mouse Y",@"Button mappings"],
        @[@"Import save folder",@"Export save folder",@"Back up save",@"Restore backup"],@[@"Game language"]];
    cell.textLabel.text = titles[path.section][path.row];
    BOOL displaySettings = TOTKLauncherDisplaySettingsAvailable(NSBundle.mainBundle.infoDictionary);
    if (path.section == 1) {
        if (path.row == 0) cell.detailTextLabel.text = displaySettings
            ? [NSString stringWithFormat:@"%ld high",(long)TOTKLauncherRenderHeight(d)] : @"1280 × 720";
        else if (path.row == 1) cell.detailTextLabel.text = displaySettings && [self fullDisplayAvailable] && [TOTKLauncherAspect(d) isEqual:@"display"] ? @"Full display" : @"16:9";
        else if (path.row == 2) cell.detailTextLabel.text = @{@0:@"Off",@1:@"Full",@2:@"FPS only"}[@(TOTKLauncherHUD(d))];
        else cell.detailTextLabel.text = TOTKLauncherMetalHUD(d) ? @"On" : @"Off";
    }
    BOOL controlsOverride = NO;
    if (path.section == 2) {
        if (path.row == 0) cell.detailTextLabel.text = TOTKLauncherTouch(d) ? @"Automatic" : @"Off";
        else if (path.row == 1) { cell.detailTextLabel.text = @{@"auto":@"Automatic",@"xbox":@"Xbox",@"playstation":@"PlayStation",@"switch":@"Switch"}[TOTKLauncherControllerType(d)]; controlsOverride = getenv("TOTK_CONTROLS") != NULL; }
        else if (path.row == 2) { cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld / 100",(long)TOTKLauncherMouseSensitivity(d)]; controlsOverride = getenv("TOTK_MOUSE_SENSITIVITY") != NULL; }
        else if (path.row == 3) { cell.detailTextLabel.text = TOTKLauncherMouseInvertY(d) ? @"On" : @"Off"; controlsOverride = getenv("TOTK_MOUSE_INVERT_Y") != NULL; }
        else { cell.detailTextLabel.text = @"Edit"; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; controlsOverride = getenv("TOTK_CONTROLS") != NULL; }
        if (controlsOverride) cell.detailTextLabel.text = @"Developer override";
    }
    if (path.section == 4) cell.detailTextLabel.text = [self languageTitle:TOTKLauncherLanguage(d)];
    BOOL disabled = _busy || _started || controlsOverride || (path.section == 0 && _unavailable) || (path.section == 1 && path.row < 2 && !displaySettings);
    cell.userInteractionEnabled = !disabled;
    cell.textLabel.enabled = !disabled;
    cell.accessibilityLabel = cell.textLabel.text;
    cell.accessibilityValue = cell.detailTextLabel.text;
    if (disabled) cell.accessibilityTraits |= UIAccessibilityTraitNotEnabled;
    return cell;
}
- (NSString *)languageTitle:(NSString *)language {
    NSUInteger index = [TOTKLanguages() indexOfObject:language];
    return @[@"System",@"繁體中文",@"简体中文",@"English",@"日本語",@"Deutsch",@"Español",@"Français",@"Italiano",@"Nederlands",@"Русский",@"한국어"][index == NSNotFound ? 0 : index];
}
- (void)message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"TOTK" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)anchor:(UIAlertController *)sheet path:(NSIndexPath *)path {
    sheet.popoverPresentationController.sourceView = self.tableView;
    sheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:path];
}
- (void)choose:(NSArray<NSString *> *)titles path:(NSIndexPath *)path selected:(void (^)(NSUInteger))selected {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [titles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger index, BOOL *stop) {
        (void)stop; [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a; selected(index); [self.tableView reloadData];
        }]];
    }];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self anchor:sheet path:path]; [self presentViewController:sheet animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (_busy || _started) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (path.section == 0) {
        if (_unavailable) return;
        BOOL controller = NO;
        for (GCController *pad in GCController.controllers) if (pad.extendedGamepad) controller = YES;
        if (!TOTKLauncherTouch(d) && !controller) { [self message:@"Enable touch controls or connect a compatible controller before Play."]; return; }
        NSError *controlsError = nil;
        if (!TOTKLauncherPrepareControls(d,&controlsError)) { [self message:controlsError.localizedDescription ?: @"Cannot prepare controls. Play has not started."]; return; }
        if (![_store sealForPlay]) return;
        _started = YES; [self.tableView reloadData]; _play();
    } else if (path.section == 1 && path.row < 2) {
        if (!TOTKLauncherDisplaySettingsAvailable(NSBundle.mainBundle.infoDictionary)) return;
        if (path.row == 0) {
            [self choose:@[@"720 high",@"1080 high"] path:path selected:^(NSUInteger i) {
                [d setInteger:(NSInteger[]){720,1080}[i] forKey:@"TOTK_LAUNCHER_RENDER_HEIGHT"];
            }];
        } else {
            [self choose:[self fullDisplayAvailable] ? @[@"16:9",@"Full display"] : @[@"16:9"] path:path selected:^(NSUInteger i) {
                [d setObject:(@[@"16:9",@"display"])[i] forKey:@"TOTK_LAUNCHER_ASPECT"];
            }];
        }
    } else if (path.section == 1 && path.row == 2) {
        [self choose:@[@"Full",@"FPS only",@"Off"] path:path selected:^(NSUInteger i) { [d setInteger:(NSInteger[]){1,2,0}[i] forKey:@"TOTK_LAUNCHER_HUD"]; }];
    } else if (path.section == 1 && path.row == 3) {
        [self choose:@[@"On",@"Off"] path:path selected:^(NSUInteger i) { [d setBool:i == 0 forKey:@"TOTK_LAUNCHER_METAL_HUD"]; }];
    } else if (path.section == 2) {
        if (path.row == 0) {
            [self choose:@[@"Automatic",@"Off"] path:path selected:^(NSUInteger i) { [d setBool:i == 0 forKey:@"TOTK_LAUNCHER_TOUCH"]; }];
        } else if (path.row == 1 && !getenv("TOTK_CONTROLS")) {
            [self choose:@[@"Automatic",@"Xbox",@"PlayStation",@"Switch"] path:path selected:^(NSUInteger i) {
                [d setObject:(@[@"auto",@"xbox",@"playstation",@"switch"])[i] forKey:@"TOTK_LAUNCHER_CONTROLLER_TYPE"];
            }];
        } else if (path.row == 2 && !getenv("TOTK_MOUSE_SENSITIVITY")) [self changeMouseSensitivity];
        else if (path.row == 3 && !getenv("TOTK_MOUSE_INVERT_Y")) {
            [self choose:@[@"Off",@"On"] path:path selected:^(NSUInteger i) { [d setBool:i == 1 forKey:@"TOTK_LAUNCHER_MOUSE_INVERT_Y"]; }];
        } else if (path.row == 4 && !getenv("TOTK_CONTROLS")) {
            [self.navigationController pushViewController:[TOTKButtonMappings new] animated:YES];
        }
    } else if (path.section == 4) {
        NSMutableArray *titles = [NSMutableArray array];
        for (NSString *language in TOTKLanguages()) [titles addObject:[self languageTitle:language]];
        [self choose:titles path:path selected:^(NSUInteger i) { [d setObject:TOTKLanguages()[i] forKey:@"TOTK_LANG"]; }];
    } else if (path.section == 3) {
        if (path.row == 0) {
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
            picker.delegate = self; [self presentViewController:picker animated:YES completion:nil];
        } else if (path.row == 1) [self exportSave];
        else if (path.row == 2) [self perform:^NSString *(NSError **error) {
            return [self->_store backup:error] ? @"Backup created. You can select it under Restore backup." : nil;
        }];
        else {
            NSError *error = nil; NSArray *backups = [_store backups:&error];
            if (!backups.count) { [self message:error.localizedDescription ?: @"No backups yet."]; return; }
            [self choose:[backups valueForKey:@"lastPathComponent"] path:path selected:^(NSUInteger i) { [self confirmImport:backups[i] restore:YES]; }];
        }
    }
}
- (void)changeMouseSensitivity {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Mouse sensitivity" message:@"Enter a whole number from 1 to 100. Default is 50. Applies at Play." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.accessibilityLabel = @"Mouse sensitivity";
        field.text = [NSString stringWithFormat:@"%ld",(long)TOTKLauncherMouseSensitivity(NSUserDefaults.standardUserDefaults)];
    }];
    __weak UIAlertController *weakAlert = alert;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; NSString *text = weakAlert.textFields.firstObject.text;
        if (!valid_mouse_sensitivity(text)) return;
        [NSUserDefaults.standardUserDefaults setInteger:text.integerValue forKey:@"TOTK_LAUNCHER_MOUSE_SENSITIVITY"];
        [self.tableView reloadData];
    }];
    __weak UIAlertAction *weakSave = save;
    UITextField *field = alert.textFields.firstObject;
    [field addAction:[UIAction actionWithHandler:^(UIAction *action) {
        UITextField *input = (UITextField *)action.sender;
        weakSave.enabled = valid_mouse_sensitivity(input.text);
    }] forControlEvents:UIControlEventEditingChanged];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:save];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)perform:(NSString *(^)(NSError **))operation {
    if (_busy || _started) return;
    _busy = YES; [self.tableView reloadData];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *error = nil; NSString *result = operation(&error);
        dispatch_async(dispatch_get_main_queue(),^{
            self->_busy = NO; [self.tableView reloadData];
            [self message:result ?: error.localizedDescription ?: @"The transfer failed. Your active save was not replaced."];
        });
    });
}
- (void)confirmImport:(NSURL *)url restore:(BOOL)restore {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:restore ? @"Restore backup?" : @"Import save?"
        message:@"Your current save will be backed up before replacement." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:restore ? @"Restore" : @"Import" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        [self perform:^NSString *(NSError **error) {
            BOOL access = [url startAccessingSecurityScopedResource];
            __block BOOL ok = NO; __block NSError *transfer = nil;
            NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
            [coordinator coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges error:error byAccessor:^(NSURL *readURL) {
                ok = restore ? [self->_store restore:readURL error:&transfer] : [self->_store importDirectory:readURL error:&transfer];
            }];
            if (access) [url stopAccessingSecurityScopedResource];
            if (transfer && error) *error = transfer;
            return ok ? @"Save ready. Press Play to load it." : nil;
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)exportSave {
    if (_busy || _started) return;
    _busy = YES; [self.tableView reloadData];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *error = nil;
        NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        BOOL made = [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error];
        NSURL *save = made ? [self->_store exportToDirectory:directory error:&error] : nil;
        dispatch_async(dispatch_get_main_queue(),^{
            self->_busy = NO; [self.tableView reloadData];
            if (!save) { [NSFileManager.defaultManager removeItemAtURL:directory error:nil]; [self message:error.localizedDescription ?: @"Export failed."]; return; }
            self->_exportDirectory = directory;
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[save] asCopy:YES];
            picker.delegate = self; [self presentViewController:picker animated:YES completion:nil];
        });
    });
}
- (void)clearExport {
    if (_exportDirectory) [NSFileManager.defaultManager removeItemAtURL:_exportDirectory error:nil];
    _exportDirectory = nil;
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { (void)controller; [self clearExport]; }
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    if (_exportDirectory) { [self clearExport]; return; }
    if (urls.count == 1) [self confirmImport:urls.firstObject restore:NO];
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end
