#import "SBUpdateService.h"
#import <CoreFoundation/CoreFoundation.h>

NSString *const SBUpdateStateDidChangeNotification=@"com.socialbox.updates.stateChanged";
static NSString *const SBUpdateEndpoint=@"https://redditspoof.vercel.app/api/releases/socialbox/latest";
static const NSUInteger SBUpdateMaximumBytes=64*1024;
static BOOL SBUpdateString(id value,NSUInteger max) { return [value isKindOfClass:NSString.class] && [value length]>0 && [value length]<=max; }
static BOOL SBUpdateMatches(NSString *value,NSString *pattern) {
    if(![value isKindOfClass:NSString.class])return NO;
    NSRegularExpression *expression=[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    return [expression numberOfMatchesInString:value options:0 range:NSMakeRange(0,value.length)]==1;
}
static BOOL SBUpdateInteger(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [value doubleValue]==[value longLongValue] && [value longLongValue]>0 && [value longLongValue]<=2147483647;
}
NSNumber *SBUpdateSequence(NSString *version) {
    if(!SBUpdateMatches(version,@"\\A3\\.1\\.0-1\\+socialbox\\.[1-9][0-9]{0,9}\\z"))return nil;
    NSNumber *number=@([[version componentsSeparatedByString:@"."].lastObject longLongValue]);
    return SBUpdateInteger(number)?number:nil;
}
NSURL *SBUpdatePageURL(void) { return [NSURL URLWithString:@"https://redditspoof.vercel.app/updates"]; }
static void SBUpdateTryURL(NSArray<NSURL *> *urls, NSUInteger index, SBUpdateURLOpener opener, void (^completion)(BOOL)) {
    if(index>=urls.count) { completion(NO);return; }
    __block BOOL answered=NO;
    opener(urls[index],^(BOOL opened){
        if(answered)return;
        answered=YES;
        if(opened)completion(YES);
        else SBUpdateTryURL(urls,index+1,opener,completion);
    });
}
void SBUpdateOpenRelease(NSDictionary *snapshot, SBUpdateURLOpener opener, void (^completion)(BOOL)) {
    NSCAssert(NSThread.isMainThread,@"Update handoff belongs to the main thread");
    if(![snapshot[@"state"] isEqual:@"available"]) { completion(NO);return; }
    // Schemes follow Sileo's AppDelegate source handler and Zebra's source
    // handler. Never hand a package URL, access key or manifest URL to an app.
    SBUpdateTryURL(@[[NSURL URLWithString:@"sileo://source/https://redditspoof.vercel.app/apt/socialbox/"],
                     [NSURL URLWithString:@"zbra://sources/add/https://redditspoof.vercel.app/apt/socialbox/"],
                     SBUpdatePageURL()],0,opener,completion);
}
static NSDictionary *SBUpdateResult(NSString *state,NSString *reason) { return @{@"state":state,@"reason":reason}; }
NSDictionary *SBUpdateEvaluateManifest(id raw,NSString *installedVersion,NSString *systemVersion) {
    if(!SBUpdateSequence(installedVersion))return SBUpdateResult(@"unavailable",@"installed-version");
    if(![raw isKindOfClass:NSDictionary.class])return SBUpdateResult(@"unavailable",@"manifest");
    NSDictionary *manifest=raw;id available=manifest[@"available"];
    if(!SBUpdateInteger(manifest[@"schemaVersion"]) || [manifest[@"schemaVersion"] integerValue]!=1 ||
       ![manifest[@"channel"] isEqual:@"stable"] || ![available isKindOfClass:NSNumber.class] ||
       CFGetTypeID((__bridge CFTypeRef)available)!=CFBooleanGetTypeID())return SBUpdateResult(@"unavailable",@"manifest");
    if(![available boolValue])return SBUpdateResult(@"no-release",@"no-stable-release");
    NSString *version=manifest[@"packageVersion"],*minimum=manifest[@"minimumIOS"];
    NSNumber *sequence=SBUpdateSequence(version);NSArray *predecessors=manifest[@"supportedFrom"];
    if(![manifest[@"package"] isEqual:@"com.socialbox"] || !sequence || !SBUpdateInteger(manifest[@"sequence"]) ||
       ![sequence isEqualToNumber:manifest[@"sequence"]] || ![manifest[@"architecture"] isEqual:@"iphoneos-arm64"] ||
       !SBUpdateMatches(minimum,@"\\A[0-9]{1,2}\\.[0-9]{1,2}(\\.[0-9]{1,2})?\\z") ||
       !SBUpdateMatches(systemVersion,@"\\A[0-9]{1,2}\\.[0-9]{1,2}(\\.[0-9]{1,2})?\\z") ||
       ![predecessors isKindOfClass:NSArray.class] || !predecessors.count || predecessors.count>64 ||
       ![manifest[@"notes"] isKindOfClass:NSString.class] || [manifest[@"notes"] length]>2000 ||
       !SBUpdateMatches(manifest[@"sha256"],@"\\A[a-f0-9]{64}\\z") ||
       ![manifest[@"updateURL"] isEqual:SBUpdatePageURL().absoluteString] || !SBUpdateString(manifest[@"publishedAt"],40))
        return SBUpdateResult(@"unavailable",@"manifest");
    NSISO8601DateFormatter *dates=[NSISO8601DateFormatter new];dates.formatOptions=NSISO8601DateFormatWithInternetDateTime;
    NSDate *published=[dates dateFromString:manifest[@"publishedAt"]];
    if(!published) { dates.formatOptions|=NSISO8601DateFormatWithFractionalSeconds;published=[dates dateFromString:manifest[@"publishedAt"]]; }
    if(!published)return SBUpdateResult(@"unavailable",@"manifest-date");
    NSMutableSet *seen=[NSMutableSet set];
    for(id predecessor in predecessors) {
        NSNumber *old=SBUpdateSequence(predecessor);
        if(!old || [old compare:sequence]!=NSOrderedAscending || [seen containsObject:predecessor])return SBUpdateResult(@"unavailable",@"manifest-predecessors");
        [seen addObject:predecessor];
    }
    NSString *state=@"current",*reason=@"stable-not-newer";
    if([sequence compare:SBUpdateSequence(installedVersion)]==NSOrderedDescending) {
        BOOL compatible=[systemVersion compare:minimum options:NSNumericSearch]!=NSOrderedAscending && [predecessors containsObject:installedVersion];
        state=compatible?@"available":@"incompatible";reason=compatible?@"supported-upgrade":@"upgrade-path";
    }
    return @{@"state":state,@"reason":reason,@"packageVersion":version,@"notes":manifest[@"notes"],@"publishedAt":manifest[@"publishedAt"]};
}

@interface SBUpdateService () <NSURLSessionDataDelegate>
@property(nonatomic,readwrite,copy) NSDictionary *snapshot;
@property(nonatomic,copy) NSString *installedVersion,*systemVersion;
@property(nonatomic,strong) NSURLSessionConfiguration *configuration;
@property(nonatomic,strong) NSUserDefaults *defaults;
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,strong) NSMutableData *body;
@property(nonatomic) BOOL responseAccepted;
@end
@implementation SBUpdateService
+ (instancetype)sharedService {
    static SBUpdateService *service;static dispatch_once_t once;
    dispatch_once(&once,^{
        service=[SBUpdateService new];service.installedVersion=[NSBundle.mainBundle objectForInfoDictionaryKey:@"SocialBoxBuild"] ?: @"";
        NSOperatingSystemVersion os=NSProcessInfo.processInfo.operatingSystemVersion;
        service.systemVersion=[NSString stringWithFormat:@"%ld.%ld.%ld",(long)os.majorVersion,(long)os.minorVersion,(long)os.patchVersion];
        service.defaults=[[NSUserDefaults alloc] initWithSuiteName:@"com.socialbox.updates"];
    });return service;
}
- (instancetype)init {
    if((self=[super init])) {
        _snapshot=SBUpdateResult(@"unchecked",@"not-checked");_installedVersion=@"";_systemVersion=@"";
        _configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
        _configuration.HTTPCookieStorage=nil;_configuration.HTTPShouldSetCookies=NO;_configuration.URLCache=nil;
        _configuration.URLCredentialStorage=nil;_configuration.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
        _configuration.timeoutIntervalForRequest=12;_configuration.timeoutIntervalForResource=20;
        _configuration.HTTPAdditionalHeaders=@{@"Accept":@"application/json",@"User-Agent":@"SocialBox-Updates/1"};
    }return self;
}
#if SB_UPDATE_TESTING
- (instancetype)initWithInstalledVersion:(NSString *)version systemVersion:(NSString *)systemVersion configuration:(NSURLSessionConfiguration *)configuration defaults:(NSUserDefaults *)defaults {
    if((self=[self init])) { _installedVersion=[version copy];_systemVersion=[systemVersion copy];_configuration.protocolClasses=configuration.protocolClasses;_defaults=defaults; }return self;
}
#endif
- (void)publish:(NSDictionary *)value {
    NSAssert(NSThread.isMainThread,@"Update state belongs to the main thread");
    NSMutableDictionary *snapshot=[value mutableCopy];snapshot[@"installedVersion"]=self.installedVersion;
    if(![value[@"state"] isEqual:@"unchecked"] && ![value[@"state"] isEqual:@"checking"])snapshot[@"checkedAt"]=@(NSDate.date.timeIntervalSince1970);
    self.snapshot=snapshot;[NSNotificationCenter.defaultCenter postNotificationName:SBUpdateStateDidChangeNotification object:self];
}
- (void)checkAutomaticallyIfDue {
    NSAssert(NSThread.isMainThread,@"Lifecycle checks belong to the main thread");
    NSTimeInterval previous=[self.defaults doubleForKey:@"lastAttempt"],now=NSDate.date.timeIntervalSince1970;
    if(previous>0 && now>=previous && now-previous<6*60*60)return;
    [self checkForUpdates];
}
- (void)checkForUpdates {
    NSAssert(NSThread.isMainThread,@"Update actions belong to the main thread");
    if(self.task)return;
    if(!SBUpdateSequence(self.installedVersion)) { [self publish:SBUpdateResult(@"unavailable",@"installed-version")];return; }
    [self.defaults setDouble:NSDate.date.timeIntervalSince1970 forKey:@"lastAttempt"];
    self.body=[NSMutableData data];self.responseAccepted=NO;
    self.session=[NSURLSession sessionWithConfiguration:self.configuration delegate:self delegateQueue:NSOperationQueue.mainQueue];
    NSURLRequest *request=[NSURLRequest requestWithURL:[NSURL URLWithString:SBUpdateEndpoint] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12];
    self.task=[self.session dataTaskWithRequest:request];[self publish:SBUpdateResult(@"checking",@"request")];[self.task resume];
}
- (void)finish:(NSDictionary *)value session:(NSURLSession *)session {
    if(session!=self.session)return;
    [self.session invalidateAndCancel];self.task=nil;self.session=nil;self.body=nil;self.responseAccepted=NO;[self publish:value];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    if(session!=self.session || task!=self.task) { completion(NSURLSessionResponseCancel);return; }
    BOOL accepted=[response isKindOfClass:NSHTTPURLResponse.class] &&
        [(NSHTTPURLResponse *)response statusCode]==200 && [response.URL.absoluteString isEqual:SBUpdateEndpoint] &&
        [response.MIMEType.lowercaseString isEqual:@"application/json"] && response.expectedContentLength<=(long long)SBUpdateMaximumBytes;
    self.responseAccepted=accepted;completion(accepted?NSURLSessionResponseAllow:NSURLSessionResponseCancel);
    if(!accepted)[self finish:SBUpdateResult(@"unavailable",@"response") session:session];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if(session!=self.session || task!=self.task || !self.responseAccepted)return;
    if(data.length>SBUpdateMaximumBytes-self.body.length) { [self finish:SBUpdateResult(@"unavailable",@"response-size") session:session];return; }
    [self.body appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if(session!=self.session || task!=self.task)return;
    id manifest=(!error && self.responseAccepted)?[NSJSONSerialization JSONObjectWithData:self.body options:0 error:nil]:nil;
    [self finish:manifest?SBUpdateEvaluateManifest(manifest,self.installedVersion,self.systemVersion):SBUpdateResult(@"unavailable",@"request") session:session];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completion {
    (void)task;(void)response;(void)request;completion(nil);[self finish:SBUpdateResult(@"unavailable",@"redirect") session:session];
}
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition,NSURLCredential * _Nullable))completion {
    (void)session;
    // Normal OS TLS trust only. Never supply credentials or accept a custom trust.
    completion([challenge.protectionSpace.authenticationMethod isEqual:NSURLAuthenticationMethodServerTrust]?NSURLSessionAuthChallengePerformDefaultHandling:NSURLSessionAuthChallengeCancelAuthenticationChallenge,nil);
}
@end

