/* Original frontend implementing nxnative front.h on Canopy's actual surface.
 * The old AppKit/iOS main/controller/gamepad sources are never linked here. */
#import "canopy_mk8dx.h"
#import <AVFAudio/AVFAudio.h>
#include "dm.h"
#include "front.h"
#include <errno.h>
#include <math.h>
#include <stdatomic.h>
#include <string.h>
extern void dm_focus_set(int);
extern void dm_gfx_suspend(int);
extern void dm_audio_suspend(int);
static CAMetalLayer *layer;
static UIView *view;
static id<MTLDevice> device;
static MKPrepared *preparedOwner;
static _Atomic int terminal,guestReady;
static BOOL hostFocus,osActive,attached,audioInterrupted;
static UIWindowScene *ownedScene;
static _Atomic uint64_t textEpoch;
static _Atomic double brightness=-1;
static _Atomic int screenFPS;
int dm_thermal_now(void){return (int)NSProcessInfo.processInfo.thermalState;}
int dm_low_power_now(void){return NSProcessInfo.processInfo.lowPowerModeEnabled;}
double dm_brightness_now(void){return atomic_load(&brightness);}
static _Atomic int textCapture;
static NSCondition *textCondition;
static BOOL textFinished,textRequestBusy;
static NSString *textResult;
static UIAlertController *textAlert;
static int textAccepted;
static _Atomic uint64_t saveEpoch;
static BOOL saveCapture;
static UIAlertController *saveAlert;
void *MKMetalDevice(void){return (__bridge void *)device;}
void MKCopyUID(uint64_t out[2]){out[0]=preparedOwner.uidLow;out[1]=preparedOwner.uidHigh;}
void *front_metal_layer(void){return (__bridge void *)layer;}
int front_screen_max_fps(void){return atomic_load(&screenFPS);}
void front_screen_match(int fps){(void)fps;/* iOS does not switch global display modes. */}
void front_run(void (*guest)(void)){MKGuestEntry(guest);}
static BOOL eligible(void){return attached&&!atomic_load(&terminal)&&osActive&&hostFocus&&view.window.isKeyWindow&&view.window.windowScene.activationState==UISceneActivationStateForegroundActive&&UIApplication.sharedApplication.applicationState==UIApplicationStateActive;}
static UIViewController *host_controller(void){
    UIResponder *owner=view.nextResponder;
    while(owner&&![owner isKindOfClass:UIViewController.class])owner=owner.nextResponder;
    return (UIViewController *)owner;
}
static void apply_focus(void){BOOL active=eligible()&&!textCapture&&!saveCapture;MKInputFocus(active);if(!atomic_load(&guestReady))return;dm_focus_set(active?1:3);dm_audio_suspend(!active||audioInterrupted);guest_clock_freeze_for(1,!active);dm_gfx_suspend(!active);}
static void finish_text(uint64_t epoch,BOOL accepted,NSString *result){[textCondition lock];if(textEpoch==epoch&&!textFinished){textFinished=YES;textAccepted=accepted;textResult=[result copy];[textCondition broadcast];}[textCondition unlock];}
static void release_text_capture(UIAlertController *alert,uint64_t epoch){
    if(textEpoch!=epoch||textAlert!=alert)return;
    textAlert=nil;textCapture=NO;apply_focus();
}
static void complete_text(UIAlertController *alert,uint64_t epoch,BOOL accepted,NSString *result){
    if(textEpoch!=epoch||textAlert!=alert)return;
    finish_text(epoch,accepted,result);
    if(alert&&alert.presentingViewController.presentedViewController==alert)
        [alert dismissViewControllerAnimated:YES completion:^{release_text_capture(alert,epoch);}];
    else release_text_capture(alert,epoch);
}
static void cancel_text(void){
    if(!textCondition)return;
    uint64_t epoch=atomic_load(&textEpoch);UIAlertController *alert=textAlert;
    complete_text(alert,epoch,NO,nil);
}
/* Only this exact native warning is dismissed. Invalidating the epoch also
 * rejects queued warnings and stale action/dismiss completions. Capture removal
 * never changes hostFocus; app/scene/overlay authority must still permit it. */
