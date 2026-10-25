#import "launcher.h"
#import "launcher_settings.h"
#import "resolution_settings.h"
#import "menu_style.h"
#import "settings_choices.h"
#import "save_editor.h"
#import "keyboard_input.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <GameController/GameController.h>
#include <math.h>
#include <stdlib.h>
#include "../../runtime/runtime.h"

static NSString *control_button_title(NSString *button) {
    return @{@"south":@"South face button",@"east":@"East face button",@"west":@"West face button",@"north":@"North face button",
        @"l3":@"Left stick press",@"r3":@"Right stick press",@"l1":@"Left shoulder",@"r1":@"Right shoulder",
        @"l2":@"Left trigger",@"r2":@"Right trigger",@"menu":@"Menu",@"view":@"View / Options",
        @"left":@"D-pad left",@"up":@"D-pad up",@"right":@"D-pad right",@"down":@"D-pad down",@"touchpad":@"Touchpad click",
        @"mouse_left":@"Mouse left",@"mouse_right":@"Mouse right",@"mouse_middle":@"Mouse middle",
        @"mouse4":@"Mouse extra 1",@"mouse5":@"Mouse extra 2"}[button] ?: button;
}

static NSDictionary *startup_preferences(NSUserDefaults *defaults) {
    NSMutableDictionary *bindings = [NSMutableDictionary dictionary];
    for (NSString *button in TOTKLauncherControlButtons()) bindings[button] = TOTKLauncherControlBinding(defaults,button);
    return @{@"graphics":TOTKLauncherGraphicsPreferences(defaults),
        @"controller":TOTKLauncherControllerType(defaults),
        @"sensitivity":@(TOTKLauncherMouseSensitivity(defaults)), @"invert":@(TOTKLauncherMouseInvertY(defaults)),
        @"bindings":[bindings copy], @"language":TOTKLauncherLanguage(defaults)};
}

static void setting_timing_hint(UITableViewCell *cell, BOOL live, BOOL pending) {
    cell.accessibilityHint = live ? @"Applies immediately to the active game." : pending
        ? @"Restart required. This saved value differs from the current session."
        : @"Changes require an app restart. The current session keeps its settings.";
}

static void show_restart_required(UIViewController *controller) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restart required"
        message:@"This setting applies after an app restart. Save your progress in the game first. Then close this app from the App Switcher and reopen it."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep playing" style:UIAlertActionStyleDefault handler:nil]];
    if (controller.presentedViewController) {
        [controller dismissViewControllerAnimated:YES completion:^{ [controller presentViewController:alert animated:YES completion:nil]; }];
    } else [controller presentViewController:alert animated:YES completion:nil];
}

