#import "CanopyDiagnosticsController.h"

// A user-initiated share exports only bounded backend JSON. No temporary file,
// filesystem URL or original provider/error object is passed to an activity.
@interface CDShareItem : NSObject<UIActivityItemSource>
@property(nonatomic,copy)NSData *data;
@end
@implementation CDShareItem
- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)controller {(void)controller;return self.data;}
- (id)activityViewController:(UIActivityViewController *)controller itemForActivityType:(UIActivityType)type {(void)controller;(void)type;return self.data;}
- (NSString *)activityViewController:(UIActivityViewController *)controller dataTypeIdentifierForActivityType:(UIActivityType)type {(void)controller;(void)type;return @"public.json";}
- (NSString *)activityViewController:(UIActivityViewController *)controller subjectForActivityType:(UIActivityType)type {(void)controller;(void)type;return @"Canopy diagnostic snapshot";}
@end
static NSString *CDValue(id value) {return !value||value==NSNull.null?@"Unavailable":[value description];}
static NSString *CDBytes(id value) {return [value isKindOfClass:NSNumber.class]?[NSByteCountFormatter stringFromByteCount:[value longLongValue] countStyle:NSByteCountFormatterCountStyleMemory]:@"Unavailable";}
@implementation CanopyDiagnosticsController {
    CanopyDiagnostics *_diagnostics;
    CanopyDiagnosticsSources *_sources;
    NSDictionary *_snapshot;
    NSString *_notice;
}
- (instancetype)initWithDiagnostics:(CanopyDiagnostics *)diagnostics sources:(CanopyDiagnosticsSources *)sources {
    if((self=[super initWithStyle:UITableViewStyleInsetGrouped])){_diagnostics=diagnostics;_sources=sources;_snapshot=@{};_notice=@"";}return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"Diagnostics";self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=70;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Refresh" style:UIBarButtonItemStylePlain target:self action:@selector(refreshSnapshot)];
    // Opening this user-selected screen requests a snapshot but does not opt in
    // or add a historical sample. Refresh is a separate explicit observation.
    _snapshot=[_sources snapshotWithDiagnostics:_diagnostics recordIfEnabled:NO];
}
- (void)refreshSnapshot {
    _snapshot=[_sources snapshotWithDiagnostics:_diagnostics recordIfEnabled:YES];_notice=@"Snapshot refreshed.";[self.tableView reloadData];
}
- (void)toggleCollection:(UISwitch *)sender {
    _diagnostics.enabled=sender.on;
    _snapshot=[_sources snapshotWithDiagnostics:_diagnostics recordIfEnabled:NO];
    _notice=sender.on?@"Collection enabled for actual host events and explicit Refresh requests.":@"Collection disabled. Recorded history cleared.";
    [self.tableView reloadData];
}
- (NSArray<NSArray<NSString *> *> *)rows:(NSInteger)section {
    NSDictionary *sample=_snapshot[@"sample"]?:@{},*memory=sample[@"memory"]?:@{},*thermal=sample[@"thermal"]?:@{},
        *session=sample[@"session"]?:@{},*prepared=sample[@"preparation"]?:@{},*metrics=sample[@"metrics"]?:@{};
    if(section==0)return @[@[@"Collect diagnostic samples",_diagnostics.enabled?@"On":@"Off"],@[@"Share redacted JSON",@"Explicit export; no file is written by Canopy"]];
    if(section==1)return @[@[@"Observed phase",CDValue(session[@"phase"])],@[@"Error category",CDValue(session[@"errorCode"])],
        @[@"Whole-process resident memory",CDBytes(memory[@"residentBytes"])],@[@"Whole-process physical footprint",CDBytes(memory[@"physicalFootprintBytes"])],
        @[@"System thermal state",CDValue(thermal[@"state"])],@[@"Measured gameplay FPS",@"Unavailable — no trusted frame counter connected"],
        @[@"Configured frame ceiling",CDValue(sample[@"configuration"][@"frameLimit"])]];
    if(section==2) {
        NSMutableArray *rows=[NSMutableArray new];
        for(NSString *key in @[@"titleID",@"generationID",@"recipeID",@"sourceKind",@"sourceSHA256",@"updateSourceSHA256",@"memberInventorySHA256",@"titleVersion",@"versionIdentified",@"assetCount"])
            if(prepared[key])[rows addObject:@[key,CDValue(prepared[key])]];
        if(prepared[@"assetBytes"])[rows addObject:@[@"Verified prepared asset bytes",CDBytes(prepared[@"assetBytes"])]];
        if(prepared[@"integrity"])[rows addObject:@[@"Observed integrity flags",CDValue(prepared[@"integrity"])]];
        return rows.count?rows:@[@[@"No prepared-result observation",@"No source or version was inferred"]];
    }
    if(section==3) {
        NSMutableArray *rows=[NSMutableArray new];
        NSArray *keys=@[@"seedCopiedBytes",@"seedReusedBytes",@"metadataWrittenBytes",@"seedBytes",@"runtimeBytes",@"clearedBytes",@"seedFiles",@"cacheReused",@"filesAndDirectories",@"phaseDone",@"phaseTotal",@"phaseUnit",
            @"storageListingComplete",@"storageListedGenerations",@"storageVerifiedGenerations",@"storageVerifiedAssetBytes",@"storageListedJobs",
            @"storageListedShaders",@"storageAvailableShaders",@"storageAvailableSeedBytes",@"storageAvailableRuntimeBytes"];
        for(NSString *key in keys)if(metrics[key])[rows addObject:@[key,[key hasSuffix:@"Bytes"]?CDBytes(metrics[key]):CDValue(metrics[key])]];
        NSArray *providerRows=@[@[@"storageListedProviderCaches",@"Listed provider caches"],
            @[@"storageKnownActiveProviderCaches",@"Known active listed provider caches"],
            @[@"storageInactiveProviderCachesWithKnownUsage",@"Inactive provider caches with known usage"],
            @[@"storageUnverifiedInactiveProviderLogicalBytes",@"UNVERIFIED inactive provider logical bytes (known subset)"]];
        for(NSArray *row in providerRows)if(metrics[row[0]])[rows addObject:@[row[1],[row[0] hasSuffix:@"Bytes"]?CDBytes(metrics[row[0]]):CDValue(metrics[row[0]])]];
        if(metrics[@"storageListedProviderCaches"] && !metrics[@"storageUnverifiedInactiveProviderLogicalBytes"])
            [rows addObject:@[@"UNVERIFIED inactive provider logical bytes",@"Unavailable — no known inactive usage; active and unknown sizes are omitted"]];
        NSDictionary *io=metrics[@"preparationIO"];
        for(NSString *key in @[@"streamedBytes",@"writtenBytes",@"clonedLogicalBytes",@"comparedEqualBytes",@"resumedBytes",@"clonedAssets",@"cloneFallbackAssets"])
            if(io[key])[rows addObject:@[[NSString stringWithFormat:@"Preparation · %@",key],[key hasSuffix:@"Bytes"]?CDBytes(io[key]):CDValue(io[key])]];
        if(metrics[@"preparationPublished"])[rows addObject:@[@"Preparation reported publication",CDValue(metrics[@"preparationPublished"])]];
        if(metrics[@"preparationPublicationMayHaveCompleted"])[rows addObject:@[@"Publication may have completed",CDValue(metrics[@"preparationPublicationMayHaveCompleted"])]];
        return rows.count?rows:@[@[@"No observed counters",@"Unavailable values are not estimated"]];
    }
    NSArray *history=_snapshot[@"recordedSamples"]?:@[];NSMutableArray *rows=[NSMutableArray new];
    for(NSUInteger i=0;i<history.count;i++) {
        NSDictionary *old=history[i];[rows addObject:@[[NSString stringWithFormat:@"Sample %lu",(unsigned long)(i+1)],
            [NSString stringWithFormat:@"%@ • RSS %@ • thermal %@",CDValue(old[@"session"][@"phase"]),CDBytes(old[@"memory"][@"residentBytes"]),CDValue(old[@"thermal"][@"state"])]]];
    }
    return rows.count?rows:@[@[@"No recorded samples",@"Collection defaults off; explicit snapshots still work"]];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {(void)tableView;return 5;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {(void)tableView;return (NSInteger)[self rows:section].count;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;return @[@"User controls",@"Process and session",@"Prepared result",@"Observed logical counters",@"Capped local history"][(NSUInteger)section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if(section==0)return [_notice stringByAppendingString:@"\nCollection is opt-in and stores at most 16 redacted samples in memory. Disable clears history. No automatic upload or timer."];
    if(section==1)return @"Memory covers this entire process, not guest-only or GPU memory. A frame ceiling is desired configuration, not measured throughput. Presentation is not gameplay evidence.";
    if(section==2)return @"Hashes and integrity do not establish execution, compatibility or signature authenticity. Folder inventories are not physical container hashes.";
    if(section==3)return @"Storage counters cover listed rows only. Verified generation bytes and available shader bytes are logical file lengths, not total disk use or promised reclaimed space. Preparation counters cover the actual attempt, including failures; old-snapshot clone lengths are not physical space savings or retained target bytes. Counters do not prove publication. Provider-cache byte totals are an UNVERIFIED known inactive subset; active, missing and unsafe sizes remain unavailable. They establish neither content correctness nor physical allocation or reclaimable space. Progress units are preserved.";
    return @"Oldest samples are discarded at 16. Refresh obtains a new observation; history is not a time series or a frame-rate measurement.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"diagnostic"];
    if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"diagnostic"];
    NSArray *row=[self rows:path.section][(NSUInteger)path.row];cell.textLabel.text=row[0];cell.detailTextLabel.text=row[1];
    cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;
    cell.accessoryView=nil;cell.accessoryType=UITableViewCellAccessoryNone;cell.selectionStyle=UITableViewCellSelectionStyleNone;
    if(path.section==0&&path.row==0){UISwitch *toggle=[UISwitch new];toggle.on=_diagnostics.enabled;toggle.accessibilityLabel=@"Collect diagnostic samples";
        [toggle addTarget:self action:@selector(toggleCollection:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;}
    else if(path.section==0&&path.row==1){cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;cell.selectionStyle=UITableViewCellSelectionStyleDefault;}
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];if(path.section!=0||path.row!=1)return;
    NSError *error=nil;NSData *data=[_sources redactedJSONWithDiagnostics:_diagnostics error:&error];
    if(!data){_notice=@"The redacted export could not be produced within its size limit.";[tableView reloadData];return;}
    CDShareItem *item=[CDShareItem new];item.data=data;
    UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[item] applicationActivities:nil];
    share.popoverPresentationController.sourceView=tableView;share.popoverPresentationController.sourceRect=[tableView rectForRowAtIndexPath:path];
    [self presentViewController:share animated:YES completion:nil];
}
@end
CanopyDiagnosticsController *CanopyMakeDiagnosticsController(CanopyDiagnostics *diagnostics,CanopyDiagnosticsSources *sources) {
    return [[CanopyDiagnosticsController alloc] initWithDiagnostics:diagnostics sources:sources];
}
