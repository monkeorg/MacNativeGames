#import "CanopyGames.h"
#import "CanopyCatalog.h"
#import "CanopySettings.h"
#import "CanopyPreparation.h"
#import "CanopyControllers.h"
#import "CanopySessionController.h"
#import "CanopyRuntime.h"
#import "CanopySaveStore.h"
#import "CanopyStorageController.h"
#import "../../../games/totk/ios/Sources/save_validation.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static UITableViewCell *GamesCell(UITableView *table, NSString *title, NSString *detail) {
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"value"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"value"];
    cell.textLabel.text = title; cell.detailTextLabel.text = detail;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.accessoryView = nil; cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.imageView.image = nil;
    return cell;
}
static void GamesAlert(UIViewController *owner, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    if (owner.presentedViewController) [owner dismissViewControllerAnimated:YES completion:^{ [owner presentViewController:alert animated:YES completion:nil]; }];
    else [owner presentViewController:alert animated:YES completion:nil];
}
static void GamesAnchor(UIAlertController *sheet, UITableView *table, NSIndexPath *path) {
    sheet.popoverPresentationController.sourceView = table;
    sheet.popoverPresentationController.sourceRect = [table rectForRowAtIndexPath:path];
}
static NSArray *MappingButtons(void) {
    return @[@"south",@"east",@"west",@"north",@"l3",@"r3",@"l1",@"r1",@"l2",@"r2",@"menu",@"view",@"left",@"up",@"right",@"down",@"touchpad",@"mouse_left",@"mouse_right",@"mouse_middle",@"mouse4",@"mouse5"];
}
static UIViewController *MakePlayersController(CanopyControllers *controllers);
static NSString *SettingApplicationDetail(NSString *key, id desired, CanopySettingsStateProvider provider) {
    if (!provider) return [desired description];
    NSDictionary *state = provider()[key];
    if (![state isKindOfClass:NSDictionary.class]) return @"Saved preference; application state has not been reported.";
    id effective = state[@"effectiveValue"];
    NSString *effectiveText = !effective || effective == NSNull.null ? @"unknown" : [effective description];
    return [NSString stringWithFormat:@"%@ • desired %@ • effective %@\n%@",state[@"state"] ?: @"unverified",[desired description],effectiveText,state[@"message"] ?: @""];
}
static void ApplySavedSettings(CanopySettings *settings, NSString *title, CanopySettingsApply apply) {
    if (!apply) return;
    NSError *error = nil; NSDictionary *desired = [settings settingsForTitleID:title error:&error];
    if (desired) apply(desired);
}

