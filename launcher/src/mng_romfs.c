#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "mng_romfs.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define NONE UINT32_MAX
#define META_LIMIT (32u*1024u*1024u)
#define PATH_LIMIT 4096u
#define NAME_LIMIT 1024u
#define DIR_LIMIT 16384u
#define FILE_LIMIT 65536u
#define BYTE_LIMIT (UINT64_C(64)*1024*1024*1024)
struct metadata {
    uint32_t offset,parent,sibling,child,file,name_length,hash_next;
    uint64_t data,size;
    const unsigned char *name;
    int seen,hash_state;
};
struct item { char *path,*alias; uint64_t offset,size; int directory; };
struct context {
    int fd;
    uint64_t image_size,data_offset,done;
    struct mng_romfs_callbacks callbacks;
    enum mng_romfs_status status;
    unsigned char *dir_table,*file_table;
    struct metadata *dirs,*files;
    size_t dir_count,file_count,item_count,path_bytes;
    struct item *items;
    struct mng_romfs_result result;
};
static uint32_t u32(const unsigned char *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
static uint64_t u64(const unsigned char *p) { return u32(p)|(uint64_t)u32(p+4)<<32; }
static int fits(uint64_t a,uint64_t n,uint64_t bound) { return a<=bound && n<=bound-a; }
static int fail(struct context *c,enum mng_romfs_status status) { c->status=status; return -1; }
static int cancelled(struct context *c) {
    return c->callbacks.cancelled && c->callbacks.cancelled(c->callbacks.context)
        ? fail(c,MNG_ROMFS_CANCELLED):0;
}
static void progress(struct context *c) {
    if (c->callbacks.progress) c->callbacks.progress(c->callbacks.context,c->done,c->result.bytes);
}
static int read_at(struct context *c,uint64_t offset,void *output,size_t length) {
    if (!fits(offset,length,c->image_size)) return fail(c,MNG_ROMFS_INVALID);
    unsigned char *cursor=output;
    while (length) {
        if (cancelled(c)) return -1;
        size_t request=length>65536 ? 65536:length;
        ssize_t n=pread(c->fd,cursor,request,(off_t)offset);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) return fail(c,MNG_ROMFS_IO);
        cursor+=(size_t)n; offset+=(uint64_t)n; length-=(size_t)n;
    }
    return 0;
}
/* Strict UTF-8 and portable safe components. No controls, NUL, separators,
 * dot traversal or colon (avoids alternate platform path interpretations). */
