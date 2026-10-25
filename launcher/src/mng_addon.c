#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include "mng_addon.h"
#include "mng_crypto.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#define MAX_IMAGE (UINT64_C(64)<<30)
#define MAX_INDEX (34u<<20)
#define HANDLES 256u
struct opened { uint64_t token; size_t row; };
struct mng_addon_volume {
    int image,index,pin;
    struct stat image_stat,index_stat;
    unsigned char *data;
    uint64_t count,strings,next;
    struct opened handles[HANDLES];
    pthread_mutex_t lock;
    struct mng_addon_callbacks callbacks;
};
static uint32_t u32(const unsigned char *p) {return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static uint64_t u64(const unsigned char *p) {return u32(p)|(uint64_t)u32(p+4)<<32;}
static int nonzero(const unsigned char *p) {unsigned n=0;for(unsigned i=0;i<32;i++)n|=p[i];return n!=0;}
static int base_valid(const struct mng_addon_base *b) {return b&&b->application_id&&b->version_verified==1;}
static int same(const struct stat *a,const struct stat *b) {
#ifdef __APPLE__
    const struct timespec am=a->st_mtimespec,bm=b->st_mtimespec,ac=a->st_ctimespec,bc=b->st_ctimespec;
#else
    const struct timespec am=a->st_mtim,bm=b->st_mtim,ac=a->st_ctim,bc=b->st_ctim;
#endif
    return a->st_dev==b->st_dev&&a->st_ino==b->st_ino&&a->st_size==b->st_size&&a->st_mode==b->st_mode&&
        a->st_nlink==b->st_nlink&&am.tv_sec==bm.tv_sec&&am.tv_nsec==bm.tv_nsec&&ac.tv_sec==bc.tv_sec&&ac.tv_nsec==bc.tv_nsec;
}
static int private_fd(int fd,uint64_t maximum,struct stat *st) {
    return !fstat(fd,st)&&S_ISREG(st->st_mode)&&st->st_uid==geteuid()&&st->st_nlink==1&&!(st->st_mode&077)&&
        st->st_size>=0&&(uint64_t)st->st_size<=maximum;
}
static int stable(struct mng_addon_volume *v) {
    struct stat a,b;return !fstat(v->image,&a)&&!fstat(v->index,&b)&&same(&a,&v->image_stat)&&same(&b,&v->index_stat);
}
static int stopped(const struct mng_addon_callbacks *c) {return c&&c->cancelled&&c->cancelled(c->context);}
static enum mng_prepare_status read_at(int fd,uint64_t offset,void *bytes,size_t n,const struct mng_addon_callbacks *c) {
    unsigned char *p=bytes;
    while(n){if(stopped(c))return MNG_PREPARE_CANCELLED;size_t want=n>65536?65536:n;
        ssize_t got=pread(fd,p,want,(off_t)offset);if(got<0&&errno==EINTR)continue;if(got<=0)return MNG_PREPARE_IO;
        p+=(size_t)got;n-=(size_t)got;offset+=(uint64_t)got;}
    return MNG_PREPARE_OK;
}
static enum mng_prepare_status hash_fd(int fd,uint64_t size,const unsigned char expected[32],const struct mng_addon_callbacks *c) {
    struct mng_sha256 *hash=NULL;unsigned char *bytes=malloc(65536),digest[32];
    if(!bytes||mng_sha256_init(&hash)){free(bytes);return MNG_PREPARE_NOMEM;}
    enum mng_prepare_status status=MNG_PREPARE_OK;
    for(uint64_t at=0;at<size;){size_t n=size-at>65536?65536:(size_t)(size-at);
        status=read_at(fd,at,bytes,n,c);if(status)break;
        if(mng_sha256_update(hash,bytes,n)){status=MNG_PREPARE_IO;break;}at+=n;}
    if(!status&&(mng_sha256_final(hash,digest)||memcmp(digest,expected,32)))status=MNG_PREPARE_INTEGRITY;
    mng_sha256_free(hash);free(bytes);return status;
}
/* Strict UTF8 and relative-component grammar; lookup never normalizes names. */
static int path_valid(const char *path) {
    if(!path)return 0;
    size_t n=strnlen(path,4096);if(!n||n==4096)return 0;
    size_t component=0,depth=1;
    for(size_t i=0;i<n;){unsigned char c=(unsigned char)path[i];
        if(c=='/'){if(++depth>64)return 0;size_t len=i-component;if(!len||len>1024||(len==1&&path[component]=='.')||
            (len==2&&path[component]=='.'&&path[component+1]=='.'))return 0;
            component=++i;continue;}
        if(c<32||c==127||c=='\\'||c==':')return 0;
        if(c<128){i++;continue;}
        size_t count;uint32_t code,minimum;
        if(c>=0xc2&&c<=0xdf){count=2;code=c&31;minimum=0x80;}
        else if(c>=0xe0&&c<=0xef){count=3;code=c&15;minimum=0x800;}
        else if(c>=0xf0&&c<=0xf4){count=4;code=c&7;minimum=0x10000;}else return 0;
        if(count>n-i)return 0;
        for(size_t j=1;j<count;j++){unsigned char d=(unsigned char)path[i+j];if((d&0xc0)!=0x80)return 0;code=(code<<6)|(d&63);}
        if(code<minimum||code>0x10ffff||(code>=0xd800&&code<=0xdfff))return 0;
        i+=count;
    }
    size_t len=n-component;return len&&len<=1024&&!(len==1&&path[component]=='.')&&!(len==2&&path[component]=='.'&&path[component+1]=='.');
}
enum mng_prepare_status mng_addon_plan(const struct mng_content *const *metadata,size_t count,
    const struct mng_content_candidate *candidates,size_t candidate_count,const struct mng_addon_base *base,struct mng_addon_plan *out) {
    if(!out||!base_valid(base)||!metadata||!count||(!candidates&&candidate_count))return MNG_PREPARE_INVALID;
    if(count>256||candidate_count>16384)return MNG_PREPARE_LIMIT;
    struct mng_addon_plan plan={0};
    for(size_t i=0;i<count;i++){
        const struct mng_content *m=metadata[i];
        if(!m||m->type!=MNG_CONTENT_ADDON||!m->title_id||m->title_id==base->application_id||m->application_id!=base->application_id)return MNG_PREPARE_INVALID;
        if(m->dependency_count||!m->content_count||m->content_count>4096||!m->contents)return MNG_PREPARE_UNSUPPORTED;
        for(size_t j=0;j<m->content_count;j++)if(m->contents[j].role!=2||m->contents[j].id_offset)return MNG_PREPARE_UNSUPPORTED;
        enum mng_content_status bound=mng_content_bind(m,candidates,candidate_count);
        if(bound!=MNG_CONTENT_OK)return bound==MNG_CONTENT_NOMEM?MNG_PREPARE_NOMEM:bound==MNG_CONTENT_LIMIT?MNG_PREPARE_LIMIT:MNG_PREPARE_INTEGRITY;
        size_t j=0;while(j<plan.count&&metadata[plan.metadata_indices[j]]->title_id!=m->title_id)j++;
        if(j==plan.count){if(plan.count==MNG_ADDON_MAX_VOLUMES)return MNG_PREPARE_LIMIT;plan.metadata_indices[plan.count++]=i;}
        else {const struct mng_content *old=metadata[plan.metadata_indices[j]];
            for(size_t k=0;k<i;k++)if(metadata[k]->title_id==m->title_id&&metadata[k]->version==m->version)return MNG_PREPARE_INVALID;
            if(m->version>old->version)plan.metadata_indices[j]=i;}
    }
    for(size_t i=0;i<plan.count;i++){
        if(metadata[plan.metadata_indices[i]]->required_application_version>base->version)return MNG_PREPARE_UNSUPPORTED;
        for(size_t j=i+1;j<plan.count;j++)if(metadata[plan.metadata_indices[j]]->title_id<metadata[plan.metadata_indices[i]]->title_id){size_t t=plan.metadata_indices[i];plan.metadata_indices[i]=plan.metadata_indices[j];plan.metadata_indices[j]=t;}
    }
    *out=plan;return MNG_PREPARE_OK;
}
void mng_addon_unmount(struct mng_addon_volume *v) {
    if(!v)return;
    if(v->image>=0)close(v->image);
    if(v->index>=0)close(v->index);
    if(v->pin>=0)close(v->pin);
    pthread_mutex_destroy(&v->lock);free(v->data);free(v);
}
/* Every ancestor must be absent as a file. The predecessor alone is not
 * sufficient: a, a-, a/b are sorted, but a- separates the conflicting pair. */
static int contains_path(const struct mng_addon_volume *v,const char *path) {
    uint64_t left=0,right=v->count;
    while(left<right){uint64_t mid=left+(right-left)/2;
        const unsigned char *row=v->data+24+mid*24;
        const char *name=(const char *)v->data+v->strings+u32(row+16);
        int cmp=strcmp(name,path);if(!cmp)return 1;if(cmp<0)left=mid+1;else right=mid;
    }
    return 0;
}
enum mng_prepare_status mng_addon_mount(int image,int index,int pin,const struct mng_addon_binding *binding,
    const struct mng_addon_base *base,const struct mng_addon_result *result,uint64_t index_size,const unsigned char index_sha[32],
    const struct mng_addon_callbacks *callbacks,struct mng_addon_volume **out) {
    if(!out||*out||!binding||!base_valid(base)||!result||!index_sha||!nonzero(index_sha)||
        binding->application_id!=base->application_id||binding->addon_title_id!=result->title_id||
        result->application_id!=base->application_id||!result->title_id||result->title_id==base->application_id||
        result->required_application_version>base->version||result->romfs_verified!=1||!result->source_size||
        !nonzero(result->source_sha256)||!nonzero(result->cnmt_sha256)||!nonzero(result->romfs_sha256)||
        result->source_size>(UINT64_C(128)<<30)||!result->romfs_size||result->romfs_size>MAX_IMAGE||index_size<24||index_size>MAX_INDEX)return MNG_PREPARE_INVALID;
    if(stopped(callbacks))return MNG_PREPARE_CANCELLED;
    struct mng_addon_volume *v=calloc(1,sizeof(*v));if(!v)return MNG_PREPARE_NOMEM;
    v->image=v->index=v->pin=-1;
    if(pthread_mutex_init(&v->lock,NULL)){free(v);return MNG_PREPARE_NOMEM;}
    if(callbacks)v->callbacks=*callbacks;
    v->image=fcntl(image,F_DUPFD_CLOEXEC,0);v->index=fcntl(index,F_DUPFD_CLOEXEC,0);v->pin=fcntl(pin,F_DUPFD_CLOEXEC,0);
    struct stat pin_stat;enum mng_prepare_status status=MNG_PREPARE_INVALID;
    if(!private_fd(v->image,MAX_IMAGE,&v->image_stat)||!private_fd(v->index,MAX_INDEX,&v->index_stat)||
        !private_fd(v->pin,0,&pin_stat)||(uint64_t)v->image_stat.st_size!=result->romfs_size||
        (uint64_t)v->index_stat.st_size!=index_size||(fcntl(v->image,F_GETFL)&O_ACCMODE)!=O_RDONLY||
        (fcntl(v->index,F_GETFL)&O_ACCMODE)!=O_RDONLY)goto failed;
    status=hash_fd(v->image,result->romfs_size,result->romfs_sha256,callbacks);if(status)goto failed;
    status=hash_fd(v->index,index_size,index_sha,callbacks);if(status)goto failed;
    v->data=malloc((size_t)index_size);if(!v->data){status=MNG_PREPARE_NOMEM;goto failed;}
    status=read_at(v->index,0,v->data,(size_t)index_size,callbacks);if(status)goto failed;
    status=MNG_PREPARE_INVALID;
    if(memcmp(v->data,"TOTKRFS1",8))goto failed;
    v->count=u64(v->data+8);v->strings=u64(v->data+16);
    if(v->count>65536||v->strings!=24+v->count*24||v->strings>index_size||
        (!v->count&&index_size!=24)||(v->count&&v->strings==index_size))goto failed;
    uint64_t names=0;const char *previous=NULL;
    for(uint64_t i=0;i<v->count;i++){
        if(stopped(callbacks)){status=MNG_PREPARE_CANCELLED;goto failed;}
        const unsigned char *row=v->data+24+i*24;uint64_t at=u64(row),size=u64(row+8);uint32_t name=u32(row+16),len=u32(row+20);
        if(at>result->romfs_size||size>result->romfs_size-at||name!=names||len<2||len>4096||
            names>index_size-v->strings||len>index_size-v->strings-names)goto failed;
        const char *path=(const char *)v->data+v->strings+names;
        if(path[len-1]||memchr(path,0,len-1)||!path_valid(path)||(previous&&strcmp(previous,path)>=0))goto failed;
        previous=path;names+=len;
    }
    if(names!=index_size-v->strings)goto failed;
    for(uint64_t i=0;i<v->count;i++){
        if(stopped(callbacks)){status=MNG_PREPARE_CANCELLED;goto failed;}
        const unsigned char *row=v->data+24+i*24;
        const char *path=(const char *)v->data+v->strings+u32(row+16);
        char ancestor[4096];memcpy(ancestor,path,strlen(path)+1);
        for(char *p=ancestor;*p;p++)if(*p=='/'){
            if(stopped(callbacks)){status=MNG_PREPARE_CANCELLED;goto failed;}
            *p=0;int conflict=contains_path(v,ancestor);*p='/';if(conflict)goto failed;
        }
    }
    if(!stable(v)){status=MNG_PREPARE_IO;goto failed;}
    if(stopped(callbacks)){status=MNG_PREPARE_CANCELLED;goto failed;}
    *out=v;return MNG_PREPARE_OK;
failed:mng_addon_unmount(v);return status;
}
static struct opened *find(struct mng_addon_volume *v,uint64_t token) {for(unsigned i=0;i<HANDLES;i++)if(token&&v->handles[i].token==token)return v->handles+i;return NULL;}
enum mng_prepare_status mng_addon_open(struct mng_addon_volume *v,const char *path,uint64_t *handle) {
    if(!v||!handle||!path_valid(path))return MNG_PREPARE_INVALID;
    pthread_mutex_lock(&v->lock);enum mng_prepare_status status=MNG_PREPARE_INVALID;
    if(!stable(v)){status=MNG_PREPARE_IO;goto done;}
    uint64_t left=0,right=v->count;
    while(left<right){uint64_t mid=left+(right-left)/2;const unsigned char *row=v->data+24+mid*24;
        const char *name=(const char *)v->data+v->strings+u32(row+16);if(strcmp(name,path)<0)left=mid+1;else right=mid;}
    if(left==v->count||strcmp((const char *)v->data+v->strings+u32(v->data+24+left*24+16),path))goto done;
    status=MNG_PREPARE_LIMIT;if(v->next==UINT64_MAX)goto done;
    for(unsigned i=0;i<HANDLES;i++)if(!v->handles[i].token){v->handles[i]=(struct opened){++v->next,(size_t)left};*handle=v->next;status=MNG_PREPARE_OK;break;}
done:pthread_mutex_unlock(&v->lock);return status;
}
enum mng_prepare_status mng_addon_size(struct mng_addon_volume *v,uint64_t handle,uint64_t *size) {
    if(!v||!size)return MNG_PREPARE_INVALID;
    pthread_mutex_lock(&v->lock);struct opened *h=find(v,handle);
    enum mng_prepare_status status=!stable(v)?MNG_PREPARE_IO:!h?MNG_PREPARE_INVALID:MNG_PREPARE_OK;
    if(!status)*size=u64(v->data+24+h->row*24+8);
    pthread_mutex_unlock(&v->lock);return status;
}
enum mng_prepare_status mng_addon_read(struct mng_addon_volume *v,uint64_t handle,uint64_t offset,void *bytes,size_t capacity,size_t *read_size) {
    if(!read_size)return MNG_PREPARE_INVALID;
    *read_size=0;if(!v||(!bytes&&capacity))return MNG_PREPARE_INVALID;
    pthread_mutex_lock(&v->lock);struct opened *h=find(v,handle);enum mng_prepare_status status=MNG_PREPARE_INVALID;
    if(!h)goto done;
    if(!stable(v)){status=MNG_PREPARE_IO;goto done;}
    const unsigned char *row=v->data+24+h->row*24;uint64_t size=u64(row+8);if(offset>size)goto done;
    size_t n=capacity;if((uint64_t)n>size-offset)n=(size_t)(size-offset);
    status=read_at(v->image,u64(row)+offset,bytes,n,&v->callbacks);
    if(!status&&!stable(v))status=MNG_PREPARE_IO;
    if(!status&&stopped(&v->callbacks))status=MNG_PREPARE_CANCELLED;
    if(!status)*read_size=n;
done:pthread_mutex_unlock(&v->lock);return status;
}
enum mng_prepare_status mng_addon_close(struct mng_addon_volume *v,uint64_t handle) {
    if(!v)return MNG_PREPARE_INVALID;
    pthread_mutex_lock(&v->lock);struct opened *h=find(v,handle);
    if(h)memset(h,0,sizeof(*h));
    pthread_mutex_unlock(&v->lock);return h?MNG_PREPARE_OK:MNG_PREPARE_INVALID;
}
