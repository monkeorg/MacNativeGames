/* Opt-in private host only; existing Mac/TOTK targets retain their own main. */
#if defined(CANOPY_HOST_RUNTIME)
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#include "canopy_host.h"
#include "canopy_metal_device.h"
#include "language.h"
#include <stdlib.h>
#include <stdatomic.h>
static _Atomic int display_patches_validated;
void canopy_host_game_patches_validated(void) { atomic_store_explicit(&display_patches_validated,1,memory_order_release); }
static __strong id<MTLDevice> retained_renderer_device;
int canopy_host_bind_metal_device(id<MTLDevice> device) {
    NSCAssert(NSThread.isMainThread,@"Metal device binding belongs on main thread");
    if(!device)return -1;
    if(retained_renderer_device)return retained_renderer_device==device?0:-1;
    retained_renderer_device=device;return 0;
}
id<MTLDevice> runtime_canopy_metal_device(void) {return retained_renderer_device;}
int canopy_host_pin_compile_environment(void) {
    const char *experiments[]={"TOTK_FAST_MATH","TOTK_SHADER_XLATE","TOTK_SHADER_SERVICE","TOTK_SHADER_DEBUGMODE",
        "TOTK_MFX","TOTK_MFX_UPSCALE","TOTK_MFX_OUTPUT","TOTK_ANISO","DM_NVN_NOFXAA",NULL};
    for(unsigned i=0;experiments[i];i++)if(unsetenv(experiments[i]))return -1;
    return 0;
}
static struct mng_display_config configured_display;
static int display_configured;
int canopy_host_read_display_state(struct mng_display_state *out) {
    NSCAssert(NSThread.isMainThread,@"Display state belongs on main thread");
    if(!out||out->abi!=MNG_DISPLAY_ABI||out->size!=sizeof(*out))return -1;
    struct mng_display_state state={MNG_DISPLAY_ABI,sizeof(state),MNG_DISPLAY_NOT_CONFIGURED,{0}};
    if(display_configured){state.config=configured_display;state.validation=atomic_load_explicit(&display_patches_validated,memory_order_acquire)?
        MNG_DISPLAY_PATCHES_VALIDATED:MNG_DISPLAY_PENDING;}
    *out=state;return 0;
}
#if TARGET_OS_IPHONE || defined(CANOPY_WORKER_NATIVE_PROBE)
#include "thread_compat.h"
#include <errno.h>
#include <limits.h>
/* One process-owned main worker and one process-lifetime observer. The latter
 * deliberately stays parked after joining: this is observation, not ownership
 * of every runtime helper and never evidence that the process can relaunch. */
static pthread_mutex_t lifecycle_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t lifecycle_changed=PTHREAD_COND_INITIALIZER;
static struct canopy_totk_lifecycle_state lifecycle_state={
    CANOPY_TOTK_LIFECYCLE_ABI,sizeof(struct canopy_totk_lifecycle_state),CANOPY_TOTK_MAIN_NOT_STARTED,0,0,0,0,0,0,0,0};
static pthread_t main_worker;
static int worker_claimed,worker_created,worker_launch_failed,main_did_return,main_result;
static int (*main_entry)(void *);
static void *main_argument;
static _Atomic int worker_running;
static void main_worker_cleanup(void *unused) {
    (void)unused;
    /* This boundary is reached only by a real return or pthread_exit on the
     * main worker. It requests no guest exit and retains all child ownership. */
    runtime_canopy_threads_close_admission();
    pthread_mutex_lock(&lifecycle_lock);
    lifecycle_state.main_returned=(uint32_t)main_did_return;
    lifecycle_state.main_return_code=main_did_return?main_result:0;
    if(lifecycle_state.phase!=CANOPY_TOTK_MAIN_OBSERVATION_FAILED)
        lifecycle_state.phase=CANOPY_TOTK_MAIN_CLEANUP_OBSERVED;
    atomic_store_explicit(&worker_running,0,memory_order_release);
    pthread_cond_broadcast(&lifecycle_changed);
    pthread_mutex_unlock(&lifecycle_lock);
}
static void *main_worker_entry(void *unused) {
    (void)unused;
    /* start holds this lock across create/publication. A fast worker therefore
     * cannot have cleanup/JOINED overwritten by a later RUNNING publication. */
    pthread_mutex_lock(&lifecycle_lock);
    int (*entry)(void *)=main_entry;void *argument=main_argument;
    pthread_mutex_unlock(&lifecycle_lock);
    pthread_cleanup_push(main_worker_cleanup,NULL);
    int result=entry(argument);
    pthread_mutex_lock(&lifecycle_lock);
    main_did_return=1;main_result=result;
    pthread_mutex_unlock(&lifecycle_lock);
    pthread_cleanup_pop(1);
    return NULL;
}
static void *main_worker_observer(void *unused) {
    (void)unused;
    pthread_mutex_lock(&lifecycle_lock);
    while(!worker_created && !worker_launch_failed)pthread_cond_wait(&lifecycle_changed,&lifecycle_lock);
    int created=worker_created;pthread_t worker=main_worker;
    pthread_mutex_unlock(&lifecycle_lock);
    if(created) {
        int result=pthread_join(worker,NULL); /* Includes all actual TLS destructors. */
        pthread_mutex_lock(&lifecycle_lock);
        if(result) {lifecycle_state.phase=CANOPY_TOTK_MAIN_OBSERVATION_FAILED;lifecycle_state.join_error=(uint32_t)result;}
        else {lifecycle_state.phase=CANOPY_TOTK_MAIN_JOINED;lifecycle_state.main_joined=1;}
        pthread_cond_broadcast(&lifecycle_changed);
        pthread_mutex_unlock(&lifecycle_lock);
    }
    pthread_mutex_lock(&lifecycle_lock);
    for(;;)pthread_cond_wait(&lifecycle_changed,&lifecycle_lock);
    return NULL;
}
/* Actual private start_host and the original-source native probe use exactly
 * this component. Caller owns entry/context for the single process lifetime. */