static int component(const unsigned char *name,size_t size,int *nonascii) {
    *nonascii=0;
    if (!size || size>NAME_LIMIT || (size==1 && name[0]=='.') ||
        (size==2 && name[0]=='.' && name[1]=='.')) return 0;
    for (size_t i=0;i<size;) {
        unsigned value=name[i++], extra, minimum;
        if (value<128) {
            if (value<32 || value==127 || value=='/' || value=='\\' || value==':') return 0;
            continue;
        }
        *nonascii=1;
        if (value>=0xc2 && value<=0xdf) { extra=1;value&=31;minimum=0x80; }
        else if (value>=0xe0 && value<=0xef) { extra=2;value&=15;minimum=0x800; }
        else if (value>=0xf0 && value<=0xf4) { extra=3;value&=7;minimum=0x10000; }
        else return 0;
        if (extra>size-i) return 0;
        while (extra--) {
            unsigned next=name[i++];
            if ((next&0xc0)!=0x80) return 0;
            value=(value<<6)|(next&63);
        }
        if (value<minimum || value>0x10ffff || (value>=0xd800 && value<=0xdfff)) return 0;
    }
    return 1;
}
static int parse_table(struct context *c,unsigned char *bytes,size_t size,int directory,
    struct metadata **output,size_t *output_count) {
    size_t at=0,count=0,fixed=directory ? 24:32, limit=directory ? DIR_LIMIT:FILE_LIMIT;
    while (at<size) {
        if (cancelled(c)) return -1;
        if (size-at<fixed) return fail(c,MNG_ROMFS_INVALID);
        uint32_t n=u32(bytes+at+fixed-4);
        if (n>NAME_LIMIT) return fail(c,MNG_ROMFS_LIMIT);
        if (n>size-at-fixed) return fail(c,MNG_ROMFS_INVALID);
        size_t raw=fixed+n, padded=(raw+3)&~(size_t)3;
        at+=padded<=size-at ? padded:raw;
        if (++count>limit) return fail(c,MNG_ROMFS_LIMIT);
    }
    struct metadata *records=calloc(count ? count:1,sizeof(*records));
    if (!records) return fail(c,MNG_ROMFS_NOMEM);
    at=0;
    for (size_t i=0;i<count;i++) {
        unsigned char *p=bytes+at; uint32_t n=u32(p+fixed-4);
        records[i]=(struct metadata){(uint32_t)at,u32(p),u32(p+4),NONE,NONE,n,u32(p+fixed-8),0,0,p+fixed,0,0};
        if (directory) { records[i].child=u32(p+8); records[i].file=u32(p+12); }
        else { records[i].data=u64(p+8); records[i].size=u64(p+16); }
        size_t raw=fixed+n, padded=(raw+3)&~(size_t)3;
        at+=padded<=size-at ? padded:raw;
    }
    *output=records; *output_count=count; return 0;
}
static struct metadata *lookup(struct metadata *records,size_t count,uint32_t offset) {
    size_t left=0,right=count;
    while (left<right) {
        size_t middle=left+(right-left)/2;
        if (records[middle].offset<offset) left=middle+1;
        else right=middle;
    }
    return left<count && records[left].offset==offset ? records+left:NULL;
}
static int hash_links(struct context *c,struct metadata *records,size_t count,uint64_t offset,uint64_t size) {
    if (size%4) return fail(c,MNG_ROMFS_INVALID);
    unsigned char bytes[65536];
    for (uint64_t at=0;at<size;) {
        size_t n=size-at>sizeof(bytes) ? sizeof(bytes):(size_t)(size-at);
        if (read_at(c,offset+at,bytes,n)) return -1;
        for (size_t j=0;j<n;j+=4) if (u32(bytes+j)!=NONE && !lookup(records,count,u32(bytes+j)))
            return fail(c,MNG_ROMFS_INVALID);
        at+=n;
    }
    for (size_t i=0;i<count;i++) if (records[i].hash_next!=NONE && !lookup(records,count,records[i].hash_next))
        return fail(c,MNG_ROMFS_INVALID);
    for (size_t i=0;i<count;i++) {
        struct metadata *p=records+i;
        while (p && !p->hash_state) {
            if (cancelled(c)) return -1;
            p->hash_state=1;
            p=p->hash_next==NONE ? NULL:lookup(records,count,p->hash_next);
        }
        if (p && p->hash_state==1) return fail(c,MNG_ROMFS_INVALID);
        p=records+i;
        while (p && p->hash_state==1) {
            p->hash_state=2;
            p=p->hash_next==NONE ? NULL:lookup(records,count,p->hash_next);
        }
    }
    return 0;
}
static int join(char output[PATH_LIMIT],const char *parent,const char *name) {
    size_t a=strlen(parent),b=strlen(name);
    if (a+b+(a!=0)>=PATH_LIMIT) return -1;
    memcpy(output,parent,a);
    if (a) output[a++]='/';
    memcpy(output+a,name,b+1); return 0;
}
static int name_alias(struct context *c,const struct metadata *m,char name[NAME_LIMIT+1],char alias[PATH_LIMIT]) {
    int nonascii;
    if (!component(m->name,m->name_length,&nonascii)) return fail(c,MNG_ROMFS_INVALID);
    memcpy(name,m->name,m->name_length); name[m->name_length]=0;
    if (nonascii) {
        if (!c->callbacks.canonical_name) return fail(c,MNG_ROMFS_UNSUPPORTED);
        memset(alias,0,PATH_LIMIT);
        if (c->callbacks.canonical_name(c->callbacks.context,name,alias,PATH_LIMIT))
            return fail(c,MNG_ROMFS_UNSUPPORTED);
        size_t n=strnlen(alias,PATH_LIMIT);
        if (!n || n==PATH_LIMIT || !component((unsigned char *)alias,n,&nonascii))
            return fail(c,MNG_ROMFS_INVALID);
    } else {
        for (size_t i=0;i<=m->name_length;i++) {
            unsigned char b=(unsigned char)name[i];
            alias[i]=(char)(b>='A' && b<='Z' ? b+32:b);
        }
    }
    return 0;
}
static int add_item(struct context *c,const struct metadata *m,const char *parent,const char *alias_parent,int directory,
    const char **out_path,const char **out_alias) {
    char name[NAME_LIMIT+1],canonical[PATH_LIMIT],path[PATH_LIMIT],alias[PATH_LIMIT];
    if (name_alias(c,m,name,canonical)) return -1;
    if (join(path,parent,name) || join(alias,alias_parent,canonical)) return fail(c,MNG_ROMFS_LIMIT);
    size_t bytes=strlen(path)+strlen(alias)+2;
    if (bytes>META_LIMIT-c->path_bytes) return fail(c,MNG_ROMFS_LIMIT);
    struct item *item=c->items+c->item_count;
    item->path=strdup(path); item->alias=strdup(alias); item->directory=directory;
    if (!item->path || !item->alias) { free(item->path);free(item->alias);return fail(c,MNG_ROMFS_NOMEM); }
    c->item_count++; c->path_bytes+=bytes;
    if (out_path) *out_path=item->path;
    if (out_alias) *out_alias=item->alias;
    if (directory) c->result.directories++;
    else {
        if (!fits(m->data,m->size,c->image_size-c->data_offset)) return fail(c,MNG_ROMFS_INVALID);
        if (m->size>BYTE_LIMIT-c->result.bytes) return fail(c,MNG_ROMFS_LIMIT);
        item->offset=c->data_offset+m->data; item->size=m->size;
        c->result.files++; c->result.bytes+=m->size;
    }
    return 0;
}
static int walk(struct context *c,struct metadata *dir,uint32_t parent,unsigned depth,
    const char *parent_path,const char *parent_alias,int root) {
    const char *path="",*alias="";
    if (cancelled(c)) return -1;
    if (depth>64) return fail(c,MNG_ROMFS_LIMIT);
    if (!dir || dir->seen || dir->parent!=parent) return fail(c,MNG_ROMFS_INVALID);
    dir->seen=1;
    if (root) {
        if (dir->name_length || dir->offset || dir->sibling!=NONE) return fail(c,MNG_ROMFS_INVALID);
    } else if (add_item(c,dir,parent_path,parent_alias,1,&path,&alias)) return -1;
    uint32_t file=dir->file;
    while (file!=NONE) {
        if (cancelled(c)) return -1;
        struct metadata *m=lookup(c->files,c->file_count,file);
        if (!m || m->seen || m->parent!=dir->offset) return fail(c,MNG_ROMFS_INVALID);
        m->seen=1;
        if (add_item(c,m,path,alias,0,NULL,NULL)) return -1;
        file=m->sibling;
    }
    uint32_t child=dir->child;
    while (child!=NONE) {
        struct metadata *m=lookup(c->dirs,c->dir_count,child);
        if (!m) return fail(c,MNG_ROMFS_INVALID);
        if (walk(c,m,dir->offset,depth+1,path,alias,0)) return -1;
        child=m->sibling;
    }
    return 0;
}
static int by_alias(const void *a,const void *b) {
    return strcmp(((const struct item *)a)->alias,((const struct item *)b)->alias);
}
static int by_offset(const void *a,const void *b) {
    const struct item *x=*(const struct item *const *)a,*y=*(const struct item *const *)b;
    return x->offset<y->offset ? -1:x->offset>y->offset;
}
static int index_image(struct context *c) {
    unsigned char header[80]; uint64_t h[10];
    if (c->image_size<80) return fail(c,MNG_ROMFS_INVALID);
    if (read_at(c,0,header,sizeof(header))) return -1;
    for (unsigned i=0;i<10;i++) h[i]=u64(header+i*8);
    if (h[0]!=80 || h[9]<80 || h[9]>c->image_size || h[4]<24) return fail(c,MNG_ROMFS_INVALID);
    uint64_t metadata_bytes=0;
    for (unsigned i=2;i<9;i+=2) {
        if (h[i]>META_LIMIT-metadata_bytes) return fail(c,MNG_ROMFS_LIMIT);
        metadata_bytes+=h[i];
    }
    for (unsigned i=1;i<9;i+=2) {
        if (!fits(h[i],h[i+1],c->image_size) || (h[i+1] && h[i]<80) ||
            h[i]+h[i+1]>h[9]) return fail(c,MNG_ROMFS_INVALID);
        for (unsigned j=1;j<i;j+=2) if (h[i+1] && h[j+1] && h[i]<h[j]+h[j+1] && h[j]<h[i]+h[i+1])
            return fail(c,MNG_ROMFS_INVALID);
    }
    c->data_offset=h[9];
    c->dir_table=malloc((size_t)h[4]); c->file_table=malloc(h[8] ? (size_t)h[8]:1);
    if (!c->dir_table || !c->file_table) return fail(c,MNG_ROMFS_NOMEM);
    if (read_at(c,h[3],c->dir_table,(size_t)h[4]) || read_at(c,h[7],c->file_table,(size_t)h[8])) return -1;
    if (parse_table(c,c->dir_table,(size_t)h[4],1,&c->dirs,&c->dir_count) ||
        parse_table(c,c->file_table,(size_t)h[8],0,&c->files,&c->file_count)) return -1;
    if (hash_links(c,c->dirs,c->dir_count,h[1],h[2]) || hash_links(c,c->files,c->file_count,h[5],h[6])) return -1;
    c->items=calloc(c->dir_count+c->file_count,sizeof(*c->items));
    if (!c->items) return fail(c,MNG_ROMFS_NOMEM);
    if (walk(c,c->dirs,0,0,"","",1)) return -1;
    for (size_t i=0;i<c->dir_count;i++) if (!c->dirs[i].seen) return fail(c,MNG_ROMFS_INVALID);
    for (size_t i=0;i<c->file_count;i++) if (!c->files[i].seen) return fail(c,MNG_ROMFS_INVALID);
    qsort(c->items,c->item_count,sizeof(*c->items),by_alias);
    for (size_t i=1;i<c->item_count;i++) if (!strcmp(c->items[i-1].alias,c->items[i].alias)) return fail(c,MNG_ROMFS_INVALID);
    struct item **files=calloc(c->file_count ? c->file_count:1,sizeof(*files));
    if (!files) return fail(c,MNG_ROMFS_NOMEM);
    size_t count=0;
    for (size_t i=0;i<c->item_count;i++) if (!c->items[i].directory && c->items[i].size) files[count++]=c->items+i;
    qsort(files,count,sizeof(*files),by_offset);
    int status=0;
    for (size_t i=1;i<count;i++) if (files[i]->offset<files[i-1]->offset+files[i-1]->size) { status=fail(c,MNG_ROMFS_INVALID);break; }
    free(files); return status;
}
static int parent_fd(struct context *c,int root,const char *path,char leaf[NAME_LIMIT+1]) {
    char copy[PATH_LIMIT]; strcpy(copy,path);
    int fd=openat(root,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (fd<0) return fail(c,MNG_ROMFS_IO);
    char *p=copy,*slash;
    while ((slash=strchr(p,'/'))!=NULL) {
        *slash=0;
        int child=openat(fd,p,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        close(fd); fd=child;
        if (fd<0) return fail(c,MNG_ROMFS_IO);
        p=slash+1;
    }
    strcpy(leaf,p); return fd;
}
static int directory_empty(struct context *c,int root) {
    struct stat st;
    if (fstat(root,&st) || !S_ISDIR(st.st_mode)) return fail(c,MNG_ROMFS_INVALID);
    int fd=openat(root,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (fd<0) return fail(c,MNG_ROMFS_IO);
    DIR *directory=fdopendir(fd);
    if (!directory) { close(fd);return fail(c,MNG_ROMFS_IO); }
    int result=0; struct dirent *entry;
    errno=0;
    while ((entry=readdir(directory))!=NULL) if (strcmp(entry->d_name,".") && strcmp(entry->d_name,"..")) { result=fail(c,MNG_ROMFS_INVALID);break; }
    if (!result && errno) result=fail(c,MNG_ROMFS_IO);
    closedir(directory); return result;
}
static int materialize(struct context *c,int root) {
    if (directory_empty(c,root)) return -1;
    for (size_t i=0;i<c->item_count;i++) {
        if (cancelled(c)) return -1;
        struct item *item=c->items+i;
        if (!item->directory) continue;
        char leaf[NAME_LIMIT+1]; int parent=parent_fd(c,root,item->path,leaf);
        if (parent<0) return -1;
        int result=mkdirat(parent,leaf,0700); close(parent);
        if (result) return fail(c,MNG_ROMFS_IO);
        if (c->callbacks.directory && c->callbacks.directory(c->callbacks.context,item->path))
            return fail(c,MNG_ROMFS_IO);
    }
    unsigned char buffer[65536];
    progress(c);
    for (size_t i=0;i<c->item_count;i++) {
        struct item *item=c->items+i;
        if (item->directory) continue;
        if (cancelled(c)) return -1;
        char leaf[NAME_LIMIT+1]; int parent=parent_fd(c,root,item->path,leaf);
        if (parent<0) return -1;
        int fd=openat(parent,leaf,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600); close(parent);
        if (fd<0) return fail(c,MNG_ROMFS_IO);
        int result=0;
        for (uint64_t at=0;at<item->size;) {
            size_t n=item->size-at>sizeof(buffer) ? sizeof(buffer):(size_t)(item->size-at);
            if (read_at(c,item->offset+at,buffer,n)) { result=-1;break; }
            size_t written=0;
            while (written<n) {
                ssize_t amount=write(fd,buffer+written,n-written);
                if (amount<0 && errno==EINTR) continue;
                if (amount<=0) { result=fail(c,MNG_ROMFS_IO);break; }
                written+=(size_t)amount;
            }
            if (result) break;
            at+=n; c->done+=n; progress(c);
        }
        struct stat st;
        if (!result && (fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_nlink!=1 ||
                        (uint64_t)st.st_size!=item->size || fsync(fd))) result=fail(c,MNG_ROMFS_IO);
        if (close(fd) && !result) result=fail(c,MNG_ROMFS_IO);
        if (result) return -1;
        if (cancelled(c)) return -1;
        if (c->callbacks.entry && c->callbacks.entry(c->callbacks.context,item->path,item->offset,item->size))
            return fail(c,MNG_ROMFS_IO);
    }
    return 0;
}
static int stable(const struct stat *a,const struct stat *b) {
#ifdef __APPLE__
    const struct timespec am=a->st_mtimespec,bm=b->st_mtimespec,ac=a->st_ctimespec,bc=b->st_ctimespec;
#else
    const struct timespec am=a->st_mtim,bm=b->st_mtim,ac=a->st_ctim,bc=b->st_ctim;
#endif
    return S_ISREG(b->st_mode) && b->st_nlink==1 && a->st_dev==b->st_dev && a->st_ino==b->st_ino &&
        a->st_size==b->st_size && am.tv_sec==bm.tv_sec && am.tv_nsec==bm.tv_nsec &&
        ac.tv_sec==bc.tv_sec && ac.tv_nsec==bc.tv_nsec;
}
static enum mng_romfs_status process(int image,int destination,int extract,
    const struct mng_romfs_callbacks *callbacks,struct mng_romfs_result *result) {
    if (!result || result->files || result->directories || result->bytes) return MNG_ROMFS_INVALID;
    struct stat before,after;
    if (fstat(image,&before)) return MNG_ROMFS_IO;
    if (!S_ISREG(before.st_mode) || before.st_nlink!=1 || before.st_size<0) return MNG_ROMFS_INVALID;
    if ((uint64_t)before.st_size>UINT64_C(128)*1024*1024*1024) return MNG_ROMFS_LIMIT;
    struct context c={0}; c.fd=image;c.image_size=(uint64_t)before.st_size;
    if (callbacks) c.callbacks=*callbacks;
    if (cancelled(&c) || index_image(&c)) goto done;
    if (extract) { if (materialize(&c,destination)) goto done; }
    else for (size_t i=0;i<c.item_count;i++) {
        if (cancelled(&c)) goto done;
        struct item *item=c.items+i;
        if (item->directory && c.callbacks.directory && c.callbacks.directory(c.callbacks.context,item->path)) {
            fail(&c,MNG_ROMFS_IO);goto done;
        }
        if (!item->directory && c.callbacks.entry && c.callbacks.entry(c.callbacks.context,item->path,item->offset,item->size)) {
            fail(&c,MNG_ROMFS_IO);goto done;
        }
    }
    if (cancelled(&c)) goto done;
done:
    if (fstat(image,&after) || !stable(&before,&after)) c.status=MNG_ROMFS_IO;
    if (c.status==MNG_ROMFS_OK) *result=c.result;
    for (size_t i=0;i<c.item_count;i++) { free(c.items[i].path);free(c.items[i].alias); }
    free(c.items);free(c.dirs);free(c.files);free(c.dir_table);free(c.file_table);
    return c.status;
}
enum mng_romfs_status mng_romfs_index_fd(int image,const struct mng_romfs_callbacks *callbacks,struct mng_romfs_result *result) {
    return process(image,-1,0,callbacks,result);
}
enum mng_romfs_status mng_romfs_extract_fd(int image,int directory,const struct mng_romfs_callbacks *callbacks,struct mng_romfs_result *result) {
    return process(image,directory,1,callbacks,result);
}
const char *mng_romfs_status_name(enum mng_romfs_status status) {
    static const char *names[]={"ok","invalid","io","unsupported","cancelled","limit","nomem"};
    return status>=MNG_ROMFS_OK && status<=MNG_ROMFS_NOMEM ? names[status]:"unknown";
}
