#import "launcher.h"
#import "launcher_settings.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <GameController/GameController.h>

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
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *width = [self.tableView.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-24];
    width.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [self.tableView.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:12],
        [self.tableView.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-12],
        [self.tableView.widthAnchor constraintLessThanOrEqualToConstant:620], width
    ]];
    self.tableView.allowsFocus = YES;
    self.tableView.remembersLastFocusedIndexPath = YES;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationController.navigationBar.prefersLargeTitles = NO;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 5; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; return (NSInteger[]){1,3,1,4,1}[section];
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; return @[@"",@"Graphics",@"Controls",@"Saves",@"Language"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return _unavailable ?: @"Choose settings and manage saves before Play. Reopen the app to return here.";
    if (section == 1) return @"The current build renders at 1280 × 720. Further graphics modes are planned.";
    if (section == 2) return @"Automatic hides touch buttons with a connected controller. Off requires a controller.";
    if (section == 3) return @"Select a folder containing complete slot_00–slot_05 saves. Imports and restores create a backup first.";
    return @"Language follows the existing Settings app preference. Changes apply when you press Play.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSArray *titles = @[@[@"Play"],@[@"Render resolution",@"Performance overlay",@"Apple Metal HUD"],@[@"Touch controls"],
        @[@"Import save folder",@"Export save folder",@"Back up save",@"Restore backup"],@[@"Game language"]];
    cell.textLabel.text = titles[path.section][path.row];
    if (path.section == 1) {
        if (path.row == 0) cell.detailTextLabel.text = @"1280 × 720";
        else if (path.row == 1) cell.detailTextLabel.text = @{@0:@"Off",@1:@"Full",@2:@"FPS only"}[@(TOTKLauncherHUD(d))];
        else cell.detailTextLabel.text = TOTKLauncherMetalHUD(d) ? @"On" : @"Off";
    }
    if (path.section == 2) cell.detailTextLabel.text = TOTKLauncherTouch(d) ? @"Automatic" : @"Off";
    if (path.section == 4) cell.detailTextLabel.text = [self languageTitle:TOTKLauncherLanguage(d)];
    BOOL disabled = _busy || _started || (path.section == 0 && _unavailable) || (path.section == 1 && path.row == 0);
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
        if (![_store sealForPlay]) return;
        _started = YES; [self.tableView reloadData]; _play();
    } else if (path.section == 1 && path.row == 1) {
        [self choose:@[@"Full",@"FPS only",@"Off"] path:path selected:^(NSUInteger i) { [d setInteger:(NSInteger[]){1,2,0}[i] forKey:@"TOTK_LAUNCHER_HUD"]; }];
    } else if (path.section == 1 && path.row == 2) {
        [self choose:@[@"On",@"Off"] path:path selected:^(NSUInteger i) { [d setBool:i == 0 forKey:@"TOTK_LAUNCHER_METAL_HUD"]; }];
    } else if (path.section == 2) {
        [self choose:@[@"Automatic",@"Off"] path:path selected:^(NSUInteger i) { [d setBool:i == 0 forKey:@"TOTK_LAUNCHER_TOUCH"]; }];
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
