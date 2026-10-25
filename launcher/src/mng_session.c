#define _POSIX_C_SOURCE 200809L
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#include "mng_session.h"
#include "mng_crypto.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif
struct mng_session {
    void *library, *instance;
    const struct mng_native_module *module;
    struct mng_native_start start;
    uint64_t sequence, input_time;
    int paused, retained;
    char root[4096], saves[4096], profile[65];
};
static int text_ok(const char *s, size_t cap) { return s && strnlen(s,cap)>0 && strnlen(s,cap)<cap; }
static int settings_ok(const struct mng_session_settings *s) {
    return s && s->size==sizeof(*s) && s->output_width>=320 && s->output_width<=16384 &&
        s->output_height>=240 && s->output_height<=16384 && s->frame_limit>=1 && s->frame_limit<=240 &&
        s->language<=31 && s->controller_layout<=7 && isfinite(s->volume) && s->volume>=0 && s->volume<=1;
}
/* Traverse every component without following links. Root must be absolute. */
static int path_fd(const char *path, int final_flags) {
    char copy[4096], *p, *next;
    int fd, child;
    if(!text_ok(path,sizeof(copy)) || path[0]!='/') return -1;
    strcpy(copy,path); fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    p=copy+1;
    while(fd>=0 && *p) {
        next=strchr(p,'/'); if(next) *next=0;
        if(!*p || !strcmp(p,".") || !strcmp(p,"..")) {close(fd);return -1;}
        child=openat(fd,p,(next?O_RDONLY|O_DIRECTORY:final_flags)|O_NOFOLLOW|O_CLOEXEC);
        close(fd); fd=child;
        if(!next) break;
        p=next+1; if(!*p) {close(fd);return -1;}
    }
    return fd;
}
/* Snapshot to a fresh 0700 directory: hash exactly the bytes subsequently
 * passed to dlopen, immune to concurrent replacement of the source path. */