static int launch_main_worker(int (*entry)(void *),void *argument,size_t stack_size) {
    if(!entry || stack_size<(size_t)PTHREAD_STACK_MIN)return -1;
    pthread_attr_t worker_attributes,observer_attributes;
    if(pthread_attr_init(&worker_attributes))return -1;
    if(pthread_attr_setstacksize(&worker_attributes,stack_size)) {pthread_attr_destroy(&worker_attributes);return -1;}
    if(pthread_attr_init(&observer_attributes)) {pthread_attr_destroy(&worker_attributes);return -1;}
    if(pthread_attr_setdetachstate(&observer_attributes,PTHREAD_CREATE_DETACHED)) {
        pthread_attr_destroy(&observer_attributes);pthread_attr_destroy(&worker_attributes);return -1;
    }
    pthread_mutex_lock(&lifecycle_lock);
    if(worker_claimed) {
        pthread_mutex_unlock(&lifecycle_lock);pthread_attr_destroy(&observer_attributes);pthread_attr_destroy(&worker_attributes);return -1;
    }
    worker_claimed=1;main_entry=entry;main_argument=argument;
    pthread_t observer;
    int result=pthread_create(&observer,&observer_attributes,main_worker_observer,NULL);
    if(!result) {
        result=pthread_create(&main_worker,&worker_attributes,main_worker_entry,NULL);
        if(!result) {
            worker_created=1;lifecycle_state.phase=CANOPY_TOTK_MAIN_RUNNING;
            atomic_store_explicit(&worker_running,1,memory_order_release);
        } else worker_launch_failed=1;
        pthread_cond_broadcast(&lifecycle_changed);
    }
    pthread_mutex_unlock(&lifecycle_lock);
    pthread_attr_destroy(&observer_attributes);pthread_attr_destroy(&worker_attributes);
    return result?-1:0;
}
int canopy_host_read_lifecycle_state(struct canopy_totk_lifecycle_state *out) {
    NSCAssert(NSThread.isMainThread,@"Lifecycle observation belongs on main thread");
    if(!out || out->abi!=CANOPY_TOTK_LIFECYCLE_ABI || out->size!=sizeof(*out))return -1;
    pthread_mutex_lock(&lifecycle_lock);struct canopy_totk_lifecycle_state state=lifecycle_state;
    pthread_mutex_unlock(&lifecycle_lock);
    struct canopy_threads_state children={CANOPY_THREADS_ABI,sizeof(children),0,0,0,0,0};
    if(runtime_canopy_threads_snapshot(&children))return -1;
    state.owned_guest_children=children.owned_children;state.joining_guest_children=children.joining_children;
    state.guest_join_failures=children.join_failures;state.guest_admission_closed=children.admission_closed;
    *out=state;return 0;
}
#endif
#if TARGET_OS_IPHONE
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#include "runtime.h"
#include "game_version.h"
#include "romfs_config.h"
#include "dmsh_chain.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifndef CANOPY_HOST_TITLE_ID
#define CANOPY_HOST_TITLE_ID UINT64_C(0)
#endif
#ifndef CANOPY_HOST_ORIGINAL_MAIN_SHA256
#define CANOPY_HOST_ORIGINAL_MAIN_SHA256 ""
#endif
#ifndef CANOPY_HOST_SHADER_SEED_MANIFEST_SHA256
#define CANOPY_HOST_SHADER_SEED_MANIFEST_SHA256 ""
#endif
#ifndef CANOPY_HOST_DISPLAY_HEAP_SHA256
#define CANOPY_HOST_DISPLAY_HEAP_SHA256 ""
#endif
#ifndef CANOPY_HOST_DISPLAY_LAYOUT_SHA256
#define CANOPY_HOST_DISPLAY_LAYOUT_SHA256 ""
#endif
#if defined(TOTK_IOS_DISPLAY_SETTINGS) && !defined(TOTK_GAME_V143)
#error Canopy display profile requires existing checked TOTK1.4.3 patches
#endif
#if defined(TOTK_GAME_V143) && defined(TOTK_IOS_DISPLAY_SETTINGS)
#ifdef TOTK_IOS_ASPECT_VERT
#define CANOPY_DISPLAY_FLAGS (MNG_DISPLAY_SCENE_1080|MNG_DISPLAY_FOUR_THREE)
#else
#define CANOPY_DISPLAY_FLAGS MNG_DISPLAY_SCENE_1080
#endif
#else
#define CANOPY_DISPLAY_FLAGS 0u
#endif
static int display_hash_valid(const char *hash) {
    if(strlen(hash)!=64)return 0;
    for(unsigned i=0;i<64;i++)if(!((hash[i]>='0'&&hash[i]<='9')||(hash[i]>='a'&&hash[i]<='f')))return 0;
    return 1;
}
extern int totk_host_main(int,char **);
extern void runtime_ios_attach_layer(CAMetalLayer *,UIView *);
extern void runtime_ios_set_host_active(int);
static _Atomic int started;
static BOOL audio_interrupted;
static char *module_path,*verified_seed_path;
int runtime_canopy_shader_seed_verified(const char *path) {
    return path && verified_seed_path && !strcmp(path,verified_seed_path);
}
static int run_host(void *unused) {
    (void)unused;char *argv[]={"Canopy",module_path,"boot",NULL};
    return totk_host_main(3,argv); /* Normally never returns; observation is not teardown. */
}
static int put_path(const char *key,const char *root,const char *leaf) {
    char path[4096];
    if(!root || root[0]!='/' || snprintf(path,sizeof(path),"%s%s%s",root,leaf?"/":"",leaf?leaf:"")>=(int)sizeof(path))return -1;
    return setenv(key,path,1);
}
static int configure_display(const struct canopy_totk_start *s) {
    const struct mng_display_profile profile={MNG_DISPLAY_ABI,sizeof(profile),CANOPY_DISPLAY_FLAGS};
    UIView *view=(__bridge UIView *)s->host_view;
    if(mng_display_check(&profile,&s->display,view.bounds.size.width,view.bounds.size.height))return -1;
    char dimensions[32],height[16];
    if(snprintf(dimensions,sizeof(dimensions),"%ux%u",s->display.width,s->display.height)>=(int)sizeof(dimensions)||
        snprintf(height,sizeof(height),"%u",s->display.height)>=(int)sizeof(height))return -1;
    if(setenv("TOTK_RENDER_RES",dimensions,1)||setenv("TOTK_OUTPUT_RES",CANOPY_DISPLAY_FLAGS?dimensions:"0",1)||
        setenv("TOTK_ASPECT",s->display.aspect==MNG_DISPLAY_FULL?"display":"0",1)||setenv("TOTK_IOS_DRAWABLE_H",height,1))return -1;
    if(CANOPY_DISPLAY_FLAGS){if(setenv("TOTK_FIXED_RES","1",1))return -1;}
    else if(unsetenv("TOTK_FIXED_RES"))return -1;
    // These are compiled checked stubs; inherited experiment settings never
    // replace the selected projection or imply a resource capability.
    if(unsetenv("TOTK_ASPECT_VERT")||unsetenv("TOTK_IOS_DISPLAY_SETTINGS")||unsetenv("TOTK_IOS_ASPECT_VERT")||unsetenv("TOTK_STRETCH"))return -1;
    if(s->display.aspect==MNG_DISPLAY_FULL){
        if(put_path("TOTK_ROMFS_PATCHES",s->resources,"romfs-patches-4x3")||setenv("TOTK_UI_SQUEEZE","0",1))return -1;
    }else if(unsetenv("TOTK_UI_SQUEEZE"))return -1;
    configured_display=s->display;atomic_store_explicit(&display_patches_validated,0,memory_order_release);display_configured=1;return 0;
}
static void clear_input(void) {runtime_input_clear();runtime_touch_pad_clear();runtime_mouse_release();}
static void input(uint64_t b,int32_t lx,int32_t ly,int32_t rx,int32_t ry,int connected) {
    if(!connected){runtime_touch_pad_clear();return;} /* Drop queued press edges too. */
    RuntimeGamepadState pad={b,lx,ly,rx,ry,connected};runtime_touch_pad_set(&pad);
}
/* Original standalone iOS main provides this desktop-only shortcut symbol.
 * The dedicated Canopy overlay is owned by its UI controller instead. */
