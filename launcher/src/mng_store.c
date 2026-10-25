#define _GNU_SOURCE
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L
#include "mng_store.h"
#include "mng_crypto.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <linux/fs.h>
#elif defined(__APPLE__)
#include <sys/clonefile.h>
#endif

#define PATH_BYTES 80u
#define RECORD_BYTES 120u
#define HEADER_BYTES 80u
#define HEADER_V2_BYTES 104u
#define HEADER_V3_BYTES 160u
#define HEADER_V4_BYTES 216u
#define HEADER_V5_BYTES 144u
#define MANIFEST_BYTES 32768u
struct asset { char path[PATH_BYTES]; uint64_t size; unsigned char sha[32]; };
struct mng_store {
    int root, lock, jobs, titles, job, output, destination;
    _Atomic int cancelled;
    int (*cancel_check)(void *context);
    void *cancel_context;
    int replay, failed;
    char job_id[33], pending[PATH_BYTES];
    uint64_t expected, written, total;
    size_t count;
    struct asset assets[MNG_STORE_MAX_ASSETS];
    struct mng_sha256 *hash;
    int reuse_root,reuse_lease,cloned;
    uint64_t cloned_overlap;
    uint64_t reuse_title,reuse_application;
    size_t reuse_count;
    struct asset reuse_assets[MNG_STORE_MAX_ASSETS];
    unsigned char *compare;
    struct mng_store_io_metrics metrics;
};
static int rename_exclusive(int from, const char *source, int to, const char *destination);
static int recover_retirement(struct mng_store *s,uint64_t *completed_title,char completed_gen[65]);
static int poll_cancel(struct mng_store *s) {
    if (!s) return 0;
    int state=atomic_load(&s->cancelled);
    if (state==1) return 1;
    /* Publication already crossed its defined cancellation boundary. */
    if (state==2) return 0;
    if (s->cancel_check && s->cancel_check(s->cancel_context)) mng_store_cancel(s);
    return atomic_load(&s->cancelled)==1;
}
static int hex_valid(const char *s, size_t length) {
    if (!s || strlen(s)!=length) return 0;
    for (size_t i=0;i<length;i++) if (!((s[i]>='0' && s[i]<='9') || (s[i]>='a' && s[i]<='f'))) return 0;
    return 1;
}
static void hex(const unsigned char *bytes, size_t count, char *out) {
    static const char digits[]="0123456789abcdef";
    for (size_t i=0;i<count;i++) { out[2*i]=digits[bytes[i]>>4]; out[2*i+1]=digits[bytes[i]&15]; }
    out[2*count]=0;
}
static int leaf(const char *p) {
    size_t n=strlen(p);
    if (!n || n>64 || !strcmp(p,".") || !strcmp(p,"..")) return 0;
    for (;*p;p++) if (!((*p>='a' && *p<='z') || (*p>='A' && *p<='Z') ||
        (*p>='0' && *p<='9') || *p=='.' || *p=='_' || *p=='-')) return 0;
    return 1;
}
static int asset_path(const char *p) {
    return p && (!strcmp(p,"romfs.bin") || !strcmp(p,"runtime-index.bin") || !strcmp(p,"input-members.json") || (!strncmp(p,"exefs/",6) && leaf(p+6)));
}
static int same_path(const char *a, const char *b) {
    while (*a && *b) {
        unsigned char x=(unsigned char)*a++, y=(unsigned char)*b++;
        if (x>='A' && x<='Z') x=(unsigned char)(x+32);
        if (y>='A' && y<='Z') y=(unsigned char)(y+32);
        if (x!=y) return 0;
    }
    return *a==*b;
}
static int write_all(int fd, const void *bytes, size_t n) {
    const unsigned char *p=bytes;
    while (n) { ssize_t wrote=write(fd,p,n); if (wrote<0 && errno==EINTR) continue;
        if (wrote<=0) return -1;
        p+=(size_t)wrote; n-=(size_t)wrote; }
    return 0;
}
static int read_all(int fd, void *bytes, size_t n) {
    unsigned char *p=bytes;
    while (n) { ssize_t got=read(fd,p,n); if (got<0 && errno==EINTR) continue;
        if (got<=0) return -1;
        p+=(size_t)got; n-=(size_t)got; }
    return 0;
}
static int regular(int fd, uint64_t limit, struct stat *out) {
    struct stat st;
    if (fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_nlink!=1 || st.st_size<0 ||
        (uint64_t)st.st_size>limit) return -1;
    if (out) *out=st;
    return 0;
}
static int directory(int parent, const char *name, int create) {
    if (create) {
        if (!mkdirat(parent,name,0700)) { if (fsync(parent)) return -1; }
        else if (errno!=EEXIST) return -1;
    }
    int fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    struct stat st;
    if (fd>=0 && (fstat(fd,&st) || !S_ISDIR(st.st_mode) || st.st_uid!=geteuid())) { close(fd); return -1; }
    return fd;
}
static int duplicate_fd(int fd) { return fcntl(fd,F_DUPFD_CLOEXEC,0); }
/* dup shares a directory's iteration offset; each validation must begin with
 * a fresh open file description, even after recovery scanned the same job. */
