#import "CanopyStorageController.h"
#include "mng_preparation_selection.h"

static NSString *STBytes(id value) {
    return [value isKindOfClass:NSNumber.class]?[NSByteCountFormatter stringFromByteCount:[value longLongValue] countStyle:NSByteCountFormatterCountStyleFile]:@"not checked";
}
static NSString *STShort(NSString *identifier) {return identifier.length>12?[identifier substringToIndex:12]:identifier;}
@implementation CanopyStorageController {
    CanopyStorage *_storage;
    NSString *_status;
    BOOL _suppressedPop,_previousPop;
    NSUInteger _intentEpoch;
    __weak UIViewController *_ownedUI;
    __weak UIWindowScene *_ownerScene,*_intentScene;
}
- (instancetype)initWithPreparedRootURL:(NSURL *)prepared cacheRootURL:(NSURL *)cache {
    if((self=[super initWithStyle:UITableViewStyleInsetGrouped])) {
        _storage=[[CanopyStorage alloc] initWithPreparedRootURL:prepared cacheRootURL:cache];
        _status=@"Storage has not been checked.";
    }
    return self;
}
- (NSDictionary<NSString *,id> *)diagnosticSnapshot {return _storage.snapshot;}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"Storage";
    self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=80;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(storageBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(storageForeground:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(storageSceneBackground:) name:UISceneDidEnterBackgroundNotification object:nil];
    [self reloadStorage];
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];if(self.view.window.windowScene)_ownerScene=self.view.window.windowScene;[self refresh];}
- (UIWindow *)ownerWindow {
    UIWindow *window=self.viewIfLoaded.window;UIViewController *owned=_ownedUI;
    // Some own presentation styles detach the underlying view temporarily.
    // Only our exact presented UI may supply its window; foreign UI may not.
    if(!window&&owned&&self.presentedViewController==owned)window=owned.viewIfLoaded.window;
    return window;
}
- (BOOL)activeOwner {
    if(!NSThread.isMainThread)return NO;
    UIWindow *window=[self ownerWindow];
    return window.isKeyWindow&&window.windowScene.activationState==UISceneActivationStateForegroundActive&&
        UIApplication.sharedApplication.applicationState==UIApplicationStateActive&&
        !self.isBeingDismissed&&!self.isMovingFromParentViewController&&!self.navigationController.isBeingDismissed&&
        (!self.navigationController||self.navigationController.topViewController==self);
}
- (BOOL)intentValid:(NSUInteger)epoch {
    if(epoch!=_intentEpoch||![self activeOwner])return NO;
    UIViewController *presented=self.presentedViewController;
    return _intentScene==[self ownerWindow].windowScene&&(!presented||presented==_ownedUI);
}
- (void)invalidateIntent {
    ++_intentEpoch;UIViewController *owned=_ownedUI;_ownedUI=nil;
    if(owned&&self.presentedViewController==owned&&!owned.isBeingDismissed)
        [owned dismissViewControllerAnimated:NO completion:nil];
    // No backend cancellation: already accepted storage work/recovery finishes
    // and updates the authoritative model even if this UI leaves the scene.
}
- (void)storageBackground:(NSNotification *)notification {(void)notification;[self invalidateIntent];[self refresh];}
- (void)storageForeground:(NSNotification *)notification {(void)notification;[self refresh];}
- (void)storageSceneBackground:(NSNotification *)notification {
    // A single iPad scene can background while the application stays active.
    // Keep the captured scene even when an owned modal covers the source view.
    if(notification.object==_intentScene||notification.object==_ownerScene||notification.object==self.viewIfLoaded.window.windowScene) {
        [self invalidateIntent];[self refresh];
    }
}
- (void)restorePop {
    if(_suppressedPop){self.navigationController.interactivePopGestureRecognizer.enabled=_previousPop;_suppressedPop=NO;}
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Presenting this controller's own sheets is not leaving its container.
    if(self.isMovingFromParentViewController||self.isBeingDismissed||self.navigationController.isBeingDismissed||
        (self.navigationController&&self.navigationController.topViewController!=self)) {
        [self invalidateIntent];[self restorePop];
    }
}
- (void)refresh {
    BOOL busy=_storage.busy,ownsNavigation=self.navigationController.topViewController==self;
    if(busy&&ownsNavigation&&!_suppressedPop){_previousPop=self.navigationController.interactivePopGestureRecognizer.enabled;_suppressedPop=YES;
        self.navigationController.interactivePopGestureRecognizer.enabled=NO;}
    if(!busy||!ownsNavigation)[self restorePop];
    self.modalInPresentation=busy;self.navigationItem.hidesBackButton=busy;self.tableView.userInteractionEnabled=!busy;
    if(busy) {
        UIActivityIndicatorView *spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];[spinner startAnimating];
        spinner.accessibilityLabel=@"Storage operation in progress";
        self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithCustomView:spinner];
    } else self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Reload" style:UIBarButtonItemStylePlain target:self action:@selector(reloadStorage)];
    [self.tableView reloadData];
}
- (void)reloadStorage {
    if(_storage.busy)return;
    [self invalidateIntent];
    _status=@"Reading storage in the background…";
    BOOL accepted=[_storage reloadWithCompletion:^(NSDictionary *snapshot,NSError *error){
        self->_status=error?error.localizedDescription:[snapshot[@"complete"] boolValue]?@"Storage checked.":@"Some storage entries could not be listed. Existing files were preserved.";
        [self refresh];
    }];
    if(!accepted)_status=@"Storage is busy.";
    [self refresh];
}
- (NSArray *)rows:(NSInteger)section {
    return _storage.snapshot[@[@"generations",@"jobs",@"shaders"][(NSUInteger)section]]?:@[];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {(void)tableView;return 3;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {(void)tableView;return MAX((NSInteger)[self rows:section].count,1);}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;return @[@"Prepared data",@"Unfinished preparations",@"Private shader caches"][(NSUInteger)section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if(section==0)return [NSString stringWithFormat:@"%@\nSelect data to verify its logical size or change the current selection. Verification checks assets, not gameplay compatibility. Current, previous and active versions are protected.",_status];
    if(section==1)return @"Resume by reselecting the original preparation mode, source and local keys. Native verification must match the retained job; a listed ID does not identify its input kind. Add-ons resume through their exact base's Add-ons screen. Only unpublished jobs can be discarded. Saves and supplied source files are preserved.";
    NSArray *issues=_storage.snapshot[@"issues"];
    NSString *details=issues.count?[[issues componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"]:@"";
    return [details stringByAppendingString:@"Sizes are logical file lengths, not disk allocation or promised free space. Clear keeps the seed; remove targets one identity. In-use caches cannot be cleared or removed. Unknown or corrupt entries are preserved."];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"storage"];
    if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"storage"];
    cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;
    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;cell.selectionStyle=UITableViewCellSelectionStyleDefault;
    NSArray *rows=[self rows:path.section];
    if(!rows.count){cell.textLabel.text=[_storage.snapshot[@"complete"] boolValue]?@"No entries":@"Storage unavailable";
        cell.detailTextLabel.text=nil;cell.accessoryType=UITableViewCellAccessoryNone;cell.selectionStyle=UITableViewCellSelectionStyleNone;return cell;}
    NSDictionary *row=rows[(NSUInteger)path.row];NSString *identifier=STShort(row[@"identifier"]);
    if(path.section==0) {
        NSString *position=[row[@"current"] boolValue]?@"Current":[row[@"previous"] boolValue]?@"Previous rollback copy":@"Unused selection";
        cell.textLabel.text=[NSString stringWithFormat:@"%@ • %@",row[@"titleID"],position];
        NSString *checked=[row[@"verification"] isEqual:@"verified"]?@"Assets checked":@"Hash check required";
        cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ • %@\nLogical assets: %@",identifier,checked,STBytes(row[@"logicalAssetBytes"])];
    } else if(path.section==1) {cell.textLabel.text=@"Unfinished preparation";cell.detailTextLabel.text=identifier;}
    else {cell.textLabel.text=[NSString stringWithFormat:@"%@ • %@",row[@"titleID"],identifier];
        cell.detailTextLabel.text=[row[@"usageState"] isEqual:@"available"]?[NSString stringWithFormat:@"Seed %@ • generated cache %@",STBytes(row[@"seedBytes"]),STBytes(row[@"runtimeBytes"])]:@"Cache could not be verified for management. Existing files were preserved.";}
    return cell;
}
- (BOOL)canMutate {
    return !self.mutationAllowed||self.mutationAllowed();
}
- (void)message:(NSString *)text {
    _status=text;[self refresh];
    if(![self activeOwner]||self.presentedViewController)return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Storage" message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];_ownedUI=alert;[self presentViewController:alert animated:YES completion:nil];
}
- (void)perform:(CanopyStorageAction)action row:(NSDictionary *)row intent:(NSUInteger)intent {
    if(_storage.busy||![self intentValid:intent])return;
    if(action!=CanopyStorageVerifyGeneration&&![self canMutate]){[self message:@"Storage changes are unavailable while a preparation or native session owns the library."];return;}
    _status=action==CanopyStorageVerifyGeneration?@"Verifying the selected assets in the background…":@"Waiting for the storage operation to finish…";
    BOOL accepted=[_storage performAction:action identifier:row[@"identifier"] titleID:action==CanopyStorageDiscardJob?nil:row[@"titleID"]
        completion:^(NSDictionary *snapshot,NSError *error){
            if(error) {
                NSString *message=error.localizedDescription;NSDictionary *operation=snapshot[@"operation"];
                if(action==CanopyStorageSelectGeneration)message=[message stringByAppendingFormat:@"\nCurrent read after the operation: %@",
                    [operation[@"currentReadState"] isEqual:@"confirmed"]?STShort(operation[@"currentGenerationID"]):@"unavailable; refresh before retrying"];
                if(intent==self->_intentEpoch)[self message:message];
                else {self->_status=message;[self refresh];}
            } else {self->_status=action==CanopyStorageVerifyGeneration?@"Asset verification completed. Execution remains unassessed.":@"The storage operation completed.";[self refresh];}
        }];
    if(!accepted)_status=@"The selected operation could not be started.";
    [self refresh];
}
- (void)confirm:(CanopyStorageAction)action row:(NSDictionary *)row title:(NSString *)title message:(NSString *)message intent:(NSUInteger)intent {
    if(_storage.busy||![self intentValid:intent])return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    __weak UIAlertController *weakAlert=alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Continue" style:action==CanopyStorageSelectGeneration?UIAlertActionStyleDefault:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *button){(void)button;
            if(!weakAlert||self->_ownedUI!=weakAlert||![self intentValid:intent])return;
            [self perform:action row:row intent:intent];
        }]];
    UIViewController *presented=self.presentedViewController;
    void (^present)(void)=^{
        if(self->_storage.busy||![self intentValid:intent]||self.presentedViewController)return;
        self->_ownedUI=alert;[self presentViewController:alert animated:YES completion:nil];
    };
    if(presented)[presented dismissViewControllerAnimated:YES completion:present];
    else present();
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];if(_storage.busy||![self activeOwner]||self.presentedViewController)return;
    NSArray *rows=[self rows:path.section];if((NSUInteger)path.row>=rows.count)return;NSDictionary *row=[rows[(NSUInteger)path.row] copy];
    NSUInteger intent=++_intentEpoch;_intentScene=self.view.window.windowScene;
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:STShort(row[@"identifier"]) message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak UIAlertController *weakSheet=sheet;
    if(path.section==0) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Verify assets and logical size" style:UIAlertActionStyleDefault handler:^(UIAlertAction *button){(void)button;if(!weakSheet||self->_ownedUI!=weakSheet||![self intentValid:intent])return;[self perform:CanopyStorageVerifyGeneration row:row intent:intent];}]];
        if(![row[@"current"] boolValue]&&![row[@"referenceState"] isEqual:@"unavailable"])
            [sheet addAction:[UIAlertAction actionWithTitle:@"Use this prepared data" style:UIAlertActionStyleDefault handler:^(UIAlertAction *button){(void)button;if(!weakSheet||self->_ownedUI!=weakSheet||![self intentValid:intent])return;
                [self confirm:CanopyStorageSelectGeneration row:row title:@"Change current prepared data?" message:@"The selected assets are reverified before selection. The displaced current data is retained for rollback. This does not establish gameplay compatibility." intent:intent];}]];
        if(![row[@"current"] boolValue]&&![row[@"previous"] boolValue]&&[row[@"referenceState"] isEqual:@"confirmed"])
            [sheet addAction:[UIAlertAction actionWithTitle:@"Remove unused prepared data" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *button){(void)button;if(!weakSheet||self->_ownedUI!=weakSheet||![self intentValid:intent])return;
                [self confirm:CanopyStorageRemoveGeneration row:row title:@"Remove this prepared data?" message:@"Only this unused prepared data is removed. Current, rollback and active versions are checked again and protected. Saves and supplied source files are preserved." intent:intent];}]];
    } else if(path.section==1) {
        if(self.resumePreparation) [sheet addAction:[UIAlertAction actionWithTitle:@"Resume with reselected inputs" style:UIAlertActionStyleDefault handler:^(UIAlertAction *button){
            (void)button;if(!weakSheet||self->_ownedUI!=weakSheet||![self intentValid:intent])return;NSString *job=row[@"identifier"];
            if(self->_storage.busy||!mng_selection_job_valid(job.UTF8String)||
                UIApplication.sharedApplication.applicationState!=UIApplicationStateActive||
                (self.mutationAllowed&&!self.mutationAllowed()))return;
            void (^resume)(NSString *)=[self.resumePreparation copy];
            void (^continueResume)(void)=^{if(resume&&!self->_storage.busy&&[self intentValid:intent]&&!self.presentedViewController&&
                UIApplication.sharedApplication.applicationState==UIApplicationStateActive&&
                (!self.mutationAllowed||self.mutationAllowed()))resume(job);};
            // UIKit may already have dismissed its action sheet. Never ask the
            // storage/container controller to dismiss an unrelated presentation.
            UIViewController *owned=weakSheet,*presented=self.presentedViewController;
            if(presented==owned)[owned dismissViewControllerAnimated:YES completion:continueResume];
            else if(!presented)continueResume();
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Discard unfinished preparation" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *button){(void)button;if(!weakSheet||self->_ownedUI!=weakSheet||![self intentValid:intent])return;
            [self confirm:CanopyStorageDiscardJob row:row title:@"Discard this preparation?" message:@"Only this unpublished job is discarded. Finish or cancel an active preparation first. Prepared versions, saves and source files are preserved." intent:intent];}]];
    } else if([row[@"usageState"] isEqual:@"available"]) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Clear generated shader cache" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *button){(void)button;if(!weakSheet||self->_ownedUI!=weakSheet||![self intentValid:intent])return;
            [self confirm:CanopyStorageClearShaderRuntime row:row title:@"Clear generated shader cache?" message:@"The seed is retained. Active caches cannot be cleared. Disk space changes may differ from logical file sizes." intent:intent];}]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Remove shader seed and cache" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *button){(void)button;if(!weakSheet||self->_ownedUI!=weakSheet||![self intentValid:intent])return;
            [self confirm:CanopyStorageRemoveShaderIdentity row:row title:@"Remove this shader identity?" message:@"Only this cached identity is removed. Supplied seed files and saves are preserved. Active identities cannot be removed." intent:intent];}]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView=tableView;sheet.popoverPresentationController.sourceRect=[tableView rectForRowAtIndexPath:path];
    _ownedUI=sheet;[self presentViewController:sheet animated:YES completion:nil];
}
@end
CanopyStorageController *CanopyMakeStorageController(NSURL *preparedRoot,NSURL *cacheRoot) {
    return [[CanopyStorageController alloc] initWithPreparedRootURL:preparedRoot cacheRootURL:cacheRoot];
}
