#import <Foundation/Foundation.h>

/* Only used before the game starts. Transfers contain the console save contents, never account.uid. */
@interface TOTKSaveStore : NSObject
- (instancetype)initWithActiveURL:(NSURL *)active backupsURL:(NSURL *)backups;
- (BOOL)sealForPlay;
- (NSURL *)exportToDirectory:(NSURL *)directory error:(NSError **)error;
- (NSURL *)backup:(NSError **)error;
- (NSArray<NSURL *> *)backups:(NSError **)error;
- (BOOL)importDirectory:(NSURL *)source error:(NSError **)error;
- (BOOL)restore:(NSURL *)backup error:(NSError **)error;
- (BOOL)applyEditedProgress:(NSData *)data slot:(NSString *)slot expectedDirectory:(NSURL *)snapshot error:(NSError **)error;
@end
