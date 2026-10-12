#import "RBXAccountStatusViewController.h"
#import "RBXAppearance.h"
#import "RBXHTTPProxy.h"
#import "RBXSecureConfig.h"
#import <WebKit/WebKit.h>

static const NSUInteger RBXAccountMaximumBytes = 2 * 1024 * 1024;
static const NSUInteger RBXAccountMaximumRedirects = 5;
static NSString *const RBXAccountUsernamePattern = @"^[A-Za-z0-9_-]{1,32}$";
// No resource types are excepted: stylesheets, images, fetches and frames all
// fail closed, independently of the injected CSP and navigation delegate.
static NSString *const RBXAccountNetworkBlockRules =
    @"[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]";
static NSString *const RBXAccountSnapshotCSP =
    @"default-src 'none'; script-src 'none'; connect-src 'none'; img-src 'none'; "
     "style-src 'unsafe-inline'; font-src 'none'; frame-src 'none'; object-src 'none'; "
     "base-uri 'none'; form-action 'none'";

static BOOL RBXAccountAllowedURL(NSURL *url) {
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    return [parts.scheme.lowercaseString isEqualToString:@"https"] &&
        [@[@"reddit.com", @"www.reddit.com"] containsObject:parts.host.lowercaseString] &&
        (!parts.port || parts.port.integerValue == 443) &&
        !parts.user && !parts.password && !parts.fragment;
}

static NSString *RBXAccountEscapeText(NSString *text) {
    return [[[text stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
        stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"]
        stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
}

@interface RBXAccountStatusViewController () <NSURLSessionDataDelegate, WKNavigationDelegate, WKUIDelegate>
@property(nonatomic, copy) NSString *initialUsername;
@property(nonatomic, strong) UITextField *usernameField;
@property(nonatomic, strong) UIButton *checkButton;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSMutableData *responseData;
@property(nonatomic, strong) NSHTTPURLResponse *httpResponse;
@property(nonatomic, strong) NSURL *requestedURL;
@property(nonatomic, copy) NSString *requestFailure;
@property(nonatomic) NSUInteger redirectCount;
@property(nonatomic) BOOL networkBlockerReady;
@property(nonatomic) BOOL allowsSnapshotDocument;
@end

@implementation RBXAccountStatusViewController

- (instancetype)initWithUsername:(NSString *)username {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _initialUsername = [username isKindOfClass:NSString.class] ? [username copy] : @"";
        self.title = @"Check account status";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = RBXCanvasColor();
    RBXStyleNavigation(self.navigationController);

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    UIStackView *page = RBXVerticalStack(@[], 16);
    page.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:page];
    UIStackView *card = RBXFormSection(page, @"Anonymous profile snapshot",
        @"A separate manual request uses your configured proxy without rotating it. "
         "It does not use any container's Reddit login. Inspect the response yourself; "
         "scripts, remote resources, links and forms are disabled.");
    self.usernameField = [UITextField new];
    self.usernameField.placeholder = @"Reddit username (without u/)";
    self.usernameField.text = self.initialUsername;
    self.usernameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.usernameField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.usernameField.spellCheckingType = UITextSpellCheckingTypeNo;
    self.usernameField.keyboardType = UIKeyboardTypeASCIICapable;
    self.usernameField.clearButtonMode = UITextFieldViewModeWhileEditing;
    RBXStyleField(self.usernameField);
    [card addArrangedSubview:self.usernameField];
    self.checkButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.checkButton setTitle:@"Fetch fresh profile" forState:UIControlStateNormal];
    [self.checkButton addTarget:self action:@selector(checkAccount) forControlEvents:UIControlEventTouchUpInside];
    RBXStyleButton(self.checkButton, YES);
    self.checkButton.enabled = NO;
    [card addArrangedSubview:self.checkButton];
    self.statusLabel = RBXLabel(@"Preparing the isolated viewer…", UIFontTextStyleSubheadline, NO);
    self.statusLabel.accessibilityTraits |= UIAccessibilityTraitUpdatesFrequently;
    [card addArrangedSubview:self.statusLabel];
    [card addArrangedSubview:RBXLabel(@"404 is inconclusive and may reflect access restrictions. "
        "It is not proof of a shadowban. A missing or limited snapshot is not an account diagnosis.",
        UIFontTextStyleFootnote, YES)];

    WKWebViewConfiguration *webConfiguration = [WKWebViewConfiguration new];
    webConfiguration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    webConfiguration.defaultWebpagePreferences.allowsContentJavaScript = NO;
    webConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = NO;
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:webConfiguration];
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.allowsLinkPreview = NO;
    self.webView.allowsBackForwardNavigationGestures = NO;
    self.webView.layer.cornerRadius = 16;
    self.webView.clipsToBounds = YES;
    self.webView.accessibilityLabel = @"Read-only anonymous profile response";
    [page addArrangedSubview:self.webView];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [page.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [page.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [page.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16],
        [page.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [page.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32],
        [self.webView.heightAnchor constraintGreaterThanOrEqualToConstant:400],
    ]];

    __weak typeof(self) weakSelf = self;
    [[WKContentRuleListStore defaultStore] compileContentRuleListForIdentifier:@"RedditBoxAnonymousSnapshotBlockAllV1"
        encodedContentRuleList:RBXAccountNetworkBlockRules completionHandler:^(WKContentRuleList *rules, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            if (!rules || error) {
                self.statusLabel.text = @"The viewer could not block remote resources. No request was sent. Reopen this screen to retry.";
                return;
            }
            [self.webView.configuration.userContentController addContentRuleList:rules];
            self.networkBlockerReady = YES;
            self.checkButton.enabled = YES;
            self.statusLabel.text = @"Enter a username and fetch a fresh anonymous response. Nothing has been requested yet.";
        });
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self cancelRequest];
    [self.webView stopLoading];
}

