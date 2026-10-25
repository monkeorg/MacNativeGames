#import "resolution_settings.h"
#import "launcher_settings.h"
#import "menu_style.h"
#include "../../runtime/runtime.h"
#include <math.h>

@interface TOTKResolutionFactor : UIViewController
@property(nonatomic) double factor;
@property(nonatomic, copy) void (^saved)(double);
@end

@implementation TOTKResolutionFactor {
    UISlider *_slider;
    UILabel *_value;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Multiplier";
    self.view.backgroundColor = UIColor.clearColor;
    UIView *background = TOTKSettingsBackground();
    background.frame = self.view.bounds;
    background.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:background];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    _value = [UILabel new];
    _value.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    _value.textAlignment = NSTextAlignmentCenter;
    _value.adjustsFontForContentSizeCategory = YES;
    _slider = [UISlider new];
    _slider.minimumValue = 1; _slider.maximumValue = 4; _slider.value = self.factor;
    _slider.accessibilityLabel = @"Upscale multiplier";
    _slider.accessibilityIdentifier = @"resolution.factor.slider";
    [_slider addTarget:self action:@selector(slide) forControlEvents:UIControlEventValueChanged];
    UIStackView *presets = [[UIStackView alloc] init];
    presets.distribution = UIStackViewDistributionFillEqually;
    for (NSNumber *number in @[@1,@1.25,@1.5,@2,@3,@4]) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        button.titleLabel.adjustsFontForContentSizeCategory = YES;
        [button setTitle:[NSString stringWithFormat:@"%@×",number] forState:UIControlStateNormal];
        [button addAction:[UIAction actionWithHandler:^(UIAction *action) {
            (void)action; self->_slider.value = number.floatValue; [self slide];
        }] forControlEvents:UIControlEventTouchUpInside];
        [presets addArrangedSubview:button];
    }
    UILabel *hint = [UILabel new];
    hint.text = @"Output ÷ multiplier = input. Input height: 360–1080 pixels.";
    hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    hint.textColor = UIColor.secondaryLabelColor; hint.numberOfLines = 0;
    hint.adjustsFontForContentSizeCategory = YES;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_value,_slider,presets,hint]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[[stack.topAnchor constraintEqualToAnchor:guide.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-24]]];
    [self slide];
}
- (void)slide {
    self.factor = round(_slider.value * 100) / 100;
    _value.text = [NSString stringWithFormat:@"%.3g×",self.factor];
    _slider.accessibilityValue = _value.text;
}
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)done {
    double factor = self.factor;
    void (^saved)(double) = self.saved;
    [self dismissViewControllerAnimated:YES completion:^{ if (saved) saved(factor); }];
}
@end