void runtime_shortcut_help_toggle(void) {}
static void audio_resume(int recreate) {
    if(!atomic_load(&worker_running))return;
    if([AVAudioSession.sharedInstance setActive:YES error:NULL]) {
        audio_interrupted=NO;runtime_audio_output_restart(recreate);
    }
}
static void observe_audio(void) {
    NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
    NSOperationQueue *main=NSOperationQueue.mainQueue;
    [center addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:main usingBlock:^(NSNotification *n) {
        if([n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue]==AVAudioSessionInterruptionTypeBegan)audio_interrupted=YES;
        else audio_resume(0);
    }];
    [center addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil queue:main usingBlock:^(NSNotification *n) {
        (void)n;audio_resume(1);
    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:main usingBlock:^(NSNotification *n) {
        (void)n;UIApplication.sharedApplication.idleTimerDisabled=YES;
        if(audio_interrupted)audio_resume(0);
        /* Audio recovery never restores overlay/controller focus. */
    }];
}
static int start_host(const struct canopy_totk_start *s) {
    NSCAssert(NSThread.isMainThread,@"Private host starts on main thread");
    if(canopy_host_pin_compile_environment())return -1;
    if(!s || !s->metal_layer || !s->host_view || !s->metal_device || !s->modules || !s->language ||
       (s->taa_enabled && !runtime_ios_taa_supported()) || !runtime_ios_fps_limit_supported(s->fps_limit))return -1;
    CAMetalLayer *selected_layer=(__bridge CAMetalLayer *)s->metal_layer;
    id<MTLDevice> selected_device=(__bridge id<MTLDevice>)s->metal_device;
    const struct mng_display_profile display_profile={MNG_DISPLAY_ABI,sizeof(display_profile),CANOPY_DISPLAY_FLAGS};
    UIView *selected_view=(__bridge UIView *)s->host_view;
    if(mng_display_check(&display_profile,&s->display,selected_view.bounds.size.width,selected_view.bounds.size.height))return -1;
    if(selected_layer.device!=selected_device || canopy_host_bind_metal_device(selected_device))return -1;
    int expected=0;if(!atomic_compare_exchange_strong(&started,&expected,1))return -1;
    if(put_path("TOTK_ROMFS",s->index_directory,NULL) || put_path("TOTK_ROMFS_DATA",s->romfs_data,NULL) ||
       put_path("TOTK_PROFILE_DIR",s->identity,NULL) || put_path("CANOPY_SAVE_DIR",s->active_saves,NULL) ||
       put_path("TOTK_SHADER_CACHE",s->shader_cache,NULL) || put_path("TOTK_GAME_SLOT_DIR",s->cache,"game-slot") ||
       put_path("TOTK_ROMFS_PROOF_DIR",s->cache,NULL) || put_path("TOTK_SHARED_FONTS",s->resources,"shared-fonts") ||
       put_path("TOTK_FONT_DIR",s->resources,"font") || put_path("TOTK_SHADER_SEED_DIR",s->shader_seed,NULL) ||
       put_path("DM_NVN_SHMAP",s->shader_seed,"shader_map.tsv") || put_path("DM_MSL_DIR",s->shader_seed,NULL) ||
       put_path("TOTK_ROMFS_PATCHES",s->resources,"romfs-patches") || put_path("TOTK_ROMFS_PATCHES_OUT",s->resources,"romfs-patches-out"))return -1;
    if(runtime_language_apply_preferred_choice(s->language,0) || setenv("TOTK_OPERATION_MODE","handheld",1) ||
       setenv("TOTK_SLOT_OWNER","user",1) || setenv("TOTK_SLOT_PURPOSE","player",1))return -1;
    const char *reset[]={"TOTK_AUTOLOAD","TOTK_INPUT_FILE","TOTK_INPUT_SCRIPT","TOTK_HEADLESS","TOTK_VERIFY_STARTUP",NULL};
    for(unsigned i=0;reset[i];i++)unsetenv(reset[i]);
    const char *gpu[]={"TOTK_GPU_ALLOW_SUBMIT","TOTK_GPU_WIDEN","TOTK_GPU_BLOCKRT","TOTK_GPU_MIDCLEAR",NULL};
    for(unsigned i=0;gpu[i];i++)if(setenv(gpu[i],"1",1))return -1;
    if(configure_display(s))return -1;
    module_path=strdup(s->modules);if(!module_path)return -1;
    /* Only the trusted CanopyRuntime path calls start, after manifest/content
     * verification and while retaining the immutable seed's shared lease. */
    verified_seed_path=strdup(s->shader_seed);if(!verified_seed_path)return -1;
    if(setenv("TOTK_SHADER_SEED","on",1) || chdir(s->shader_cache))return -1;
    NSError *audio_error=nil;
    AVAudioSession *audio=AVAudioSession.sharedInstance;
    if(![audio setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&audio_error] ||
       ![audio setActive:YES error:&audio_error])return -1;
    UIApplication.sharedApplication.idleTimerDisabled=YES;
    observe_audio();
    runtime_ios_attach_layer((__bridge CAMetalLayer *)s->metal_layer,(__bridge UIView *)s->host_view);
    runtime_ios_set_fps_limit(s->fps_limit);runtime_ios_set_taa_enabled(s->taa_enabled);
    for(unsigned i=0;i<3 && fps_overlay_hud_mode()!=s->hud_mode;i++)fps_overlay_toggle_hints();
    if(fps_overlay_hud_mode()!=s->hud_mode)return -1;
    /* Preserve the actual existing iOS host's 64 MiB native worker stack. */
    return launch_main_worker(run_host,NULL,64u<<20);
    /* Main and its observer remain process-owned; no reusable-destroy claim. */
}
const struct canopy_totk_host *totk_canopy_host_v1(void) {
    if(!CANOPY_HOST_TITLE_ID || strlen(CANOPY_HOST_ORIGINAL_MAIN_SHA256)!=64 ||
       strlen(CANOPY_HOST_SHADER_SEED_MANIFEST_SHA256)!=64)return NULL;
    if((CANOPY_DISPLAY_FLAGS&MNG_DISPLAY_SCENE_1080)&&!display_hash_valid(CANOPY_HOST_DISPLAY_HEAP_SHA256))return NULL;
    if((CANOPY_DISPLAY_FLAGS&MNG_DISPLAY_FOUR_THREE)&&!display_hash_valid(CANOPY_HOST_DISPLAY_LAYOUT_SHA256))return NULL;
    static const struct canopy_totk_host host={CANOPY_TOTK_HOST_ABI,sizeof(host),CANOPY_HOST_TITLE_ID,TOTK_GAME_VERSION,
        CANOPY_HOST_ORIGINAL_MAIN_SHA256,ROMFS_IMAGE_SHA256,ROMFS_INDEX_SHA256,NULL,CANOPY_HOST_SHADER_SEED_MANIFEST_SHA256,DMSH_CHAIN,start_host,
        runtime_ios_fps_limit_supported,runtime_ios_set_fps_limit,runtime_ios_fps_limit,
        runtime_ios_taa_supported,runtime_ios_set_taa_enabled,runtime_ios_taa_enabled,
        fps_overlay_hud_mode,fps_overlay_toggle_hints,clear_input,runtime_ios_set_host_active,input,
        {MNG_DISPLAY_ABI,sizeof(struct canopy_totk_display),{MNG_DISPLAY_ABI,sizeof(struct mng_display_profile),CANOPY_DISPLAY_FLAGS},
         CANOPY_DISPLAY_FLAGS&MNG_DISPLAY_SCENE_1080?CANOPY_HOST_DISPLAY_HEAP_SHA256:NULL,
         CANOPY_DISPLAY_FLAGS&MNG_DISPLAY_FOUR_THREE?CANOPY_HOST_DISPLAY_LAYOUT_SHA256:NULL,canopy_host_read_display_state},
        {CANOPY_TOTK_LIFECYCLE_ABI,sizeof(struct canopy_totk_lifecycle),canopy_host_read_lifecycle_state}};
    return &host;
}
#else
const struct canopy_totk_host *totk_canopy_host_v1(void) {return NULL;}
#endif
#endif