@interface CanopySaveController : UITableViewController <UIDocumentPickerDelegate>
- (instancetype)initWithStore:(CanopySaveStore *)store queue:(dispatch_queue_t)queue;
@end
@implementation CanopySaveController {
    CanopySaveStore *_store;
    dispatch_queue_t _queue;
    NSArray *_backups;
    NSString *_status;
    BOOL _busy, _importPicker, _rawImportPicker, _exportPicker, _cancelRequested;
    NSFileCoordinator *_coordinator;
    NSURL *_temporaryExport;
}
- (instancetype)initWithStore:(CanopySaveStore *)store queue:(dispatch_queue_t)queue {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _store = store; _queue = queue; _backups = @[]; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"Save management";
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 70;
    [self reloadBackups];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(saveBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_coordinator cancel]; NSURL *temporary = _temporaryExport;
    if (temporary) dispatch_async(_queue, ^{ [NSFileManager.defaultManager removeItemAtURL:temporary error:NULL]; });
}
- (void)refresh {
    self.navigationItem.rightBarButtonItem = _coordinator ? [[UIBarButtonItem alloc] initWithTitle:_cancelRequested ? @"Cancel requested" : @"Cancel access" style:UIBarButtonItemStylePlain target:self action:@selector(cancelAccess)] : nil;
    self.navigationItem.rightBarButtonItem.enabled = !_cancelRequested;
    [self.tableView reloadData];
}
- (void)performWork:(id (^)(NSError **))work completion:(void (^)(id, NSError *))completion {
    if (_busy || _store.sealed) return;
    _busy = YES; [self refresh];
    dispatch_async(_queue, ^{
        @autoreleasepool { NSError *error = nil; id result = work(&error);
            if (!error && (!result || ([result isKindOfClass:NSNumber.class] && ![result boolValue]))) error = [NSError errorWithDomain:@"CanopySaveUI" code:2 userInfo:@{NSLocalizedDescriptionKey:@"The save operation did not report successful completion. Check recovery status before retrying."}];
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_busy = NO; self->_coordinator = nil; self->_cancelRequested = NO;
                if (error) self->_status = error.localizedDescription;
                completion(result,error); [self refresh];
            });
        }
    });
}
- (void)reloadBackups {
    [self performWork:^id(NSError **error) { return [self->_store backups:error]; } completion:^(id result, NSError *error) {
        if (!error && [result isKindOfClass:NSArray.class]) self->_backups = result;
    }];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section == 0 ? 5 : MAX((NSInteger)_backups.count,1); }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return section == 0 ? @"This title • default profile" : @"Stored backups"; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    NSString *explanation = @"Canopy exports preserve opaque bytes in a versioned format. External Canopy exports and raw folders additionally require the actual trusted title-format validator; hashes alone are not a format check. Unknown titles cannot import external saves. Semantic editing is unavailable. Account identity is never exported or replaced. Transfers are locked while a native session may write saves.";
    return [NSString stringWithFormat:@"%@%@%@",_busy ? @"Working on the serialized save queue…\n\n" : @"",_status ? [_status stringByAppendingString:@"\n\n"] : @"",explanation];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell;
    if (!path.section) {
        NSArray *titles = @[@"Export Canopy save bundle",@"Import Canopy export",@"Import validated raw save folder",@"Back up active saves",@"Recover interrupted transaction"];
        NSString *detail = _store.sealed ? @"Locked for the native session" : path.row == 4 ? (_store.recoveryRequired ? @"Explicitly reconcile an unfinished transaction" : @"No recovery currently required") : @"Account identity remains separate";
        if ((path.row == 1 || path.row == 2) && !_store.externalImportSupported) detail = @"Unavailable: this title has no trusted save-format validator. Opaque export and internal backups remain available.";
        else if (path.row == 2) detail = @"Private staged copy, trusted title-structure validation and byte verification";
        cell = GamesCell(tableView,titles[(NSUInteger)path.row],detail);
    } else if (!_backups.count) cell = GamesCell(tableView,@"No stored backups",@"Create a backup before changing active saves.");
    else {
        NSDictionary *backup = _backups[(NSUInteger)path.row];
        cell = GamesCell(tableView,[backup[@"identifier"] description],@"Verified during restore; active data is backed up first.");
    }
    if (_busy || _store.sealed || (path.section && !_backups.count) || (!path.section && (path.row == 1 || path.row == 2) && !_store.externalImportSupported)) { cell.selectionStyle = UITableViewCellSelectionStyleNone; cell.textLabel.textColor = UIColor.secondaryLabelColor; }
    else cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)confirmTitle:(NSString *)title message:(NSString *)message action:(void (^)(void))action {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *selected) { (void)selected; action(); }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES]; if (_busy || _store.sealed) return;
    if (path.section) {
        if (!_backups.count) return;
        NSString *identifier = _backups[(NSUInteger)path.row][@"identifier"];
        [self confirmTitle:@"Restore this backup?" message:@"Active saves are backed up before replacement. Only this title/profile's bytes change; account identity is untouched." action:^{
            [self performWork:^id(NSError **error) { return @([self->_store restoreBackup:identifier error:error]); } completion:^(id result, NSError *error) { (void)result; if (!error) self->_status = @"Backup restored and byte-checked."; [self reloadBackups]; }];
        }]; return;
    }
    if (path.row == 0) [self exportBundle];
    else if (path.row == 1 || path.row == 2) {
        if (!_store.externalImportSupported) return;
        _importPicker = YES; _rawImportPicker = path.row == 2;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO]; picker.delegate = self; picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    } else if (path.row == 3) [self performWork:^id(NSError **error) { return [self->_store backup:error]; } completion:^(id result, NSError *error) { if (!error && result) self->_status = @"Active saves were backed up and verified."; [self reloadBackups]; }];
    else if (_store.recoveryRequired) [self confirmTitle:@"Recover the interrupted save replacement?" message:@"The store will reconcile its journal: roll back an unfinished replacement or verify and finalize a committed save. Account identity and ambiguous data are preserved." action:^{
        [self performWork:^id(NSError **error) { return @([self->_store recover:error]); } completion:^(id result, NSError *error) { (void)result; if (!error) self->_status = @"Save transaction recovery completed."; [self reloadBackups]; }];
    }];
}
- (void)exportBundle {
    NSURL *temporary = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[@"Canopy-export-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    _temporaryExport = temporary;
    [self performWork:^id(NSError **error) {
        if (![NSFileManager.defaultManager createDirectoryAtURL:temporary withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:error]) return nil;
        return [self->_store exportToDirectory:temporary error:error];
    } completion:^(id result, NSError *error) {
        if (error || ![result isKindOfClass:NSURL.class]) { [self cleanupExport]; return; }
        if (!self.view.window) { [self cleanupExport]; return; }
        self->_exportPicker = YES; self->_busy = YES;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[result] asCopy:YES]; picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    }];
}
- (void)cleanupExport {
    NSURL *temporary = _temporaryExport; _temporaryExport = nil;
    if (temporary) dispatch_async(_queue, ^{ [NSFileManager.defaultManager removeItemAtURL:temporary error:NULL]; });
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller; _busy = NO; _importPicker = NO; _rawImportPicker = NO; _exportPicker = NO; [self cleanupExport]; [self refresh];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (_exportPicker) { _exportPicker = NO; _busy = NO; _status = @"Canopy export handed to Files."; [self cleanupExport]; [self refresh]; return; }
    if (!_importPicker || urls.count != 1) return;
    _importPicker = NO; BOOL raw = _rawImportPicker; _rawImportPicker = NO; NSURL *source = urls.firstObject;
    [controller dismissViewControllerAnimated:YES completion:^{
        [self confirmTitle:raw ? @"Import this validated raw save folder?" : @"Import this Canopy export?"
            message:raw ? @"A private bounded copy must pass this title's trusted structural validator. Active saves are backed up before replacement; account identity is untouched." : @"A matching title/profile export and the trusted title-format validator are required. Active saves are backed up before replacement; account identity is untouched."
            action:^{ [self importBundle:source raw:raw]; }];
    }];
}
- (void)importBundle:(NSURL *)source raw:(BOOL)raw {
    if (_busy || _store.sealed || !_store.externalImportSupported) return;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    _coordinator = coordinator; _cancelRequested = NO;
    [self performWork:^id(NSError **error) {
        BOOL scoped = [source startAccessingSecurityScopedResource]; __block BOOL okay = NO;
        __block NSError *importError = nil; NSError *providerError = nil;
        [coordinator coordinateReadingItemAtURL:source options:0 error:&providerError byAccessor:^(NSURL *readURL) {
            NSError *readError = nil;
            okay = raw ? [self->_store importRawDirectoryURL:readURL error:&readError] : [self->_store importExportURL:readURL error:&readError]; importError = readError;
        }];
        if (scoped) [source stopAccessingSecurityScopedResource];
        if (!okay && error) *error = importError ?: [NSError errorWithDomain:@"CanopySaveUI" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The file provider could not complete access. The save store will be rechecked; do not assume a failed publication left active data unchanged."}];
        (void)providerError; return @(okay);
    } completion:^(id result, NSError *error) {
        if (!error && [result boolValue]) self->_status = raw ? @"Validated raw save folder imported and byte-checked. Account identity was preserved." : @"Canopy export imported, title-validated and byte-checked. Account identity was preserved.";
        [self reloadBackups];
    }];
}
- (void)cancelAccess {
    if (!_coordinator || _cancelRequested) return;
    _cancelRequested = YES; [_coordinator cancel];
    _status = @"Access cancellation requested. A save publication may already have completed; waiting for the authoritative result."; [self refresh];
}
- (void)saveBackground:(NSNotification *)notification {
    (void)notification;
    if (_importPicker) { _importPicker = NO; _rawImportPicker = NO; [self dismissViewControllerAnimated:NO completion:nil]; }
    [self cancelAccess];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    if (!path.section || !_backups.count || _busy || _store.sealed) return nil;
    NSString *identifier = _backups[(NSUInteger)path.row][@"identifier"];
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete backup" handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
        (void)action; (void)view; done(NO);
        [self confirmTitle:@"Delete this backup?" message:@"Only this stored backup is removed. Active saves and account identity are untouched. This cannot be undone." action:^{
            [self performWork:^id(NSError **error) { return @([self->_store removeBackup:identifier error:error]); } completion:^(id result, NSError *error) { (void)result; if (!error) self->_status = @"Backup deleted."; [self reloadBackups]; }];
        }];
    }];
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[remove]]; configuration.performsFirstActionWithFullSwipe = NO; return configuration;
}
@end

