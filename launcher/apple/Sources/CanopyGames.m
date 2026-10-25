#import "CanopyGames.h"
#import "CanopyCatalog.h"
#import "CanopySettings.h"
#import "CanopyPreparation.h"
#import "CanopyControllers.h"
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

@interface CanopyMappingController : UITableViewController
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
    return @"Saved for this title only. Default retains the runtime layout; other choices map a held physical button. Runtime application requires a supported session and remains unverified here.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    NSError *error = nil; NSDictionary *values = [_settings settingsForTitleID:_titleID error:&error];
    NSString *button = MappingButtons()[(NSUInteger)path.row];
    UITableViewCell *cell = GamesCell(tableView, button, values ? (values[@"buttonMappings"][button] ?: @"default") : @"Metadata recovery required");
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
        [self.tableView reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    GamesAnchor(sheet,tableView,path); [self presentViewController:sheet animated:YES completion:nil];
}
@end

@interface CanopyGameDetails : UITableViewController
- (instancetype)initWithEntry:(NSDictionary *)entry settings:(CanopySettings *)settings;
@end
@implementation CanopyGameDetails {
    NSDictionary *_entry;
    CanopySettings *_settings;
}
- (instancetype)initWithEntry:(NSDictionary *)entry settings:(CanopySettings *)settings {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _entry = [entry copy]; _settings = settings; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = _entry[@"displayName"];
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 70;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Rename" style:UIBarButtonItemStylePlain target:self action:@selector(rename)];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section == 0 ? 6 : section == 1 ? 6 : section == 2 ? 5 : 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return @[@"Prepared assets",@"Graphics preferences",@"Control preferences",@"Language"][(NSUInteger)section]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"Preparation integrity is distinct from Nintendo signature authenticity and native execution. Gameplay is unavailable; this screen does not start a session.";
    return @"These preferences persist for this title. Applying them to a running game is not verified in this build. A supported runtime/device must establish each setting's capabilities and live or next-start behavior.";
}
- (NSArray *)keysForSection:(NSInteger)section {
    if (section == 1) return @[@"fpsLimit",@"renderHeight",@"aspect",@"hud",@"metalHUD",@"taa"];
    if (section == 2) return @[@"touch",@"controllerType",@"mouseSensitivity",@"mouseInvertY",@"buttonMappings"];
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
    NSArray *titles = path.section == 1 ? @[@"Target frame rate",@"Render height",@"Aspect ratio",@"Performance overlay",@"Apple Metal HUD",@"Temporal anti-aliasing"] : path.section == 2 ? @[@"Touch controls",@"Controller layout",@"Mouse sensitivity",@"Invert mouse Y",@"Button mappings"] : @[@"Language"];
    NSString *key = [self keysForSection:path.section][(NSUInteger)path.row];
    NSError *error = nil; NSDictionary *values = [_settings settingsForTitleID:_entry[@"titleID"] error:&error];
    id value = values[key];
    NSString *detail = values ? [value description] : @"Metadata recovery required";
    if ([key isEqual:@"hud"] && values) detail = @[@"Off",@"Full",@"FPS only"][[value unsignedIntegerValue]];
    if ([key isEqual:@"language"] && [value isEqual:@""]) detail = @"System";
    if ([key isEqual:@"buttonMappings"] && values) detail = @"Per-game controller and mouse buttons";
    UITableViewCell *cell = GamesCell(tableView,titles[(NSUInteger)path.row],detail);
    if (values && [@[@"touch",@"mouseInvertY",@"metalHUD",@"taa"] containsObject:key]) {
        UISwitch *toggle = [UISwitch new]; toggle.on = [value boolValue]; toggle.accessibilityIdentifier = key;
        toggle.accessibilityLabel = titles[(NSUInteger)path.row];
        toggle.accessibilityHint = @"Saves this preference for this game. Runtime application is unverified.";
        [toggle addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle; cell.detailTextLabel.text = @"Saved for a supported session"; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (values) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)toggle:(UISwitch *)toggle {
    NSError *error = nil;
    if (![_settings setValue:@(toggle.on) forSetting:toggle.accessibilityIdentifier titleID:_entry[@"titleID"] error:&error]) GamesAlert(self,@"Could not save preference",error.localizedDescription);
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
    NSError *error = nil; NSDictionary *values = [_settings settingsForTitleID:_entry[@"titleID"] error:&error];
    if (!values) { GamesAlert(self,@"Settings unavailable",error.localizedDescription); return; }
    NSString *key = [self keysForSection:path.section][(NSUInteger)path.row];
    if ([@[@"touch",@"mouseInvertY",@"metalHUD",@"taa"] containsObject:key]) return;
    if ([key isEqual:@"buttonMappings"]) {
        [self.navigationController pushViewController:[[CanopyMappingController alloc] initWithSettings:_settings titleID:_entry[@"titleID"]] animated:YES]; return;
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
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    GamesAnchor(sheet,tableView,path); [self presentViewController:sheet animated:YES completion:nil];
}
@end

@interface CanopyPlayersController : UITableViewController
- (instancetype)initWithControllers:(CanopyControllers *)controllers;
@end
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
    NSURL *_preparedRoot, *_metadataRoot, *_pendingSource;
    CanopySettings *_settings;
    CanopyPreparation *_preparation;
    CanopyControllers *_controllers;
    NSArray *_entries, *_issues;
    NSString *_status, *_metadataError, *_progressText;
    BOOL _refreshing, _cancelRequested;
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
    if (_settings) [self refreshUI];
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
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section == 0 ? MAX((NSInteger)_entries.count,1) : 5; }
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
    NSArray *titles = @[@"Prepare game",@"Players & controllers",@"Inspection history",@"Verify library",@"Reset title metadata"];
    NSArray *details = @[@"Select a user-owned NSP/XCI, then your local key file",@"Assign connected controllers to four independent seats",@"Read-only container metadata from the earlier inspector",@"Rehash prepared assets and reload current generations",@"Explicit recovery for display names and preferences only"];
    UITableViewCell *cell = GamesCell(tableView,titles[(NSUInteger)path.row],details[(NSUInteger)path.row]);
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if ([self working]) { cell.textLabel.textColor = UIColor.secondaryLabelColor; cell.selectionStyle = UITableViewCellSelectionStyleNone; }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES]; if ([self working]) return;
    if (!path.section) { if (_entries.count) [self.navigationController pushViewController:[[CanopyGameDetails alloc] initWithEntry:_entries[(NSUInteger)path.row] settings:_settings] animated:YES]; return; }
    if (path.row == 0) [self chooseSource];
    else if (path.row == 1) [self.navigationController pushViewController:[[CanopyPlayersController alloc] initWithControllers:_controllers] animated:YES];
    else if (path.row == 2) [self.navigationController pushViewController:CanopyMakeInspectionHistoryController() animated:YES];
    else if (path.row == 3) [self reloadCatalog];
    else [self resetMetadata];
}
- (void)chooseSource {
    if ([self working] || self.presentedViewController) return;
    _pickerStage = 1; [self refreshUI];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:NO];
    picker.allowsMultipleSelection = NO; picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)chooseKeys {
    if (!_pendingSource) { _pickerStage = 0; [self refreshUI]; return; }
    _pickerStage = 2;
    UIAlertController *explanation = [UIAlertController alertControllerWithTitle:@"Choose your local key file"
        message:@"Keys are used in memory for this preparation job. Canopy does not retain the selected key file, its path or bookmarks. Use only your own local inputs."
        preferredStyle:UIAlertControllerStyleAlert];
    [explanation addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { (void)action; self->_pendingSource = nil; self->_pickerStage = 0; [self refreshUI]; }]];
    [explanation addAction:[UIAlertAction actionWithTitle:@"Choose file" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        if (self->_pickerStage != 2 || !self->_pendingSource) return;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:NO];
        picker.allowsMultipleSelection = NO; picker.delegate = self;
        [self dismissViewControllerAnimated:YES completion:^{ [self presentViewController:picker animated:YES completion:nil]; }];
    }]];
    [self presentViewController:explanation animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller; _pendingSource = nil; _pickerStage = 0; [self refreshUI];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count != 1) { _pendingSource = nil; _pickerStage = 0; [self refreshUI]; return; }
    NSURL *url = urls.firstObject;
    if (_pickerStage == 1) {
        if (![@[@"nsp",@"xci"] containsObject:url.pathExtension.lowercaseString]) {
            _pickerStage = 0; [self refreshUI]; GamesAlert(self,@"Unsupported preparation input",@"Choose an NSP or XCI container. Folder preparation and unsupported NCA layouts are separate work."); return;
        }
        _pendingSource = url;
        [controller dismissViewControllerAnimated:YES completion:^{ [self chooseKeys]; }];
    } else if (_pickerStage == 2 && _pendingSource) {
        NSURL *source = _pendingSource; _pendingSource = nil; _pickerStage = 3;
        [controller dismissViewControllerAnimated:YES completion:^{ [self startSource:source keys:url]; }];
    }
}
- (void)startSource:(NSURL *)source keys:(NSURL *)keys {
    if (_pickerStage != 3) return;
    _pickerStage = 0;
    if (_preparation.busy || _refreshing) { _status = @"Another library operation is still running. Select your files again after it completes."; [self refreshUI]; return; }
    _cancelRequested = NO; _progressText = nil; _status = nil;
    BOOL accepted = [_preparation startSourceURL:source keysURL:keys jobIdentifier:nil completion:^(NSDictionary *result, NSError *error) {
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
        _pickerStage = 0; _pendingSource = nil;
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
