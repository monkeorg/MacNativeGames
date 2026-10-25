#import "resolution_settings.h"
#import "launcher_settings.h"
#import "menu_style.h"
#import "settings_choices.h"
#include "../../runtime/runtime.h"
#include <math.h>

@interface TOTKResolutionFactor : UIViewController
@property(nonatomic) double factor;
@property(nonatomic) BOOL inputHeightMode;
@property(nonatomic) double aspect;
@property(nonatomic, copy) void (^saved)(double);
@end

@implementation TOTKResolutionFactor {
    UISlider *_slider;
    UILabel *_value;
    UITextField *_heightField;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.inputHeightMode ? @"Input height" : @"Multiplier";
    self.view.backgroundColor = UIColor.clearColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    _value = [UILabel new];
    _value.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    _value.textAlignment = NSTextAlignmentCenter;
    _value.adjustsFontForContentSizeCategory = YES;
    _slider = [UISlider new];
    _slider.minimumValue = self.inputHeightMode ? 360 : 1;
    _slider.maximumValue = self.inputHeightMode ? 1080 : 4;
    _slider.value = self.factor;
    _slider.accessibilityLabel = self.inputHeightMode ? @"Input height" : @"Upscale multiplier";
    _slider.accessibilityIdentifier = self.inputHeightMode ? @"resolution.input.slider" : @"resolution.factor.slider";
    [_slider addTarget:self action:@selector(slide) forControlEvents:UIControlEventValueChanged];
    UIStackView *presets = [[UIStackView alloc] init];
    presets.distribution = UIStackViewDistributionFillEqually;
    NSArray *values = self.inputHeightMode ? @[@540,@720,@900,@960,@1080] : @[@1,@1.25,@1.5,@2,@3,@4];
    for (NSNumber *number in values) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        button.titleLabel.adjustsFontForContentSizeCategory = YES;
        [button setTitle:[NSString stringWithFormat:self.inputHeightMode ? @"%@" : @"%@×",number] forState:UIControlStateNormal];
        [button addAction:[UIAction actionWithHandler:^(UIAction *action) {
            (void)action; self->_slider.value = number.floatValue; [self slide];
        }] forControlEvents:UIControlEventTouchUpInside];
        [presets addArrangedSubview:button];
    }
    UILabel *hint = [UILabel new];
    hint.text = self.inputHeightMode ? @"Select 360–1080 pixels in steps of 6. Width follows the selected aspect. Enter an exact height below."
        : @"Output ÷ multiplier = input. Input height: 360–1080 pixels.";
    hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    hint.textColor = UIColor.secondaryLabelColor; hint.numberOfLines = 0;
    hint.adjustsFontForContentSizeCategory = YES;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_value,_slider,presets,hint]];
    if (self.inputHeightMode) {
        _heightField = [UITextField new];
        _heightField.borderStyle = UITextBorderStyleRoundedRect;
        _heightField.keyboardType = UIKeyboardTypeNumberPad;
        _heightField.accessibilityLabel = @"Exact input height";
        _heightField.accessibilityIdentifier = @"resolution.input.height";
        [_heightField addTarget:self action:@selector(editHeight) forControlEvents:UIControlEventEditingChanged];
        [stack addArrangedSubview:_heightField];
    }
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
    self.factor = self.inputHeightMode ? 6 * round(_slider.value / 6) : round(_slider.value * 100) / 100;
    _slider.value = self.factor;
    _value.text = self.inputHeightMode ? [NSString stringWithFormat:@"%u × %u",(unsigned)(2 * round(self.factor * self.aspect / 2)),(unsigned)self.factor]
        : [NSString stringWithFormat:@"%.3g×",self.factor];
    _slider.accessibilityValue = _value.text;
    _heightField.text = [NSString stringWithFormat:@"%u",(unsigned)self.factor];
    self.navigationItem.rightBarButtonItem.enabled = YES;
}
- (void)editHeight {
    NSString *text = _heightField.text;
    NSInteger height = text.integerValue;
    BOOL valid = text.length && text.length <= 4 &&
        [text rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound &&
        height >= 360 && height <= 1080 && height % 6 == 0;
    self.navigationItem.rightBarButtonItem.enabled = valid;
    if (valid) { _slider.value = height; [self slide]; }
}
- (void)cancel { [self.navigationController popViewControllerAnimated:YES]; }
- (void)done {
    double factor = self.factor;
    void (^saved)(double) = self.saved;
    UINavigationController *navigation = self.navigationController;
    [navigation popViewControllerAnimated:YES];
    id<UIViewControllerTransitionCoordinator> transition = navigation.transitionCoordinator;
    if (transition) [transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) { (void)context; if (saved) saved(factor); }];
    else if (saved) saved(factor);
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
        TOTKResolutionSettings *owner = weakSelf;
        NSUInteger row = [owner.statusRows indexOfObject:@"MetalFX activity"];
        if (owner && row != NSNotFound)
            [owner.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:2]] withRowAnimation:UITableViewRowAnimationNone];
    }];
}
- (void)viewWillDisappear:(BOOL)animated {
    [_statusTimer invalidate]; _statusTimer = nil;
    [super viewWillDisappear:animated];
}
- (NSArray<NSString *> *)configurationRows {
    NSString *mode = TOTKLauncherResolutionMode(NSUserDefaults.standardUserDefaults);
    NSMutableArray *rows = [NSMutableArray array];
    if (![mode isEqual:@"output-scale"]) [rows addObject:@"Input"];
    if (![mode isEqual:@"input-scale"]) [rows addObject:@"Output"];
    if (![mode isEqual:@"input-output"]) [rows addObject:@"Multiplier"];
    [rows addObject:@"Scaler"];
    if ([TOTKLauncherScalerStage(NSUserDefaults.standardUserDefaults) isEqual:@"game-output"]) [rows addObject:@"Game canvas"];
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
- (NSArray<NSString *> *)statusRows {
    TOTKGraphicsPlan plan;
    NSMutableArray *rows = [NSMutableArray arrayWithObject:@"Input size"];
    if ([self graphicsPlan:&plan] && (plan.inputWidth != plan.canvasWidth || plan.inputHeight != plan.canvasHeight))
        [rows addObject:@"Game canvas"];
    [rows addObjectsFromArray:@[@"Output size",@"Effective multiplier",@"MetalFX activity"]];
    return rows;
}
- (NSString *)activity {
    unsigned activity = runtime_ios_upscaling_activity();
    NSMutableArray *passes = [NSMutableArray array];
    if (activity & 1) [passes addObject:@"scene"];
    if (activity & 2) [passes addObject:@"docked scene"];
    if (activity & 4) [passes addObject:@"final output"];
    return passes.count ? [passes componentsJoinedByString:@" / "] : @"None recently";
}
- (NSString *)effectiveMultiplier {
    TOTKGraphicsPlan plan;
    if (![self graphicsPlan:&plan]) return @"Unavailable";
    double fit=fmin((double)plan.displayWidth/plan.canvasWidth,(double)plan.displayHeight/plan.canvasHeight);
    return [NSString stringWithFormat:@"%.2f×",fit*plan.canvasHeight/plan.inputHeight];
}
- (NSString *)scalerTitle:(NSString *)stage {
    return @{@"game":@"Game scaling",@"game-output":@"Game → final MetalFX",
        @"scene-output":@"Scene MetalFX + final MetalFX"}[stage];
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
    if ([mode isEqual:@"game"]) return @"Match game canvas";
    CGSize size = self.view.window ? self.view.window.bounds.size : self.view.bounds.size;
    double ratio = MAX(size.width,size.height) / MAX(1,MIN(size.width,size.height));
    BOOL fullDisplay = self.fullDisplayAvailable && [TOTKLauncherAspect(NSUserDefaults.standardUserDefaults) isEqual:@"display"];
    double height = [mode isEqual:@"custom"] ? TOTKLauncherCustomOutputHeight(NSUserDefaults.standardUserDefaults) : mode.doubleValue;
    unsigned width = (unsigned)(2 * round(height * (fullDisplay ? ratio : 16.0 / 9.0) / 2));
    return [NSString stringWithFormat:@"%@ high · %u × %u",[mode isEqual:@"custom"] ? [NSString stringWithFormat:@"Custom %u",(unsigned)height] : mode,width,(unsigned)(2 * round(height / 2))];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section==1) return self.configurationRows.count;
    return section==2 ? self.statusRows.count : 2;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; return (@[@"Setup",@"Resolution",@"Status"])[section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 1) return @"Recommended input: 900p minimum, 960p+ for better clarity. Use Native output.";
    if (section == 2) {
        TOTKGraphicsPlan plan;
        return [self graphicsPlan:&plan]
            ? @"Sizes apply at the next game start. MetalFX activity covers the last two seconds."
            : @"Adjust output, multiplier, or game canvas. Input must fit 1920 × 1080. Game canvas must be at least the input height.";
    }
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
        else if ([row isEqual:@"Game canvas"]) {
            NSInteger height = TOTKLauncherGameCanvasHeight(defaults);
            cell.detailTextLabel.text = height ? [NSString stringWithFormat:@"%ld high",(long)height] : @"Match input";
        }
        else if ([row isEqual:@"Multiplier"]) cell.detailTextLabel.text = [NSString stringWithFormat:@"%.3g×",TOTKLauncherUpscaleFactor(defaults)];
        else cell.detailTextLabel.text = runtime_ios_spatial_upscaling_supported()
            ? [self scalerTitle:TOTKLauncherScalerStage(defaults)] : @"Game scaling · MetalFX unavailable";
    } else {
        NSString *row = self.statusRows[path.row];
        cell.textLabel.text = row;
        TOTKGraphicsPlan plan;
        BOOL valid = [self graphicsPlan:&plan];
        if ([row isEqual:@"MetalFX activity"]) cell.detailTextLabel.text = self.activity;
        else if ([row isEqual:@"Effective multiplier"]) cell.detailTextLabel.text = self.effectiveMultiplier;
        else if (!valid) cell.detailTextLabel.text = @"Invalid plan";
        else if ([row isEqual:@"Input size"]) cell.detailTextLabel.text = [NSString stringWithFormat:@"%u × %u",plan.inputWidth,plan.inputHeight];
        else if ([row isEqual:@"Game canvas"]) cell.detailTextLabel.text = [NSString stringWithFormat:@"%u × %u",plan.canvasWidth,plan.canvasHeight];
        else {
            double fit = fmin((double)plan.displayWidth/plan.canvasWidth,(double)plan.displayHeight/plan.canvasHeight);
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%u × %u",(unsigned)(2*round(plan.canvasWidth*fit/2)),(unsigned)(2*round(plan.canvasHeight*fit/2))];
        }
    }
    NSDictionary *symbols = @{@"Mode":@"slider.horizontal.3",@"Aspect":@"aspectratio",@"Input":@"arrow.down.square",
        @"Output":@"display",@"Game canvas":@"rectangle.on.rectangle",@"Multiplier":@"multiply",@"Effective multiplier":@"multiply",@"Scaler":@"sparkles",@"Input size":@"arrow.down.square",@"Output size":@"display",@"MetalFX activity":@"waveform.path"};
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
    UITableViewCell *cell=[self.tableView cellForRowAtIndexPath:path];
    NSString *selection = cell.detailTextLabel.text;
    if (![titles containsObject:selection] && [titles containsObject:@"Custom…"]) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        BOOL customInput = [cell.textLabel.text isEqual:@"Input"] && [defaults objectForKey:@"TOTK_LAUNCHER_CUSTOM_HEIGHT"];
        BOOL customOutput = [cell.textLabel.text isEqual:@"Output"] && [TOTKLauncherPresentationMode(defaults) isEqual:@"custom"];
        if (customInput || customOutput) selection = @"Custom…";
    }
    TOTKChooseSetting(self,cell.textLabel.text,titles,selection,nil,selected);
}
- (void)saveInputHeight:(NSInteger)height {
    [self save:^(NSUserDefaults *defaults) {
        [defaults setInteger:height forKey:@"TOTK_LAUNCHER_CUSTOM_HEIGHT"];
    } resetScene:YES];
}
- (void)customInput {
    TOTKResolutionFactor *editor = [TOTKResolutionFactor new];
    editor.inputHeightMode = YES;
    editor.factor = TOTKLauncherRenderHeight(NSUserDefaults.standardUserDefaults);
    CGSize size = self.view.window ? self.view.window.bounds.size : self.view.bounds.size;
    BOOL full = self.fullDisplayAvailable && [TOTKLauncherAspect(NSUserDefaults.standardUserDefaults) isEqual:@"display"];
    editor.aspect = full ? MAX(size.width,size.height) / MAX(1,MIN(size.width,size.height)) : 16.0 / 9.0;
    editor.saved = ^(double height) { [self saveInputHeight:(NSInteger)height]; };
    [self.navigationController pushViewController:editor animated:YES];
}
- (void)customOutput {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Custom output height"
        message:@"Enter an even content height from 64 to 8192 pixels. Width follows the selected aspect. The drawable must also fit within 8192 × 8192."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.accessibilityLabel = @"Output height";
        field.text = [NSString stringWithFormat:@"%ld",(long)TOTKLauncherCustomOutputHeight(NSUserDefaults.standardUserDefaults)];
    }];
    BOOL (^valid)(NSString *) = ^BOOL(NSString *text) {
        if (!text.length || text.length > 4 || [text rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return NO;
        NSInteger height = text.integerValue;
        if (height < 64 || height > 8192 || height % 2) return NO;
        CGSize size = self.view.window ? self.view.window.bounds.size : self.view.bounds.size;
        double ratio = MAX(size.width,size.height) / MAX(1,MIN(size.width,size.height));
        BOOL full = self.fullDisplayAvailable && [TOTKLauncherAspect(NSUserDefaults.standardUserDefaults) isEqual:@"display"];
        double contentRatio = full ? ratio : 16.0 / 9.0;
        double drawableHeight = height * fmax(1.0,contentRatio / ratio);
        return drawableHeight <= 8192 && drawableHeight * ratio <= 8192;
    };
    __weak UIAlertController *weakAlert = alert;
    UIAlertAction *done = [UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; NSString *text = weakAlert.textFields.firstObject.text;
        if (valid(text)) [self save:^(NSUserDefaults *defaults) {
            [defaults setInteger:text.integerValue forKey:@"TOTK_LAUNCHER_CUSTOM_OUTPUT_HEIGHT"];
            [defaults setObject:@"custom" forKey:@"TOTK_LAUNCHER_DISPLAY_OUTPUT"];
        } resetScene:NO];
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
        for (NSString *mode in modes) [titles addObject:[mode isEqual:@"custom"] ? @"Custom…" : [self outputTitle:mode]];
        [self choose:titles path:path selected:^(NSUInteger index) {
            if ([modes[index] isEqual:@"custom"]) { [self customOutput]; return; }
            [self save:^(NSUserDefaults *defaults) { [defaults setObject:modes[index] forKey:@"TOTK_LAUNCHER_DISPLAY_OUTPUT"]; } resetScene:NO];
        }];
    } else if ([row isEqual:@"Game canvas"]) {
        TOTKGraphicsPlan plan;
        unsigned inputHeight = [self graphicsPlan:&plan] ? plan.inputHeight : 1080;
        NSMutableArray *heights = [NSMutableArray arrayWithObject:@0];
        NSMutableArray *titles = [NSMutableArray arrayWithObject:@"Match input"];
        for (NSNumber *height in @[@900,@1080]) if (height.unsignedIntValue >= inputHeight) {
            [heights addObject:height]; [titles addObject:[NSString stringWithFormat:@"%@ high",height]];
        }
        [self choose:titles path:path selected:^(NSUInteger index) {
            [self save:^(NSUserDefaults *defaults) { [defaults setInteger:[heights[index] integerValue] forKey:@"TOTK_LAUNCHER_GAME_CANVAS_HEIGHT"]; } resetScene:NO];
        }];
    } else if ([row isEqual:@"Multiplier"]) {
        TOTKResolutionFactor *factor = [TOTKResolutionFactor new];
        factor.factor = TOTKLauncherUpscaleFactor(NSUserDefaults.standardUserDefaults);
        factor.saved = ^(double value) { [self save:^(NSUserDefaults *defaults) { [defaults setDouble:value forKey:@"TOTK_LAUNCHER_UPSCALE_FACTOR"]; } resetScene:NO]; };
        [self.navigationController pushViewController:factor animated:YES];
    } else {
        NSArray *stages = runtime_ios_spatial_upscaling_supported() ? TOTKLauncherScalerStages() : @[@"game"];
        NSMutableArray *titles = [NSMutableArray array];
        for (NSString *stage in stages) [titles addObject:[self scalerTitle:stage]];
        [self choose:titles path:path selected:^(NSUInteger index) {
            [self save:^(NSUserDefaults *defaults) {
                [defaults setObject:stages[index] forKey:@"TOTK_LAUNCHER_SCALER_STAGE"];
                [defaults setBool:[stages[index] isEqual:@"scene-output"] forKey:@"TOTK_LAUNCHER_SPATIAL_UPSCALING"];
            } resetScene:NO];
        }];
    }
}
@end