static void cancel_save(void){
    ++saveEpoch;UIAlertController *old=saveAlert;saveAlert=nil;saveCapture=NO;
    if(old&&old.presentingViewController.presentedViewController==old)
        [old dismissViewControllerAnimated:NO completion:nil];
}
static void finish_save(UIAlertController *alert,uint64_t epoch){
    if(saveAlert!=alert||saveEpoch!=epoch)return;
    void (^finished)(void)=^{
        if(saveAlert!=alert||saveEpoch!=epoch)return;
        saveAlert=nil;saveCapture=NO;apply_focus();
    };
    if(alert.presentingViewController.presentedViewController==alert)
        [alert dismissViewControllerAnimated:YES completion:finished];
    else finished();
}
int MKSetFocus(int active){NSCAssert(NSThread.isMainThread,@"Native focus belongs on main");if(!attached||atomic_load(&terminal))return -1;hostFocus=active!=0;if(!hostFocus){cancel_text();cancel_save();}apply_focus();return active&&!eligible()?-1:0;}
int MKUpdateLayout(double width,double height,double scale){NSCAssert(NSThread.isMainThread,@"Native presentation belongs on main");if(!attached||atomic_load(&terminal)||!isfinite(width)||!isfinite(height)||!isfinite(scale)||width<=0||height<=0||scale<=0||width>32768||height>32768||scale>16)return -1;
    // A separate native layer keeps the original projection at16:9 while its
    // parent remains the UI owner's full view. This is presentation, not a scene
    // resolution patch. The game's original render targets are untouched.
    UIScreen *screen=view.window.screen;
    double nativeScale=screen.nativeScale>0?screen.nativeScale:screen.scale;
    double w=fmin(width,height*16.0/9.0),h=w*9.0/16.0;
    // Conservative admission ceiling: Metal Feature Set Tables' original iOS
    // GPUFamily1_v1 supports 8192x8192 2D textures. All admitted iOS Metal
    // hardware supports this minimum; larger output is refused, never reduced.
    double pixelsW=round(w*nativeScale),pixelsH=round(h*nativeScale);
    if(!screen||!isfinite(nativeScale)||nativeScale<=0||nativeScale>16||
       !isfinite(pixelsW)||!isfinite(pixelsH)||pixelsW<1||pixelsH<1||pixelsW>8192||pixelsH>8192)return -1;
    atomic_store(&screenFPS,(int)screen.maximumFramesPerSecond);
    [CATransaction begin];[CATransaction setDisableActions:YES];
    layer.frame=CGRectMake((width-w)/2,(height-h)/2,w,h);layer.contentsScale=nativeScale;
    layer.drawableSize=CGSizeMake(pixelsW,pixelsH);[CATransaction commit];return 0;}
int MKAttach(const struct mng_apple_start *s){NSCAssert(NSThread.isMainThread,@"Native attachment belongs on main");if(attached||!s||s->abi!=MNG_APPLE_HOST_ABI||s->size!=sizeof(*s))return -1;
    MKPrepared *p=MKPreparedObject(s->prepared);id<MTLDevice> selected=(__bridge id<MTLDevice>)s->metal_device;CAMetalLayer *parent=(__bridge CAMetalLayer *)s->metal_layer;UIView *host=(__bridge UIView *)s->host_view;
    if(!p||!selected||p.device!=selected||![parent isKindOfClass:CAMetalLayer.class]||parent.device!=selected||![host isKindOfClass:UIView.class])return -1;
    preparedOwner=p;device=selected;view=host;ownedScene=host.window.windowScene;atomic_store(&brightness,host.window.screen.brightness);layer=[CAMetalLayer layer];layer.device=device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.opaque=YES;layer.framebufferOnly=NO;[parent insertSublayer:layer atIndex:0];attached=YES;hostFocus=NO;osActive=UIApplication.sharedApplication.applicationState==UIApplicationStateActive;
    if(MKUpdateLayout(host.bounds.size.width,host.bounds.size.height,host.window.screen.scale?:1))return -1;
    textCondition=[NSCondition new];
    NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;NSOperationQueue *main=NSOperationQueue.mainQueue;
    [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:main usingBlock:^(NSNotification *n){(void)n;osActive=NO;cancel_text();cancel_save();apply_focus();}];
    [nc addObserverForName:UISceneWillDeactivateNotification object:nil queue:main usingBlock:^(NSNotification *n){if(n.object==ownedScene){osActive=NO;cancel_text();cancel_save();apply_focus();}}];
    [nc addObserverForName:UISceneDidActivateNotification object:nil queue:main usingBlock:^(NSNotification *n){if(n.object==ownedScene){osActive=UIApplication.sharedApplication.applicationState==UIApplicationStateActive;apply_focus();}}];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:main usingBlock:^(NSNotification *n){(void)n;osActive=YES;apply_focus();}];
    [nc addObserverForName:UIScreenBrightnessDidChangeNotification object:nil queue:main usingBlock:^(NSNotification *n){if(n.object==view.window.screen)atomic_store(&brightness,view.window.screen.brightness);}];
    [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:main usingBlock:^(NSNotification *n){audioInterrupted=[n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue]==AVAudioSessionInterruptionTypeBegan;apply_focus();}];
    NSError *error=nil;if(![AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:&error]||![AVAudioSession.sharedInstance setActive:YES error:&error])return -1;
    // No guest services/Metal queue are initialized here. Initial input is
    // captured; the worker's real front_run hook applies focus after loading.
    MKInputFocus(0);return 0;}
