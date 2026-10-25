#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#import "CanopyStorage.h"
#import "CanopyShaderCache.h"
#include "mng_store.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static BOOL STHex(id value,NSUInteger length) {
    return [value isKindOfClass:NSString.class] && [value length]==length &&
        [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
static BOOL STTitle(id value) {return STHex(value,16)&&![value isEqual:@"0000000000000000"];}
static NSURL *STPhysicalURL(NSURL *url) {
    if(!url.isFileURL)return nil;
    NSString *path=url.path;
    for(NSString *alias in @[@"/var",@"/tmp"])if([path isEqual:alias]||[path hasPrefix:[alias stringByAppendingString:@"/"]]) {
        path=[@"/private" stringByAppendingString:path];break;
    }
    for(NSString *part in path.pathComponents)if([part isEqual:@"."]||[part isEqual:@".."])return nil;
    return [NSURL fileURLWithPath:path isDirectory:YES];
}
static BOOL STPrivate(int fd) {
    struct stat st={0};return fd>=0&&!fstat(fd,&st)&&S_ISDIR(st.st_mode)&&st.st_uid==geteuid()&&!(st.st_mode&077);
}
static int STRoot(NSURL *url) {
    NSURL *physical=STPhysicalURL(url);if(!physical){errno=EINVAL;return -1;}
    int fd=open(physical.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW_ANY|O_CLOEXEC);
    if(fd<0)return -1;
    if(!STPrivate(fd)){close(fd);errno=EACCES;return -1;}return fd;
}
static int STChild(int parent,const char *name) {
    int fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0)return -1;
    if(!STPrivate(fd)){close(fd);errno=EACCES;return -1;}return fd;
}
static BOOL STStoreLayout(int root,BOOL *empty) {
    int jobs=STChild(root,"jobs"),jobsError=errno;
    int titles=STChild(root,"titles"),titlesError=errno;
    BOOL valid=jobs>=0&&titles>=0;
    *empty=jobs<0&&titles<0&&jobsError==ENOENT&&titlesError==ENOENT;
    if(jobs>=0)close(jobs);if(titles>=0)close(titles);return valid;
}
static void STIssue(NSMutableArray *issues,NSString *message) {
    if(issues.count<32 && ![issues containsObject:message])[issues addObject:message];
}
static NSArray<NSString *> *STNames(int directory,NSMutableArray *issues) {
    int fd=openat(directory,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    DIR *iterator=fd<0?NULL:fdopendir(fd);
    if(!iterator){if(fd>=0)close(fd);STIssue(issues,@"A storage directory could not be read. Its contents were preserved.");return nil;}
    NSMutableArray *names=[NSMutableArray new];NSUInteger count=0;BOOL ok=YES;struct dirent *entry;errno=0;
    while((entry=readdir(iterator))) {
        if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
        // Count every real entry, including unknown names and abandoned stages.
        if(++count>128){ok=NO;STIssue(issues,@"A storage list exceeds 128 entries. No entries were removed to shorten it.");break;}
        NSString *name=[NSString stringWithUTF8String:entry->d_name];
        if(name)[names addObject:name];else STIssue(issues,@"An unsupported storage name was preserved.");
        errno=0;
    }
    if(!entry&&errno){ok=NO;STIssue(issues,@"A storage directory could not be read completely. Existing data was preserved.");}
    closedir(iterator);
    return ok?[names sortedArrayUsingSelector:@selector(compare:)]:nil;
}
static NSString *STPrevious(int title,BOOL *valid) {
    int fd=openat(title,"previous",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0){*valid=errno==ENOENT;return nil;}
    struct stat before={0},after={0};char bytes[65];size_t used=0;
    BOOL ok=!fstat(fd,&before)&&S_ISREG(before.st_mode)&&before.st_nlink==1&&before.st_uid==geteuid()&&
        !(before.st_mode&077)&&before.st_size==65;
    while(ok&&used<sizeof(bytes)) {
        ssize_t n=read(fd,bytes+used,sizeof(bytes)-used);if(n<0&&errno==EINTR)continue;
        if(n<=0){ok=NO;break;}used+=(size_t)n;
    }
    if(ok)ok=!fstat(fd,&after)&&before.st_dev==after.st_dev&&before.st_ino==after.st_ino&&before.st_size==after.st_size&&
        before.st_nlink==after.st_nlink&&before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec&&
        before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec&&before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec&&
        before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec&&bytes[64]=='\n';
    close(fd);NSString *value=ok?[[NSString alloc] initWithBytes:bytes length:64 encoding:NSUTF8StringEncoding]:nil;
    *valid=STHex(value,64);return *valid?value:nil;
}
static NSString *STDigest(const unsigned char bytes[32]) {char text[65];for(unsigned i=0;i<32;i++)snprintf(text+2*i,3,"%02x",bytes[i]);return [NSString stringWithUTF8String:text];}
static NSDictionary *STAddonIntent(NSString *job,const struct mng_store_job_intent *intent) {
    return @{@"mode":@"addon",@"jobIdentifier":job,
        @"applicationID":[NSString stringWithFormat:@"%016llx",(unsigned long long)intent->application_id],
        @"baseGenerationID":[NSString stringWithUTF8String:intent->base_generation_id],
        @"addonTitleID":[NSString stringWithFormat:@"%016llx",(unsigned long long)intent->addon_title_id]};
}
static NSDictionary *STEmpty(void) {return @{@"generations":@[],@"jobs":@[],@"shaders":@[],@"issues":@[],@"complete":@YES};}
static NSError *STError(NSInteger code) {
    NSString *message=code==2?@"Storage is busy or the selected target is protected. Review current/rollback selections, active leases and retained preparation jobs before retrying.":
        code==4?@"The selected prepared assets did not pass verification. Existing data was preserved.":
        @"The storage operation could not be confirmed. It may have partially completed. Current was read again where possible; refresh before retrying.";
    return [NSError errorWithDomain:@"CanopyStorage" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSString *STAction(CanopyStorageAction action) {
    switch(action){case CanopyStorageVerifyGeneration:return @"verifyGeneration";case CanopyStorageSelectGeneration:return @"selectGeneration";
        case CanopyStorageRemoveGeneration:return @"removeGeneration";case CanopyStorageDiscardJob:return @"discardJob";
        case CanopyStorageClearShaderRuntime:return @"clearShaderRuntime";case CanopyStorageRemoveShaderIdentity:return @"removeShaderIdentity";}
    return @"unknown";
}
@interface CanopyStorage ()
- (NSDictionary *)scan;
- (NSDictionary *)runAction:(CanopyStorageAction)action identifier:(NSString *)identifier title:(NSString *)title error:(NSError **)error;
@end
@implementation CanopyStorage {
    NSURL *_prepared,*_cache;
    dispatch_queue_t _queue;
    BOOL _busy;
    NSDictionary *_snapshot;
}
- (instancetype)initWithPreparedRootURL:(NSURL *)prepared cacheRootURL:(NSURL *)cache {
    if((self=[super init])){_prepared=[STPhysicalURL(prepared) copy];_cache=[STPhysicalURL(cache) copy];
        _snapshot=STEmpty();_queue=dispatch_queue_create("org.monkeorg.canopy.storage",DISPATCH_QUEUE_SERIAL);}
    return self;
}
- (BOOL)busy {return _busy;}
- (NSDictionary *)snapshot {return _snapshot;}
- (NSDictionary *)scan {
    NSMutableArray *generations=[NSMutableArray new],*jobs=[NSMutableArray new],*shaders=[NSMutableArray new],*issues=[NSMutableArray new];
    BOOL complete=YES;
    int root=STRoot(_prepared);struct mng_store *store=NULL;
    if(root>=0) {
        BOOL empty=NO,layout=STStoreLayout(root,&empty);
        enum mng_prepare_status opened=layout?mng_store_open(root,&store):MNG_PREPARE_IO;
        if(!empty) {
        if(opened!=MNG_PREPARE_OK){complete=NO;STIssue(issues,@"Prepared storage is busy or unavailable. Existing data was preserved.");}
        else {
            int titles=STChild(root,"titles"),jobRoot=STChild(root,"jobs");
            NSArray *titleNames=titles<0?nil:STNames(titles,issues),*jobNames=jobRoot<0?nil:STNames(jobRoot,issues);
            if(!titleNames||!jobNames)complete=NO;
            for(NSString *title in titleNames) {
                if(!STTitle(title)){STIssue(issues,@"An unknown title entry was preserved.");continue;}
                int titleFD=STChild(titles,title.UTF8String);
                if(titleFD<0){STIssue(issues,@"A linked or nonprivate title entry was preserved.");continue;}
                char currentText[65]={0};NSString *current=nil,*reference=@"confirmed";BOOL previousValid=NO;
                enum mng_prepare_status status=mng_store_current(store,strtoull(title.UTF8String,NULL,16),currentText);
                if(status==MNG_PREPARE_OK)current=[NSString stringWithUTF8String:currentText];
                else {struct stat st;reference=fstatat(titleFD,"current",&st,AT_SYMLINK_NOFOLLOW)&&errno==ENOENT?@"missing":@"unavailable";}
                NSString *previous=STPrevious(titleFD,&previousValid);
                if(!previousValid){reference=@"unavailable";STIssue(issues,@"A rollback reference could not be read safely. Its data was preserved.");}
                int versions=STChild(titleFD,"generations");NSArray *names=versions<0?nil:STNames(versions,issues);
                if(!names)complete=NO;
                for(NSString *name in names) {
                    if(!STHex(name,64)){STIssue(issues,@"An unknown prepared-data entry was preserved.");continue;}
                    int version=STChild(versions,name.UTF8String);
                    if(version<0){STIssue(issues,@"A linked or nonprivate prepared-data entry was preserved.");continue;}close(version);
                    if(generations.count==128){complete=NO;STIssue(issues,@"Prepared-data rows exceed 128. Additional entries were preserved.");break;}
                    [generations addObject:@{@"titleID":title,@"identifier":name,@"current":current&&[current isEqual:name]?@YES:@NO,
                        @"previous":previous&&[previous isEqual:name]?@YES:@NO,@"referenceState":reference,
                        @"verification":@"notChecked",@"logicalAssetBytes":NSNull.null,@"executionStatus":@"unassessed"}];
                }
                if(versions>=0)close(versions);close(titleFD);
            }
            for(NSString *job in jobNames) {
                if(!STHex(job,32)){STIssue(issues,@"An unknown preparation-job entry was preserved.");continue;}
                int fd=STChild(jobRoot,job.UTF8String);
                if(fd<0){STIssue(issues,@"A linked or nonprivate preparation job was preserved.");continue;}close(fd);
                struct mng_store_job_intent intent={0};int present=0;
                enum mng_prepare_status routing=mng_store_read_job_intent(store,job.UTF8String,&intent,&present);
                NSMutableDictionary *row=[@{@"identifier":job,@"resumeKind":routing==MNG_PREPARE_OK?(present?@"addon":@"legacy"):@"unavailable"} mutableCopy];
                if(routing==MNG_PREPARE_OK&&present)row[@"resumeIntent"]=STAddonIntent(job,&intent);
                else if(routing!=MNG_PREPARE_OK)STIssue(issues,@"A preparation's resume context could not be verified. Its data was preserved; no different mode was inferred.");
                [jobs addObject:[row copy]];
            }
            if(titles>=0)close(titles);if(jobRoot>=0)close(jobRoot);
        }
        }
        mng_store_close(store);close(root);
    } else if(errno!=ENOENT){complete=NO;STIssue(issues,@"Prepared storage could not be opened privately. Existing files were preserved.");}
    int cache=STRoot(_cache);
    if(cache>=0) {
        NSArray *titles=STNames(cache,issues);if(!titles)complete=NO;
        for(NSString *title in titles) {
            if(!STTitle(title)){STIssue(issues,@"An unrelated cache entry was preserved.");continue;}
            int titleFD=STChild(cache,title.UTF8String);if(titleFD<0){STIssue(issues,@"A linked or nonprivate cache title was preserved.");continue;}
            int shaderFD=STChild(titleFD,"shader-identities"),shaderError=errno;close(titleFD);
            if(shaderFD<0){if(shaderError!=ENOENT){complete=NO;STIssue(issues,@"A shader-cache directory could not be opened privately. Existing files were preserved.");}continue;}
            NSURL *shaderURL=[[_cache URLByAppendingPathComponent:title isDirectory:YES] URLByAppendingPathComponent:@"shader-identities" isDirectory:YES];
            CanopyShaderCache *shaderCache=[[CanopyShaderCache alloc] initWithRootURL:shaderURL];
            NSError *recoveryError=nil;
            BOOL removalReconciled=[shaderCache recoverPendingRemovalWithError:&recoveryError];
            if(!removalReconciled) {
                complete=NO;STIssue(issues,@"A recorded shader-cache removal could not be reconciled. Reload or retry is required; removal may have progressed.");
            }
            NSArray *names=STNames(shaderFD,issues);if(!names)complete=NO;
            for(NSString *name in names) {
                if([name isEqual:@".shader.lock"] || (removalReconciled && [name isEqual:@".shader-retirement"]))continue;
                if(!STHex(name,64)){STIssue(issues,@"Unpublished or unknown shader-cache entries were preserved.");continue;}
                int folder=STChild(shaderFD,name.UTF8String);
                if(folder<0){STIssue(issues,@"A linked or nonprivate shader identity was preserved.");continue;}close(folder);
                if(shaders.count==128){complete=NO;STIssue(issues,@"Shader rows exceed 128. Additional entries were preserved.");break;}
                NSError *failure=nil;NSDictionary *usage=[shaderCache usageForIdentityHash:name titleID:title error:&failure];
                [shaders addObject:@{@"titleID":title,@"identifier":name,@"usageState":usage?@"available":@"unavailable",
                    @"seedBytes":usage[@"seedBytes"]?:NSNull.null,@"runtimeBytes":usage[@"runtimeBytes"]?:NSNull.null,
                    @"filesAndDirectories":usage[@"filesAndDirectories"]?:NSNull.null}];
            }
            close(shaderFD);
        }
        close(cache);
    } else if(errno!=ENOENT){complete=NO;STIssue(issues,@"Cache storage could not be opened privately. Existing files were preserved.");}
    return @{@"generations":[generations copy],@"jobs":[jobs copy],@"shaders":[shaders copy],@"issues":[issues copy],@"complete":complete?@YES:@NO};
}
- (BOOL)reloadWithCompletion:(CanopyStorageCompletion)completion {
    NSAssert(NSThread.isMainThread,@"Storage main-thread owner");
    if(_busy||!completion)return NO;_busy=YES;
    dispatch_async(_queue,^{@autoreleasepool{NSDictionary *snapshot=[self scan];
        dispatch_async(dispatch_get_main_queue(),^{self->_snapshot=snapshot;self->_busy=NO;completion(snapshot,nil);});}});return YES;
}
- (BOOL)resolveAddonResumeJob:(NSString *)jobIdentifier completion:(void (^)(NSDictionary<NSString *,id> * _Nullable,NSError * _Nullable))completion {
    NSAssert(NSThread.isMainThread,@"Storage main-thread owner");
    if(_busy||!completion||!STHex(jobIdentifier,32))return NO;
    _busy=YES;NSString *job=[jobIdentifier copy];
    dispatch_async(_queue,^{@autoreleasepool{
        int root=STRoot(self->_prepared);struct mng_store *store=NULL;
        enum mng_prepare_status status=root<0?MNG_PREPARE_IO:mng_store_open(root,&store);
        struct mng_store_job_intent intent={0};int present=0;struct mng_prepare_result base={0};NSDictionary *route=nil;
        if(status==MNG_PREPARE_OK)status=mng_store_read_job_intent(store,job.UTF8String,&intent,&present);
        if(status==MNG_PREPARE_OK&&!present)status=MNG_PREPARE_UNSUPPORTED;
        if(status==MNG_PREPARE_OK)status=mng_store_verify(store,intent.application_id,intent.base_generation_id,&base);
        if(status==MNG_PREPARE_OK&&(base.title_id!=intent.application_id||base.application_id!=intent.application_id||base.version_identified!=1||base.source_kind||
            (base.content_role!=0x80&&base.content_role!=0x81)||base.exefs_verified!=1||base.romfs_verified!=1))status=MNG_PREPARE_UNSUPPORTED;
        if(status==MNG_PREPARE_OK) {
            NSMutableDictionary *resolved=[STAddonIntent(job,&intent) mutableCopy];[resolved removeObjectForKey:@"mode"];
            NSString *title=resolved[@"applicationID"],*generation=resolved[@"baseGenerationID"];
            resolved[@"verifiedBaseEntry"]=@{@"titleID":title,@"applicationID":title,@"generationID":generation,
                @"titleVersion":@(base.title_version),@"versionIdentified":@YES,@"contentRole":@(base.content_role),
                @"sourceSize":@(base.source_size),@"sourceSHA256":STDigest(base.source_sha256),
                @"assetCount":@(base.asset_count),@"assetBytes":@(base.asset_bytes),@"preparationState":@"prepared",
                @"integrity":@{@"exefsVerified":@YES,@"romfsVerified":@YES,@"signatureVerified":@NO},@"runtimeEligibility":@"unassessed"};
            route=[resolved copy];
        }
        mng_store_close(store);if(root>=0)close(root);NSError *error=status==MNG_PREPARE_OK?nil:STError(status==MNG_PREPARE_INTEGRITY?4:3);
        dispatch_async(dispatch_get_main_queue(),^{self->_busy=NO;completion(route,error);});
    }});return YES;
}
- (NSDictionary *)runAction:(CanopyStorageAction)action identifier:(NSString *)identifier title:(NSString *)title error:(NSError **)error {
    NSMutableDictionary *operation=[@{@"action":STAction(action),@"identifier":identifier,@"outcome":@"unavailable"} mutableCopy];
    if(title)operation[@"titleID"]=title;
    if(action<=CanopyStorageDiscardJob) {
        int root=STRoot(_prepared);struct mng_store *store=NULL;
        BOOL empty=NO;
        enum mng_prepare_status status=root<0||!STStoreLayout(root,&empty)?MNG_PREPARE_IO:mng_store_open(root,&store);
        struct mng_prepare_result verified={0};
        if(status==MNG_PREPARE_OK) {
            uint64_t titleID=title?strtoull(title.UTF8String,NULL,16):0;
            if(action==CanopyStorageVerifyGeneration)status=mng_store_verify(store,titleID,identifier.UTF8String,&verified);
            else if(action==CanopyStorageSelectGeneration)status=mng_store_select(store,titleID,identifier.UTF8String);
            else if(action==CanopyStorageRemoveGeneration)status=mng_store_remove_generation(store,titleID,identifier.UTF8String);
            else status=mng_store_discard_job(store,identifier.UTF8String);
            if(title) {char current[65]={0};enum mng_prepare_status read=mng_store_current(store,titleID,current);
                operation[@"currentReadState"]=read==MNG_PREPARE_OK?@"confirmed":@"unavailable";
                operation[@"currentGenerationID"]=read==MNG_PREPARE_OK?[NSString stringWithUTF8String:current]:NSNull.null;}
        } else if(title){operation[@"currentReadState"]=@"unavailable";operation[@"currentGenerationID"]=NSNull.null;}
        mng_store_close(store);if(root>=0)close(root);
        if(status==MNG_PREPARE_OK){operation[@"outcome"]=@"completed";
            if(action==CanopyStorageVerifyGeneration)operation[@"verifiedAssets"]=@{@"assetBytes":@(verified.asset_bytes),@"assetCount":@(verified.asset_count),
                @"titleVersion":@(verified.title_version),@"versionIdentified":verified.version_identified?@YES:@NO};
        } else {operation[@"outcome"]=@"notConfirmed";if(error)*error=STError(status==MNG_PREPARE_INVALID?2:status==MNG_PREPARE_INTEGRITY?4:3);}
    } else {
        int cache=STRoot(_cache),titleFD=cache<0?-1:STChild(cache,title.UTF8String),shader=titleFD<0?-1:STChild(titleFD,"shader-identities");
        if(shader>=0) {
            NSURL *url=[[_cache URLByAppendingPathComponent:title isDirectory:YES] URLByAppendingPathComponent:@"shader-identities" isDirectory:YES];
            CanopyShaderCache *manager=[[CanopyShaderCache alloc] initWithRootURL:url];NSError *failure=nil;
            BOOL ok=action==CanopyStorageClearShaderRuntime?[manager clearRuntimeForIdentityHash:identifier titleID:title error:&failure]:
                [manager removeIdentityHash:identifier titleID:title error:&failure];
            operation[@"outcome"]=ok?@"completed":@"notConfirmed";if(!ok&&error)*error=STError(failure.code==3?2:3);
        } else if(error)*error=STError(3);
        if(shader>=0)close(shader);if(titleFD>=0)close(titleFD);if(cache>=0)close(cache);
    }
    return [operation copy];
}
- (BOOL)performAction:(CanopyStorageAction)action identifier:(NSString *)identifier titleID:(NSString *)title completion:(CanopyStorageCompletion)completion {
    NSAssert(NSThread.isMainThread,@"Storage main-thread owner");
    BOOL job=action==CanopyStorageDiscardJob;
    if(_busy||!completion||action>CanopyStorageRemoveShaderIdentity||!STHex(identifier,job?32:64)||
        (job?title!=nil:!STTitle(title)))return NO;
    _busy=YES;NSString *selected=[identifier copy],*selectedTitle=[title copy];
    dispatch_async(_queue,^{@autoreleasepool{
        NSError *failure=nil;NSDictionary *operation=[self runAction:action identifier:selected title:selectedTitle error:&failure];
        NSMutableDictionary *snapshot=[[self scan] mutableCopy];snapshot[@"operation"]=operation;
        NSDictionary *verified=operation[@"verifiedAssets"];
        if(verified) {
            NSMutableArray *rows=[snapshot[@"generations"] mutableCopy];
            for(NSUInteger i=0;i<rows.count;i++)if([rows[i][@"identifier"] isEqual:selected]&&[rows[i][@"titleID"] isEqual:selectedTitle]) {
                NSMutableDictionary *row=[rows[i] mutableCopy];row[@"verification"]=@"verified";row[@"logicalAssetBytes"]=verified[@"assetBytes"];
                row[@"assetCount"]=verified[@"assetCount"];row[@"titleVersion"]=verified[@"titleVersion"];row[@"versionIdentified"]=verified[@"versionIdentified"];rows[i]=[row copy];break;
            }
            snapshot[@"generations"]=[rows copy];
        }
        NSDictionary *finished=[snapshot copy];
        dispatch_async(dispatch_get_main_queue(),^{self->_snapshot=finished;self->_busy=NO;completion(finished,failure);});
    }});return YES;
}
@end