@interface TOTKButtonMappings : UITableViewController
@property(nonatomic) BOOL editingNextLaunch;
@property(nonatomic,copy) NSDictionary<NSString *,NSString *> *runningBindings;
@property(nonatomic,copy) void (^changed)(void);
@end
@implementation TOTKButtonMappings
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = @"Button mappings";
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    TOTKStyleSettingsPage(self);
    self.tableView.allowsFocus = YES;
    self.tableView.remembersLastFocusedIndexPath = YES;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; return section == 0 ? 17 : 5;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; return section == 0 ? @"Controller" : @"Mouse";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (self.editingNextLaunch) return @"Button mappings require an app restart. Save game progress before you close the app from the App Switcher and reopen it.";
    return section == 0 ? @"Choose a Switch button or None. Custom mappings hold while pressed. Default restores the standard mapping. Applies at the next game start."
        : @"Default right click draws the bow; left click shoots while aiming. Extra buttons require a mouse that exposes them to iPadOS. Touch controls keep their standard layout.";
}
- (NSString *)buttonAtPath:(NSIndexPath *)path { return TOTKLauncherControlButtons()[path.section == 0 ? path.row : 17 + path.row]; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSString *button = [self buttonAtPath:path];
    cell.textLabel.text = control_button_title(button);
    TOTKStyleSettingsCell(cell,[button hasPrefix:@"mouse"] ? @"computermouse" : @"gamecontroller");
    cell.detailTextLabel.text = TOTKLauncherControlBindingTitle(NSUserDefaults.standardUserDefaults,button);
    cell.accessibilityLabel = cell.textLabel.text;
    cell.accessibilityValue = cell.detailTextLabel.text;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (self.editingNextLaunch) setting_timing_hint(cell,NO,![TOTKLauncherControlBinding(NSUserDefaults.standardUserDefaults,button) isEqual:self.runningBindings[button]]);
    else cell.accessibilityHint = @"Applies when you press Play.";
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (!self.editingNextLaunch && getenv("TOTK_CONTROLS")) return;
    NSString *button = [self buttonAtPath:path];
    NSArray *targets=TOTKLauncherControlTargets();
    NSMutableArray *titles=[NSMutableArray array];
    for (NSString *target in targets) [titles addObject:[target isEqual:@"default"] ? @"Default" : [target isEqual:@"none"] ? @"None" : target.uppercaseString];
    NSUInteger current=[targets indexOfObject:TOTKLauncherControlBinding(NSUserDefaults.standardUserDefaults,button)];
    TOTKChooseSetting(self,control_button_title(button),titles,current<titles.count ? titles[current] : nil,nil,^(NSUInteger index) {
        NSString *target=targets[index];
        NSString *previous=TOTKLauncherControlBinding(NSUserDefaults.standardUserDefaults,button);
        [NSUserDefaults.standardUserDefaults setObject:target forKey:[@"TOTK_LAUNCHER_BIND_" stringByAppendingString:button]];
        [self.tableView reloadData];
        if (![previous isEqual:target]) {
            if (self.changed) self.changed();
            if (self.editingNextLaunch && ![target isEqual:self.runningBindings[button]]) show_restart_required(self);
        }
    });
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

@interface TOTKKeyboardMappings : UITableViewController
@end
@implementation TOTKKeyboardMappings
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = @"Keyboard mappings";
    return self;
}
- (void)viewDidLoad { [super viewDidLoad]; TOTKStyleSettingsPage(self); }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return TOTKKeyboardActions().count; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return @"Changes apply live to the next key press. Each key has one action. Choose None to free a key. Escape opens the game menu. Command shortcuts stay with iPadOS.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = TOTKKeyboardActions()[path.row];
    TOTKStyleSettingsCell(cell,@"keyboard");
    cell.detailTextLabel.text = TOTKKeyboardKeyTitle(TOTKKeyboardBinding(NSUserDefaults.standardUserDefaults,path.row));
    cell.accessibilityLabel = cell.textLabel.text;
    cell.accessibilityValue = cell.detailTextLabel.text;
    setting_timing_hint(cell,YES,NO);
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    TOTKClearKeyboardInput();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray<NSNumber *> *keys=TOTKKeyboardSupportedKeys();
    NSMutableArray *titles=[NSMutableArray array];
    NSMutableIndexSet *disabled=[NSMutableIndexSet indexSet];
    for (NSUInteger index=0;index<keys.count;index++) {
        unsigned key=keys[index].unsignedIntValue;
        [titles addObject:TOTKKeyboardKeyTitle(key)];
        for (NSUInteger i=0;key && i<TOTKKeyboardActions().count;i++)
            if (i!=(NSUInteger)path.row && TOTKKeyboardBinding(defaults,i)==key) [disabled addIndex:index];
    }
    TOTKChooseSetting(self,TOTKKeyboardActions()[path.row],titles,TOTKKeyboardKeyTitle(TOTKKeyboardBinding(defaults,path.row)),disabled,^(NSUInteger index) {
        if (TOTKKeyboardSetBinding(defaults,path.row,keys[index].unsignedIntValue)) [self.tableView reloadData];
    });
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

