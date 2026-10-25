#import "metal_hud_settings.h"
#import "launcher_settings.h"
#import "menu_style.h"
#import "settings_choices.h"

@implementation TOTKMetalHUDSettings {
    void (^_changed)(void);
}
- (instancetype)initWithChanged:(void (^)(void))changed {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) { _changed = [changed copy]; self.title = @"Metal HUD"; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    TOTKStyleSettingsPage(self);
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}
- (NSArray<NSString *> *)alignmentTitles {
    return @[@"Top left",@"Top center",@"Top right",@"Center left",@"Center",@"Center right",
        @"Bottom left",@"Bottom center",@"Bottom right"];
}
- (NSString *)metricTitle:(NSString *)metric {
    return @{@"fps":@"Frame rate",@"frameinterval":@"Frame interval",@"gputime":@"GPU time",
        @"metalcpu":@"Metal CPU time",@"memory":@"Memory",@"device":@"Device",
        @"layersize":@"Drawable size",@"layerscale":@"Drawable scale",@"fpsgraph":@"Frame rate graph",
        @"frameintervalgraph":@"Frame interval graph",@"frameintervalhistogram":@"Frame interval histogram",
        @"presentdelay":@"Present delay",@"gputimeline":@"GPU timeline",@"shaders":@"Shader compilation",
        @"framenumber":@"Frame number",@"disk":@"Disk use",@"toplabeledcommandbuffers":@"Top command buffers",
        @"toplabeledencoders":@"Top encoders"}[metric];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? 4 : section == 1 ? TOTKLauncherMetalHUDMetricOptions().count : 3;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; return (@[@"Appearance",@"Metrics",@"Advanced"])[section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"Changes apply immediately. Scale follows drawable width, with a minimum HUD width of 300 pixels.";
    if (section == 1) return @"Select at least one metric. Availability depends on the device and Metal workload. GPU timeline and top encoders may need encoder timing.";
    return @"Encoder timing and performance insights add measurement cost. Metric range covers the last 1200 frames. HUD logging stays off.";
}
- (void)save:(void (^)(NSUserDefaults *))update {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *before = TOTKLauncherMetalHUDProperties(defaults);
    update(defaults);
    NSDictionary *after = TOTKLauncherMetalHUDProperties(defaults);
    [self.tableView reloadData];
    if (![before isEqual:after] && _changed) _changed();
}
- (void)toggle:(UISwitch *)sender {
    NSArray *keys = @[@"TOTK_LAUNCHER_METAL_HUD",@"TOTK_LAUNCHER_METAL_HUD_ENCODER_TIMING",
        @"TOTK_LAUNCHER_METAL_HUD_INSIGHTS",@"TOTK_LAUNCHER_METAL_HUD_RANGE"];
    [self save:^(NSUserDefaults *defaults) { [defaults setBool:sender.on forKey:keys[sender.tag]]; }];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    NSString *symbol = @"chart.bar";
    if (path.section == 1) {
        NSString *metric = TOTKLauncherMetalHUDMetricOptions()[path.row];
        cell.textLabel.text = [self metricTitle:metric];
        cell.accessoryType = [TOTKLauncherMetalHUDMetrics(defaults) containsObject:metric]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.accessibilityIdentifier = [@"metalhud.metric." stringByAppendingString:metric];
        cell.accessibilityTraits |= UIAccessibilityTraitButton;
        if (cell.accessoryType == UITableViewCellAccessoryCheckmark) cell.accessibilityTraits |= UIAccessibilityTraitSelected;
    } else if (path.section == 2 || path.row == 0) {
        BOOL advanced = path.section == 2;
        cell.textLabel.text = advanced ? (@[@"Encoder timing",@"Performance insights",@"Metric range"])[path.row] : @"Show HUD";
        UISwitch *toggle = [UISwitch new];
        toggle.tag = advanced ? path.row + 1 : 0;
        toggle.on = advanced ? (path.row == 0 ? TOTKLauncherMetalHUDEncoderTiming(defaults)
            : path.row == 1 ? TOTKLauncherMetalHUDInsights(defaults) : TOTKLauncherMetalHUDRange(defaults)) : TOTKLauncherMetalHUD(defaults);
        toggle.accessibilityLabel = cell.textLabel.text;
        toggle.accessibilityIdentifier = [NSString stringWithFormat:@"metalhud.toggle.%ld",(long)toggle.tag];
        [toggle addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        symbol = advanced ? @"gauge.with.dots.needle.67percent" : @"chart.xyaxis.line";
    } else {
        cell.textLabel.text = (@[@"",@"Position",@"Scale",@"Opacity"])[path.row];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (path.row == 1) {
            NSUInteger index = [TOTKLauncherMetalHUDAlignments() indexOfObject:TOTKLauncherMetalHUDAlignment(defaults)];
            cell.detailTextLabel.text = self.alignmentTitles[index];
            symbol = @"viewfinder";
        } else {
            double value = path.row == 2 ? TOTKLauncherMetalHUDScale(defaults) : TOTKLauncherMetalHUDOpacity(defaults);
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%",value * 100];
            symbol = path.row == 2 ? @"arrow.up.left.and.arrow.down.right" : @"circle.lefthalf.filled";
        }
        cell.accessibilityIdentifier = [@"metalhud." stringByAppendingString:cell.textLabel.text.lowercaseString];
    }
    TOTKStyleSettingsCell(cell,symbol);
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 1) {
        NSString *metric = TOTKLauncherMetalHUDMetricOptions()[path.row];
        [self save:^(NSUserDefaults *defaults) {
            NSMutableArray *metrics = [TOTKLauncherMetalHUDMetrics(defaults) mutableCopy];
            if ([metrics containsObject:metric]) { if (metrics.count > 1) [metrics removeObject:metric]; }
            else [metrics addObject:metric];
            [defaults setObject:metrics forKey:@"TOTK_LAUNCHER_METAL_HUD_METRICS"];
        }];
        return;
    }
    if (path.section != 0 || path.row == 0) return;
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:path];
    if (path.row == 1) {
        TOTKChooseSetting(self,@"Position",self.alignmentTitles,cell.detailTextLabel.text,nil,^(NSUInteger index) {
            [self save:^(NSUserDefaults *defaults) {
                [defaults setObject:TOTKLauncherMetalHUDAlignments()[index] forKey:@"TOTK_LAUNCHER_METAL_HUD_ALIGNMENT"];
            }];
        });
    } else {
        NSArray<NSNumber *> *values = path.row == 2 ? @[@0,@0.1,@0.15,@0.2,@0.25,@0.3,@0.4,@0.5,@0.75,@1]
            : @[@0,@0.25,@0.5,@0.75,@1];
        NSMutableArray *titles = [NSMutableArray array];
        for (NSNumber *value in values) [titles addObject:[NSString stringWithFormat:@"%.0f%%",value.doubleValue * 100]];
        TOTKChooseSetting(self,cell.textLabel.text,titles,cell.detailTextLabel.text,nil,^(NSUInteger index) {
            [self save:^(NSUserDefaults *defaults) {
                [defaults setDouble:values[index].doubleValue forKey:path.row == 2
                    ? @"TOTK_LAUNCHER_METAL_HUD_SCALE" : @"TOTK_LAUNCHER_METAL_HUD_OPACITY"];
            }];
        });
    }
}
@end
