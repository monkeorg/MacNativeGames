#import "CanopySaveEditorController.h"
#include "mng_totk_save.h"

static NSString *const CEWarning=@"UNVERIFIED candidate. The reference identifies a TOTK 1.4.x family, not exact 1.4.3. Integrity and game compatibility are unverified; no checksum is repaired. Active Apply is unavailable.";
static void CEDiscard(CanopySaveStore *store,dispatch_queue_t queue,CanopySaveEditPreview *preview) {
    if(preview)dispatch_async(queue,^{@autoreleasepool{(void)[store discardEditPreview:preview error:NULL];}});
}
static NSString *CERefusal(enum mng_totk_save_status status) {
    switch(status) {
        case MNG_TOTK_SAVE_SIGNATURE:return @"The selected file does not match the documented reference-family tuple.";
        case MNG_TOTK_SAVE_STRUCTURE:return @"The selected file lacks an unambiguous wallet in the interpreted simple-record prefix.";
        case MNG_TOTK_SAVE_POLICY:return @"The wallet is outside the reference editor's UI policy. No candidate was produced.";
        default:return @"The candidate could not be prepared safely. Active saves were not edited.";
    }
}
@interface CanopySaveEditorController : UITableViewController
- (instancetype)initWithStore:(CanopySaveStore *)store queue:(dispatch_queue_t)queue;
@end
@implementation CanopySaveEditorController {
    CanopySaveStore *_store;
    dispatch_queue_t _queue;
    CanopySaveEditPreview *_preview;
    NSString *_slot,*_status;
    uint32_t _oldWallet,_newWallet;
    NSUInteger _epoch;
    BOOL _busy,_ready;
    UIActivityViewController *_share;
}
- (instancetype)initWithStore:(CanopySaveStore *)store queue:(dispatch_queue_t)queue {
    if((self=[super initWithStyle:UITableViewStyleInsetGrouped])){_store=store;_queue=queue;_slot=@"slot_00";}
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"Unverified rupee candidate";
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(foreground:) name:UIApplicationDidBecomeActiveNotification object:nil];
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    CEDiscard(_store,_queue,_preview);
}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];[self refresh];}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if(self.isMovingFromParentViewController||self.isBeingDismissed||self.navigationController.isBeingDismissed)[self invalidate];
}
- (BOOL)visible {
    return self.viewIfLoaded.window!=nil&&UIApplication.sharedApplication.applicationState==UIApplicationStateActive;
}
- (BOOL)canBegin {
    return [self visible]&&!_busy&&!_store.sealed&&!_store.recoveryRequired&&!self.presentedViewController;
}
- (void)refresh {
    self.navigationItem.hidesBackButton=_busy;
    self.modalInPresentation=_busy;
    [self.tableView reloadData];
}
- (void)invalidate {
    ++_epoch;_ready=NO;
    CanopySaveEditPreview *old=_preview;_preview=nil;CEDiscard(_store,_queue,old);
    // An in-flight copy continues to its authoritative completion on the same
    // save queue; stale completion may only discard its own returned token.
}
- (void)foreground:(NSNotification *)notification {
    (void)notification;[self refresh]; // Expired preview/epoch stays invalid.
}
- (void)background:(NSNotification *)notification {
    (void)notification;[self invalidate];_status=@"Preview expired after leaving the foreground. Read a new preview before sharing.";
    if(_share){_share=nil;_busy=NO;} // Programmatic dismissal need not call the activity completion.
    if(self.presentedViewController)[self dismissViewControllerAnimated:NO completion:nil];
    [self refresh];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {(void)tableView;return 3;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {(void)tableView;return section==2?1:2;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;return @[@"Private snapshot",@"Rupees — reference policy",@"Raw candidate only"][(NSUInteger)section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if(section==0)return _status?:@"Read a bounded private snapshot before editing. All active save files and account identity stay untouched.";
    if(section==1)return @"Allowed input: whole numbers 0–999,999. This is the pinned MIT reference editor's UI policy, not a certified game-format limit.";
    return CEWarning;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    (void)tableView;BOOL enabled=[self visible]&&!_busy&&!_store.sealed&&!_store.recoveryRequired;
    if(path.section==0&&path.row==0){cell.textLabel.text=@"Slot";cell.detailTextLabel.text=_slot;cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}
    else if(path.section==0){cell.textLabel.text=_busy?@"Waiting for private copy…":@"Read new preview";cell.detailTextLabel.text=@"No active edit";}
    else if(path.section==1&&path.row==0){cell.textLabel.text=@"Snapshot wallet";cell.detailTextLabel.text=_ready?[NSString stringWithFormat:@"%u",_oldWallet]:@"Not inspected";enabled=NO;}
    else if(path.section==1){cell.textLabel.text=@"Candidate wallet";cell.detailTextLabel.text=_ready?[NSString stringWithFormat:@"%u",_newWallet]:@"Read preview first";enabled=enabled&&_ready;cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}
    else {cell.textLabel.text=@"Share UNVERIFIED candidate…";enabled=enabled&&_ready;}
    cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;
    cell.textLabel.enabled=enabled;cell.selectionStyle=enabled?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;
    cell.accessibilityHint=path.section==2?@"Shares raw unverified bytes only. Never imports or applies to active saves.":nil;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];if(![self canBegin])return;
    if(path.section==0&&path.row==0)[self chooseSlot];
    else if(path.section==0)[self readPreview];
    else if(path.section==1&&path.row==1&&_ready)[self chooseWallet];
    else if(path.section==2&&_ready)[self confirmShare];
}
- (void)chooseSlot {
    NSUInteger epoch=_epoch;
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"Select an existing slot" message:@"Only a snapshot of this selected profile is read." preferredStyle:UIAlertControllerStyleActionSheet];
    for(unsigned i=0;i<6;i++) {
        NSString *slot=[NSString stringWithFormat:@"slot_0%u",i];
        [sheet addAction:[UIAlertAction actionWithTitle:slot style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            (void)action;if(self->_epoch!=epoch||![self visible]||self->_busy)return;
            [self invalidate];self->_slot=slot;self->_status=nil;[self refresh];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView=self.tableView;
    sheet.popoverPresentationController.sourceRect=[self.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)readPreview {
    if(![self canBegin])return;
    [self invalidate];_busy=YES;_status=nil;NSUInteger epoch=_epoch;NSString *slot=[_slot copy];[self refresh];
    CanopySaveStore *store=_store;dispatch_queue_t queue=_queue;
    dispatch_async(queue,^{@autoreleasepool{
        CanopySaveEditPreview *preview=[store previewEditForSlot:slot error:NULL];
        struct mng_totk_save_preview parsed={0};
        enum mng_totk_save_status status=preview?mng_totk_save_inspect(preview.originalData.bytes,preview.originalData.length,&parsed):MNG_TOTK_SAVE_INVALID;
        dispatch_async(dispatch_get_main_queue(),^{
            self->_busy=NO;
            if(self->_epoch!=epoch||![self visible]){CEDiscard(store,queue,preview);[self refresh];return;}
            if(status!=MNG_TOTK_SAVE_OK){CEDiscard(store,queue,preview);self->_status=CERefusal(status);}
            else {self->_preview=preview;self->_oldWallet=parsed.wallet;self->_newWallet=parsed.wallet;self->_ready=YES;
                self->_status=@"TOTK 1.4.x reference tuple matched. Exact version, integrity and compatibility remain unverified.";}
            [self refresh];
        });
    }});
}
- (void)chooseWallet {
    NSUInteger epoch=_epoch;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Candidate rupees" message:@"Reference UI policy: integer 0–999,999. No active save is changed." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.keyboardType=UIKeyboardTypeNumberPad;field.text=[NSString stringWithFormat:@"%u",self->_newWallet];field.accessibilityLabel=@"Unverified candidate rupees";}];
    __weak UIAlertController *weakAlert=alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Preview value" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        (void)action;if(self->_epoch!=epoch||![self visible]||self->_busy||!self->_ready)return;
        NSString *text=weakAlert.textFields.firstObject.text?:@"";uint32_t value=0;BOOL valid=text.length>0&&text.length<=6;
        for(NSUInteger i=0;valid&&i<text.length;i++){unichar c=[text characterAtIndex:i];if(c<'0'||c>'9')valid=NO;else value=value*10+(uint32_t)(c-'0');}
        if(!valid||value>MNG_TOTK_SAVE_REFERENCE_POLICY_MAX)self->_status=@"Enter only a whole number from 0 to 999,999. The prior candidate value was retained.";
        else {self->_newWallet=value;self->_status=@"Value selected for an unverified raw candidate. Active saves remain unchanged.";}
        [self refresh];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)confirmShare {
    NSUInteger epoch=_epoch;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Share an UNVERIFIED candidate?" message:CEWarning preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Share raw candidate" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        (void)action;
        [self dismissViewControllerAnimated:YES completion:^{if(self->_epoch==epoch&&[self canBegin]&&self->_ready)[self makeCandidate];}];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)makeCandidate {
    if(![self canBegin]||!_ready||!_preview)return;
    _busy=YES;NSUInteger epoch=_epoch;NSString *slot=[_slot copy];uint32_t wallet=_newWallet;
    CanopySaveEditPreview *oldPreview=_preview;
    NSData *original=oldPreview.originalData;CanopySaveStore *store=_store;dispatch_queue_t queue=_queue;
    _preview=nil;_ready=NO;[self refresh];
    dispatch_async(queue,^{@autoreleasepool{
        // Refresh the selected snapshot on the same serial owner before share.
        // A changed selected file requires a new visible preview, never a
        // silent edit against a different wallet snapshot.
        CanopySaveEditPreview *fresh=[store previewEditForSlot:slot error:NULL];
        BOOL changed=fresh&&![fresh.originalData isEqual:original];
        NSMutableData *candidate=fresh&&!changed?[NSMutableData dataWithLength:MNG_TOTK_SAVE_REFERENCE_SIZE]:nil;
        enum mng_totk_save_status status=candidate?mng_totk_save_candidate(fresh.originalData.bytes,fresh.originalData.length,wallet,candidate.mutableBytes,candidate.length):MNG_TOTK_SAVE_INVALID;
        NSData *immutable=status==MNG_TOTK_SAVE_OK?[candidate copy]:nil;
        (void)[store discardEditPreview:fresh?:oldPreview error:NULL];
        dispatch_async(dispatch_get_main_queue(),^{
            self->_busy=NO;
            if(self->_epoch!=epoch||![self visible]){[self refresh];return;}
            if(!immutable){self->_status=changed?@"The selected save changed. Read and inspect a new preview before sharing.":CERefusal(status);[self refresh];return;}
            [self shareBytes:immutable epoch:epoch];
        });
    }});
}
- (void)shareBytes:(NSData *)bytes epoch:(NSUInteger)epoch {
    if(![self canBegin]||_epoch!=epoch)return;
    NSItemProvider *provider=[NSItemProvider new];provider.suggestedName=@"UNVERIFIED-TOTK-1.4x-rupee-candidate.bin";
    [provider registerDataRepresentationForTypeIdentifier:@"public.data" visibility:NSItemProviderRepresentationVisibilityAll
        loadHandler:^NSProgress * _Nullable(void (^completion)(NSData * _Nullable,NSError * _Nullable)) {completion(bytes,nil);return nil;}];
    UIActivityItemsConfiguration *configuration=[[UIActivityItemsConfiguration alloc] initWithItemProviders:@[provider]];
    configuration.metadataProvider=^id _Nullable(UIActivityItemsConfigurationMetadataKey key){return [key isEqual:UIActivityItemsConfigurationMetadataKeyTitle]?@"UNVERIFIED TOTK reference-family candidate":nil;};
    UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItemsConfiguration:configuration];_share=share;
    _busy=YES;_status=@"Sharing raw unverified bytes. This is not a validated Canopy save export and is never imported automatically.";[self refresh];
    __weak CanopySaveEditorController *weakSelf=self;
    __weak UIActivityViewController *weakShare=share;
    share.completionWithItemsHandler=^(UIActivityType type,BOOL completed,NSArray *items,NSError *error){
        (void)type;(void)completed;(void)items;(void)error;
        dispatch_async(dispatch_get_main_queue(),^{CanopySaveEditorController *owner=weakSelf;
            UIActivityViewController *finished=weakShare;
            if(!owner||!finished||owner->_share!=finished)return;
            owner->_busy=NO;owner->_share=nil;if(owner->_epoch==epoch)owner->_status=@"Share sheet closed. Active saves were never edited. Read a new preview for another candidate.";[owner refresh];});
    };
    share.popoverPresentationController.sourceView=self.tableView;
    share.popoverPresentationController.sourceRect=[self.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:2]];
    [self presentViewController:share animated:YES completion:nil];
}
@end
UIViewController *CanopyMakeTOTKSaveEditorController(CanopySaveStore *store,dispatch_queue_t existingSaveQueue) {
    NSCParameterAssert(store);NSCParameterAssert(existingSaveQueue);
    return [[CanopySaveEditorController alloc] initWithStore:store queue:existingSaveQueue];
}
