/* Native iOS view and VI service adapter: the iPhone counterpart of frontend.m (same exported functions).
   The app (ios/app/Sources/main.m) owns UIKit: it creates the full-screen Metal view, hands its layer over with
   runtime_ios_attach_layer, and calls the loader's main on a game thread. No guest frame is synthesized. */
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#include <stdatomic.h>
#include "runtime.h"
#include "ios_fps_policy.h"
#include "totk_taa.h"
#include "totk_ui_lang.h"
#if defined(CANOPY_HOST_RUNTIME)
#include "canopy_host.h"
#endif
static CAMetalLayer *metalLayer;
static UIView *bootOverlay;
static UILabel *bootStage,*bootDetail;
static UIProgressView *bootProgress;
static uint64_t bootStartNS;
static _Atomic uint64_t presentedFrames;
static CADisplayLink *displayLink;
static pthread_mutex_t vsyncLock=PTHREAD_MUTEX_INITIALIZER;
static void *vsyncEvents[16];
static unsigned vsyncCount;
static __weak UIView *rateHost;
static _Atomic unsigned fpsLimit = 60, maximumFps = 60;
extern int mfx_enabled(void);
static int realtime_profile(void) {
#if defined(TOTK_GAME_V143) && defined(TOTK_IOS_DISPLAY_SETTINGS)
 const char *rt=getenv("TOTK_REALTIME");return !(rt&&!strcmp(rt,"0"));
#else
 return 0;
#endif
}
static UIScreen *active_screen(void) {
 UIScreen *screen=rateHost.window.screen;
 if(!screen)for(UIScene *scene in UIApplication.sharedApplication.connectedScenes){
  if([scene isKindOfClass:UIWindowScene.class]&&scene.activationState==UISceneActivationStateForegroundActive){screen=((UIWindowScene *)scene).screen;break;}
 }
 return screen;
}
static unsigned screen_maximum(void) {
 UIScreen *screen=active_screen();
 if(screen)atomic_store(&maximumFps,(unsigned)screen.maximumFramesPerSecond);
 return atomic_load(&maximumFps);
}
unsigned runtime_ios_fps_limit(void){return ios_fps_effective(atomic_load(&fpsLimit),atomic_load(&maximumFps));}
int runtime_ios_fps_limit_supported(unsigned fps){return ios_fps_supported(fps,screen_maximum(),realtime_profile(),mfx_enabled());}
/* Render threads read only atomics and the existing interpolation state. */
uint64_t runtime_ios_fps_period(void){
 unsigned fps=runtime_ios_fps_limit();
 return ios_fps_supported(fps,atomic_load(&maximumFps),realtime_profile(),mfx_enabled())?1000000000ull/fps:0;
}
void runtime_ios_set_fps_limit(unsigned fps){
 NSCAssert(NSThread.isMainThread,@"Frame cap must change on the main thread");
 if(!runtime_ios_fps_limit_supported(fps))return;
 atomic_store(&fpsLimit,fps);
 fprintf(stderr,"[totk] requested native frame cap %u FPS (system display rate may differ)\n",fps);
}
int runtime_ios_taa_supported(void){
 id<MTLDevice> device=metalLayer.device ?: MTLCreateSystemDefaultDevice();
 return device && [MTLFXTemporalScalerDescriptor supportsMetal4FX:device];
}
void runtime_ios_set_taa_enabled(int enabled){
 if((enabled!=0&&enabled!=1)||(enabled&&!runtime_ios_taa_supported()))return;
 taa_set_enabled(enabled);
}
int runtime_ios_taa_enabled(void){return taa_enabled();}
void hle_bind_system_event(void *,int);
void hle_signal_system_event(void *);
void *front_metal_layer(void){return (__bridge void *)metalLayer;}
void front_frame_presented(void){
 if(atomic_fetch_add_explicit(&presentedFrames,1,memory_order_relaxed)==0){
  fprintf(stderr,"[totk-boot] %.3f first presented frame\n",(runtime_now_ns()-bootStartNS)/1e9);
  dispatch_async(dispatch_get_main_queue(), ^{bootOverlay.hidden=YES;});
 }
}
void runtime_boot_progress(const char *stage,uint64_t done,uint64_t total){
 static const char *last;
 if(stage!=last){fprintf(stderr,"[totk-boot] %.3f %s\n",bootStartNS?(runtime_now_ns()-bootStartNS)/1e9:0,stage?stage:"startup");last=stage;}
 NSString *s=[NSString stringWithUTF8String:stage?stage:TOTK_UI("正在启动","Starting")];
 dispatch_async(dispatch_get_main_queue(), ^{
  if(!bootOverlay||bootOverlay.hidden)return;
  bootStage.text=s;
  if(total){bootDetail.text=[NSString stringWithFormat:@"%.1f / %.1f GB",done/1e9,total/1e9];bootProgress.hidden=NO;bootProgress.progress=(float)((double)done/(double)total);}
  else {bootDetail.text=@(TOTK_UI("正在处理，请稍候","Working, please wait"));bootProgress.hidden=YES;}
 });
}
void runtime_boot_count(const char *stage,uint64_t done,uint64_t total){
 /* Steps counted in items, not bytes (the shader import: tens of thousands of files, minutes on a phone). */
 static const char *last;
 if(stage!=last){fprintf(stderr,"[totk-boot] %.3f %s\n",bootStartNS?(runtime_now_ns()-bootStartNS)/1e9:0,stage?stage:"startup");last=stage;}
 NSString *s=[NSString stringWithUTF8String:stage?stage:TOTK_UI("正在启动","Starting")];
 dispatch_async(dispatch_get_main_queue(), ^{
  if(!bootOverlay||bootOverlay.hidden)return;
  bootStage.text=s;bootDetail.text=[NSString stringWithFormat:@"%llu / %llu",(unsigned long long)done,(unsigned long long)total];
  if(total){bootProgress.hidden=NO;bootProgress.progress=(float)((double)done/(double)total);}
 });
}
void runtime_boot_status(const char *stage,const char *detail){
 if(bootStartNS)fprintf(stderr,"[totk-boot] %.3f %s — %s\n",(runtime_now_ns()-bootStartNS)/1e9,stage?stage:"startup",detail?detail:"");
 NSString *s=[NSString stringWithUTF8String:stage?stage:TOTK_UI("正在启动","Starting")];
 NSString *d=[NSString stringWithUTF8String:detail?detail:TOTK_UI("正在处理，请稍候","Working, please wait")];
 dispatch_async(dispatch_get_main_queue(), ^{if(!bootOverlay||bootOverlay.hidden)return;bootStage.text=s;bootDetail.text=d;bootProgress.hidden=YES;});
}
/* Background shader/pipeline warm-up progress (iOS ships with the warm manifest off, but the hooks are shared with the Mac front end). */
void runtime_warm_progress(uint64_t done,uint64_t total,uint64_t shaders,uint64_t shader_total,uint64_t pipelines,uint64_t pipeline_total){
 (void)shaders;(void)shader_total;(void)pipelines;(void)pipeline_total;
 dispatch_async(dispatch_get_main_queue(), ^{
  if(!bootOverlay||bootOverlay.hidden)return;
  double frac=total ? fmin(1.0,(double)done/(double)total) : 1.0;
  bootStage.text=[NSString stringWithFormat:@(TOTK_UI("预热着色器与管线 %.0f%%","Warming shaders and pipelines %.0f%%")),floor(frac*100.0)];
  bootDetail.text=[NSString stringWithFormat:@(TOTK_UI("已处理 %llu/%llu 项","%llu/%llu items")),(unsigned long long)done,(unsigned long long)total];
  bootProgress.hidden=NO;bootProgress.progress=(float)frac;
 });
}
void runtime_warm_done(void){}
uint64_t front_game_res(int docked){
 (void)docked;
#if defined(TOTK_GAME_V143) && defined(TOTK_IOS_DISPLAY_SETTINGS)
 return runtime_output_size_current();
#else
 return (720ULL<<32)|1280;
#endif
}
static _Atomic int appActive=1;
#if defined(CANOPY_HOST_RUNTIME)
static _Atomic int canopySystemActive=1, canopyHostActive=1;
#endif
int runtime_front_focus(void){return atomic_load(&appActive);}
void mtl_app_active(int active);
/* Not active (background, Control Center, lock): stop GPU submission (iOS rejects background GPU work) and tell the game focus changed, like the Mac window. */
static void app_active_changed(int active){
#if defined(CANOPY_HOST_RUNTIME)
 atomic_store(&canopySystemActive,!!active);
 active=active&&atomic_load(&canopyHostActive);
#endif
 if(atomic_exchange(&appActive,active)==active)return;
 if(!active)runtime_input_clear();
 mtl_app_active(active);runtime_oe_push_message(15);
 fprintf(stderr,"[totk] app %s\n",active?"became active":"resigned active: GPU submission paused");
}
#if defined(CANOPY_HOST_RUNTIME)
/* Opt-in private host: overlay focus follows the actual OS graphics/focus path.
 * This deactivates GPU submission; guest CPU suspension is not promised. */