static BOOL valid_mouse_sensitivity(NSString *text) {
    return text.length > 0 && text.length <= 3 &&
        [text rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location == NSNotFound &&
        text.integerValue >= 1 && text.integerValue <= 100;
}

@interface TOTKLauncher () <UIDocumentPickerDelegate, UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UITableView *tableView;
@end
@implementation TOTKLauncher {
    TOTKSaveStore *_store;
    NSString *_unavailable;
    void (^_play)(void);
    BOOL _busy, _started, _inGame, _touchOffConfirmed;
    void (^_HUDChanged)(void);
    NSURL *_exportDirectory;
    NSDictionary *_runningPreferences;
}
- (instancetype)initWithStore:(TOTKSaveStore *)store unavailable:(NSString *)reason play:(void (^)(void))play {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _store = store; _unavailable = reason; _play = [play copy]; self.title = @"Tears of the Kingdom";
    }
    return self;
}
- (instancetype)initForGameWithResume:(void (^)(void))resume HUDChanged:(void (^)(void))HUDChanged {
    if ((self = [self initWithStore:nil unavailable:nil play:resume])) {
        _inGame = YES;
        _HUDChanged = [HUDChanged copy];
        _runningPreferences = startup_preferences(NSUserDefaults.standardUserDefaults);
        self.title = @"Settings";
    }
    return self;
}
- (void)resumeGame { if (_inGame && _play) _play(); }
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
    [self refreshRestartFooter];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self; self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 56;
    self.tableView.cellLayoutMarginsFollowReadableWidth = YES; self.tableView.sectionHeaderTopPadding = 12;
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    self.tableView.allowsFocus = YES; self.tableView.remembersLastFocusedIndexPath = YES;
    [self refreshRestartFooter];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 5; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; return (NSInteger[]){1,6,6,5,1}[section];
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; return @[@"",@"Graphics",@"Controls",@"Saves",@"Language"][section];
}
- (BOOL)fullDisplayAvailable {
    id capability = NSBundle.mainBundle.infoDictionary[@"TOTKIOSFourThreeLayoutVersion"];
    if (![capability isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)capability) == CFBooleanGetTypeID() ||
        [capability doubleValue] != 1) return NO;
    CGSize size = self.view.window ? self.view.window.bounds.size : self.view.bounds.size;
    double shortSide = MIN(size.width,size.height), longSide = MAX(size.width,size.height);
    return shortSide > 0 && fabs(longSide / shortSide - 4.0 / 3.0) <= 0.001;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return _inGame ? @"Adjust graphics and controls. The game stays active while this menu is open." : (_unavailable ?: @"Choose settings and manage saves before Play. Use the game menu to return to settings during play.");
    if (section == 1) return _inGame ? @"Frame rate, anti-aliasing and HUDs apply live. Resolution changes apply after restart." : @"Choose your picture size, performance target and overlays.";
    if (_inGame && section == 2) return @"Touch visibility and keyboard mappings apply live. Other control changes apply after an app restart.";
    if (_inGame && section == 3) return @"Save transfers, backups and restores are available before Play only. Reopen the app to manage saves safely.";
    if (_inGame && section == 4) return @"Language changes require an app restart.";
    if (section == 2) return @"Automatic hides touch buttons with a controller. Off keeps the bottom-left menu button available for keyboard or controller use.";
    if (section == 3) return @"Select a folder containing complete slot_00–slot_05 saves. Imports and restores create a backup first.";
    return @"Language follows the existing Settings app preference. Changes apply when you press Play.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.backgroundColor = [UIColor.secondarySystemGroupedBackgroundColor colorWithAlphaComponent:0.65];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSArray *titles = @[@[@"Play"],@[@"Resolution & scaling",@"Performance overlay",@"Apple Metal HUD",@"Target frame rate",@"Anti-aliasing (TAA)",@"Shader compilation indicator"],@[@"Touch controls",@"Controller type",@"Mouse sensitivity",@"Invert mouse Y",@"Button mappings",@"Keyboard mappings"],
        @[@"Import save folder",@"Export save folder",@"Back up save",@"Restore backup",@"Edit this save"],@[@"Game language"]];
    cell.textLabel.text = _inGame && path.section == 0 ? @"Resume game" : titles[path.section][path.row];
    NSArray *symbols = @[@[@"play.fill"],@[@"arrow.up.left.and.arrow.down.right",@"gauge.with.dots.needle.50percent",@"chart.xyaxis.line",@"speedometer",@"sparkles",@"cpu"],
        @[@"hand.tap",@"gamecontroller",@"computermouse",@"arrow.up.arrow.down",@"button.programmable",@"keyboard"],
        @[@"square.and.arrow.down",@"square.and.arrow.up",@"externaldrive.badge.plus",@"clock.arrow.circlepath",@"pencil"],@[@"globe"]];
    TOTKStyleSettingsCell(cell,symbols[path.section][path.row]);
    if (path.section == 0) {
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        cell.textLabel.textColor = UIColor.systemBlueColor;
        cell.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.12];
    }
    BOOL displaySettings = TOTKLauncherDisplaySettingsAvailable(NSBundle.mainBundle.infoDictionary);
    if (path.section == 1) {
        if (path.row == 0) { cell.detailTextLabel.text = @"Configure"; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
        else if (path.row == 1) cell.detailTextLabel.text = @{@0:@"Off",@1:@"Full",@2:@"FPS only"}[@(TOTKLauncherHUD(d))];
        else if (path.row == 2) cell.detailTextLabel.text = TOTKLauncherMetalHUD(d) ? @"On" : @"Off";
        else if (path.row == 3) {
            unsigned rate = _inGame ? runtime_ios_fps_limit() : (unsigned)TOTKLauncherFPSLimit(d);
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%u FPS%@",rate,runtime_ios_fps_limit_supported(rate) ? @"" : @" · unavailable"];
        } else if (path.row == 4) cell.detailTextLabel.text = runtime_ios_taa_supported() ? ((_inGame ? runtime_ios_taa_enabled() : TOTKLauncherTAA(d)) ? @"On" : @"Off") : @"Unavailable";
        else {
            UISwitch *toggle = [UISwitch new];
            toggle.on = [d boolForKey:@"TOTK_LAUNCHER_SHADER_HUD"];
            toggle.accessibilityLabel = @"Shader compilation indicator";
            [toggle addTarget:self action:@selector(shaderIndicatorChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    }
    BOOL controlsOverride = NO;
    if (path.section == 2) {
        if (path.row == 0) cell.detailTextLabel.text = TOTKLauncherTouch(d) ? @"Automatic" : @"Off";
        else if (path.row == 1) { cell.detailTextLabel.text = @{@"auto":@"Automatic",@"xbox":@"Xbox",@"playstation":@"PlayStation",@"switch":@"Switch"}[TOTKLauncherControllerType(d)]; controlsOverride = getenv("TOTK_CONTROLS") != NULL; }
        else if (path.row == 2) { cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld / 100",(long)TOTKLauncherMouseSensitivity(d)]; controlsOverride = getenv("TOTK_MOUSE_SENSITIVITY") != NULL; }
        else if (path.row == 3) { cell.detailTextLabel.text = TOTKLauncherMouseInvertY(d) ? @"On" : @"Off"; controlsOverride = getenv("TOTK_MOUSE_INVERT_Y") != NULL; }
        else { cell.detailTextLabel.text = @"Edit"; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; controlsOverride = path.row == 4 && getenv("TOTK_CONTROLS") != NULL; }
        if (_inGame) controlsOverride = NO;
        if (controlsOverride) cell.detailTextLabel.text = @"Developer override";
    }
    if (path.section == 4) cell.detailTextLabel.text = [self languageTitle:TOTKLauncherLanguage(d)];
    BOOL disabled = _busy || _started || controlsOverride || (_inGame && path.section == 3) || (path.section == 0 && _unavailable) ||
        (path.section == 1 && path.row == 0 && !displaySettings) ||
        (path.section == 1 && path.row == 3 && !runtime_ios_fps_limit_supported(60)) ||
        (path.section == 1 && path.row == 4 && !runtime_ios_taa_supported());
    cell.userInteractionEnabled = !disabled;
    cell.textLabel.enabled = !disabled;
    cell.accessibilityLabel = cell.textLabel.text;
    cell.accessibilityValue = cell.detailTextLabel.text;
    cell.accessibilityIdentifier = [@"TOTKSetting." stringByAppendingString:cell.textLabel.text];
    if (_inGame && (path.section == 1 || path.section == 2 || path.section == 4)) {
        NSString *key = [self startupKeyForPath:path];
        BOOL pending = key && ![startup_preferences(d)[key] isEqual:_runningPreferences[key]];
        setting_timing_hint(cell,(path.section == 1 && path.row > 0) || (path.section == 2 && (path.row == 0 || path.row == 5)),pending);
    } else if (path.section == 1 || path.section == 2 || path.section == 4) cell.accessibilityHint = @"Applies when you press Play.";
    else if (_inGame && path.section == 3) cell.accessibilityHint = @"Available before Play. Save your progress, close the app, and reopen it.";
    else if (path.section == 0) cell.accessibilityHint = _inGame ? @"Close settings and return to the active game." : @"Start the game with these settings.";
    if (disabled) cell.accessibilityTraits |= UIAccessibilityTraitNotEnabled;
    return cell;
}
- (NSString *)languageTitle:(NSString *)language {
    NSUInteger index = [TOTKLanguages() indexOfObject:language];
    return @[@"System",@"繁體中文",@"简体中文",@"English",@"日本語",@"Deutsch",@"Español",@"Français",@"Italiano",@"Nederlands",@"Русский",@"한국어"][index == NSNotFound ? 0 : index];
}
- (void)refreshRestartFooter {
    if (!_inGame || !self.tableView) return;
    BOOL pending = ![startup_preferences(NSUserDefaults.standardUserDefaults) isEqual:_runningPreferences];
    CGFloat width = MAX(self.tableView.bounds.size.width,320);
    UILabel *label = [UILabel new];
    label.text = pending ? @"Restart required\nSave progress, then close and reopen TOTK."
        : @"Live controls apply immediately.";
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = pending ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
    label.numberOfLines = 0;
    label.accessibilityIdentifier = @"TOTKRestartFooter";
    CGSize size = [label sizeThatFits:CGSizeMake(width-40,CGFLOAT_MAX)];
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0,0,width,size.height+32)];
    label.frame = CGRectMake(20,16,width-40,size.height);
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [footer addSubview:label];
    self.tableView.tableFooterView = footer;
}
- (void)shaderIndicatorChanged:(UISwitch *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"TOTK_LAUNCHER_SHADER_HUD"];
    if (_HUDChanged) _HUDChanged();
}
- (void)setTouchChoice:(NSUInteger)choice {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (!choice) {
        [defaults setBool:YES forKey:@"TOTK_LAUNCHER_TOUCH"];
        if (_HUDChanged) _HUDChanged();
        [self.tableView reloadData];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Hide touch controls?"
        message:@"Use your keyboard or controller. The bottom-left game menu button stays visible, so you can turn touch controls on again."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hide controls" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        self->_touchOffConfirmed = YES;
        [defaults setBool:NO forKey:@"TOTK_LAUNCHER_TOUCH"];
        if (self->_HUDChanged) self->_HUDChanged();
        [self.tableView reloadData];
    }]];
    if (self.presentedViewController) [self dismissViewControllerAnimated:YES completion:^{ [self presentViewController:alert animated:YES completion:nil]; }];
    else [self presentViewController:alert animated:YES completion:nil];
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
- (NSString *)startupKeyForPath:(NSIndexPath *)path {
    if (path.section == 1 && path.row == 0) return @"graphics";
    if (path.section == 2 && path.row > 0 && path.row < 5) return @[@"controller",@"sensitivity",@"invert",@"bindings"][path.row-1];
    return path.section == 4 ? @"language" : nil;
}
- (void)startupSettingChangedAtPath:(NSIndexPath *)path previousValue:(id)previous {
    if (!_inGame) return;
    NSString *key = [self startupKeyForPath:path];
    if (!key) return;
    id current = startup_preferences(NSUserDefaults.standardUserDefaults)[key];
    if (![previous isEqual:current] && ![current isEqual:_runningPreferences[key]]) show_restart_required(self);
}
- (void)choose:(NSArray<NSString *> *)titles path:(NSIndexPath *)path selected:(void (^)(NSUInteger))selected {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
    TOTKChooseSetting(self,cell.textLabel.text,titles,cell.detailTextLabel.text,nil,^(NSUInteger index) {
        NSString *key = [self startupKeyForPath:path];
        id previous = key ? startup_preferences(NSUserDefaults.standardUserDefaults)[key] : nil;
        selected(index); [self.tableView reloadData]; [self refreshRestartFooter];
        if (key) [self startupSettingChangedAtPath:path previousValue:previous];
    });
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (_busy || _started) return;
    if (_inGame && path.section == 0) { [self resumeGame]; return; }
    if (_inGame && path.section == 3) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (path.section == 0) {
        if (_unavailable) return;
        BOOL controller = NO;
        for (GCController *pad in GCController.controllers) if (pad.extendedGamepad) controller = YES;
        if (!TOTKLauncherTouch(d) && !controller && !GCKeyboard.coalescedKeyboard && !_touchOffConfirmed) { [self message:@"Enable touch controls, connect a controller or keyboard, or select Off again and confirm keyboard-only input before Play."]; return; }
        NSError *controlsError = nil;
        if (!TOTKLauncherPrepareControls(d,&controlsError)) { [self message:controlsError.localizedDescription ?: @"Cannot prepare controls. Play has not started."]; return; }
        if (TOTKLauncherDisplaySettingsAvailable(NSBundle.mainBundle.infoDictionary)) {
            CGSize bounds = self.view.window.bounds.size; TOTKGraphicsPlan plan;
            if (!TOTKLauncherGraphicsPlan(d,NSBundle.mainBundle.infoDictionary,bounds.width,bounds.height,self.view.window.windowScene.screen.nativeScale,&plan)) {
                [self message:@"Choose a resolution combination within the game profile. Use a larger multiplier or lower output when the calculated input exceeds 1080 high."]; return;
            }
        }
        if (![_store sealForPlay]) return;
        _started = YES; [self.tableView reloadData]; _play();
    } else if (path.section == 1 && path.row == 0) {
        __weak TOTKLauncher *weakSelf = self;
        TOTKResolutionSettings *resolution = [[TOTKResolutionSettings alloc] initWithChanged:^{
            TOTKLauncher *owner = weakSelf; if (!owner) return;
            [owner.tableView reloadData]; [owner refreshRestartFooter];
            if (owner->_inGame && ![TOTKLauncherGraphicsPreferences(NSUserDefaults.standardUserDefaults) isEqual:owner->_runningPreferences[@"graphics"]]) {
                show_restart_required(owner.navigationController.topViewController);
            }
        }];
        [self.navigationController pushViewController:resolution animated:YES];
    } else if (path.section == 1 && path.row == 1) {
        [self choose:@[@"Full",@"FPS only",@"Off"] path:path selected:^(NSUInteger i) {
            [d setInteger:(NSInteger[]){1,2,0}[i] forKey:@"TOTK_LAUNCHER_HUD"];
            if (self->_HUDChanged) self->_HUDChanged();
        }];
    } else if (path.section == 1 && path.row == 2) {
        [self choose:@[@"On",@"Off"] path:path selected:^(NSUInteger i) {
            [d setBool:i == 0 forKey:@"TOTK_LAUNCHER_METAL_HUD"];
            if (self->_HUDChanged) self->_HUDChanged();
        }];
    } else if (path.section == 1 && path.row == 3) {
        NSMutableArray<NSNumber *> *rates = [NSMutableArray array];
        NSMutableArray<NSString *> *titles = [NSMutableArray array];
        for (NSNumber *rate in @[@30,@40,@60]) if (runtime_ios_fps_limit_supported(rate.unsignedIntValue)) {
            [rates addObject:rate]; [titles addObject:[NSString stringWithFormat:@"%@ FPS",rate]];
        }
        if (!rates.count) return;
        [self choose:titles path:path selected:^(NSUInteger i) {
            [d setInteger:rates[i].integerValue forKey:@"TOTK_LAUNCHER_FPS_LIMIT"];
            if (self->_HUDChanged) self->_HUDChanged();
        }];
    } else if (path.section == 1 && path.row == 4) {
        if (!runtime_ios_taa_supported()) return;
        [self choose:@[@"Off",@"On"] path:path selected:^(NSUInteger i) {
            [d setBool:i == 1 forKey:@"TOTK_LAUNCHER_TAA"];
            if (self->_HUDChanged) self->_HUDChanged();
        }];
    } else if (path.section == 2) {
        if (path.row == 0) {
            [self choose:@[@"Automatic",@"Off"] path:path selected:^(NSUInteger i) { [self setTouchChoice:i]; }];
        } else if (path.row == 1 && (_inGame || !getenv("TOTK_CONTROLS"))) {
            [self choose:@[@"Automatic",@"Xbox",@"PlayStation",@"Switch"] path:path selected:^(NSUInteger i) {
                [d setObject:(@[@"auto",@"xbox",@"playstation",@"switch"])[i] forKey:@"TOTK_LAUNCHER_CONTROLLER_TYPE"];
            }];
        } else if (path.row == 2 && (_inGame || !getenv("TOTK_MOUSE_SENSITIVITY"))) [self changeMouseSensitivity];
        else if (path.row == 3 && (_inGame || !getenv("TOTK_MOUSE_INVERT_Y"))) {
            [self choose:@[@"Off",@"On"] path:path selected:^(NSUInteger i) { [d setBool:i == 1 forKey:@"TOTK_LAUNCHER_MOUSE_INVERT_Y"]; }];
        } else if (path.row == 4 && (_inGame || !getenv("TOTK_CONTROLS"))) {
            TOTKButtonMappings *mappings = [TOTKButtonMappings new];
            mappings.editingNextLaunch = _inGame;
            mappings.runningBindings = _runningPreferences[@"bindings"];
            __weak TOTKLauncher *weakSelf = self;
            mappings.changed = ^{ [weakSelf.tableView reloadData]; [weakSelf refreshRestartFooter]; };
            [self.navigationController pushViewController:mappings animated:YES];
        } else if (path.row == 5) {
            [self.navigationController pushViewController:[TOTKKeyboardMappings new] animated:YES];
        }
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
        else if (path.row == 3) {
            NSError *error = nil; NSArray *backups = [_store backups:&error];
            if (!backups.count) { [self message:error.localizedDescription ?: @"No backups yet."]; return; }
            [self choose:[backups valueForKey:@"lastPathComponent"] path:path selected:^(NSUInteger i) { [self confirmImport:backups[i] restore:YES]; }];
        } else [self editSaveAtPath:path];
    }
}
- (void)changeMouseSensitivity {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Mouse sensitivity" message:@"Enter a whole number from 1 to 100. Default is 50. Applies at the next game start." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.accessibilityLabel = @"Mouse sensitivity";
        field.text = [NSString stringWithFormat:@"%ld",(long)TOTKLauncherMouseSensitivity(NSUserDefaults.standardUserDefaults)];
    }];
    __weak UIAlertController *weakAlert = alert;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; NSString *text = weakAlert.textFields.firstObject.text;
        if (!valid_mouse_sensitivity(text)) return;
        NSNumber *previous = @(TOTKLauncherMouseSensitivity(NSUserDefaults.standardUserDefaults));
        [NSUserDefaults.standardUserDefaults setInteger:text.integerValue forKey:@"TOTK_LAUNCHER_MOUSE_SENSITIVITY"];
        [self.tableView reloadData]; [self refreshRestartFooter];
        [self startupSettingChangedAtPath:[NSIndexPath indexPathForRow:2 inSection:2] previousValue:previous];
    }];
    __weak UIAlertAction *weakSave = save;
    UITextField *field = alert.textFields.firstObject;
    [field addAction:[UIAction actionWithHandler:^(UIAction *action) {
        UITextField *input = (UITextField *)action.sender;
        weakSave.enabled = valid_mouse_sensitivity(input.text);
    }] forControlEvents:UIControlEventEditingChanged];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:save];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)perform:(NSString *(^)(NSError **))operation {
    if (_busy || _started || _inGame) return;
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
    if (_inGame) return;
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
    if (_busy || _started || _inGame) return;
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
- (void)finishEditorDirectory:(NSURL *)directory message:(NSString *)message {
    [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
    _busy = NO;
    [self.tableView reloadData];
    if (message) [self message:message];
}
- (void)editSaveAtPath:(NSIndexPath *)path {
    if (_busy || _started || _inGame) return;
    _busy = YES;
    [self.tableView reloadData];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *error = nil;
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        BOOL made = [fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error];
        NSURL *snapshot = made ? [self->_store exportToDirectory:directory error:&error] : nil;
        NSMutableArray<NSString *> *slots = [NSMutableArray array];
        if (snapshot) {
            for (unsigned i = 0; i < 6; i++) {
                NSString *slot = [NSString stringWithFormat:@"slot_%02u",i];
                if ([fm fileExistsAtPath:[[snapshot URLByAppendingPathComponent:slot] URLByAppendingPathComponent:@"progress.sav"].path]) [slots addObject:slot];
            }
        }
        dispatch_async(dispatch_get_main_queue(),^{
            if (!snapshot || !slots.count) {
                [self finishEditorDirectory:directory message:error.localizedDescription ?: @"No complete save slot is available to edit."];
                return;
            }
            UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Edit this save"
                message:@"Choose a slot to open in Marc Robledo’s online editor. Website scripts can read this copy. Apply edited save creates a backup before replacement."
                preferredStyle:UIAlertControllerStyleActionSheet];
            for (NSString *slot in slots) {
                [sheet addAction:[UIAlertAction actionWithTitle:slot style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    (void)action;
                    NSURL *progress = [[snapshot URLByAppendingPathComponent:slot] URLByAppendingPathComponent:@"progress.sav"];
                    NSError *readError = nil;
                    NSData *data = [NSData dataWithContentsOfURL:progress options:0 error:&readError];
                    if (!data) { [self finishEditorDirectory:directory message:readError.localizedDescription ?: @"Cannot read this save slot."]; return; }
                    TOTKSaveEditor *editor = [[TOTKSaveEditor alloc] initWithProgressData:data completion:^(NSData *edited) {
                        if (!edited) { [self finishEditorDirectory:directory message:nil]; return; }
                        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
                            NSError *applyError = nil;
                            BOOL ok = [self->_store applyEditedProgress:edited slot:slot expectedDirectory:snapshot error:&applyError];
                            dispatch_async(dispatch_get_main_queue(),^{
                                [self finishEditorDirectory:directory message:ok ? @"Edited save applied. The previous save is under Restore backup. Press Play to load it." : (applyError.localizedDescription ?: @"The edited save was not applied.")];
                            });
                        });
                    }];
                    editor.modalPresentationStyle = UIModalPresentationFullScreen;
                    [self presentViewController:editor animated:YES completion:nil];
                }]];
            }
            [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
                (void)action; [self finishEditorDirectory:directory message:nil];
            }]];
            [self anchor:sheet path:path];
            [self presentViewController:sheet animated:YES completion:nil];
        });
    });
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