void MKFrontendGuestReady(void){atomic_store(&guestReady,1);dispatch_sync(dispatch_get_main_queue(),^{apply_focus();});}
void MKFrontendTerminal(void){atomic_store(&terminal,1);MKInputTerminal();dispatch_async(dispatch_get_main_queue(),^{hostFocus=NO;cancel_text();cancel_save();apply_focus();});}
static NSString *bounded_text(const char *p){if(!p)return @"";size_t n=strnlen(p,4096);return n<4096?[[NSString alloc] initWithBytes:p length:n encoding:NSUTF8StringEncoding]:nil;}
int front_text_input(const char *title,const char *sub,const char *guide,const char *initial,int max_chars,char *out,int out_cap){
    if(NSThread.isMainThread||!out||out_cap<=0||out_cap>65536||atomic_load(&terminal))return 0;
    NSString *t=bounded_text(title),*a=bounded_text(sub),*b=bounded_text(guide),*initialValue=bounded_text(initial);if(!t||!a||!b||!initialValue)return 0;
    [textCondition lock];if(textCapture||textRequestBusy){[textCondition unlock];return 0;}textRequestBusy=YES;textCapture=YES;textFinished=NO;textAccepted=NO;textResult=nil;uint64_t epoch=++textEpoch;[textCondition unlock];
    dispatch_async(dispatch_get_main_queue(),^{
        [textCondition lock];BOOL current=textEpoch==epoch&&!textFinished&&textCapture;[textCondition unlock];
        if(!current)return;
        UIViewController *vc=host_controller();
        if(!eligible()||saveCapture||!vc||vc.viewIfLoaded.window!=view.window||vc.presentedViewController||
           vc.isBeingDismissed||(vc.navigationController&&vc.navigationController.topViewController!=vc)){
            complete_text(nil,epoch,NO,nil);return;
        }
        apply_focus();UIAlertController *alert=[UIAlertController alertControllerWithTitle:t message:[NSString stringWithFormat:@"%@\n%@",a,b] preferredStyle:UIAlertControllerStyleAlert];textAlert=alert;
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=initialValue;}];__weak UIAlertController *weakAlert=alert;
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){(void)action;UIAlertController *owned=weakAlert;if(owned)complete_text(owned,epoch,NO,nil);}]];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;NSString *value=weakAlert.textFields.firstObject.text?:@"";UIAlertController *owned=weakAlert;if(owned)complete_text(owned,epoch,eligible()&&(max_chars<=0||value.length<=(NSUInteger)max_chars),value);}]];
        [vc presentViewController:alert animated:YES completion:^{if(textEpoch==epoch&&textAlert==alert&&(!eligible()||vc.presentedViewController!=alert))complete_text(alert,epoch,NO,nil);}];
    });
    [textCondition lock];while(!textFinished)[textCondition wait];NSString *value=textResult;BOOL accepted=textAccepted;textRequestBusy=NO;[textCondition unlock];
    NSData *bytes=accepted?[value dataUsingEncoding:NSUTF8StringEncoding]:nil;if(!bytes||bytes.length>=(NSUInteger)out_cap)return 0;memcpy(out,bytes.bytes,bytes.length);out[bytes.length]=0;return 1;}
void front_save_failed(int err){
    (void)err;uint64_t epoch=atomic_load(&saveEpoch);
    dispatch_async(dispatch_get_main_queue(),^{
        if(saveEpoch!=epoch||!eligible()||saveCapture||textCapture)return;
        UIViewController *owner=host_controller();
        if(!owner||owner.viewIfLoaded.window!=view.window||owner.presentedViewController||
           owner.isBeingDismissed||(owner.navigationController&&owner.navigationController.topViewController!=owner))return;
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Progress was not saved"
            message:@"The native save transaction failed. Its previous committed save is retained; check available storage before continuing."
            preferredStyle:UIAlertControllerStyleAlert];
        saveAlert=alert;saveCapture=YES;apply_focus();
        __weak UIAlertController *weakAlert=alert;
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            (void)action;UIAlertController *owned=weakAlert;if(owned)finish_save(owned,epoch);
        }]];
        [owner presentViewController:alert animated:YES completion:^{
            if(saveEpoch!=epoch||saveAlert!=alert)return;
            if(!eligible()||owner.presentedViewController!=alert){cancel_save();apply_focus();}
        }];
    });
}
