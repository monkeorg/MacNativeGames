#import "CanopyGames.h"
#import "CanopyCatalog.h"
#import "CanopySettings.h"
#import "CanopyPreparation.h"
#import "CanopyControllers.h"
#import "CanopySessionController.h"
#import "CanopyRuntime.h"
#import "CanopySaveStore.h"
#import "CanopySaveEditorController.h"
#import "CanopyProfiles.h"
#import "CanopyStorageController.h"
#import "CanopyDiagnosticsController.h"
#import "CanopyAddonsController.h"
#import "CanopyGameProfiles.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "mng_preparation_selection.h"
#include "mng_prepare.h"

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
static NSString *GamesDisplayName(NSDictionary *entry, CanopySettings *settings) {
    NSString *title = entry[@"titleID"];
    NSString *saved = [settings displayNameForTitleID:title];
    // Legacy preference-only rows used titleID as a generated name. The schema
    // cannot distinguish an intentional literal titleID name, so both use the
    // default label here. This display fallback never rewrites metadata.
    if ([saved isEqual:title]) saved = nil;
    return saved ?: CanopyGameNameForTitleID(title) ?: entry[@"displayName"] ?: title;
}
static NSString *GamesVersion(NSDictionary *entry) {
    return CanopyGameVersionLabel(entry[@"titleID"], [entry[@"titleVersion"] unsignedIntValue], [entry[@"versionIdentified"] boolValue]);
}
// Closed native phase labels only: never speak provider paths, keys, job IDs,
// arbitrary progress text or raw error descriptions.
static NSString *PreparationAnnouncement(NSString *phase) {
    if([@[@"hash-source",@"hash-base-source",@"hash-update-source",@"fingerprint-folder-members"] containsObject:phase])
        return @"Preparation: checking source files.";
    if([phase isEqual:@"hash-content-nca"] || [phase isEqual:@"verify-metadata"])
        return @"Preparation: checking content integrity.";
    if([@[@"verify-exefs",@"verify-base-exefs"] containsObject:phase])return @"Preparation: verifying executable assets.";
    if([@[@"verify-ivfc",@"validate-romfs-structure"] containsObject:phase])return @"Preparation: verifying filesystem assets.";
    if([@[@"write-private-asset",@"copy-plaintext-assets"] containsObject:phase])return @"Preparation: writing private assets.";
    if([phase isEqual:@"verify-and-publish"])return @"Preparation: verifying and publishing the generation.";
    return nil;
}
// Units come from the exact native callback sites, not a guessed overall %.
static NSString *PreparationProgressUnit(NSString *phase) {
    if([@[@"hash-source",@"hash-base-source",@"hash-update-source",@"hash-addon-source",@"hash-content-nca",@"write-private-asset",@"copy-plaintext-assets",@"fingerprint-folder-members"] containsObject:phase])return @"bytes";
    if([@[@"verify-exefs",@"verify-base-exefs",@"verify-metadata",@"verify-ivfc"] containsObject:phase])return @"blocks";
    if([@[@"bktr-relocations",@"bktr-subsections"] containsObject:phase])return @"records";
    return @"unspecified";
}
static NSString *PreparationIOSummary(NSDictionary *metrics) {
    if(![metrics isKindOfClass:NSDictionary.class] || ![metrics[@"scope"] isEqual:@"logicalPayloadIO"])return nil;
    NSArray *keys=@[@"streamedBytes",@"writtenBytes",@"clonedLogicalBytes",@"comparedEqualBytes"];
    NSMutableArray *values=[NSMutableArray array];
    for(NSString *key in keys) {
        NSNumber *value=metrics[key];if(![value isKindOfClass:NSNumber.class] || value.longLongValue<0)return nil;
        [values addObject:[NSByteCountFormatter stringFromByteCount:value.longLongValue countStyle:NSByteCountFormatterCountStyleFile]];
    }
    return [NSString stringWithFormat:@"Logical payload I/O: streamed %@; written %@; old snapshots cloned %@; matching retained spans %@. These observations do not measure physical space or establish publication.",values[0],values[1],values[2],values[3]];
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
- (instancetype)initWithStore:(CanopySaveStore *)store queue:(dispatch_queue_t)queue profileName:(NSString *)name titleID:(NSString *)titleID;
@end
@implementation CanopySaveController {
    CanopySaveStore *_store;
    dispatch_queue_t _queue;
    NSArray *_backups;
    NSString *_status,*_profileName;
    BOOL _busy, _importPicker, _rawImportPicker, _exportPicker, _cancelRequested;
    NSFileCoordinator *_coordinator;
    NSURL *_temporaryExport;
    BOOL _totkCandidateAvailable, _workInFlight;
    NSUInteger _presentationEpoch, _workOperation, _pickerEpoch, _exportOperation;
    UIDocumentPickerViewController *_ownedPicker;
    CanopySaveController *_pickerLifetime;
    UIAlertController *_confirmation;
    __weak UIWindowScene *_intentScene;
}
- (instancetype)initWithStore:(CanopySaveStore *)store queue:(dispatch_queue_t)queue profileName:(NSString *)name titleID:(NSString *)titleID {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _store = store; _queue = queue; _profileName=[name copy]; _backups = @[];
        _totkCandidateAvailable=[titleID isEqual:@"0100f2c0115b6000"]; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"Save management";
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 70;
    [self reloadBackups];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(saveBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(saveSceneBackground:) name:UISceneDidEnterBackgroundNotification object:nil];
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_coordinator cancel]; NSURL *temporary = _temporaryExport;
    if (temporary) dispatch_async(_queue, ^{ [NSFileManager.defaultManager removeItemAtURL:temporary error:NULL]; });
}
- (BOOL)activeOwnerAtEpoch:(NSUInteger)epoch allowing:(UIViewController *)presentation {
    UIWindow *window=self.viewIfLoaded.window;
    // A full-screen Files picker can detach the presenting view. Only that
    // exact owned, still-presented picker may supply a window, in the scene
    // captured before its presentation. Queued exports pass nil and cannot
    // borrow another controller's foreground window.
    if(!window && presentation && presentation==_ownedPicker && self.presentedViewController==_ownedPicker &&
       _pickerEpoch==epoch && _intentScene && presentation.viewIfLoaded.window.windowScene==_intentScene)
        window=presentation.viewIfLoaded.window;
    if(presentation==_ownedPicker && presentation && window.windowScene!=_intentScene)return NO;
    return NSThread.isMainThread && epoch!=NSUIntegerMax && epoch==_presentationEpoch &&
        self.navigationController.topViewController==self && !self.isBeingDismissed && !self.navigationController.isBeingDismissed &&
        window.isKeyWindow && UIApplication.sharedApplication.applicationState==UIApplicationStateActive &&
        window.windowScene.activationState==UISceneActivationStateForegroundActive &&
        (!self.presentedViewController || self.presentedViewController==presentation);
}
- (void)invalidatePresentationIntent {
    if(_presentationEpoch!=NSUIntegerMax)++_presentationEpoch;
    if(_confirmation) {
        UIAlertController *alert=_confirmation;_confirmation=nil;
        if(self.presentedViewController==alert)[alert dismissViewControllerAnimated:NO completion:nil];
    }
    // An accepted export picker owns its data until its terminal delegate event.
    // Invalidate its UI intent, but never delete bytes Files may still be copying.
    if(_ownedPicker && !_exportPicker) {
        UIDocumentPickerViewController *picker=_ownedPicker;
        [picker dismissViewControllerAnimated:NO completion:^{[self finishPicker:picker];}];
    }
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Our own Files presentation is not navigation away from save management.
    if(self.isMovingFromParentViewController || self.isBeingDismissed || self.navigationController.isBeingDismissed ||
       self.navigationController.topViewController!=self || !_ownedPicker)[self invalidatePresentationIntent];
}
- (BOOL)ownsPicker:(UIDocumentPickerViewController *)picker { return picker && _ownedPicker==picker; }
- (void)finishPicker:(UIDocumentPickerViewController *)picker {
    if(![self ownsPicker:picker])return;
    BOOL exported=_exportPicker;
    _ownedPicker=nil;_importPicker=NO;_rawImportPicker=NO;_exportPicker=NO;
    if(!_workInFlight)_busy=NO;
    if(exported)[self cleanupExport];
    [self refresh];_pickerLifetime=nil;
}
- (void)refresh {
    self.navigationItem.rightBarButtonItem = _coordinator ? [[UIBarButtonItem alloc] initWithTitle:_cancelRequested ? @"Cancel requested" : @"Cancel access" style:UIBarButtonItemStylePlain target:self action:@selector(cancelAccess)] : nil;
    self.navigationItem.rightBarButtonItem.enabled = !_cancelRequested;
    [self.tableView reloadData];
}
- (void)performWork:(id (^)(NSError **))work completion:(void (^)(id, NSError *))completion {
    if (_busy || _store.sealed) return;
    if(_workOperation==NSUIntegerMax)return;
    _busy = YES;_workInFlight=YES;NSUInteger operation=++_workOperation;[self refresh];
    dispatch_async(_queue, ^{
        @autoreleasepool { NSError *error = nil; id result = work(&error);
            if (!error && (!result || ([result isKindOfClass:NSNumber.class] && ![result boolValue]))) error = [NSError errorWithDomain:@"CanopySaveUI" code:2 userInfo:@{NSLocalizedDescriptionKey:@"The save operation did not report successful completion. Check recovery status before retrying."}];
            dispatch_async(dispatch_get_main_queue(), ^{
                if(self->_workOperation!=operation)return;
                self->_workInFlight=NO;self->_busy = NO; self->_coordinator = nil; self->_cancelRequested = NO;
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
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section == 0 ? (_totkCandidateAvailable ? 6 : 5) : MAX((NSInteger)_backups.count,1); }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return section == 0 ? [@"This title • " stringByAppendingString:_profileName] : @"Stored backups"; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    NSString *explanation = @"Canopy exports preserve opaque bytes in a versioned format. External Canopy exports and raw folders additionally require the actual trusted title-format validator; hashes alone are not a format check. Unknown titles cannot import external saves. Active save editing is unavailable. The experimental TOTK rupee candidate can only share explicitly unverified raw bytes. Account identity is never exported or replaced. Transfers are locked while a native session may write saves.";
    return [NSString stringWithFormat:@"%@%@%@",_busy ? @"Working on the serialized save queue…\n\n" : @"",_status ? [_status stringByAppendingString:@"\n\n"] : @"",explanation];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell;
    if (!path.section) {
        NSArray *titles = @[@"Export Canopy save bundle",@"Import Canopy export",@"Import validated raw save folder",@"Back up active saves",@"Recover interrupted transaction",@"Experimental rupee candidate"];
        NSString *detail = _store.sealed ? @"Locked for the native session" : path.row == 4 ? (_store.recoveryRequired ? @"Explicitly reconcile an unfinished transaction" : @"No recovery currently required") : @"Account identity remains separate";
        if ((path.row == 1 || path.row == 2) && !_store.externalImportSupported) detail = @"Unavailable: this title has no trusted save-format validator. Opaque export and internal backups remain available.";
        else if (path.row == 2) detail = @"Private staged copy, trusted title-structure validation and byte verification";
        else if (path.row == 5) detail = @"Unverified TOTK 1.4.x reference-family preview and raw share; no active Apply";
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
    NSUInteger epoch=_presentationEpoch;
    if(_busy || _store.sealed || ![self activeOwnerAtEpoch:epoch allowing:nil])return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    _intentScene=self.viewIfLoaded.window.windowScene;
    _confirmation=alert;__weak UIAlertController *weakAlert=alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *selected){
        (void)selected;if(self->_confirmation==weakAlert)self->_confirmation=nil;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *selected) {
        (void)selected;UIAlertController *current=weakAlert;
        if(!current || self->_confirmation!=current || ![self activeOwnerAtEpoch:epoch allowing:current] || self->_busy || self->_store.sealed)return;
        self->_confirmation=nil;action();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES]; if (_busy || _store.sealed || _presentationEpoch==NSUIntegerMax || ![self activeOwnerAtEpoch:_presentationEpoch allowing:nil]) return;
    if (!path.section && path.row == 5) {
        if (!_totkCandidateAvailable || _store.recoveryRequired || [CanopySessionController nativeSessionOwnsProcess] ||
            self.presentedViewController || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        UIViewController *editor=CanopyMakeTOTKSaveEditorController(_store,_queue);
        if(editor)[self.navigationController pushViewController:editor animated:YES];
        return;
    }
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
        _importPicker = YES; _rawImportPicker = path.row == 2;_busy=YES;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO]; picker.delegate = self; picker.allowsMultipleSelection = NO;
        _intentScene=self.viewIfLoaded.window.windowScene;
        _ownedPicker=picker;_pickerEpoch=_presentationEpoch;_pickerLifetime=self;[self refresh];
        [self presentViewController:picker animated:YES completion:nil];
    } else if (path.row == 3) [self performWork:^id(NSError **error) { return [self->_store backup:error]; } completion:^(id result, NSError *error) { if (!error && result) self->_status = @"Active saves were backed up and verified."; [self reloadBackups]; }];
    else if (_store.recoveryRequired) [self confirmTitle:@"Recover the interrupted save replacement?" message:@"The store will reconcile its journal: roll back an unfinished replacement or verify and finalize a committed save. Account identity and ambiguous data are preserved." action:^{
        [self performWork:^id(NSError **error) { return @([self->_store recover:error]); } completion:^(id result, NSError *error) { (void)result; if (!error) self->_status = @"Save transaction recovery completed."; [self reloadBackups]; }];
    }];
}
- (void)exportBundle {
    NSUInteger epoch=_presentationEpoch;
    if(_busy || _store.sealed || epoch==NSUIntegerMax || _workOperation==NSUIntegerMax || ![self activeOwnerAtEpoch:epoch allowing:nil])return;
    NSUInteger operation=_workOperation+1;_intentScene=self.viewIfLoaded.window.windowScene;
    NSURL *temporary = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[@"Canopy-export-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    __block BOOL created=NO;
    [self performWork:^id(NSError **error) {
        created=[NSFileManager.defaultManager createDirectoryAtURL:temporary withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:error];
        return created ? [self->_store exportToDirectory:temporary error:error] : nil;
    } completion:^(id result, NSError *error) {
        // The accepted worker settles authoritatively even when presentation has
        // expired. Only its own successfully-created temporary root is removed.
        if(error || ![result isKindOfClass:NSURL.class] || ![self activeOwnerAtEpoch:epoch allowing:nil]) {
            if(created)dispatch_async(self->_queue,^{[NSFileManager.defaultManager removeItemAtURL:temporary error:NULL];});
            return;
        }
        self->_temporaryExport=temporary;self->_exportOperation=operation;
        self->_exportPicker=YES;self->_busy=YES;
        UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForExportingURLs:@[result] asCopy:YES];picker.delegate=self;
        self->_ownedPicker=picker;self->_pickerEpoch=epoch;self->_pickerLifetime=self;
        [self presentViewController:picker animated:YES completion:nil];
    }];
}
- (void)cleanupExport {
    NSURL *temporary=_temporaryExport;
    if(!temporary || _exportOperation!=_workOperation)return;
    _temporaryExport=nil;
    dispatch_async(_queue,^{[NSFileManager.defaultManager removeItemAtURL:temporary error:NULL];});
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self finishPicker:controller];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if(![self ownsPicker:controller])return;
    NSUInteger epoch=_pickerEpoch;
    BOOL active=[self activeOwnerAtEpoch:epoch allowing:controller];
    if(_exportPicker) {
        if(active)_status=@"Canopy export handed to Files.";
        [self finishPicker:controller];return;
    }
    BOOL raw=_rawImportPicker;BOOL accepted=_importPicker && active && urls.count==1 && urls.firstObject.isFileURL;
    NSURL *source=accepted?urls.firstObject:nil;
    // Keep identity until dismissal completes, so a late delegate callback
    // cannot clear the flags of a replacement picker or accepted worker.
    _importPicker=NO;_rawImportPicker=NO;
    [controller dismissViewControllerAnimated:YES completion:^{
        if(![self ownsPicker:controller])return;
        [self finishPicker:controller];
        if(!source || ![self activeOwnerAtEpoch:epoch allowing:nil])return;
        [self confirmTitle:raw ? @"Import this validated raw save folder?" : @"Import this Canopy export?"
            message:raw ? @"A private bounded copy must pass this title's trusted structural validator. Active saves are backed up before replacement; account identity is untouched." : @"A matching title/profile export and the trusted title-format validator are required. Active saves are backed up before replacement; account identity is untouched."
            action:^{[self importBundle:source raw:raw];}];
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
- (void)saveSceneBackground:(NSNotification *)notification {
    if(notification.object==_intentScene || notification.object==self.viewIfLoaded.window.windowScene)[self saveBackground:notification];
}
- (void)saveBackground:(NSNotification *)notification {
    (void)notification;
    [self invalidatePresentationIntent];
    [self cancelAccess];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    if (!path.section || !_backups.count || _busy || _store.sealed || ![self activeOwnerAtEpoch:_presentationEpoch allowing:nil]) return nil;
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

@interface CanopyKeyboardKeyPicker : UITableViewController
@property(nonatomic,copy) void (^choose)(UIViewController *,NSNumber *);
@end
@implementation CanopyKeyboardKeyPicker
- (void)viewDidLoad {[super viewDidLoad];self.title=@"Choose keyboard key";self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=50;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {(void)tableView;(void)section;return (NSInteger)CanopySettings.keyboardSupportedKeys.count;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    NSNumber *usage=CanopySettings.keyboardSupportedKeys[(NSUInteger)path.row];
    return GamesCell(tableView,[CanopySettings keyboardKeyTitle:usage.unsignedIntValue],usage.unsignedIntValue ? [NSString stringWithFormat:@"HID usage %@",usage] : @"Unbind this action");
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {(void)tableView;(void)section;return @"Escape and Command remain system controls. Reusing a bound key requires confirming which action will be unbound.";}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {[tableView deselectRowAtIndexPath:path animated:YES];if(self.choose)self.choose(self,CanopySettings.keyboardSupportedKeys[(NSUInteger)path.row]);}
@end

@interface CanopyKeyboardBindingsController : UITableViewController
@property(nonatomic,copy) CanopySettingsApply applySettings;
@property(nonatomic,copy) CanopySettingsStateProvider settingStates;
- (instancetype)initWithSettings:(CanopySettings *)settings titleID:(NSString *)titleID;
@end
@implementation CanopyKeyboardBindingsController {
    CanopySettings *_settings; NSString *_titleID;
}
- (instancetype)initWithSettings:(CanopySettings *)settings titleID:(NSString *)titleID {
    if((self=[super initWithStyle:UITableViewStyleInsetGrouped])){_settings=settings;_titleID=[titleID copy];}return self;
}
- (void)viewDidLoad {[super viewDidLoad];self.title=@"Keyboard bindings";self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=60;}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];[self.tableView reloadData];}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {(void)tableView;(void)section;return (NSInteger)CanopySettings.keyboardActions.count;}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;(void)section;
    NSError *error=nil;NSDictionary *values=[_settings settingsForTitleID:_titleID error:&error];
    if(!values)return error.localizedDescription;
    return self.settingStates ? SettingApplicationDetail(@"keyboardBindings",values[@"keyboardBindings"],self.settingStates) : @"Bindings are saved for this game. Each key controls one action. Gameplay input stays captured while this editor is open.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    NSString *action=CanopySettings.keyboardActions[(NSUInteger)path.row];NSError *error=nil;
    NSDictionary *values=[_settings settingsForTitleID:_titleID error:&error];
    UITableViewCell *cell=GamesCell(tableView,action,values ? [CanopySettings keyboardKeyTitle:[CanopySettings keyboardBindingForAction:action settings:values]] : @"Metadata recovery required");
    cell.accessoryType=values ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;return cell;
}
- (void)assignUsage:(NSNumber *)usage action:(NSString *)action presenter:(UIViewController *)presenter {
    NSError *error=nil;NSDictionary *values=[_settings settingsForTitleID:_titleID error:&error];
    if(!values){GamesAlert(presenter,@"Settings unavailable",error.localizedDescription);return;}
    NSMutableArray<NSString *> *conflicts=[NSMutableArray new];
    if(usage.unsignedIntValue)for(NSString *other in CanopySettings.keyboardActions)
        if(![other isEqual:action] && [CanopySettings keyboardBindingForAction:other settings:values]==usage.unsignedIntValue)[conflicts addObject:other];
    // Confirm the exact current conflict, then re-read before writing so a
    // stale confirmation cannot silently displace a different binding.
    void (^save)(void)=^{
        NSError *failure=nil;NSDictionary *current=[self->_settings settingsForTitleID:self->_titleID error:&failure];
        if(!current){GamesAlert(presenter,@"Could not save keyboard binding",failure.localizedDescription);return;}
        NSMutableArray *actual=[NSMutableArray new];
        if(usage.unsignedIntValue)for(NSString *other in CanopySettings.keyboardActions)
            if(![other isEqual:action] && [CanopySettings keyboardBindingForAction:other settings:current]==usage.unsignedIntValue)[actual addObject:other];
        if(![actual isEqualToArray:conflicts]){GamesAlert(presenter,@"Bindings changed",@"Choose the key again to review its current assignment.");return;}
        NSMutableDictionary *bindings=[current[@"keyboardBindings"] mutableCopy] ?: [NSMutableDictionary new];
        for(NSString *other in conflicts)bindings[other]=@0;
        bindings[action]=usage;
        if(![self->_settings setValue:bindings forSetting:@"keyboardBindings" titleID:self->_titleID error:&failure]){GamesAlert(presenter,@"Could not save keyboard binding",failure.localizedDescription);return;}
        ApplySavedSettings(self->_settings,self->_titleID,self.applySettings);
        [self.navigationController popToViewController:self animated:YES];[self.tableView reloadData];
    };
    if(!conflicts.count){save();return;}
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Reassign this key?" message:[NSString stringWithFormat:@"Assign %@ to %@ and unbind %@?",[CanopySettings keyboardKeyTitle:usage.unsignedIntValue],action,[conflicts componentsJoinedByString:@", "]] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reassign" style:UIAlertActionStyleDefault handler:^(UIAlertAction *button){(void)button;save();}]];
    [presenter presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];NSString *action=CanopySettings.keyboardActions[(NSUInteger)path.row];
    CanopyKeyboardKeyPicker *picker=[[CanopyKeyboardKeyPicker alloc] initWithStyle:UITableViewStyleInsetGrouped];
    __weak CanopyKeyboardBindingsController *owner=self;
    picker.choose=^(UIViewController *presenter,NSNumber *usage){[owner assignUsage:usage action:action presenter:presenter];};
    [self.navigationController pushViewController:picker animated:YES];
}
@end

@interface CanopyGameDetails : UITableViewController
@property(nonatomic, copy) CanopySettingsApply applySettings;
@property(nonatomic, copy) CanopySettingsStateProvider settingStates;
@property(nonatomic, strong) CanopyControllers *controllers;
@property(nonatomic, copy) void (^prepareUpdate)(void);
@property(nonatomic, copy) BOOL (^libraryIdle)(void);
- (instancetype)initWithEntry:(NSDictionary *)entry settings:(CanopySettings *)settings;
@end
@implementation CanopyGameDetails {
    NSDictionary *_entry;
    CanopySettings *_settings;
    CanopySaveStore *_saves;
    dispatch_queue_t _saveQueue;
    BOOL _saveLoading,_profileNeedsReload;
    NSString *_saveError,*_profileID,*_profileName;
    CanopyProfiles *_profiles;
    NSDictionary *_profileSnapshot;
    NSUInteger _profileEpoch;
}
- (instancetype)initWithEntry:(NSDictionary *)entry settings:(CanopySettings *)settings {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _entry = [entry copy]; _settings = settings; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = GamesDisplayName(_entry,_settings);
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 70;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Rename" style:UIBarButtonItemStylePlain target:self action:@selector(rename)];
    NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    _profiles=[[CanopyProfiles alloc] initWithDirectoryURL:[[support URLByAppendingPathComponent:@"Canopy" isDirectory:YES] URLByAppendingPathComponent:@"Metadata" isDirectory:YES]];
    if(!self.settingStates)[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(profileBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (BOOL)profileAvailable {
    return !self.settingStates && !_saveLoading && !_saves.sealed &&
        (!self.libraryIdle || self.libraryIdle()) &&
        ![CanopySessionController nativeSessionOwnsProcess] &&
        UIApplication.sharedApplication.applicationState==UIApplicationStateActive &&
        self.navigationController.topViewController==self;
}
- (void)loadSaveStore { if(!_saves)[self openProfile:nil]; }
- (void)openProfile:(NSString *)requested {
    if(![self profileAvailable])return;
    _saveLoading=YES;_saveError=nil;NSUInteger epoch=++_profileEpoch;
    if(!_saveQueue)_saveQueue=dispatch_queue_create("org.monkeorg.canopy.save-profile",DISPATCH_QUEUE_SERIAL);
    NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *root=[[support URLByAppendingPathComponent:@"Canopy" isDirectory:YES] URLByAppendingPathComponent:@"Profiles" isDirectory:YES];
    NSString *title=_entry[@"titleID"],*oldID=_profileID;CanopySaveStore *old=_saves;
    dispatch_async(_saveQueue,^{@autoreleasepool {
        NSError *error=nil;NSDictionary *snapshot=[self->_profiles snapshotForTitleID:title error:&error];
        NSString *identifier=requested ?: snapshot[@"selectedID"],*name=nil;
        for(NSDictionary *row in snapshot[@"profiles"])if([row[@"identifier"] isEqual:identifier])name=row[@"displayName"];
        CanopySaveValidator validator=CanopyGameSaveValidatorForTitleID(title);
        CanopySaveStore *candidate=nil;
        if(name)candidate=[identifier isEqual:oldID] ? old : [[CanopySaveStore alloc] initWithRootURL:root titleID:title profileID:identifier externalValidator:validator error:&error];
        dispatch_async(dispatch_get_main_queue(),^{
            self->_saveLoading=NO;
            if(epoch!=self->_profileEpoch || ![self profileAvailable]) {
                self->_saveError=@"Profile opening was canceled. The previous live profile remains selected.";[self.tableView reloadData];return;
            }
            NSError *failure=error;
            NSString *expected=requested ? oldID ?: @"default" : snapshot[@"selectedID"];
            // This bounded local commit and store swap run together on main;
            // native startup cannot interleave. fsync wall time is not bounded.
            BOOL committed=candidate && [self->_profiles selectProfileID:identifier titleID:title expectedSelection:expected error:&failure];
            if(committed) {
                self->_saves=candidate;self->_profileID=[identifier copy];self->_profileName=[name copy];
                NSMutableDictionary *selected=[snapshot mutableCopy];selected[@"selectedID"]=identifier;self->_profileSnapshot=[selected copy];
                self->_profileNeedsReload=NO;self->_saveError=nil;
            } else {
                self->_profileNeedsReload=YES;self->_saveError=failure.localizedDescription ?: @"This profile could not be opened or selected. Existing saves and the previous live profile were preserved. Reload profile selection before Play.";
            }
            [self.tableView reloadData];
        });
    }});[self.tableView reloadData];
}
- (void)chooseSaveProfile {
    if(![self profileAvailable]||self.presentedViewController)return;
    NSUInteger epoch=++_profileEpoch;
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"Save profile" message:@"Profiles isolate this title's saves, backups and local account identity. Switching is available only before native startup. Existing profile bytes are never copied or converted." preferredStyle:UIAlertControllerStyleActionSheet];
    NSCountedSet *names=[NSCountedSet new];
    for(NSDictionary *row in _profileSnapshot[@"profiles"])[names addObject:[row[@"displayName"] precomposedStringWithCanonicalMapping].lowercaseString];
    NSMutableSet *used=[NSMutableSet new];
    for(NSDictionary *row in _profileSnapshot[@"profiles"]) {
        NSString *identifier=row[@"identifier"];
        NSString *name=row[@"displayName"],*key=name.precomposedStringWithCanonicalMapping.lowercaseString;
        NSString *display=name;
        if([names countForObject:key]>1) {
            NSString *shortID=[identifier isEqual:@"default"]?@"default":[identifier substringToIndex:8];
            display=[NSString stringWithFormat:@"%@ • %@",name,shortID];
            if([used containsObject:display])display=[display stringByAppendingFormat:@" (%lu)",(unsigned long)used.count+1];
        }
        [used addObject:display];
        NSString *label=[NSString stringWithFormat:@"%@%@",[identifier isEqual:_profileID]?@"✓ ":@"",display];
        [menu addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            (void)action;if(epoch!=self->_profileEpoch || ![self profileAvailable])return;
            NSUInteger next=++self->_profileEpoch;
            [self dismissViewControllerAnimated:YES completion:^{if(next==self->_profileEpoch)[self openProfile:identifier];}];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Reload persisted selection" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        (void)action;if(epoch!=self->_profileEpoch || ![self profileAvailable])return;
        NSUInteger next=++self->_profileEpoch;
        [self dismissViewControllerAnimated:YES completion:^{if(next==self->_profileEpoch)[self openProfile:nil];}];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Inspect label recovery" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        (void)action;if(epoch!=self->_profileEpoch || ![self profileAvailable])return;
        NSUInteger next=++self->_profileEpoch;
        [self dismissViewControllerAnimated:YES completion:^{if(next==self->_profileEpoch)[self inspectProfileLabelRecovery];}];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Create empty profile" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        (void)action;if(epoch!=self->_profileEpoch || ![self profileAvailable])return;
        NSUInteger next=++self->_profileEpoch;
        [self dismissViewControllerAnimated:YES completion:^{if(next==self->_profileEpoch)[self askProfileName];}];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){(void)action;if(epoch==self->_profileEpoch)++self->_profileEpoch;}]];
    menu.popoverPresentationController.sourceView=self.tableView;menu.popoverPresentationController.sourceRect=[self.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:3 inSection:3]];
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)inspectProfileLabelRecovery {
    if(![self profileAvailable] || self.presentedViewController)return;
    _saveLoading=YES;_profileNeedsReload=YES;_saveError=@"Inspecting label-only recovery. Play remains unavailable until profile selection is reconciled.";
    NSUInteger epoch=++_profileEpoch;
    if(!_saveQueue)_saveQueue=dispatch_queue_create("org.monkeorg.canopy.save-profile",DISPATCH_QUEUE_SERIAL);
    NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *root=[[support URLByAppendingPathComponent:@"Canopy" isDirectory:YES] URLByAppendingPathComponent:@"Profiles" isDirectory:YES];
    NSString *title=[_entry[@"titleID"] copy],*oldID=[_profileID copy];CanopySaveStore *old=_saves;
    dispatch_async(_saveQueue,^{@autoreleasepool {
        NSError *error=nil;
        CanopyProfileLabelRepair *repair=[self->_profiles prepareLabelRepairForTitleID:title error:&error];
        NSDictionary *snapshot=repair.candidateSnapshot;NSString *identifier=repair.selectedID,*name=nil;
        for(NSDictionary *row in snapshot[@"profiles"])if([row[@"identifier"] isEqual:identifier])name=row[@"displayName"];
        CanopySaveStore *candidate=nil;
        // The token's exact selection is authoritative; never choose default,
        // migrate identity or commit labels before its actual store is open.
        if(repair && [repair.titleID isEqual:title] && [snapshot[@"selectedID"] isEqual:identifier] && name)
            candidate=old && [oldID isEqual:identifier] ? old : [[CanopySaveStore alloc] initWithRootURL:root titleID:title profileID:identifier externalValidator:CanopyGameSaveValidatorForTitleID(title) error:&error];
        dispatch_async(dispatch_get_main_queue(),^{
            self->_saveLoading=NO;
            if(epoch!=self->_profileEpoch || ![self profileAvailable]) {
                self->_saveError=@"Label recovery inspection was canceled. The previous live profile was retained; reload selection before Play.";
                [self.tableView reloadData];return;
            }
            if(!repair || !candidate || candidate.sealed || candidate.recoveryRequired) {
                self->_saveError=error.localizedDescription ?: @"Label-only recovery is unavailable or the exact selected store could not be opened. Existing metadata and the previous live profile were retained. Reload selection before Play.";
                [self.tableView reloadData];return;
            }
            [self confirmProfileLabelRepair:repair candidate:candidate name:name epoch:epoch];
        });
    }});[self.tableView reloadData];
}
- (void)confirmProfileLabelRepair:(CanopyProfileLabelRepair *)repair candidate:(CanopySaveStore *)candidate name:(NSString *)name epoch:(NSUInteger)epoch {
    if(epoch!=_profileEpoch || ![self profileAvailable] || self.presentedViewController)return;
    NSString *message=[NSString stringWithFormat:@"Repair %lu display label(s) for this title. The exact selected profile remains %@ (label: %@). Original current metadata is quarantined; previous metadata, save bytes, backups and account identity are unchanged. This does not reset schema or choose a different profile.",(unsigned long)repair.repairedLabelCount,repair.selectedID,name];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Repair profile labels only?" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){
        (void)action;if(epoch!=self->_profileEpoch)return;++self->_profileEpoch;
        self->_saveError=@"Label recovery canceled. No repair was applied. The previous live profile was retained; reload selection before Play.";
        [self.tableView reloadData];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Repair labels" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        (void)action;if(epoch!=self->_profileEpoch || ![self profileAvailable])return;
        NSUInteger next=++self->_profileEpoch;
        [self dismissViewControllerAnimated:YES completion:^{
            if(next!=self->_profileEpoch || ![self profileAvailable] || self.presentedViewController || candidate.sealed || candidate.recoveryRequired)return;
            NSError *error=nil;
            // Main-thread exclusion and metadata CAS keep final apply and the
            // live store/name/snapshot swap indivisible with respect to Play.
            if([self->_profiles applyLabelRepair:repair expectedSelection:repair.selectedID error:&error]) {
                self->_saves=candidate;self->_profileID=[repair.selectedID copy];self->_profileName=[name copy];
                self->_profileSnapshot=[repair.candidateSnapshot copy];self->_profileNeedsReload=NO;self->_saveError=nil;
            } else {
                self->_profileNeedsReload=YES;
                self->_saveError=error.localizedDescription ?: @"Label repair could not be confirmed. The previous live store was retained. Reload persisted selection before Play; metadata publication may require reconciliation.";
            }
            [self.tableView reloadData];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)askProfileName {
    if(![self profileAvailable]||self.presentedViewController)return;NSUInteger epoch=++_profileEpoch;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Create empty profile" message:@"Choose a local label. This creates no account bytes and copies no saves. The existing reviewed runtime initializes an empty profile's local identity only when it starts." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"Profile name";field.autocorrectionType=UITextAutocorrectionTypeNo;}];
    __weak UIAlertController *weak=alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){(void)action;if(epoch==self->_profileEpoch)++self->_profileEpoch;}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        (void)action;if(epoch!=self->_profileEpoch || ![self profileAvailable])return;
        NSUInteger next=++self->_profileEpoch;
        NSError *error=nil;NSString *identifier=[self->_profiles createProfileWithName:weak.textFields.firstObject.text ?: @"" titleID:self->_entry[@"titleID"] error:&error];
        if(!identifier){self->_profileNeedsReload=YES;self->_saveError=error.localizedDescription;[self.tableView reloadData];return;}
        [self dismissViewControllerAnimated:YES completion:^{if(next==self->_profileEpoch)[self openProfile:identifier];}];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)profileBackground:(NSNotification *)notification {
    (void)notification;++_profileEpoch;
    if(self.presentedViewController)[self dismissViewControllerAnimated:NO completion:nil];
}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];if(!_saves&&!_saveLoading&&!self.settingStates)[self loadSaveStore];}
- (void)viewWillDisappear:(BOOL)animated {[super viewWillDisappear:animated];if(self.isMovingFromParentViewController||self.isBeingDismissed)++_profileEpoch;}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 5; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;return section==3 ? (self.prepareUpdate ? 5:4) : section==2 ? 8 : section==0 ? 7 : section==1 ? 6:1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return @[@"Prepared assets",@"Graphics preferences",@"Control preferences",self.prepareUpdate ? @"Updates, saves & native session" : @"Saves & native session",@"Language"][(NSUInteger)section]; }
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
    if (section == 2) return @[@"touch",@"controllerType",@"mouseSensitivity",@"mouseInvertY",@"buttonMappings",@"players",@"keyboardBindings",@"mouseEnabled"];
    return @[@"language"];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == 0) {
        NSArray *titles = @[@"Title ID",@"Generation",@"Private assets",@"Integrity",_entry[@"sourceKind"] ? @"Consumed-member inventory SHA-256" : @"Source SHA-256",@"Preparation recipe",@"Prepared version"];
        NSDictionary *integrity = _entry[@"integrity"];
        NSString *checks = [NSString stringWithFormat:@"ExeFS %@ • RomFS %@ • signature not verified",[integrity[@"exefsVerified"] boolValue] ? @"verified" : @"unverified",[integrity[@"romfsVerified"] boolValue] ? @"verified" : @"unverified"];
        NSString *assets = [NSString stringWithFormat:@"%@ files • %@",_entry[@"assetCount"],[NSByteCountFormatter stringFromByteCount:[_entry[@"assetBytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]];
        if ([_entry[@"sourceKind"] isEqual:@"asset-folder"]) checks=@"Asset hashes and RomFS structure checked • original NCA integrity and signature not verified";
        NSArray *details = @[_entry[@"titleID"],_entry[@"generationID"],assets,checks,_entry[@"memberInventorySHA256"] ?: _entry[@"sourceSHA256"] ?: @"Unavailable",_entry[@"recipeID"],GamesVersion(_entry)];
        UITableViewCell *cell = GamesCell(tableView,titles[(NSUInteger)path.row],details[(NSUInteger)path.row]); cell.selectionStyle = UITableViewCellSelectionStyleNone; return cell;
    }
    if (path.section == 3) {
        if(path.row==4) {
            UITableViewCell *cell=GamesCell(tableView,@"Prepare update",@"Reselect the original base, matching update and local keys. Reuse is verified against this exact prepared generation.");
            if([self profileAvailable] && !self.presentedViewController)cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
            else {cell.selectionStyle=UITableViewCellSelectionStyleNone;cell.textLabel.textColor=UIColor.secondaryLabelColor;}
            return cell;
        }
        if(path.row==3) {
            UITableViewCell *cell=GamesCell(tableView,@"Save profile",_saveLoading ? @"Opening the actual private profile…" : _profileName ?: @"Reload profile selection");
            if(!self.settingStates&&!_saveLoading&&!_saves.sealed&&![CanopySessionController nativeSessionOwnsProcess])cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
            else {cell.selectionStyle=UITableViewCellSelectionStyleNone;cell.textLabel.textColor=UIColor.secondaryLabelColor;}return cell;
        }
        if(path.row==2) {
            UITableViewCell *cell=GamesCell(tableView,@"Add-ons",@"Install and manage isolated prepared content. Activation requires a reviewed native host binding.");
            if(!self.settingStates && !_saves.sealed && ![CanopySessionController nativeSessionOwnsProcess])cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
            else {cell.selectionStyle=UITableViewCellSelectionStyleNone;cell.textLabel.textColor=UIColor.secondaryLabelColor;}
            return cell;
        }
        BOOL trusted = [CanopyRuntime trustedProfileForTitleID:_entry[@"titleID"]] != nil;
        NSString *title = path.row == 0 ? @"Manage saves and backups" : trusted ? @"Start reviewed native host" : @"Gameplay unavailable";
        NSString *detail = path.row == 0 ? (_saveLoading ? @"Opening the private save profile…" : _saveError ?: @"Canopy export/import, backup, restore and recovery") : @"No compiled reviewed native profile is present for this title";
        if (path.row == 1 && trusted) detail = @"Real native host integration • device acceptance remains separate";
        if (self.settingStates || _saves.sealed) { detail = path.row == 0 ? @"Locked while the native host may write saves" : @"Native host owns this profile; close the app before another session"; if (path.row == 1) title = @"Native session owns this profile"; }
        UITableViewCell *cell = GamesCell(tableView,title,detail);
        BOOL enabled = !self.settingStates && !_saveLoading && !_profileNeedsReload && !_saves.sealed && ![CanopySessionController nativeSessionOwnsProcess] && (path.row == 0 || (trusted && _saves && !_saves.recoveryRequired));
        if (enabled) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        else { cell.selectionStyle = UITableViewCellSelectionStyleNone; cell.textLabel.textColor = UIColor.secondaryLabelColor; }
        return cell;
    }
    NSArray *titles = path.section == 1 ? @[@"Target frame rate",@"Render height",@"Aspect ratio",@"Performance overlay",@"Apple Metal HUD",@"Temporal anti-aliasing"] : path.section == 2 ? @[@"Touch controls",@"Controller layout",@"Mouse sensitivity",@"Invert mouse Y",@"Button mappings",@"Players & controllers",@"Keyboard bindings",@"Mouse input"] : @[@"Language"];
    NSString *key = [self keysForSection:path.section][(NSUInteger)path.row];
    NSError *error = nil; NSDictionary *values = [_settings settingsForTitleID:_entry[@"titleID"] error:&error];
    id value = values[key];
    NSString *detail = values ? [value description] : @"Metadata recovery required";
    if ([key isEqual:@"hud"] && values) detail = @[@"Off",@"Full",@"FPS only"][[value unsignedIntegerValue]];
    if ([key isEqual:@"language"] && [value isEqual:@""]) detail = @"System";
    if ([key isEqual:@"buttonMappings"] && values) detail = @"Per-game controller and mouse buttons";
    if ([key isEqual:@"keyboardBindings"] && values) detail = @"24 per-game actions with explicit key reassignment";
    if ([key isEqual:@"players"]) detail = @"Assign, unassign or swap connected controllers";
    else if (values && self.settingStates) detail = SettingApplicationDetail(key,value,self.settingStates);
    UITableViewCell *cell = GamesCell(tableView,titles[(NSUInteger)path.row],detail);
    if (values && [@[@"touch",@"mouseInvertY",@"metalHUD",@"taa",@"mouseEnabled"] containsObject:key]) {
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
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = GamesDisplayName(self->_entry,self->_settings); field.accessibilityLabel = @"Display name"; }];
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
        if(self.libraryIdle && !self.libraryIdle())return;
        if(path.row==4){if(self.prepareUpdate && [self profileAvailable] && !self.presentedViewController)self.prepareUpdate();return;}
        if(path.row==3){[self chooseSaveProfile];return;}
        if(path.row==2) {
            if(self.settingStates || _saves.sealed || [CanopySessionController nativeSessionOwnsProcess])return;
            NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
            NSURL *base=[support URLByAppendingPathComponent:@"Canopy" isDirectory:YES];
            CanopyAddonsController *addons=CanopyMakeAddonsController(_entry,[base URLByAppendingPathComponent:@"Prepared" isDirectory:YES],[base URLByAppendingPathComponent:@"Caches" isDirectory:YES],_settings);
            __weak CanopyGameDetails *owner=self;
            addons.mutationAllowed=^BOOL {CanopyGameDetails *current=owner;return current && !current.settingStates && !current->_saves.sealed && (!current.libraryIdle || current.libraryIdle()) && ![CanopySessionController nativeSessionOwnsProcess];};
            [self.navigationController pushViewController:addons animated:YES];return;
        }
        if (self.settingStates || _saveLoading || _saves.sealed || [CanopySessionController nativeSessionOwnsProcess]) return;
        if(_profileNeedsReload){GamesAlert(self,@"Reload the save profile",@"Reload the persisted profile selection before using saves or Play.");return;}
        if (!_saves) { [self loadSaveStore]; return; }
        if (path.row == 0) [self.navigationController pushViewController:[[CanopySaveController alloc] initWithStore:_saves queue:_saveQueue profileName:_profileName titleID:_entry[@"titleID"]] animated:YES];
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
    if ([@[@"touch",@"mouseInvertY",@"metalHUD",@"taa",@"mouseEnabled"] containsObject:key]) return;
    if ([key isEqual:@"keyboardBindings"]) {
        CanopyKeyboardBindingsController *keyboard=[[CanopyKeyboardBindingsController alloc] initWithSettings:_settings titleID:_entry[@"titleID"]];
        keyboard.applySettings=self.applySettings;keyboard.settingStates=self.settingStates;
        [self.navigationController pushViewController:keyboard animated:YES];return;
    }
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
    if(![self profileAvailable] || self.presentedViewController || _profileNeedsReload || !_profileID)return;
    NSError *profileError=nil;NSDictionary *current=[_profiles snapshotForTitleID:_entry[@"titleID"] error:&profileError];
    if(!current || ![current[@"selectedID"] isEqual:_profileID]){_profileNeedsReload=YES;_saveError=profileError.localizedDescription ?: @"The persisted profile changed. Reload the actual selected profile before Play.";[self.tableView reloadData];return;}
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
    CanopyDiagnostics *_diagnostics;
    CanopyStorageController *_storageScreen;
    NSDictionary *_lastPreparationResult;
    NSError *_lastPreparationError;
    NSString *_observedPhase;
    uint64_t _phaseDone, _phaseTotal;
    NSArray *_entries, *_issues;
    NSString *_status, *_metadataError, *_progressText;
    BOOL _refreshing, _cancelRequested;
    NSUInteger _scanToken, _preparationAnnouncementEpoch;
    NSMutableSet<NSString *> *_announcedPreparationPhases;
    BOOL _preparationAnnouncementsActive, _preparationScreenVisible;
    struct mng_preparation_selection _selection;
    CanopyGameDetails *_selectionOrigin;
    UIWindowScene *_selectionScene;
    UIViewController *_selectionUI;
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
    _diagnostics = [CanopyDiagnostics new];
    _catalogQueue = dispatch_queue_create("org.monkeorg.canopy.catalog", DISPATCH_QUEUE_SERIAL);
    _entries = @[]; _issues = @[];
    __weak CanopyGamesController *weakSelf = self;
    _preparation.progress = ^(NSString *phase, uint64_t done, uint64_t total) {
        CanopyGamesController *owner = weakSelf; if (!owner) return;
        BOOL changed=![owner->_observedPhase isEqual:phase];
        owner->_observedPhase=phase; owner->_phaseDone=done; owner->_phaseTotal=total;
        owner->_progressText = [NSString stringWithFormat:@"%@ • %llu / %llu",phase,(unsigned long long)done,(unsigned long long)total];
        [owner refreshUI];
        if(changed && owner->_preparationAnnouncementsActive && owner->_preparation.busy) {
            NSString *announcement=PreparationAnnouncement(phase);
            // Each human phase is spoken at most once per attempt, even when
            // native per-asset phases alternate repeatedly. Never per-byte.
            if(announcement && ![owner->_announcedPreparationPhases containsObject:announcement] &&
               [owner announcePreparation:announcement]) [owner->_announcedPreparationPhases addObject:announcement];
        }
        if(changed && owner->_diagnostics.enabled)(void)[[owner diagnosticSources] snapshotWithDiagnostics:owner->_diagnostics recordIfEnabled:YES];
    };
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(selectionSceneInactive:) name:UISceneWillDeactivateNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(selectionSceneInactive:) name:UISceneDidEnterBackgroundNotification object:nil];
    [self reloadCatalog];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; (void)[_controllers setFocused:NO];
    if (_settings && !_selection.stage) [self reloadCatalog];
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated];_preparationScreenVisible=YES; }
- (void)viewWillDisappear:(BOOL)animated { _preparationScreenVisible=NO;[super viewWillDisappear:animated]; }
- (BOOL)announcePreparation:(NSString *)message {
    if(!NSThread.isMainThread || !_preparationScreenVisible || !UIAccessibilityIsVoiceOverRunning() ||
       self.navigationController.topViewController!=self || self.presentedViewController || !self.viewIfLoaded.window.isKeyWindow ||
       UIApplication.sharedApplication.applicationState!=UIApplicationStateActive ||
       self.viewIfLoaded.window.windowScene.activationState!=UISceneActivationStateForegroundActive)return NO;
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,message);return YES;
}
- (BOOL)working { return _refreshing || _preparation.busy || _selection.stage != MNG_SELECT_IDLE; }
- (void)refreshUI {
    if (_preparation.busy) self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:_cancelRequested ? @"Cancel requested" : @"Cancel preparation" style:UIBarButtonItemStylePlain target:self action:@selector(cancelPreparation)];
    else self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Prepare game" style:UIBarButtonItemStylePlain target:self action:@selector(chooseSource)];
    self.navigationItem.rightBarButtonItem.enabled = !_cancelRequested && (!_refreshing || _preparation.busy) && !_selection.stage;
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
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section == 0 ? MAX((NSInteger)_entries.count,1) : 7; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return section == 0 ? @"Prepared games" : @"Library tools"; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 1) return @"The inspection history remains separate from prepared assets. Resetting title metadata changes only names and preferences; it never deletes prepared assets, saves or source files.";
    NSMutableArray *messages = [NSMutableArray arrayWithObject:@"Prepared assets may contain private game content. Preparation does not establish game compatibility; native execution requires an approved compiled host and matching verified assets."];
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
            UITableViewCell *cell = GamesCell(tableView,@"Your private game library",@"Prepare your own NSP/XCI, optionally with its update, or choose an NCA or extracted ExeFS/RomFS folder. Extracted ExeFS/RomFS folders need no keys; container and NCA-folder preparation requests a local key file. Preparation and native execution are separate checks.");
            cell.imageView.image = [UIImage imageNamed:@"Canopy.png"]; cell.selectionStyle = UITableViewCellSelectionStyleNone; return cell;
        }
        NSDictionary *entry = _entries[(NSUInteger)path.row];
        BOOL backend=[CanopyRuntime trustedProfileForTitleID:entry[@"titleID"]] != nil;
        NSString *status=backend ? @"Native host present; start checks required" : @"No reviewed native host present";
        UITableViewCell *cell = GamesCell(tableView,GamesDisplayName(entry,_settings),[NSString stringWithFormat:@"Prepared assets • %@ • %@",GamesVersion(entry),status]);
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if ([self working]) cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSArray *titles = @[@"Prepare game",@"Players & controllers",@"Inspection history",@"Verify library",@"Storage",@"Diagnostics",@"Reset title metadata"];
    NSArray *details = @[@"NSP/XCI, optional update, NCA folder or extracted ExeFS/RomFS folder",@"Assign connected controllers to four independent seats",@"Read-only container metadata from the earlier inspector",@"Rehash prepared assets and reload current generations",@"Verify, select and manage prepared versions, unfinished jobs and private shader caches",@"Actual observations and explicit redacted JSON export; collection defaults off",@"Explicit recovery for display names and preferences only"];
    UITableViewCell *cell = GamesCell(tableView,titles[(NSUInteger)path.row],details[(NSUInteger)path.row]);
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if ([self working]) { cell.textLabel.textColor = UIColor.secondaryLabelColor; cell.selectionStyle = UITableViewCellSelectionStyleNone; }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES]; if ([self working]) return;
    if (!path.section) {
        if (_entries.count) {
            NSDictionary *entry=_entries[(NSUInteger)path.row];
            CanopyGameDetails *detail=[[CanopyGameDetails alloc] initWithEntry:entry settings:_settings];detail.controllers=_controllers;
            NSDictionary *selected=@{@"titleID":[entry[@"titleID"] copy],@"generationID":[entry[@"generationID"] copy]};
            __weak CanopyGamesController *owner=self;__weak CanopyGameDetails *origin=detail;
            detail.libraryIdle=^BOOL {CanopyGamesController *current=owner;return current && ![current working] && ![CanopySessionController nativeSessionOwnsProcess];};
            detail.prepareUpdate=^{CanopyGamesController *current=owner;CanopyGameDetails *sender=origin;
                if(current && sender)[current beginUpdateForEntry:selected origin:sender];};
            [self.navigationController pushViewController:detail animated:YES];
        }
        return;
    }
    if (path.row == 0) [self chooseSource];
    else if (path.row == 1) [self.navigationController pushViewController:[[CanopyPlayersController alloc] initWithControllers:_controllers] animated:YES];
    else if (path.row == 2) [self.navigationController pushViewController:CanopyMakeInspectionHistoryController() animated:YES];
    else if (path.row == 3) [self reloadCatalog];
    else if (path.row == 4) {
        NSURL *cache = [[_preparedRoot URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"Caches" isDirectory:YES];
        CanopyStorageController *storage = CanopyMakeStorageController(_preparedRoot,cache);
        _storageScreen=storage;
        __weak CanopyGamesController *owner = self;
        storage.mutationAllowed = ^BOOL { CanopyGamesController *current = owner; return current && ![current working] && ![CanopySessionController nativeSessionOwnsProcess]; };
        __weak CanopyStorageController *selectionSource=storage;
        storage.resumePreparation = ^(NSString *job) {
            CanopyGamesController *current=owner;CanopyStorageController *sender=selectionSource;
            if(!current||!sender||[current working]||[CanopySessionController nativeSessionOwnsProcess]||
                UIApplication.sharedApplication.applicationState!=UIApplicationStateActive||
                !sender.viewIfLoaded.window.isKeyWindow||sender.viewIfLoaded.window.windowScene.activationState!=UISceneActivationStateForegroundActive||
                current.navigationController.topViewController!=sender||sender.presentedViewController||
                !mng_selection_begin(&current->_selection,job.UTF8String))return;
            current->_selectionScene=sender.viewIfLoaded.window.windowScene;
            // Reserve before popping: viewWillAppear must not start a catalog
            // reload which races and silently consumes the Resume request.
            uint64_t epoch=current->_selection.epoch;
            [current.navigationController popToViewController:current animated:YES];
            id<UIViewControllerTransitionCoordinator> transition=current.navigationController.transitionCoordinator;
            if(transition)[transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){
                if(context.isCancelled){if(mng_selection_is(&current->_selection,epoch,MNG_SELECT_MODE)){[current clearSelection];[current refreshUI];}}
                else [current presentModeAtEpoch:epoch];
            }];
            else [current presentModeAtEpoch:epoch];
        };
        __weak CanopyStorageController *resumeSource=storage;
        storage.resumeAddonPreparation=^(NSDictionary *route) {
            CanopyGamesController *current=owner;CanopyStorageController *sender=resumeSource;
            if(!current || !sender || current.navigationController.topViewController!=sender ||
                sender.presentedViewController || !sender.viewIfLoaded.window.isKeyWindow ||
                sender.viewIfLoaded.window.windowScene.activationState!=UISceneActivationStateForegroundActive ||
                UIApplication.sharedApplication.applicationState!=UIApplicationStateActive || [current working] ||
                [CanopySessionController nativeSessionOwnsProcess])return;
            NSString *job=route[@"jobIdentifier"],*application=route[@"applicationID"],*generation=route[@"baseGenerationID"],*addon=route[@"addonTitleID"];
            NSDictionary *base=route[@"verifiedBaseEntry"];
            if(![job isKindOfClass:NSString.class] || !mng_selection_job_valid(job.UTF8String) ||
                ![CanopySettings isValidTitleID:application] || ![CanopySettings isValidTitleID:addon] ||
                [application isEqual:@"0000000000000000"] || [addon isEqual:@"0000000000000000"] || [addon isEqual:application] ||
                ![generation isKindOfClass:NSString.class] || !mng_selection_hex_valid(generation.UTF8String,64) ||
                ![base isKindOfClass:NSDictionary.class] || ![base[@"titleID"] isEqual:application] ||
                ![base[@"generationID"] isEqual:generation] || [base[@"preparedKind"] isEqual:@"addOn"])return;
            NSURL *globalCache=[[current->_preparedRoot URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"Caches" isDirectory:YES];
            CanopyAddonsController *addons=[[CanopyAddonsController alloc] initWithBaseEntry:[base copy]
                preparedRootURL:current->_preparedRoot globalCacheRootURL:globalCache settings:current->_settings
                resumeJobIdentifier:[job copy] addonTitleID:[addon copy]];
            if(!addons)return;
            addons.mutationAllowed=^BOOL {CanopyGamesController *live=owner;return live && ![live working] && ![CanopySessionController nativeSessionOwnsProcess];};
            [current.navigationController pushViewController:addons animated:YES];
        };
        [self.navigationController pushViewController:storage animated:YES];
    }
    else if (path.row == 5) [self.navigationController pushViewController:CanopyMakeDiagnosticsController(_diagnostics,[self diagnosticSources]) animated:YES];
    else [self resetMetadata];
}
- (CanopyDiagnosticsSources *)diagnosticSources {
    CanopyDiagnosticsSources *sources=[CanopyDiagnosticsSources new];
    __weak CanopyGamesController *weakSelf=self;
    sources.preparedEntry=^NSDictionary<NSString *,id> * _Nullable {CanopyGamesController *owner=weakSelf;return owner ? owner->_lastPreparationResult ?: (owner->_preparation.busy ? nil : owner->_entries.firstObject) : nil;};
    sources.metrics=^NSDictionary<NSString *,id> * _Nullable {CanopyGamesController *owner=weakSelf;
        if(!owner)return nil;
        if(owner->_preparation.busy)return owner->_observedPhase ? @{@"phaseDone":@(owner->_phaseDone),@"phaseTotal":@(owner->_phaseTotal),@"phaseUnit":PreparationProgressUnit(owner->_observedPhase)} : nil;
        // Completion/error counters remain actual attempt observations even if
        // publication was uncertain. Backend redaction admits only closed keys.
        NSMutableDictionary *metrics=[NSMutableDictionary new];
        id io=owner->_lastPreparationResult[@"ioMetrics"] ?: owner->_lastPreparationError.userInfo[@"ioMetrics"];
        if([io isKindOfClass:NSDictionary.class])metrics[@"preparationIO"]=io;
        if(owner->_lastPreparationResult)metrics[@"preparationPublished"]=@YES;
        id uncertain=owner->_lastPreparationError.userInfo[@"publishedGenerationMayExist"];
        if(uncertain)metrics[@"preparationPublicationMayHaveCompleted"]=uncertain;
        return metrics.count ? [metrics copy] : nil;};
    sources.storageSnapshot=^NSDictionary<NSString *,id> * _Nullable {CanopyGamesController *owner=weakSelf;return owner ? owner->_storageScreen.diagnosticSnapshot : nil;};
    sources.phase=^CanopyDiagnosticsPhase {CanopyGamesController *owner=weakSelf;
        if(!owner)return CanopyDiagnosticsPhaseUnknown;
        if(owner->_preparation.busy)return owner->_cancelRequested ? CanopyDiagnosticsPhaseCancelling : CanopyDiagnosticsPhasePreparing;
        if(owner->_refreshing)return CanopyDiagnosticsPhaseVerifying;
        if(owner->_lastPreparationError)return CanopyDiagnosticsPhaseFailed;
        return owner->_lastPreparationResult || owner->_entries.count ? CanopyDiagnosticsPhasePrepared : CanopyDiagnosticsPhaseIdle;};
    sources.errorCode=^CanopyDiagnosticsError {CanopyGamesController *owner=weakSelf;return [CanopyDiagnostics errorForError:owner ? owner->_lastPreparationError : nil];};
    return sources;
}
- (UIWindow *)selectionWindow {
    UIWindow *window=self.viewIfLoaded.window;
    UIViewController *owned=_selectionUI;
    if(!window && owned && self.presentedViewController==owned)window=owned.viewIfLoaded.window;
    return window;
}
- (BOOL)selectionAvailable {
    if(!NSThread.isMainThread)return NO;
    UIWindow *window=[self selectionWindow];UIWindowScene *scene=window.windowScene;
    return window.isKeyWindow && scene && scene.activationState==UISceneActivationStateForegroundActive &&
        (!_selection.stage || (_selectionScene && scene==_selectionScene)) &&
        (!self.presentedViewController || self.presentedViewController==_selectionUI) &&
        UIApplication.sharedApplication.applicationState==UIApplicationStateActive &&
        self.navigationController.topViewController==self &&
        !_preparation.busy && !_refreshing && ![CanopySessionController nativeSessionOwnsProcess];
}
- (void)dismissSelectionUIAtEpoch:(uint64_t)epoch completion:(void (^)(void))completion {
    if(_selection.epoch!=epoch||![self selectionAvailable])return;
    UIViewController *owned=_selectionUI;
    void (^finish)(void)=^{
        if(self->_selectionUI==owned)self->_selectionUI=nil;
        if(self->_selection.epoch==epoch && [self selectionAvailable] && completion)completion();
    };
    if(owned && self.presentedViewController==owned)[owned dismissViewControllerAnimated:YES completion:finish];
    else if(!self.presentedViewController)dispatch_async(dispatch_get_main_queue(),finish);
}
- (void)invalidateSelectionForInactiveScene {
    if(!_selection.stage)return;
    UIViewController *owned=_selectionUI;
    [self clearSelection];
    if(owned && self.presentedViewController==owned)[owned dismissViewControllerAnimated:NO completion:nil];
    _status=@"File selection was canceled when its scene became inactive. Choose your local inputs again.";
    [self refreshUI];
}
- (void)selectionSceneInactive:(NSNotification *)notification {
    if(notification.object==_selectionScene)[self invalidateSelectionForInactiveScene];
}
- (void)chooseSource { [self beginSelectionForJob:nil]; }
- (BOOL)selectionOriginMatches:(uint64_t)epoch {
    if(!_selection.origin)return _selectionOrigin==nil && _selection.epoch==epoch;
    return _selectionOrigin && mng_selection_origin_is(&_selection,epoch,(uintptr_t)(__bridge void *)_selectionOrigin);
}
- (void)beginUpdateForEntry:(NSDictionary *)entry origin:(CanopyGameDetails *)origin {
    if([self working] || [CanopySessionController nativeSessionOwnsProcess] ||
        UIApplication.sharedApplication.applicationState!=UIApplicationStateActive ||
        self.navigationController.topViewController!=origin || origin.presentedViewController || self.presentedViewController ||
        !origin.viewIfLoaded.window.isKeyWindow || origin.viewIfLoaded.window.windowScene.activationState!=UISceneActivationStateForegroundActive ||
        ![origin profileAvailable] || !mng_selection_begin_reuse(&_selection,[entry[@"titleID"] UTF8String],
            [entry[@"generationID"] UTF8String],(uintptr_t)(__bridge void *)origin))return;
    _selectionOrigin=origin;_selectionScene=origin.viewIfLoaded.window.windowScene;uint64_t epoch=_selection.epoch;[self refreshUI];
    [self.navigationController popToViewController:self animated:YES];
    id<UIViewControllerTransitionCoordinator> transition=self.navigationController.transitionCoordinator;
    if(transition) {
        BOOL registered=[transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){
            if(![self selectionOriginMatches:epoch])return;
            if(context.isCancelled){[self clearSelection];[self refreshUI];}
            else [self presentModeAtEpoch:epoch];
        }];
        if(!registered && [self selectionOriginMatches:epoch]){[self clearSelection];[self refreshUI];}
    } else [self presentModeAtEpoch:epoch];
}
- (void)beginSelectionForJob:(NSString *)job {
    if(![self selectionAvailable] || [self working] || self.presentedViewController ||
        !mng_selection_begin(&_selection,job ? job.UTF8String : NULL))return;
    _selectionScene=[self selectionWindow].windowScene;
    [self presentModeAtEpoch:_selection.epoch];
}
- (void)presentModeAtEpoch:(uint64_t)epoch {
    if(!mng_selection_is(&_selection,epoch,MNG_SELECT_MODE))return;
    if(![self selectionAvailable] || ![self selectionOriginMatches:epoch] || self.presentedViewController){[self clearSelection];[self refreshUI];return;}
    (void)[_controllers setFocused:NO];[self refreshUI];
    if(_selection.origin) {
        NSString *message=[NSString stringWithFormat:@"Title %@ • generation %@. Reselect your original base, matching update and local keys. Native verification must match this exact reusable generation and its title/application owner. Choose the latest matching metadata revision or request an exact numeric revision. Preparation does not grant gameplay compatibility.",[NSString stringWithUTF8String:_selection.reuse_title],[NSString stringWithUTF8String:_selection.reuse_generation]];
        UIAlertController *setup=[UIAlertController alertControllerWithTitle:@"Prepare update for this title" message:message preferredStyle:UIAlertControllerStyleAlert];
        [setup addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){
            (void)action;if(mng_selection_is(&self->_selection,epoch,MNG_SELECT_MODE) && [self selectionOriginMatches:epoch]){[self clearSelection];[self refreshUI];}
        }]];
        [setup addAction:[UIAlertAction actionWithTitle:@"Choose original base" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            (void)action;if(!mng_selection_is(&self->_selection,epoch,MNG_SELECT_MODE) || ![self selectionOriginMatches:epoch])return;
            if(![self selectionAvailable]){[self clearSelection];[self refreshUI];return;}
            if(!mng_selection_choose_revision(&self->_selection,epoch))return;
            [self dismissSelectionUIAtEpoch:epoch completion:^{[self presentSelectionPickerAtEpoch:epoch];}];
        }]];
        _selectionUI=setup;[self presentViewController:setup animated:YES completion:nil];return;
    }
    NSString *job=_selection.job[0] ? [NSString stringWithUTF8String:_selection.job] : nil;
    NSString *message=job ? [NSString stringWithFormat:@"Job %@. Select its original mode and inputs again. Native verification must match the retained job; filenames and this ID do not establish a match. Add-ons must use the exact base's Add-ons screen.",job] :
        @"Choose base-only preparation, base plus matching update, or a folder. To update an existing title, select its original base again. Paired preparation offers latest or exact native metadata revision selection.";
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:job ? @"Resume unfinished preparation" : @"Prepare private game assets" message:message preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *names=@[@"Base only",@"Base + update",@"NCA folder + keys",@"Extracted ExeFS/RomFS folder"];
    for(unsigned mode=MNG_SELECT_BASE;mode<=MNG_SELECT_ASSET_FOLDER;mode++) {
        [menu addAction:[UIAlertAction actionWithTitle:names[mode-1] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            (void)action;if(![self selectionAvailable] || !(mode==MNG_SELECT_PAIRED ? mng_selection_choose_revision(&self->_selection,epoch) : mng_selection_choose(&self->_selection,epoch,mode)))return;
            [self dismissSelectionUIAtEpoch:epoch completion:^{[self presentSelectionPickerAtEpoch:epoch];}];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){
        (void)action;if(mng_selection_is(&self->_selection,epoch,MNG_SELECT_MODE)){[self clearSelection];[self refreshUI];}
    }]];
    menu.popoverPresentationController.barButtonItem=self.navigationItem.rightBarButtonItem;
    _selectionUI=menu;[self presentViewController:menu animated:YES completion:nil];
}
- (void)clearSelection {
    _pendingSource=nil;_pendingUpdate=nil;_selectionOrigin=nil;_selectionScene=nil;_selectionUI=nil;mng_selection_cancel(&_selection);
}
- (void)presentRevisionAtEpoch:(uint64_t)epoch {
    if(!mng_selection_is(&_selection,epoch,MNG_SELECT_REVISION))return;
    if(![self selectionAvailable]||![self selectionOriginMatches:epoch]||self.presentedViewController){[self clearSelection];[self refreshUI];return;}
    UIAlertController *revision=[UIAlertController alertControllerWithTitle:@"Update metadata revision"
        message:@"Choose the highest declared matching revision, or enter an exact decimal revision (0–4294967295). This is native metadata, not a semantic game version or a compatibility claim. Resume must match the retained job's original inputs and revision."
        preferredStyle:UIAlertControllerStyleAlert];
    [revision addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"Exact metadata revision";field.keyboardType=UIKeyboardTypeNumberPad;field.autocorrectionType=UITextAutocorrectionTypeNo;}];
    __weak UIAlertController *weakRevision=revision;
    void (^choose)(BOOL)=^(BOOL latest){
        UIAlertController *owned=weakRevision;
        if(!owned||self->_selectionUI!=owned||(self.presentedViewController&&self.presentedViewController!=owned)||![self selectionAvailable]||![self selectionOriginMatches:epoch]||!mng_selection_is(&self->_selection,epoch,MNG_SELECT_REVISION))return;
        uint32_t target=0;
        if(!latest){NSString *text=owned.textFields.firstObject.text ?: @"";
            if(text.length<1||text.length>10||!text.UTF8String||strlen(text.UTF8String)!=text.length||!mng_selection_revision_decimal(text.UTF8String,&target)){
                [self clearSelection];self->_status=@"Exact revision must be decimal digits from 0 through 4294967295. Reselect preparation to retry.";[self refreshUI];return;
            }
        }
        if(!mng_selection_revision(&self->_selection,epoch,latest?1:0,target))return;
        [self dismissSelectionUIAtEpoch:epoch completion:^{[self presentSelectionPickerAtEpoch:epoch];}];
    };
    [revision addAction:[UIAlertAction actionWithTitle:@"Latest matching revision" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;choose(YES);}]];
    [revision addAction:[UIAlertAction actionWithTitle:@"Use exact revision" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;choose(NO);}]];
    [revision addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){(void)action;if(mng_selection_is(&self->_selection,epoch,MNG_SELECT_REVISION)){[self clearSelection];[self refreshUI];}}]];
    _selectionUI=revision;[self presentViewController:revision animated:YES completion:nil];
}
- (void)presentSelectionPickerAtEpoch:(uint64_t)epoch {
    if(mng_selection_is(&_selection,epoch,MNG_SELECT_REVISION)){[self presentRevisionAtEpoch:epoch];return;}
    if(_selection.epoch!=epoch || _selection.picker || self.presentedViewController)return;
    if(![self selectionAvailable] || ![self selectionOriginMatches:epoch]){[self clearSelection];[self refreshUI];return;}
    BOOL keys=_selection.stage==MNG_SELECT_KEYS;
    if(!keys && _selection.stage!=MNG_SELECT_SOURCE && _selection.stage!=MNG_SELECT_UPDATE)return;
    BOOL folder=!keys && _selection.mode>=MNG_SELECT_NCA_FOLDER;
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[folder ? UTTypeFolder : UTTypeData] asCopy:NO];
    picker.title=keys ? @"Choose your local key file" : folder ? @"Choose original private game folder" : _selection.stage==MNG_SELECT_UPDATE ? @"Choose original matching update NSP/XCI" : @"Choose original base NSP/XCI";
    picker.allowsMultipleSelection=NO;picker.delegate=self;
    if(!mng_selection_bind(&_selection,epoch,(uintptr_t)(__bridge void *)picker))return;
    _selectionUI=picker;[self presentViewController:picker animated:YES completion:nil];
}
- (void)chooseKeysAtEpoch:(uint64_t)epoch {
    if(self.presentedViewController || !mng_selection_is(&_selection,epoch,MNG_SELECT_KEY_PROMPT) || !_pendingSource)return;
    if(![self selectionAvailable] || ![self selectionOriginMatches:epoch]){[self clearSelection];[self refreshUI];return;}
    UIAlertController *explanation=[UIAlertController alertControllerWithTitle:@"Choose your local key file"
        message:@"Keys are used in memory for this attempt. Canopy retains no key file, path or bookmark. Resume requires reselecting local inputs and native verification of the retained job."
        preferredStyle:UIAlertControllerStyleAlert];
    [explanation addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){
        (void)action;if(mng_selection_is(&self->_selection,epoch,MNG_SELECT_KEY_PROMPT)){[self clearSelection];[self refreshUI];}
    }]];
    [explanation addAction:[UIAlertAction actionWithTitle:@"Choose file" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        (void)action;if(!mng_selection_is(&self->_selection,epoch,MNG_SELECT_KEY_PROMPT))return;
        if(![self selectionAvailable] || ![self selectionOriginMatches:epoch]){[self clearSelection];[self refreshUI];return;}
        if(!mng_selection_request_keys(&self->_selection,epoch))return;
        [self dismissSelectionUIAtEpoch:epoch completion:^{[self presentSelectionPickerAtEpoch:epoch];}];
    }]];
    _selectionUI=explanation;[self presentViewController:explanation animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if(!mng_selection_owns(&_selection,(uintptr_t)(__bridge void *)controller))return;
    [self clearSelection];[self refreshUI];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    uintptr_t token=(uintptr_t)(__bridge void *)controller;
    if(!mng_selection_owns(&_selection,token))return;
    if(![self selectionAvailable] || ![self selectionOriginMatches:_selection.epoch] || urls.count!=1 || !urls.firstObject.isFileURL){[self clearSelection];[self refreshUI];return;}
    NSURL *url=urls.firstObject;unsigned stage=_selection.stage;uint64_t epoch=_selection.epoch;
    if(stage!=MNG_SELECT_KEYS && _selection.mode<=MNG_SELECT_PAIRED && ![@[@"nsp",@"xci"] containsObject:url.pathExtension.lowercaseString]) {
        [self clearSelection];[self refreshUI];GamesAlert(self,@"Unsupported preparation input",@"Choose an NSP or XCI container, or explicitly select a folder mode.");return;
    }
    if(stage==MNG_SELECT_SOURCE)_pendingSource=url;
    else if(stage==MNG_SELECT_UPDATE)_pendingUpdate=url;
    if(!mng_selection_picked(&_selection,token))return;
    if(_selection.stage==MNG_SELECT_READY) {
        NSURL *source=_pendingSource,*update=_pendingUpdate,*keys=stage==MNG_SELECT_KEYS ? url : nil;
        _pendingSource=nil;_pendingUpdate=nil;
        [self dismissSelectionUIAtEpoch:epoch completion:^{[self startSource:source update:update keys:keys epoch:epoch];}];
    } else if(_selection.stage==MNG_SELECT_KEY_PROMPT) {
        [self dismissSelectionUIAtEpoch:epoch completion:^{[self chooseKeysAtEpoch:epoch];}];
    } else [self dismissSelectionUIAtEpoch:epoch completion:^{[self presentSelectionPickerAtEpoch:epoch];}];
}
- (void)startSource:(NSURL *)source update:(NSURL *)update keys:(NSURL *)keys epoch:(uint64_t)epoch {
    if(!mng_selection_is(&_selection,epoch,MNG_SELECT_READY))return;
    if(![self selectionAvailable] || ![self selectionOriginMatches:epoch] || self.presentedViewController){[self clearSelection];_status=@"Preparation is unavailable. Reselect inputs after other operations finish.";[self refreshUI];return;}
    struct mng_preparation_request request;
    if(!mng_selection_take_request(&_selection,epoch,(uintptr_t)(__bridge void *)_selectionOrigin,&request))return;
    _selectionOrigin=nil;_selectionScene=nil;_selectionUI=nil;
    unsigned mode=request.mode;
    NSString *job=request.job[0] ? [NSString stringWithUTF8String:request.job] : nil;
    NSString *reuseTitle=request.reuse_title[0] ? [NSString stringWithUTF8String:request.reuse_title] : nil;
    NSString *reuseGeneration=request.reuse_generation[0] ? [NSString stringWithUTF8String:request.reuse_generation] : nil;
    _cancelRequested=NO;_progressText=nil;_status=nil;
    _preparationAnnouncementEpoch=epoch;_preparationAnnouncementsActive=YES;
    _announcedPreparationPhases=[NSMutableSet set];
    void (^completion)(NSDictionary<NSString *,id> * _Nullable,NSError * _Nullable)=^(NSDictionary *result,NSError *error){
        if(self->_preparationAnnouncementsActive && self->_preparationAnnouncementEpoch==epoch) {
            self->_preparationAnnouncementsActive=NO;
            NSString *announcement=result ? @"Preparation published assets. The library will verify the current generation. This does not establish game compatibility." :
                [error.domain isEqual:@"CanopyPreparation"] && error.code==MNG_PREPARE_CANCELLED ?
                @"Preparation cancellation completed. Check the library and retained work before resuming." :
                @"Preparation ended without a published result. The library will reload to check the current generation.";
            (void)[self announcePreparation:announcement];
        }
        self->_cancelRequested=NO;self->_progressText=nil;
        self->_lastPreparationResult=[result copy];self->_lastPreparationError=error;
        if(self->_diagnostics.enabled)(void)[[self diagnosticSources] snapshotWithDiagnostics:self->_diagnostics recordIfEnabled:YES];
        if(result)self->_status=@"Prepared assets were published. The library will verify the current generation; Play requires an approved native profile.";
        else self->_status=error.localizedDescription ?: @"Preparation ended without a published result. Reselect the retained job from Storage to resume.";
        NSString *observed=PreparationIOSummary(result[@"ioMetrics"] ?: error.userInfo[@"ioMetrics"]);
        if(observed)self->_status=[self->_status stringByAppendingFormat:@"\n%@",observed];
        // Native completion, including publication uncertainty, stays authoritative.
        [self reloadCatalog];[self refreshUI];
    };
    BOOL accepted=mode>=MNG_SELECT_NCA_FOLDER ? [_preparation startFolderURL:source keysURL:keys jobIdentifier:job completion:completion] :
        [_preparation startSourceURL:source updateURL:update keysURL:keys selectLatestUpdate:(request.latest_update?YES:NO) targetVersion:request.target_version reuseTitleID:reuseTitle reuseGenerationID:reuseGeneration jobIdentifier:job completion:completion];
    if(accepted){_observedPhase=nil;_phaseDone=0;_phaseTotal=0;_lastPreparationError=nil;_lastPreparationResult=nil;}
    else {
        _preparationAnnouncementsActive=NO;
        _status=@"The job could not start. Its retained data is unchanged; select it in Storage and reselect inputs.";
        (void)[self announcePreparation:@"Preparation could not start. Reselect the retained work and local inputs."];
    }
    [self refreshUI];
}
- (void)cancelPreparation {
    if (!_preparation.busy || _cancelRequested) return;
    _cancelRequested = YES; [_preparation cancel];
    (void)[self announcePreparation:@"Preparation cancellation requested. Waiting for the authoritative result; publication may already have completed."];
    _status = @"Cancellation requested. Waiting for the provider and preparation worker to finish; publication may already have completed.";
    [self refreshUI];
}
- (void)background:(NSNotification *)notification {
    (void)notification; (void)[_controllers setFocused:NO];
    [self invalidateSelectionForInactiveScene];
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
