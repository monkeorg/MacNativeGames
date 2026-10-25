#import <Foundation/Foundation.h>
#import "CanopyProfiles.h"
#import "CanopySaveStore.h"
#import "CanopySettings.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
static int failDirectorySync;
static unsigned deniedAncestorOpens;
int canopy_profiles_test_open(const char *path,int flags,...) {
    const char *root=getenv("CANOPY_PROFILES_DENY_ANCESTORS");size_t n=strlen(path);
    if(root&&(flags&O_DIRECTORY)&&(!strcmp(path,"/")||(n<strlen(root)&&!strncmp(path,root,n)&&root[n]=='/'))) {
        deniedAncestorOpens++;errno=EACCES;return -1;
    }
    if(flags&O_CREAT){va_list args;va_start(args,flags);int mode=va_arg(args,int);va_end(args);return open(path,flags,mode);}
    return open(path,flags);
}
int canopy_profiles_test_fsync(int fd){if(failDirectorySync){failDirectorySync=0;errno=EIO;return -1;}return fsync(fd);}
int canopy_profiles_test_rename(int a,const char *from,int b,const char *to){
    const char *fault=getenv("CANOPY_PROFILES_FAULT");
    if(fault&&!strcmp(to,"save-profiles.json")&&!strcmp(fault,"before-rename")){errno=EIO;return -1;}
    int result=renameat(a,from,b,to);
    if(!result&&fault&&!strcmp(to,"save-profiles.json")&&!strcmp(fault,"after-rename"))failDirectorySync=1;
    return result;
}
static void need(BOOL yes,const char *message){if(!yes){fprintf(stderr,"FAIL %s\n",message);exit(1);}}
static NSURL *child(NSURL *root,NSString *name){return [root URLByAppendingPathComponent:name];}
static void folder(NSURL *root){need([NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL],"create original fixture directory");}
static void writeData(NSURL *url,NSData *data){need([data writeToURL:url options:NSDataWritingAtomic error:NULL],"write original fixture");need(!chmod(url.fileSystemRepresentation,0600),"private fixture mode");}
static void writeJSON(NSURL *url,id object){writeData(url,[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:NULL]);}
static NSData *readData(NSURL *url){NSData *data=[NSData dataWithContentsOfURL:url];need(data!=nil,"read fixture");return data;}
static id readJSON(NSURL *url){id result=[NSJSONSerialization JSONObjectWithData:readData(url) options:0 error:NULL];need(result!=nil,"decode registry fixture");return result;}
static CanopySaveStore *store(NSURL *root,NSString *title,NSString *profile){
    NSError *error=nil;CanopySaveStore *value=[[CanopySaveStore alloc] initWithRootURL:root titleID:title profileID:profile
        externalValidator:^BOOL(NSURL *directory,NSError **failure){(void)directory;(void)failure;return YES;} error:&error];
    need(value!=nil,"open actual synthetic save store");return value;
}
int main(int argc,char **argv){@autoreleasepool {
    need(argc==3,"mode/root");NSString *mode=@(argv[1]),*title=@"0100123456780000",*otherTitle=@"0100123456780001";
    NSURL *root=[NSURL fileURLWithPath:@(argv[2]) isDirectory:YES],*metadata=child(root,@"Metadata"),*saveRoot=child(root,@"Profiles");
    CanopyProfiles *profiles=[[CanopyProfiles alloc] initWithDirectoryURL:metadata];NSError *error=nil;
    NSDictionary *initial=[profiles snapshotForTitleID:title error:&error];need([initial[@"selectedID"] isEqual:@"default"]&&[initial[@"profiles"] count]==1,"implicit exact default");
    NSURL *registry=child(metadata,@"save-profiles.json"),*previous=child(metadata,@"save-profiles.previous.json");
    if([mode isEqual:@"default"]){
        need([profiles selectProfileID:@"default" titleID:title expectedSelection:@"default" error:&error],"implicit default no-op selection");
        need(![NSFileManager.defaultManager fileExistsAtPath:metadata.path],"missing default must not write registry/directory");
    } else if([mode isEqual:@"ancestor"]){
        setenv("CANOPY_PROFILES_DENY_ANCESTORS",root.fileSystemRepresentation,1);
        NSString *identifier=[profiles createProfileWithName:@"Sandbox-safe" titleID:title error:&error];need(identifier!=nil,"create through known private parent without readable system ancestors");
        need([profiles selectProfileID:identifier titleID:title expectedSelection:@"default" error:&error],"select without ancestor enumeration");
        need([[[profiles snapshotForTitleID:title error:&error] objectForKey:@"selectedID"] isEqual:identifier],"read known private registry path");
        need(deniedAncestorOpens==0,"no readable ancestor open attempted");unsetenv("CANOPY_PROFILES_DENY_ANCESTORS");
    } else if([mode isEqual:@"isolation"]){
        CanopySaveStore *original=store(saveRoot,title,@"default");NSURL *progress=child(original.activeDirectoryURL,@"progress.sav"),*identity=child(original.accountIdentityDirectoryURL,@"account.uid");
        NSData *payload=[@"original opaque save fixture" dataUsingEncoding:NSUTF8StringEncoding],*uid=[@"original isolated identity fixture" dataUsingEncoding:NSUTF8StringEncoding];writeData(progress,payload);writeData(identity,uid);
        NSString *backup=[original backup:&error];need(backup!=nil,"real verified default backup");struct stat before,after;need(!lstat(progress.fileSystemRepresentation,&before),"original inode");
        NSString *identifier=[profiles createProfileWithName:@"Second" titleID:title error:&error];need(identifier.length==32,"original UUID logical identity");
        NSArray *beforeOpen=[NSFileManager.defaultManager contentsOfDirectoryAtPath:child(saveRoot,title).path error:NULL];need(beforeOpen.count==1,"registering profile copies no data or directories");
        CanopySaveStore *second=store(saveRoot,title,identifier);need(![second.activeDirectoryURL isEqual:original.activeDirectoryURL],"actual profile paths distinct");
        need([[NSFileManager.defaultManager contentsOfDirectoryAtPath:second.activeDirectoryURL.path error:NULL] count]==0,"new save profile empty");
        need([[NSFileManager.defaultManager contentsOfDirectoryAtPath:second.accountIdentityDirectoryURL.path error:NULL] count]==0,"no copied or generated account UID");
        need([profiles selectProfileID:identifier titleID:title expectedSelection:@"default" error:&error],"select after actual isolated store opens");
        need([readData(progress) isEqual:payload]&&[readData(identity) isEqual:uid],"default save/identity bytes preserved");need(!lstat(progress.fileSystemRepresentation,&after)&&before.st_ino==after.st_ino,"default inode retained");
        need([original backups:&error].count==1,"default backups retained");
        NSURL *exports=child(root,@"Exports");folder(exports);NSURL *export=[original exportToDirectory:exports error:&error];need(export!=nil,"actual original export");
        need(![second importExportURL:export error:&error],"crossprofile export refused by actual store");
        CanopyProfiles *reopened=[[CanopyProfiles alloc] initWithDirectoryURL:metadata];need([[[reopened snapshotForTitleID:title error:&error] objectForKey:@"selectedID"] isEqual:identifier],"selection survives model restart");
        need([profiles selectProfileID:@"default" titleID:title expectedSelection:identifier error:&error],"return to unchanged default");
    } else if([mode isEqual:@"settings"]){
        NSString *identifier=[profiles createProfileWithName:@"Local" titleID:title error:&error];need(identifier!=nil,"register");
        need([profiles selectProfileID:identifier titleID:title expectedSelection:@"default" error:&error],"select");NSData *bytes=readData(registry);
        CanopySettings *settings=[[CanopySettings alloc] initWithDirectoryURL:metadata];need([settings load:&error]&&[settings setDisplayName:@"Original" forTitleID:title error:&error]&&[settings resetMetadata:&error],"actual preference reset");
        need([readData(registry) isEqual:bytes],"reset names/preferences never resets logical profiles");
    } else if([mode isEqual:@"stale"]){
        NSString *a=[profiles createProfileWithName:@"A" titleID:title error:&error],*b=[profiles createProfileWithName:@"B" titleID:title error:&error];need(a&&b,"two registrations");
        need([profiles selectProfileID:a titleID:title expectedSelection:@"default" error:&error],"first selection");NSData *bytes=readData(registry);
        need(![profiles selectProfileID:b titleID:title expectedSelection:@"default" error:&error]&&[readData(registry) isEqual:bytes],"stale selector cannot overwrite current");
        NSString *other=[profiles createProfileWithName:@"Other title" titleID:otherTitle error:&error];need(other!=nil,"independent title");need([[[profiles snapshotForTitleID:title error:&error] objectForKey:@"selectedID"] isEqual:a],"other title mutation preserves selection");
    } else if([mode isEqual:@"fault"]){
        CanopySaveStore *original=store(saveRoot,title,@"default");writeData(child(original.activeDirectoryURL,@"progress.sav"),[@"retained" dataUsingEncoding:NSUTF8StringEncoding]);
        NSString *identifier=[profiles createProfileWithName:@"Candidate" titleID:title error:&error];need(identifier!=nil,"register before injected failures");CanopySaveStore *candidate=store(saveRoot,title,identifier);need(candidate!=nil,"actual open before select");NSData *bytes=readData(registry);
        setenv("CANOPY_PROFILES_FAULT","before-rename",1);need(![profiles selectProfileID:identifier titleID:title expectedSelection:@"default" error:&error],"failed rename refused");unsetenv("CANOPY_PROFILES_FAULT");need(![error.userInfo[@"publicationUncertain"] boolValue]&&[readData(registry) isEqual:bytes],"prepublish failure leaves current unchanged");
        setenv("CANOPY_PROFILES_FAULT","after-rename",1);need(![profiles selectProfileID:identifier titleID:title expectedSelection:@"default" error:&error],"postrename IO not success");unsetenv("CANOPY_PROFILES_FAULT");need([error.userInfo[@"publicationUncertain"] boolValue],"publication uncertainty explicit");
        need([readJSON(registry)[@"titles"][title][@"selectedID"] isEqual:identifier]&&[readJSON(previous)[@"titles"][title][@"selectedID"] isEqual:@"default"],"actual current and previous facts retained");
        need([readData(child(original.activeDirectoryURL,@"progress.sav")) isEqual:[@"retained" dataUsingEncoding:NSUTF8StringEncoding]],"old live store bytes remain intact");
    } else if([mode isEqual:@"limit"]){
        for(unsigned i=1;i<16;i++)need([profiles createProfileWithName:@"Original fixture" titleID:title error:&error]!=nil,"bounded profile registration");NSData *bytes=readData(registry);need(![profiles createProfileWithName:@"Excess" titleID:title error:&error]&&[readData(registry) isEqual:bytes],"17th profile refused without overwrite");
    } else if([mode isEqual:@"unsafe"]){
        folder(metadata);NSURL *outside=child(root,@"outside.json");writeJSON(outside,@{@"original":@YES});need(!symlink(outside.fileSystemRepresentation,registry.fileSystemRepresentation),"linked registry fixture");
        need(![profiles snapshotForTitleID:title error:&error]&&![profiles createProfileWithName:@"Local" titleID:title error:&error],"linked registry load/write refused");need([readJSON(outside)[@"original"] boolValue],"outside unchanged");
        need(!unlink(registry.fileSystemRepresentation)&&!link(outside.fileSystemRepresentation,registry.fileSystemRepresentation),"hardlinked registry fixture");need(![profiles snapshotForTitleID:title error:&error],"hardlink refused");
        NSURL *external=child(root,@"external-directory"),*alias=child(root,@"linked-parent");folder(external);
        need(!symlink(external.fileSystemRepresentation,alias.fileSystemRepresentation),"linked ancestor fixture");
        CanopyProfiles *linked=[[CanopyProfiles alloc] initWithDirectoryURL:child(alias,@"Metadata")];
        need(![linked createProfileWithName:@"No outside creation" titleID:title error:&error],"linked ancestor rejected before mkdir");
        need(![NSFileManager.defaultManager fileExistsAtPath:child(external,@"Metadata").path],"no outside directory created through alias");
    } else {
        need([mode isEqual:@"invalid"],"known scenario");folder(metadata);
        NSArray *documents=@[@{@"schemaVersion":@2,@"titles":@{}},@{@"schemaVersion":@YES,@"titles":@{}},
            @{@"schemaVersion":@1,@"titles":@{title:@{@"selectedID":@"default",@"profiles":@[]}}},
            @{@"schemaVersion":@1,@"titles":@{title:@{@"selectedID":@"../escape",@"profiles":@[@{@"identifier":@"default",@"displayName":@"Default"}]}}}];
        for(id document in documents){writeJSON(registry,document);NSData *bytes=readData(registry);need(![profiles snapshotForTitleID:title error:&error]&&![profiles createProfileWithName:@"X" titleID:title error:&error]&&[readData(registry) isEqual:bytes],"invalid schema preserved/refused");}
        writeData(registry,[NSMutableData dataWithLength:65537]);need(![profiles snapshotForTitleID:title error:&error],"oversize bounded");
        need(!unlink(registry.fileSystemRepresentation),"remove original malformed fixture");writeJSON(previous,@{@"schemaVersion":@1,@"titles":@{}});need(![profiles snapshotForTitleID:title error:&error],"missing primary with previous is recovery, not empty default");
    }
    puts("{\"passed\":true}");return 0;
}}
