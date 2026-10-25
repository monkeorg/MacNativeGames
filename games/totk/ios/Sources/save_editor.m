#import "save_editor.h"
#import "save_editor_validation.h"
#import <WebKit/WebKit.h>

@interface TOTKEditorBridge : NSObject <WKScriptMessageHandler>
@property(nonatomic,weak) id<WKScriptMessageHandler> target;
@end
@implementation TOTKEditorBridge
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.target userContentController:controller didReceiveScriptMessage:message];
}
@end

@interface TOTKSaveEditor () <WKNavigationDelegate, WKScriptMessageHandler, UIAdaptivePresentationControllerDelegate>
@property(nonatomic,strong) NSData *progressData;
@property(nonatomic,copy) void (^completion)(NSData *);
@property(nonatomic,strong) WKWebView *webView;
@property(nonatomic,strong) UIView *statusView;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic,strong) UIButton *retryButton;
@property(nonatomic,copy) NSString *token;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL ready, finished, finishing, confirming;
@end

@implementation TOTKSaveEditor
- (instancetype)initWithProgressData:(NSData *)data completion:(void (^)(NSData *))completion {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _progressData = [data copy];
        _completion = [completion copy];
        self.title = @"Save editor";
        self.modalInPresentation = YES;
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"Close" forState:UIControlStateNormal];
    close.accessibilityLabel = @"Close save editor";
    [close addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
    UILabel *title = [UILabel new];
    title.text = self.title;
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.textAlignment = NSTextAlignmentCenter;
    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.retryButton setTitle:@"Retry" forState:UIControlStateNormal];
    [self.retryButton addTarget:self action:@selector(loadEditor) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *bar = [[UIStackView alloc] initWithArrangedSubviews:@[close,title,self.retryButton]];
    bar.spacing = 12;
    bar.alignment = UIStackViewAlignmentCenter;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [title setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self.view addSubview:bar];

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = NO;
    TOTKEditorBridge *bridge = [TOTKEditorBridge new];
    bridge.target = self;
    [configuration.userContentController addScriptMessageHandler:bridge name:@"totkSave"];
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.allowsBackForwardNavigationGestures = NO;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.webView];

    self.statusView = [UIView new];
    self.statusView.backgroundColor = UIColor.systemBackgroundColor;
    self.statusView.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel = [UILabel new];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.statusLabel.adjustsFontForContentSizeCategory = YES;
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    UIStackView *status = [[UIStackView alloc] initWithArrangedSubviews:@[self.spinner,self.statusLabel]];
    status.axis = UILayoutConstraintAxisVertical;
    status.spacing = 16;
    status.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusView addSubview:status];
    [self.view addSubview:self.statusView];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [bar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [bar.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [bar.heightAnchor constraintGreaterThanOrEqualToConstant:48],
        [self.webView.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [self.statusView.topAnchor constraintEqualToAnchor:self.webView.topAnchor],
        [self.statusView.leadingAnchor constraintEqualToAnchor:self.webView.leadingAnchor],
        [self.statusView.trailingAnchor constraintEqualToAnchor:self.webView.trailingAnchor],
        [self.statusView.bottomAnchor constraintEqualToAnchor:self.webView.bottomAnchor],
        [status.centerYAnchor constraintEqualToAnchor:self.statusView.centerYAnchor],
        [status.leadingAnchor constraintEqualToAnchor:self.statusView.leadingAnchor constant:24],
        [status.trailingAnchor constraintEqualToAnchor:self.statusView.trailingAnchor constant:-24],
    ]];
    [self loadEditor];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    UIViewController *container = self.navigationController ?: self;
    container.modalInPresentation = YES;
    container.presentationController.delegate = self;
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (!self.finished && !self.finishing && (self.isBeingDismissed || self.navigationController.isBeingDismissed || self.isMovingFromParentViewController)) {
        [self complete:nil];
    }
}
- (void)loadEditor {
    if (self.finished) return;
    [self.webView stopLoading];
    self.ready = NO;
    self.confirming = NO;
    self.token = NSUUID.UUID.UUIDString;
    NSUInteger generation = ++self.generation;
    self.statusView.hidden = NO;
    self.retryButton.enabled = NO;
    if (!validProgress(self.progressData)) {
        [self showError:@"This editor requires a supported TOTK 1.4.x progress.sav copy." retry:NO];
        return;
    }
    self.statusLabel.text = @"Loading the save editor…";
    [self.spinner startAnimating];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:EditorURL]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    [self.webView loadRequest:request];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (self && !self.finished && !self.ready && self.generation == generation) {
            [self showError:@"The editor did not finish loading. Check the connection and retry." retry:YES];
        }
    });
}
- (void)showError:(NSString *)text retry:(BOOL)retry {
    if (self.finished) return;
    self.generation++;
    self.ready = NO;
    [self.webView stopLoading];
    [self.spinner stopAnimating];
    self.statusLabel.text = text;
    self.statusView.hidden = NO;
    self.retryButton.enabled = retry;
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    (void)webView;
    BOOL allowed = action.targetFrame.isMainFrame && editorLocation(action.request.URL) && !self.finished;
    decisionHandler(allowed ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)response decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    (void)webView;
    BOOL allowed = response.isForMainFrame && editorLocation(response.response.URL) && response.canShowMIMEType;
    decisionHandler(allowed ? WKNavigationResponsePolicyAllow : WKNavigationResponsePolicyCancel);
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    (void)navigation;
    if (self.finished || self.ready || !editorLocation(webView.URL)) return;
    NSUInteger generation = self.generation;
    NSString *script =
        @"if (window !== window.top) throw new Error('frame');"
        "for (let i=0; i<100 && !(typeof MarcFile==='function' && typeof _tempFileLoadFunction==='function' && typeof SavegameEditor==='object' && typeof saveAs==='function'); i++) await new Promise(r=>setTimeout(r,100));"
        "if (!(typeof MarcFile==='function' && typeof _tempFileLoadFunction==='function' && typeof SavegameEditor==='object' && typeof saveAs==='function')) throw new Error('editor unavailable');"
        "if (window.__totkSaveToken===token) return true;"
        "const notify=(kind,data)=>window.webkit.messageHandlers.totkSave.postMessage({token,kind,data});"
        "const originalSaveAs=window.saveAs;"
        "window.saveAs=function(blob,name,...rest){"
          "if(name!=='progress.sav') return originalSaveAs.call(this,blob,name,...rest);"
          "if(!(blob instanceof Blob)||blob.size!==size){notify('error','invalid');return;}"
          "blob.arrayBuffer().then(buffer=>{"
            "const bytes=new Uint8Array(buffer);"
            "if(new DataView(buffer).getUint32(4,true)!==0x0049e946){notify('error','invalid');return;}"
            "let binary='';for(let i=0;i<bytes.length;i+=32768) binary+=String.fromCharCode(...bytes.subarray(i,i+32768));"
            "notify('save',btoa(binary));"
          "}).catch(()=>notify('error','read'));"
        "};"
        "const binary=atob(encoded),bytes=new Uint8Array(binary.length);"
        "for(let i=0;i<binary.length;i++) bytes[i]=binary.charCodeAt(i);"
        "window.tempFile=await MarcFile.newFromPromise(new File([bytes],'progress.sav',{type:'application/octet-stream'}));"
        "if(!SavegameEditor.checkValidSavegame()) throw new Error('unsupported save');"
        "window.__totkSaveToken=token;_tempFileLoadFunction();return true;";
    NSDictionary *arguments = @{@"encoded":[self.progressData base64EncodedStringWithOptions:0], @"size":@(ProgressSize), @"token":self.token};
    __weak typeof(self) weakSelf = self;
    [webView callAsyncJavaScript:script arguments:arguments inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || self.finished || self.generation != generation) return;
        if (error || ![result isEqual:@YES]) {
            [self showError:@"The editor could not open this save copy. Retry or close without applying changes." retry:YES];
            return;
        }
        self.ready = YES;
        self.statusView.hidden = YES;
        [self.spinner stopAnimating];
    }];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)webView; (void)navigation;
    if (error.code != NSURLErrorCancelled) [self showError:@"The editor could not load. Check the connection and retry." retry:YES];
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self webView:webView didFailProvisionalNavigation:navigation withError:error];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    (void)webView;
    [self showError:@"The editor stopped. Retry to reopen the original save copy." retry:YES];
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)controller;
    WKSecurityOrigin *origin = message.frameInfo.securityOrigin;
    if (self.finished || self.finishing || !self.ready || self.confirming || message.webView != self.webView ||
        !message.frameInfo.isMainFrame || ![message.name isEqual:@"totkSave"] ||
        ![origin.protocol.lowercaseString isEqual:@"https"] || ![origin.host.lowercaseString isEqual:@"www.marcrobledo.com"] ||
        (origin.port != 0 && origin.port != 443) || !editorLocation(message.frameInfo.request.URL) ||
        ![message.body isKindOfClass:NSDictionary.class]) return;
    NSDictionary *body = message.body;
    if (![body[@"token"] isKindOfClass:NSString.class] || ![body[@"token"] isEqual:self.token]) return;
    NSString *encoded = body[@"data"];
    NSUInteger base64Size = 4 * ((ProgressSize + 2) / 3);
    NSData *edited = nil;
    if ([body[@"kind"] isEqual:@"save"] && [encoded isKindOfClass:NSString.class] && encoded.length == base64Size) {
        edited = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
    }
    if (!validProgress(edited)) {
        [self showError:@"The editor returned an unsupported save. Nothing was applied. Retry or close." retry:YES];
        return;
    }
    self.confirming = YES;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Apply edited save?"
        message:@"Return this edited copy to TOTK for validation and backup before replacement?"
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep editing" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        (void)action; weakSelf.confirming = NO;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Apply" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; [weakSelf finish:edited];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)complete:(NSData *)data {
    if (self.finished) return;
    self.finished = YES;
    self.generation++;
    [self.webView stopLoading];
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"totkSave"];
    self.webView.navigationDelegate = nil;
    [self.webView removeFromSuperview];
    self.webView = nil;
    void (^completion)(NSData *) = self.completion;
    self.completion = nil;
    self.progressData = nil;
    if (completion) completion(data);
}
- (void)finish:(NSData *)data {
    if (self.finished || self.finishing) return;
    self.finishing = YES;
    self.ready = NO;
    UIViewController *container = self.navigationController ?: self;
    if (container.presentingViewController) {
        [container dismissViewControllerAnimated:YES completion:^{ [self complete:data]; }];
    } else {
        [self complete:data];
    }
}
- (void)cancel { [self finish:nil]; }
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    (void)presentationController;
    if (!self.finishing) [self complete:nil];
}
- (void)dealloc {
    [_webView.configuration.userContentController removeScriptMessageHandlerForName:@"totkSave"];
}
@end
