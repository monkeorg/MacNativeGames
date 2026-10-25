#import "settings_choices.h"
#import "menu_style.h"

@interface TOTKSettingsChoices : UITableViewController
@property(nonatomic, copy) NSArray<NSString *> *choices;
@property(nonatomic) NSUInteger selectedIndex;
@property(nonatomic, copy) NSIndexSet *disabled;
@property(nonatomic, copy) void (^selection)(NSUInteger);
@end

@implementation TOTKSettingsChoices {
    BOOL _didSelect;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    TOTKStyleSettingsPage(self);
    self.tableView.backgroundView = nil;
    self.tableView.backgroundColor = UIColor.clearColor;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.choices.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    TOTKStyleSettingsCell(cell,@"");
    NSString *choice = self.choices[path.row];
    BOOL selected = (NSUInteger)path.row == self.selectedIndex;
    BOOL disabled = [self.disabled containsIndex:path.row];
    cell.textLabel.text = choice;
    cell.tintColor = UIColor.systemBlueColor;
    cell.textLabel.textColor = disabled ? UIColor.tertiaryLabelColor : selected ? UIColor.systemBlueColor : UIColor.labelColor;
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.selectionStyle = disabled ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    cell.userInteractionEnabled = !disabled;
    cell.isAccessibilityElement = YES;
    cell.accessibilityIdentifier = [NSString stringWithFormat:@"TOTKChoice.%@.%ld",self.title,(long)path.row];
    cell.accessibilityLabel = choice;
    cell.accessibilityValue = [choice stringByAppendingString:disabled ? @", unavailable" : selected ? @", selected" : @""];
    cell.accessibilityTraits = UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0) |
        (disabled ? UIAccessibilityTraitNotEnabled : 0);
    return cell;
}
- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    return _didSelect || [self.disabled containsIndex:path.row] ? nil : path;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (_didSelect || [self.disabled containsIndex:path.row]) return;
    UINavigationController *navigation = self.navigationController;
    if (navigation.topViewController != self) return;
    _didSelect = YES;
    void (^selection)(NSUInteger) = self.selection;
    NSUInteger index = path.row;
    __block BOOL delivered = NO;
    void (^finish)(void) = ^{
        if (delivered) return;
        delivered = YES;
        if (selection) selection(index);
    };
    [navigation popViewControllerAnimated:YES];
    id<UIViewControllerTransitionCoordinator> transition = navigation.transitionCoordinator;
    if (!transition || ![transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context; finish();
    }]) finish();
}
@end

void TOTKChooseSetting(UIViewController *owner, NSString *title, NSArray<NSString *> *choices,
                       NSString *selected, NSIndexSet *disabled, void (^selection)(NSUInteger)) {
    UINavigationController *navigation = owner.navigationController;
    if (!navigation) return;
    TOTKSettingsChoices *page = [[TOTKSettingsChoices alloc] initWithStyle:UITableViewStyleInsetGrouped];
    page.title = title;
    page.choices = choices;
    page.selectedIndex = selected ? [choices indexOfObject:selected] : NSNotFound;
    page.disabled = disabled ?: NSIndexSet.indexSet;
    page.selection = selection;
    [navigation pushViewController:page animated:YES];
}