@interface CanopyMappingController : UITableViewController
@property(nonatomic, copy) CanopySettingsApply applySettings;
@property(nonatomic, copy) CanopySettingsStateProvider settingStates;
- (instancetype)initWithSettings:(CanopySettings *)settings titleID:(NSString *)titleID;
@end
@implementation CanopyMappingController {
    CanopySettings *_settings;
    NSString *_titleID;
}
- (instancetype)initWithSettings:(CanopySettings *)settings titleID:(NSString *)titleID {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _settings = settings; _titleID = [titleID copy]; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"Button mappings";
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 65;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return (NSInteger)MappingButtons().count; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    if (self.settingStates) {
        NSError *error = nil; NSDictionary *values = [_settings settingsForTitleID:_titleID error:&error];
        return values ? SettingApplicationDetail(@"buttonMappings",values[@"buttonMappings"],self.settingStates) : error.localizedDescription;
    }
    return @"Saved for this title only. Default retains the runtime layout; other choices map a held physical button. Runtime application requires a supported session and remains unverified here.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    NSError *error = nil; NSDictionary *values = [_settings settingsForTitleID:_titleID error:&error];
    NSString *button = MappingButtons()[(NSUInteger)path.row];
    NSString *detail = values ? (values[@"buttonMappings"][button] ?: @"default") : @"Metadata recovery required";
    UITableViewCell *cell = GamesCell(tableView, button, detail);
    if (values) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    NSError *error = nil; NSDictionary *values = [_settings settingsForTitleID:_titleID error:&error];
    if (!values) { GamesAlert(self,@"Settings unavailable",error.localizedDescription); return; }
    NSString *button = MappingButtons()[(NSUInteger)path.row];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:button message:@"Save the target button for this game." preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *targets = @[@"default",@"none",@"a",@"b",@"x",@"y",@"lstick",@"rstick",@"l",@"r",@"zl",@"zr",@"plus",@"minus",@"left",@"up",@"right",@"down"];
    for (NSString *target in targets) [sheet addAction:[UIAlertAction actionWithTitle:target style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; NSError *writeError = nil;
        NSDictionary *current = [self->_settings settingsForTitleID:self->_titleID error:&writeError];
        if (!current) { GamesAlert(self,@"Could not save mapping",writeError.localizedDescription); return; }
        NSMutableDictionary *mappings = [current[@"buttonMappings"] mutableCopy]; mappings[button] = target;
        if (![self->_settings setValue:mappings forSetting:@"buttonMappings" titleID:self->_titleID error:&writeError]) GamesAlert(self,@"Could not save mapping",writeError.localizedDescription);
        else ApplySavedSettings(self->_settings,self->_titleID,self.applySettings);
        [self.tableView reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    GamesAnchor(sheet,tableView,path); [self presentViewController:sheet animated:YES completion:nil];
}
@end

@interface CanopyGameDetails : UITableViewController
@property(nonatomic, copy) CanopySettingsApply applySettings;
@property(nonatomic, copy) CanopySettingsStateProvider settingStates;
@property(nonatomic, strong) CanopyControllers *controllers;
- (instancetype)initWithEntry:(NSDictionary *)entry settings:(CanopySettings *)settings;
@end
@implementation CanopyGameDetails {
    NSDictionary *_entry;
    CanopySettings *_settings;
    CanopySaveStore *_saves;
    dispatch_queue_t _saveQueue;
    BOOL _saveLoading;
    NSString *_saveError;
}
- (instancetype)initWithEntry:(NSDictionary *)entry settings:(CanopySettings *)settings {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _entry = [entry copy]; _settings = settings; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = _entry[@"displayName"];
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 70;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Rename" style:UIBarButtonItemStylePlain target:self action:@selector(rename)];
    if (!self.settingStates) [self loadSaveStore];
}
- (void)loadSaveStore {
    if (_saveLoading || _saves || self.settingStates) return;
    _saveLoading = YES; _saveError = nil;
    if (!_saveQueue) _saveQueue = dispatch_queue_create("org.monkeorg.canopy.save-profile",DISPATCH_QUEUE_SERIAL);
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *profiles = [[support URLByAppendingPathComponent:@"Canopy" isDirectory:YES] URLByAppendingPathComponent:@"Profiles" isDirectory:YES];
    NSString *title = _entry[@"titleID"];
    dispatch_async(_saveQueue, ^{
        NSError *error = nil;
        // This is a trusted native format selection, never a validator name
        // supplied by a manifest or a display label. fs_host.c defines this ID.
        CanopySaveValidator validator = nil;
        if ([title isEqualToString:@"0100f2c0115b6000"]) validator = ^BOOL(NSURL *directory, NSError **validationError) { return TOTKSaveValidateDirectory(directory,validationError); };
        CanopySaveStore *store = [[CanopySaveStore alloc] initWithRootURL:profiles titleID:title profileID:@"default" externalValidator:validator error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{ self->_saveLoading = NO; self->_saves = store; self->_saveError = error.localizedDescription; [self.tableView reloadData]; });
    });
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 5; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section < 3 ? 6 : section == 3 ? 2 : 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return @[@"Prepared assets",@"Graphics preferences",@"Control preferences",@"Saves & native session",@"Language"][(NSUInteger)section]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        if (self.settingStates) return @"Preparation integrity is distinct from Nintendo signature authenticity and native execution. Session settings below report the actual host's desired/effective state; physical gameplay acceptance remains separate.";
        return [CanopyRuntime trustedProfileForTitleID:_entry[@"titleID"]] ? @"Prepared assets are separate from the compiled, reviewed native host profile. Starting that host remains subject to exact hashes, save sealing and executable permissions; device acceptance is not implied." : @"Preparation integrity is distinct from Nintendo signature authenticity and native execution. No reviewed native host profile is present; gameplay is unavailable.";
    }
    if (section == 3) return self.settingStates ? @"Save operations remain sealed while native save writers may exist. This single-use host requires closing the app before save transfers; opening settings does not unseal saves." : (_saveError ?: @"Canopy exports preserve opaque save bytes and account separation. Raw save formats and game-specific editing require a validated title adapter. A native session can start only with a compiled, reviewed exact-title host profile; preparation never grants execution permission.");
    if (self.settingStates) return @"Desired preferences are saved separately from effective session values. Applied means the host reported the change; restartRequired keeps the current value. Rejected and unsupported changes are not active. This menu captures input; guest execution may continue.";
    return @"These preferences persist for this title. Applying them to a running game is not verified in this build. A supported runtime/device must establish each setting's capabilities and live or next-start behavior.";
}
- (NSArray *)keysForSection:(NSInteger)section {
    if (section == 1) return @[@"fpsLimit",@"renderHeight",@"aspect",@"hud",@"metalHUD",@"taa"];
    if (section == 2) return @[@"touch",@"controllerType",@"mouseSensitivity",@"mouseInvertY",@"buttonMappings",@"players"];
    return @[@"language"];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == 0) {
        NSArray *titles = @[@"Title ID",@"Generation",@"Private assets",@"Integrity",@"Source SHA-256",@"Preparation recipe"];
        NSDictionary *integrity = _entry[@"integrity"];
        NSString *checks = [NSString stringWithFormat:@"ExeFS %@ • RomFS %@ • signature not verified",[integrity[@"exefsVerified"] boolValue] ? @"verified" : @"unverified",[integrity[@"romfsVerified"] boolValue] ? @"verified" : @"unverified"];
        NSString *assets = [NSString stringWithFormat:@"%@ files • %@",_entry[@"assetCount"],[NSByteCountFormatter stringFromByteCount:[_entry[@"assetBytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]];
        NSArray *details = @[_entry[@"titleID"],_entry[@"generationID"],assets,checks,_entry[@"sourceSHA256"],_entry[@"recipeID"]];
        UITableViewCell *cell = GamesCell(tableView,titles[(NSUInteger)path.row],details[(NSUInteger)path.row]); cell.selectionStyle = UITableViewCellSelectionStyleNone; return cell;
    }
    if (path.section == 3) {
        BOOL trusted = [CanopyRuntime trustedProfileForTitleID:_entry[@"titleID"]] != nil;
        NSString *title = path.row == 0 ? @"Manage saves and backups" : trusted ? @"Start reviewed native host" : @"Gameplay unavailable";
        NSString *detail = path.row == 0 ? (_saveLoading ? @"Opening the private save profile…" : _saveError ?: @"Canopy export/import, backup, restore and recovery") : @"No compiled reviewed native profile is present for this title";
        if (path.row == 1 && trusted) detail = @"Real native host integration • device acceptance remains separate";
        if (self.settingStates || _saves.sealed) { detail = path.row == 0 ? @"Locked while the native host may write saves" : @"Native host owns this profile; close the app before another session"; if (path.row == 1) title = @"Native session owns this profile"; }
        UITableViewCell *cell = GamesCell(tableView,title,detail);
        BOOL enabled = !self.settingStates && !_saveLoading && !_saves.sealed && (path.row == 0 || (trusted && _saves && !_saves.recoveryRequired));
        if (enabled) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        else { cell.selectionStyle = UITableViewCellSelectionStyleNone; cell.textLabel.textColor = UIColor.secondaryLabelColor; }
        return cell;
    }
    NSArray *titles = path.section == 1 ? @[@"Target frame rate",@"Render height",@"Aspect ratio",@"Performance overlay",@"Apple Metal HUD",@"Temporal anti-aliasing"] : path.section == 2 ? @[@"Touch controls",@"Controller layout",@"Mouse sensitivity",@"Invert mouse Y",@"Button mappings",@"Players & controllers"] : @[@"Language"];
    NSString *key = [self keysForSection:path.section][(NSUInteger)path.row];
    NSError *error = nil; NSDictionary *values = [_settings settingsForTitleID:_entry[@"titleID"] error:&error];
    id value = values[key];
    NSString *detail = values ? [value description] : @"Metadata recovery required";
    if ([key isEqual:@"hud"] && values) detail = @[@"Off",@"Full",@"FPS only"][[value unsignedIntegerValue]];
    if ([key isEqual:@"language"] && [value isEqual:@""]) detail = @"System";
    if ([key isEqual:@"buttonMappings"] && values) detail = @"Per-game controller and mouse buttons";
    if ([key isEqual:@"players"]) detail = @"Assign, unassign or swap connected controllers";
    else if (values && self.settingStates) detail = SettingApplicationDetail(key,value,self.settingStates);
    UITableViewCell *cell = GamesCell(tableView,titles[(NSUInteger)path.row],detail);
    if (values && [@[@"touch",@"mouseInvertY",@"metalHUD",@"taa"] containsObject:key]) {
        UISwitch *toggle = [UISwitch new]; toggle.on = [value boolValue]; toggle.accessibilityIdentifier = key;
        toggle.accessibilityLabel = titles[(NSUInteger)path.row];
        toggle.accessibilityHint = self.settingStates ? SettingApplicationDetail(key,value,self.settingStates) : @"Saves this preference for this game. Runtime application is unverified.";
        [toggle addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle; if (!self.settingStates) cell.detailTextLabel.text = @"Saved for a supported session"; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (values) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if ([key isEqual:@"players"] && self.controllers) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)toggle:(UISwitch *)toggle {
    NSError *error = nil;
    if (![_settings setValue:@(toggle.on) forSetting:toggle.accessibilityIdentifier titleID:_entry[@"titleID"] error:&error]) GamesAlert(self,@"Could not save preference",error.localizedDescription);
    else ApplySavedSettings(_settings,_entry[@"titleID"],self.applySettings);
    [self.tableView reloadData];
}
- (void)rename {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename prepared title" message:@"Changes only the local display name; prepared assets are unchanged." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = [self->_settings displayNameForTitleID:self->_entry[@"titleID"]] ?: self->_entry[@"displayName"]; field.accessibilityLabel = @"Display name"; }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; NSError *error = nil;
        if ([self->_settings setDisplayName:weakAlert.textFields.firstObject.text ?: @"" forTitleID:self->_entry[@"titleID"] error:&error]) self.title = [self->_settings displayNameForTitleID:self->_entry[@"titleID"]];
        else GamesAlert(self,@"Could not rename title",error.localizedDescription);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES]; if (!path.section) return;
    if (path.section == 3) {
        if (self.settingStates || _saveLoading || _saves.sealed) return;
        if (!_saves) { [self loadSaveStore]; return; }
        if (path.row == 0) [self.navigationController pushViewController:[[CanopySaveController alloc] initWithStore:_saves queue:_saveQueue] animated:YES];
        else [self startNativeSession];
        return;
    }
    if (path.section == 2 && path.row == 5) {
        if (self.controllers) [self.navigationController pushViewController:MakePlayersController(self.controllers) animated:YES];
        return;
    }
    NSError *error = nil; NSDictionary *values = [_settings settingsForTitleID:_entry[@"titleID"] error:&error];
    if (!values) { GamesAlert(self,@"Settings unavailable",error.localizedDescription); return; }
    NSString *key = [self keysForSection:path.section][(NSUInteger)path.row];
    if ([@[@"touch",@"mouseInvertY",@"metalHUD",@"taa"] containsObject:key]) return;
    if ([key isEqual:@"buttonMappings"]) {
        CanopyMappingController *mappings = [[CanopyMappingController alloc] initWithSettings:_settings titleID:_entry[@"titleID"]];
        mappings.applySettings = self.applySettings; mappings.settingStates = self.settingStates;
        [self.navigationController pushViewController:mappings animated:YES]; return;
    }
    if ([key isEqual:@"mouseSensitivity"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Mouse sensitivity" message:@"Whole number from 1 to 100. Default is 50." preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = [values[key] description]; field.keyboardType = UIKeyboardTypeNumberPad; field.accessibilityLabel = @"Mouse sensitivity"; }];
        __weak UIAlertController *weakAlert = alert;
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action; NSString *text = weakAlert.textFields.firstObject.text ?: @"";
            NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]; NSError *writeError = nil;
            if (!text.length || text.length > 3 || [text rangeOfCharacterFromSet:invalid].location != NSNotFound ||
                ![self->_settings setValue:@(text.integerValue) forSetting:key titleID:self->_entry[@"titleID"] error:&writeError]) GamesAlert(self,@"Could not save sensitivity",writeError.localizedDescription ?: @"Enter a whole number from 1 to 100.");
            else ApplySavedSettings(self->_settings,self->_entry[@"titleID"],self.applySettings);
            [self.tableView reloadData];
        }]]; [self presentViewController:alert animated:YES completion:nil]; return;
    }
    NSDictionary *choices = @{@"fpsLimit":@[@30,@40,@60],@"renderHeight":@[@720,@1080],@"aspect":@[@"16:9",@"display"],@"hud":@[@0,@1,@2],@"controllerType":@[@"auto",@"xbox",@"playstation",@"switch"],@"language":@[@"",@"zh-Hant",@"zh-Hans",@"en-US",@"ja",@"de",@"es",@"fr",@"it",@"nl",@"ru",@"ko"]};
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Save per-game preference" message:@"Runtime application remains unverified." preferredStyle:UIAlertControllerStyleActionSheet];
    for (id option in choices[key]) {
        NSString *label = [option description];
        if ([key isEqual:@"language"] && [option isEqual:@""]) label = @"System";
        if ([key isEqual:@"hud"]) label = @[@"Off",@"Full",@"FPS only"][[option unsignedIntegerValue]];
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action; NSError *writeError = nil;
            if (![self->_settings setValue:option forSetting:key titleID:self->_entry[@"titleID"] error:&writeError]) GamesAlert(self,@"Could not save preference",writeError.localizedDescription);
            else ApplySavedSettings(self->_settings,self->_entry[@"titleID"],self.applySettings);
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    GamesAnchor(sheet,tableView,path); [self presentViewController:sheet animated:YES completion:nil];
}
- (void)startNativeSession {
    if (![CanopyRuntime trustedProfileForTitleID:_entry[@"titleID"]] || !_saves || _saves.sealed || _saves.recoveryRequired || !self.controllers) return;
    for (NSDictionary *device in self.controllers.devices) if ([device[@"player"] integerValue] > 0) {
        GamesAlert(self,@"This host supports Player 1 only",@"Unassign other player seats before starting this native host. Independent assignment infrastructure does not establish multiplayer support."); return;
    }
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *base = [support URLByAppendingPathComponent:@"Canopy" isDirectory:YES];
    NSURL *prepared = [base URLByAppendingPathComponent:@"Prepared" isDirectory:YES];
    NSURL *cache = [[base URLByAppendingPathComponent:@"Caches" isDirectory:YES] URLByAppendingPathComponent:_entry[@"titleID"] isDirectory:YES];
    NSError *error = nil;
    CanopySessionController *session = [[CanopySessionController alloc] initWithEntry:_entry preparedRootURL:prepared settings:_settings controllers:self.controllers saveStore:_saves saveQueue:_saveQueue cacheURL:cache error:&error];
    if (!session) { GamesAlert(self,@"Native session unavailable",error.localizedDescription); return; }
    [self.navigationController pushViewController:session animated:YES];
}
@end

@interface CanopyPlayersController : UITableViewController
- (instancetype)initWithControllers:(CanopyControllers *)controllers;
@end
static UIViewController *MakePlayersController(CanopyControllers *controllers) { return [[CanopyPlayersController alloc] initWithControllers:controllers]; }
@implementation CanopyPlayersController {
    CanopyControllers *_controllers;
}
- (instancetype)initWithControllers:(CanopyControllers *)controllers {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _controllers = controllers;
    return self;
}
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"Players & controllers"; self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 65; }
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated]; __weak CanopyPlayersController *weakSelf = self;
    _controllers.stateDidChange = ^{ [weakSelf.tableView reloadData]; };
    (void)[_controllers setFocused:NO]; [self.tableView reloadData];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; _controllers.stateDidChange = nil; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section == 0 ? 4 : MAX((NSInteger)_controllers.devices.count,1); }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return section == 0 ? @"Player assignments" : @"Connected devices"; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section; return @"Assignments use real connected controllers and remain local to this app session. Menus keep gameplay input inactive. Device compatibility and a real multiplayer game session still need physical acceptance.";
}
- (NSDictionary *)deviceForPlayer:(NSInteger)player {
    for (NSDictionary *device in _controllers.devices) if ([device[@"player"] integerValue] == player) return device;
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    if (!path.section) {
        NSDictionary *device = [self deviceForPlayer:path.row];
        UITableViewCell *cell = GamesCell(tableView,[NSString stringWithFormat:@"Player %ld",(long)path.row+1],device ? device[@"name"] : @"Unassigned"); cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return cell;
    }
    NSArray *devices = _controllers.devices;
    if (!devices.count) { UITableViewCell *cell = GamesCell(tableView,@"No connected controllers",@"Connect a supported controller using iPadOS Bluetooth settings."); cell.selectionStyle = UITableViewCellSelectionStyleNone; return cell; }
    NSDictionary *device = devices[(NSUInteger)path.row];
    NSString *detail = ![device[@"supported"] boolValue] ? @"This controller has no supported extended gamepad layout" : [device[@"player"] integerValue] < 0 ? @"Unassigned" : [NSString stringWithFormat:@"Player %ld",[device[@"player"] longValue]+1];
    UITableViewCell *cell = GamesCell(tableView,device[@"name"],detail); cell.selectionStyle = UITableViewCellSelectionStyleNone; return cell;
}
- (void)routingResult:(enum mng_player_status)status {
    if (status != MNG_PLAYER_OK) GamesAlert(self,@"Assignment unavailable",@"The controller disconnected, the seat is occupied, or its layout is unsupported. Refresh the assignments and try again.");
    [self.tableView reloadData];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES]; if (path.section) return;
    unsigned seat = (unsigned)path.row;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Player %u",seat+1] message:@"Assign an unassigned controller, clear this seat, or explicitly swap seats." preferredStyle:UIAlertControllerStyleActionSheet];
    if ([self deviceForPlayer:path.row]) [sheet addAction:[UIAlertAction actionWithTitle:@"Unassign" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { (void)action; [self routingResult:[self->_controllers unassignPlayer:seat]]; }]];
    else for (NSDictionary *device in _controllers.devices) if ([device[@"supported"] boolValue] && [device[@"player"] integerValue] < 0) {
        uint64_t identifier = [device[@"id"] unsignedLongLongValue];
        [sheet addAction:[UIAlertAction actionWithTitle:device[@"name"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { (void)action; [self routingResult:[self->_controllers assignDevice:identifier toPlayer:seat]]; }]];
    }
    for (unsigned other = 0; other < 4; ++other) if (other != seat && ([self deviceForPlayer:other] || [self deviceForPlayer:seat])) {
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Swap with Player %u",other+1] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { (void)action; [self routingResult:[self->_controllers swapPlayer:seat withPlayer:other]]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    GamesAnchor(sheet,tableView,path); [self presentViewController:sheet animated:YES completion:nil];
}
@end

@interface CanopyGamesController : UITableViewController <UIDocumentPickerDelegate>
@end
@implementation CanopyGamesController {
    NSURL *_preparedRoot, *_metadataRoot, *_pendingSource, *_pendingUpdate;
    CanopySettings *_settings;
    CanopyPreparation *_preparation;
    CanopyControllers *_controllers;
    NSArray *_entries, *_issues;
    NSString *_status, *_metadataError, *_progressText;
    BOOL _refreshing, _cancelRequested, _withUpdate;
    NSUInteger _scanToken, _pickerStage;
    dispatch_queue_t _catalogQueue;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"Canopy"; self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 90;
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *canopy = [support URLByAppendingPathComponent:@"Canopy" isDirectory:YES];
    _preparedRoot = [canopy URLByAppendingPathComponent:@"Prepared" isDirectory:YES];
    _metadataRoot = [canopy URLByAppendingPathComponent:@"Metadata" isDirectory:YES];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:_preparedRoot withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) _status = @"The private preparation directory could not be created.";
    _settings = [[CanopySettings alloc] initWithDirectoryURL:_metadataRoot];
    if (![_settings load:&error]) _metadataError = error.localizedDescription;
    _preparation = [[CanopyPreparation alloc] initWithPreparedRootURL:_preparedRoot];
    _controllers = [CanopyControllers new]; (void)[_controllers setFocused:NO];
    _catalogQueue = dispatch_queue_create("org.monkeorg.canopy.catalog", DISPATCH_QUEUE_SERIAL);
    _entries = @[]; _issues = @[];
    __weak CanopyGamesController *weakSelf = self;
    _preparation.progress = ^(NSString *phase, uint64_t done, uint64_t total) {
        CanopyGamesController *owner = weakSelf; if (!owner) return;
        owner->_progressText = [NSString stringWithFormat:@"%@ • %llu / %llu",phase,(unsigned long long)done,(unsigned long long)total];
        [owner refreshUI];
    };
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [self reloadCatalog];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; (void)[_controllers setFocused:NO];
    if (_settings) [self reloadCatalog];
}
- (BOOL)working { return _refreshing || _preparation.busy || _pickerStage != 0; }
- (void)refreshUI {
    if (_preparation.busy) self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:_cancelRequested ? @"Cancel requested" : @"Cancel preparation" style:UIBarButtonItemStylePlain target:self action:@selector(cancelPreparation)];
    else self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Prepare game" style:UIBarButtonItemStylePlain target:self action:@selector(chooseSource)];
    self.navigationItem.rightBarButtonItem.enabled = !_cancelRequested && (!_refreshing || _preparation.busy) && !_pickerStage;
    [self.tableView reloadData];
}
- (void)reloadCatalog {
    if (_refreshing || _preparation.busy) return;
    _refreshing = YES; NSUInteger token = ++_scanToken; [self refreshUI];
    NSURL *root = _preparedRoot, *metadata = _metadataRoot;
    dispatch_async(_catalogQueue, ^{
        CanopySettings *snapshot = [[CanopySettings alloc] initWithDirectoryURL:metadata];
        NSError *metadataError = nil; (void)[snapshot load:&metadataError];
        CanopyCatalog *catalog = [[CanopyCatalog alloc] initWithPreparedRootURL:root settings:snapshot];
        NSError *error = nil; BOOL success = [catalog reload:&error];
        NSArray *entries = catalog.entries, *issues = catalog.issues;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != self->_scanToken) return;
            self->_refreshing = NO;
            if (success) { self->_entries = entries; self->_issues = issues; }
            else self->_status = error.localizedDescription;
            NSError *settingsError = nil;
            if (![self->_settings load:&settingsError]) self->_metadataError = settingsError.localizedDescription;
            else self->_metadataError = nil;
            [self refreshUI];
        });
    });
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section == 0 ? MAX((NSInteger)_entries.count,1) : 6; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return section == 0 ? @"Prepared games" : @"Library tools"; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 1) return @"The inspection history remains separate from prepared assets. Resetting title metadata changes only names and preferences; it never deletes prepared assets, saves or source files.";
    NSMutableArray *messages = [NSMutableArray arrayWithObject:@"Prepared assets do not establish game compatibility. Gameplay is unavailable in this build."];
    if (_preparation.busy) [messages addObject:_progressText ?: @"Waiting for coordinated file access…"];
    if (_preparation.busy && _preparation.jobIdentifier) [messages addObject:[NSString stringWithFormat:@"Job %@",_preparation.jobIdentifier]];
    if (_refreshing) [messages addObject:@"Verifying prepared assets in the background…"];
    if (_status) [messages addObject:_status];
    if (_metadataError) [messages addObject:_metadataError];
    if (_issues.count) [messages addObject:[NSString stringWithFormat:@"%lu prepared entries need attention. %@",(unsigned long)_issues.count,[_issues componentsJoinedByString:@"\n"]]];
    return [messages componentsJoinedByString:@"\n\n"];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    if (!path.section) {
        if (!_entries.count) {
            UITableViewCell *cell = GamesCell(tableView,@"Your private game library",@"Choose your own NSP or XCI and a local key file to prepare verified private assets. No game content or keys are bundled with Canopy.");
            cell.imageView.image = [UIImage imageNamed:@"Canopy.png"]; cell.selectionStyle = UITableViewCellSelectionStyleNone; return cell;
        }
        NSDictionary *entry = _entries[(NSUInteger)path.row];
        UITableViewCell *cell = GamesCell(tableView,[_settings displayNameForTitleID:entry[@"titleID"]] ?: entry[@"displayName"],@"Prepared assets • gameplay unavailable");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if ([self working]) cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSArray *titles = @[@"Prepare game",@"Players & controllers",@"Inspection history",@"Verify library",@"Storage",@"Reset title metadata"];
    NSArray *details = @[@"Base NSP/XCI, optional matching update, then local keys",@"Assign connected controllers to four independent seats",@"Read-only container metadata from the earlier inspector",@"Rehash prepared assets and reload current generations",@"Verify, select and manage prepared versions, unfinished jobs and private shader caches",@"Explicit recovery for display names and preferences only"];
    UITableViewCell *cell = GamesCell(tableView,titles[(NSUInteger)path.row],details[(NSUInteger)path.row]);
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if ([self working]) { cell.textLabel.textColor = UIColor.secondaryLabelColor; cell.selectionStyle = UITableViewCellSelectionStyleNone; }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES]; if ([self working]) return;
    if (!path.section) {
        if (_entries.count) { CanopyGameDetails *detail = [[CanopyGameDetails alloc] initWithEntry:_entries[(NSUInteger)path.row] settings:_settings]; detail.controllers = _controllers; [self.navigationController pushViewController:detail animated:YES]; }
        return;
    }
    if (path.row == 0) [self chooseSource];
    else if (path.row == 1) [self.navigationController pushViewController:[[CanopyPlayersController alloc] initWithControllers:_controllers] animated:YES];
    else if (path.row == 2) [self.navigationController pushViewController:CanopyMakeInspectionHistoryController() animated:YES];
    else if (path.row == 3) [self reloadCatalog];
    else if (path.row == 4) {
        NSURL *cache = [[_preparedRoot URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"Caches" isDirectory:YES];
        CanopyStorageController *storage = CanopyMakeStorageController(_preparedRoot,cache);
        __weak CanopyGamesController *owner = self;
        storage.mutationAllowed = ^BOOL { CanopyGamesController *current = owner; return current && ![current working]; };
        [self.navigationController pushViewController:storage animated:YES];
    }
    else [self resetMetadata];
}
- (void)chooseSource {
    if ([self working] || self.presentedViewController) return;
    _pickerStage = 5; [self refreshUI];
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Prepare private game assets"
        message:@"Choose base-only preparation or a base plus matching update. To update an existing prepared title, select its original base again. The latest declared matching update revision is selected automatically."
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *paired in @[@NO,@YES]) [menu addAction:[UIAlertAction actionWithTitle:paired.boolValue ? @"Base + update" : @"Base only" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; if (self->_pickerStage != 5) return;
        self->_withUpdate = paired.boolValue; self->_pickerStage = 1;
        [self dismissViewControllerAnimated:YES completion:^{ [self presentDataPickerForStage:1]; }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { (void)action; [self clearSelection]; [self refreshUI]; }]];
    menu.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)clearSelection { _pendingSource = nil; _pendingUpdate = nil; _withUpdate = NO; _pickerStage = 0; }
