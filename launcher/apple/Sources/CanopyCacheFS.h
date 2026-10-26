#import <Foundation/Foundation.h>
#include <sys/stat.h>
NS_ASSUME_NONNULL_BEGIN
/* Internal descriptor-only helpers. The caller owns a fixed private root and
 * its genuine exclusive operation lock. No imported URL grants deletion. */
BOOL CCFPrivate(int fd,BOOL directory);
BOOL CCFStable(const struct stat *a,const struct stat *b);
BOOL CCFWalk(int directory,unsigned depth,uint64_t *bytes,uint64_t *count,BOOL remove,BOOL strict,BOOL (^ _Nullable cancelled)(void));
BOOL CCFWalkExcept(int directory,uint64_t *bytes,uint64_t *count,BOOL remove,NSString * _Nullable retainedLeaf);
int CCFChild(int parent,const char *leaf);
NSData * _Nullable CCFData(int parent,const char *leaf,size_t limit);
NSString * _Nullable CCFDigest(NSData * _Nullable data);
BOOL CCFHex(id _Nullable value,NSUInteger length);
typedef NS_ENUM(unsigned,CCFFamily){CCFMKIdentity=1,CCFMKRuntime=2,CCFRomFS=3};
/* Each family uses its own fixed retirement namespace. validate runs only for
 * a still canonical target, before recording and again before moving it. */
typedef BOOL (^CCFValidation)(int parent,int target,NSString *identifier);
BOOL CCFRecover(int root,CCFFamily family,NSString *title,CCFValidation validate,NSString * _Nullable * _Nullable completed);
BOOL CCFRetire(int root,CCFFamily family,NSString *title,NSString *identifier,CCFValidation validate);
NS_ASSUME_NONNULL_END
