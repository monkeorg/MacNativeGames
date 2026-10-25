#import <Foundation/Foundation.h>
#import "CanopySaveStore.h"
#import "save_validation.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failSync;
static _Atomic int blockRead;
static dispatch_semaphore_t copyEntered,copyRelease,statusFinished;
ssize_t canopy_test_save_read(int fd,void *bytes,size_t count) {
    if(atomic_exchange(&blockRead,0)){
        dispatch_semaphore_signal(copyEntered);
        (void)dispatch_semaphore_wait(copyRelease,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));
    }
    return read(fd,bytes,count);
}
int canopy_test_save_unlink(int parent,const char *name,int flags) {
    const char *fault=getenv("CANOPY_SAVE_FAULT");
    if(fault&&!strcmp(name,"transaction.json")){
        if(!strcmp(fault,"journal_unlink_fail")){errno=EIO;return -1;}
        if(!strcmp(fault,"crash_before_journal_unlink"))_exit(30);
    }
    int result=unlinkat(parent,name,flags);
    if(!result&&fault&&!strcmp(name,"transaction.json")){
        if(!strcmp(fault,"journal_unlink_sync"))failSync=1;
        if(!strcmp(fault,"crash_after_journal_unlink"))_exit(31);
    }
    return result;
}
int canopy_test_save_fsync(int fd) {
    if(failSync){failSync=0;errno=EIO;return -1;}return fsync(fd);
}
int canopy_test_save_rename(int from,const char *source,int to,const char *dest,unsigned flags) {
    const char *fault=getenv("CANOPY_SAVE_FAULT");
    if(flags==RENAME_SWAP&&fault&&!strcmp(fault,"swap_fail")){errno=EIO;return -1;}
    int result=renameatx_np(from,source,to,dest,flags);
    if(!result&&flags==RENAME_EXCL&&fault&&!strcmp(fault,"copy_final_sync")&&!strncmp(source,".pending-",9))failSync=1;
    if(!result&&flags==RENAME_SWAP&&fault){
        if(!strcmp(fault,"crash_after_swap"))_exit(29);
        if(!strcmp(fault,"after_swap_sync"))failSync=1;
    }
    return result;
}
static void Check(BOOL condition,const char *message) {
    if(!condition){fprintf(stderr,"FAIL: %s\n",message);exit(1);}
}
static NSURL *Child(NSURL *root,NSString *name){return [root URLByAppendingPathComponent:name];}
static void Write(NSURL *url,NSString *text){Check([[text dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url atomically:YES],"write fixture");}
static NSString *Read(NSURL *url){return [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL];}
static CanopySaveStore *Store(NSURL *root,NSString *title,NSString *profile){
    // Invented fixture validator, not a claim about any real title format.
    CanopySaveValidator validator=^BOOL(NSURL *stage,NSError **error){
        (void)error;NSString *text=Read(Child(stage,@"progress.sav"));return [text isEqual:@"A"]||[text isEqual:@"B"];
    };
    NSError *error=nil;CanopySaveStore *store=[[CanopySaveStore alloc] initWithRootURL:root titleID:title profileID:profile externalValidator:validator error:&error];
    Check(store!=nil&&error==nil,"open store");return store;
}
static NSURL *Export(CanopySaveStore *store,NSURL *root){NSError *error=nil;NSURL *url=[store exportToDirectory:root error:&error];Check(url!=nil&&error==nil,"export");return url;}
static BOOL Import(CanopySaveStore *store,NSURL *source){NSError *error=nil;return [store importExportURL:source error:&error];}
static NSString *Backup(CanopySaveStore *store){NSError *error=nil;NSString *identifier=[store backup:&error];Check(identifier!=nil&&error==nil,"backup");return identifier;}
struct small_stack { __unsafe_unretained CanopySaveStore *store;__unsafe_unretained NSURL *root;BOOL ok; };
static void *SmallStack(void *opaque){@autoreleasepool{
    struct small_stack *context=opaque;NSError *error=nil;
    context->ok=[context->store exportToDirectory:context->root error:&error]!=nil;return NULL;
}}
static void *ReadStatus(void *opaque){@autoreleasepool{
    struct small_stack *context=opaque;
    context->ok=!context->store.sealed&&!context->store.recoveryRequired;
    dispatch_semaphore_signal(statusFinished);return NULL;
}}
int main(int argc,const char *argv[]){@autoreleasepool{
    atomic_init(&blockRead,0);
    Check(argc==3,"usage");NSString *mode=@(argv[1]);NSURL *root=[NSURL fileURLWithPath:@(argv[2]) isDirectory:YES];
    NSURL *saveRoot=Child(root,@"saves");NSString *title=@"0100123456780000",*profile=@"profile-default";
    if([mode isEqual:@"root_symlink"]){
        NSURL *outside=Child(root,@"outside");
        Check([NSFileManager.defaultManager createDirectoryAtURL:outside withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:NULL],"outside fixture");
        NSURL *alias=Child(root,@"alias");Check(!symlink(outside.fileSystemRepresentation,alias.fileSystemRepresentation),"ancestor symlink fixture");
        NSError *failure=nil;
        CanopySaveStore *rejected=[[CanopySaveStore alloc] initWithRootURL:Child(alias,@"missing-child") titleID:title profileID:profile error:&failure];
        Check(rejected==nil&&failure!=nil,"symlink ancestor accepted");
        Check([NSFileManager.defaultManager contentsOfDirectoryAtPath:outside.path error:NULL].count==0,"rejected root created outside child");
        puts("{\"status\":\"pass\"}");return 0;
    }
    CanopySaveStore *store=Store(saveRoot,title,profile);NSError *error=nil;
    NSURL *active=store.activeDirectoryURL,*identity=Child(store.accountIdentityDirectoryURL,@"account.uid");
    if([mode isEqual:@"recover"]){
        Check(store.recoveryRequired&&!store.sealed,"crash journal detection");
        Check([store sealForSession:&error]==nil,"seal with pending recovery");
        error=nil;Check([store recover:&error]&&!store.recoveryRequired,"rollback recovery");
        Check([Read(Child(active,@"progress.sav")) isEqual:@"B"],"recovery restored pretransaction bytes");
        Check([Read(identity) isEqual:@"identity-retain"],"identity after recovery");
    }else if([mode isEqual:@"recover_committed"]||[mode isEqual:@"after_cleanup_crash"]){
        if(store.recoveryRequired)Check([store recover:&error],"committed cleanup recovery");
        Check([Read(Child(active,@"progress.sav")) isEqual:@"A"],"committed save was rolled back");
        Check([Read(identity) isEqual:@"identity-retain"],"committed identity changed");
    }else if([mode isEqual:@"after_session_crash"]){
        Check(!store.sealed&&!store.recoveryRequired,"stale session seal survived process death");
        NSString *token=[store sealForSession:&error];Check(token!=nil,"reopen session seal");
        Check([store finishSessionWithToken:token error:&error],"reopen session finish");
    }else{
        Write(identity,@"identity-retain");Write(Child(active,@"progress.sav"),@"A");
        Check([NSFileManager.defaultManager createDirectoryAtURL:Child(active,@"empty") withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:NULL],"empty folder");
        if([mode isEqual:@"validator"]){
            CanopySaveStore *unknown=[[CanopySaveStore alloc] initWithRootURL:saveRoot titleID:title profileID:@"unknown" error:&error];
            Check(unknown!=nil&&!unknown.externalImportSupported,"unknown title gained validator");
            Write(Child(unknown.activeDirectoryURL,@"progress.sav"),@"A");NSURL *opaque=Export(unknown,root);
            Check(!Import(unknown,opaque)&&[unknown backups:&error].count==0,"unvalidated external replacement accepted");
            CanopySaveValidator validator=^BOOL(NSURL *stage,NSError **failure){return TOTKSaveValidateDirectory(stage,failure);};
            CanopySaveStore *totk=[[CanopySaveStore alloc] initWithRootURL:saveRoot titleID:@"0100f2c0115b6000" profileID:profile externalValidator:validator error:&error];
            Check(totk!=nil&&totk.externalImportSupported,"trusted TOTK validator missing");
            NSURL *data=totk.activeDirectoryURL;Write(Child(data,@"progress.sav"),@"opaque invalid slot layout");
            NSURL *invalid=Export(totk,root);
            Check(!unlink(Child(data,@"progress.sav").fileSystemRepresentation),"raw fixture cleanup");
            NSURL *slot=Child(data,@"slot_00");Check([NSFileManager.defaultManager createDirectoryAtURL:slot withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:NULL],"TOTK slot fixture");
            for(NSString *name in @[@"progress.sav",@"caption.sav",@"footprint.sav",@"direct_file_save_related.sav"])Write(Child(slot,name),@"original structural fixture");
            Check(!Import(totk,invalid)&&[totk backups:&error].count==0,"forged own manifest bypassed title validator");
            Check([Read(Child(slot,@"caption.sav")) isEqual:@"original structural fixture"],"validator refusal changed active");
            NSURL *valid=Export(totk,root);Write(Child(slot,@"caption.sav"),@"modified");
            Check(Import(totk,valid),"valid existing TOTK slot policy rejected");
            Check([Read(Child(slot,@"caption.sav")) isEqual:@"original structural fixture"],"validated replacement did not publish");
        }else if([mode isEqual:@"roundtrip"]){
            NSURL *export=Export(store,root);Write(Child(active,@"progress.sav"),@"B");
            Check(Import(store,export),"own export import");Check([Read(Child(active,@"progress.sav")) isEqual:@"A"],"import exact bytes");
            Check([NSFileManager.defaultManager fileExistsAtPath:Child(active,@"empty").path],"empty directory lost");
            NSArray *backups=[store backups:&error];Check(backups.count==1,"preimport backup missing");
            Check([store restoreBackup:backups[0][@"identifier"] error:&error],"restore verified backup");
            Check([Read(Child(active,@"progress.sav")) isEqual:@"B"],"restore old bytes");
            Check([Read(identity) isEqual:@"identity-retain"],"identity replaced");
        }else if([mode isEqual:@"isolation"]){
            NSURL *export=Export(store,root);
            CanopySaveStore *other=Store(saveRoot,title,@"Profile-Default");
            Check(![other.activeDirectoryURL isEqual:active],"case-sensitive profile identities aliased");
            Check(!Import(other,export),"crossprofile import accepted");
            CanopySaveStore *different=Store(saveRoot,@"0100123456780001",profile);
            Check(!Import(different,export),"crosstitle import accepted");
            CanopySaveStore *locked=[[CanopySaveStore alloc] initWithRootURL:saveRoot titleID:title profileID:profile error:&error];
            Check(locked==nil,"profile lock not exclusive");
        }else if([mode isEqual:@"seal"] || [mode isEqual:@"session_crash"]){
            NSString *token=[store sealForSession:&error];Check(token!=nil&&store.sealed,"session seal");
            if([mode isEqual:@"session_crash"])_exit(27);
            Check([store exportToDirectory:root error:&error]==nil,"sealed export accepted");
            Check([store backup:&error]==nil,"sealed backup accepted");
            Check(![store finishSessionWithToken:@"wrong" error:&error]&&store.sealed,"wrong session token");
            Check([store finishSessionWithToken:token error:&error]&&!store.sealed,"session release");
            NSString *next=[store sealForSession:&error];Check(next!=nil&&![next isEqual:token],"session token reused");
            Check(![store finishSessionWithToken:token error:&error]&&store.sealed,"stale session release");
            Check([store finishSessionWithToken:next error:&error],"second session release");
        }else if([mode isEqual:@"tamper"]){
            NSURL *export=Export(store,root);Write(Child(Child(export,@"data"),@"progress.sav"),@"forged");
            Check(!Import(store,export),"tampered export accepted");
            Check([Read(Child(active,@"progress.sav")) isEqual:@"A"],"tampering changed active");
            Check(!Import(store,active),"raw save import accepted");
            Check([store backups:&error].count==0,"rejected import made backup");
        }else if([mode isEqual:@"links"]){
            NSURL *outside=Child(root,@"outside");Write(outside,@"retain");
            Check(!symlink(outside.fileSystemRepresentation,Child(active,@"link").fileSystemRepresentation),"symlink fixture");
            Check([store exportToDirectory:root error:&error]==nil,"symlink copied");
            Check(!unlink(Child(active,@"link").fileSystemRepresentation),"unlink symlink fixture");
            Check(!link(outside.fileSystemRepresentation,Child(active,@"hardlink").fileSystemRepresentation),"hardlink fixture");
            Check([store backup:&error]==nil,"hardlink copied");
            Check([Read(outside) isEqual:@"retain"],"link target changed");
        }else if([mode isEqual:@"status_nonblocking"]){
            copyEntered=dispatch_semaphore_create(0);copyRelease=dispatch_semaphore_create(0);statusFinished=dispatch_semaphore_create(0);
            struct small_stack copying={store,root,NO},reading={store,root,NO};pthread_t copyThread,statusThread;
            atomic_store(&blockRead,1);Check(!pthread_create(&copyThread,NULL,SmallStack,&copying),"blocked copy worker");
            Check(!dispatch_semaphore_wait(copyEntered,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)),"copy never entered real read");
            Check(!pthread_create(&statusThread,NULL,ReadStatus,&reading),"status reader");
            BOOL returnedBeforeRelease=!dispatch_semaphore_wait(statusFinished,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC));
            dispatch_semaphore_signal(copyRelease);
            Check(!pthread_join(copyThread,NULL)&&!pthread_join(statusThread,NULL),"status worker joins");
            Check(returnedBeforeRelease&&copying.ok&&reading.ok,"readonly status waited for transfer monitor");
        }else if([mode isEqual:@"deep_worker"]){
            NSURL *deep=active;
            for(unsigned i=0;i<12;i++){
                deep=Child(deep,@"nested");Check([NSFileManager.defaultManager createDirectoryAtURL:deep withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:NULL],"deep folder");
            }
            Write(Child(deep,@"last"),@"bounded worker stack");
            struct small_stack context={store,root,NO};pthread_attr_t attributes;pthread_t thread;
            Check(!pthread_attr_init(&attributes)&&!pthread_attr_setstacksize(&attributes,256*1024),"small stack attributes");
            Check(!pthread_create(&thread,&attributes,SmallStack,&context),"small stack worker");pthread_attr_destroy(&attributes);
            Check(!pthread_join(thread,NULL)&&context.ok,"deep snapshot on 256KiB worker");
        }else if([mode isEqual:@"copy_sync"]){
            setenv("CANOPY_SAVE_FAULT","copy_final_sync",1);error=nil;
            Check([store exportToDirectory:root error:&error]==nil&&[error.userInfo[@"publicationMayHaveCompleted"] boolValue],"export ambiguity flag");
            unsetenv("CANOPY_SAVE_FAULT");
            NSArray *names=[NSFileManager.defaultManager contentsOfDirectoryAtPath:root.path error:NULL];NSUInteger complete=0;
            for(NSString *name in names)if([name hasPrefix:@"Canopy-Save-"])complete++;
            Check(complete==1,"complete export disappeared after directory sync failure");
            setenv("CANOPY_SAVE_FAULT","copy_final_sync",1);error=nil;
            Check([store backup:&error]==nil&&[error.userInfo[@"publicationMayHaveCompleted"] boolValue],"backup ambiguity flag");
            unsetenv("CANOPY_SAVE_FAULT");Check([store backups:&error].count==1,"complete backup after ambiguous sync");
        }else if([mode isEqual:@"quota"]){
            int fd=open(Child(active,@"large").fileSystemRepresentation,O_CREAT|O_EXCL|O_WRONLY,0600);
            Check(fd>=0&&!ftruncate(fd,((off_t)64<<20)+1),"sparse quota fixture");close(fd);
            Check([store backup:&error]==nil,"oversized file copied");
            Check(!unlink(Child(active,@"large").fileSystemRepresentation),"quota cleanup");
            for(unsigned i=0;i<16;i++)(void)Backup(store);
            Check([store backup:&error]==nil,"backup count exceeded");
            NSArray *backups=[store backups:&error];Check(backups.count==16,"backup limit catalog");
            Check([store removeBackup:backups[0][@"identifier"] error:&error],"explicit backup removal");(void)Backup(store);
        }else if([mode isEqual:@"journal_unlink_sync"]||[mode isEqual:@"journal_unlink_fail"]||[mode isEqual:@"committed_crash"]||[mode isEqual:@"cleanup_crash"]){
            NSURL *export=Export(store,root);Write(Child(active,@"progress.sav"),@"B");
            const char *fault=[mode isEqual:@"committed_crash"]?"crash_before_journal_unlink":[mode isEqual:@"cleanup_crash"]?"crash_after_journal_unlink":mode.UTF8String;
            setenv("CANOPY_SAVE_FAULT",fault,1);error=nil;
            Check(![store importExportURL:export error:&error]&&[error.userInfo[@"publicationMayHaveCompleted"] boolValue],"committed cleanup fault");unsetenv("CANOPY_SAVE_FAULT");
            Check(store.recoveryRequired,"cleanup fault not quarantined");
            Check([store recover:&error]&&!store.recoveryRequired,"cleanup retry recovery");
            Check([Read(Child(active,@"progress.sav")) isEqual:@"A"],"durable committed save rolled back");
        }else if([mode isEqual:@"swap_fail"] || [mode isEqual:@"after_swap_sync"] || [mode isEqual:@"crash"]){
            NSURL *export=Export(store,root);Write(Child(active,@"progress.sav"),@"B");
            setenv("CANOPY_SAVE_FAULT",[mode isEqual:@"crash"]?"crash_after_swap":mode.UTF8String,1);
            Check(!Import(store,export),"injected transaction unexpectedly succeeded");unsetenv("CANOPY_SAVE_FAULT");
            Check(store.recoveryRequired,"failed transaction not quarantined");
            Check([store sealForSession:&error]==nil,"quarantined profile exposed to runtime");
            Check([store recover:&error]&&!store.recoveryRequired,"recover failed transaction");
            Check([Read(Child(active,@"progress.sav")) isEqual:@"B"],"rollback lost pretransaction bytes");
            Check([Read(identity) isEqual:@"identity-retain"],"rollback changed identity");
        }else Check(NO,"unknown scenario");
    }
    puts("{\"status\":\"pass\",\"scope\":\"opaque save transfer, not title-format or gameplay acceptance\"}");
}return 0;}
