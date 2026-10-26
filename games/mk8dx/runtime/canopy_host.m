/* Original single-use native host. Generated pins are private build output;
 * this file contains no original/rewritten game instructions or libraries. */
#import "canopy_mk8dx.h"
#include "mk8dx_pins.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
extern int nxnative_host_main(int,char **);
static pthread_mutex_t lifeLock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t lifeChanged=PTHREAD_COND_INITIALIZER;
static struct mng_apple_lifecycle life={MNG_APPLE_HOST_ABI,sizeof(life),MNG_APPLE_NOT_STARTED,0,0,0,0,0};
static pthread_t worker;
static int claimed,created,launchFailed,returned,result;
static MKPrepared *live;
static void cleanup(void *unused){(void)unused;MKFrontendTerminal();pthread_mutex_lock(&lifeLock);life.main_returned=returned;life.main_return_code=returned?result:0;if(!life.provider_error)life.phase=MNG_APPLE_CLEANUP_OBSERVED;pthread_cond_broadcast(&lifeChanged);pthread_mutex_unlock(&lifeLock);}
static void *run(void *unused){(void)unused;pthread_mutex_lock(&lifeLock);MKPrepared *p=live;pthread_mutex_unlock(&lifeLock);pthread_cleanup_push(cleanup,NULL);
    char *args[]={"Canopy-MK8DX",(char *)p.modules.fileSystemRepresentation,"main","subsdk0","sdk",NULL};int rc=nxnative_host_main(5,args);
    pthread_mutex_lock(&lifeLock);returned=1;result=rc;pthread_mutex_unlock(&lifeLock);pthread_cleanup_pop(1);return NULL;}
static void *observe(void *unused){(void)unused;pthread_mutex_lock(&lifeLock);while(!created&&!launchFailed)pthread_cond_wait(&lifeChanged,&lifeLock);int join=created;pthread_t th=worker;pthread_mutex_unlock(&lifeLock);if(join){int rc=pthread_join(th,NULL);pthread_mutex_lock(&lifeLock);life.main_joined=rc?0:1;life.join_error=rc;if(!life.provider_error)life.phase=rc?MNG_APPLE_OBSERVATION_FAILED:MNG_APPLE_JOINED;pthread_cond_broadcast(&lifeChanged);pthread_mutex_unlock(&lifeLock);}return NULL;}
static _Noreturn void fail_provider(enum mng_apple_provider_error error){
    MKFrontendTerminal();pthread_mutex_lock(&lifeLock);
    life.phase=MNG_APPLE_PROVIDER_FAILED;
    if(life.provider_error==MNG_APPLE_PROVIDER_NONE)life.provider_error=error;
    pthread_mutex_unlock(&lifeLock);pthread_exit(NULL);
}
_Noreturn void MKUnsupportedService(void){fail_provider(MNG_APPLE_PROVIDER_UNIMPLEMENTED_SERVICE);}
_Noreturn void MKControllerUnavailable(void){fail_provider(MNG_APPLE_PROVIDER_CONTROLLER_UNAVAILABLE);}