- (void)cancelRequest {
    NSURLSession *session = self.session;
    self.session = nil;
    self.task = nil;
    [session invalidateAndCancel];
    self.responseData = nil;
    self.checkButton.enabled = self.networkBlockerReady;
}

- (NSMutableURLRequest *)anonymousRequestForURL:(NSURL *)url {
    if (!RBXAccountAllowedURL(url)) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    request.HTTPMethod = @"GET";
    request.HTTPShouldHandleCookies = NO;
    [request setValue:@"text/html,application/xhtml+xml,text/plain;q=0.8" forHTTPHeaderField:@"Accept"];
    [request setValue:@"no-store, no-cache" forHTTPHeaderField:@"Cache-Control"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Pragma"];
    return request;
}

- (void)checkAccount {
    if (!self.networkBlockerReady || self.task) return;
    NSString *username = [self.usernameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!username.length || [username rangeOfString:RBXAccountUsernamePattern
            options:NSRegularExpressionSearch].location == NSNotFound) {
        self.statusLabel.text = @"Enter 1–32 letters, numbers, underscores or hyphens, without u/ or a URL.";
        return;
    }
    NSError *configurationError = nil;
    NSDictionary *configuration = [RBXSecureConfig rotationConfiguration:&configurationError];
    NSDictionary *endpoint = configurationError ? nil : RBXParseHTTPProxyURL(configuration[@"proxyURL"]);
    NSDictionary *proxySettings = endpoint ? RBXHTTPProxySettings(endpoint) : nil;
    if (!proxySettings.count) {
        self.statusLabel.text = @"A readable HTTP proxy is required. Set an http://host:port proxy in Settings, then retry. No request was sent.";
        return;
    }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.reddit.com/user/%@/", username]];
    NSMutableURLRequest *request = [self anonymousRequestForURL:url];
    if (!request) return;
    [self.view endEditing:YES];
    self.checkButton.enabled = NO;
    self.statusLabel.text = [NSString stringWithFormat:@"Fetching %@ through the configured proxy…", url.absoluteString];
    self.httpResponse = nil;
    self.requestedURL = url;
    self.requestFailure = nil;
    self.redirectCount = 0;
    self.responseData = [NSMutableData data];
    self.allowsSnapshotDocument = YES;
    [self.webView loadHTMLString:@"" baseURL:nil];

    // A new ephemeral session on every explicit request has no shared cookies,
    // cache, credentials, clone session, or cloud bearer. PAC has no DIRECT arm.
    NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    sessionConfiguration.connectionProxyDictionary = proxySettings;
    sessionConfiguration.HTTPCookieStorage = nil;
    sessionConfiguration.HTTPShouldSetCookies = NO;
    sessionConfiguration.HTTPAdditionalHeaders = @{};
    sessionConfiguration.URLCredentialStorage = nil;
    sessionConfiguration.URLCache = nil;
    sessionConfiguration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    sessionConfiguration.timeoutIntervalForRequest = 20;
    sessionConfiguration.timeoutIntervalForResource = 30;
    sessionConfiguration.waitsForConnectivity = NO;
    RBXHTTPProxyDelegate *proxyDelegate = [[RBXHTTPProxyDelegate alloc] initWithDelegate:self
        endpoint:^NSDictionary *{ return endpoint; }];
    self.session = [NSURLSession sessionWithConfiguration:sessionConfiguration
        delegate:proxyDelegate delegateQueue:NSOperationQueue.mainQueue];
    self.task = [self.session dataTaskWithRequest:request];
    [self.task resume];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    if (session != self.session || task != self.task) { completionHandler(nil); return; }
    if (++self.redirectCount > RBXAccountMaximumRedirects || !RBXAccountAllowedURL(request.URL)) {
        self.requestFailure = @"The response redirected outside the allowed HTTPS Reddit hosts or exceeded five redirects. Navigation was blocked.";
        completionHandler(nil);
        [task cancel];
        return;
    }
    // Build a new request instead of carrying redirect headers or cookies.
    completionHandler([self anonymousRequestForURL:request.URL]);
}

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    // RBXHTTPProxyDelegate handles credentials only for the exact configured
    // proxy. Origin HTTP authentication is never permitted; normal TLS trust is.
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust])
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    else completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    [self URLSession:session didReceiveChallenge:challenge completionHandler:completionHandler];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    if (session != self.session || dataTask != self.task) { completionHandler(NSURLSessionResponseCancel); return; }
    if ([response isKindOfClass:NSHTTPURLResponse.class] && RBXAccountAllowedURL(response.URL))
        self.httpResponse = (NSHTTPURLResponse *)response;
    if (![response isKindOfClass:NSHTTPURLResponse.class] || !RBXAccountAllowedURL(response.URL) ||
        response.expectedContentLength > (long long)RBXAccountMaximumBytes ||
        ![@[@"text/html", @"application/xhtml+xml", @"text/plain"] containsObject:response.MIMEType.lowercaseString]) {
        self.requestFailure = @"The response is not a supported HTML/text page within the 2 MiB limit. Nothing was opened outside the isolated viewer.";
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    self.httpResponse = (NSHTTPURLResponse *)response;
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    willCacheResponse:(NSCachedURLResponse *)proposedResponse
    completionHandler:(void (^)(NSCachedURLResponse *))completionHandler {
    completionHandler(nil);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (session != self.session || dataTask != self.task) return;
    if (data.length > RBXAccountMaximumBytes - self.responseData.length) {
        self.requestFailure = @"The response exceeded 2 MiB and was canceled. No account diagnosis was made.";
        [dataTask cancel];
        return;
    }
    [self.responseData appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (session != self.session || task != self.task) return;
    NSData *data = [self.responseData copy];
    NSHTTPURLResponse *response = self.httpResponse;
    NSString *failure = self.requestFailure;
    [self cancelRequest];
    if (failure.length || error || !response) {
        NSString *observation = response ? [NSString stringWithFormat:@"HTTP %ld · %@",
            (long)response.statusCode, response.URL.absoluteString] :
            [NSString stringWithFormat:@"No HTTP response · %@", self.requestedURL.absoluteString ?: @""];
        self.statusLabel.text = [NSString stringWithFormat:@"%@\n%@", observation,
            failure ?: @"The proxied request failed or timed out. No direct-network retry was attempted. Check the proxy and retry manually."];
        return;
    }
    NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!html) html = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!html) {
        self.statusLabel.text = @"The response could not be decoded. No account diagnosis was made.";
        return;
    }
    if ([response.MIMEType.lowercaseString isEqualToString:@"text/plain"])
        html = [NSString stringWithFormat:@"<pre>%@</pre>", RBXAccountEscapeText(html)];
    // The CSP is parsed before any untrusted markup. It cannot be relaxed by
    // another CSP in the response. Inline styles may improve human readability;
    // all remote resources remain blocked by both CSP and the content rule list.
    NSString *snapshot = [NSString stringWithFormat:
        @"<!doctype html><html><head><meta http-equiv=\"Content-Security-Policy\" content=\"%@\">"
         "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head><body>%@</body></html>",
        RBXAccountSnapshotCSP, html];
    self.statusLabel.text = [NSString stringWithFormat:@"HTTP %ld · %@\nAnonymous snapshot only. Links, scripts and remote resources are disabled.",
        (long)response.statusCode, response.URL.absoluteString];
    self.allowsSnapshotDocument = YES;
    [self.webView loadHTMLString:snapshot baseURL:nil];
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    // Allow exactly the in-memory main document; meta refresh, frames, links,
    // forms and downloads never become URLSession or WebKit network requests.
    BOOL snapshot = self.allowsSnapshotDocument && navigationAction.targetFrame.isMainFrame &&
        navigationAction.navigationType == WKNavigationTypeOther &&
        [navigationAction.request.URL.absoluteString isEqualToString:@"about:blank"];
    if (snapshot) self.allowsSnapshotDocument = NO;
    decisionHandler(snapshot ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
    forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures {
    return nil;
}

@end
