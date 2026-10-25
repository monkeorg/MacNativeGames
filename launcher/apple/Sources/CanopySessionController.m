#import "CanopySessionController.h"
#import "CanopyRuntime.h"
#import "CanopyOverlay.h"
#import "CanopyGames.h"
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
    CADisplayLink *_displayLink;
    NSString *_seal;
    BOOL _attempted, _starting, _active, _returning, _cancelStartupRequested;
    uint64_t _sequence;
    id<UIGestureRecognizerDelegate> _previousPopDelegate;
    BOOL _previousPopEnabled;
    UIView *_startupView;
    UILabel *_startupStatus;
    UIActivityIndicatorView *_startupSpinner;
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
    }
    return self;
}
- (void)loadView { self.view = [CanopySessionSurface new]; self.view.backgroundColor = UIColor.blackColor; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = _entry[@"displayName"];
    self.navigationItem.hidesBackButton = YES;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Session lifecycle" style:UIBarButtonItemStylePlain target:self action:@selector(endSession)];
    CAMetalLayer *layer = (CAMetalLayer *)self.view.layer;
    layer.device = MTLCreateSystemDefaultDevice(); layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
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
        ^NSDictionary *(NSDictionary *desired) { CanopySessionController *owner = weakSelf; return owner ? [owner->_runtime applyDesiredSettings:desired] : @{}; },
        ^NSDictionary *{ CanopySessionController *owner = weakSelf; return owner ? owner->_runtime.settingStates : @{}; },_controllers);
    _overlay = [[CanopyOverlay alloc] initWithContentController:content captureInput:^BOOL(NSError **error) {
        CanopySessionController *owner = weakSelf; if (!owner) return NO;
        (void)[owner->_controllers setFocused:NO];
        BOOL okay = [owner->_runtime captureInput:error];
        [owner setNeedsUpdateOfPrefersPointerLocked];
        [owner->_overlay showStatus:@"Gameplay input is captured. This native host does not pause guest CPU execution; the game may continue while settings are open. Save transfers remain locked."];
        return okay;
    } restoreInput:^BOOL(NSError **error) {
        CanopySessionController *owner = weakSelf; if (!owner) return NO;
        if (!owner->_active || UIApplication.sharedApplication.applicationState != UIApplicationStateActive || !owner.view.window.isKeyWindow) {
            if (error) *error = [NSError errorWithDomain:@"CanopySessionController" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Return to the active game window before restoring gameplay input."}];
            return NO;
        }
        if (![owner->_runtime restoreInput:error]) return NO;
        (void)[owner->_controllers setFocused:YES]; (void)[owner->_controllers consumeUICommandEdges];
        [owner becomeFirstResponder]; [owner setNeedsUpdateOfPrefersPointerLocked]; return YES;
    }];
    _overlay.stateDidChange = ^(BOOL expanded) {
        CanopySessionController *owner = weakSelf; if (!owner) return;
        [owner setNeedsUpdateOfPrefersPointerLocked]; if (!expanded) [owner becomeFirstResponder];
    };
    [self addChildViewController:_overlay]; _overlay.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_overlay.view];
    [NSLayoutConstraint activateConstraints:@[[_overlay.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[_overlay.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[_overlay.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],[_overlay.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];
    [_overlay didMoveToParentViewController:self];
    _overlay.view.hidden = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(lostFocus:) name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowResigned:) name:UIWindowDidResignKeyNotification object:nil];
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
- (BOOL)prefersPointerLocked { return _active && !_overlay.expanded && UIApplication.sharedApplication.applicationState == UIApplicationStateActive && self.view.window.isKeyWindow; }
- (BOOL)canBecomeFirstResponder { return YES; }
- (NSArray<UIKeyCommand *> *)keyCommands {
    UIKeyCommand *escape = [UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(toggleSettings)];
    escape.discoverabilityTitle = _starting ? @"Cancel startup" : @"Session settings"; return @[escape];
}
- (void)toggleSettings {
    if (_starting) [self endSession];
    else if (_active) { if (_overlay.expanded) [_overlay close]; else [_overlay open]; }
}
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event { if (!_overlay.expanded) [super pressesBegan:presses withEvent:event]; }
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event { if (!_overlay.expanded) [super pressesEnded:presses withEvent:event]; }
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event { if (!_overlay.expanded) [super pressesCancelled:presses withEvent:event]; }
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    (void)[_controllers setFocused:NO];
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
                if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive && self.view.window.isKeyWindow) {
                    NSError *focusError = nil;
                    if ([self->_runtime captureInput:&focusError] && [self->_runtime restoreInput:&focusError]) { (void)[self->_controllers setFocused:YES]; (void)[self->_controllers consumeUICommandEdges]; }
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
    if (!_active || UIApplication.sharedApplication.applicationState != UIApplicationStateActive || !self.view.window.isKeyWindow) return;
    if (commands & (UINT64_C(1) << 16)) { if (_overlay.expanded) [_overlay close]; else [_overlay open]; return; }
    if (_overlay.expanded) return;
    struct mng_session_input input = {0};
    if (_sequence == UINT64_MAX) { [_overlay open]; [_overlay showStatus:@"Input sequence exhausted. Restart this app before continuing."]; return; }
    input.sequence = ++_sequence;
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC,&now) != 0) { [_overlay open]; [_overlay showStatus:@"The monotonic input clock is unavailable. Input remains captured."]; return; }
    input.timestamp_ns = (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
    for (unsigned i = 0; i < MNG_PLAYER_COUNT; ++i) {
        uint64_t identifier = 0; struct mng_input state = {0};
        if ([_controllers readPlayer:i deviceID:&identifier input:&state] != MNG_PLAYER_OK) continue;
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
- (void)lostFocus:(NSNotification *)notification { (void)notification; (void)[_controllers setFocused:NO]; if (_starting) [self endSession]; else if (_active) [_overlay open]; [self setNeedsUpdateOfPrefersPointerLocked]; }
- (void)windowResigned:(NSNotification *)notification { if (notification.object == self.view.window) [self lostFocus:notification]; }
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
    _returning = YES; (void)[_controllers setFocused:NO];
    self.navigationController.interactivePopGestureRecognizer.delegate = _previousPopDelegate;
    self.navigationController.interactivePopGestureRecognizer.enabled = _previousPopEnabled;
    if (ConsumedNativeSession == self && !_seal) ConsumedNativeSession = nil;
    [self.navigationController popViewControllerAnimated:YES];
}
- (void)dealloc { [_displayLink invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
