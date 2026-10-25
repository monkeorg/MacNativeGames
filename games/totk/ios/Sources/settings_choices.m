#import "settings_choices.h"
#import "menu_style.h"

@interface TOTKSettingsChoices : UITableViewController <UIPopoverPresentationControllerDelegate>
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
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.selectedIndex < self.choices.count)
        [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:self.selectedIndex inSection:0]
                             atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.choices.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.title;
}
- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller
    traitCollection:(UITraitCollection *)traits {
    (void)controller; (void)traits;
    return UIModalPresentationNone;
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
    if (!self.presentingViewController || self.isBeingDismissed) return;
    _didSelect = YES;
    void (^selection)(NSUInteger) = self.selection;
    NSUInteger index = path.row;
    self.selection = nil;
    [self dismissViewControllerAnimated:YES completion:^{
        if (selection) selection(index);
    }];
}
@end

static UITableView *TOTKSettingsTable(UIView *view) {
    if ([view isKindOfClass:UITableView.class]) return (UITableView *)view;
    for (UIView *child in view.subviews) {
        UITableView *table = TOTKSettingsTable(child);
        if (table) return table;
    }
    return nil;
}

void TOTKChooseSetting(UIViewController *owner, NSString *title, NSArray<NSString *> *choices,
                       NSString *selected, NSIndexSet *disabled, void (^selection)(NSUInteger)) {
    if (!choices.count || owner.presentedViewController || !owner.view.window) return;
    TOTKSettingsChoices *page = [[TOTKSettingsChoices alloc] initWithStyle:UITableViewStyleInsetGrouped];
    page.title = title;
    page.choices = choices;
    page.selectedIndex = selected ? [choices indexOfObject:selected] : NSNotFound;
    page.disabled = disabled ?: NSIndexSet.indexSet;
    page.selection = selection;
    page.modalPresentationStyle = UIModalPresentationPopover;
    CGFloat width = MIN(360, MAX(240, CGRectGetWidth(owner.view.bounds) - 32));
    CGFloat height = MIN(420, MAX(120, CGRectGetHeight(owner.view.bounds) - 64));
    page.preferredContentSize = CGSizeMake(width, MIN(height, 56 * choices.count + 64));
    UIPopoverPresentationController *popover = page.popoverPresentationController;
    popover.delegate = page;
    popover.sourceView = owner.view;
    popover.sourceRect = CGRectMake(CGRectGetMidX(owner.view.bounds), CGRectGetMidY(owner.view.bounds), 1, 1);
    popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
    UITableView *table = TOTKSettingsTable(owner.view);
    NSIndexPath *selectedPath = table.indexPathForSelectedRow;
    UITableViewCell *anchor = selectedPath ? [table cellForRowAtIndexPath:selectedPath] : nil;
    // Callers may deselect the row before opening its choices.
    for (UITableViewCell *cell in table.visibleCells) {
        if ([cell.textLabel.text isEqualToString:title]) { anchor = cell; break; }
    }
    if (anchor) {
        popover.sourceView = anchor;
        popover.sourceRect = anchor.bounds;
    }
    [owner presentViewController:page animated:YES completion:nil];
}