void MKGuestEntry(void (*guest)(void)){if(!guest)return;MKFrontendGuestReady();guest();}
int MKReadLifecycle(struct mng_apple_lifecycle *out){NSCAssert(NSThread.isMainThread,@"Lifecycle query belongs on main");if(!out||out->abi!=MNG_APPLE_HOST_ABI||out->size!=sizeof(*out))return -1;pthread_mutex_lock(&lifeLock);*out=life;pthread_mutex_unlock(&lifeLock);return 0;}
static int envpath(const char *key,NSString *path){return !path.isAbsolutePath||strlen(path.fileSystemRepresentation)>=1024?-1:setenv(key,path.fileSystemRepresentation,1);}
int MKStart(const struct mng_apple_start *s){NSCAssert(NSThread.isMainThread,@"Native start belongs on main");if(!s||s->abi!=MNG_APPLE_HOST_ABI||s->size!=sizeof(*s))return -1;MKPrepared *p=MKPreparedObject(s->prepared);if(!p)return -1;
    pthread_mutex_lock(&lifeLock);if(claimed){pthread_mutex_unlock(&lifeLock);return -1;}claimed=1;live=p;pthread_mutex_unlock(&lifeLock);
    // The host profile is compiled; no imported/env profile or native-code path
    // can override it. No diagnostic input/translator/alternate root is inherited.
    // This single-use process has not initialized the original host yet.
    // Remove every inherited original-host switch, including diagnostic paths,
    // compiler modes and provisional profile selectors, before any reader runs.
    extern char **environ;NSMutableArray<NSString *> *clear=[NSMutableArray new];
    for(char **entry=environ;entry&&*entry;entry++){const char *end=strchr(*entry,'=');if(end&&end-*entry>3&&!strncmp(*entry,"DM_",3)){NSString *key=[[NSString alloc] initWithBytes:*entry length:(NSUInteger)(end-*entry) encoding:NSUTF8StringEncoding];if(!key)return -1;[clear addObject:key];}}
    for(NSString *key in clear)if(unsetenv(key.UTF8String))return -1;
    if(envpath("DM_ROMFS",p.romfs)||envpath("DM_SAVE",[p.active stringByAppendingPathComponent:@"guest-user"])||
       envpath("DM_TEMP",[p.runtime stringByAppendingPathComponent:@"temp"])||envpath("DM_ROOT",p.runtime)||envpath("DM_MSL_DIR",p.seed)||
       envpath("DM_NVN_SHMAP",[p.seed stringByAppendingPathComponent:@"shader_map.tsv"])||setenv("DM_LANG",p.language.UTF8String,1)||
       setenv("DM_OPMODE","1",1)||setenv("DM_WINDOW","0",1)||chdir(p.runtime.fileSystemRepresentation)||MKAttach(s))return -1;
    pthread_attr_t a,o;if(pthread_attr_init(&a))return -1;if(pthread_attr_setstacksize(&a,64u<<20)){pthread_attr_destroy(&a);return -1;}
    if(pthread_attr_init(&o)){pthread_attr_destroy(&a);return -1;}if(pthread_attr_setdetachstate(&o,PTHREAD_CREATE_DETACHED)){pthread_attr_destroy(&o);pthread_attr_destroy(&a);return -1;}
    pthread_mutex_lock(&lifeLock);pthread_t watcher;int rc=pthread_create(&watcher,&o,observe,NULL);
    if(!rc){rc=pthread_create(&worker,&a,run,NULL);if(!rc){created=1;life.phase=MNG_APPLE_RUNNING;}else launchFailed=1;pthread_cond_broadcast(&lifeChanged);}
    pthread_mutex_unlock(&lifeLock);pthread_attr_destroy(&o);pthread_attr_destroy(&a);return rc?-1:0;}
const struct mng_apple_host *canopy_mk8dx_host_v1(void){
    static const struct mng_apple_host host={MNG_APPLE_HOST_ABI,sizeof(host),UINT64_C(0x0100152000022000),MK_ROMFS_SIZE,1441792,4,3,
        "4.0.0",MK_ROMFS_SHA256,MK_SOURCE_RECIPE_SHA256,MK_SHADER_MANIFEST_SHA256,MK_SHADER_CHAIN,MK_NATIVE_MANIFEST_SHA256,NULL,
        {{"main",MK_MAIN_SHA256,"2c336a9bcf79c3040ce506cdd391b578"},{"subsdk0",MK_SUBSDK0_SHA256,"d9de423efc1512328c3c05378c7cb031"},{"sdk",MK_SDK_SHA256,"ba520906609c503227871a314a94fb5f"}},
        MKPrepare,MKReleasePrepared,MKStart,MKReadLifecycle,MKClearInput,MKSetFocus,MKSubmit,MKUpdateLayout};return &host;}
