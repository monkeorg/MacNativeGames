#import "save_validation.h"

static BOOL failure(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"TOTKSaveStore" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}

BOOL TOTKSaveValidateDirectory(NSURL *root, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *names = [fm contentsOfDirectoryAtPath:root.path error:error];
    if (!names) return NO;
    unsigned slots = 0;
    for (NSString *name in names) {
        if (![name hasPrefix:@"slot_"]) continue;
        if (name.length != 7 || [name characterAtIndex:5] != '0' || [name characterAtIndex:6] < '0' || [name characterAtIndex:6] > '5')
            return failure(error,@"The folder contains an unsupported save slot.");
        for (NSString *required in @[@"progress.sav",@"caption.sav",@"footprint.sav",@"direct_file_save_related.sav"]) {
            NSURL *file = [[root URLByAppendingPathComponent:name] URLByAppendingPathComponent:required];
            NSDictionary *attrs = [fm attributesOfItemAtPath:file.path error:error];
            if (![attrs[NSFileType] isEqual:NSFileTypeRegular] || ![attrs[NSFileSize] unsignedLongLongValue])
                return failure(error,@"Each slot needs progress.sav, caption.sav, footprint.sav, and direct_file_save_related.sav.");
        }
        slots++;
    }
    if (!slots) return failure(error,@"Select the save folder containing slot_00 through slot_05, not one slot or a profile folder.");
    if ([names containsObject:@"account.uid"]) return failure(error,@"Import the console save contents, not the account profile.");
    return YES;
}