void runtime_ios_set_host_active(int active) {
 NSCAssert(NSThread.isMainThread,@"Host focus changes on main thread");
 atomic_store(&canopyHostActive,!!active);
 app_active_changed(atomic_load(&canopySystemActive));
}
#endif
void runtime_front_request_close(void){fprintf(stderr,"[totk] close requested; iOS apps are closed by the user\n");}
void runtime_front_text_test(const char *op,const char *text){(void)text;fprintf(stderr,"[totk] text entry test \"%s\" ignored: iOS has no text entry bar (the keyboard request is cancelled)\n",op?op:"");}

@interface TOTKVsync:NSObject
@end
@implementation TOTKVsync
-(void)tick:(CADisplayLink *)l{(void)l;pthread_mutex_lock(&vsyncLock);for(unsigned i=0;i<vsyncCount;i++)hle_signal_system_event(vsyncEvents[i]);pthread_mutex_unlock(&vsyncLock);}
@end
static TOTKVsync *vsyncTarget;

/* Called on the main thread by the app before the game thread starts. */
void runtime_ios_attach_layer(CAMetalLayer *layer,UIView *host){
 rateHost=host;screen_maximum();
 bootStartNS=runtime_now_ns();
 metalLayer=layer;
#if defined(CANOPY_HOST_RUNTIME)
 // Preserve the exact selected device used to namespace verified shader caches.
 if(!metalLayer.device)metalLayer.device=MTLCreateSystemDefaultDevice();
#else
 metalLayer.device=MTLCreateSystemDefaultDevice();
#endif
 metalLayer.pixelFormat=MTLPixelFormatBGRA8Unorm;metalLayer.framebufferOnly=NO;
#if defined(CANOPY_HOST_RUNTIME)
 // Preflight may have finished after an OS resign notification. Read current
 // state and start captured before the worker can submit any GPU work. The UI
 // restores host focus only after an active key window and closed overlay.
 atomic_store(&canopyHostActive,0);
 app_active_changed(UIApplication.sharedApplication.applicationState==UIApplicationStateActive);
#endif
 UIScreen *screen=active_screen();
 CGFloat s=screen.nativeScale>0?screen.nativeScale:host.traitCollection.displayScale;
 if(s<=0)s=1;
#if defined(CANOPY_HOST_RUNTIME)
 if(!isfinite(host.bounds.size.width)||!isfinite(host.bounds.size.height)||host.bounds.size.width<=0||host.bounds.size.height<=0)
  runtime_fail("Invalid Canopy display view dimensions");
 if(!isfinite(s))s=1;
#endif
 metalLayer.contentsScale=s;
 /* TOTK_IOS_DRAWABLE_H (default 720; 0 = native pixels): build the drawable this many pixels tall at the view's aspect, so the
    game picture (1280x720 canvas) lands about 1:1 and the system compositor scales it to the screen instead of our GPU. */
 double vw=round(host.bounds.size.width*s),vh=round(host.bounds.size.height*s);
 const char *dh=getenv("TOTK_IOS_DRAWABLE_H");long want=dh?strtol(dh,NULL,10):720;
 /* the 16:9 picture should get about want rows: a screen narrower than 16:9 (an iPad, about 4:3; 2026-10-17) holds it by
    width, so there the drawable is want*16/9 columns wide (1281x890 on a 2360x1640 iPad); an iPhone keeps want rows */
 if(want>0){double h=vw/vh<16.0/9.0?round(want*16.0/9.0*vh/vw):(double)want;if(h<vh){vw=round(vw*h/vh);vh=h;}}
#if defined(CANOPY_HOST_RUNTIME)
 struct mng_display_state selected={MNG_DISPLAY_ABI,sizeof(selected),MNG_DISPLAY_NOT_CONFIGURED,{0}};
 if(canopy_host_read_display_state(&selected)||selected.validation==MNG_DISPLAY_NOT_CONFIGURED)
  runtime_fail("Canopy display must be configured before attaching its native layer");
 if(selected.config.fixed_resolution){
  // Scene/canvas targets come from the checked startup profile. Drawable size
  // only controls presentation and is never evidence of rendered resolution.
  vw=selected.config.width;
  vh=selected.config.aspect==MNG_DISPLAY_FULL?selected.config.height:
      round(vw*host.bounds.size.height/host.bounds.size.width);
  runtime_aspect_view(vw,vh);
 }
#elif defined(TOTK_GAME_V143) && defined(TOTK_IOS_DISPLAY_SETTINGS)
 /* Match the real game canvas; presentation still letterboxes 16:9 on a taller screen. */
 uint64_t output=runtime_output_size_current();
 double outputW=(unsigned)output,outputH=(unsigned)(output>>32);
 const char *aspect=getenv("TOTK_ASPECT");
 if(aspect&&!strcmp(aspect,"display")){
  vw=outputW;vh=outputH;
 }else{
  // Retain the full view's aspect for letterboxing while the game canvas stays 16:9.
  vh=round(outputW*host.bounds.size.height/host.bounds.size.width);vw=outputW;
 }
 runtime_aspect_view(vw,vh);
#endif
#if defined(CANOPY_HOST_RUNTIME)
 if(!isfinite(vw)||!isfinite(vh)||vw<1||vh<1||vw>16384||vh>16384)
  runtime_fail("Canopy drawable exceeds bounded presentation dimensions");
#endif
 metalLayer.drawableSize=CGSizeMake(vw,vh);
 fprintf(stderr,"[totk] view drawable %.0fx%.0f (screen scale %.1f, TOTK_IOS_DRAWABLE_H=%ld)\n",vw,vh,s,want);
 bootOverlay=[[UIView alloc] initWithFrame:host.bounds];bootOverlay.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
 bootOverlay.backgroundColor=[UIColor colorWithRed:0.035 green:0.075 blue:0.09 alpha:1];
 CGFloat w=host.bounds.size.width,h=host.bounds.size.height;
 bootStage=[[UILabel alloc] initWithFrame:CGRectMake(0,h/2-50,w,36)];bootStage.text=@(TOTK_UI("正在启动海拉鲁","Starting Hyrule"));bootStage.textColor=UIColor.whiteColor;
 bootStage.font=[UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];bootStage.textAlignment=NSTextAlignmentCenter;
 bootDetail=[[UILabel alloc] initWithFrame:CGRectMake(0,h/2-8,w,24)];bootDetail.text=@(TOTK_UI("正在准备游戏环境","Preparing the game environment"));bootDetail.textColor=[UIColor colorWithWhite:0.72 alpha:1];
 bootDetail.font=[UIFont systemFontOfSize:14];bootDetail.textAlignment=NSTextAlignmentCenter;
 bootProgress=[[UIProgressView alloc] initWithFrame:CGRectMake(w/2-140,h/2+30,280,8)];bootProgress.hidden=YES;
 [bootOverlay addSubview:bootStage];[bootOverlay addSubview:bootDetail];[bootOverlay addSubview:bootProgress];[host addSubview:bootOverlay];
 NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
 [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n){(void)n;app_active_changed(0);}];
 [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n){(void)n;app_active_changed(1);}];
 vsyncTarget=[TOTKVsync new];displayLink=[CADisplayLink displayLinkWithTarget:vsyncTarget selector:@selector(tick:)];
 /* VI remains the display-service clock. Native-frame caps use the existing NVN pacer and Metal display link. */
 displayLink.preferredFrameRateRange=CAFrameRateRangeMake(60,60,60);[displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
/* The app already runs the loader on a game thread with a large stack; the event loop belongs to UIKit. */
void runtime_front_run(void(*callback)(void)){
 if(!metalLayer)runtime_fail("iOS view not attached before boot");
 runtime_gamepad_start();
 @autoreleasepool{callback();}
}
static int viReady;
static unsigned displayIdentity,layerIdentity;
static void vi_initialize(void){if(!metalLayer)runtime_fail("VI requires the native iOS view");viReady=1;fprintf(stderr,"[totk] native VI display initialized\n");}
static uint32_t vi_open(void **out){if(!viReady||!out)return 0xf601;*out=&displayIdentity;return 0;}
static uint32_t vi_layer(void **out,void *display){if(!out||display!=&displayIdentity)return 0xf601;*out=&layerIdentity;return 0;}
static uint32_t vi_window(void **out,void *layer){if(!out||layer!=&layerIdentity)return 0xf601;*out=front_metal_layer();return 0;}
static uint32_t vi_vsync(void *ev,void *display){
 if(!ev||display!=&displayIdentity)return 0xf601;hle_bind_system_event(ev,1);
 pthread_mutex_lock(&vsyncLock);if(vsyncCount>=16)runtime_fail("VI display event limit");vsyncEvents[vsyncCount++]=ev;pthread_mutex_unlock(&vsyncLock);return 0;
}
void *runtime_front_override(const char *name){
 static const struct{const char *name;void *fn;} entries[]={
 {"_ZN2nn2vi10InitializeEv",vi_initialize},{"_ZN2nn2vi18OpenDefaultDisplayEPPNS0_7DisplayE",vi_open},
 {"_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayE",vi_layer},{"_ZN2nn2vi15GetNativeWindowEPPvPNS0_5LayerE",vi_window},
 {"_ZN2nn2vi20GetDisplayVsyncEventEPNS_2os15SystemEventTypeEPNS0_7DisplayE",vi_vsync}};
 for(unsigned i=0;i<sizeof(entries)/sizeof(*entries);i++)if(!strcmp(name,entries[i].name))return entries[i].fn;return NULL;
}
