#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Trusted native read-only title-format validator. Never chosen by imported
/// JSON. It receives an already private, bounded, hash-checked replacement.
typedef BOOL (^CanopySaveValidator)(NSURL *privateStagedDirectory,
    NSError * _Nullable * _Nullable error);
/// Native constructor policy only: approves this exact selected-file edit.
/// Must validate original/replacement semantics and integrity, never mutate or
/// reenter the store. Imported metadata/UI cannot authorize an editor.
typedef BOOL (^CanopySaveEditValidator)(NSString *relativePath, NSData *original,
    NSData *replacement, NSError * _Nullable * _Nullable error);
/// Private immutable selected bytes from a bounded whole-tree snapshot. The
/// token belongs only to its original store instance/title/profile and slot.
@interface CanopySaveEditPreview : NSObject
@property(nonatomic,readonly) NSString *relativePath;
@property(nonatomic,readonly) NSData *originalData;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Serialized, synchronous private save storage. Run transfers on a host-owned
/// serial worker queue. The process holds an exclusive profile lock until this
/// object is released. No account identity bytes are created, imported or copied.
/// Root must exist privately, or its immediate parent must already exist as
/// an owned private directory. Intermediate directories are never created.
@interface CanopySaveStore : NSObject
- (nullable instancetype)initWithRootURL:(NSURL *)root titleID:(NSString *)titleID
                              profileID:(NSString *)profileID error:(NSError **)error;
- (nullable instancetype)initWithRootURL:(NSURL *)root titleID:(NSString *)titleID
    profileID:(NSString *)profileID externalValidator:(nullable CanopySaveValidator)validator
        error:(NSError **)error;
/// Existing initializers supply no edit validator and cannot Apply edits.
- (nullable instancetype)initWithRootURL:(NSURL *)root titleID:(NSString *)titleID
    profileID:(NSString *)profileID externalValidator:(nullable CanopySaveValidator)validator
    editValidator:(nullable CanopySaveEditValidator)editValidator error:(NSError **)error;
@property(nonatomic, readonly) BOOL editingSupported;
/// Whole-tree copy/CAS observation; slot must be slot_00...slot_05. One preview
/// per store. No source path, account file or publication capability is exposed.
- (nullable CanopySaveEditPreview *)previewEditForSlot:(NSString *)slot error:(NSError **)error;
/// Requires BOTH constructor validators, unchanged active/snapshot manifests,
/// unsealed/no-recovery state, then existing backup/journal publication. A
/// production TOTK reference-family candidate has no approved edit validator.
- (BOOL)applyEditPreview:(CanopySaveEditPreview *)preview replacementData:(NSData *)data error:(NSError **)error;
- (BOOL)discardEditPreview:(CanopySaveEditPreview *)preview error:(NSError **)error;
@property(nonatomic, readonly) NSURL *activeDirectoryURL;
@property(nonatomic, readonly) NSURL *accountIdentityDirectoryURL;
/// Nonblocking atomic status mirrors; safe to read from the UI during a copy.
/// Actual permission to mutate is always rechecked by the serialized methods.
@property(nonatomic, readonly) BOOL sealed;
@property(nonatomic, readonly) BOOL recoveryRequired;
/// Old initializer has no validator and refuses external imports. Internal
/// opaque export/backup/restore remain available without semantic claims.
@property(nonatomic, readonly) BOOL externalImportSupported;
/// The runtime must acquire this token before exposing active saves to writers.
/// Keep this store alive until genuine teardown has stopped every save writer.
/// A failed startup may release its token only after the same guarantee holds.
/// A process crash releases its kernel lock; no stale on-disk session seal exists.
- (nullable NSString *)sealForSession:(NSError **)error;
- (BOOL)finishSessionWithToken:(NSString *)token error:(NSError **)error;
/// Transfers are refused while sealed. Accepts only this store's versioned
/// manifest+data format with matching title/profile and checked file hashes.
/// The caller coordinates external provider URLs and balances security scope
/// around this synchronous operation. Internal storage is always private.
/// External replacement additionally requires the trusted title validator.
/// Backup/export/restore alone do not validate a title's save format.
/// Raw save folders and semantic editing require a separate real title validator.
/// Limits:64MiB/file,512MiB/transfer,10000 entries,12 levels,16 retained backups.
/// Unsupported names, ASCII case collisions and account.uid files are refused.
- (nullable NSURL *)exportToDirectory:(NSURL *)directory error:(NSError **)error;
- (BOOL)importExportURL:(NSURL *)source error:(NSError **)error;
/// Raw folder replacement is available only with the constructor's trusted
/// title validator. The source is copied privately, validated and rehashed
/// before creating a backup or publishing. Same provider-scope rules apply.
- (BOOL)importRawDirectoryURL:(NSURL *)source error:(NSError **)error;
- (nullable NSString *)backup:(NSError **)error;
- (nullable NSArray<NSDictionary<NSString *, id> *> *)backups:(NSError **)error;
- (BOOL)restoreBackup:(NSString *)identifier error:(NSError **)error;
- (BOOL)removeBackup:(NSString *)identifier error:(NSError **)error;
/// Recovery rolls an uncommitted transaction back to its verified old backup,
/// or verifies/finalizes a durable committed save whose cleanup was interrupted.
/// Then resumes only an explicitly recorded backup retirement after verifying
/// every surviving path, inode and file hash. Unknown/corrupt backups and
/// retirement records are preserved; missing prepared targets are not success.
/// On ambiguous I/O preserve quarantine; never assume active stayed unchanged.
- (BOOL)recover:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