@implementation TOTKResolutionSettings {
    void (^_changed)(void);
    NSTimer *_statusTimer;
}
- (instancetype)initWithChanged:(void (^)(void))changed {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) { _changed = [changed copy]; self.title = @"Resolution"; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    TOTKStyleSettingsPage(self);
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
    __weak TOTKResolutionSettings *weakSelf = self;
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:2]] withRowAnimation:UITableViewRowAnimationNone];
    }];
}
- (void)viewWillDisappear:(BOOL)animated {
    [_statusTimer invalidate]; _statusTimer = nil;
    [super viewWillDisappear:animated];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:2]];
    cell.detailTextLabel.text = [self summary];
}
- (NSArray<NSString *> *)configurationRows {
    NSString *mode = TOTKLauncherResolutionMode(NSUserDefaults.standardUserDefaults);
    NSMutableArray *rows = [NSMutableArray array];
    if (![mode isEqual:@"output-scale"]) [rows addObject:@"Input"];
    if (![mode isEqual:@"input-scale"]) [rows addObject:@"Output"];
    if (![mode isEqual:@"input-output"]) [rows addObject:@"Multiplier"];
    [rows addObject:@"Scaler"];
    return rows;
}
- (BOOL)fullDisplayAvailable {
    CGSize size = self.view.window ? self.view.window.bounds.size : self.view.bounds.size;
    id version = NSBundle.mainBundle.infoDictionary[@"TOTKIOSFourThreeLayoutVersion"];
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad &&
        TOTKLauncherDisplaySettingsAvailable(NSBundle.mainBundle.infoDictionary) &&
        [version isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)version) != CFBooleanGetTypeID() &&
        [version isEqual:@1] && MIN(size.width,size.height) > 0 &&
        fabs(MAX(size.width,size.height) / MIN(size.width,size.height) - 4.0 / 3.0) <= 0.001;
}
- (BOOL)graphicsPlan:(TOTKGraphicsPlan *)plan {
    CGSize size = self.view.window ? self.view.window.bounds.size : self.view.bounds.size;
    UIScreen *screen = self.view.window.windowScene.screen ?: UIScreen.mainScreen;
    return TOTKLauncherGraphicsPlan(NSUserDefaults.standardUserDefaults,NSBundle.mainBundle.infoDictionary,
        MAX(size.width,size.height),MIN(size.width,size.height),screen.nativeScale,plan);
}
- (NSString *)summary {
    TOTKGraphicsPlan plan;
    if (![self graphicsPlan:&plan]) return @"Input outside game profile";
    double fit = fmin((double)plan.displayWidth / plan.canvasWidth,(double)plan.displayHeight / plan.canvasHeight);
    unsigned width = (unsigned)(2 * round(plan.canvasWidth * fit / 2));
    unsigned height = (unsigned)(2 * round(plan.canvasHeight * fit / 2));
    return [NSString stringWithFormat:@"%u × %u → %u × %u",plan.inputWidth,plan.inputHeight,width,height];
}
- (NSString *)activity {
    if (!TOTKLauncherSpatialUpscaling(NSUserDefaults.standardUserDefaults)) return @"Off";
    unsigned activity = runtime_ios_upscaling_activity();
    NSMutableArray *passes = [NSMutableArray array];
    if (activity & 1) [passes addObject:@"scene"];
    if (activity & 2) [passes addObject:@"docked"];
    if (activity & 4) [passes addObject:@"output"];
    return passes.count ? [@"Recent MetalFX activity: " stringByAppendingString:[passes componentsJoinedByString:@" / "]] : @"No recent MetalFX frames";
}
- (NSString *)modeTitle:(NSString *)mode {
    return @{@"input-output":@"Input + output",@"input-scale":@"Input + multiplier",@"output-scale":@"Output + multiplier"}[mode];
}
- (NSString *)outputTitle:(NSString *)mode {
    if ([mode hasPrefix:@"native"]) {
        CGSize size = self.view.window ? self.view.window.bounds.size : self.view.bounds.size;
        UIScreen *screen = self.view.window.windowScene.screen ?: UIScreen.mainScreen;
        double fraction = [mode isEqual:@"native50"] ? 0.5 : [mode isEqual:@"native75"] ? 0.75 : 1;
        unsigned width = (unsigned)(2 * round(MAX(size.width,size.height) * screen.nativeScale * fraction / 2));
        unsigned height = (unsigned)(2 * round(MIN(size.width,size.height) * screen.nativeScale * fraction / 2));
        NSString *title = @{@"native50":@"50% native",@"native75":@"75% native",@"native":@"Native"}[mode];
        return [NSString stringWithFormat:@"%@ · %u × %u",title,width,height];
    }
    if ([mode isEqual:@"game"]) return @"Match input";
    CGSize size = self.view.window ? self.view.window.bounds.size : self.view.bounds.size;
    double ratio = MAX(size.width,size.height) / MAX(1,MIN(size.width,size.height));
    BOOL fullDisplay = self.fullDisplayAvailable && [TOTKLauncherAspect(NSUserDefaults.standardUserDefaults) isEqual:@"display"];
    double height = mode.doubleValue;
    unsigned width = (unsigned)(2 * round(height * (fullDisplay ? ratio : 16.0 / 9.0) / 2));
    return [NSString stringWithFormat:@"%@ high · %u × %u",mode,width,(unsigned)(2 * round(height / 2))];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; return section == 1 ? self.configurationRows.count : 2;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; return (@[@"Setup",@"Resolution",@"Status"])[section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 1) return @"Input renders the game. Full display fills the iPad; 16:9 keeps black bars. Native uses the window’s physical pixels.";
    if (section == 2) return [[self summary] isEqual:@"Input outside game profile"]
        ? @"Adjust output or multiplier. Input height must be 360–1080 pixels, within the 1920 × 1080 game limit."
        : @"Sizes apply at the next game start. MetalFX activity shows encodes from the last two seconds.";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    cell.accessoryType = path.section == 2 ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = path.section == 2 ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    cell.detailTextLabel.numberOfLines = 0;
    if (path.section == 0) {
        cell.textLabel.text = path.row == 0 ? @"Mode" : @"Aspect";
        cell.detailTextLabel.text = path.row == 0 ? [self modeTitle:TOTKLauncherResolutionMode(defaults)]
            : ([self fullDisplayAvailable] && [TOTKLauncherAspect(defaults) isEqual:@"display"] ? @"Full display" : @"16:9");
    } else if (path.section == 1) {
        NSString *row = self.configurationRows[path.row]; cell.textLabel.text = row;
        if ([row isEqual:@"Input"]) {
            TOTKGraphicsPlan plan;
            cell.detailTextLabel.text = [self graphicsPlan:&plan] ? [NSString stringWithFormat:@"%u high",plan.inputHeight] : @"Outside game profile";
        }
        else if ([row isEqual:@"Output"]) cell.detailTextLabel.text = [self outputTitle:TOTKLauncherPresentationMode(defaults)];
        else if ([row isEqual:@"Multiplier"]) cell.detailTextLabel.text = [NSString stringWithFormat:@"%.3g×",TOTKLauncherUpscaleFactor(defaults)];
        else cell.detailTextLabel.text = runtime_ios_spatial_upscaling_supported()
            ? (TOTKLauncherSpatialUpscaling(defaults) ? @"MetalFX Spatial" : @"Game scaling") : @"Game scaling · MetalFX unavailable";
    } else {
        cell.textLabel.text = path.row == 0 ? @"Configured" : @"Activity";
        cell.detailTextLabel.text = path.row == 0 ? self.summary : self.activity;
    }
    NSDictionary *symbols = @{@"Mode":@"slider.horizontal.3",@"Aspect":@"aspectratio",@"Input":@"square.arrow.down",
        @"Output":@"display",@"Multiplier":@"multiply",@"Scaler":@"sparkles",@"Configured":@"rectangle.on.rectangle",@"Activity":@"waveform.path"};
    cell.accessibilityIdentifier = [@"resolution." stringByAppendingString:cell.textLabel.text.lowercaseString];
    TOTKStyleSettingsCell(cell,symbols[cell.textLabel.text]);
    return cell;
}
- (void)save:(void (^)(NSUserDefaults *))update resetScene:(BOOL)resetScene {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *before = TOTKLauncherGraphicsPreferences(defaults);
    update(defaults);
    if (resetScene) {
        [defaults removeObjectForKey:@"TOTK_LAUNCHER_CUSTOM_SCENE_HEIGHT"];
        [defaults setInteger:100 forKey:@"TOTK_LAUNCHER_SCENE_SCALE"];
    }
    [self.tableView reloadData];
    if (![before isEqual:TOTKLauncherGraphicsPreferences(defaults)] && _changed) _changed();
}
- (void)choose:(NSArray<NSString *> *)titles path:(NSIndexPath *)path selected:(void (^)(NSUInteger))selected {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [titles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger index, BOOL *stop) {
        (void)stop;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action; selected(index);
        }]];
    }];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.tableView;
    sheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:path];
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)saveInputHeight:(NSInteger)height {
    [self save:^(NSUserDefaults *defaults) {
        [defaults setInteger:height forKey:@"TOTK_LAUNCHER_CUSTOM_HEIGHT"];
    } resetScene:YES];
}
- (void)customInput {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Input height" message:@"Enter 360–1080 pixels in steps of 6. Width follows the selected aspect." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.accessibilityLabel = @"Input height";
        field.text = [NSString stringWithFormat:@"%ld",(long)TOTKLauncherRenderHeight(NSUserDefaults.standardUserDefaults)];
    }];
    BOOL (^valid)(NSString *) = ^BOOL(NSString *text) {
        if (!text.length || text.length > 4 || [text rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return NO;
        return text.integerValue >= 360 && text.integerValue <= 1080 && text.integerValue % 6 == 0;
    };
    __weak UIAlertController *weakAlert = alert;
    UIAlertAction *done = [UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; NSString *text = weakAlert.textFields.firstObject.text;
        if (valid(text)) [self saveInputHeight:text.integerValue];
    }];
    done.enabled = valid(alert.textFields.firstObject.text);
    __weak UIAlertAction *weakDone = done;
    [alert.textFields.firstObject addAction:[UIAction actionWithHandler:^(UIAction *action) {
        weakDone.enabled = valid(((UITextField *)action.sender).text);
    }] forControlEvents:UIControlEventEditingChanged];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:done];
    void (^present)(void) = ^{ [self presentViewController:alert animated:YES completion:nil]; };
    if (self.presentedViewController) [self dismissViewControllerAnimated:YES completion:present];
    else present();
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 2) return;
    if (path.section == 0 && path.row == 0) {
        NSArray *modes = TOTKLauncherResolutionModes();
        NSMutableArray *titles = [NSMutableArray array];
        for (NSString *mode in modes) [titles addObject:[self modeTitle:mode]];
        [self choose:titles path:path selected:^(NSUInteger index) {
            [self save:^(NSUserDefaults *defaults) {
                [defaults setObject:modes[index] forKey:@"TOTK_LAUNCHER_RESOLUTION_MODE"];
                if ([modes[index] isEqual:@"output-scale"] && [TOTKLauncherPresentationMode(defaults) isEqual:@"game"]) {
                    [defaults setObject:@"1440" forKey:@"TOTK_LAUNCHER_DISPLAY_OUTPUT"];
                    [defaults setDouble:2 forKey:@"TOTK_LAUNCHER_UPSCALE_FACTOR"];
                }
            } resetScene:YES];
        }];
        return;
    }
    if (path.section == 0) {
        [self choose:[self fullDisplayAvailable] ? @[@"16:9",@"Full display"] : @[@"16:9"] path:path selected:^(NSUInteger index) {
            [self save:^(NSUserDefaults *defaults) { [defaults setObject:index ? @"display" : @"16:9" forKey:@"TOTK_LAUNCHER_ASPECT"]; } resetScene:NO];
        }];
        return;
    }
    NSString *row = self.configurationRows[path.row];
    if ([row isEqual:@"Input"]) {
        [self choose:@[@"540 high",@"720 high",@"900 high",@"960 high",@"1080 high",@"Custom…"] path:path selected:^(NSUInteger index) {
            if (index == 5) [self customInput];
            else [self saveInputHeight:(NSInteger[]){540,720,900,960,1080}[index]];
        }];
    } else if ([row isEqual:@"Output"]) {
        NSMutableArray *modes = [TOTKLauncherPresentationModes() mutableCopy];
        if ([TOTKLauncherResolutionMode(NSUserDefaults.standardUserDefaults) isEqual:@"output-scale"]) [modes removeObject:@"game"];
        NSMutableArray *titles = [NSMutableArray array];
        for (NSString *mode in modes) [titles addObject:[self outputTitle:mode]];
        [self choose:titles path:path selected:^(NSUInteger index) {
            [self save:^(NSUserDefaults *defaults) { [defaults setObject:modes[index] forKey:@"TOTK_LAUNCHER_DISPLAY_OUTPUT"]; } resetScene:NO];
        }];
    } else if ([row isEqual:@"Multiplier"]) {
        TOTKResolutionFactor *factor = [TOTKResolutionFactor new];
        factor.factor = TOTKLauncherUpscaleFactor(NSUserDefaults.standardUserDefaults);
        factor.saved = ^(double value) { [self save:^(NSUserDefaults *defaults) { [defaults setDouble:value forKey:@"TOTK_LAUNCHER_UPSCALE_FACTOR"]; } resetScene:NO]; };
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:factor];
        nav.modalPresentationStyle = UIModalPresentationPopover; nav.preferredContentSize = CGSizeMake(420,310);
        nav.popoverPresentationController.sourceView = self.tableView;
        nav.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:path];
        [self presentViewController:nav animated:YES completion:nil];
    } else {
        [self choose:runtime_ios_spatial_upscaling_supported() ? @[@"Game scaling",@"MetalFX Spatial"] : @[@"Game scaling"] path:path selected:^(NSUInteger index) {
            [self save:^(NSUserDefaults *defaults) { [defaults setBool:index == 1 forKey:@"TOTK_LAUNCHER_SPATIAL_UPSCALING"]; } resetScene:NO];
        }];
    }
}
@end
