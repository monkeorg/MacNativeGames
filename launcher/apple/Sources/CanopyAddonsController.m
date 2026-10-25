#import "CanopyAddonsController.h"
#import "CanopyCatalog.h"
#import "CanopyPreparation.h"
#import "CanopySessionController.h"
#import "CanopyStorageController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static BOOL CAHex(id value,NSUInteger length) {
    return [value isKindOfClass:NSString.class]&&[value length]==length&&
        [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
static BOOL CATitle(id value) {return CAHex(value,16)&&![value isEqual:@"0000000000000000"];}
static NSString *CAText(id value) {return !value||value==NSNull.null?@"Unavailable":[value description];}

@interface CanopyAddonsController ()<UIDocumentPickerDelegate>
@end
@implementation CanopyAddonsController {
    NSDictionary *_base;
    NSURL *_prepared,*_cache,*_source;
    CanopyPreparation *_preparation;
    __weak UIDocumentPickerViewController *_picker;
    dispatch_queue_t _catalogQueue;
    NSArray<NSDictionary *> *_rows;
    NSArray<NSString *> *_issues;
    NSString *_status,*_progressText,*_selectedAddon,*_resumeAddon,*_resumeJob;
    NSUInteger _stage,_selectionEpoch;
    BOOL _reloading,_catalogFailed,_cancelRequested,_resuming,_previousPop,_suppressedPop;
}
- (instancetype)initWithBaseEntry:(NSDictionary *)base preparedRootURL:(NSURL *)prepared globalCacheRootURL:(NSURL *)cache settings:(CanopySettings *)settings {
    return [self initWithBaseEntry:base preparedRootURL:prepared globalCacheRootURL:cache settings:settings resumeJobIdentifier:nil addonTitleID:nil];
}
- (instancetype)initWithBaseEntry:(NSDictionary *)base preparedRootURL:(NSURL *)prepared globalCacheRootURL:(NSURL *)cache settings:(CanopySettings *)settings
    resumeJobIdentifier:(NSString *)jobIdentifier addonTitleID:(NSString *)addonTitleID {
    if((jobIdentifier!=nil)!=(addonTitleID!=nil)||(jobIdentifier&&(!CAHex(jobIdentifier,32)||!CATitle(addonTitleID)||[addonTitleID isEqual:base[@"titleID"]])))return nil;
    if((self=[super initWithStyle:UITableViewStyleInsetGrouped])) {
        _resumeJob=[jobIdentifier copy];_resumeAddon=[addonTitleID copy];
        (void)settings; // Factory compatibility; this IDs-only screen reads no user metadata.
        _base=[base copy];_prepared=[prepared copy];_cache=[cache copy];_rows=@[];_issues=@[];
        _status=@"Prepared add-ons are not activated by this screen.";
        _catalogQueue=dispatch_queue_create("org.monkeorg.canopy.addons.catalog",DISPATCH_QUEUE_SERIAL);
        _preparation=[[CanopyPreparation alloc] initWithPreparedRootURL:prepared];
        __weak CanopyAddonsController *weakSelf=self;
        _preparation.progress=^(NSString *phase,uint64_t done,uint64_t total){
            (void)phase;CanopyAddonsController *owner=weakSelf;if(!owner||!owner->_preparation.busy)return;
            owner->_progressText=[NSString stringWithFormat:@"Preparation progress: %llu / %llu",(unsigned long long)done,(unsigned long long)total];[owner refresh];
        };
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    }
    return self;
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (BOOL)working {return _reloading||_preparation.busy||_stage!=0;}
- (BOOL)canMutate {return ![CanopySessionController nativeSessionOwnsProcess]&&(!self.mutationAllowed||self.mutationAllowed());}
- (BOOL)validBase {return CATitle(_base[@"titleID"])&&CAHex(_base[@"generationID"],64)&&![_base[@"preparedKind"] isEqual:@"addOn"];}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"Add-ons";self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=75;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if(![self working]&&UIApplication.sharedApplication.applicationState==UIApplicationStateActive)[self reloadCatalog];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if(self.isMovingFromParentViewController||self.isBeingDismissed){[self cancelCurrent];[self clearSelection];[self restorePop];}
}
- (void)restorePop {if(_suppressedPop){self.navigationController.interactivePopGestureRecognizer.enabled=_previousPop;_suppressedPop=NO;}}
- (void)refresh {
    BOOL busy=[self working];self.tableView.userInteractionEnabled=!busy;self.modalInPresentation=busy;self.navigationItem.hidesBackButton=busy;
    if(busy&&!_suppressedPop){_previousPop=self.navigationController.interactivePopGestureRecognizer.enabled;_suppressedPop=YES;self.navigationController.interactivePopGestureRecognizer.enabled=NO;}
    if(!busy)[self restorePop];
    if(_preparation.busy||_stage) {
        self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:_cancelRequested?@"Cancel requested":@"Cancel" style:UIBarButtonItemStylePlain target:self action:@selector(cancelCurrent)];
        self.navigationItem.rightBarButtonItem.enabled=!_cancelRequested;
    } else if(_reloading) {
        UIActivityIndicatorView *spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];[spinner startAnimating];
        spinner.accessibilityLabel=@"Verifying prepared add-ons";self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithCustomView:spinner];
    } else self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Reload" style:UIBarButtonItemStylePlain target:self action:@selector(reloadCatalog)];
    [self.tableView reloadData];
}
- (void)reloadCatalog {
    if([self working])return;
    if(![self validBase]){_status=@"A verified base title and exact generation are required. Reopen this screen from the verified library.";[self refresh];return;}
    _reloading=YES;[self refresh];NSString *application=[_base[@"titleID"] copy];
    dispatch_async(_catalogQueue,^{@autoreleasepool{
        CanopyCatalog *catalog=[[CanopyCatalog alloc] initWithPreparedRootURL:self->_prepared settings:nil];NSError *error=nil;
        BOOL okay=[catalog reload:&error];NSMutableArray *matching=[NSMutableArray new];
        if(okay)for(NSDictionary *entry in catalog.addOns)if([entry[@"applicationID"] isEqual:application]&&matching.count<128)[matching addObject:entry];
        NSArray *rows=[matching copy],*issues=[catalog.issues copy];
        dispatch_async(dispatch_get_main_queue(),^{
            self->_reloading=NO;if(okay)self->_rows=rows;self->_issues=issues;
            if(!okay)self->_status=@"Catalog verification could not complete. The list is the previous observation; refresh before retrying. Existing files were preserved.";
            else if(self->_catalogFailed)self->_status=@"Catalog reverified. Prepared add-ons are not activated.";
            self->_catalogFailed=!okay;
            [self refresh];
        });
    }});
}
- (void)clearSelection {_selectionEpoch++;_stage=0;_source=nil;_selectedAddon=nil;_resuming=NO;_picker=nil;}
- (void)cancelCurrent {
    if(_preparation.busy){if(!_cancelRequested){_cancelRequested=YES;[_preparation cancel];_status=@"Cancellation requested. Waiting for the authoritative result; publication may already have completed.";}}
    else if(_stage){[self clearSelection];[self dismissViewControllerAnimated:YES completion:nil];_status=@"Selection canceled. No selected source or key URL was retained.";}
    [self refresh];
}
- (void)background:(NSNotification *)notification {(void)notification;[self cancelCurrent];}
- (void)notice:(NSString *)message {
    _status=message;[self refresh];if(self.presentedViewController||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Add-ons" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:alert animated:YES completion:nil];
}
- (void)presentPickerForStage:(NSUInteger)stage epoch:(NSUInteger)epoch {
    if(_selectionEpoch!=epoch||_stage!=stage||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:NO];
    picker.title=stage==1?@"Choose add-on NSP/XCI":@"Choose your local key file";picker.allowsMultipleSelection=NO;picker.delegate=self;
    _picker=picker;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)beginSelectionResuming:(BOOL)resume {
    if([self working]||![self validBase]||![self canMutate]||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive){[self notice:@"Preparation is unavailable while another operation or native session owns the library."];return;}
    if(resume&&(!CAHex(_resumeJob,32)||!CATitle(_resumeAddon)))return;
    [self clearSelection];_resuming=resume;_selectedAddon=resume?[_resumeAddon copy]:nil;_stage=1;
    _status=resume?@"Choose the original source and local keys again to resume the retained job.":@"Choose an add-on source, its exact title ID and your local keys.";
    [self refresh];[self presentPickerForStage:1 epoch:_selectionEpoch];
}
- (void)chooseNew {
    if(!_resumeJob){[self beginSelectionResuming:NO];return;}
    _stage=5;NSUInteger epoch=++_selectionEpoch;[self refresh];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Start a different preparation?" message:@"Any unpublished data from the previous attempt is preserved in Storage. This screen will track the new preparation ID after it starts. Cancel to reuse the previous ID instead." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){(void)action;if(epoch==self->_selectionEpoch){[self clearSelection];[self refresh];}}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Choose new source" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;
        if(epoch!=self->_selectionEpoch||self->_stage!=5)return;
        [self dismissViewControllerAnimated:YES completion:^{if(epoch==self->_selectionEpoch&&self->_stage==5){[self clearSelection];[self beginSelectionResuming:NO];}}];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)askTitleAtEpoch:(NSUInteger)epoch {
    if(epoch!=_selectionEpoch||_stage!=2||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Exact add-on title ID" message:@"Enter the 16-digit hexadecimal title ID of the add-on in your source. This identifies a selection; verified source metadata must match. The base title ID is not an add-on ID." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"16 hexadecimal digits";field.autocapitalizationType=UITextAutocapitalizationTypeNone;field.autocorrectionType=UITextAutocorrectionTypeNo;field.spellCheckingType=UITextSpellCheckingTypeNo;}];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){(void)action;if(epoch==self->_selectionEpoch){[self clearSelection];[self refresh];}}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;
        if(epoch!=self->_selectionEpoch||self->_stage!=2)return;
        NSString *title=[alert.textFields.firstObject.text lowercaseString];
        if(!CATitle(title)||[title isEqual:self->_base[@"titleID"]]){[self clearSelection];[self notice:@"Enter a nonzero 16-digit add-on title ID distinct from the base. No title ID was inferred."];return;}
        self->_selectedAddon=[title copy];self->_stage=3;
        [self dismissViewControllerAnimated:YES completion:^{[self presentPickerForStage:3 epoch:epoch];}];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if(controller!=_picker)return;[self clearSelection];[controller dismissViewControllerAnimated:YES completion:nil];[self refresh];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if(controller!=_picker||(_stage!=1&&_stage!=3))return;
    _picker=nil;
    NSUInteger epoch=_selectionEpoch;
    if(urls.count!=1||!urls.firstObject.isFileURL){[self clearSelection];[controller dismissViewControllerAnimated:YES completion:nil];[self refresh];return;}
    NSURL *url=urls.firstObject;
    if(_stage==1) {
        if(![@[@"nsp",@"xci"] containsObject:url.pathExtension.lowercaseString]){[self clearSelection];[controller dismissViewControllerAnimated:YES completion:^{[self notice:@"Choose a local NSP or XCI add-on container."];}];return;}
        _source=url;_stage=_resuming?3:2;
        [controller dismissViewControllerAnimated:YES completion:^{if(self->_stage==2)[self askTitleAtEpoch:epoch];else [self presentPickerForStage:3 epoch:epoch];}];
    } else {
        NSURL *source=_source;NSString *addon=[_selectedAddon copy];BOOL resume=_resuming;
        _source=nil;_stage=4;
        [controller dismissViewControllerAnimated:YES completion:^{[self startSource:source keys:url addon:addon resume:resume epoch:epoch];}];
    }
}
- (void)startSource:(NSURL *)source keys:(NSURL *)keys addon:(NSString *)addon resume:(BOOL)resume epoch:(NSUInteger)epoch {
    if(epoch!=_selectionEpoch||_stage!=4)return;
    if(!source.isFileURL||!keys.isFileURL||!CATitle(addon)||![self canMutate]||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive){[self clearSelection];[self notice:@"Preparation could not start. Choose your local inputs again after other operations finish."];return;}
    NSString *job=resume?[_resumeJob copy]:[[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
    _stage=0;_selectedAddon=nil;_resuming=NO;_cancelRequested=NO;_progressText=nil;
    BOOL accepted=[_preparation startAddonURL:source keysURL:keys applicationID:_base[@"titleID"] baseGenerationID:_base[@"generationID"] addonTitleID:addon jobIdentifier:job completion:^(NSDictionary *result,NSError *error){
        self->_cancelRequested=NO;self->_progressText=nil;
        if(result){self->_resumeJob=nil;self->_resumeAddon=nil;self->_status=@"Add-on assets prepared. They are not activated. The catalog will verify current data.";}
        else if([error.userInfo[@"publicationUncertain"] boolValue])self->_status=@"Publication could not be confirmed and current data may have changed. Review the reloaded list before resuming; prepared does not mean activated.";
        else self->_status=error.code==6?@"Preparation canceled before confirmed completion. The retained job can be resumed with the same inputs.":@"Preparation did not complete. Review the reloaded catalog and Storage before retrying the retained job.";
        [self reloadCatalog];[self refresh];
    }];
    if(accepted){_resumeJob=[job copy];_resumeAddon=[addon copy];_status=@"Preparing the selected add-on against the exact verified base generation…";}
    else _status=@"The preparation job could not start. Select your inputs again after other operations finish.";
    [self refresh];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {(void)tableView;return 2;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {(void)tableView;return section==0?MAX((NSInteger)_rows.count,1):3;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {(void)tableView;return section==0?@"Prepared add-ons for this application":@"Local preparation and storage";}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if(section==0)return [NSString stringWithFormat:@"%@\n%@\n%@",_status,_progressText?:@"",[_issues componentsJoinedByString:@"\n"]];
    return [NSString stringWithFormat:@"Base %@ • generation %@\nPrepared assets are not activated. The current TOTK host has no add-on binding. Installation does not grant mount, execution or gameplay support. Sources, keys, saves and account identities are outside storage cleanup. Storage retains only the exact resume IDs; select the original source and keys again.",CAText(_base[@"titleID"]),CAText(_base[@"generationID"])];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"addon"];
    if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"addon"];
    cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;
    cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;cell.accessoryType=UITableViewCellAccessoryNone;cell.selectionStyle=UITableViewCellSelectionStyleNone;
    if(path.section==0) {
        if(!_rows.count){cell.textLabel.text=@"No verified prepared add-ons listed";cell.detailTextLabel.text=@"Unknown or corrupt entries are preserved.";return cell;}
        NSDictionary *entry=_rows[(NSUInteger)path.row];cell.textLabel.text=[NSString stringWithFormat:@"%@ • Prepared, not activated",CAText(entry[@"titleID"])];
        cell.detailTextLabel.text=[NSString stringWithFormat:@"Version %@ • requires application version %@\nGeneration %@\nLogical assets: %@",CAText(entry[@"titleVersion"]),CAText(entry[@"requiredApplicationVersion"]),CAText(entry[@"generationID"]),[NSByteCountFormatter stringFromByteCount:[entry[@"assetBytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]];
    } else {
        cell.textLabel.text=@[@"Prepare add-on from local container",@"Resume retained preparation",@"Manage prepared storage"][(NSUInteger)path.row];
        cell.detailTextLabel.text=path.row==0?@"Choose source, exact add-on title ID, then your local keys":path.row==1?(_resumeJob?[NSString stringWithFormat:@"Job %@\nAdd-on %@",_resumeJob,_resumeAddon]:@"No unfinished job is retained by this screen"):@"Verify, select or remove through existing protected storage controls";
        if(path.row!=1||_resumeJob){cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;cell.selectionStyle=UITableViewCellSelectionStyleDefault;}
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];if(path.section!=1||[self working])return;
    if(path.row==0)[self chooseNew];else if(path.row==1)[self beginSelectionResuming:YES];else {
        CanopyStorageController *storage=CanopyMakeStorageController(_prepared,_cache);__weak CanopyAddonsController *weakSelf=self;
        storage.mutationAllowed=^BOOL {CanopyAddonsController *owner=weakSelf;return owner&&![owner working]&&[owner canMutate];};
        [self.navigationController pushViewController:storage animated:YES];
    }
}
@end
CanopyAddonsController *CanopyMakeAddonsController(NSDictionary *base,NSURL *prepared,NSURL *cache,CanopySettings *settings) {
    return [[CanopyAddonsController alloc] initWithBaseEntry:base preparedRootURL:prepared globalCacheRootURL:cache settings:settings];
}
