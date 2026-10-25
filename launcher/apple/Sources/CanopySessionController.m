#import "CanopySessionController.h"
#import "CanopyRuntime.h"
#import "CanopyOverlay.h"
#import "CanopyGames.h"
#import "CanopyDiagnosticsController.h"
#import "CanopyInputController.h"
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#include <time.h>

// Native single-use hosts may outlive UIKit navigation, including partial
// startup failure. Keep the save seal and controller owner alive until an
// actual successful teardown or process exit, not merely until view removal.
static CanopySessionController *ConsumedNativeSession;

@interface CanopySessionSurface : UIView
@end
@implementation CanopySessionSurface
+ (Class)layerClass { return CAMetalLayer.class; }
@end

@implementation CanopySessionController {
    NSDictionary *_entry, *_profile;
    CanopySettings *_settings;
    CanopyControllers *_controllers;
    CanopySaveStore *_saves;
    dispatch_queue_t _saveQueue;
    NSURL *_cache;
    CanopyRuntime *_runtime;
    CanopyOverlay *_overlay;
    CanopyInputController *_frontend;
    NSDictionary *_frontendSettingStates;
    CanopyDiagnostics *_diagnostics;
    CADisplayLink *_displayLink;
    NSString *_seal;
    BOOL _attempted, _starting, _active, _returning, _cancelStartupRequested;
    BOOL _diagnosticsModalOwnsInput;
    uint64_t _sequence;
    id<UIGestureRecognizerDelegate> _previousPopDelegate;
    BOOL _previousPopEnabled;
    UIView *_startupView;
    UILabel *_startupStatus;
    UIActivityIndicatorView *_startupSpinner;
}
+ (BOOL)nativeSessionOwnsProcess {
    NSAssert(NSThread.isMainThread,@"Session ownership belongs on main thread");
    return ConsumedNativeSession != nil;
}
- (instancetype)initWithEntry:(NSDictionary *)entry preparedRootURL:(NSURL *)root
                     settings:(CanopySettings *)settings controllers:(CanopyControllers *)controllers
                    saveStore:(CanopySaveStore *)saves saveQueue:(dispatch_queue_t)queue
                     cacheURL:(NSURL *)cache error:(NSError **)error {
    NSDictionary *profile = [CanopyRuntime trustedProfileForTitleID:entry[@"titleID"]];
    if (ConsumedNativeSession || !profile || ![profile[@"hostAssetsURL"] isKindOfClass:NSURL.class]) {
        if (error) *error = [NSError errorWithDomain:@"CanopySessionController" code:1 userInfo:@{NSLocalizedDescriptionKey:ConsumedNativeSession ? @"A single-use native host already owns this process. Close the app before starting another session." : @"This title has no compiled, reviewed native host profile. Prepared assets alone cannot make it executable."}];
        return nil;
    }
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _entry = [entry copy]; _profile = [profile copy]; _settings = settings; _controllers = controllers;
        _saves = saves; _saveQueue = queue; _cache = [cache copy];
        _runtime = [[CanopyRuntime alloc] initWithPreparedRootURL:root];
        _diagnostics = [CanopyDiagnostics new];
    }
    return self;
}
- (void)loadView { self.view = [CanopySessionSurface new]; self.view.backgroundColor = UIColor.blackColor; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = _entry[@"displayName"];
    self.navigationItem.hidesBackButton = YES;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Session lifecycle" style:UIBarButtonItemStylePlain target:self action:@selector(endSession)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Diagnostics" style:UIBarButtonItemStylePlain target:self action:@selector(showDiagnostics)];
    CAMetalLayer *layer = (CAMetalLayer *)self.view.layer;
    layer.device = MTLCreateSystemDefaultDevice(); layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _frontend=[[CanopyInputController alloc] initWithHostController:self hostView:self.view controllers:_controllers localPlayer:0];
    _startupStatus = [UILabel new]; _startupStatus.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _startupStatus.adjustsFontForContentSizeCategory = YES; _startupStatus.numberOfLines = 0;
    _startupStatus.textColor = UIColor.whiteColor; _startupStatus.textAlignment = NSTextAlignmentCenter;
    _startupStatus.text = @"Starting the reviewed native host…";
    _startupSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _startupSpinner.color = UIColor.whiteColor; [_startupSpinner startAnimating];
    UIStackView *startup = [[UIStackView alloc] initWithArrangedSubviews:@[_startupSpinner,_startupStatus]];
    startup.axis = UILayoutConstraintAxisVertical; startup.spacing = 16; startup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:startup]; _startupView = startup;
    [NSLayoutConstraint activateConstraints:@[[startup.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],[startup.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],[startup.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24]]];
    __weak CanopySessionController *weakSelf = self;
    UIViewController *content = CanopyMakeSettingsController(_entry,_settings,
        ^NSDictionary *(NSDictionary *desired) { return [weakSelf applySessionSettings:desired] ?: @{}; },
        ^NSDictionary *{ return [weakSelf sessionSettingStates] ?: @{}; },_controllers);
    _overlay = [[CanopyOverlay alloc] initWithContentController:content captureInput:^BOOL(NSError **error) {
        CanopySessionController *owner = weakSelf; if (!owner) return NO;
        [owner->_frontend setCaptured:YES];
        (void)[owner->_controllers setFocused:NO];
        BOOL okay = [owner->_runtime captureInput:error];
        [owner setNeedsUpdateOfPrefersPointerLocked];
        [owner->_overlay showStatus:@"Gameplay input is captured. This native host does not pause guest CPU execution; the game may continue while settings are open. Save transfers remain locked."];
        return okay;
    } restoreInput:^BOOL(NSError **error) {
        CanopySessionController *owner = weakSelf; if (!owner) return NO;
        if (!owner->_active || owner->_diagnosticsModalOwnsInput || owner.presentedViewController ||
            UIApplication.sharedApplication.applicationState != UIApplicationStateActive || !owner.view.window.isKeyWindow ||
            owner.view.window.windowScene.activationState!=UISceneActivationStateForegroundActive) {
            if (error) *error = [NSError errorWithDomain:@"CanopySessionController" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Return to the active game window before restoring gameplay input."}];
            return NO;
        }
        if (![owner->_runtime restoreInput:error]) return NO;
        (void)[owner->_controllers setFocused:YES]; (void)[owner->_controllers consumeUICommandEdges];
        [owner->_frontend setCaptured:NO];
        [owner becomeFirstResponder]; [owner setNeedsUpdateOfPrefersPointerLocked]; return YES;
    }];
    _overlay.stateDidChange = ^(BOOL expanded) {
        CanopySessionController *owner = weakSelf; if (!owner) return;
        [owner setNeedsUpdateOfPrefersPointerLocked]; if (!expanded) [owner becomeFirstResponder];
        [owner recordDiagnosticEvent];
    };
    [self addChildViewController:_overlay]; _overlay.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_overlay.view];
    [NSLayoutConstraint activateConstraints:@[[_overlay.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[_overlay.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[_overlay.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],[_overlay.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];
    [_overlay didMoveToParentViewController:self];
    _overlay.view.hidden = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(lostFocus:) name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowResigned:) name:UIWindowDidResignKeyNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sceneResigned:) name:UISceneWillDeactivateNotification object:nil];
}
- (NSDictionary *)sessionSettingStates {
    NSMutableDictionary *states=[_runtime.settingStates mutableCopy] ?: [NSMutableDictionary dictionary];
    [states addEntriesFromDictionary:_frontendSettingStates ?: @{}];return [states copy];
}
- (NSDictionary *)applySessionSettings:(NSDictionary *)desired {
    _frontendSettingStates=[_frontend applySettings:desired];
    if([CanopySettings areValidOptions:desired]) {
        NSMutableDictionary *states=[_frontendSettingStates mutableCopy];
        BOOL enabled=[desired[@"metalHUD"] boolValue];
        ((CAMetalLayer *)self.view.layer).developerHUDProperties=@{@"mode":enabled?@"default":@"disabled"};
        states[@"metalHUD"]=@{@"state":@"applied",@"desiredValue":@(enabled),@"effectiveValue":@(enabled),@"message":@"Configured on this session's Metal layer. This HUD is a system diagnostic display, not a gameplay FPS measurement."};
        _frontendSettingStates=[states copy];
        (void)[_runtime applyDesiredSettings:desired];
    }
    return [self sessionSettingStates];
}
- (CanopyDiagnosticsSources *)diagnosticSources {
    CanopyDiagnosticsSources *sources=[CanopyDiagnosticsSources new];
    __weak CanopySessionController *weakSelf=self;
    sources.preparedEntry=^NSDictionary * {CanopySessionController *owner=weakSelf;return owner ? owner->_entry : nil;};
    sources.metrics=^NSDictionary * {CanopySessionController *owner=weakSelf;return owner ? owner->_runtime.diagnosticMetrics : nil;};
    sources.phase=^CanopyDiagnosticsPhase {CanopySessionController *owner=weakSelf;return [CanopyDiagnostics phaseForRuntimeState:owner ? owner->_runtime.state : nil];};
    sources.errorCode=^CanopyDiagnosticsError {CanopySessionController *owner=weakSelf;return owner && [owner->_runtime.state isEqual:@"failed"] ? CanopyDiagnosticsErrorUnknown : CanopyDiagnosticsErrorNone;};
    return sources;
}
- (void)recordDiagnosticEvent {
    if(_diagnostics.enabled)(void)[[self diagnosticSources] snapshotWithDiagnostics:_diagnostics recordIfEnabled:YES];
}
- (void)showDiagnostics {
    if(_starting || _diagnosticsModalOwnsInput || self.presentedViewController)return;
    if(![_overlay open])return;
    _diagnosticsModalOwnsInput=YES;
    CanopyDiagnosticsController *screen=CanopyMakeDiagnosticsController(_diagnostics,[self diagnosticSources]);
    screen.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Done" style:UIBarButtonItemStyleDone target:self action:@selector(closeDiagnostics)];
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:screen];
    navigation.modalInPresentation=YES;
    [self presentViewController:navigation animated:YES completion:nil];
}
- (void)closeDiagnostics {
    [self dismissViewControllerAnimated:YES completion:^{
        (void)[self->_controllers consumeUICommandEdges];
        self->_diagnosticsModalOwnsInput=NO;
        [self setNeedsUpdateOfPrefersPointerLocked];
        // The expanded shield remains until an explicit Resume succeeds.
    }];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!_runtime.nativeEntryInvoked) {
        CAMetalLayer *layer = (CAMetalLayer *)self.view.layer;
        layer.contentsScale = self.view.window.screen.scale ?: UIScreen.mainScreen.scale;
        layer.drawableSize = CGSizeMake(self.view.bounds.size.width * layer.contentsScale,self.view.bounds.size.height * layer.contentsScale);
    }
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    UIGestureRecognizer *pop = self.navigationController.interactivePopGestureRecognizer;
    if (!_attempted) { _previousPopDelegate = pop.delegate; _previousPopEnabled = pop.enabled; }
    pop.enabled = NO;
    [self becomeFirstResponder];
    if (!_attempted) [self startSession];
}
- (BOOL)prefersPointerLocked { return _active && !_overlay.expanded && !_diagnosticsModalOwnsInput && !self.presentedViewController && [_frontend wantsPointerLock]; }
- (BOOL)canBecomeFirstResponder { return YES; }
- (NSArray<UIKeyCommand *> *)keyCommands {
    UIKeyCommand *escape = [UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(toggleSettings)];
    escape.discoverabilityTitle = _starting ? @"Cancel startup" : @"Session settings"; return @[escape];
}
- (void)toggleSettings {
    if(_diagnosticsModalOwnsInput || self.presentedViewController)return;
    if (_starting) [self endSession];
    else if (_active) { if (_overlay.expanded) [_overlay close]; else [_overlay open]; }
}
- (NSSet<UIPress *> *)unhandledPresses:(NSSet<UIPress *> *)presses down:(BOOL)down {
    NSMutableSet *unhandled=[NSMutableSet set];
    for(UIPress *press in presses)if(![_frontend handlePress:press down:down])[unhandled addObject:press];
    return unhandled;
}
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    NSSet *unhandled=[self unhandledPresses:presses down:YES];if(unhandled.count)[super pressesBegan:unhandled withEvent:event];
}
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    NSSet *unhandled=[self unhandledPresses:presses down:NO];if(unhandled.count)[super pressesEnded:unhandled withEvent:event];
}
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    NSSet *unhandled=[self unhandledPresses:presses down:NO];if(unhandled.count)[super pressesCancelled:unhandled withEvent:event];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    (void)[_controllers setFocused:NO];
    [_frontend setCaptured:YES];
    if (_starting) [self endSession];
    if (_runtime.nativeEntryInvoked) { NSError *error = nil; (void)[_runtime captureInput:&error]; }
    [self setNeedsUpdateOfPrefersPointerLocked];
}
- (void)startSession {
    _attempted = YES; _starting = YES; (void)[_controllers setFocused:NO];
    (void)[_controllers consumeUICommandEdges];
    self.navigationItem.leftBarButtonItem.title = @"Cancel startup";
    self.navigationItem.leftBarButtonItem.enabled = YES;
    self.navigationItem.prompt = @"Validating and acquiring the save-session seal…";
    dispatch_async(_saveQueue, ^{
        NSError *error = nil;
        BOOL cacheReady = [NSFileManager.defaultManager createDirectoryAtURL:self->_cache withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error];
        NSString *seal = cacheReady ? [self->_saves sealForSession:&error] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!seal) { self->_starting = NO; [self showFailure:error.localizedDescription]; return; }
            self->_seal = seal;
            if (self->_cancelStartupRequested) {
                [self failedBeforeEntry:[NSError errorWithDomain:@"CanopySessionController" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Startup was canceled before entering native code."}]]; return;
            }
            NSError *settingsError = nil;
            NSDictionary *desired = [self->_settings settingsForTitleID:self->_entry[@"titleID"] error:&settingsError];
            if (!desired) { [self failedBeforeEntry:settingsError]; return; }
            [self applySessionSettings:desired];
            for(NSDictionary *state in self->_frontendSettingStates.allValues)if([state[@"state"] isEqual:@"rejected"]) {
                [self failedBeforeEntry:[NSError errorWithDomain:@"CanopySessionController" code:4 userInfo:@{NSLocalizedDescriptionKey:state[@"message"] ?: @"The input frontend refused this session configuration."}]];return;
            }
            self.navigationItem.prompt = @"Verifying the private native host and prepared generation…";
            NSError *startError = nil;
            BOOL accepted = [self->_runtime startTitleID:self->_entry[@"titleID"] generationID:self->_entry[@"generationID"]
                hostAssetsURL:self->_profile[@"hostAssetsURL"] activeSavesURL:self->_saves.activeDirectoryURL
                identityURL:self->_saves.accountIdentityDirectoryURL cacheURL:self->_cache settings:desired
                graphicsSurface:self.view.layer hostView:self.view error:&startError completion:^(BOOL started, NSError *completionError) {
                self->_starting = NO;
                if (self->_runtime.nativeEntryInvoked) ConsumedNativeSession = self;
                if (!started) {
                    if (!self->_runtime.nativeEntryInvoked) [self failedBeforeEntry:completionError];
                    else { [self showFailure:completionError.localizedDescription]; self->_overlay.view.hidden = NO; [self->_overlay open]; }
                    return;
                }
                self->_active = YES; self->_overlay.view.hidden = NO; self->_startupView.hidden = YES;
                [self->_startupSpinner stopAnimating]; self.navigationItem.leftBarButtonItem.enabled = YES;
                self.navigationItem.leftBarButtonItem.title = @"Session lifecycle";
                self.navigationItem.prompt = @"Native host active • single use until this app closes";
                self->_displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
                [self->_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
                if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive && self.view.window.isKeyWindow &&
                    self.view.window.windowScene.activationState==UISceneActivationStateForegroundActive) {
                    NSError *focusError = nil;
                    if ([self->_runtime captureInput:&focusError] && [self->_runtime restoreInput:&focusError]) { (void)[self->_controllers setFocused:YES]; (void)[self->_controllers consumeUICommandEdges]; [self->_frontend setCaptured:NO]; }
                    else { [self->_overlay open]; [self->_overlay showStatus:focusError.localizedDescription]; }
                } else [self->_overlay open];
                [self setNeedsUpdateOfPrefersPointerLocked];
            }];
            if (!accepted) [self failedBeforeEntry:startError];
        });
    });
}
- (void)failedBeforeEntry:(NSError *)error {
    _starting = NO;
    if (_runtime.nativeEntryInvoked) { [self showFailure:error.localizedDescription]; return; }
    NSString *seal = _seal; _seal = nil;
    if (!seal) { [self showFailure:error.localizedDescription]; return; }
    _starting = YES;
    dispatch_async(_saveQueue, ^{
        NSError *releaseError = nil; BOOL released = [self->_saves finishSessionWithToken:seal error:&releaseError];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_starting = NO;
            if (!released) self->_seal = seal;
            [self showFailure:released ? error.localizedDescription : releaseError.localizedDescription];
        });
    });
}
- (void)showFailure:(NSString *)message {
    if (_runtime.nativeEntryInvoked) ConsumedNativeSession = self;
    [_startupSpinner stopAnimating]; _startupStatus.text = message ?: @"The native session could not start.";
    self.navigationItem.leftBarButtonItem.enabled = YES;
    self.navigationItem.prompt = message ?: @"The native session could not start.";
    if (!_runtime.nativeEntryInvoked && !_seal) self.navigationItem.leftBarButtonItem.title = @"Return to library";
    else self.navigationItem.leftBarButtonItem.title = @"Close app required";
}
- (void)tick:(CADisplayLink *)link {
    (void)link;
    uint64_t commands = [_controllers consumeUICommandEdges];
    if(_diagnosticsModalOwnsInput || self.presentedViewController)return;
    if (!_active || UIApplication.sharedApplication.applicationState != UIApplicationStateActive || !self.view.window.isKeyWindow ||
        self.view.window.windowScene.activationState!=UISceneActivationStateForegroundActive) return;
    if (commands & (UINT64_C(1) << 16)) { if (_overlay.expanded) [_overlay close]; else [_overlay open]; return; }
    if (_overlay.expanded) return;
    struct mng_session_input input = {0};
    if (_sequence == UINT64_MAX) { [_overlay open]; [_overlay showStatus:@"Input sequence exhausted. Restart this app before continuing."]; return; }
    input.sequence = ++_sequence;
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC,&now) != 0) { [_overlay open]; [_overlay showStatus:@"The monotonic input clock is unavailable. Input remains captured."]; return; }
    input.timestamp_ns = (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
    unsigned players=MIN(MNG_PLAYER_COUNT,[_profile[@"maxPlayers"] unsignedIntValue]);
    for (unsigned i = 0; i < players; ++i) {
        uint64_t identifier = 0; struct mng_input state = {0};
        if ([_controllers consumePlayer:i deviceID:&identifier input:&state] != MNG_PLAYER_OK) continue;
        if(i==_frontend.localPlayer) {
            struct mng_input local={0},mixed;
            if(![_frontend consumeInput:&local now:input.timestamp_ns]) { [_overlay open];[_overlay showStatus:@"Local input could not be sampled safely."];return; }
            struct mng_input sources[2]={state,local};
            if(mng_input_mix(sources,2,&mixed)!=MNG_INPUT_OK){[_overlay open];return;}
            state=mixed;
            // Synthetic logical seat marker, never a physical-device identity.
            if(!identifier && _frontend.hasLocalInput)identifier=UINT64_MAX-i;
        }
        input.players[i].device_id = identifier; input.players[i].connected = identifier != 0;
        // Home belongs to the host menu; Capture is a host/system command, not
        // a supported guest Npad bit. Neither is forwarded to the native host.
        input.players[i].buttons = state.buttons & UINT64_C(0xffff);
        input.players[i].left_x = state.sticks[0]; input.players[i].left_y = state.sticks[1];
        input.players[i].right_x = state.sticks[2]; input.players[i].right_y = state.sticks[3];
    }
    NSError *error = nil;
    if (![_runtime submitInput:&input error:&error] || ![_runtime tick:&error]) { [_overlay open]; [_overlay showStatus:error.localizedDescription]; }
}
- (void)lostFocus:(NSNotification *)notification { (void)notification; [_frontend setCaptured:YES]; (void)[_controllers setFocused:NO]; if (_starting) [self endSession]; else if (_active) [_overlay open]; [self setNeedsUpdateOfPrefersPointerLocked]; }
- (void)windowResigned:(NSNotification *)notification { if (notification.object == self.view.window) [self lostFocus:notification]; }
- (void)sceneResigned:(NSNotification *)notification { if (notification.object == self.view.window.windowScene) [self lostFocus:notification]; }
- (void)endSession {
    if (_returning) return;
    if (_starting) {
        if (_cancelStartupRequested) return;
        _cancelStartupRequested = YES;
        NSError *error = nil;
        if ([_runtime.state isEqual:@"preparing"] || [_runtime.state isEqual:@"cancelling"]) (void)[_runtime cancelPreparation:&error];
        _startupStatus.text = error.localizedDescription ?: @"Startup cancellation requested. Waiting for verification and save-seal cleanup to finish.";
        self.navigationItem.leftBarButtonItem.title = @"Cancel requested"; self.navigationItem.leftBarButtonItem.enabled = NO;
        return;
    }
    if (!_runtime.nativeEntryInvoked && !_seal) { [self returnToLibrary]; return; }
    NSError *error = nil;
    if (![_runtime close:&error]) {
        [_overlay open]; [_overlay showStatus:error.localizedDescription ?: @"This native host cannot stop its save writers safely. Save your progress in-game, then close the app from the App Switcher. Save transfers remain locked until process exit."];
        return;
    }
    _active = NO; [_displayLink invalidate]; _displayLink = nil; (void)[_controllers setFocused:NO];
    NSString *seal = _seal;
    dispatch_async(_saveQueue, ^{
        NSError *releaseError = nil; BOOL okay = !seal || [self->_saves finishSessionWithToken:seal error:&releaseError];
        dispatch_async(dispatch_get_main_queue(), ^{ if (okay) { self->_seal = nil; [self returnToLibrary]; } else [self showFailure:releaseError.localizedDescription]; });
    });
}
- (void)returnToLibrary {
    [_frontend setCaptured:YES];
    _returning = YES; (void)[_controllers setFocused:NO];
    self.navigationController.interactivePopGestureRecognizer.delegate = _previousPopDelegate;
    self.navigationController.interactivePopGestureRecognizer.enabled = _previousPopEnabled;
    if (ConsumedNativeSession == self && !_seal) ConsumedNativeSession = nil;
    [self.navigationController popViewControllerAnimated:YES];
}
- (void)dealloc { [_displayLink invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
