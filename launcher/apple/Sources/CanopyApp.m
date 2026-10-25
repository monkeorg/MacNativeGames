#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "CanopyLibrary.h"
#include "mng_file.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

@interface CanopyViewController : UITableViewController <UIDocumentPickerDelegate>
@end

@implementation CanopyViewController {
    CanopyLibrary *_library;
    BOOL _busy;
    NSString *_loadFailure;
    NSString *_notice;
    UIBarButtonItem *_inspectButton;
    UIActivityIndicatorView *_spinner;
    NSFileCoordinator *_coordinator;
    NSUInteger _operationToken;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Canopy";
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 90;
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    _library = [[CanopyLibrary alloc] initWithDirectoryURL:[support URLByAppendingPathComponent:@"Canopy" isDirectory:YES]];
    NSError *error = nil;
    if (![_library load:&error]) _loadFailure = error.localizedDescription;
    _inspectButton = [[UIBarButtonItem alloc] initWithTitle:@"Inspect file" style:UIBarButtonItemStylePlain target:self action:@selector(inspectFile)];
    _inspectButton.accessibilityHint = @"Select an NSP or XCI container to inspect its metadata.";
    self.navigationItem.rightBarButtonItem = _inspectButton;
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.accessibilityLabel = @"Inspecting container";
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appDidEnterBackground:)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
    [self refresh];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)refresh {
    _inspectButton.enabled = !_busy && !_library.recoveryRequired;
    self.navigationItem.leftBarButtonItem = _library.recoveryRequired ?
        [[UIBarButtonItem alloc] initWithTitle:@"Reset metadata" style:UIBarButtonItemStylePlain target:self action:@selector(confirmReset)] : nil;
    if (_busy) {
        [_spinner startAnimating];
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:_spinner];
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Cancel inspection"
            style:UIBarButtonItemStylePlain target:self action:@selector(cancelInspection)];
    } else { [_spinner stopAnimating]; self.navigationItem.rightBarButtonItem = _inspectButton; }
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section; return MAX((NSInteger)_library.records.count, 1);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section; return _library.records.count ? @"Inspected containers" : nil;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    if (!_library.records.count) return nil;
    NSString *explanation = @"Metadata only. Container inspection does not verify authenticity, completeness or game compatibility. Gameplay is unavailable.";
    return _notice ? [NSString stringWithFormat:@"%@\n\n%@", _notice, explanation] : explanation;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    if (_library.records.count == 0) {
        UITableViewCell *empty = [tableView dequeueReusableCellWithIdentifier:@"empty"];
        if (!empty) empty = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"empty"];
        UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
        content.image = [UIImage imageNamed:@"Canopy.png"];
        content.imageProperties.maximumSize = CGSizeMake(80, 80);
        content.text = _library.recoveryRequired ? @"Your library needs attention" : (_busy ? @"Inspecting your container" : @"A clear view of your files");
        content.secondaryText = _loadFailure ?: _notice ?: (_busy ? @"Reading container metadata. Your source file stays unchanged." :
            @"Inspect an NSP or XCI file to add its metadata here. Canopy does not copy your game files or run games.");
        content.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
        content.textProperties.numberOfLines = 0;
        content.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        content.secondaryTextProperties.numberOfLines = 0;
        content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        empty.contentConfiguration = content;
        empty.selectionStyle = UITableViewCellSelectionStyleNone;
        return empty;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"container"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"container"];
    NSDictionary *record = _library.records[(NSUInteger)path.row];
    cell.textLabel.text = record[@"displayName"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = @"Container inspected • gameplay unavailable";
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@. Container inspected. Gameplay unavailable.", record[@"displayName"]];
    cell.accessibilityHint = @"Shows the inspection metadata.";
    return cell;
}
- (void)showMessage:(NSString *)message title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    if (self.presentedViewController) {
        [self dismissViewControllerAnimated:YES completion:^{ [self presentViewController:alert animated:YES completion:nil]; }];
    } else [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (_busy || _library.records.count == 0) return;
    NSDictionary *record = _library.records[(NSUInteger)path.row];
    NSString *size = [NSByteCountFormatter stringFromByteCount:[record[@"sourceSize"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile];
    NSString *message = [NSString stringWithFormat:@"%@ container\n%@\n%@ entries in the inspected partition\nInspected %@\n\nOnly this metadata is stored. The source file is not retained, copied, decrypted or opened again. Inspection does not verify content hashes or game compatibility. Gameplay is unavailable.",
        record[@"format"], size, record[@"entryCount"], record[@"date"]];
    [self showMessage:message title:record[@"displayName"]];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    if (_busy || _library.records.count == 0) return nil;
    NSDictionary *record = _library.records[(NSUInteger)path.row];
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Remove"
        handler:^(UIContextualAction *action, UIView *view, void (^completion)(BOOL)) {
        (void)action; (void)view; completion(NO);
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Remove metadata?"
            message:@"Only this library record will be removed. Your source file is unchanged." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *selected) {
            (void)selected; if (self->_busy) return; NSError *error = nil;
            if (![self->_library removeIdentifier:record[@"id"] error:&error]) [self showMessage:error.localizedDescription title:@"Could not remove metadata"];
            [self refresh];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }];
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[remove]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}
- (void)confirmReset {
    if (_busy) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset library metadata?"
        message:@"The unreadable index will be replaced with an empty library. This cannot be undone. No source files or game data will be changed."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset metadata" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *selected) {
        (void)selected; NSError *error = nil;
        if ([self->_library reset:&error]) self->_loadFailure = nil;
        else [self showMessage:error.localizedDescription title:@"Could not reset metadata"];
        [self refresh];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)inspectFile {
    if (_busy || _library.recoveryRequired || self.presentedViewController) return;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:NO];
    picker.allowsMultipleSelection = NO; picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { (void)controller; }
- (void)cancelInspection {
    if (!_busy) return;
    ++_operationToken;
    [_coordinator cancel];
    _coordinator = nil;
    _busy = NO;
    _notice = @"Inspection canceled. Its result will be discarded. The file provider may still be finishing its read.";
    [self refresh];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"Inspection canceled. No metadata will be added.");
}
- (void)appDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    [self cancelInspection];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    if (_busy || _library.recoveryRequired || urls.count != 1) return;
    NSURL *source = urls.firstObject;
    NSString *extension = source.pathExtension.lowercaseString;
    if (![@[@"nsp", @"xci"] containsObject:extension]) {
        [self showMessage:@"Choose a file with an .nsp or .xci extension." title:@"Unsupported file"]; return;
    }
    NSString *displayName = source.lastPathComponent;
    if (displayName.length > 200 || [displayName rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        [self showMessage:@"Choose a file with a name of at most 200 characters and no control characters." title:@"Unsupported filename"]; return;
    }
    _notice = nil;
    _busy = YES;
    NSUInteger token = ++_operationToken;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    _coordinator = coordinator;
    [self refresh];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL scoped = [source startAccessingSecurityScopedResource];
        __block NSString *failure = nil;
        __block NSString *format = nil;
        __block uint64_t sourceSize = 0;
        __block NSUInteger entryCount = 0;
        NSError *coordinationError = nil;
        [coordinator coordinateReadingItemAtURL:source options:0 error:&coordinationError byAccessor:^(NSURL *readURL) {
            int descriptor = open(readURL.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
            if (descriptor < 0) { failure = @"The selected file could not be opened for reading. It may be unavailable or access may have expired."; return; }
            struct stat attributes;
            struct mng_inventory inventory = {0};
            if (fstat(descriptor, &attributes) != 0 || !S_ISREG(attributes.st_mode) || attributes.st_size < 0) failure = @"Choose a regular file. Folders, links and special files cannot be inspected.";
            else {
                enum mng_status status = mng_inspect_fd(descriptor, &inventory);
                struct stat after;
                if (status == MNG_OK && (fstat(descriptor, &after) != 0 ||
                    attributes.st_dev != after.st_dev || attributes.st_ino != after.st_ino ||
                    attributes.st_size != after.st_size ||
                    attributes.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec ||
                    attributes.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec ||
                    attributes.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec ||
                    attributes.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec)) status = MNG_IO;
                if (status == MNG_OK) {
                    sourceSize = (uint64_t)attributes.st_size;
                    entryCount = inventory.count;
                    format = inventory.kind == MNG_NSP ? @"NSP" : inventory.kind == MNG_XCI ? @"XCI" : nil;
                    if (!format) failure = @"The file is not a supported NSP or XCI container.";
                } else if (status == MNG_LIMIT) failure = @"The container exceeds Canopy's safe inspection limits.";
                else if (status == MNG_IO) failure = @"The file could not be read consistently. It may have changed or become unavailable. Try again when the file is available locally.";
                else if (status == MNG_NOMEM) failure = @"There is not enough memory to inspect this container.";
                else failure = @"The file is malformed or is not a supported NSP or XCI container. No metadata was added.";
            }
            mng_inventory_free(&inventory);
            close(descriptor);
        }];
        if (coordinationError) failure = @"The file provider could not make this file available. No metadata was added.";
        if (scoped) [source stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != self->_operationToken || !self->_busy) return;
            self->_coordinator = nil;
            self->_busy = NO;
            NSError *saveError = nil;
            if (!failure && format && ![self->_library addDisplayName:displayName format:format sourceSize:sourceSize entryCount:entryCount error:&saveError]) failure = saveError.localizedDescription;
            if (!failure && !format) failure = @"The selected file could not be inspected. No metadata was added.";
            [self refresh];
            if (failure) [self showMessage:failure title:@"Inspection unavailable"];
            else UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"Container inspected. Metadata added to your library. Gameplay is unavailable.");
        });
    });
}
@end

@interface CanopySceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation CanopySceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[[CanopyViewController alloc] initWithStyle:UITableViewStyleInsetGrouped]];
    [self.window makeKeyAndVisible];
}
@end

@interface CanopyAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation CanopyAppDelegate
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)application; (void)options;
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Canopy" sessionRole:session.role];
    configuration.delegateClass = CanopySceneDelegate.class;
    return configuration;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(CanopyAppDelegate.class)); }
}
