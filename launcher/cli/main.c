#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#include "mng_file.h"
#include "mng_crypto.h"
#include "mng_keys.h"
#include "mng_store.h"
#include "mng_folder.h"
#include "mng_install.h"
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/random.h> /* Darwin declares getentropy here, not unistd.h. */
#endif

/* Constant error codes deliberately omit private paths and platform errors. */
static int error(const char *code, int exit_code) {
    fprintf(stderr,"{\"error\":\"%s\",\"execution_verified\":false}\n",code);
    return exit_code;
}
static void json_string(const char *text) {
    putchar('"');
    for (const unsigned char *p=(const unsigned char *)text;*p;p++) {
        if (*p=='"' || *p=='\\') { putchar('\\'); putchar(*p); }
        else if (*p<0x20) printf("\\u%04x",(unsigned)*p);
        else putchar(*p); /* parser has already validated UTF-8 */
    }
    putchar('"');
}
static int inspect_command(int argc, char **argv) {
    if (argc!=3 || strcmp(argv[1],"inspect")) return error("usage",2);
    int fd=open(argv[2],O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if (fd<0) return error("open_failed",3);
    struct stat before, after;
    if (fstat(fd,&before)) { close(fd); return error("read_failed",4); }
    struct mng_inventory result={0};
    enum mng_status status=mng_inspect_fd(fd,&result);
    /* Bind source_size in the report to the inspected descriptor, including a
     * final check rather than reopening the pathname for a separate stat. */
    int size_valid=!fstat(fd,&after) && before.st_size==after.st_size;
    close(fd);
    if (status!=MNG_OK || !size_valid) {
        mng_inventory_free(&result);
        switch (status) {
            case MNG_INVALID: return error("invalid_container",4);
            case MNG_LIMIT: return error("resource_limit",4);
            case MNG_NOMEM: return error("out_of_memory",5);
            default: return error("read_failed",4);
        }
    }
    printf("{\"format\":\"%s\",\"count\":%zu,\"source_size\":%" PRIu64
           ",\"execution_verified\":false,\"entries\":[",
           result.kind==MNG_NSP ? "nsp":"xci",result.count,(uint64_t)before.st_size);
    for (size_t i=0;i<result.count;i++) {
        if (i) putchar(',');
        fputs("{\"name\":",stdout); json_string(result.entries[i].name);
        printf(",\"offset\":%" PRIu64 ",\"size\":%" PRIu64 "}",
               result.entries[i].offset,result.entries[i].size);
    }
    puts("]}");
    mng_inventory_free(&result);
    return ferror(stdout) ? 5:0;
}

static volatile sig_atomic_t interrupted;
static void interrupt_handler(int signum) { (void)signum;interrupted=1; }
static int interrupt_requested(void *context) { (void)context;return interrupted!=0; }
struct cancel_sink { struct mng_asset_sink sink; struct mng_store *store; };
static int cancelled(void *context) {
    struct cancel_sink *c=context;
    if(interrupted)mng_store_cancel(c->store);
    return interrupted || (c->sink.cancelled && c->sink.cancelled(c->sink.context));
}
static int asset_begin(void *context,const char *path,uint64_t length) {
    struct cancel_sink *c=context;
    return cancelled(c) ? -1:c->sink.begin(c->sink.context,path,length);
}
static int asset_write(void *context,const void *bytes,size_t length) {
    struct cancel_sink *c=context;
    return cancelled(c) ? -1:c->sink.write(c->sink.context,bytes,length);
}
static int asset_end(void *context,const unsigned char digest[32]) {
    struct cancel_sink *c=context;
    return cancelled(c) ? -1:c->sink.end(c->sink.context,digest);
}
static void progress(void *context,const char *phase,uint64_t done,uint64_t total) {
    struct cancel_sink *c=context;
    (void)cancelled(c);
    if(c->sink.progress)c->sink.progress(c->sink.context,phase,done,total);
}
static int stable(const struct stat *a,const struct stat *b) {
#ifdef __APPLE__
#define MNG_MT st_mtimespec
#define MNG_CT st_ctimespec
#else
#define MNG_MT st_mtim
#define MNG_CT st_ctim
#endif
    return a->st_dev==b->st_dev && a->st_ino==b->st_ino && a->st_size==b->st_size &&
        a->st_mode==b->st_mode && a->st_nlink==b->st_nlink &&
        a->MNG_MT.tv_sec==b->MNG_MT.tv_sec && a->MNG_MT.tv_nsec==b->MNG_MT.tv_nsec &&
        a->MNG_CT.tv_sec==b->MNG_CT.tv_sec && a->MNG_CT.tv_nsec==b->MNG_CT.tv_nsec;
}
static int read_keys(const char *path,struct mng_keys **keys) {
    int fd=open(path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC), result=-1;
    struct stat before,after;unsigned char *bytes=NULL,extra=0;size_t size=0,used=0;
    if(fd<0)return -1;
    if(fstat(fd,&before) || !S_ISREG(before.st_mode) || before.st_size<1 || before.st_size>1048576)goto done;
    size=(size_t)before.st_size;
    bytes=malloc(size);if(!bytes)goto done;
    while(used<size) {
        ssize_t n=read(fd,bytes+used,size-used);
        if(n<0 && errno==EINTR && !interrupted)continue;
        if(n<=0 || interrupted)goto done;
        used+=(size_t)n;
    }
    if(read(fd,&extra,1)!=0 || fstat(fd,&after) || !stable(&before,&after))goto done;
    result=mng_keys_parse(bytes,size,keys);
 done:
    mng_secure_clear(&extra,sizeof(extra));
    if(bytes){mng_secure_clear(bytes,size);free(bytes);}
    close(fd);return result;
}
static int job_valid(const char *job) {
    if(!job || strlen(job)!=32)return 0;
    for(unsigned i=0;i<32;i++)if(!((job[i]>='0'&&job[i]<='9')||(job[i]>='a'&&job[i]<='f')))return 0;
    return 1;
}
static void digest_hex(const unsigned char *bytes,size_t size,char *out) {
    static const char digits[]="0123456789abcdef";
    for(size_t i=0;i<size;i++){out[2*i]=digits[bytes[i]>>4];out[2*i+1]=digits[bytes[i]&15];}out[size*2]=0;
}
static int prepare_command(int argc,char **argv) {
    const char *key_path=NULL,*store_path=NULL,*job=NULL,*update_path=NULL,*version=NULL;
    struct mng_keys *keys=NULL;struct mng_store *store=NULL;
    struct mng_prepare_result prepared={0};
    int input=-1,update=-1,root=-1,result=4,publication_attempted=0,cancelled_result=0;const char *failure="prepare_failed";
    enum mng_prepare_status status;
    enum mng_folder_kind folder_kind=0;
    char generated_job[33],generation[65],source_hash[65];
    if(argc<5 || argc>13 || !(argc&1))return error("usage",2);
    for(int i=3;i<argc;i+=2) {
        if(!strcmp(argv[i],"--keys") && !key_path)key_path=argv[i+1];
        else if(!strcmp(argv[i],"--store") && !store_path)store_path=argv[i+1];
        else if(!strcmp(argv[i],"--job") && !job)job=argv[i+1];
        else if(!strcmp(argv[i],"--update") && !update_path)update_path=argv[i+1];
        else if(!strcmp(argv[i],"--version") && !version)version=argv[i+1];
        else return error("usage",2);
    }
    if(!store_path || (job && !job_valid(job)) || (version && !update_path))return error("usage",2);
    uint32_t target_version=0;
    int exact_version=version && strcmp(version,"latest");
    if(exact_version) {
        uint64_t parsed=0;size_t length=strlen(version);
        if(!length || length>10)return error("usage",2);
        for(size_t i=0;i<length;i++) {
            if(version[i]<'0' || version[i]>'9')return error("usage",2);
            parsed=parsed*10+(unsigned)(version[i]-'0');
            if(parsed>UINT32_MAX)return error("usage",2);
        }
        target_version=(uint32_t)parsed;
    }
    if(!job) {
        unsigned char random[16];
        if(getentropy(random,sizeof(random)))return error("random_failed",4);
        digest_hex(random,sizeof(random),generated_job);job=generated_job;
    }
    struct sigaction action={0};action.sa_handler=interrupt_handler;sigemptyset(&action.sa_mask);
    if(sigaction(SIGINT,&action,NULL))return error("signal_failed",4);
    input=open(argv[2],O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(input<0){failure="open_failed";goto done;}
    struct stat info;
    if(fstat(input,&info) || (!S_ISREG(info.st_mode) && !S_ISDIR(info.st_mode))){failure="invalid_source";goto done;}
    if(S_ISDIR(info.st_mode)) {
        if(update_path){failure="unsupported_folder_update";goto done;}
        status=mng_folder_kind_fd(input,&folder_kind);
        if(status!=MNG_PREPARE_OK){failure=mng_prepare_status_name(status);goto done;}
    }
    if(folder_kind!=MNG_FOLDER_ASSETS) {
        if(!key_path){failure="usage";result=2;goto done;}
        if(read_keys(key_path,&keys)){failure="keys_invalid";goto done;}
    }
    if(update_path) {
        update=open(update_path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
        if(update<0 || fstat(update,&info)){failure="invalid_update_source";goto done;}
        if(S_ISDIR(info.st_mode)){failure="unsupported_folder_update";goto done;}
        if(!S_ISREG(info.st_mode)){failure="invalid_update_source";goto done;}
    }
    if(mkdir(store_path,0700) && errno!=EEXIST){failure="store_open_failed";goto done;}
    root=open(store_path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(root<0 || fstat(root,&info) || (info.st_mode&077) || info.st_uid!=geteuid()) {failure="store_open_failed";goto done;}
    status=mng_store_open(root,&store);
    if(status!=MNG_PREPARE_OK){failure=mng_prepare_status_name(status);goto done;}
    mng_store_set_cancel_check(store,interrupt_requested,NULL);
    status=mng_store_begin(store,job);
    if(status!=MNG_PREPARE_OK){failure=mng_prepare_status_name(status);goto done;}
    struct cancel_sink wrapped={mng_store_sink(store),store};
    struct mng_asset_sink sink={&wrapped,asset_begin,asset_write,asset_end,cancelled,progress};
    struct mng_key_provider provider=mng_keys_provider(keys);
    if(folder_kind) status=mng_prepare_folder_fd(input,folder_kind,
        folder_kind==MNG_FOLDER_ASSETS ? NULL:&provider,NULL,&sink,&prepared);
    else if(update_path) status=exact_version ? mng_prepare_update_fd(input,update,&provider,&sink,target_version,&prepared):
        mng_prepare_latest_update_fd(input,update,&provider,&sink,&prepared);
    else status=mng_prepare_fd(input,&provider,&sink,&prepared);
    if(interrupted)status=MNG_PREPARE_CANCELLED;
    if(status==MNG_PREPARE_OK) {
        /* The store polls cancellation during verification and establishes its
         * own atomic publication cutoff. Its return is authoritative afterward. */
        publication_attempted=1;
        status=mng_store_commit(store,&prepared,generation);
    }
    if(status!=MNG_PREPARE_OK){cancelled_result=status==MNG_PREPARE_CANCELLED;failure=mng_prepare_status_name(status);goto done;}
    printf("{\"title_id\":\"%016" PRIx64 "\",\"generation\":\"%s\",\"job\":\"%s\","
           "\"asset_count\":%" PRIu64 ",\"asset_bytes\":%" PRIu64 ","
           "\"exefs_verified\":%s,\"romfs_verified\":%s,\"signature_verified\":false,\"execution_verified\":false,"
           "\"application_id\":\"%016" PRIx64 "\",\"title_version\":%" PRIu32 ",\"version_identified\":%s,\"update_applied\":%s",
           prepared.title_id,generation,job,prepared.asset_count,prepared.asset_bytes,
           prepared.exefs_verified?"true":"false",prepared.romfs_verified?"true":"false",prepared.application_id,
           prepared.title_version,prepared.version_identified?"true":"false",prepared.update_applied?"true":"false");
    if(prepared.source_kind) {
        digest_hex(prepared.member_inventory_sha256,32,source_hash);
        printf(",\"source_kind\":\"%s\",\"member_inventory_sha256\":\"%s\","
               "\"source_member_count\":%" PRIu32 ",\"source_member_bytes\":%" PRIu64 ","
               "\"asset_hashes_verified\":%s,\"romfs_structure_verified\":%s",
               prepared.source_kind==MNG_PREPARE_NCA_FOLDER ? "nca-folder":"asset-folder",source_hash,
               prepared.source_member_count,prepared.source_member_bytes,
               prepared.asset_hashes_verified ? "true":"false",prepared.romfs_structure_verified ? "true":"false");
    } else {
        digest_hex(prepared.source_sha256,32,source_hash);
        printf(",\"source_kind\":\"container\",\"source_sha256\":\"%s\"",source_hash);
    }
    if(prepared.update_applied) {
        char update_hash[65];digest_hex(prepared.update_source_sha256,32,update_hash);
        printf(",\"base_title_version\":%" PRIu32 ",\"patch_title_id\":\"%016" PRIx64 "\","
               "\"update_source_sha256\":\"%s\",\"update_source_size\":%" PRIu64,
               prepared.base_title_version,prepared.patch_title_id,update_hash,prepared.update_source_size);
    }
    puts("}");
    result=ferror(stdout)?5:0;
 done:
    mng_keys_free(keys);mng_store_close(store);
    if(input>=0)close(input);
    if(update>=0)close(update);
    if(root>=0)close(root);
    if(cancelled_result || (!publication_attempted && interrupted))return error("cancelled",130);
    return result ? error(failure,result):0;
}
static int fixed_hex(const char *value,size_t length) {
    if(!value || strlen(value)!=length)return 0;
    for(size_t i=0;i<length;i++)if(!((value[i]>='0'&&value[i]<='9')||(value[i]>='a'&&value[i]<='f')))return 0;
    return 1;
}
static int parse_title_id(const char *text,uint64_t *out) {
    if(!fixed_hex(text,16))return -1;
    uint64_t value=0;
    for(unsigned i=0;i<16;i++)value=(value<<4)|(unsigned)(text[i]<='9'?text[i]-'0':text[i]-'a'+10);
    if(!value)return -1;
    *out=value;return 0;
}
static void install_report(enum mng_prepare_status status,const struct mng_install_report *report,
    uint64_t application,uint64_t addon,const char *base_generation) {
    char source[65],cnmt[65],image[65],index[65];
    printf("{\"operation\":\"install-addon\",\"status\":\"%s\",\"requested_application_id\":\"%016" PRIx64
        "\",\"requested_addon_id\":\"%016" PRIx64 "\",\"base_generation\":\"%s\",\"job\":\"%s\",\"generation\":\"%s\","
        "\"commit_attempted\":%s,\"publication_uncertain\":%s,\"reload_required\":%s,\"current_readable\":%s,\"currentObserved\":",
        mng_prepare_status_name(status),application,addon,base_generation,report->job_id,report->generation_id,
        report->commit_attempted?"true":"false",report->publication_uncertain?"true":"false",
        report->reload_required?"true":"false",report->current_readable?"true":"false");
    if(report->current_readable)json_string(report->current_generation_id);else fputs("null",stdout);
    if(report->addon.title_id) {
        digest_hex(report->addon.source_sha256,32,source);digest_hex(report->addon.cnmt_sha256,32,cnmt);digest_hex(report->addon.romfs_sha256,32,image);
        printf(",\"prepared_kind\":\"addOn\",\"verified_base_version\":%" PRIu32 ",\"addon\":{\"application_id\":\"%016" PRIx64
            "\",\"title_id\":\"%016" PRIx64 "\",\"version\":%" PRIu32 ",\"required_application_version\":%" PRIu32
            ",\"source_size\":%" PRIu64 ",\"source_sha256\":\"%s\",\"cnmt_sha256\":\"%s\",\"romfs_size\":%" PRIu64
            ",\"romfs_sha256\":\"%s\",\"romfs_verified\":%s}",report->verified_base_version,report->addon.application_id,
            report->addon.title_id,report->addon.version,report->addon.required_application_version,report->addon.source_size,source,cnmt,
            report->addon.romfs_size,image,report->addon.romfs_verified?"true":"false");
    } else fputs(",\"verified_base_version\":null,\"addon\":null",stdout);
    if(report->index.index_size) {
        digest_hex(report->index.index_sha256,32,index);
        printf(",\"index\":{\"file_count\":%" PRIu64 ",\"size\":%" PRIu64 ",\"sha256\":\"%s\"}",
            report->index.file_count,report->index.index_size,index);
    } else fputs(",\"index\":null",stdout);
    puts(",\"execution_verified\":false,\"signature_verified\":false,\"activation_verified\":false}");
}
static int install_addon_command(int argc,char **argv) {
    const char *key_path=NULL,*store_path=NULL,*application_text=NULL,*base_generation=NULL,*addon_text=NULL,*job=NULL;
    uint64_t application=0,addon=0;int input=-1,root=-1;struct mng_keys *keys=NULL;
    const char *failure="install_failed";int result=4;
    if((argc!=13 && argc!=15))return error("usage",2);
    for(int i=3;i<argc;i+=2) {
        if(!strcmp(argv[i],"--keys")&&!key_path)key_path=argv[i+1];
        else if(!strcmp(argv[i],"--store")&&!store_path)store_path=argv[i+1];
        else if(!strcmp(argv[i],"--application-id")&&!application_text)application_text=argv[i+1];
        else if(!strcmp(argv[i],"--base-generation")&&!base_generation)base_generation=argv[i+1];
        else if(!strcmp(argv[i],"--addon-id")&&!addon_text)addon_text=argv[i+1];
        else if(!strcmp(argv[i],"--job")&&!job)job=argv[i+1];
        else return error("usage",2);
    }
    if(!key_path || !store_path || parse_title_id(application_text,&application) || parse_title_id(addon_text,&addon) ||
        application==addon || !fixed_hex(base_generation,64) || (job&&!job_valid(job)))return error("usage",2);
    struct sigaction action={0};action.sa_handler=interrupt_handler;sigemptyset(&action.sa_mask);
    if(sigaction(SIGINT,&action,NULL))return error("signal_failed",4);
    input=open(argv[2],O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);struct stat info;
    if(input<0){failure="open_failed";goto done;}
    if(fstat(input,&info)||!S_ISREG(info.st_mode)){failure="invalid_source";goto done;}
    if(read_keys(key_path,&keys)){failure=interrupted?"cancelled":"keys_invalid";result=interrupted?130:4;goto done;}
    root=open(store_path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(root<0||fstat(root,&info)||info.st_uid!=geteuid()||(info.st_mode&077)){failure="store_open_failed";goto done;}
    struct mng_key_provider provider=mng_keys_provider(keys);
    struct mng_install_control control={NULL,interrupt_requested,NULL,NULL};struct mng_install_report report={0};
    enum mng_prepare_status status=mng_install_addon_fd(root,input,&provider,application,base_generation,addon,job,&control,&report);
    // The install/store publication cutoff is authoritative. A late SIGINT or
    // commit IO must not be rewritten into an assertion that nothing published.
    install_report(status,&report,application,addon,base_generation);
    mng_keys_free(keys);close(input);close(root);
    if(ferror(stdout))return 5;
    return status==MNG_PREPARE_OK?0:status==MNG_PREPARE_CANCELLED?130:4;
 done:
    mng_keys_free(keys);if(input>=0)close(input);if(root>=0)close(root);return error(failure,result);
}
int main(int argc,char **argv) {
    if(argc>=2 && !strcmp(argv[1],"prepare"))return prepare_command(argc,argv);
    if(argc>=2 && !strcmp(argv[1],"install-addon"))return install_addon_command(argc,argv);
    return inspect_command(argc,argv);
}
