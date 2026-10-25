#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include "mng_install.h"
#include "mng_store.h"
#include "mng_crypto.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
struct installation {struct mng_asset_sink sink;const struct mng_install_control *control;};
static int valid_hex(const char *p,size_t n){if(!p||strlen(p)!=n)return 0;for(size_t i=0;i<n;i++)if(!((p[i]>='0'&&p[i]<='9')||(p[i]>='a'&&p[i]<='f')))return 0;return 1;}
static int cancel(void *context){struct installation *i=context;return i->control&&i->control->cancelled&&i->control->cancelled(i->control->context);}
static int stopped(void *context){struct installation *i=context;return i->sink.cancelled(i->sink.context);}
static int begin(void *context,const char *p,uint64_t n){struct installation *i=context;return i->sink.begin(i->sink.context,p,n);}
static int write_asset(void *context,const void *p,size_t n){struct installation *i=context;return i->sink.write(i->sink.context,p,n);}
static int end(void *context,const unsigned char sha[32]){struct installation *i=context;return i->sink.end(i->sink.context,sha);}
static void progress(void *context,const char *phase,uint64_t done,uint64_t total){struct installation *i=context;if(i->control&&i->control->progress)i->control->progress(i->control->context,phase,done,total);}
static void index_progress(void *context,uint64_t done,uint64_t total){progress(context,"index-addon-romfs",done,total);}
static int canonical(void *context,const char *name,char *out,size_t capacity){struct installation *i=context;return i->control->canonical_name(i->control->context,name,out,capacity);}
static int private_fd(int fd,int directory,struct stat *st){return fd>=0&&!fstat(fd,st)&&(directory?S_ISDIR(st->st_mode):S_ISREG(st->st_mode))&&st->st_uid==geteuid()&&!(st->st_mode&077)&&(directory||st->st_nlink==1);}
static int same(const struct stat *a,const struct stat *b){
#ifdef __APPLE__
    const struct timespec am=a->st_mtimespec,bm=b->st_mtimespec,ac=a->st_ctimespec,bc=b->st_ctimespec;
#else
    const struct timespec am=a->st_mtim,bm=b->st_mtim,ac=a->st_ctim,bc=b->st_ctim;
#endif
    return a->st_dev==b->st_dev&&a->st_ino==b->st_ino&&a->st_size==b->st_size&&a->st_mode==b->st_mode&&a->st_nlink==b->st_nlink&&
        am.tv_sec==bm.tv_sec&&am.tv_nsec==bm.tv_nsec&&ac.tv_sec==bc.tv_sec&&ac.tv_nsec==bc.tv_nsec;
}
static int random_job(char out[33]){
    unsigned char bytes[16];int fd=open("/dev/urandom",O_RDONLY|O_CLOEXEC);if(fd<0)return -1;size_t used=0;
    while(used<sizeof(bytes)){ssize_t n=read(fd,bytes+used,sizeof(bytes)-used);if(n<0&&errno==EINTR)continue;if(n<=0){close(fd);mng_secure_clear(bytes,sizeof(bytes));return -1;}used+=(size_t)n;}
    close(fd);static const char hex[]="0123456789abcdef";for(size_t i=0;i<16;i++){out[2*i]=hex[bytes[i]>>4];out[2*i+1]=hex[bytes[i]&15];}out[32]=0;mng_secure_clear(bytes,sizeof(bytes));return 0;
}
static enum mng_prepare_status index_status(enum mng_romfs_status status){switch(status){case MNG_ROMFS_OK:return MNG_PREPARE_OK;case MNG_ROMFS_IO:return MNG_PREPARE_IO;case MNG_ROMFS_LIMIT:return MNG_PREPARE_LIMIT;case MNG_ROMFS_NOMEM:return MNG_PREPARE_NOMEM;case MNG_ROMFS_UNSUPPORTED:return MNG_PREPARE_UNSUPPORTED;case MNG_ROMFS_CANCELLED:return MNG_PREPARE_CANCELLED;default:return MNG_PREPARE_INVALID;}}
static enum mng_prepare_status stream_index(struct installation *i,int fd,const struct mng_romfs_runtime_result *index){
    if(stopped(i))return MNG_PREPARE_CANCELLED;
    if(i->sink.begin(i->sink.context,"runtime-index.bin",index->index_size))return stopped(i)?MNG_PREPARE_CANCELLED:MNG_PREPARE_IO;
    struct stat before,after;if(!private_fd(fd,0,&before)||(uint64_t)before.st_size!=index->index_size)return MNG_PREPARE_IO;
    unsigned char *bytes=malloc(65536);struct mng_sha256 *hash=NULL;if(!bytes||mng_sha256_init(&hash)){free(bytes);return MNG_PREPARE_NOMEM;}
    enum mng_prepare_status status=MNG_PREPARE_OK;unsigned char digest[32];
    for(uint64_t at=0;at<index->index_size;){
        if(stopped(i)){status=MNG_PREPARE_CANCELLED;break;}
        uint64_t remaining=index->index_size-at;
        size_t request=remaining<65536 ? (size_t)remaining:65536;
        ssize_t got=pread(fd,bytes,request,(off_t)at);
        if(got<0 && errno==EINTR)continue;
        if(got<=0 || (size_t)got>request){status=MNG_PREPARE_IO;break;}
        size_t n=(size_t)got;
        if(mng_sha256_update(hash,bytes,n)||i->sink.write(i->sink.context,bytes,n)){status=stopped(i)?MNG_PREPARE_CANCELLED:MNG_PREPARE_IO;break;}
        at+=n;progress(i,"write-addon-index",at,index->index_size);
    }
    if(!status&&(mng_sha256_final(hash,digest)||memcmp(digest,index->index_sha256,32)||fstat(fd,&after)||!same(&before,&after)))status=MNG_PREPARE_INTEGRITY;
    if(!status&&stopped(i))status=MNG_PREPARE_CANCELLED;
    if(!status&&i->sink.end(i->sink.context,index->index_sha256))status=stopped(i)?MNG_PREPARE_CANCELLED:MNG_PREPARE_IO;
    mng_sha256_free(hash);free(bytes);return status;
}
enum mng_prepare_status mng_install_addon_fd(int root,int source,const struct mng_key_provider *keys,uint64_t application,
    const char *base_generation,uint64_t addon,const char *job,const struct mng_install_control *control,struct mng_install_report *report){
    if(!report)return MNG_PREPARE_INVALID;
    memset(report,0,sizeof(*report));
    if(!keys||!keys->lookup||!application||!addon||addon==application||!valid_hex(base_generation,64)||(job&&!valid_hex(job,32)))return MNG_PREPARE_INVALID;
    if(job)memcpy(report->job_id,job,33);else if(random_job(report->job_id))return MNG_PREPARE_IO;
    struct mng_store *store=NULL;int jobs=-1,stage=-1,image=-1,index=-1,temp_created=0;struct stat temp_identity={0};
    struct installation context={0};context.control=control;
    enum mng_prepare_status status=mng_store_open(root,&store);if(status)return status;
    mng_store_set_cancel_check(store,cancel,&context);
    struct mng_prepare_result base={0};status=mng_store_verify(store,application,base_generation,&base);if(status)goto done;
    if(base.title_id!=application||base.application_id!=application||base.version_identified!=1||base.source_kind||
        (base.content_role!=0x80&&base.content_role!=0x81)||base.exefs_verified!=1||base.romfs_verified!=1){status=MNG_PREPARE_UNSUPPORTED;goto done;}
    report->verified_base_version=base.title_version;
    status=mng_store_begin(store,report->job_id);if(status)goto done;context.sink=mng_store_sink(store);
    struct mng_asset_sink sink={&context,begin,write_asset,end,stopped,progress};
    struct mng_addon_base owner={application,base.title_version,1};
    status=mng_prepare_addon_fd(source,keys,&sink,&owner,addon,&report->addon);if(status)goto done;
    jobs=openat(root,"jobs",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);struct stat st;
    if(!private_fd(jobs,1,&st)){status=MNG_PREPARE_IO;goto done;}
    stage=openat(jobs,report->job_id,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(!private_fd(stage,1,&st)){status=MNG_PREPARE_IO;goto done;}
    image=openat(stage,"romfs.bin",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(!private_fd(image,0,&st)||st.st_size<0||(uint64_t)st.st_size!=report->addon.romfs_size){status=MNG_PREPARE_INTEGRITY;goto done;}
    index=openat(stage,".runtime-index.tmp",O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(index<0){status=MNG_PREPARE_IO;goto done;}temp_created=1;
    if(fstat(index,&temp_identity)){status=MNG_PREPARE_IO;goto done;}
    struct mng_romfs_callbacks callbacks={0};callbacks.context=&context;callbacks.cancelled=stopped;callbacks.progress=index_progress;
    if(control&&control->canonical_name)callbacks.canonical_name=canonical;
    progress(&context,"index-addon-romfs",0,0);
    status=index_status(mng_romfs_runtime_index_fd_ex(image,index,&callbacks,MNG_ROMFS_RUNTIME_ALLOW_EMPTY,&report->index));if(status)goto done;
    if(report->index.index_size>(34u<<20)||report->addon.romfs_size>MNG_STORE_MAX_BYTES-report->index.index_size){status=MNG_PREPARE_LIMIT;goto done;}
    status=stream_index(&context,index,&report->index);if(status)goto done;
    if(fstatat(stage,".runtime-index.tmp",&st,AT_SYMLINK_NOFOLLOW)||st.st_dev!=temp_identity.st_dev||st.st_ino!=temp_identity.st_ino||
        !S_ISREG(st.st_mode)||st.st_nlink!=1||unlinkat(stage,".runtime-index.tmp",0)||fsync(stage)){status=MNG_PREPARE_IO;goto done;}temp_created=0;
    struct mng_prepare_result prepared={0};prepared.title_id=report->addon.title_id;prepared.application_id=application;
    prepared.title_version=report->addon.version;prepared.version_identified=1;prepared.content_role=0x82;
    prepared.source_size=report->addon.source_size;memcpy(prepared.source_sha256,report->addon.source_sha256,32);
    prepared.romfs_verified=1;prepared.asset_count=2;prepared.asset_bytes=report->addon.romfs_size+report->index.index_size;
    prepared.addon_required_application_version=report->addon.required_application_version;memcpy(prepared.addon_cnmt_sha256,report->addon.cnmt_sha256,32);
    progress(&context,"commit-addon",0,0);report->commit_attempted=1;
    status=mng_store_commit(store,&prepared,report->generation_id);
    report->publication_uncertain=status==MNG_PREPARE_IO;report->reload_required=status!=MNG_PREPARE_OK;
    if(mng_store_current(store,addon,report->current_generation_id)==MNG_PREPARE_OK)report->current_readable=1;
done:
    if(temp_created&&stage>=0){struct stat now;if(!fstatat(stage,".runtime-index.tmp",&now,AT_SYMLINK_NOFOLLOW)&&
        now.st_dev==temp_identity.st_dev&&now.st_ino==temp_identity.st_ino&&S_ISREG(now.st_mode)&&now.st_nlink==1){if(unlinkat(stage,".runtime-index.tmp",0)||fsync(stage))status=MNG_PREPARE_IO;}}
    if(index>=0)close(index);
    if(image>=0)close(image);
    if(stage>=0)close(stage);
    if(jobs>=0)close(jobs);
    mng_store_close(store);return status;
}
