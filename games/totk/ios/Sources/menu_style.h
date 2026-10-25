#pragma once
#import <UIKit/UIKit.h>

static inline BOOL TOTKSettingsSolidBackground(void) {
    return UIAccessibilityIsReduceTransparencyEnabled() || UIAccessibilityDarkerSystemColorsEnabled();
}

static inline UIView *TOTKSettingsBackground(void) {
    if (!TOTKSettingsSolidBackground()) {
        if (@available(iOS 26.0, *)) {
            UIGlassEffect *effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
            effect.tintColor = [UIColor.systemBackgroundColor colorWithAlphaComponent:0.16];
            return [[UIVisualEffectView alloc] initWithEffect:effect];
        }
    }
    UIView *background = [UIView new];
    background.backgroundColor = UIColor.systemGroupedBackgroundColor;
    return background;
}

static inline void TOTKStyleSettingsPage(UITableViewController *page) {
    UITableView *table = page.tableView;
    table.backgroundColor = UIColor.clearColor;
    table.backgroundView = TOTKSettingsBackground();
    table.cellLayoutMarginsFollowReadableWidth = YES;
    table.rowHeight = UITableViewAutomaticDimension;
    table.estimatedRowHeight = 56;
    table.sectionHeaderTopPadding = 12;
    table.separatorColor = [UIColor.separatorColor colorWithAlphaComponent:0.35];
    page.viewRespectsSystemMinimumLayoutMargins = YES;
    page.navigationController.navigationBar.prefersLargeTitles = NO;
}

static inline void TOTKStyleSettingsCell(UITableViewCell *cell, NSString *symbol) {
    cell.backgroundColor = TOTKSettingsSolidBackground()
        ? UIColor.secondarySystemGroupedBackgroundColor
        : [UIColor.secondarySystemGroupedBackgroundColor colorWithAlphaComponent:0.78];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.numberOfLines = 0;
    cell.imageView.image = symbol.length ? [UIImage systemImageNamed:symbol withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular]] : nil;
    cell.imageView.tintColor = UIColor.systemBlueColor;
    cell.layoutMargins = UIEdgeInsetsMake(12,18,12,18);
    BOOL hasMinimum = NO;
    for (NSLayoutConstraint *constraint in cell.contentView.constraints)
        if ([constraint.identifier isEqual:@"TOTKSettingsMinimumHeight"]) hasMinimum = YES;
    if (!hasMinimum) {
        NSLayoutConstraint *minimum = [cell.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:56];
        minimum.identifier = @"TOTKSettingsMinimumHeight";
        minimum.active = YES;
    }
}