static int directory_iterator(int fd) {
    return openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
}
static int safe_unlink(int parent, const char *name) {
    struct stat st;
    if (fstatat(parent,name,&st,AT_SYMLINK_NOFOLLOW)) return errno==ENOENT ? 0:-1;
    if (!S_ISREG(st.st_mode) || st.st_nlink!=1) return -1;
    return unlinkat(parent,name,0);
}
static int replace_file(int dir, const char *name, const char *temporary, const void *data, size_t n) {
    if (safe_unlink(dir,temporary)) return -1;
    int fd=openat(dir,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if (fd<0) return -1;
    int failed=write_all(fd,data,n) || fsync(fd);
    if (close(fd)) failed=1;
    if (!failed && renameat(dir,temporary,dir,name)) failed=1;
    if (!failed && fsync(dir)) failed=1;
    if (failed) (void)safe_unlink(dir,temporary);
    return failed ? -1:0;
}
static void put64(unsigned char *p, uint64_t n) { for (unsigned i=0;i<8;i++) { p[i]=(unsigned char)n; n>>=8; } }
static uint64_t get64(const unsigned char *p) { uint64_t n=0; for (unsigned i=0;i<8;i++) n|=(uint64_t)p[i]<<(8*i); return n; }
static void put32(unsigned char *p, uint32_t n) { for (unsigned i=0;i<4;i++) { p[i]=(unsigned char)n; n>>=8; } }
static uint32_t get32(const unsigned char *p) { uint32_t n=0; for (unsigned i=0;i<4;i++) n|=(uint32_t)p[i]<<(8*i); return n; }
static int identity_valid(const struct mng_prepare_result *r) {
    static const unsigned char zero[32]={0};
    if (r->content_role==0x82) {
        return r->title_id && r->application_id && r->application_id!=r->title_id && r->version_identified==1 &&
            r->source_size && r->source_size<=(UINT64_C(128)<<30) && memcmp(r->source_sha256,zero,32) &&
            memcmp(r->addon_cnmt_sha256,zero,32) && r->exefs_verified==0 && r->romfs_verified==1 &&
            !r->source_kind && !r->source_member_bytes && !r->source_member_count && !r->asset_hashes_verified &&
            !r->romfs_structure_verified && !memcmp(r->member_inventory_sha256,zero,32) &&
            !r->update_applied && !r->update_source_size && !r->patch_title_id && !r->base_title_version &&
            !memcmp(r->update_source_sha256,zero,32);
    }
    if (r->addon_required_application_version || memcmp(r->addon_cnmt_sha256,zero,32)) return 0;
    if (r->source_kind) {
        if ((r->source_kind!=MNG_PREPARE_NCA_FOLDER && r->source_kind!=MNG_PREPARE_ASSET_FOLDER) ||
            !r->title_id || r->application_id!=r->title_id || r->source_size || memcmp(r->source_sha256,zero,32) ||
            !r->source_member_count || r->source_member_count>512 || !r->source_member_bytes ||
            r->source_member_bytes>(UINT64_C(128)<<30) || !memcmp(r->member_inventory_sha256,zero,32) ||
            r->asset_hashes_verified!=1 || (r->romfs_structure_verified!=0 && r->romfs_structure_verified!=1) ||
            r->update_applied || r->update_source_size || r->patch_title_id || r->base_title_version ||
            memcmp(r->update_source_sha256,zero,32)) return 0;
        if (r->source_kind==MNG_PREPARE_ASSET_FOLDER)
            return r->version_identified==0 && !r->title_version && !r->content_role &&
                r->exefs_verified==0 && r->romfs_verified==0 && r->romfs_structure_verified==1;
        if (r->exefs_verified!=1 || r->romfs_verified!=1) return 0;
        return (r->version_identified==1 && r->content_role==0x80) ||
            (r->version_identified==0 && !r->title_version && !r->content_role);
    }
    if (r->source_member_bytes || r->source_member_count || r->asset_hashes_verified ||
        r->romfs_structure_verified || memcmp(r->member_inventory_sha256,zero,32)) return 0;
    if (r->update_applied==1) return r->version_identified==1 && r->title_id && r->application_id==r->title_id &&
        r->content_role==0x81 && r->patch_title_id && r->patch_title_id!=r->title_id &&
        r->base_title_version<=r->title_version && r->update_source_size;
    if (r->update_applied || r->update_source_size || r->patch_title_id || r->base_title_version ||
        memcmp(r->update_source_sha256,zero,32)) return 0;
    if (r->version_identified==1) return r->title_id && r->application_id==r->title_id && r->content_role==0x80;
    return r->version_identified==0 && !r->title_version && !r->content_role &&
        (!r->application_id || r->application_id==r->title_id);
}
static const char *recipe_for(const struct mng_prepare_result *r) {
    if (r->content_role==0x82) return MNG_STORE_RECIPE_V5;
    if (r->source_kind) return MNG_STORE_RECIPE_V4;
    if (r->update_applied) return MNG_STORE_RECIPE_V3;
    return r->version_identified ? MNG_STORE_RECIPE_V2:MNG_STORE_RECIPE;
}
static int asset_parent(int root, const char *path, int create, const char **name) {
    if (!asset_path(path)) return -1;
    if (!strncmp(path,"exefs/",6)) { *name=path+6; return directory(root,"exefs",create); }
    *name=path; return duplicate_fd(root);
}
static int hash_asset(int root, const struct asset *asset, struct mng_store *cancel_store) {
    if (poll_cancel(cancel_store)) return -2;
    const char *name;
    int parent=asset_parent(root,asset->path,0,&name);
    if (parent<0) return -1;
    int fd=openat(parent,name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC); close(parent);
    if (fd<0) return -1;
    struct stat before={0}, after={0};
    struct mng_sha256 *hash_state=NULL;
    int bad=regular(fd,asset->size,&before) || (uint64_t)before.st_size!=asset->size || mng_sha256_init(&hash_state);
    unsigned char buffer[65536], digest[32]; uint64_t remaining=asset->size;
    while (!bad && remaining) {
        if (poll_cancel(cancel_store)) { bad=2; break; }
        size_t n=remaining>sizeof(buffer) ? sizeof(buffer):(size_t)remaining;
        if (read_all(fd,buffer,n) || mng_sha256_update(hash_state,buffer,n)) { bad=1; break; }
        remaining-=n;
    }
    if (poll_cancel(cancel_store)) bad=2;
    if (!bad && (mng_sha256_final(hash_state,digest) || memcmp(digest,asset->sha,32))) bad=1;
    if (!bad && (fstat(fd,&after) || before.st_size!=after.st_size || before.st_ino!=after.st_ino ||
        before.st_dev!=after.st_dev || before.st_nlink!=after.st_nlink)) bad=1;
#ifdef __APPLE__
    if (!bad && (before.st_mtimespec.tv_sec!=after.st_mtimespec.tv_sec || before.st_mtimespec.tv_nsec!=after.st_mtimespec.tv_nsec ||
        before.st_ctimespec.tv_sec!=after.st_ctimespec.tv_sec || before.st_ctimespec.tv_nsec!=after.st_ctimespec.tv_nsec)) bad=1;
#else
    if (!bad && (before.st_mtim.tv_sec!=after.st_mtim.tv_sec || before.st_mtim.tv_nsec!=after.st_mtim.tv_nsec ||
        before.st_ctim.tv_sec!=after.st_ctim.tv_sec || before.st_ctim.tv_nsec!=after.st_ctim.tv_nsec)) bad=1;
#endif
    mng_sha256_free(hash_state); close(fd); return bad==2 ? -2:bad ? -1:0;
}
static unsigned char *receipt(const struct asset *assets, size_t count, const struct mng_prepare_result *r, size_t *length) {
    int addon=r && r->content_role==0x82;
    int folder=r && r->source_kind;
    int applied=r && r->update_applied;
    int identified=r && r->version_identified;
    size_t header=addon ? HEADER_V5_BYTES:folder ? HEADER_V4_BYTES:applied ? HEADER_V3_BYTES:identified ? HEADER_V2_BYTES:HEADER_BYTES;
    *length=header+count*RECORD_BYTES;
    unsigned char *data=calloc(1,*length); if (!data) return NULL;
    memcpy(data,addon ? "CNPYST05":folder ? "CNPYST04":applied ? "CNPYST03":identified ? "CNPYST02":"CNPYST01",8); put64(data+24,count);
    uint64_t total=0;
    for (size_t i=0;i<count;i++) {
        unsigned char *record=data+header+i*RECORD_BYTES;
        memcpy(record,assets[i].path,strlen(assets[i].path)); put64(record+80,assets[i].size);
        memcpy(record+88,assets[i].sha,32); total+=assets[i].size;
    }
    put64(data+32,total);
    if (r) { put64(data+8,r->title_id); put64(data+16,r->source_size); memcpy(data+40,r->source_sha256,32);
        data[72]=(unsigned char)r->exefs_verified; data[73]=(unsigned char)r->romfs_verified;
        if (identified || folder) { put64(data+80,r->application_id); put32(data+88,r->title_version);
            data[92]=(unsigned char)r->version_identified; data[93]=r->content_role; }
        if (applied) { put64(data+104,r->update_source_size); put64(data+112,r->patch_title_id);
            put32(data+120,r->base_title_version); data[124]=1; memcpy(data+128,r->update_source_sha256,32); }
        if (folder) {
            data[160]=r->source_kind; data[161]=(unsigned char)r->asset_hashes_verified;
            data[162]=(unsigned char)r->romfs_structure_verified; memcpy(data+168,r->member_inventory_sha256,32);
            put64(data+200,r->source_member_bytes); put32(data+208,r->source_member_count);
        }
        if (addon) { put32(data+104,r->addon_required_application_version); memcpy(data+112,r->addon_cnmt_sha256,32); }
    }
    return data;
}
static int save_receipt(int dir, const struct asset *assets, size_t count, const struct mng_prepare_result *r) {
    size_t size; unsigned char *data=receipt(assets,count,r,&size); if (!data) return -1;
    int status=replace_file(dir,"receipt.bin",".receipt.tmp",data,size); free(data); return status;
}
static int load_receipt(int dir, struct asset *assets, size_t *count, struct mng_prepare_result *r) {
    int fd=openat(dir,"receipt.bin",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if (fd<0) return -1;
    struct stat st; unsigned char data[HEADER_V4_BYTES+MNG_STORE_MAX_ASSETS*RECORD_BYTES];
    int bad=regular(fd,sizeof(data),&st) || st.st_size<HEADER_BYTES;
    if (!bad) bad=read_all(fd,data,(size_t)st.st_size);
    close(fd);
    if (bad) return -1;
    int addon=!memcmp(data,"CNPYST05",8);
    int folder=!memcmp(data,"CNPYST04",8);
    int applied=!memcmp(data,"CNPYST03",8);
    int identified=addon || applied || !memcmp(data,"CNPYST02",8);
    if (!folder && !identified && memcmp(data,"CNPYST01",8)) return -1;
    size_t header=addon ? HEADER_V5_BYTES:folder ? HEADER_V4_BYTES:applied ? HEADER_V3_BYTES:identified ? HEADER_V2_BYTES:HEADER_BYTES;
    uint64_t n=get64(data+24), total=0;
    if (n>MNG_STORE_MAX_ASSETS || header+n*RECORD_BYTES!=(uint64_t)st.st_size || data[72]>1 || data[73]>1) return -1;
    for (size_t i=74;i<HEADER_BYTES;i++) if (data[i]) return -1;
    if (identified || folder) {
        if (folder ? data[92]>1:data[92]!=1) return -1;
        if (addon && data[93]!=0x82) return -1;
        for (size_t i=94;i<HEADER_V2_BYTES;i++) if (data[i]) return -1;
    }
    if (applied) {
        if (data[124]!=1) return -1;
        for (size_t i=125;i<128;i++) if (data[i]) return -1;
    }
    if (folder) {
        if ((data[160]!=MNG_PREPARE_NCA_FOLDER && data[160]!=MNG_PREPARE_ASSET_FOLDER) || data[161]!=1 || data[162]>1) return -1;
        for (size_t i=104;i<160;i++) if (data[i]) return -1;
        for (size_t i=163;i<168;i++) if (data[i]) return -1;
        for (size_t i=212;i<HEADER_V4_BYTES;i++) if (data[i]) return -1;
    }
    if (addon) for (size_t i=108;i<112;i++) if (data[i]) return -1;
    for (size_t i=0;i<(size_t)n;i++) {
        const unsigned char *record=data+header+i*RECORD_BYTES;
        if (!memchr(record,0,PATH_BYTES) || !asset_path((const char *)record)) return -1;
        size_t path_length=strlen((const char *)record);
        for (size_t j=path_length;j<PATH_BYTES;j++) if (record[j]) return -1;
        memcpy(assets[i].path,record,PATH_BYTES); assets[i].size=get64(record+80); memcpy(assets[i].sha,record+88,32);
        if (assets[i].size>MNG_STORE_MAX_BYTES-total) return -1;
        total+=assets[i].size;
        for (size_t j=0;j<i;j++) if (same_path(assets[i].path,assets[j].path)) return -1;
    }
    if (total!=get64(data+32)) return -1;
    memset(r,0,sizeof(*r)); r->title_id=get64(data+8); r->source_size=get64(data+16);
    r->asset_count=n; r->asset_bytes=total; memcpy(r->source_sha256,data+40,32);
    r->exefs_verified=data[72]; r->romfs_verified=data[73];
    r->application_id=(identified || folder) ? get64(data+80):r->title_id;
    if (identified || folder) { r->title_version=get32(data+88); r->version_identified=data[92]; r->content_role=data[93]; }
    if (applied) { r->update_applied=1; r->update_source_size=get64(data+104); r->patch_title_id=get64(data+112);
        r->base_title_version=get32(data+120); memcpy(r->update_source_sha256,data+128,32); }
    if (folder) {
        r->source_kind=data[160]; r->asset_hashes_verified=data[161]; r->romfs_structure_verified=data[162];
        memcpy(r->member_inventory_sha256,data+168,32); r->source_member_bytes=get64(data+200); r->source_member_count=get32(data+208);
    }
    if (addon) { r->addon_required_application_version=get32(data+104); memcpy(r->addon_cnmt_sha256,data+112,32); }
    if (!identity_valid(r)) return -1;
    *count=(size_t)n;
    return 0;
}
static int compare_assets(const void *left, const void *right) {
    return strcmp(((const struct asset *)left)->path,((const struct asset *)right)->path);
}
static int generation(const struct asset *assets, size_t count, const struct mng_prepare_result *r, char out[65]) {
    size_t length; unsigned char *data=receipt(assets,count,r,&length), digest[32];
    if (!data) return -1;
    struct mng_sha256 *hash_state=NULL;
    const char *recipe=recipe_for(r);
    int bad=mng_sha256_init(&hash_state) || mng_sha256_update(hash_state,recipe,strlen(recipe)+1) ||
        mng_sha256_update(hash_state,data,length) || mng_sha256_final(hash_state,digest);
    mng_sha256_free(hash_state); free(data); if (bad) return -1;
    hex(digest,32,out); return 0;
}
static char *manifest(const struct asset *assets, size_t count, const struct mng_prepare_result *r, const char *gen) {
    char *json=calloc(1,MANIFEST_BYTES), sha[65]; if (!json) return NULL;
    hex(r->source_sha256,32,sha);
    int n;
    if (r->source_kind) {
        char inventory[65]; hex(r->member_inventory_sha256,32,inventory);
        n=snprintf(json,MANIFEST_BYTES,"{\"schemaVersion\":4,\"titleID\":\"%016" PRIx64 "\",\"generationID\":\"%s\",\"recipeID\":\"%s\","
            "\"sourceKind\":\"%s\",\"memberInventorySHA256\":\"%s\",\"sourceMemberBytes\":%" PRIu64 ",\"sourceMemberCount\":%" PRIu32,
            r->title_id,gen,recipe_for(r),r->source_kind==MNG_PREPARE_NCA_FOLDER ? "nca-folder":"asset-folder",
            inventory,r->source_member_bytes,r->source_member_count);
    } else n=snprintf(json,MANIFEST_BYTES,"{\"schemaVersion\":%u,\"titleID\":\"%016" PRIx64 "\",\"generationID\":\"%s\",\"recipeID\":\"%s\",\"sourceSHA256\":\"%s\",\"sourceSize\":%" PRIu64,
        r->content_role==0x82 ? 5u:r->update_applied ? 3u:r->version_identified ? 2u:1u,r->title_id,gen,recipe_for(r),sha,r->source_size);
    if (n<0 || (size_t)n>=MANIFEST_BYTES) { free(json); return NULL; }
    size_t used=(size_t)n;
    if (r->content_role==0x82) {
        char cnmt[65]; hex(r->addon_cnmt_sha256,32,cnmt);
        n=snprintf(json+used,MANIFEST_BYTES-used,",\"preparedKind\":\"addOn\",\"requiredApplicationVersion\":%" PRIu32 ",\"cnmtSHA256\":\"%s\"",r->addon_required_application_version,cnmt);
        if (n<0 || (size_t)n>=MANIFEST_BYTES-used) { free(json); return NULL; } used+=(size_t)n;
    }
    if (r->version_identified) {
        n=snprintf(json+used,MANIFEST_BYTES-used,",\"applicationID\":\"%016" PRIx64 "\",\"titleVersion\":%" PRIu32 ",\"versionIdentified\":true,\"contentRole\":%u",
            r->application_id,r->title_version,(unsigned)r->content_role);
        if (n<0 || (size_t)n>=MANIFEST_BYTES-used) { free(json); return NULL; } used+=(size_t)n;
    }
    if (r->source_kind && !r->version_identified) {
        n=snprintf(json+used,MANIFEST_BYTES-used,",\"applicationID\":\"%016" PRIx64 "\",\"titleVersion\":0,\"versionIdentified\":false,\"contentRole\":0",r->application_id);
        if (n<0 || (size_t)n>=MANIFEST_BYTES-used) { free(json); return NULL; } used+=(size_t)n;
    }
    if (r->update_applied) {
        char update_sha[65]; hex(r->update_source_sha256,32,update_sha);
        n=snprintf(json+used,MANIFEST_BYTES-used,",\"updateApplied\":true,\"sources\":[{\"role\":\"base\",\"titleID\":\"%016" PRIx64
            "\",\"titleVersion\":%" PRIu32 ",\"sourceSHA256\":\"%s\",\"sourceSize\":%" PRIu64
            "},{\"role\":\"update\",\"titleID\":\"%016" PRIx64 "\",\"titleVersion\":%" PRIu32
            ",\"sourceSHA256\":\"%s\",\"sourceSize\":%" PRIu64 "}]",
            r->title_id,r->base_title_version,sha,r->source_size,r->patch_title_id,r->title_version,update_sha,r->update_source_size);
        if (n<0 || (size_t)n>=MANIFEST_BYTES-used) { free(json); return NULL; } used+=(size_t)n;
    }
    n=snprintf(json+used,MANIFEST_BYTES-used,",\"assets\":[");
    if (n<0 || (size_t)n>=MANIFEST_BYTES-used) { free(json); return NULL; } used+=(size_t)n;
    for (size_t i=0;i<count;i++) {
        hex(assets[i].sha,32,sha);
        n=snprintf(json+used,MANIFEST_BYTES-used,"%s{\"path\":\"%s\",\"size\":%" PRIu64 ",\"sha256\":\"%s\"}",i ? ",":"",assets[i].path,assets[i].size,sha);
        if (n<0 || (size_t)n>=MANIFEST_BYTES-used) { free(json); return NULL; } used+=(size_t)n;
    }
    if (r->source_kind) n=snprintf(json+used,MANIFEST_BYTES-used,"],\"integrity\":{\"assetHashesVerified\":true,\"exefsVerified\":%s,\"romfsVerified\":%s,\"romfsStructureVerified\":%s,\"signatureVerified\":false},\"executionVerified\":false}\n",
        r->exefs_verified ? "true":"false",r->romfs_verified ? "true":"false",r->romfs_structure_verified ? "true":"false");
    else n=snprintf(json+used,MANIFEST_BYTES-used,"],\"integrity\":{\"exefsVerified\":%s,\"romfsVerified\":%s,\"signatureVerified\":false},\"executionVerified\":false}\n",
        r->exefs_verified ? "true":"false",r->romfs_verified ? "true":"false");
    if (n<0 || (size_t)n>=MANIFEST_BYTES-used) { free(json); return NULL; }
    return json;
}
static int matching_file(int dir, const char *name, const char *expected) {
    int fd=openat(dir,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC); if (fd<0) return -1;
    struct stat st; size_t n=strlen(expected); char *data=malloc(n ? n:1);
    int bad=!data || regular(fd,n,&st) || (size_t)st.st_size!=n || read_all(fd,data,n);
    if (!bad) bad=memcmp(data,expected,n)!=0;
    free(data); close(fd); return bad ? -1:0;
}
static int find_asset(const struct mng_store *s, const char *path) {
    for (size_t i=0;i<s->count;i++) if (same_path(s->assets[i].path,path)) return (int)i;
    return -1;
}
static int sweep_job(struct mng_store *s, int dir, int exefs) {
    int duplicate=directory_iterator(dir); if (duplicate<0) return -1;
    DIR *entries=fdopendir(duplicate); if (!entries) { close(duplicate); return -1; }
    int bad=0; size_t count=0; struct dirent *entry; errno=0;
    while ((entry=readdir(entries))) {
        if (poll_cancel(s)) { bad=2; break; }
        const char *name=entry->d_name;
        if (!strcmp(name,".") || !strcmp(name,"..")) continue;
        if (++count>MNG_STORE_MAX_ASSETS+8) { bad=1; break; }
        if (!exefs && !strcmp(name,"exefs")) {
            int child=directory(dir,name,0);
            if (child<0 || sweep_job(s,child,1)) bad=1;
            if (child>=0) close(child);
        } else {
            char path[PATH_BYTES];
            if (exefs) { if (!leaf(name)) { bad=1; break; } strcpy(path,"exefs/"); strcat(path,name); }
            else { if (strlen(name)>=sizeof(path)) { bad=1; break; } strcpy(path,name); }
            if (find_asset(s,path)<0 && (exefs || !strcmp(path,"romfs.bin") || !strcmp(path,"runtime-index.bin") || !strcmp(path,".runtime-index.tmp") || !strcmp(path,"input-members.json") || !strcmp(path,".asset.tmp") ||
                !strcmp(path,".receipt.tmp") || !strcmp(path,".manifest.tmp") || !strcmp(path,"manifest.json") || !strcmp(path,".lease"))) {
                if (safe_unlink(dir,name)) bad=1;
            } else if (!exefs && strcmp(path,"receipt.bin") && strcmp(path,"romfs.bin") && strcmp(path,"runtime-index.bin") && strcmp(path,"input-members.json")) bad=1;
        }
        if (bad) break;
        errno=0;
    }
    if (!entry && errno) bad=1;
    closedir(entries); return bad==2 ? -2:bad ? -1:0;
}
enum mng_prepare_status mng_store_open(int root_fd, struct mng_store **out) {
    if (!out || *out) return MNG_PREPARE_INVALID;
    struct stat st;
    if (fstat(root_fd,&st) || !S_ISDIR(st.st_mode) || st.st_uid!=geteuid() || (st.st_mode&077)) return MNG_PREPARE_INVALID;
    struct mng_store *s=calloc(1,sizeof(*s)); if (!s) return MNG_PREPARE_NOMEM;
    atomic_init(&s->cancelled,0);
    s->root=duplicate_fd(root_fd); s->lock=s->jobs=s->titles=s->job=s->output=s->destination=s->reuse_root=s->reuse_lease=-1;
    if (s->root<0) goto bad;
    s->lock=openat(s->root,".lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC,0600);
    if (s->lock<0 || regular(s->lock,0,NULL) || flock(s->lock,LOCK_EX|LOCK_NB)) goto bad;
    s->jobs=directory(s->root,"jobs",1); s->titles=directory(s->root,"titles",1);
    if (s->jobs<0 || s->titles<0 || recover_retirement(s,NULL,NULL)) goto bad;
    *out=s; return MNG_PREPARE_OK;
bad:
    mng_store_close(s); return MNG_PREPARE_IO;
}
void mng_store_close(struct mng_store *s) {
    if (!s) return;
    mng_sha256_free(s->hash);
    free(s->compare);
    int fds[]={s->output,s->destination,s->job,s->jobs,s->titles,s->lock,s->root,s->reuse_root,s->reuse_lease};
    for (size_t i=0;i<sizeof(fds)/sizeof(fds[0]);i++) if (fds[i]>=0) close(fds[i]);
    free(s);
}
void mng_store_set_cancel_check(struct mng_store *s, int (*check)(void *), void *context) {
    if (s) { s->cancel_check=check; s->cancel_context=context; }
}
enum mng_prepare_status mng_store_begin(struct mng_store *s, const char *job_id) {
    if (!s || !hex_valid(job_id,32) || s->job>=0) return MNG_PREPARE_INVALID;
    memset(&s->metrics,0,sizeof(s->metrics));
    if (poll_cancel(s)) return MNG_PREPARE_CANCELLED;
    s->job=directory(s->jobs,job_id,1); if (s->job<0) return MNG_PREPARE_IO;
    strcpy(s->job_id,job_id); s->failed=0; s->count=0; s->total=0;
    enum mng_prepare_status failure=MNG_PREPARE_INTEGRITY;
    struct stat st; struct mng_prepare_result result;
    if (!fstatat(s->job,"receipt.bin",&st,AT_SYMLINK_NOFOLLOW)) {
        if (load_receipt(s->job,s->assets,&s->count,&result)) goto bad;
        s->total=result.asset_bytes;
        for (size_t i=0;i<s->count;i++) {
            int checked=hash_asset(s->job,s->assets+i,s);
            if (checked) { if (checked==-2) failure=MNG_PREPARE_CANCELLED; goto bad; }
        }
    } else if (errno!=ENOENT) goto bad;
    int swept=sweep_job(s,s->job,0);
    if (swept) { if (swept==-2 || poll_cancel(s)) failure=MNG_PREPARE_CANCELLED; goto bad; }
    if (poll_cancel(s)) { failure=MNG_PREPARE_CANCELLED; goto bad; }
    if (save_receipt(s->job,s->assets,s->count,NULL)) goto bad;
    return MNG_PREPARE_OK;
bad:
    close(s->job); s->job=-1; s->count=0; s->total=0; return failure;
}
static int same_snapshot(const struct stat *a,const struct stat *b) {
    if(a->st_dev!=b->st_dev||a->st_ino!=b->st_ino||a->st_mode!=b->st_mode||a->st_nlink!=b->st_nlink||a->st_size!=b->st_size)return 0;
#ifdef __APPLE__
    return a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec&&a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec&&a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
#else
    return a->st_mtim.tv_sec==b->st_mtim.tv_sec&&a->st_mtim.tv_nsec==b->st_mtim.tv_nsec&&a->st_ctim.tv_sec==b->st_ctim.tv_sec&&a->st_ctim.tv_nsec==b->st_ctim.tv_nsec;
#endif
}
/* 1 cloned,0 safe ordinary-stream fallback,-1 unsafe source/temp or IO. */
static int clone_candidate(struct mng_store *s,const char *path,uint64_t size) {
    if(s->reuse_root<0)return 0;
    const struct asset *candidate=NULL;
    for(size_t i=0;i<s->reuse_count;i++)if(!strcmp(path,s->reuse_assets[i].path)){candidate=s->reuse_assets+i;break;}
    if(!candidate)return 0;
    uint64_t old_size=candidate->size;off_t target_size=(off_t)size;
    if(target_size<0 || (uint64_t)target_size!=size)return -1;
    const char *name;int parent=asset_parent(s->reuse_root,path,0,&name);
    if(parent<0)return -1;
    int source=openat(parent,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);close(parent);
    struct stat before={0},after={0},temp={0};
    int bad=source<0||regular(source,old_size,&before)||(uint64_t)before.st_size!=old_size||before.st_uid!=geteuid();
    if(bad){if(source>=0)close(source);return -1;}
    if(!fstatat(s->job,".asset.tmp",&temp,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT){close(source);return -1;}
    if(poll_cancel(s)){close(source);return -1;}
    int result=-1;
#ifdef __APPLE__
    result=fclonefileat(source,s->job,".asset.tmp",0);
    if(!result){int readonly=openat(s->job,".asset.tmp",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
        if(readonly<0||regular(readonly,old_size,&temp)||(uint64_t)temp.st_size!=old_size||temp.st_uid!=geteuid()||fchmod(readonly,0600))bad=1;
        s->output=bad?-1:openat(s->job,".asset.tmp",O_RDWR|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
        struct stat reopened={0};
        if(s->output<0||regular(s->output,old_size,&reopened)||reopened.st_dev!=temp.st_dev||reopened.st_ino!=temp.st_ino||
            (uint64_t)reopened.st_size!=old_size||reopened.st_uid!=geteuid()||(reopened.st_mode&0777)!=0600)bad=1;
        if(readonly>=0)close(readonly);}
#elif defined(__linux__)
    s->output=openat(s->job,".asset.tmp",O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(s->output<0){close(source);return -1;}
    result=ioctl(s->output,FICLONE,source);
    if(result){if(fstat(s->output,&temp)||!S_ISREG(temp.st_mode)||temp.st_nlink!=1)bad=1;
        struct stat named;if(!bad&&(fstatat(s->job,".asset.tmp",&named,AT_SYMLINK_NOFOLLOW)||named.st_dev!=temp.st_dev||named.st_ino!=temp.st_ino||safe_unlink(s->job,".asset.tmp")))bad=1;
        close(s->output);s->output=-1;}
#endif
    if(fstat(source,&after)||!same_snapshot(&before,&after))bad=1;
    if(bad){close(source);return -1;}
    if(result){close(source);struct stat unexpected;if(!fstatat(s->job,".asset.tmp",&unexpected,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT)return -1;
        s->metrics.clone_fallback_assets++;return 0;}
    if(regular(s->output,old_size,&temp)||(uint64_t)temp.st_size!=old_size||temp.st_uid!=geteuid()||
        (temp.st_mode&077)||(temp.st_dev==before.st_dev&&temp.st_ino==before.st_ino)){close(source);return -1;}
    /* This records the verified old snapshot actually cloned, even if later
     * resize/stream/commit fails. Never mutate or truncate the source lease. */
    s->metrics.cloned_assets++;s->metrics.cloned_logical_bytes+=old_size;
    if(poll_cancel(s)||(old_size!=size&&ftruncate(s->output,target_size))||poll_cancel(s)){close(source);return -1;}
    struct stat resized={0};
    if(regular(s->output,size,&resized)||(uint64_t)resized.st_size!=size||resized.st_uid!=geteuid()||
        resized.st_mode!=temp.st_mode||resized.st_dev!=temp.st_dev||resized.st_ino!=temp.st_ino||
        fstat(source,&after)||!same_snapshot(&before,&after)){close(source);return -1;}
    close(source);s->cloned_overlap=old_size<size?old_size:size;return 1;
}
static int payload_write(struct mng_store *s,const unsigned char *bytes,size_t length,uint64_t offset,int positional) {
    while(length){if(poll_cancel(s))return -1;
        ssize_t n=positional?pwrite(s->output,bytes,length,(off_t)offset):write(s->output,bytes,length);
        if(n<0&&errno==EINTR)continue;
        if(n<=0)return -1;
        s->metrics.written_bytes+=(uint64_t)n;bytes+=(size_t)n;length-=(size_t)n;offset+=(uint64_t)n;}
    return 0;
}
static int sink_begin(void *context, const char *path, uint64_t size) {
    struct mng_store *s=context;
    if (!s) return -1;
    if (s->job<0 || poll_cancel(s) || s->failed || s->hash || !asset_path(path)) { s->failed=1; return -1; }
    int existing=find_asset(s,path);
    if ((existing>=0 && strcmp(s->assets[existing].path,path)) ||
        (existing<0 && (s->count>=MNG_STORE_MAX_ASSETS || size>MNG_STORE_MAX_BYTES-s->total)) ||
        (existing>=0 && s->assets[existing].size!=size) ||
        (!strncmp(path,"exefs/",6) && size>(UINT64_C(512)<<20)) || mng_sha256_init(&s->hash)) {
        s->failed=1; return -1;
    }
    strcpy(s->pending,path); s->expected=size; s->written=0; s->replay=existing+1;s->cloned=0;s->cloned_overlap=0;
    if (existing>=0) return 0;
    const char *name;
    s->destination=asset_parent(s->job,path,1,&name);
    if (s->destination<0 || fstatat(s->destination,name,&(struct stat){0},AT_SYMLINK_NOFOLLOW)==0 || errno!=ENOENT) goto bad;
    int cloned=clone_candidate(s,path,size);if(cloned<0)goto bad;
    if(cloned){s->cloned=1;return 0;}
    struct statvfs space;
    if (fstatvfs(s->job,&space) || !space.f_frsize ||
        size/space.f_frsize+(size%space.f_frsize!=0)>space.f_bavail) goto bad;
    s->output=openat(s->job,".asset.tmp",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if (s->output<0) goto bad;
    return 0;
bad:
    if (s->output>=0) { close(s->output); s->output=-1; }
    if (s->destination>=0) { close(s->destination); s->destination=-1; }
    mng_sha256_free(s->hash); s->hash=NULL; s->failed=1; return -1;
}
static int sink_write(void *context, const void *bytes, size_t length) {
    struct mng_store *s=context;
    if (!s) return -1;
    if (poll_cancel(s) || s->failed || !s->hash || length>s->expected-s->written || (!bytes && length)) { s->failed=1; return -1; }
    const unsigned char *incoming=bytes;size_t at=0;
    while(at<length){size_t n=length-at>65536?65536:length-at;
        if(s->cloned&&s->written<s->cloned_overlap&&n>s->cloned_overlap-s->written)n=(size_t)(s->cloned_overlap-s->written);
        if(poll_cancel(s)||mng_sha256_update(s->hash,incoming+at,n)){s->failed=1;return -1;}
        if(s->replay)s->metrics.resumed_bytes+=n;
        else if(s->cloned&&s->written<s->cloned_overlap){size_t got=0;
            while(got<n){if(poll_cancel(s)){s->failed=1;return -1;}
                ssize_t read_bytes=pread(s->output,s->compare+got,n-got,(off_t)(s->written+got));
                if(read_bytes<0&&errno==EINTR)continue;
                if(read_bytes<=0||(size_t)read_bytes>n-got){s->failed=1;return -1;}got+=(size_t)read_bytes;}
            if(!memcmp(s->compare,incoming+at,n))s->metrics.compared_equal_bytes+=n;
            else if(payload_write(s,incoming+at,n,s->written,1)){s->failed=1;return -1;}
        }else if(payload_write(s,incoming+at,n,s->written,s->cloned)){s->failed=1;return -1;}
        s->written+=n;at+=n;s->metrics.streamed_bytes+=n;
    }
    return 0;
}
static int sink_end(void *context, const unsigned char expected[32]) {
    struct mng_store *s=context; unsigned char digest[32];
    if (!s) return -1;
    if (poll_cancel(s) || s->failed || !s->hash || !expected || s->written!=s->expected) { s->failed=1; return -1; }
    int bad=mng_sha256_final(s->hash,digest) || memcmp(digest,expected,32);
    mng_sha256_free(s->hash); s->hash=NULL;
    if (s->replay) {
        if (!bad) bad=memcmp(s->assets[s->replay-1].sha,digest,32);
        s->replay=0; if (bad) s->failed=1; return bad ? -1:0;
    }
    if (!bad) bad=fsync(s->output) || fchmod(s->output,0400);
    if (close(s->output)) bad=1;
    s->output=-1;
    const char *name=!strncmp(s->pending,"exefs/",6) ? s->pending+6:s->pending;
    if (!bad) bad=rename_exclusive(s->job,".asset.tmp",s->destination,name);
    if (!bad) bad=fsync(s->destination) || fsync(s->job);
    close(s->destination); s->destination=-1;
    if (bad) { s->failed=1; return -1; }
    struct asset *asset=s->assets+s->count;
    strcpy(asset->path,s->pending); asset->size=s->written; memcpy(asset->sha,digest,32);
    if (save_receipt(s->job,s->assets,s->count+1,NULL)) { s->failed=1; return -1; }
    s->count++; s->total+=s->written; return 0;
}
static int sink_cancelled(void *context) { return !context || poll_cancel(context); }
struct mng_asset_sink mng_store_sink(struct mng_store *s) {
    return (struct mng_asset_sink){s,sink_begin,sink_write,sink_end,sink_cancelled,NULL};
}
void mng_store_cancel(struct mng_store *s) {
    if (s) { int active=0; (void)atomic_compare_exchange_strong(&s->cancelled,&active,1); }
}
static int title_directory(struct mng_store *s, uint64_t title, int create) {
    char name[17]; (void)snprintf(name,sizeof(name),"%016" PRIx64,title);
    return directory(s->titles,name,create);
}
static int pointer_read(int title, const char *name, char out[65]) {
    int fd=openat(title,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC); if (fd<0) return -1;
    struct stat st; char data[65];
    int bad=regular(fd,65,&st) || st.st_size!=65 || read_all(fd,data,65);
    close(fd); if (bad || data[64]!='\n') return -1;
    data[64]=0; if (!hex_valid(data,64)) return -1; memcpy(out,data,65); return 0;
}
enum mng_prepare_status mng_store_current(struct mng_store *s, uint64_t title, char out[65]) {
    if (!s || !title || !out) return MNG_PREPARE_INVALID;
    int dir=title_directory(s,title,0); if (dir<0) return MNG_PREPARE_IO;
    int bad=pointer_read(dir,"current",out); close(dir); return bad ? MNG_PREPARE_IO:MNG_PREPARE_OK;
}
static int complete(const struct asset *assets, size_t count, const struct mng_prepare_result *r) {
    if (!r->title_id || r->asset_count!=count || !identity_valid(r)) return 0;
    int addon=r->content_role==0x82;
    if (!r->source_kind && (!r->source_size || (!addon && r->exefs_verified!=1) || r->romfs_verified!=1)) return 0;
    uint64_t total=0; int main_found=0, metadata=0, romfs=0, inventory=0, runtime_index=0;
    for (size_t i=0;i<count;i++) { total+=assets[i].size;
        if (!strcmp(assets[i].path,"exefs/main")) main_found=1;
        if (!strcmp(assets[i].path,"exefs/main.npdm")) metadata=1;
        if (!strcmp(assets[i].path,"romfs.bin")) { if (addon && !assets[i].size) return 0; romfs=1; }
        if (!strcmp(assets[i].path,"runtime-index.bin")) {
            runtime_index=1;
            if (!addon || assets[i].size<24 || assets[i].size>(34u<<20)) return 0;
        }
        if (!strcmp(assets[i].path,"input-members.json")) {
            inventory=1;
            if (!r->source_kind || memcmp(assets[i].sha,r->member_inventory_sha256,32)) return 0;
        }
    }
    if (addon) return total==r->asset_bytes && count==2 && romfs && runtime_index && !inventory;
    return total==r->asset_bytes && main_found && metadata && romfs && !runtime_index && (r->source_kind ? inventory:!inventory);
}
static int open_generation(struct mng_store *s, uint64_t title, const char *gen) {
    if (!title || !hex_valid(gen,64)) return -1;
    int dir=title_directory(s,title,0); if (dir<0) return -1;
    int generations=directory(dir,"generations",0); close(dir); if (generations<0) return -1;
    int result=directory(generations,gen,0); close(generations); return result;
}
static int generation_shape(int dir, const struct asset *assets, size_t count, int exefs) {
    int iterator=directory_iterator(dir); if (iterator<0) return -1;
    DIR *entries=fdopendir(iterator); if (!entries) { close(iterator); return -1; }
    int bad=0; size_t seen=0; struct dirent *entry; errno=0;
    while ((entry=readdir(entries))) {
        const char *name=entry->d_name;
        if (!strcmp(name,".") || !strcmp(name,"..")) continue;
        if (++seen>MNG_STORE_MAX_ASSETS+4) { bad=1; break; }
        if (!exefs && !strcmp(name,"exefs")) {
            int child=directory(dir,name,0);
            if (child<0 || generation_shape(child,assets,count,1)) bad=1;
            if (child>=0) close(child);
        } else {
            char path[PATH_BYTES];
            int known=0;
            if (exefs) {
                if (!leaf(name)) { bad=1; break; }
                strcpy(path,"exefs/"); strcat(path,name);
            } else {
                if (strlen(name)>=sizeof(path)) { bad=1; break; }
                strcpy(path,name);
                known=!strcmp(name,"receipt.bin") || !strcmp(name,"manifest.json") || !strcmp(name,".lease");
            }
            for (size_t i=0;i<count;i++) if (!strcmp(assets[i].path,path)) known=1;
            struct stat st;
            if (!known || fstatat(dir,name,&st,AT_SYMLINK_NOFOLLOW) || !S_ISREG(st.st_mode) || st.st_nlink!=1 ||
                (!strcmp(name,".lease") && st.st_size!=0)) bad=1;
        }
        if (bad) break;
        errno=0;
    }
    if (!entry && errno) bad=1;
    closedir(entries); return bad ? -1:0;
}
static enum mng_prepare_status verify_generation(struct mng_store *s, uint64_t title, const char *gen,
    struct mng_prepare_result *out, struct mng_store *cancel_store, struct mng_store_verified_assets *verified) {
    if (!s || !out || !hex_valid(gen,64) || !title) return MNG_PREPARE_INVALID;
    int dir=open_generation(s,title,gen); if (dir<0) return MNG_PREPARE_IO;
    struct asset assets[MNG_STORE_MAX_ASSETS]; size_t count=0; struct mng_prepare_result result;
    char actual[65]; char *json=NULL;
    int bad=load_receipt(dir,assets,&count,&result) || result.title_id!=title || !complete(assets,count,&result);
    if (!bad) bad=generation_shape(dir,assets,count,0) || matching_file(dir,".lease","");
    if (!bad) for (size_t i=0;i<count;i++) {
        int checked=hash_asset(dir,assets+i,cancel_store);
        if (checked) { bad=checked==-2 ? 2:1; break; }
    }
    if (!bad) { qsort(assets,count,sizeof(*assets),compare_assets);
        bad=generation(assets,count,&result,actual) || strcmp(actual,gen); }
    if (!bad) { json=manifest(assets,count,&result,gen); bad=!json || matching_file(dir,"manifest.json",json); }
    free(json); close(dir);
    if (bad) return bad==2 ? MNG_PREPARE_CANCELLED:MNG_PREPARE_INTEGRITY;
    if (verified) {
        struct mng_store_verified_assets facts={0};facts.preparation=result;
        for (size_t i=0;i<count;i++) {
            struct mng_store_asset_identity *identity=!strcmp(assets[i].path,"exefs/main") ? &facts.main:
                !strcmp(assets[i].path,"romfs.bin") ? &facts.romfs:NULL;
            if (identity) { identity->present=1;identity->size=assets[i].size;memcpy(identity->sha256,assets[i].sha,32); }
        }
        *verified=facts;
    }
    *out=result; return MNG_PREPARE_OK;
}
enum mng_prepare_status mng_store_verify(struct mng_store *s, uint64_t title, const char *gen, struct mng_prepare_result *out) {
    return verify_generation(s,title,gen,out,s,NULL);
}
static int replace_current(struct mng_store *s, int dir, const char *line, int preparation) {
    if (safe_unlink(dir,".current.tmp")) return -1;
    int fd=openat(dir,".current.tmp",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if (fd<0) return -1;
    int bad=write_all(fd,line,65) || fsync(fd);
    if (close(fd)) bad=1;
    if (!bad && preparation) {
        (void)poll_cancel(s);
        int active=0;
        if (!atomic_compare_exchange_strong(&s->cancelled,&active,2)) {
            (void)safe_unlink(dir,".current.tmp"); return -2;
        }
    }
    if (!bad) bad=renameat(dir,".current.tmp",dir,"current") || fsync(dir);
    if (bad) (void)safe_unlink(dir,".current.tmp");
    return bad ? -1:0;
}
static int publish(struct mng_store *s, uint64_t title, const char *gen, int preparation) {
    int dir=title_directory(s,title,0); if (dir<0) return -1;
    char previous[65], line[66];
    if (!pointer_read(dir,"current",previous)) {
        if (!strcmp(previous,gen)) { close(dir); return preparation && poll_cancel(s) ? -2:0; }
        memcpy(line,previous,64); line[64]='\n';
        if (replace_file(dir,"previous",".previous.tmp",line,65)) { close(dir); return -1; }
    } else {
        struct stat st;
        if (!fstatat(dir,"current",&st,AT_SYMLINK_NOFOLLOW) || errno!=ENOENT) { close(dir); return -1; }
    }
    memcpy(line,gen,64); line[64]='\n';
    int bad=replace_current(s,dir,line,preparation); close(dir); return bad;
}
static void finish_publication(struct mng_store *s) {
    /* Only the in-flight publication is past the cancellation cutoff. Future
     * operations on this handle must be cancellable again. Never clear state1. */
    int publishing=2;
    (void)atomic_compare_exchange_strong(&s->cancelled,&publishing,0);
}
enum mng_prepare_status mng_store_select(struct mng_store *s, uint64_t title, const char *gen) {
    struct mng_prepare_result verified;
    enum mng_prepare_status status=mng_store_verify(s,title,gen,&verified);
    if (status!=MNG_PREPARE_OK) return status;
    int published=publish(s,title,gen,1);
    finish_publication(s);
    return published==-2 ? MNG_PREPARE_CANCELLED:published ? MNG_PREPARE_IO:MNG_PREPARE_OK;
}
static int rename_exclusive(int from, const char *source, int to, const char *destination) {
#ifdef __APPLE__
    return renameatx_np(from,source,to,destination,RENAME_EXCL);
#elif defined(__linux__) && defined(SYS_renameat2)
    return (int)syscall(SYS_renameat2,from,source,to,destination,1u);
#else
    (void)from; (void)source; (void)to; (void)destination; errno=ENOTSUP; return -1;
#endif
}
enum mng_prepare_status mng_store_commit(struct mng_store *s, const struct mng_prepare_result *r, char out[65]) {
    if (!s || !r || !out || s->job<0 || s->hash || s->output>=0 || !complete(s->assets,s->count,r)) return MNG_PREPARE_INVALID;
    if(s->reuse_root>=0&&(r->title_id!=s->reuse_title||(r->application_id?r->application_id:r->title_id)!=s->reuse_application))return MNG_PREPARE_INVALID;
    if (poll_cancel(s)) return MNG_PREPARE_CANCELLED;
    if (s->failed) return MNG_PREPARE_IO;
    qsort(s->assets,s->count,sizeof(*s->assets),compare_assets);
    for (size_t i=0;i<s->count;i++) {
        int checked=hash_asset(s->job,s->assets+i,s);
        if (checked) return checked==-2 ? MNG_PREPARE_CANCELLED:MNG_PREPARE_INTEGRITY;
    }
    char gen[65]; if (generation(s->assets,s->count,r,gen)) return MNG_PREPARE_NOMEM;
    char *json=manifest(s->assets,s->count,r,gen); if (!json) return MNG_PREPARE_NOMEM;
    int bad=save_receipt(s->job,s->assets,s->count,r) || replace_file(s->job,"manifest.json",".manifest.tmp",json,strlen(json));
    free(json); if (bad) return MNG_PREPARE_IO;
    int lease=openat(s->job,".lease",O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0400);
    if (lease<0) return MNG_PREPARE_IO;
    bad=fsync(lease); close(lease); if (bad || fsync(s->job)) return MNG_PREPARE_IO;
    if (generation_shape(s->job,s->assets,s->count,0)) return MNG_PREPARE_INTEGRITY;
    int title=title_directory(s,r->title_id,1); if (title<0) return MNG_PREPARE_IO;
    int generations=directory(title,"generations",1); close(title); if (generations<0) return MNG_PREPARE_IO;
    if (poll_cancel(s)) { close(generations); return MNG_PREPARE_CANCELLED; }
    if (rename_exclusive(s->jobs,s->job_id,generations,gen)) {
        if (errno!=EEXIST && errno!=ENOTEMPTY) { close(generations); return MNG_PREPARE_IO; }
        struct mng_prepare_result existing;
        enum mng_prepare_status status=verify_generation(s,r->title_id,gen,&existing,s,NULL);
        if (status!=MNG_PREPARE_OK) { close(generations); return status; }
    } else if (fsync(generations) || fsync(s->jobs)) { close(generations); return MNG_PREPARE_IO; }
    close(generations);
    close(s->job); s->job=-1;
    int published=publish(s,r->title_id,gen,1);
    finish_publication(s);
    if (published) return published==-2 ? MNG_PREPARE_CANCELLED:MNG_PREPARE_IO;
    memcpy(out,gen,65); return MNG_PREPARE_OK;
}
enum mng_prepare_status mng_store_pin_verified_assets(struct mng_store *s, uint64_t title, const char *gen,
    struct mng_store_verified_assets *out, int *lease_fd) {
    if (!out || !lease_fd) return MNG_PREPARE_INVALID;
    struct mng_store_verified_assets verified={0};struct mng_prepare_result result;
    enum mng_prepare_status status=verify_generation(s,title,gen,&result,s,&verified);
    if (status!=MNG_PREPARE_OK) return status;
    int dir=open_generation(s,title,gen); if (dir<0) return MNG_PREPARE_IO;
    int fd=openat(dir,".lease",O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK); close(dir);
    if (fd<0 || regular(fd,0,NULL) || flock(fd,LOCK_SH|LOCK_NB)) { if (fd>=0) close(fd); return MNG_PREPARE_IO; }
    *out=verified;*lease_fd=fd;return MNG_PREPARE_OK;
}
enum mng_prepare_status mng_store_pin(struct mng_store *s, uint64_t title, const char *gen, int *lease_fd) {
    struct mng_store_verified_assets verified;
    return mng_store_pin_verified_assets(s,title,gen,&verified,lease_fd);
}
void mng_store_get_io_metrics(const struct mng_store *s,struct mng_store_io_metrics *out) {
    if(out){if(s)*out=s->metrics;else memset(out,0,sizeof(*out));}
}
enum mng_prepare_status mng_store_set_reuse_generation(struct mng_store *s,uint64_t title,const char *gen,struct mng_prepare_result *verified_source) {
    if(!s||s->job>=0||s->hash||s->output>=0||((!title)!=(!gen)))return MNG_PREPARE_INVALID;
    if(!gen){if(s->reuse_root>=0)close(s->reuse_root);if(s->reuse_lease>=0)close(s->reuse_lease);
        s->reuse_root=s->reuse_lease=-1;s->reuse_count=0;s->reuse_title=s->reuse_application=0;
        free(s->compare);s->compare=NULL;if(verified_source)memset(verified_source,0,sizeof(*verified_source));return MNG_PREPARE_OK;}
    struct mng_store_verified_assets verified;int lease=-1;
    enum mng_prepare_status status=mng_store_pin_verified_assets(s,title,gen,&verified,&lease);if(status)return status;
    int dir=open_generation(s,title,gen);struct asset assets[MNG_STORE_MAX_ASSETS];size_t count=0;struct mng_prepare_result result;
    if(dir<0||load_receipt(dir,assets,&count,&result)||result.title_id!=title||!complete(assets,count,&result)){
        if(dir>=0)close(dir);
        close(lease);return MNG_PREPARE_INTEGRITY;}
    qsort(assets,count,sizeof(*assets),compare_assets);char actual[65];
    if(generation(assets,count,&result,actual)||strcmp(actual,gen)){close(dir);close(lease);return MNG_PREPARE_INTEGRITY;}
    if(!s->compare)s->compare=malloc(65536);
    if(!s->compare){close(dir);close(lease);return MNG_PREPARE_NOMEM;}
    if(s->reuse_root>=0)close(s->reuse_root);
    if(s->reuse_lease>=0)close(s->reuse_lease);
    s->reuse_root=dir;s->reuse_lease=lease;s->reuse_title=title;s->reuse_application=result.application_id;
    s->reuse_count=count;memcpy(s->reuse_assets,assets,count*sizeof(*assets));
    if(verified_source)*verified_source=verified.preparation;
    return MNG_PREPARE_OK;
}
/* Inspect the entire candidate before a NEW retirement writes any intent or
 * moves its canonical name. Mirror remove_tree's bounded shape and safe_unlink's
 * regular/single-link rule without unlinking, parsing receipts or hashing data.
 * A retained exclusive lease/store lock excludes cooperating mutations; metadata
 * snapshots also reject detectable directory changes during this read-only pass. */
static int removal_preflight(int dir, unsigned depth) {
    struct stat before={0},after={0};
    if (depth>1 || fstat(dir,&before) || !S_ISDIR(before.st_mode) || before.st_uid!=geteuid()) return -1;
    int iterator=directory_iterator(dir); if (iterator<0) return -1;
    DIR *entries=fdopendir(iterator); if (!entries) { close(iterator); return -1; }
    size_t count=0; int bad=0; struct dirent *entry; errno=0;
    while ((entry=readdir(entries))) {
        const char *name=entry->d_name;
        if (!strcmp(name,".") || !strcmp(name,"..")) { errno=0; continue; }
        struct stat st;
        if (++count>MNG_STORE_MAX_ASSETS+8 || fstatat(dir,name,&st,AT_SYMLINK_NOFOLLOW) || st.st_uid!=geteuid()) { bad=1; break; }
        if (S_ISDIR(st.st_mode)) {
            if (depth || strcmp(name,"exefs")) { bad=1; break; }
            int child=openat(dir,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            struct stat opened={0};
            bad=child<0 || fstat(child,&opened) || !same_snapshot(&st,&opened) || removal_preflight(child,depth+1);
            if (child>=0) close(child);
        } else if (!S_ISREG(st.st_mode) || st.st_nlink!=1) bad=1;
        if (bad) break;
        errno=0;
    }
    if (!entry && errno) bad=1;
    if (!bad && (fstat(dir,&after) || !same_snapshot(&before,&after))) bad=1;
    closedir(entries); return bad ? -1:0;
}
static int remove_tree(int parent, const char *name, unsigned depth) {
    if (depth>2) return -1;
    int dir=directory(parent,name,0); if (dir<0) return -1;
    int iterator=directory_iterator(dir); if (iterator<0) { close(dir); return -1; }
    DIR *entries=fdopendir(iterator); if (!entries) { close(iterator); close(dir); return -1; }
    size_t count=0; int bad=0; struct dirent *entry; errno=0;
    while ((entry=readdir(entries))) {
        const char *child=entry->d_name;
        if (!strcmp(child,".") || !strcmp(child,"..")) continue;
        struct stat st;
        if (++count>MNG_STORE_MAX_ASSETS+8 || fstatat(dir,child,&st,AT_SYMLINK_NOFOLLOW)) { bad=1; break; }
        if (S_ISDIR(st.st_mode)) { if (depth || strcmp(child,"exefs") || remove_tree(dir,child,depth+1)) bad=1; }
        else if (safe_unlink(dir,child)) bad=1;
        if (bad) break;
        errno=0;
    }
    if (!entry && errno) bad=1;
    closedir(entries); close(dir);
    if (!bad) bad=unlinkat(parent,name,AT_REMOVEDIR) || fsync(parent);
    return bad ? -1:0;
}
/* One serialized removal intent, independent of generation receipts/identity.
 * A missing lease is never authority: only the recorded retired inode may be
 * completed without its lease, and then only when that directory is empty. */
#define RETIRE_BYTES 144u
static int retirement_dir(struct mng_store *s,int create) {
    if(create&&mkdirat(s->root,".retirement",0700)&&errno!=EEXIST)return -1;
    int fd=openat(s->root,".retirement",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    struct stat st;
    if(fd>=0&&(fstat(fd,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=geteuid()||(st.st_mode&077))) {close(fd);errno=EINVAL;return -1;}
    /* An earlier mkdir may have returned IO at its root fsync. Every actual
     * removal confirms that namespace link, including the EEXIST retry path. */
    if(fd>=0&&create&&fsync(s->root)){close(fd);return -1;}
    return fd;
}
static int retirement_digest(const unsigned char *data,unsigned char out[32]) {
    struct mng_sha256 *hash=NULL;
    int bad=mng_sha256_init(&hash)||mng_sha256_update(hash,data,112)||mng_sha256_final(hash,out);
    mng_sha256_free(hash);return bad;
}
static int retirement_shape(int dir,unsigned *flags) {
    int fd=directory_iterator(dir);DIR *stream=fd<0?NULL:fdopendir(fd);
    if(!stream){if(fd>=0)close(fd);return -1;}
    struct dirent *entry;unsigned found=0,count=0;int bad=0;errno=0;
    while((entry=readdir(stream))) {
        const char *name=entry->d_name;if(!strcmp(name,".")||!strcmp(name,"..")){errno=0;continue;}
        struct stat st;unsigned bit=!strcmp(name,"intent.bin")?1:!strcmp(name,".intent.tmp")?2:!strcmp(name,"target")?4:0;
        if(++count>3||!bit||(found&bit)||fstatat(dir,name,&st,AT_SYMLINK_NOFOLLOW)||st.st_uid!=geteuid()||(st.st_mode&077)) {bad=1;break;}
        if(bit==4) {if(!S_ISDIR(st.st_mode)){bad=1;break;}}
        else if(!S_ISREG(st.st_mode)||st.st_nlink!=1||st.st_size<0||(uint64_t)st.st_size>RETIRE_BYTES||
                (bit==1&&(uint64_t)st.st_size!=RETIRE_BYTES)) {bad=1;break;}
        found|=bit;errno=0;
    }
    if(!entry&&errno)bad=1;
    closedir(stream);if(bad)return -1;*flags=found;return 0;
}
static int retirement_identity(int fd,uint64_t dev,uint64_t ino,int directory_expected) {
    struct stat st;
    return fstat(fd,&st)||st.st_uid!=geteuid()||(st.st_mode&077)||
        (uint64_t)st.st_dev!=dev||(uint64_t)st.st_ino!=ino||
        (directory_expected?!S_ISDIR(st.st_mode):(!S_ISREG(st.st_mode)||st.st_nlink!=1||st.st_size!=0));
}
static int retirement_unprotected(struct mng_store *s,uint64_t title,const char *gen,int *generations) {
    int dir=title_directory(s,title,0);if(dir<0)return -1;
    char current[65],previous[65];
    if(pointer_read(dir,"current",current)||!strcmp(current,gen)){close(dir);return -2;}
    if(pointer_read(dir,"previous",previous)) {
        struct stat st;
        if(!fstatat(dir,"previous",&st,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT){close(dir);return -1;}
    } else if(!strcmp(previous,gen)){close(dir);return -2;}
    int result=directory(dir,"generations",0);close(dir);
    if(result<0)return -1;
    *generations=result;return 0;
}
static int retirement_payloads(int target) {
    int fd=directory_iterator(target);DIR *stream=fd<0?NULL:fdopendir(fd);
    if(!stream){if(fd>=0)close(fd);return -1;}
    size_t count=0;struct dirent *entry;int bad=0;errno=0;
    while((entry=readdir(stream))) {
        const char *name=entry->d_name;
        if(!strcmp(name,".")||!strcmp(name,"..")){errno=0;continue;}
        struct stat st;
        if(++count>MNG_STORE_MAX_ASSETS+8||fstatat(target,name,&st,AT_SYMLINK_NOFOLLOW)){bad=1;break;}
        if(!strcmp(name,".lease")) {errno=0;continue;}
        if(S_ISDIR(st.st_mode)) {if(strcmp(name,"exefs")||remove_tree(target,name,1))bad=1;}
        else if(safe_unlink(target,name))bad=1;
        if(bad)break;
        errno=0;
    }
    if(!entry&&errno)bad=1;
    closedir(stream);return bad||fsync(target)?-1:0;
}
static int retirement_contents(int target,int lease_expected) {
    int fd=directory_iterator(target);DIR *stream=fd<0?NULL:fdopendir(fd);
    if(!stream){if(fd>=0)close(fd);return -1;}
    int bad=0,lease_seen=0;struct dirent *entry;errno=0;
    while((entry=readdir(stream))) {
        const char *name=entry->d_name;
        if(strcmp(name,".")&&strcmp(name,"..")) {
            if(lease_expected&&!strcmp(name,".lease")&&!lease_seen)lease_seen=1;
            else {bad=1;break;}
        }
        errno=0;
    }
    if(!entry&&errno)bad=1;
    closedir(stream);return bad||(lease_expected&&!lease_seen)?-1:0;
}
static int recover_retirement(struct mng_store *s,uint64_t *completed_title,char completed_gen[65]) {
    int retired=retirement_dir(s,0);
    if(retired<0)return errno==ENOENT?0:-1;
    unsigned flags=0;int target=-1,lease=-1,journal=-1,generations=-1,bad=1;
    unsigned char data[RETIRE_BYTES],hash[32];struct stat intent_before={0},intent_after={0};char gen[65];uint64_t title=0;
    if(retirement_shape(retired,&flags))goto done;
    if(flags==0){bad=0;goto done;}
    if(flags==2) { /* Reserved incomplete metadata; never payload authority. */
        bad=safe_unlink(retired,".intent.tmp")||fsync(retired);goto done;
    }
    if(!(flags&1)||(flags&2))goto done;
    journal=openat(retired,"intent.bin",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(journal<0||regular(journal,RETIRE_BYTES,&intent_before)||intent_before.st_size!=RETIRE_BYTES||
        intent_before.st_uid!=geteuid()||(intent_before.st_mode&077)||
        read_all(journal,data,sizeof(data))||fstat(journal,&intent_after)||!same_snapshot(&intent_before,&intent_after)||
        memcmp(data,"CNPYRM01",8)||retirement_digest(data,hash)||memcmp(hash,data+112,32))goto done;
    title=get64(data+8);memcpy(gen,data+48,64);gen[64]=0;
    if(!title||!hex_valid(gen,64)||!get64(data+24)||!get64(data+40)||retirement_unprotected(s,title,gen,&generations))goto done;
    struct stat normal;
    int canonical=fstatat(generations,gen,&normal,AT_SYMLINK_NOFOLLOW)==0;
    if(!canonical&&errno!=ENOENT)goto done;
    if(canonical&&(flags&4))goto done; /* Preserve replacement namespaces. */
    if(canonical) {
        target=openat(generations,gen,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(target<0||retirement_identity(target,get64(data+16),get64(data+24),1))goto done;
    } else if(flags&4) {
        target=openat(retired,"target",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(target<0||retirement_identity(target,get64(data+16),get64(data+24),1))goto done;
    }
    if(target>=0) {
        lease=openat(target,".lease",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
        if(lease<0) {
            if(canonical||errno!=ENOENT||retirement_contents(target,0))goto done;
        } else if(retirement_identity(lease,get64(data+32),get64(data+40),0)||flock(lease,LOCK_EX|LOCK_NB))goto done;
        struct stat retired_name;
        if(canonical) {
            if(fstatat(generations,gen,&retired_name,AT_SYMLINK_NOFOLLOW)||
                (uint64_t)retired_name.st_dev!=get64(data+16)||(uint64_t)retired_name.st_ino!=get64(data+24)||
                rename_exclusive(generations,gen,retired,"target"))goto done;
        }
        if(fstatat(retired,"target",&retired_name,AT_SYMLINK_NOFOLLOW)||
            (uint64_t)retired_name.st_dev!=get64(data+16)||(uint64_t)retired_name.st_ino!=get64(data+24))goto done;
        /* Confirm both sides of retirement before deleting any payload. */
        if(fsync(generations)||fsync(retired))goto done;
        if(lease>=0) {
            if(retirement_payloads(target)||retirement_contents(target,1))goto done;
            struct stat named;
            if(fstatat(target,".lease",&named,AT_SYMLINK_NOFOLLOW)||
                (uint64_t)named.st_dev!=get64(data+32)||(uint64_t)named.st_ino!=get64(data+40)||
                safe_unlink(target,".lease")||fsync(target))goto done;
        }
        if(retirement_contents(target,0)||(lease<0&&fsync(target)))goto done;
        struct stat named;
        if(fstatat(retired,"target",&named,AT_SYMLINK_NOFOLLOW)||
            (uint64_t)named.st_dev!=get64(data+16)||(uint64_t)named.st_ino!=get64(data+24)||
            unlinkat(retired,"target",AT_REMOVEDIR))goto done;
    }
    if(fsync(retired))goto done;
    struct stat named;
    if(fstat(journal,&intent_after)||!same_snapshot(&intent_before,&intent_after)||
        fstatat(retired,"intent.bin",&named,AT_SYMLINK_NOFOLLOW)||named.st_dev!=intent_before.st_dev||named.st_ino!=intent_before.st_ino||
        safe_unlink(retired,"intent.bin")||fsync(retired))goto done;
    if(completed_title)*completed_title=title;
    if(completed_gen)memcpy(completed_gen,gen,65);
    bad=0;
 done:
    if(journal>=0)close(journal);
    if(lease>=0)close(lease);
    if(target>=0)close(target);
    if(generations>=0)close(generations);
    close(retired);return bad?-1:0;
}
static int retirement_intent(int dir,uint64_t title,const char *gen,const struct stat *target,const struct stat *lease) {
    unsigned flags=0;if(retirement_shape(dir,&flags)||flags)return -1;
    unsigned char data[RETIRE_BYTES]={0};memcpy(data,"CNPYRM01",8);put64(data+8,title);
    put64(data+16,(uint64_t)target->st_dev);put64(data+24,(uint64_t)target->st_ino);
    put64(data+32,(uint64_t)lease->st_dev);put64(data+40,(uint64_t)lease->st_ino);memcpy(data+48,gen,64);
    if(retirement_digest(data,data+112))return -1;
    int fd=openat(dir,".intent.tmp",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return -1;
    int bad=write_all(fd,data,sizeof(data))||fsync(fd);if(close(fd))bad=1;
    if(!bad)bad=rename_exclusive(dir,".intent.tmp",dir,"intent.bin")||fsync(dir);
    return bad?-1:0;
}
enum mng_prepare_status mng_store_discard_job(struct mng_store *s, const char *job_id) {
    if (!s || !hex_valid(job_id,32) || (s->job>=0 && !strcmp(job_id,s->job_id))) return MNG_PREPARE_INVALID;
    return remove_tree(s->jobs,job_id,0) ? MNG_PREPARE_IO:MNG_PREPARE_OK;
}
enum mng_prepare_status mng_store_remove_generation(struct mng_store *s, uint64_t title, const char *gen) {
    if (!s || !title || !hex_valid(gen,64)) return MNG_PREPARE_INVALID;
    uint64_t completed=0;char recovered[65];
    if(recover_retirement(s,&completed,recovered))return MNG_PREPARE_IO;
    if(completed==title&&!strcmp(recovered,gen))return MNG_PREPARE_OK;
    int generations=-1;
    int protected=retirement_unprotected(s,title,gen,&generations);
    if(protected)return protected==-2?MNG_PREPARE_INVALID:MNG_PREPARE_IO;
    int target=openat(generations,gen,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    struct stat target_stat={0},lease_stat={0};
    int lease=target<0?-1:openat(target,".lease",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    int bad=target<0||fstat(target,&target_stat)||target_stat.st_uid!=geteuid()||(target_stat.st_mode&077)||
        lease<0||regular(lease,0,&lease_stat)||lease_stat.st_uid!=geteuid()||(lease_stat.st_mode&077)||flock(lease,LOCK_EX|LOCK_NB);
    if(!bad) {
        struct stat checked={0},named={0};
        bad=removal_preflight(target,0) || fstat(target,&checked) || !same_snapshot(&target_stat,&checked) ||
            fstatat(generations,gen,&named,AT_SYMLINK_NOFOLLOW) || !same_snapshot(&checked,&named) ||
            fstatat(target,".lease",&named,AT_SYMLINK_NOFOLLOW) || !same_snapshot(&lease_stat,&named);
    }
    int retired=-1;
    if(!bad) {retired=retirement_dir(s,1);bad=retired<0||retirement_intent(retired,title,gen,&target_stat,&lease_stat);}
    if(retired>=0)close(retired);
    if(lease>=0)close(lease);
    if(target>=0)close(target);
    close(generations);
    /* Reacquire/check the genuine recorded lease immediately before retirement.
     * The exclusive store lock stays held across intent and this recovery path. */
    if(!bad)bad=recover_retirement(s,NULL,NULL);
    return bad?MNG_PREPARE_IO:MNG_PREPARE_OK;
}