- (void)presentDataPickerForStage:(NSUInteger)stage {
    if (_pickerStage != stage || (stage == 4 && !_pendingSource)) return;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:NO];
    picker.title = stage == 4 ? @"Choose matching update NSP/XCI" : @"Choose original base NSP/XCI";
    picker.allowsMultipleSelection = NO; picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)chooseKeys {
    if (!_pendingSource || (_withUpdate && !_pendingUpdate)) { [self clearSelection]; [self refreshUI]; return; }
    _pickerStage = 2;
    UIAlertController *explanation = [UIAlertController alertControllerWithTitle:@"Choose your local key file"
        message:@"Keys are used in memory for this preparation job. Canopy does not retain the selected key file, its path or bookmarks. Use only your own local inputs."
        preferredStyle:UIAlertControllerStyleAlert];
    [explanation addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { (void)action; [self clearSelection]; [self refreshUI]; }]];
    [explanation addAction:[UIAlertAction actionWithTitle:@"Choose file" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        if (self->_pickerStage != 2 || !self->_pendingSource) return;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:NO];
        picker.allowsMultipleSelection = NO; picker.delegate = self;
        [self dismissViewControllerAnimated:YES completion:^{
            if (self->_pickerStage == 2 && self->_pendingSource) [self presentViewController:picker animated:YES completion:nil];
        }];
    }]];
    [self presentViewController:explanation animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller; [self clearSelection]; [self refreshUI];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count != 1) { [self clearSelection]; [self refreshUI]; return; }
    NSURL *url = urls.firstObject;
    if (_pickerStage == 1 || _pickerStage == 4) {
        if (![@[@"nsp",@"xci"] containsObject:url.pathExtension.lowercaseString]) {
            [self clearSelection]; [self refreshUI]; GamesAlert(self,@"Unsupported preparation input",@"Choose an NSP or XCI container. Folder preparation and unsupported NCA layouts are separate work."); return;
        }
        if (_pickerStage == 1) {
            _pendingSource = url;
            if (_withUpdate) { _pickerStage = 4; [controller dismissViewControllerAnimated:YES completion:^{ [self presentDataPickerForStage:4]; }]; }
            else [controller dismissViewControllerAnimated:YES completion:^{ [self chooseKeys]; }];
        } else {
            _pendingUpdate = url;
            [controller dismissViewControllerAnimated:YES completion:^{ [self chooseKeys]; }];
        }
    } else if (_pickerStage == 2 && _pendingSource) {
        NSURL *source = _pendingSource, *update = _pendingUpdate;
        [self clearSelection]; _pickerStage = 3;
        [controller dismissViewControllerAnimated:YES completion:^{ [self startSource:source update:update keys:url]; }];
    }
}
- (void)startSource:(NSURL *)source update:(NSURL *)update keys:(NSURL *)keys {
    if (_pickerStage != 3) return;
    _pickerStage = 0;
    if (_preparation.busy || _refreshing) { _status = @"Another library operation is still running. Select your files again after it completes."; [self refreshUI]; return; }
    _cancelRequested = NO; _progressText = nil; _status = nil;
    BOOL accepted = [_preparation startSourceURL:source updateURL:update keysURL:keys jobIdentifier:nil completion:^(NSDictionary *result, NSError *error) {
        self->_cancelRequested = NO; self->_progressText = nil;
        if (result) self->_status = @"Prepared assets were published. The library will verify the current generation. Gameplay remains unavailable.";
        else self->_status = error.localizedDescription ?: @"Preparation ended without a published result. The library will be rechecked.";
        // A final publication/fsync failure can still leave a new current generation.
        // Completion, not the cancellation request, determines whether publication succeeded.
        [self reloadCatalog]; [self refreshUI];
    }];
    if (!accepted) _status = @"The preparation job could not start. Select your files again after other operations finish.";
    [self refreshUI];
}
- (void)cancelPreparation {
    if (!_preparation.busy || _cancelRequested) return;
    _cancelRequested = YES; [_preparation cancel];
    _status = @"Cancellation requested. Waiting for the provider and preparation worker to finish; publication may already have completed.";
    [self refreshUI];
}
- (void)background:(NSNotification *)notification {
    (void)notification; (void)[_controllers setFocused:NO];
    if (_pickerStage) {
        [self clearSelection];
        [self dismissViewControllerAnimated:NO completion:nil];
        _status = @"File selection was canceled when Canopy entered the background. Choose your local inputs again.";
        [self refreshUI];
    }
    [self cancelPreparation];
}
- (void)resetMetadata {
    if ([self working]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset all title names and preferences?" message:@"This replaces only local title metadata. Prepared assets, source files, account identity and saves are untouched. This cannot be undone." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset metadata" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action; NSError *error = nil;
        if ([self->_settings resetMetadata:&error]) { self->_metadataError = nil; self->_status = @"Title display names and preferences were reset."; [self reloadCatalog]; }
        else { self->_metadataError = error.localizedDescription; GamesAlert(self,@"Could not reset metadata",error.localizedDescription); }
        [self refreshUI];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

UIViewController *CanopyMakeGamesController(void) {
    return [[CanopyGamesController alloc] initWithStyle:UITableViewStyleInsetGrouped];
}
UIViewController *CanopyMakeSettingsController(NSDictionary *entry, CanopySettings *settings,
    CanopySettingsApply apply, CanopySettingsStateProvider states, CanopyControllers *controllers) {
    CanopyGameDetails *controller = [[CanopyGameDetails alloc] initWithEntry:entry settings:settings];
    controller.applySettings = apply; controller.settingStates = states; controller.controllers = controllers; return controller;
}