#if !SB_UPDATE_FOUNDATION_ONLY
#import "SBInterfaceCopy.h"
#import "SBDesign.h"
#import "SBBackendAdapter.h"
#import <objc/runtime.h>
static void SBUpdateOpenFromController(UIViewController *owner) {
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive ||
       !owner.isViewLoaded || !owner.view.window || owner.presentedViewController)return;
    __weak UIViewController *weak=owner;
    SBUpdateOpenRelease(SBUpdateService.sharedService.snapshot,^(NSURL *url,void (^reply)(BOOL)){
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:reply];
    },^(BOOL opened){
        if(opened || !weak.view.window || weak.presentedViewController)return;
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:SBUIText(@"updates.title")
            message:SBUIText(@"updates.openFailed") preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:SBUIText(@"common.close") style:UIAlertActionStyleCancel handler:nil]];
        [weak presentViewController:alert animated:YES completion:nil];
    });
}
static NSString *SBUpdateStatusText(NSDictionary *snapshot) {
    NSString *state=snapshot[@"state"];
    if([state isEqual:@"checking"])return SBUIText(@"updates.checking");
    if([state isEqual:@"available"])return SBUIText(@"updates.available");
    if([state isEqual:@"current"])return SBUIText(@"updates.current");
    if([state isEqual:@"incompatible"])return SBUIText(@"updates.incompatible");
    if([state isEqual:@"no-release"])return SBUIText(@"updates.noRelease");
    if([state isEqual:@"unavailable"])return SBUIText(@"updates.unavailable");
    return SBUIText(@"updates.unchecked");
}
@interface SBAppUpdatesViewController ()
@property(nonatomic,strong) UILabel *statusLabel,*versionLabel,*notesLabel;
@property(nonatomic,strong) UIButton *checkButton,*updateButton;
@property(nonatomic,strong) id observer;
@property(nonatomic) BOOL manualCheckPending;
@end
@implementation SBAppUpdatesViewController
- (void)viewDidLoad {
    [super viewDidLoad];self.title=SBUIText(@"updates.title");self.view.backgroundColor=SBInk();self.view.tintColor=SBAccent();
    UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:scroll];
    self.statusLabel=SBLabel(@"",22,UIFontWeightSemibold);self.statusLabel.accessibilityIdentifier=@"socialbox.updates.status";
    self.versionLabel=SBLabel(@"",14,UIFontWeightRegular);self.notesLabel=SBLabel(@"",15,UIFontWeightRegular);
    __weak typeof(self) weak=self;
    self.checkButton=SBButton(SBUIText(@"updates.check"),@"connection",YES,^{
        weak.manualCheckPending=YES;[SBUpdateService.sharedService checkForUpdates];
    });self.checkButton.accessibilityIdentifier=@"socialbox.updates.check";
    self.updateButton=SBButton(SBUIText(@"updates.openManager"),@"import",NO,^{SBUpdateOpenFromController(weak);});
    self.updateButton.accessibilityIdentifier=@"socialbox.updates.open";
    UIButton *instructions=SBButton(SBUIText(@"updates.open"),@"more",NO,^{
        [UIApplication.sharedApplication openURL:SBUpdatePageURL() options:@{} completionHandler:^(BOOL opened){
            if(!opened)weak.statusLabel.text=SBUIText(@"updates.openFailed");
        }];
    });instructions.accessibilityIdentifier=@"socialbox.updates.instructions";
    UIStackView *body=[[UIStackView alloc] initWithArrangedSubviews:@[self.statusLabel,self.versionLabel,self.notesLabel,
        SBLabel(SBUIText(@"updates.preservation"),14,UIFontWeightRegular),self.checkButton,self.updateButton,instructions]];
    body.axis=UILayoutConstraintAxisVertical;body.spacing=16;body.translatesAutoresizingMaskIntoConstraints=NO;[scroll addSubview:body];
    [NSLayoutConstraint activateConstraints:@[[scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],[body.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],[body.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],[body.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],[body.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],[body.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]]];
    self.observer=[NSNotificationCenter.defaultCenter addObserverForName:SBUpdateStateDidChangeNotification object:SBUpdateService.sharedService queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){[weak refresh];}];
    [self refresh]; // Read current state only; opening the page never checks.
}
- (void)refresh {
    NSDictionary *snapshot=SBUpdateService.sharedService.snapshot;NSString *installed=[NSBundle.mainBundle objectForInfoDictionaryKey:@"SocialBoxBuild"] ?: SBUIText(@"updates.unknownVersion");
    self.statusLabel.text=SBUpdateStatusText(snapshot);self.versionLabel.text=[NSString stringWithFormat:SBUIText(@"updates.installed"),installed];
    NSString *published=snapshot[@"packageVersion"],*notes=snapshot[@"notes"];
    self.notesLabel.text=published?[NSString stringWithFormat:@"%@\n%@",published,notes ?: @""]:@"";self.notesLabel.hidden=!published;
    self.checkButton.enabled=![snapshot[@"state"] isEqual:@"checking"];
    self.updateButton.hidden=![snapshot[@"state"] isEqual:@"available"];
    if(self.manualCheckPending && ![snapshot[@"state"] isEqual:@"checking"]) {
        self.manualCheckPending=NO;
        if([snapshot[@"state"] isEqual:@"available"])SBUpdateOpenFromController(self);
    }
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated];self.manualCheckPending=NO; }
- (void)dealloc { if(_observer)[NSNotificationCenter.defaultCenter removeObserver:_observer]; }
@end

