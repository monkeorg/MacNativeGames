#import "CanopyStorageController.h"

static NSString *STBytes(id value) {
    return [value isKindOfClass:NSNumber.class]?[NSByteCountFormatter stringFromByteCount:[value longLongValue] countStyle:NSByteCountFormatterCountStyleFile]:@"not checked";
}
static NSString *STShort(NSString *identifier) {return identifier.length>12?[identifier substringToIndex:12]:identifier;}
@implementation CanopyStorageController {
    CanopyStorage *_storage;
    NSString *_status;
    BOOL _suppressedPop,_previousPop;
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
    [self reloadStorage];
}
- (void)restorePop {
    if(_suppressedPop){self.navigationController.interactivePopGestureRecognizer.enabled=_previousPop;_suppressedPop=NO;}
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if(self.isMovingFromParentViewController||self.isBeingDismissed)[self restorePop];
}
- (void)refresh {
    BOOL busy=_storage.busy;
    if(busy&&!_suppressedPop){_previousPop=self.navigationController.interactivePopGestureRecognizer.enabled;_suppressedPop=YES;
        self.navigationController.interactivePopGestureRecognizer.enabled=NO;}
    if(!busy)[self restorePop];
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
    if(section==1)return @"Only unpublished preparation jobs can be discarded. Finish or cancel an active preparation first. Source files, profiles, account identities and saves are outside these operations.";
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
    if(self.presentedViewController)return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Storage" message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:alert animated:YES completion:nil];
}
- (void)perform:(CanopyStorageAction)action row:(NSDictionary *)row {
    if(_storage.busy)return;
    if(action!=CanopyStorageVerifyGeneration&&![self canMutate]){[self message:@"Storage changes are unavailable while a preparation or native session owns the library."];return;}
    _status=action==CanopyStorageVerifyGeneration?@"Verifying the selected assets in the background…":@"Waiting for the storage operation to finish…";
    BOOL accepted=[_storage performAction:action identifier:row[@"identifier"] titleID:action==CanopyStorageDiscardJob?nil:row[@"titleID"]
        completion:^(NSDictionary *snapshot,NSError *error){
            if(error) {
                NSString *message=error.localizedDescription;NSDictionary *operation=snapshot[@"operation"];
                if(action==CanopyStorageSelectGeneration)message=[message stringByAppendingFormat:@"\nCurrent read after the operation: %@",
                    [operation[@"currentReadState"] isEqual:@"confirmed"]?STShort(operation[@"currentGenerationID"]):@"unavailable; refresh before retrying"];
                [self message:message];
            } else {self->_status=action==CanopyStorageVerifyGeneration?@"Asset verification completed. Execution remains unassessed.":@"The storage operation completed.";[self refresh];}
        }];
    if(!accepted)_status=@"The selected operation could not be started.";
    [self refresh];
}
- (void)confirm:(CanopyStorageAction)action row:(NSDictionary *)row title:(NSString *)title message:(NSString *)message {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Continue" style:action==CanopyStorageSelectGeneration?UIAlertActionStyleDefault:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *button){(void)button;[self perform:action row:row];}]];
    UIViewController *presented=self.presentedViewController;
    if(presented)[presented dismissViewControllerAnimated:YES completion:^{[self presentViewController:alert animated:YES completion:nil];}];
    else [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];if(_storage.busy)return;
    NSArray *rows=[self rows:path.section];if(!rows.count)return;NSDictionary *row=rows[(NSUInteger)path.row];
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:STShort(row[@"identifier"]) message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    if(path.section==0) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Verify assets and logical size" style:UIAlertActionStyleDefault handler:^(UIAlertAction *button){(void)button;[self perform:CanopyStorageVerifyGeneration row:row];}]];
        if(![row[@"current"] boolValue]&&![row[@"referenceState"] isEqual:@"unavailable"])
            [sheet addAction:[UIAlertAction actionWithTitle:@"Use this prepared data" style:UIAlertActionStyleDefault handler:^(UIAlertAction *button){(void)button;
                [self confirm:CanopyStorageSelectGeneration row:row title:@"Change current prepared data?" message:@"The selected assets are reverified before selection. The displaced current data is retained for rollback. This does not establish gameplay compatibility."];}]];
        if(![row[@"current"] boolValue]&&![row[@"previous"] boolValue]&&[row[@"referenceState"] isEqual:@"confirmed"])
            [sheet addAction:[UIAlertAction actionWithTitle:@"Remove unused prepared data" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *button){(void)button;
                [self confirm:CanopyStorageRemoveGeneration row:row title:@"Remove this prepared data?" message:@"Only this unused prepared data is removed. Current, rollback and active versions are checked again and protected. Saves and supplied source files are preserved."];}]];
    } else if(path.section==1) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Discard unfinished preparation" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *button){(void)button;
            [self confirm:CanopyStorageDiscardJob row:row title:@"Discard this preparation?" message:@"Only this unpublished job is discarded. Finish or cancel an active preparation first. Prepared versions, saves and source files are preserved."];}]];
    } else if([row[@"usageState"] isEqual:@"available"]) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Clear generated shader cache" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *button){(void)button;
            [self confirm:CanopyStorageClearShaderRuntime row:row title:@"Clear generated shader cache?" message:@"The seed is retained. Active caches cannot be cleared. Disk space changes may differ from logical file sizes."];}]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Remove shader seed and cache" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *button){(void)button;
            [self confirm:CanopyStorageRemoveShaderIdentity row:row title:@"Remove this shader identity?" message:@"Only this cached identity is removed. Supplied seed files and saves are preserved. Active identities cannot be removed."];}]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView=tableView;sheet.popoverPresentationController.sourceRect=[tableView rectForRowAtIndexPath:path];
    [self presentViewController:sheet animated:YES completion:nil];
}
@end
CanopyStorageController *CanopyMakeStorageController(NSURL *preparedRoot,NSURL *cacheRoot) {
    return [[CanopyStorageController alloc] initWithPreparedRootURL:preparedRoot cacheRootURL:cacheRoot];
}
