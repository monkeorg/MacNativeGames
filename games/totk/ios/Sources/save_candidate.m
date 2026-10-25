#import "save_candidate.h"
#include "../../../../launcher/include/mng_totk_save.h"
static NSString *const CandidateWarning=@"UNVERIFIED raw candidate. The documented tuple identifies a TOTK 1.4.x family, not exact 1.4.3. Integrity and compatibility remain unverified. No checksum is repaired. This sheet never applies or imports a candidate.";
@implementation TOTKSaveCandidate {
    NSData *_source;
    dispatch_queue_t _queue;
    TOTKCandidateRefresh _refresh;
    void (^_closed)(void);
    NSString *_status;
    uint32_t _originalWallet,_wallet;
    BOOL _ready,_working,_expired,_finished;
    UIActivityViewController *_share;
}
- (instancetype)initWithProgressData:(NSData *)data queue:(dispatch_queue_t)queue
    refreshSnapshot:(TOTKCandidateRefresh)refresh completion:(void (^)(void))closed {
    if((self=[super initWithStyle:UITableViewStyleInsetGrouped])){_source=[data copy];_queue=queue;_refresh=[refresh copy];_closed=[closed copy];}
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"Unverified rupee candidate";self.modalInPresentation=YES;
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Close" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(foreground:) name:UIApplicationDidBecomeActiveNotification object:nil];
    _working=YES;[self update];
    dispatch_async(_queue,^{@autoreleasepool{
        struct mng_totk_save_preview parsed={0};enum mng_totk_save_status status=mng_totk_save_inspect(self->_source.bytes,self->_source.length,&parsed);
        dispatch_async(dispatch_get_main_queue(),^{self->_working=NO;
            if(!self->_expired&&!self->_finished){self->_ready=status==MNG_TOTK_SAVE_OK;self->_originalWallet=parsed.wallet;self->_wallet=parsed.wallet;
                self->_status=self->_ready?@"Reference-family tuple matched. This does not validate a game save.":@"The selected snapshot does not satisfy the reference-family candidate checks. No candidate can be shared.";}
            [self update];});
    }});
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (BOOL)visible {return self.viewIfLoaded.window&&UIApplication.sharedApplication.applicationState==UIApplicationStateActive;}
- (BOOL)allowed {return [self visible]&&_ready&&!_working&&!_expired&&!_finished&&!self.presentedViewController;}
- (void)update {self.navigationItem.leftBarButtonItem.enabled=!_working&&!_share;[self.tableView reloadData];}
- (void)foreground:(NSNotification *)notification {(void)notification;[self update];}
- (void)background:(NSNotification *)notification {
    (void)notification;_expired=YES;_ready=NO;_status=@"This preview expired in the background. Close and reopen the candidate sheet for a new snapshot.";
    _share=nil;if(self.presentedViewController)[self dismissViewControllerAnimated:NO completion:nil];[self update];
}
- (void)close {
    if(_working||_share||_finished)return;_finished=YES;
    void (^closed)(void)=_closed;_closed=nil;_refresh=nil;
    [self.navigationController dismissViewControllerAnimated:YES completion:^{if(closed)closed();}];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {(void)tableView;return 2;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {(void)tableView;return section?1:2;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {(void)tableView;return section?@"No active Apply":@"Rupees — reference editor policy";}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {(void)tableView;return section?CandidateWarning:(_status?:@"Reading private snapshot…");}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    BOOL enabled=_ready&&!_working&&!_expired&&!_finished;
    if(path.section){cell.textLabel.text=@"Share UNVERIFIED raw candidate…";}
    else if(!path.row){cell.textLabel.text=@"Snapshot wallet";cell.detailTextLabel.text=_ready?[NSString stringWithFormat:@"%u",_originalWallet]:@"Unverified";enabled=NO;}
    else{cell.textLabel.text=@"Candidate wallet";cell.detailTextLabel.text=_ready?[NSString stringWithFormat:@"%u",_wallet]:@"Unavailable";cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}
    cell.textLabel.numberOfLines=0;cell.textLabel.enabled=enabled;cell.selectionStyle=enabled?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];if(![self allowed])return;
    if(path.section)[self confirmShare];else if(path.row)[self chooseValue];
}
- (void)chooseValue {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Candidate rupees" message:@"Whole numbers 0–999,999 only. This is the reference editor's UI policy, not a certified game-format limit." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.keyboardType=UIKeyboardTypeNumberPad;field.text=[NSString stringWithFormat:@"%u",self->_wallet];field.accessibilityLabel=@"Unverified candidate rupees";}];
    __weak UIAlertController *weakAlert=alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Preview value" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        (void)action;if(self->_expired||self->_finished||self->_working||![self visible])return;
        NSString *text=weakAlert.textFields.firstObject.text?:@"";BOOL ok=text.length>0&&text.length<=6;uint32_t value=0;
        for(NSUInteger i=0;ok&&i<text.length;i++){unichar c=[text characterAtIndex:i];if(c<'0'||c>'9')ok=NO;else value=value*10+(uint32_t)(c-'0');}
        if(ok&&value<=MNG_TOTK_SAVE_REFERENCE_POLICY_MAX){self->_wallet=value;self->_status=@"Candidate value selected. No active save was changed.";}
        else self->_status=@"Enter only a whole number 0–999,999. The prior value was retained.";
        [self update];
    }]];[self presentViewController:alert animated:YES completion:nil];
}
- (void)confirmShare {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Share an UNVERIFIED candidate?" message:CandidateWarning preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Share raw bytes" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        (void)action;[self dismissViewControllerAnimated:YES completion:^{if([self allowed])[self makeCandidate];}];
    }]];[self presentViewController:alert animated:YES completion:nil];
}
- (void)makeCandidate {
    if(![self allowed])return;_working=YES;[self update];uint32_t wallet=_wallet;TOTKCandidateRefresh refresh=_refresh;
    dispatch_async(_queue,^{@autoreleasepool{
        NSData *fresh=refresh?refresh(NULL):nil;BOOL unchanged=[fresh isEqual:self->_source];
        NSMutableData *candidate=unchanged?[NSMutableData dataWithLength:MNG_TOTK_SAVE_REFERENCE_SIZE]:nil;
        enum mng_totk_save_status status=candidate?mng_totk_save_candidate(fresh.bytes,fresh.length,wallet,candidate.mutableBytes,candidate.length):MNG_TOTK_SAVE_INVALID;
        NSData *bytes=status==MNG_TOTK_SAVE_OK?[candidate copy]:nil;
        dispatch_async(dispatch_get_main_queue(),^{self->_working=NO;
            if(self->_expired||self->_finished||![self visible]){[self update];return;}
            if(!bytes){self->_ready=NO;self->_status=@"The snapshot changed or could not be checked. Close and reopen before sharing.";[self update];return;}
            [self share:bytes];
        });
    }});
}
- (void)share:(NSData *)bytes {
    if(![self allowed])return;
    NSItemProvider *provider=[NSItemProvider new];provider.suggestedName=@"UNVERIFIED-TOTK-1.4x-rupee-candidate.bin";
    [provider registerDataRepresentationForTypeIdentifier:@"public.data" visibility:NSItemProviderRepresentationVisibilityAll loadHandler:^NSProgress * _Nullable(void (^completion)(NSData * _Nullable,NSError * _Nullable)){completion(bytes,nil);return nil;}];
    UIActivityItemsConfiguration *items=[[UIActivityItemsConfiguration alloc] initWithItemProviders:@[provider]];
    items.metadataProvider=^id _Nullable(UIActivityItemsConfigurationMetadataKey key){return [key isEqual:UIActivityItemsConfigurationMetadataKeyTitle]?@"UNVERIFIED raw TOTK candidate":nil;};
    UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItemsConfiguration:items];_share=share;
    __weak TOTKSaveCandidate *owner=self;__weak UIActivityViewController *weakShare=share;
    share.completionWithItemsHandler=^(UIActivityType type,BOOL completed,NSArray *objects,NSError *error){
        (void)type;(void)completed;(void)objects;(void)error;
        dispatch_async(dispatch_get_main_queue(),^{TOTKSaveCandidate *current=owner;UIActivityViewController *finished=weakShare;
            if(!current||!finished||current->_share!=finished)return;current->_share=nil;[current update];});
    };
    share.popoverPresentationController.sourceView=self.tableView;
    share.popoverPresentationController.sourceRect=[self.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1]];
    [self update];[self presentViewController:share animated:YES completion:nil];
}
@end