@interface SBUpdateLifecycle : NSObject
@property(nonatomic,weak) UITabBarController *host;
@property(nonatomic,strong) id activeObserver,stateObserver;
@property(nonatomic,copy) NSString *lastPromptVersion;
- (BOOL)isVisibleAdmittedShell;
- (void)offerAvailableUpdate;
@end
static UIViewController *SBUpdateRoot(UIViewController *controller) {
    return [controller isKindOfClass:UINavigationController.class]?((UINavigationController *)controller).viewControllers.firstObject:controller;
}
static BOOL SBUpdateAdmittedShell(UITabBarController *tabs) {
    if(!tabs || tabs.viewControllers.count!=5)return NO;
    NSMutableSet *roles=[NSMutableSet set];
    for(UIViewController *entry in tabs.viewControllers)[roles addObject:@(SBBackendScreen(SBUpdateRoot(entry)))];
    return [roles isEqual:[NSSet setWithArray:@[@(SBScreenHome),@(SBScreenContainers),@(SBScreenLocation),@(SBScreenProxies),@(SBScreenSettings)]]];
}
@implementation SBUpdateLifecycle
- (BOOL)isVisibleAdmittedShell {
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive || !SBUpdateAdmittedShell(self.host) || !self.host.isViewLoaded || !self.host.view.window)return NO;
    UIViewController *root=self.host.view.window.rootViewController;
    if(root!=self.host)return NO; // Unknown containment is not admission.
    return !root.presentedViewController;
}
- (void)offerAvailableUpdate {
    NSDictionary *snapshot=SBUpdateService.sharedService.snapshot;
    if(![self isVisibleAdmittedShell] || ![snapshot[@"state"] isEqual:@"available"] || [self.lastPromptVersion isEqual:snapshot[@"packageVersion"]])return;
    UIViewController *selected=self.host.selectedViewController;
    UIViewController *visible=[selected isKindOfClass:UINavigationController.class]?((UINavigationController *)selected).topViewController:selected;
    // Never interrupt a form, a confirmation, or an explicitly opened update page.
    if(visible!=SBUpdateRoot(selected) || visible.presentedViewController || visible.view.window!=self.host.view.window)return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:SBUIText(@"updates.available") message:[NSString stringWithFormat:@"%@\n\n%@",snapshot[@"packageVersion"],SBUIText(@"updates.preservation")] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:SBUIText(@"updates.later") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:SBUIText(@"updates.openManager") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){
        [visible dismissViewControllerAnimated:YES completion:^{SBUpdateOpenFromController(visible);}];
    }]];
    self.lastPromptVersion=snapshot[@"packageVersion"];[visible presentViewController:alert animated:YES completion:nil];
}
- (void)dealloc {
    if(_activeObserver)[NSNotificationCenter.defaultCenter removeObserver:_activeObserver];
    if(_stateObserver)[NSNotificationCenter.defaultCenter removeObserver:_stateObserver];
}
@end
void SBUpdateObserveAdmittedWorkspace(UIViewController *owner) {
    if(!NSThread.isMainThread)return;
    UITabBarController *tabs=owner.tabBarController;
    static char key;
    if(!SBUpdateAdmittedShell(tabs) || objc_getAssociatedObject(tabs,&key))return;
    SBUpdateLifecycle *observer=[SBUpdateLifecycle new];observer.host=tabs;objc_setAssociatedObject(tabs,&key,observer,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak SBUpdateLifecycle *weak=observer;
    observer.activeObserver=[NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){
        if(![weak isVisibleAdmittedShell])return;
        [SBUpdateService.sharedService checkAutomaticallyIfDue];[weak offerAvailableUpdate];
    }];
    observer.stateObserver=[NSNotificationCenter.defaultCenter addObserverForName:SBUpdateStateDidChangeNotification object:SBUpdateService.sharedService queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){[weak offerAvailableUpdate];}];
    // No request here. Only a later application-active event or explicit user
    // Check action can request metadata. Rendering is side-effect free.
}
#endif
