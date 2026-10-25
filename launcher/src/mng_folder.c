#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include "mng_folder.h"
#include "mng_prepare_internal.h"
#include "mng_crypto.h"
#include "mng_romfs.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MEMBERS 512u
#define MAX_BYTES (UINT64_C(128)<<30)
#define OUTPUT_BYTES (UINT64_C(64)<<30)
#define JSON_BYTES (2u<<20)
#define CHUNK 65536u
struct member {
    char name[129],path[136];unsigned parent;
    struct stat before;
    uint64_t offset,size;
    unsigned char sha[32];
};
struct folder {
    int dirs[3],cached;
    size_t cached_index,count;
    struct stat before[3];
    struct member *members;
    unsigned char *table;
    size_t table_size;
    uint64_t bytes,view_size;
    const struct mng_asset_sink *sink;
    const struct mng_folder_callbacks *callbacks;
    enum mng_prepare_status status;
    unsigned snapshots;
};
static uint32_t u32(const unsigned char *p) { return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24; }
static uint64_t u64(const unsigned char *p) { return u32(p)|(uint64_t)u32(p+4)<<32; }
static void put32(unsigned char *p,uint32_t n) { for (unsigned i=0;i<4;i++) p[i]=(unsigned char)(n>>(i*8)); }
static void put64(unsigned char *p,uint64_t n) { for (unsigned i=0;i<8;i++) p[i]=(unsigned char)(n>>(i*8)); }
static int fits(uint64_t a,uint64_t n,uint64_t bound) { return a<=bound && n<=bound-a; }
static int fail(struct folder *f,enum mng_prepare_status status) { f->status=status;return -1; }
static int stopped(struct folder *f) {
    return f->sink && f->sink->cancelled && f->sink->cancelled(f->sink->context) ? fail(f,MNG_PREPARE_CANCELLED):0;
}
static void progress(struct folder *f,const char *phase,uint64_t done,uint64_t total) {
    if (f->sink && f->sink->progress) f->sink->progress(f->sink->context,phase,done,total);
}
static int stable(const struct stat *a,const struct stat *b) {
#ifdef __APPLE__
    const struct timespec am=a->st_mtimespec,bm=b->st_mtimespec,ac=a->st_ctimespec,bc=b->st_ctimespec;
#else
    const struct timespec am=a->st_mtim,bm=b->st_mtim,ac=a->st_ctim,bc=b->st_ctim;
#endif
    return a->st_dev==b->st_dev && a->st_ino==b->st_ino && a->st_mode==b->st_mode && a->st_nlink==b->st_nlink &&
        a->st_size==b->st_size && am.tv_sec==bm.tv_sec && am.tv_nsec==bm.tv_nsec && ac.tv_sec==bc.tv_sec && ac.tv_nsec==bc.tv_nsec;
}
static int safe_name(const char *name,size_t maximum) {
    size_t n=strnlen(name,maximum+1);
    if (!n || n>maximum || !strcmp(name,".") || !strcmp(name,"..")) return 0;
    for (size_t i=0;i<n;i++) {
        unsigned char c=(unsigned char)name[i];
        if (!((c>='a'&&c<='z') || (c>='A'&&c<='Z') || (c>='0'&&c<='9') || c=='.' || c=='_' || c=='-')) return 0;
    }
    return 1;
}
static int ascii_equal(const char *a,const char *b) {
    while (*a && *b) {
        unsigned char x=(unsigned char)*a++,y=(unsigned char)*b++;
        if (x>='A'&&x<='Z') x=(unsigned char)(x+32);
        if (y>='A'&&y<='Z') y=(unsigned char)(y+32);
        if (x!=y) return 0;
    }
    return !*a && !*b;
}
static int suffix(const char *name,const char *end) {
    size_t a=strlen(name),b=strlen(end);
    return a>=b && ascii_equal(name+a-b,end);
}
static int module_name(const char *name) {
    return !strcmp(name,"main") || !strcmp(name,"main.npdm") || !strcmp(name,"rtld") || !strcmp(name,"sdk") ||
        (strlen(name)==7 && !memcmp(name,"subsdk",6) && name[6]>='0' && name[6]<='9');
}
static int folder_stat(struct folder *f) {
    for (unsigned i=0;i<3;i++) if (f->snapshots&(1u<<i)) {
        struct stat now;
        if (fstat(f->dirs[i],&now) || !stable(f->before+i,&now)) return fail(f,MNG_PREPARE_IO);
    }
    for (size_t i=0;i<f->count;i++) {
        struct member *m=f->members+i;struct stat now;
        if (fstatat(f->dirs[m->parent],m->name,&now,AT_SYMLINK_NOFOLLOW) || !stable(&m->before,&now)) return fail(f,MNG_PREPARE_IO);
    }
    return 0;
}
static int check_reader(void *context) { return folder_stat(context); }
static int open_member(struct folder *f,size_t index) {
    struct member *m=f->members+index;struct stat now;
    if (f->cached>=0 && f->cached_index!=index) { close(f->cached);f->cached=-1; }
    if (f->cached<0) {
        f->cached=openat(f->dirs[m->parent],m->name,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
        f->cached_index=index;
    }
    if (f->cached<0 || fstat(f->cached,&now) || !stable(&m->before,&now)) return fail(f,MNG_PREPARE_IO);
    return 0;
}
static int member_read(struct folder *f,size_t index,uint64_t at,void *out,size_t size) {
    struct member *m=f->members+index;
    if (!fits(at,size,m->size)) return fail(f,MNG_PREPARE_INVALID);
    if (stopped(f) || open_member(f,index)) return -1;
    unsigned char *p=out;
    while (size) {
        if (stopped(f)) return -1;
        size_t request=size>CHUNK ? CHUNK:size;
        ssize_t n=pread(f->cached,p,request,(off_t)at);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) return fail(f,MNG_PREPARE_IO);
        p+=(size_t)n;at+=(uint64_t)n;size-=(size_t)n;
    }
    struct stat now;
    if (fstat(f->cached,&now) || !stable(&m->before,&now)) return fail(f,MNG_PREPARE_IO);
    return 0;
}
static int by_path(const void *a,const void *b) { return strcmp(((const struct member *)a)->path,((const struct member *)b)->path); }
static int add_member(struct folder *f,unsigned parent,const char *name,const char *prefix) {
    if (!safe_name(name,parent==1 ? 64:128)) return fail(f,MNG_PREPARE_UNSUPPORTED);
    if (f->count==MEMBERS) return fail(f,MNG_PREPARE_LIMIT);
    struct member *m=f->members+f->count;
    if (fstatat(f->dirs[parent],name,&m->before,AT_SYMLINK_NOFOLLOW)) return fail(f,MNG_PREPARE_IO);
    if (!S_ISREG(m->before.st_mode) || m->before.st_size<0 || m->before.st_nlink<1) return fail(f,MNG_PREPARE_INVALID);
    m->size=(uint64_t)m->before.st_size;
    if (m->size>MAX_BYTES-f->bytes) return fail(f,MNG_PREPARE_LIMIT);
    strcpy(m->name,name);m->parent=parent;
    int n=snprintf(m->path,sizeof(m->path),"%s%s",prefix,name);
    if (n<0 || (size_t)n>=sizeof(m->path)) return fail(f,MNG_PREPARE_LIMIT);
    for (size_t i=0;i<f->count;i++) if (ascii_equal(m->path,f->members[i].path)) return fail(f,MNG_PREPARE_INVALID);
    f->bytes+=m->size;f->count++;return 0;
}
static int enumerate(struct folder *f,unsigned parent,int nca) {
    int scan=openat(f->dirs[parent],".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (scan<0) return fail(f,MNG_PREPARE_IO);
    DIR *directory=fdopendir(scan);if (!directory) { close(scan);return fail(f,MNG_PREPARE_IO); }
    struct dirent *entry;size_t count=0;int status=0;errno=0;
    while ((entry=readdir(directory))!=NULL) {
        if (!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")) continue;
        if (stopped(f) || ++count>MEMBERS) { if (!f->status)fail(f,MNG_PREPARE_LIMIT);status=-1;break; }
        if (!strcmp(entry->d_name,".DS_Store")) { errno=0;continue; } /* Never read/copied or claimed as a member. */
        if (nca) {
            if (!suffix(entry->d_name,".nca") && !suffix(entry->d_name,".tik") &&
                !suffix(entry->d_name,".cert") && !suffix(entry->d_name,".xml")) { status=fail(f,MNG_PREPARE_UNSUPPORTED);break; }
        } else if (!module_name(entry->d_name)) { status=fail(f,MNG_PREPARE_UNSUPPORTED);break; }
        if (add_member(f,parent,entry->d_name,nca ? "":"exefs/")) { status=-1;break; }
        errno=0;
    }
    if (!entry && errno) status=fail(f,MNG_PREPARE_IO);
    closedir(directory);return status;
}
/* Ignore imported reports, but bound even unconsumed directory entries and
 * reject alternate spellings of the controlled layout on case-sensitive hosts. */
static int check_layout_directory(struct folder *f,unsigned parent) {
    int scan=openat(f->dirs[parent],".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (scan<0) return fail(f,MNG_PREPARE_IO);
    DIR *directory=fdopendir(scan);if (!directory) { close(scan);return fail(f,MNG_PREPARE_IO); }
    struct dirent *entry;size_t count=0;int status=0;errno=0;
    while ((entry=readdir(directory))!=NULL) {
        const char *name=entry->d_name;
        if (!strcmp(name,".") || !strcmp(name,"..")) continue;
        if (stopped(f) || ++count>MEMBERS) { if (!f->status)fail(f,MNG_PREPARE_LIMIT);status=-1;break; }
        if ((!parent && ((ascii_equal(name,"exefs") && strcmp(name,"exefs")) ||
             (ascii_equal(name,"romfs") && strcmp(name,"romfs")) || suffix(name,".nca"))) ||
            (parent==2 && ascii_equal(name,"romfs.bin") && strcmp(name,"romfs.bin"))) {
            status=fail(f,MNG_PREPARE_INVALID);break;
        }
        errno=0;
    }
    if (!entry && errno)status=fail(f,MNG_PREPARE_IO);
    closedir(directory);return status;
}
enum mng_prepare_status mng_folder_kind_fd(int root,enum mng_folder_kind *kind) {
    if (!kind) return MNG_PREPARE_INVALID;
    struct stat before,after;
    if (fstat(root,&before) || !S_ISDIR(before.st_mode)) return MNG_PREPARE_INVALID;
    int fd=openat(root,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (fd<0) return MNG_PREPARE_IO;
    DIR *d=fdopendir(fd);if (!d) { close(fd);return MNG_PREPARE_IO; }
    struct dirent *e;size_t count=0;int nca=0,assets=0;enum mng_prepare_status status=MNG_PREPARE_OK;errno=0;
    while ((e=readdir(d))!=NULL) {
        if (!strcmp(e->d_name,".") || !strcmp(e->d_name,"..")) continue;
        if (++count>MEMBERS) { status=MNG_PREPARE_LIMIT;break; }
        struct stat st;
        if (fstatat(root,e->d_name,&st,AT_SYMLINK_NOFOLLOW)) { status=MNG_PREPARE_IO;break; }
        if (suffix(e->d_name,".nca") && S_ISREG(st.st_mode)) nca=1;
        if (!strcmp(e->d_name,"exefs") && S_ISDIR(st.st_mode)) assets=1;
        errno=0;
    }
    if (!e && errno) status=MNG_PREPARE_IO;
    closedir(d);
    if (fstat(root,&after) || !stable(&before,&after)) return MNG_PREPARE_IO;
    if (status) return status;
    if (nca==assets) return MNG_PREPARE_UNSUPPORTED;
    if (assets) {
        struct stat st;
        if (fstatat(root,"romfs",&st,AT_SYMLINK_NOFOLLOW) || !S_ISDIR(st.st_mode)) return MNG_PREPARE_INVALID;
    }
    *kind=nca ? MNG_FOLDER_NCA:MNG_FOLDER_ASSETS;return MNG_PREPARE_OK;
}
static int fingerprint(struct folder *f) {
    uint64_t done=0;unsigned char bytes[CHUNK];
    progress(f,"fingerprint-folder-members",0,f->bytes);
    for (size_t i=0;i<f->count;i++) {
        struct mng_sha256 *hash=NULL;
        if (mng_sha256_init(&hash)) return fail(f,MNG_PREPARE_NOMEM);
        int status=0;
        for (uint64_t at=0;at<f->members[i].size;) {
            size_t n=f->members[i].size-at>CHUNK ? CHUNK:(size_t)(f->members[i].size-at);
            if (member_read(f,i,at,bytes,n) || mng_sha256_update(hash,bytes,n)) { if (!f->status)fail(f,MNG_PREPARE_IO);status=-1;break; }
            at+=n;done+=n;progress(f,"fingerprint-folder-members",done,f->bytes);
        }
        if (!status && mng_sha256_final(hash,f->members[i].sha)) status=fail(f,MNG_PREPARE_IO);
        mng_sha256_free(hash);if (status) { mng_secure_clear(bytes,sizeof(bytes));return -1; }
    }
    mng_secure_clear(bytes,sizeof(bytes));return folder_stat(f);
}
static int build_view(struct folder *f) {
    size_t strings=0;
    for (size_t i=0;i<f->count;i++) strings+=strlen(f->members[i].name)+1;
    f->table_size=16+f->count*24+strings;f->view_size=f->table_size+f->bytes;
    f->table=calloc(1,f->table_size);
    if (!f->table) return fail(f,MNG_PREPARE_NOMEM);
    memcpy(f->table,"PFS0",4);put32(f->table+4,(uint32_t)f->count);put32(f->table+8,(uint32_t)strings);
    size_t name=0;uint64_t payload=0;
    for (size_t i=0;i<f->count;i++) {
        unsigned char *row=f->table+16+i*24;
        put64(row,payload);put64(row+8,f->members[i].size);put32(row+16,(uint32_t)name);
        size_t length=strlen(f->members[i].name)+1;
        memcpy(f->table+16+f->count*24+name,f->members[i].name,length);name+=length;
        f->members[i].offset=f->table_size+payload;payload+=f->members[i].size;
    }
    return 0;
}
static int view_read(void *context,uint64_t offset,void *output,size_t length) {
    struct folder *f=context;unsigned char *to=output;
    if (!fits(offset,length,f->view_size)) return fail(f,MNG_PREPARE_INVALID);
    while (length) {
        if (offset<f->table_size) {
            size_t n=f->table_size-(size_t)offset;if (n>length)n=length;
            memcpy(to,f->table+(size_t)offset,n);offset+=n;to+=n;length-=n;continue;
        }
        size_t index=0;
        while (index<f->count && (!f->members[index].size || offset>=f->members[index].offset+f->members[index].size)) index++;
        if (index==f->count || offset<f->members[index].offset) return fail(f,MNG_PREPARE_INVALID);
        uint64_t at=offset-f->members[index].offset;
        size_t n=length;if (n>f->members[index].size-at)n=(size_t)(f->members[index].size-at);
        if (member_read(f,index,at,to,n)) return -1;
        offset+=n;to+=n;length-=n;
    }
    return 0;
}
static int finish_asset(struct folder *f,struct mng_prepare_result *r,const unsigned char digest[32],uint64_t size) {
    if (stopped(f)) return -1;
    if (f->sink->end(f->sink->context,digest)) return stopped(f) ? -1:fail(f,MNG_PREPARE_IO);
    r->asset_count++;r->asset_bytes+=size;return 0;
}
static int copy_member(struct folder *f,size_t index,struct mng_prepare_result *r) {
    struct member *m=f->members+index;unsigned char bytes[CHUNK],digest[32];struct mng_sha256 *hash=NULL;
    if (stopped(f)) return -1;
    if (mng_sha256_init(&hash)) return fail(f,MNG_PREPARE_NOMEM);
    int status=-1;
    if (f->sink->begin(f->sink->context,m->path,m->size)) { if (!stopped(f))fail(f,MNG_PREPARE_IO);goto done; }
    for (uint64_t at=0;at<m->size;) {
        size_t n=m->size-at>CHUNK ? CHUNK:(size_t)(m->size-at);
        if (member_read(f,index,at,bytes,n) || mng_sha256_update(hash,bytes,n)) { if (!f->status)fail(f,MNG_PREPARE_IO);goto done; }
        if (f->sink->write(f->sink->context,bytes,n)) { if (!stopped(f))fail(f,MNG_PREPARE_IO);goto done; }
        at+=n;progress(f,"copy-plaintext-assets",at,m->size);
    }
    if (mng_sha256_final(hash,digest)) { fail(f,MNG_PREPARE_IO);goto done; }
    if (memcmp(digest,m->sha,32)) { fail(f,MNG_PREPARE_INTEGRITY);goto done; }
    status=finish_asset(f,r,digest,m->size);
done:
    mng_sha256_free(hash);mng_secure_clear(bytes,sizeof(bytes));return status;
}
static int romfs_cancel(void *context) { return stopped(context)!=0; }
static int romfs_canonical(void *context,const char *name,char *out,size_t capacity) {
    struct folder *f=context;
    return f->callbacks->canonical_name(f->callbacks->context,name,out,capacity);
}
static int validate_nso(struct folder *f,size_t index) {
    unsigned char header[0x100];struct member *m=f->members+index;
    if (m->size<sizeof(header)) return fail(f,MNG_PREPARE_INVALID);
    if (member_read(f,index,0,header,sizeof(header))) return -1;
    if (memcmp(header,"NSO0",4) || (u32(header+12)&~63u)) return fail(f,MNG_PREPARE_UNSUPPORTED);
    uint64_t ends[3],starts[3];
    for (unsigned i=0;i<3;i++) {
        starts[i]=u32(header+0x10+i*0x10);
        uint64_t size=(u32(header+12)&(1u<<i)) ? u32(header+0x60+i*4):u32(header+0x18+i*0x10);
        if (starts[i]<0x100 || !fits(starts[i],size,m->size)) return fail(f,MNG_PREPARE_INVALID);
        ends[i]=starts[i]+size;
        for (unsigned j=0;j<i;j++) if (size && ends[j]>starts[j] && starts[i]<ends[j] && starts[j]<ends[i]) return fail(f,MNG_PREPARE_INVALID);
    }
    return 0;
}
static int plaintext(struct folder *f,struct mng_prepare_result *r) {
    size_t npdm=SIZE_MAX,image=SIZE_MAX;int main=0;
    for (size_t i=0;i<f->count;i++) {
        if (!strcmp(f->members[i].path,"exefs/main.npdm")) npdm=i;
        else if (!strcmp(f->members[i].path,"romfs.bin")) image=i;
        else { if (validate_nso(f,i)) return -1;if (!strcmp(f->members[i].path,"exefs/main")) main=1; }
    }
    if (!main || npdm==SIZE_MAX || image==SIZE_MAX) return fail(f,MNG_PREPARE_INVALID);
    if (f->count>127) return fail(f,MNG_PREPARE_LIMIT);
    unsigned char header[0x80],aci[0x20];
    if (f->members[npdm].size<sizeof(header)) return fail(f,MNG_PREPARE_INVALID);
    if (f->members[npdm].size>(1u<<20)) return fail(f,MNG_PREPARE_LIMIT);
    if (member_read(f,npdm,0,header,sizeof(header))) return -1;
    uint64_t offset=u32(header+0x70),size=u32(header+0x74);
    /* Same public META/ACI0 layout used by build_app.py:npdm_program_id.
     * This is a bounded program-ID claim, not ACID signature verification. */
    if (memcmp(header,"META",4) || offset<sizeof(header) || size<sizeof(aci) || !fits(offset,size,f->members[npdm].size))
        return fail(f,MNG_PREPARE_INVALID);
    if (member_read(f,npdm,offset,aci,sizeof(aci))) return -1;
    if (memcmp(aci,"ACI0",4) || !u64(aci+0x10)) return fail(f,MNG_PREPARE_INVALID);
    r->title_id=u64(aci+0x10);r->application_id=r->title_id;
    if (open_member(f,image)) return -1;
    struct mng_romfs_callbacks callbacks={0};callbacks.context=f;callbacks.cancelled=romfs_cancel;
    if (f->callbacks && f->callbacks->canonical_name) callbacks.canonical_name=romfs_canonical;
    struct mng_romfs_result indexed={0};progress(f,"validate-romfs-structure",0,0);
    enum mng_romfs_status checked=mng_romfs_index_fd(f->cached,&callbacks,&indexed);
    if (checked!=MNG_ROMFS_OK) {
        enum mng_prepare_status status=checked==MNG_ROMFS_CANCELLED ? MNG_PREPARE_CANCELLED:
            checked==MNG_ROMFS_LIMIT ? MNG_PREPARE_LIMIT:checked==MNG_ROMFS_UNSUPPORTED ? MNG_PREPARE_UNSUPPORTED:
            checked==MNG_ROMFS_IO ? MNG_PREPARE_IO:checked==MNG_ROMFS_NOMEM ? MNG_PREPARE_NOMEM:MNG_PREPARE_INVALID;
        return fail(f,status);
    }
    r->romfs_structure_verified=1;
    for (size_t i=0;i<f->count;i++) if (copy_member(f,i,r)) return -1;
    r->asset_hashes_verified=1;r->source_kind=MNG_PREPARE_ASSET_FOLDER;return 0;
}
static int inventory_asset(struct folder *f,enum mng_folder_kind kind,struct mng_prepare_result *r) {
    char *json=calloc(1,JSON_BYTES);if (!json)return fail(f,MNG_PREPARE_NOMEM);
    int first=snprintf(json,JSON_BYTES,"{\"schemaVersion\":1,\"sourceKind\":\"%s\",\"members\":[",kind==MNG_FOLDER_NCA ? "nca-folder":"asset-folder");
    size_t used=first>0 ? (size_t)first:JSON_BYTES;int status=-1;
    for (size_t i=0;i<f->count;i++) {
        if (stopped(f)) goto done;
        char hex[65];for (unsigned j=0;j<32;j++) snprintf(hex+j*2,3,"%02x",f->members[i].sha[j]);
        if (used>=JSON_BYTES) { fail(f,MNG_PREPARE_LIMIT);goto done; }
        int n=snprintf(json+used,JSON_BYTES-used,"%s{\"path\":\"%s\",\"size\":%llu,\"sha256\":\"%s\"}",i ? ",":"",
            kind==MNG_FOLDER_ASSETS && f->members[i].parent==2 ? "romfs/romfs.bin":f->members[i].path,
            (unsigned long long)f->members[i].size,hex);
        if (n<0 || (size_t)n>=JSON_BYTES-used) { fail(f,MNG_PREPARE_LIMIT);goto done; }used+=(size_t)n;
    }
    if (used+4>=JSON_BYTES) { fail(f,MNG_PREPARE_LIMIT);goto done; }
    memcpy(json+used,"]}\n",3);used+=3;
    if (r->asset_count>=128 || r->asset_bytes>OUTPUT_BYTES || used>OUTPUT_BYTES-r->asset_bytes) { fail(f,MNG_PREPARE_LIMIT);goto done; }
    struct mng_sha256 *hash=NULL;
    int bad=mng_sha256_init(&hash) || mng_sha256_update(hash,json,used) || mng_sha256_final(hash,r->member_inventory_sha256);
    mng_sha256_free(hash);if (bad) { fail(f,MNG_PREPARE_IO);goto done; }
    if (stopped(f)) goto done;
    if (f->sink->begin(f->sink->context,"input-members.json",used) || f->sink->write(f->sink->context,json,used)) {
        if (!stopped(f))fail(f,MNG_PREPARE_IO);
        goto done;
    }
    if (finish_asset(f,r,r->member_inventory_sha256,used)) goto done;
    r->source_member_bytes=f->bytes;r->source_member_count=(uint32_t)f->count;status=0;
done:
    free(json);return status;
}
enum mng_prepare_status mng_prepare_folder_fd(int root,enum mng_folder_kind kind,
    const struct mng_key_provider *keys,const struct mng_folder_callbacks *callbacks,
    const struct mng_asset_sink *sink,struct mng_prepare_result *result) {
    if (!mng_prepare_result_empty(result) || !sink || !sink->begin || !sink->write || !sink->end ||
        (kind!=MNG_FOLDER_NCA && kind!=MNG_FOLDER_ASSETS) || (kind==MNG_FOLDER_NCA && (!keys || !keys->lookup))) return MNG_PREPARE_INVALID;
    struct folder f={0};f.dirs[0]=f.dirs[1]=f.dirs[2]=f.cached=-1;f.sink=sink;f.callbacks=callbacks;
    f.members=calloc(MEMBERS,sizeof(*f.members));if (!f.members)return MNG_PREPARE_NOMEM;
    struct mng_prepare_result prepared={0};
    f.dirs[0]=openat(root,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (f.dirs[0]<0 || fstat(f.dirs[0],f.before)) { fail(&f,MNG_PREPARE_IO);goto done; }
    f.snapshots=1;
    if (kind==MNG_FOLDER_NCA) { if (enumerate(&f,0,1)) goto done; }
    else {
        f.dirs[1]=openat(f.dirs[0],"exefs",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        f.dirs[2]=openat(f.dirs[0],"romfs",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if (f.dirs[1]<0 || f.dirs[2]<0) { fail(&f,MNG_PREPARE_INVALID);goto done; }
        if (fstat(f.dirs[1],f.before+1)) { fail(&f,MNG_PREPARE_IO);goto done; }f.snapshots|=2;
        if (fstat(f.dirs[2],f.before+2)) { fail(&f,MNG_PREPARE_IO);goto done; }f.snapshots|=4;
        if (check_layout_directory(&f,0) || check_layout_directory(&f,2) ||
            enumerate(&f,1,0) || add_member(&f,2,"romfs.bin","")) goto done;
    }
    if (!f.count) { fail(&f,MNG_PREPARE_INVALID);goto done; }
    if (kind==MNG_FOLDER_ASSETS && f.bytes>OUTPUT_BYTES) { fail(&f,MNG_PREPARE_LIMIT);goto done; }
    qsort(f.members,f.count,sizeof(*f.members),by_path);
    if (fingerprint(&f)) goto done;
    if (kind==MNG_FOLDER_NCA) {
        if (build_view(&f)) goto done;
        struct mng_prepare_reader reader={&f,f.view_size,view_read,check_reader};
        enum mng_prepare_status status=mng_prepare_nca_folder_reader(&reader,keys,sink,&prepared);
        if (status!=MNG_PREPARE_OK) { if (!f.status)f.status=status;goto done; }
    } else if (plaintext(&f,&prepared)) goto done;
    if (inventory_asset(&f,kind,&prepared) || stopped(&f)) goto done;
done:
    if (f.dirs[0]>=0 && folder_stat(&f)) f.status=MNG_PREPARE_IO;
    if (f.status==MNG_PREPARE_OK) *result=prepared;
    if (f.cached>=0)close(f.cached);
    for (unsigned i=0;i<3;i++) if (f.dirs[i]>=0)close(f.dirs[i]);
    free(f.members);free(f.table);return f.status;
}
