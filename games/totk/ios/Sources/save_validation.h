#import <Foundation/Foundation.h>

/* Existing TOTK save-directory structural checks, shared without changing the
 * standalone app's validation policy. Caller first makes a private link-free
 * bounded copy. This checks supported slots/files, not editable save values. */
FOUNDATION_EXPORT BOOL TOTKSaveValidateDirectory(NSURL *root, NSError **error);
