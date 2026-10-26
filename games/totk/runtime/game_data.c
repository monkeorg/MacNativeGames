#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
/* Shared immutable byte reader for upstream TOTKTAB1 and fixed text schemas.
 * Serializer/layout originate in f541e14e prepare_runtime.py/load_tables.
 * Files and every pointer consumed below remain owned until process exit. */
#include "game_data.h"
#include "game_version.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static const char *const file_names[4]={"runtime-tables.bin","romfs-config.txt","shared-fonts.txt","rewriter.txt"};
static const uint64_t file_limits[4]={UINT64_C(256)<<20,UINT64_C(1)<<20,UINT64_C(1)<<20,UINT64_C(1)<<20};
typedef struct {char magic[8],version[8];uint32_t nmodule,format;uint64_t probe_plt,probe_slot,strings,strings_size,size;} TablesHeader;
typedef struct {char name[16],digest[72];uint64_t file_size,text_end,ro_off,data_off,patch_off,key_off,init,ctor_flag,init_array,init_size,symbols,relocs,gates;uint32_t nsym,nreloc,ngate,reserved;} TablesModule;
typedef struct {uint64_t value,size;uint32_t name;uint8_t defined,binding,type,reserved;} TablesSymbol;
_Static_assert(sizeof(TablesHeader)==64&&sizeof(TablesModule)==208&&sizeof(TablesSymbol)==24&&sizeof(Reloc)==24&&sizeof(Gate)==24,"TOTKTAB1 layout");
struct Config {char *text;const char *keys[32],*values[32];size_t count;};
struct RuntimeGameData {unsigned char *bytes[4];size_t sizes[4];struct Config config[3];Module modules[3];uint64_t probe_plt,probe_slot;int (*cancelled)(void *);void *cancel_context;};
static pthread_mutex_t data_lock=PTHREAD_MUTEX_INITIALIZER;
static struct RuntimeGameData *installed;
static int installed_external;
static int sha_text(const char *s){return s&&strlen(s)==64&&strspn(s,"0123456789abcdef")==64;}
static int stopped(const struct RuntimeGameData *d){return d->cancelled&&d->cancelled(d->cancel_context);}
static int sha_bytes(const void *p,size_t size,char out[65],int(*cancel)(void *),void *context){
    CC_SHA256_CTX hash;CC_SHA256_Init(&hash);const unsigned char *bytes=p;size_t used=0;
    while(used<size){if(cancel&&cancel(context))return -1;size_t n=size-used;if(n>65536)n=65536;CC_SHA256_Update(&hash,bytes+used,(CC_LONG)n);used+=n;}
    unsigned char digest[32];CC_SHA256_Final(digest,&hash);for(unsigned i=0;i<32;i++)snprintf(out+i*2,3,"%02x",digest[i]);return 0;
}
static int stable(const struct stat *a,const struct stat *b){return a->st_dev==b->st_dev&&a->st_ino==b->st_ino&&a->st_uid==b->st_uid&&a->st_mode==b->st_mode&&a->st_nlink==b->st_nlink&&a->st_size==b->st_size&&a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec&&a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec&&a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;}
static int read_file(int directory,const char *name,uint64_t limit,int(*cancel)(void *),void *context,unsigned char **out,size_t *size){
    int fd=openat(directory,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);if(fd<0)return -1;
    struct stat before,after,named;unsigned char *bytes=NULL;int ok=!fstat(fd,&before)&&S_ISREG(before.st_mode)&&before.st_nlink==1&&before.st_size>0&&(uint64_t)before.st_size<=limit;
    if(ok){bytes=malloc((size_t)before.st_size+1);ok=bytes!=NULL;}
    size_t used=0;
    while(ok&&used<(size_t)before.st_size){if(cancel&&cancel(context)){ok=0;break;}size_t n=(size_t)before.st_size-used;if(n>65536)n=65536;ssize_t got=read(fd,bytes+used,n);if(got<0&&errno==EINTR)continue;if(got<=0){ok=0;break;}used+=(size_t)got;}
    if(ok)ok=!fstat(fd,&after)&&stable(&before,&after)&&!fstatat(directory,name,&named,AT_SYMLINK_NOFOLLOW)&&stable(&after,&named);
    if(close(fd))ok=0;
    if(!ok){free(bytes);return -1;}bytes[used]=0;*out=bytes;*size=used;return 0;
}
static const char *value(const struct Config *c,const char *key){for(size_t i=0;i<c->count;i++)if(!strcmp(c->keys[i],key))return c->values[i];return NULL;}
static int config_parse(struct Config *c,const unsigned char *bytes,size_t size,const struct RuntimeGameData *owner){
    if(memchr(bytes,0,size))return -1;c->text=malloc(size+1);if(!c->text)return -1;memcpy(c->text,bytes,size);c->text[size]=0;
    for(char *line=c->text,*next;*line;line=next){if(stopped(owner))return -1;char *end=strchr(line,'\n');next=end?end+1:line+strlen(line);if(end)*end=0;if(!*line||*line=='#')continue;
        char *space=strchr(line,' ');if(!space||space==line||!space[1]||c->count==32)return -1;*space=0;
        if(strspn(line,"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")!=strlen(line)||value(c,line))return -1;
        for(const unsigned char *p=(const unsigned char *)space+1;*p;p++)if(*p<0x21||*p>0x7e)return -1;
        c->keys[c->count]=line;c->values[c->count++]=space+1;
    }return 0;
}
static int number(const char *s,uint64_t *out){if(!s||!*s||strspn(s,"0123456789")!=strlen(s))return -1;char *end=NULL;errno=0;unsigned long long n=strtoull(s,&end,10);if(errno||!end||*end)return -1;*out=n;return 0;}
static int configs_validate(struct RuntimeGameData *d,const char *romfs,const char *index){
    for(unsigned i=0;i<3;i++)if(config_parse(&d->config[i],d->bytes[i+1],d->sizes[i+1],d))return -1;
    struct Config *r=&d->config[0];uint64_t size;
    if(r->count!=3||number(value(r,"ROMFS_IMAGE_SIZE"),&size)||!size||size>(UINT64_C(64)<<30)||!sha_text(value(r,"ROMFS_IMAGE_SHA256"))||!sha_text(value(r,"ROMFS_INDEX_SHA256")))return -1;
    if((romfs&&strcmp(romfs,value(r,"ROMFS_IMAGE_SHA256")))||(index&&strcmp(index,value(r,"ROMFS_INDEX_SHA256"))))return -1;
    struct Config *f=&d->config[1];if(f->count!=24)return -1;
    for(unsigned i=0;i<6;i++){char key[40];uint64_t file_size,font_size;snprintf(key,sizeof key,"FONT%u_FILE",i);const char *name=value(f,key);
        if(!name||!strcmp(name,".")||!strcmp(name,"..")||strlen(name)>255||strspn(name,"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")!=strlen(name))return -1;
        snprintf(key,sizeof key,"FONT%u_FILE_BYTES",i);if(number(value(f,key),&file_size))return -1;
        snprintf(key,sizeof key,"FONT%u_FONT_BYTES",i);if(number(value(f,key),&font_size)||!font_size||font_size>=(64u<<20)||file_size!=font_size+8||file_size>=(64u<<20))return -1;
        snprintf(key,sizeof key,"FONT%u_SHA256",i);if(!sha_text(value(f,key)))return -1;
    }
    return d->config[2].count==1&&sha_text(value(&d->config[2],"REWRITER_SHA256"))?0:-1;
}
static int range(uint64_t size,uint64_t off,uint64_t count,uint64_t each){return !(off&7)&&off>=64+3*208&&off<=size&&each&&count<=(size-off)/each;}
static int fixed_string(const char *bytes,size_t width,const char *expected){size_t n=strlen(expected);if(n>=width||memcmp(bytes,expected,n))return 0;for(size_t i=n;i<width;i++)if(bytes[i])return 0;return 1;}