static int snapshot(const struct mng_session_manifest *m, char dir[64], char image[96]) {
    char source[4096]; unsigned char buf[65536], digest[32];
    struct stat st; struct mng_sha256 *sha=NULL;
    int in=-1,out=-1,result=-1; uint64_t total=0;
    if(snprintf(source,sizeof(source),"%s/%s",m->prepared_root,m->module_relative_path)>=(int)sizeof(source)) return -1;
    in=path_fd(source,O_RDONLY|O_NONBLOCK);
    if(in<0 || fstat(in,&st) || !S_ISREG(st.st_mode) || st.st_size<1 || (uint64_t)st.st_size!=m->module_size) goto done;
    strcpy(dir,"/tmp/canopy-native-XXXXXX"); if(!mkdtemp(dir)) {dir[0]=0;goto done;}
    snprintf(image,96,"%s/module",dir);
    out=open(image,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0500);
    if(out<0 || mng_sha256_init(&sha)) goto done;
    while(total<m->module_size) {
        size_t want=(size_t)((m->module_size-total)<sizeof(buf)?m->module_size-total:sizeof(buf));
        ssize_t n=read(in,buf,want); size_t written=0;
        if(n<=0 || mng_sha256_update(sha,buf,(size_t)n)) goto done;
        while(written<(size_t)n) {ssize_t w=write(out,buf+written,(size_t)n-written);if(w<=0)goto done;written+=(size_t)w;}
        total+=(uint64_t)n;
    }
    if(read(in,buf,1)!=0 || mng_sha256_final(sha,digest) || memcmp(digest,m->module_sha256,32) || fsync(out)) goto done;
    result=0;
 done:
    if(in>=0)close(in);
    if(out>=0)close(out);
    mng_sha256_free(sha);
    return result;
}
int mng_session_open(const struct mng_session_manifest *m, const struct mng_session_host *h,
                    const struct mng_session_settings *settings, struct mng_session **out) {
    struct mng_session *s; char dir[64]={0},image[96]={0};
    mng_native_entry_fn entry; void *symbol; int result=MNG_SESSION_UNVERIFIED, fd;
    if(out) *out=NULL;
    if(!out || !m || m->version!=1 || !h || h->size!=sizeof(*h) || !h->monotonic_ns || !h->retain_prepared || !h->release_prepared || !settings_ok(settings) ||
       !text_ok(m->prepared_root,4096) || !text_ok(m->save_root,4096) || !text_ok(m->profile_id,65) ||
       !text_ok(m->module_relative_path,1024) || m->module_relative_path[0]=='/' || !m->title_id ||
       !m->module_size || m->module_size>512u*1024u*1024u) return MNG_SESSION_INVALID;
    for(const char *p=m->profile_id;*p;p++) if(!((*p>='a'&&*p<='z')||(*p>='A'&&*p<='Z')||(*p>='0'&&*p<='9')||*p=='-'||*p=='_')) return MNG_SESSION_INVALID;
    if(m->execution_capability!=MNG_NATIVE_EXECUTION_APPROVED) return MNG_SESSION_UNSUPPORTED;
#if defined(__APPLE__) && TARGET_OS_IPHONE
    /* No external executable capability is established for the public app. */
    return MNG_SESSION_UNSUPPORTED;
#endif
    fd=path_fd(m->save_root,O_RDONLY|O_DIRECTORY); if(fd<0)return MNG_SESSION_INVALID; close(fd);
    s=calloc(1,sizeof(*s));if(!s)return MNG_SESSION_LOAD_FAILED;
    strcpy(s->root,m->prepared_root);strcpy(s->saves,m->save_root);strcpy(s->profile,m->profile_id);
    s->start.host=*h;
    if(h->retain_prepared(h->context,s->root))goto done;
    s->retained=1;
    if(snapshot(m,dir,image)) goto done;
    s->library=dlopen(image,RTLD_NOW|RTLD_LOCAL); if(!s->library){result=MNG_SESSION_LOAD_FAILED;goto done;}
    symbol=dlsym(s->library,"canopy_native_module_v1");
    if(!symbol){result=MNG_SESSION_ABI_MISMATCH;goto done;}
    /* POSIX guarantees dlsym conversion; memcpy avoids ISO C pedantic casts. */
    _Static_assert(sizeof(entry)==sizeof(symbol),"POSIX function pointer size");
    memcpy(&entry,&symbol,sizeof(entry));s->module=entry();
    if(!s->module || s->module->abi_version!=MNG_NATIVE_ABI_V1 || s->module->size!=sizeof(*s->module) ||
       s->module->title_id!=m->title_id || s->module->title_version!=m->title_version ||
       !s->module->create || !s->module->settings || !s->module->input || !s->module->pause || !s->module->tick || !s->module->destroy) {
        result=MNG_SESSION_ABI_MISMATCH;goto done;
    }
    s->start=(struct mng_native_start){sizeof(s->start),m->title_id,m->title_version,s->root,s->saves,s->profile,*settings,*h};
    if(s->module->create(&s->start,&s->instance) || !s->instance) {result=MNG_SESSION_BACKEND_FAILED;goto done;}
    *out=s;result=0;
 done:
    if(image[0])unlink(image);
    if(dir[0])rmdir(dir);
    if(result){if(s->library)dlclose(s->library);if(s->retained)h->release_prepared(h->context,s->root);free(s);}
    return result;
}
int mng_session_update_settings(struct mng_session *s,const struct mng_session_settings *v) {
    if(!s || !settings_ok(v))return MNG_SESSION_INVALID;
    if(s->module->settings(s->instance,v))return MNG_SESSION_BACKEND_FAILED;
    s->start.settings=*v;return 0;
}
int mng_session_submit_input(struct mng_session *s,const struct mng_session_input *v) {
    uint64_t now;
    if(!s || !v)return MNG_SESSION_INVALID;
    now=s->start.host.monotonic_ns(s->start.host.context);
    if(!v->sequence || !v->timestamp_ns || v->sequence<=s->sequence || v->timestamp_ns<s->input_time || v->timestamp_ns>now || now-v->timestamp_ns>250000000) return MNG_SESSION_STALE_INPUT;
    for(unsigned i=0;i<MNG_SESSION_PLAYERS;i++) {
        const struct mng_player_input *p=&v->players[i];
        const float axes[]={p->left_x,p->left_y,p->right_x,p->right_y};
        if(p->connected>1 || (p->connected && !p->device_id) || (!p->connected && (p->buttons || p->left_x || p->left_y || p->right_x || p->right_y)))return MNG_SESSION_INVALID;
        for(unsigned a=0;a<4;a++)if(!isfinite(axes[a]) || axes[a]<-1 || axes[a]>1)return MNG_SESSION_INVALID;
        for(unsigned j=0;j<i;j++)if(p->connected && v->players[j].connected && p->device_id==v->players[j].device_id)return MNG_SESSION_INVALID;
    }
    if(s->paused)return MNG_SESSION_INVALID;
    if(s->module->input(s->instance,v))return MNG_SESSION_BACKEND_FAILED;
    s->sequence=v->sequence;s->input_time=v->timestamp_ns;return 0;
}
int mng_session_pause(struct mng_session *s,int paused) {
    struct mng_session_input neutral={0};
    if(!s || (paused!=0 && paused!=1))return MNG_SESSION_INVALID;
    if(s->paused==paused)return 0;
    if(paused && s->module->input(s->instance,&neutral))return MNG_SESSION_BACKEND_FAILED;
    if(s->module->pause(s->instance,paused))return MNG_SESSION_BACKEND_FAILED;
    s->paused=paused;return 0;
}
int mng_session_tick(struct mng_session *s) {
    if(!s || s->paused)return MNG_SESSION_INVALID;
    return s->module->tick(s->instance,s->start.host.monotonic_ns(s->start.host.context))?MNG_SESSION_BACKEND_FAILED:0;
}
void mng_session_close(struct mng_session *s) {
    if(!s)return;
    s->module->destroy(s->instance);dlclose(s->library);
    s->start.host.release_prepared(s->start.host.context,s->root);free(s);
}
