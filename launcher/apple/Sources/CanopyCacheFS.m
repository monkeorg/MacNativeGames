#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#import "CanopyCacheFS.h"
#include "mng_crypto.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <stdio.h>
#include <sys/file.h>
#include <unistd.h>

BOOL CCFStable(const struct stat *a,const struct stat *b) {
    return a->st_dev==b->st_dev && a->st_ino==b->st_ino && a->st_mode==b->st_mode && a->st_nlink==b->st_nlink &&
        a->st_size==b->st_size && a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec &&
        a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec && a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec &&
        a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
}
BOOL CCFPrivate(int fd,BOOL directory) {
    struct stat s;return fd>=0 && !fstat(fd,&s) && (directory ? S_ISDIR(s.st_mode):S_ISREG(s.st_mode)) &&
        s.st_uid==geteuid() && !(s.st_mode&077) && (directory || s.st_nlink==1);
}
static BOOL CCFWalkInternal(int directory,unsigned depth,uint64_t *bytes,uint64_t *count,BOOL remove,BOOL strict,BOOL (^cancel)(void),NSString *retained,unsigned limit) {
    struct stat owner={0},finished={0};
    if(depth>limit||fstat(directory,&owner)||!S_ISDIR(owner.st_mode)||owner.st_uid!=geteuid()||(strict&&(owner.st_mode&077)))return NO;
    int copy=openat(directory,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *d=copy<0?NULL:fdopendir(copy);if(!d){if(copy>=0)close(copy);return NO;}
    BOOL ok=YES;struct dirent *e;errno=0;
    while((e=readdir(d))){
        if(!strcmp(e->d_name,".")||!strcmp(e->d_name,"..")||(retained&&!strcmp(e->d_name,retained.UTF8String))){errno=0;continue;}
        struct stat named={0},opened={0},after={0};
        if((cancel&&cancel())||++*count>200010||fstatat(directory,e->d_name,&named,AT_SYMLINK_NOFOLLOW)||named.st_uid!=geteuid()||(strict&&(named.st_mode&077))){ok=NO;break;}
        if(S_ISDIR(named.st_mode)){
            int child=openat(directory,e->d_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            BOOL childStrict=retained&&!strcmp(e->d_name,"runtime")?NO:strict;
            ok=child>=0&&!fstat(child,&opened)&&CCFStable(&named,&opened)&&CCFWalkInternal(child,depth+1,bytes,count,remove,childStrict,cancel,nil,limit)&&
                !fstat(child,&after)&&after.st_dev==opened.st_dev&&after.st_ino==opened.st_ino&&
                !fstatat(directory,e->d_name,&named,AT_SYMLINK_NOFOLLOW)&&CCFStable(&after,&named);
            if(ok&&remove)ok=!fsync(child)&&!unlinkat(directory,e->d_name,AT_REMOVEDIR);
            if(child>=0)close(child);
        }else{
            if(!S_ISREG(named.st_mode)||named.st_nlink!=1||named.st_size<0||(uint64_t)named.st_size>(UINT64_C(128)<<30)-*bytes){ok=NO;break;}
            int file=openat(directory,e->d_name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
            ok=file>=0&&!fstat(file,&opened)&&CCFStable(&named,&opened)&&!fstatat(directory,e->d_name,&after,AT_SYMLINK_NOFOLLOW)&&CCFStable(&opened,&after);
            if(ok){*bytes+=(uint64_t)opened.st_size;if(remove)ok=!unlinkat(directory,e->d_name,0);}
            if(file>=0)close(file);
        }
        if(!ok)break;errno=0;
    }
    if(!e&&errno)ok=NO;
    if(ok)ok=!fstat(directory,&finished)&&(remove?(owner.st_dev==finished.st_dev&&owner.st_ino==finished.st_ino&&owner.st_mode==finished.st_mode):CCFStable(&owner,&finished));
    closedir(d);return ok;
}

BOOL CCFWalk(int directory,unsigned depth,uint64_t *bytes,uint64_t *count,BOOL remove,BOOL strict,BOOL (^cancel)(void)) {
    return CCFWalkInternal(directory,depth,bytes,count,remove,strict,cancel,nil,8);
}
BOOL CCFWalkExcept(int directory,uint64_t *bytes,uint64_t *count,BOOL remove,NSString *retained) {
    return CCFWalkInternal(directory,0,bytes,count,remove,YES,nil,retained,64);
}
int CCFChild(int parent,const char *leaf) {
    int fd=openat(parent,leaf,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0)return -1;
    if(!CCFPrivate(fd,YES)){close(fd);errno=EINVAL;return -1;}return fd;
}
BOOL CCFHex(id value,NSUInteger length) {
    return [value isKindOfClass:NSString.class] && [value length]==length &&
        [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
NSData *CCFData(int parent,const char *leaf,size_t limit) {
    int fd=openat(parent,leaf,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);struct stat before={0},after={0},named={0};
    if(!CCFPrivate(fd,NO)||fstat(fd,&before)||before.st_size<0||(uint64_t)before.st_size>limit){if(fd>=0)close(fd);return nil;}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)before.st_size];size_t used=0;BOOL ok=YES;
    while(used<data.length){ssize_t n=read(fd,(char *)data.mutableBytes+used,data.length-used);if(n<0&&errno==EINTR)continue;if(n<=0){ok=NO;break;}used+=(size_t)n;}
    ok=ok&&!fstat(fd,&after)&&CCFStable(&before,&after)&&!fstatat(parent,leaf,&named,AT_SYMLINK_NOFOLLOW)&&CCFStable(&after,&named);
    if(close(fd))ok=NO;return ok?data:nil;
}
NSString *CCFDigest(NSData *data) {
    if(!data)return nil;struct mng_sha256 *state=NULL;unsigned char digest[32];char text[65];
    int bad=mng_sha256_init(&state)||mng_sha256_update(state,data.bytes,data.length)||mng_sha256_final(state,digest);mng_sha256_free(state);
    if(bad)return nil;for(unsigned i=0;i<32;i++)snprintf(text+2*i,3,"%02x",digest[i]);return [NSString stringWithUTF8String:text];
}
/* New family-specific journal; existing shader retirement bytes are untouched.
 * 512 bytes: magic8,family32,phase32,title16,identifier160,sidecar160,
 * target dev/ino16,lease dev/ino16,reserved64,checksum ASCII64. */
#define CCFRecordBytes 512u
static void CFPut(unsigned char *p,uint64_t n){for(unsigned i=0;i<8;i++)p[i]=(unsigned char)(n>>(8*i));}
static uint64_t CFGet(const unsigned char *p){uint64_t n=0;for(unsigned i=0;i<8;i++)n|=(uint64_t)p[i]<<(8*i);return n;}
static const char *CFJournal(CCFFamily family){return family==CCFMKIdentity?".mk-removal":family==CCFMKRuntime?".mk-runtime-removal":family==CCFRomFS?".romfs-removal":NULL;}
static BOOL CFIdentifier(CCFFamily family,NSString *title,NSString *identifier) {
    if(!CCFHex(title,16)||[title isEqual:@"0000000000000000"])return NO;
    if(family==CCFMKIdentity||family==CCFMKRuntime)return [title isEqual:@"0100152000022000"]&&CCFHex(identifier,64);
    NSString *prefix=[NSString stringWithFormat:@"romfs-folders-v1-%@-",title];
    return family==CCFRomFS&&[identifier isKindOfClass:NSString.class]&&[identifier hasPrefix:prefix]&&CCFHex([identifier substringFromIndex:prefix.length],64);
}
static BOOL CFName(int parent,const char *name,uint64_t dev,uint64_t ino,BOOL directory) {
    struct stat s={0};return !fstatat(parent,name,&s,AT_SYMLINK_NOFOLLOW)&&s.st_uid==geteuid()&&!(s.st_mode&077)&&
        (uint64_t)s.st_dev==dev&&(uint64_t)s.st_ino==ino&&(directory?S_ISDIR(s.st_mode):(S_ISREG(s.st_mode)&&s.st_nlink==1&&!s.st_size));
}
static BOOL CFHeldName(int fd,int parent,const char *name,uint64_t dev,uint64_t ino) {
    struct stat held={0};return CCFPrivate(fd,NO)&&!fstat(fd,&held)&&!held.st_size&&
        (uint64_t)held.st_dev==dev&&(uint64_t)held.st_ino==ino&&CFName(parent,name,dev,ino,NO);
}
static BOOL CFJournalShape(int journal,unsigned *flags) {
    int fd=openat(journal,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *d=fd<0?NULL:fdopendir(fd);if(!d){if(fd>=0)close(fd);return NO;}
    unsigned found=0,count=0;BOOL ok=YES;struct dirent *e;errno=0;
    while((e=readdir(d))){if(!strcmp(e->d_name,".")||!strcmp(e->d_name,"..")){errno=0;continue;}
        unsigned bit=!strcmp(e->d_name,"intent.bin")?1:!strcmp(e->d_name,".intent.tmp")?2:!strcmp(e->d_name,"target")?4:0;struct stat st={0};
        if(++count>3||!bit||(found&bit)||fstatat(journal,e->d_name,&st,AT_SYMLINK_NOFOLLOW)||st.st_uid!=geteuid()||(st.st_mode&077)||
            (bit==4?!S_ISDIR(st.st_mode):(!S_ISREG(st.st_mode)||st.st_nlink!=1||st.st_size<0||st.st_size>CCFRecordBytes||(bit==1&&st.st_size!=CCFRecordBytes)))){ok=NO;break;}
        found|=bit;errno=0;
    }
    if(!e&&errno)ok=NO;closedir(d);if(ok)*flags=found;return ok;
}
static BOOL CFWriteRecord(int journal,unsigned char data[CCFRecordBytes],BOOL replace) {
    NSString *hash=CCFDigest([NSData dataWithBytes:data length:448]);if(!CCFHex(hash,64))return NO;memcpy(data+448,hash.UTF8String,64);
    int fd=openat(journal,".intent.tmp",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return NO;
    size_t used=0;BOOL ok=YES;while(used<CCFRecordBytes){ssize_t n=write(fd,data+used,CCFRecordBytes-used);if(n<0&&errno==EINTR)continue;if(n<=0){ok=NO;break;}used+=(size_t)n;}
    if(ok)ok=!fsync(fd);if(close(fd))ok=NO;
    if(ok)ok=!(replace?renameat(journal,".intent.tmp",journal,"intent.bin"):renameatx_np(journal,".intent.tmp",journal,"intent.bin",RENAME_EXCL))&&!fsync(journal);
    return ok;
}
static int CFOperationParent(int root,CCFFamily family,NSString *identifier) {return family==CCFMKRuntime?CCFChild(root,identifier.UTF8String):fcntl(root,F_DUPFD_CLOEXEC,0);}
static BOOL CFMKContents(int target,unsigned *contents) {
    int copy=openat(target,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *d=copy<0?NULL:fdopendir(copy);if(!d){if(copy>=0)close(copy);return NO;}
    BOOL ok=YES;unsigned flags=0,count=0;struct dirent *e;errno=0;
    while((e=readdir(d))){if(!strcmp(e->d_name,".")||!strcmp(e->d_name,"..")){errno=0;continue;}
        unsigned bit=!strcmp(e->d_name,"seed")?1:!strcmp(e->d_name,"runtime")?2:!strcmp(e->d_name,"identity.json")?4:!strcmp(e->d_name,".lease")?8:0;struct stat st={0};
        if(++count>4||!bit||(flags&bit)||fstatat(target,e->d_name,&st,AT_SYMLINK_NOFOLLOW)||st.st_uid!=geteuid()||(st.st_mode&077)||
            (bit<4?!S_ISDIR(st.st_mode):(!S_ISREG(st.st_mode)||st.st_nlink!=1||st.st_size<0||(bit==8?st.st_size!=0:st.st_size>16384)))){ok=NO;break;}
        flags|=bit;errno=0;
    }
    if(!e&&errno)ok=NO;closedir(d);if(ok)*contents=flags;return ok;
}
static BOOL CFPayloadWalk(int target,CCFFamily family,NSString *identifier,uint64_t *bytes,uint64_t *count,BOOL remove) {
    if(family==CCFMKRuntime)return CCFWalk(target,0,bytes,count,remove,NO,nil);
    if(family!=CCFMKIdentity)return CCFWalkExcept(target,bytes,count,remove,nil);
    unsigned flags=0;if(!CFMKContents(target,&flags))return NO;
    if((flags&4)?![CCFDigest(CCFData(target,"identity.json",16384)) isEqual:identifier]:(flags&3)!=0)return NO;
    const char *names[]={"seed","runtime"};
    /* Validate every surviving payload before deleting any of it. */
    for(unsigned i=0;i<2;i++)if(flags&(1u<<i)){
        int child=CCFChild(target,names[i]);BOOL ok=child>=0&&CCFWalk(child,0,bytes,count,NO,i==0,nil);if(child>=0)close(child);if(!ok)return NO;
    }
    if(!remove)return YES;
    uint64_t deleted=0,entries=0;
    for(unsigned i=0;i<2;i++)if(flags&(1u<<i)){
        int child=CCFChild(target,names[i]);BOOL ok=child>=0&&CCFWalk(child,0,&deleted,&entries,YES,i==0,nil)&&!fsync(child)&&!unlinkat(target,names[i],AT_REMOVEDIR)&&!fsync(target);if(child>=0)close(child);if(!ok)return NO;
    }
    if((flags&4)&&(unlinkat(target,"identity.json",0)||fsync(target)))return NO;
    return YES;
}
static BOOL CFEmpty(int fd){uint64_t bytes=0,count=0;return CCFWalkExcept(fd,&bytes,&count,NO,nil)&&!count;}
BOOL CCFRecover(int root,CCFFamily family,NSString *title,CCFValidation validate,NSString **completed) {
    const char *namespace=CFJournal(family);if(!namespace||!CCFHex(title,16))return NO;
    int journal=CCFChild(root,namespace);if(journal<0)return errno==ENOENT;
    int parent=-1,target=-1,lease=-1,marker=-1;BOOL ok=NO;unsigned flags=0;NSData *raw=nil;NSString *identifier=nil,*sidecar=nil,*expected=nil;unsigned char data[CCFRecordBytes]={0};
    struct stat record={0},named={0};
    if(!CFJournalShape(journal,&flags))goto done;
    if(flags&2){if(unlinkat(journal,".intent.tmp",0)||fsync(journal))goto done;flags&=~2u;}
    if(!flags){ok=!fsync(journal)&&!fsync(root);goto done;}
    if(!(flags&1))goto done;
    marker=openat(journal,"intent.bin",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(!CCFPrivate(marker,NO)||fstat(marker,&record)||record.st_size!=CCFRecordBytes)goto done;
    raw=CCFData(journal,"intent.bin",CCFRecordBytes);if(raw.length!=CCFRecordBytes)goto done;memcpy(data,raw.bytes,CCFRecordBytes);
    if(fstat(marker,&named)||!CCFStable(&record,&named))goto done;
    identifier=[[NSString alloc] initWithBytes:data+32 length:strnlen((const char *)data+32,160) encoding:NSASCIIStringEncoding];
    sidecar=[[NSString alloc] initWithBytes:data+192 length:strnlen((const char *)data+192,160) encoding:NSASCIIStringEncoding];
    if(memcmp(data,"CNPYCF01",8)||data[8]!=(unsigned)family||data[9]||data[10]||data[11]||data[12]>1||data[13]||data[14]||data[15]||
        memcmp(data+16,title.UTF8String,16)||!CFIdentifier(family,title,identifier)||!CFGet(data+360)||!CFGet(data+376)||
        ![[[NSString alloc] initWithBytes:data+448 length:64 encoding:NSASCIIStringEncoding] isEqual:CCFDigest([raw subdataWithRange:NSMakeRange(0,448)])])goto done;
    for(size_t i=32+identifier.length;i<192;i++)if(data[i])goto done;
    for(size_t i=192+sidecar.length;i<352;i++)if(data[i])goto done;
    for(size_t i=384;i<448;i++)if(data[i])goto done;
    expected=family==CCFRomFS?[NSString stringWithFormat:@".%@.lease",identifier]:@"";if(![sidecar isEqual:expected])goto done;
    if(fstatat(journal,"intent.bin",&named,AT_SYMLINK_NOFOLLOW)||!CCFStable(&record,&named)||fsync(marker)||fsync(journal)||fsync(root))goto done;
    parent=CFOperationParent(root,family,identifier);if(parent<0)goto done;
    const char *leaf=family==CCFMKRuntime?"runtime":identifier.UTF8String;
    if(!data[12]) {
        BOOL canonical=!fstatat(parent,leaf,&named,AT_SYMLINK_NOFOLLOW);if(!canonical&&errno!=ENOENT)goto done;
        if(canonical&&(flags&4))goto done;
        if(canonical||flags&4){target=CCFChild(canonical?parent:journal,canonical?leaf:"target");
            struct stat held={0};if(target<0||fstat(target,&held)||(uint64_t)held.st_dev!=CFGet(data+352)||(uint64_t)held.st_ino!=CFGet(data+360))goto done;
            int leaseParent=family==CCFMKIdentity?target:family==CCFMKRuntime?parent:root;
            const char *leaseName=family==CCFRomFS?sidecar.UTF8String:".lease";
            lease=openat(leaseParent,leaseName,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
            if(lease<0){if(canonical||errno!=ENOENT||family!=CCFMKIdentity||!CFEmpty(target))goto done;}
            else if(!CFHeldName(lease,leaseParent,leaseName,CFGet(data+368),CFGet(data+376))||flock(lease,LOCK_EX|LOCK_NB))goto done;
            uint64_t bytes=0,count=0;
            if(!CFPayloadWalk(target,family,identifier,&bytes,&count,NO))goto done;
            if(canonical&&(!validate(parent,target,identifier)||!CFName(parent,leaf,CFGet(data+352),CFGet(data+360),YES)||
                renameatx_np(parent,leaf,journal,"target",RENAME_EXCL)))goto done;
            if(!CFName(journal,"target",CFGet(data+352),CFGet(data+360),YES)||fsync(parent)||fsync(journal))goto done;
            bytes=0;count=0;if(!CFPayloadWalk(target,family,identifier,&bytes,&count,YES)||fsync(target))goto done;
            if(family==CCFMKIdentity&&lease>=0&&(!CFName(target,".lease",CFGet(data+368),CFGet(data+376),NO)||unlinkat(target,".lease",0)||fsync(target)))goto done;
            if(!CFEmpty(target)||!CFName(journal,"target",CFGet(data+352),CFGet(data+360),YES)||unlinkat(journal,"target",AT_REMOVEDIR)||fsync(journal)||fsync(parent))goto done;
        }
        data[12]=1;if(!CFWriteRecord(journal,data,YES))goto done;
        close(marker);marker=-1;marker=openat(journal,"intent.bin",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
        if(!CCFPrivate(marker,NO)||fstat(marker,&record)||record.st_size!=CCFRecordBytes||fsync(marker)||fsync(journal))goto done;
    } else if(flags&4)goto done;
    if(family==CCFRomFS){
        /* A producer may have recreated this name after an older process died.
         * Never unlink its shared sidecar or acknowledge that newer tree. The
         * producer interlock now refuses nonempty journals under this same EX
         * parent lock; still verify absence for pre-interlock/unknown state. */
        if(!fstatat(root,identifier.UTF8String,&named,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT||fsync(root))goto done;
        if(!fstatat(root,sidecar.UTF8String,&named,AT_SYMLINK_NOFOLLOW)){
            if(lease<0)lease=openat(root,sidecar.UTF8String,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
            if(!CFHeldName(lease,root,sidecar.UTF8String,CFGet(data+368),CFGet(data+376))||flock(lease,LOCK_EX|LOCK_NB)||unlinkat(root,sidecar.UTF8String,0)||fsync(root))goto done;
        }else if(errno!=ENOENT)goto done;
    }
    if(family==CCFMKRuntime){
        if(lease<0)lease=openat(parent,".lease",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
        if(!CFHeldName(lease,parent,".lease",CFGet(data+368),CFGet(data+376))||flock(lease,LOCK_EX|LOCK_NB))goto done;
        if(mkdirat(parent,"runtime",0700)&&errno!=EEXIST)goto done;
        int runtime=CCFChild(parent,"runtime");if(runtime<0)goto done;
        /* Phase1 never clears newly produced runtime output. */
        BOOL ready=YES;if(mkdirat(runtime,"temp",0700)&&errno!=EEXIST)ready=NO;
        int temp=ready?CCFChild(runtime,"temp"):-1;ready=ready&&temp>=0&&!fsync(temp)&&!fsync(runtime)&&!fsync(parent);if(temp>=0)close(temp);close(runtime);if(!ready)goto done;
    }
    if(family==CCFRomFS&&(!fstatat(root,identifier.UTF8String,&named,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT))goto done;
    if(fsync(root)||fsync(journal)||fstatat(journal,"intent.bin",&named,AT_SYMLINK_NOFOLLOW)||!CCFStable(&record,&named)||unlinkat(journal,"intent.bin",0)||fsync(journal))goto done;
    if(completed)*completed=identifier;ok=YES;
done:
    if(marker>=0)close(marker);if(lease>=0)close(lease);if(target>=0)close(target);if(parent>=0)close(parent);close(journal);return ok;
}
BOOL CCFRetire(int root,CCFFamily family,NSString *title,NSString *identifier,CCFValidation validate) {
    if(!CFIdentifier(family,title,identifier)||!validate)return NO;
    NSString *completed=nil;if(!CCFRecover(root,family,title,validate,&completed))return NO;if([completed isEqual:identifier])return YES;
    int parent=CFOperationParent(root,family,identifier);if(parent<0)return NO;
    const char *leaf=family==CCFMKRuntime?"runtime":identifier.UTF8String;
    int target=CCFChild(parent,leaf),lease=-1,journal=-1;BOOL ok=NO;struct stat folder={0},held={0};
    NSString *sidecar=family==CCFRomFS?[NSString stringWithFormat:@".%@.lease",identifier]:@"";
    int leaseParent=family==CCFMKIdentity?target:family==CCFMKRuntime?parent:root;
    lease=openat(leaseParent,family==CCFRomFS?sidecar.UTF8String:".lease",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(target<0||!CCFPrivate(lease,NO)||fstat(target,&folder)||fstat(lease,&held)||held.st_size||flock(lease,LOCK_EX|LOCK_NB)||!validate(parent,target,identifier))goto done;
    uint64_t bytes=0,count=0;if(!CFPayloadWalk(target,family,identifier,&bytes,&count,NO)||
        !CFName(parent,leaf,(uint64_t)folder.st_dev,(uint64_t)folder.st_ino,YES)||!CFName(leaseParent,family==CCFRomFS?sidecar.UTF8String:".lease",(uint64_t)held.st_dev,(uint64_t)held.st_ino,NO))goto done;
    const char *namespace=CFJournal(family);if(mkdirat(root,namespace,0700)&&errno!=EEXIST)goto done;
    journal=CCFChild(root,namespace);unsigned flags=0;if(journal<0||fsync(root)||!CFJournalShape(journal,&flags)||flags)goto done;
    unsigned char data[CCFRecordBytes]={0};memcpy(data,"CNPYCF01",8);data[8]=(unsigned char)family;memcpy(data+16,title.UTF8String,16);memcpy(data+32,identifier.UTF8String,identifier.length);memcpy(data+192,sidecar.UTF8String,sidecar.length);
    CFPut(data+352,(uint64_t)folder.st_dev);CFPut(data+360,(uint64_t)folder.st_ino);CFPut(data+368,(uint64_t)held.st_dev);CFPut(data+376,(uint64_t)held.st_ino);
    if(!CFWriteRecord(journal,data,NO))goto done;
    close(lease);lease=-1;close(target);target=-1;close(parent);parent=-1;close(journal);journal=-1;
    ok=CCFRecover(root,family,title,validate,NULL);
done:
    if(journal>=0)close(journal);if(lease>=0)close(lease);if(target>=0)close(target);if(parent>=0)close(parent);return ok;
}