static int string_length(const struct RuntimeGameData *d,const char *text,uint64_t available,uint64_t *length){
    uint64_t at=0;
    while(at<available){if(stopped(d))return -1;size_t n=available-at>65536?65536:(size_t)(available-at);const char *end=memchr(text+at,0,n);if(end){*length=(uint64_t)(end-text);return 0;}at+=n;}
    return -1;
}
static int tables_parse(struct RuntimeGameData *d){
    const unsigned char *b=d->bytes[0];uint64_t size=d->sizes[0];if(size<64+3*208)return -1;
    const TablesHeader *h=(const void *)b;if(memcmp(h->magic,"TOTKTAB1",8)||!fixed_string(h->version,8,TOTK_GAME_DIR)||h->format!=1||h->nmodule!=3||h->size!=size||!h->strings_size||!range(size,h->strings,h->strings_size,1)||h->strings_size!=size-h->strings||b[size-1])return -1;
    uint64_t allocated=0,next_string=0,next_array=64+3*208;static const char *const names[3]={"main","subsdk0","sdk"};const char *strings=(const char *)b+h->strings;
    for(unsigned i=0;i<3;i++){
        const TablesModule *t=(const void *)(b+64+i*208);Module *m=&d->modules[i];
        if(stopped(d)||!fixed_string(t->name,16,names[i])||t->reserved||!memchr(t->digest,0,72)||!sha_text(t->digest)||!fixed_string(t->digest,72,t->digest)||!t->nsym||
            !range(size,t->symbols,t->nsym,24)||!range(size,t->relocs,t->nreloc,24)||!range(size,t->gates,t->ngate,24)||
            t->symbols+(uint64_t)t->nsym*24>h->strings||t->relocs+(uint64_t)t->nreloc*24>h->strings||t->gates+(uint64_t)t->ngate*24>h->strings)return -1;
        if(t->symbols!=next_array)return -1;next_array+=(uint64_t)t->nsym*24;
        if(t->relocs!=next_array)return -1;next_array+=(uint64_t)t->nreloc*24;
        if(t->gates!=next_array)return -1;next_array+=(uint64_t)t->ngate*24;
        if(!t->text_end||t->text_end>t->ro_off||t->ro_off>t->data_off||t->data_off>t->key_off||t->file_size>=UINT32_MAX-0x4000u||
            (t->key_off&0x3fff)||(t->patch_off&0x3fff)||t->key_off>t->patch_off||t->patch_off-t->key_off<0x4000||t->patch_off>=t->file_size||
            t->init>=t->text_end||(t->init&3)||t->ctor_flag<t->data_off||t->ctor_flag>t->key_off-4||(t->ctor_flag&3)||
            (t->init_size&7)||t->init_array>t->key_off||t->init_size>t->key_off-t->init_array)return -1;
        *m=(Module){.name=t->name,.digest=t->digest,.file_size=(size_t)t->file_size,.text_end=t->text_end,.ro_off=t->ro_off,.data_off=t->data_off,.patch_off=t->patch_off,.key_off=t->key_off,.init=t->init,.ctor_flag=t->ctor_flag,.init_array=t->init_array,.init_size=t->init_size,.nsym=t->nsym,.nreloc=t->nreloc,.ngate=t->ngate,.relocs=(const Reloc *)(b+t->relocs)};
        uint64_t requested=(uint64_t)t->nsym*sizeof(Symbol)+(uint64_t)t->ngate*sizeof(Gate);
        if(requested>(UINT64_C(256)<<20)-allocated)return -1;allocated+=requested;
        Symbol *symbols=calloc(t->nsym,sizeof *symbols);if(!symbols)return -1;m->symbols=symbols;
        const TablesSymbol *ts=(const void *)(b+t->symbols);
        for(uint32_t k=0;k<t->nsym;k++){
            uint64_t length=0;
            if((!(k&255)&&stopped(d))||ts[k].name!=next_string||ts[k].name>=h->strings_size||string_length(d,strings+ts[k].name,h->strings_size-ts[k].name,&length)||ts[k].defined>1||ts[k].reserved||
                (ts[k].defined&&(ts[k].value>=t->key_off||ts[k].size>t->key_off-ts[k].value)))return -1;
            next_string+=length+1;
            symbols[k]=(Symbol){strings+ts[k].name,ts[k].value,ts[k].size,ts[k].defined,ts[k].binding,ts[k].type};
        }
        for(uint32_t k=0;k<t->nreloc;k++){if(!(k&255)&&stopped(d))return -1;const Reloc *r=&m->relocs[k];if(r->where<t->data_off||r->where>t->key_off-8||r->symbol>=t->nsym||
            (r->kind!=257&&r->kind!=1025&&r->kind!=1026&&r->kind!=1027)||(r->kind==1027&&(r->addend<0||(uint64_t)r->addend>=t->key_off)))return -1;}
        const Gate *g=(const void *)(b+t->gates);m->gates=g;
        for(uint32_t k=0;k<t->ngate;k++)if((!(k&255)&&stopped(d))||g[k].ret>=t->file_size||(g[k].ret&3)||g[k].original>=t->text_end||g[k].timer>1||(g[k].timer&&(g[k].arg>=31||g[k].arg==18)))return -1;
        for(uint32_t k=1;k<t->ngate;k++){if(!(k&255)&&stopped(d))return -1;if(g[k].ret<=g[k-1].ret)return -1;}
    }
    if(next_string!=h->strings_size||next_array!=h->strings)return -1;
    if(h->probe_plt>=d->modules[0].text_end||(h->probe_plt&3)||h->probe_slot<d->modules[0].data_off||h->probe_slot>d->modules[0].key_off-8||(h->probe_slot&7))return -1;
    d->probe_plt=h->probe_plt;d->probe_slot=h->probe_slot;return 0;
}
void runtime_game_data_release(struct RuntimeGameData *d){if(!d)return;pthread_mutex_lock(&data_lock);int live=installed==d;pthread_mutex_unlock(&data_lock);if(live)return;for(unsigned i=0;i<3;i++){free((void *)d->modules[i].symbols);free(d->config[i].text);}for(unsigned i=0;i<4;i++)free(d->bytes[i]);free(d);}
static int exact_directory(int directory){
    int scan=openat(directory,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(scan<0)return 0;
    DIR *stream=fdopendir(scan);if(!stream){close(scan);return 0;}unsigned count=0;int ok=1;struct dirent *entry;errno=0;
    while((entry=readdir(stream))){if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,"..")){errno=0;continue;}
        int known=!strcmp(entry->d_name,"manifest.txt");for(unsigned i=0;i<4;i++)known|=!strcmp(entry->d_name,file_names[i]);
        struct stat st;if(!known||++count>5||fstatat(directory,entry->d_name,&st,AT_SYMLINK_NOFOLLOW)||!S_ISREG(st.st_mode)||st.st_nlink!=1){ok=0;break;}errno=0;
    }if(!entry&&errno)ok=0;if(closedir(stream))ok=0;return ok&&count==5;
}
static int prepare_directory(int directory,const char *manifest_sha,const char *romfs,const char *index,int(*cancel)(void *),void *context,struct RuntimeGameData **out){
    struct RuntimeGameData *d=calloc(1,sizeof *d);if(!d)return -1;d->cancelled=cancel;d->cancel_context=context;
    struct stat before,after;int directoryOK=!fstat(directory,&before)&&S_ISDIR(before.st_mode);
    unsigned char *manifest=NULL;size_t length=0;int ok=directoryOK;uint64_t sizes[4]={0};char pins[4][65]={{0}};
    if(manifest_sha){
        if(!sha_text(manifest_sha)||read_file(directory,"manifest.txt",16384,cancel,context,&manifest,&length))ok=0;
        if(ok){char digest[65];ok=!sha_bytes(manifest,length,digest,cancel,context);ok=ok&&!strcmp(digest,manifest_sha)&&!memchr(manifest,0,length);}
        if(ok){char *cursor=(char *)manifest;const char *magic="CANOPY-GAME-DATA-1\n";size_t n=strlen(magic);ok=length>=n&&!memcmp(cursor,magic,n);if(ok)cursor+=n;
            for(unsigned i=0;ok&&i<4;i++){
                char *end=strchr(cursor,'\n');if(!end){ok=0;break;}*end=0;
                char *first=strchr(cursor,' '),*second=first?strchr(first+1,' '):NULL;
                if(!first||!second||first==cursor||second==first+1){ok=0;break;}
                *first=0;*second=0;const char *digest=second+1;uint64_t size=0;
                ok=!strcmp(cursor,file_names[i])&&!strchr(digest,' ')&&sha_text(digest)&&!number(first+1,&size)&&size&&size<=file_limits[i];
                if(ok){sizes[i]=size;memcpy(pins[i],digest,65);}cursor=end+1;
            }
            if(ok)ok=cursor==(char *)manifest+length;
        }
    }
    for(unsigned i=0;ok&&i<4;i++){
        ok=!read_file(directory,file_names[i],file_limits[i],cancel,context,&d->bytes[i],&d->sizes[i]);
        if(ok&&manifest_sha){char digest[65];ok=!sha_bytes(d->bytes[i],d->sizes[i],digest,cancel,context);ok=ok&&d->sizes[i]==sizes[i]&&!strcmp(digest,pins[i]);}
    }
    if(ok&&manifest_sha)ok=exact_directory(directory);
    if(ok)ok=!fstat(directory,&after)&&stable(&before,&after);
    free(manifest);if(ok)ok=!configs_validate(d,romfs,index)&&!tables_parse(d);
    if(cancel&&cancel(context))ok=0;
    if(!ok){runtime_game_data_release(d);return -1;}d->cancelled=NULL;d->cancel_context=NULL;*out=d;return 0;
}
int runtime_game_data_prepare_fd(int resources,const char *manifest_sha,const char *romfs,const char *index,int(*cancel)(void *),void *context,struct RuntimeGameData **out){
    if(resources<0||!out||!sha_text(manifest_sha)||!sha_text(romfs)||!sha_text(index))return -1;
    int directory=openat(resources,"runtime-data",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(directory<0)return -1;
    int rc=prepare_directory(directory,manifest_sha,romfs,index,cancel,context,out);close(directory);return rc;
}
int runtime_game_data_install(struct RuntimeGameData *d){if(!d)return -1;pthread_mutex_lock(&data_lock);int rc=installed?-1:0;if(!rc){installed=d;installed_external=1;}pthread_mutex_unlock(&data_lock);return rc;}
int runtime_game_data_is_installed(void){pthread_mutex_lock(&data_lock);int yes=installed_external&&installed;pthread_mutex_unlock(&data_lock);return yes;}
void runtime_game_data_path(const char *name,char *out,size_t capacity){const char *dir=getenv("TOTK_GAME_DATA");int n=dir&&*dir?snprintf(out,capacity,"%s/%s",dir,name):snprintf(out,capacity,"build/game-data/" TOTK_GAME_DIR "/%s",name);if(n<=0||(size_t)n>=capacity)runtime_fail("game data path too long");}
static struct RuntimeGameData *current(void){
    pthread_mutex_lock(&data_lock);struct RuntimeGameData *d=installed;pthread_mutex_unlock(&data_lock);if(d)return d;
#if defined(CANOPY_GAME_DATA_RESOURCES)
    runtime_fail("verified game data was not installed");
#else
    char path[4096];runtime_game_data_path("",path,sizeof path);int fd=open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)runtime_fail("game data missing");
    if(prepare_directory(fd,NULL,NULL,NULL,NULL,NULL,&d)){close(fd);runtime_fail("game data invalid");}close(fd);
    pthread_mutex_lock(&data_lock);if(!installed)installed=d;else{struct RuntimeGameData *unused=d;d=installed;pthread_mutex_unlock(&data_lock);runtime_game_data_release(unused);return d;}pthread_mutex_unlock(&data_lock);return d;
#endif
}
void runtime_game_data_modules(Module out[3],uint64_t *plt,uint64_t *slot){struct RuntimeGameData *d=current();memcpy(out,d->modules,sizeof d->modules);*plt=d->probe_plt;*slot=d->probe_slot;}
const char *runtime_game_text(const char *file,const char *key){struct RuntimeGameData *d=current();for(unsigned i=0;i<3;i++)if(!strcmp(file,file_names[i+1])){const char *s=value(&d->config[i],key);if(s)return s;break;}runtime_fail("game data value missing");}
uint64_t runtime_game_number(const char *file,const char *key){uint64_t n;if(number(runtime_game_text(file,key),&n))runtime_fail("game data number invalid");return n;}
const char *runtime_game_sha256(const char *file,const char *key){const char *s=runtime_game_text(file,key);if(!sha_text(s))runtime_fail("game data SHA256 invalid");return s;}
