// Real UIKit wizard, inert daemon IPC and state. No real container or network.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "RBXSimpleWizardViewController.h"
#import "RBXIdentityViewController.h"
#import "RBXSettingsViewController.h"
#import "RBXProxiesViewController.h"
#import "RBXLauncherViewController.h"
#import "RBXLauncherIPC.h"
#import "RBXSecureConfig.h"
static NSMutableArray *Requests, *Failures;
static NSMutableDictionary *Results;
static NSArray *Rows;
static NSDictionary *Configuration;
static NSUInteger Checks;
static BOOL RejectSend;
@interface NSDictionary (FixtureState)
+ (id)creationDictionaryWithContentsOfFile:(NSString *)path;
@end
@implementation NSDictionary (FixtureState)
+ (id)creationDictionaryWithContentsOfFile:(NSString *)path {
    if ([path isEqual:@"/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist"])
        return @{@"updatedAt":@(NSDate.date.timeIntervalSince1970), @"containers":Rows ?: @[],
            @"configuration":Configuration,
            @"source":@{@"decrypted":@YES}, @"license":@{@"unlocked":@YES}};
    if ([path hasPrefix:@"/var/mobile/"]) return @{};
    return [self creationDictionaryWithContentsOfFile:path];
}
@end
@implementation RBXLauncherIPC
+ (NSString *)sendActionReturningRequestId:(NSString *)action values:(NSDictionary *)values notification:(CFStringRef)notification owner:(NSString *)owner appType:(NSString *)appType {
    if (RejectSend) return nil;
    NSString *identifier = NSUUID.UUID.UUIDString;
    [Requests addObject:[@{@"requestId":identifier,@"action":action,@"values":values,@"owner":owner,@"appType":appType,@"pending":@YES} mutableCopy]];
    return identifier;
}
+ (NSArray *)pendingRequestsForOwner:(NSString *)owner {
    return [Requests filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *r, NSDictionary *b){ return [r[@"owner"] isEqual:owner] && [r[@"pending"] boolValue]; }]];
}
+ (NSDictionary *)requestResultForId:(NSString *)identifier { return identifier ? Results[identifier] : nil; }
+ (void)finishObservingRequestId:(NSString *)identifier owner:(NSString *)owner {
    for (NSMutableDictionary *r in Requests) if ([r[@"requestId"] isEqual:identifier] && [r[@"owner"] isEqual:owner]) r[@"pending"] = @NO;
}
@end
@implementation RBXSecureConfig
+ (NSDictionary *)identityEditorDraftForRequestID:(NSString *)identifier container:(NSString *)container error:(NSError **)error { return nil; }
+ (NSDictionary *)safeSummary { return Configuration; }
@end
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RBXProxiesViewController
- (instancetype)initWithAppType:(NSString *)app { return [super init]; }
@end
@implementation RBXSettingsViewController
- (instancetype)initWithAppType:(NSString *)app proxyMode:(BOOL)proxy { return [super init]; }
@end
@implementation RBXLauncherViewController
- (instancetype)initWithAppType:(NSString *)app advancedMode:(BOOL)advanced { return [super init]; }
@end
@interface RBXSimpleWizardViewController (FixtureActions)
- (void)generate;
- (void)refresh;
- (void)review;
- (void)commitCreation;
- (void)discardPreview;
- (void)resetFailedDraft;
- (void)chooseProxy;
- (void)toggleDetails;
@end
static void Check(BOOL value, NSString *message) { Checks++; if (!value) [Failures addObject:message]; }
static void Pump(void) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.5];
    while (until.timeIntervalSinceNow > 0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static NSDictionary *Draft(id wizard) { return [wizard valueForKey:@"draft"]; }
static BOOL Enabled(id wizard, NSString *key) { return [[wizard valueForKey:key] isEnabled]; }
static NSDictionary *Review(id wizard, NSUInteger revision) {
    return @{@"creationDraftToken":@"9E202F0E-93DE-4EDC-B5C9-989094A4C950",@"creationDraftRevision":@(revision),
        @"containerId":Draft(wizard)[@"container"],@"appType":@"reddit",@"expiresAt":@(NSDate.date.timeIntervalSince1970+280),
        @"review":@{@"marketingName":revision == 1 ? @"iPhone 16" : @"iPhone 15",@"iosVersion":@"18.0",@"country":@"US",@"carrierName":@"Catalog carrier",@"locale":@"en_US",@"timezone":@"America/New_York"}};
}
static void Complete(id wizard, BOOL ok, NSDictionary *details) {
    NSString *identifier = [wizard valueForKey:@"pendingRequestId"];
    NSDictionary *sent = [Requests filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"requestId == %@",identifier]].firstObject;
    Results[identifier] = @{@"requestId":identifier,@"action":sent[@"action"],@"containerId":sent[@"values"][@"container"] ?: @"",@"ok":@(ok),@"state":ok?@"completed":@"failed",@"updatedAt":@(NSDate.date.timeIntervalSince1970-0.1),@"message":ok?@"Fixture completed":@"Fixture rejected",@"details":details ?: @{}};
    [wizard refresh];
}
static RBXSimpleWizardViewController *NewWizard(UINavigationController *nav) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"RBXSimpleWizardDraft"];
    RBXSimpleWizardViewController *wizard = [[RBXSimpleWizardViewController alloc] initWithAppType:@"reddit"];
    [nav setViewControllers:@[wizard] animated:NO]; Pump();
    ((UITextField *)[wizard valueForKey:@"nameField"]).text = @"Research fixture";
    ((UITextField *)[wizard valueForKey:@"countryField"]).text = @"";
    [wizard setValue:@YES forKey:@"proxySelected"];
    [wizard setValue:@{@"proxyHost":Configuration[@"proxyHost"],@"updatedAt":Configuration[@"updatedAt"]} forKey:@"selectedProxyConfiguration"];
    return wizard;
}
static void ChooseProxyAction(RBXSimpleWizardViewController *wizard, NSString *title) {
    UIAlertController *sheet = (id)wizard.presentedViewController;
    UIAlertAction *selected = nil;
    for (UIAlertAction *action in sheet.actions) if ([action.title isEqual:title]) selected = action;
    Check(selected != nil, [@"Proxy action is available: " stringByAppendingString:title]);
    void (^handler)(UIAlertAction *) = [selected valueForKey:@"handler"];
    [sheet dismissViewControllerAnimated:NO completion:nil]; Pump();
    if (handler) handler(selected);
    Pump();
}
static void SetProxy(NSString *host, NSUInteger version) {
    Configuration = @{@"configured":@YES,@"readable":@YES,@"disabled":@NO,@"proxyHost":host,@"updatedAt":@(version)};
}
static void FlowRecovery(UINavigationController *nav) {
    RBXSimpleWizardViewController *w = NewWizard(nav);
    UITextField *name = [w valueForKey:@"nameField"], *country = [w valueForKey:@"countryField"];
    UISegmentedControl *role = [w valueForKey:@"roleControl"];
    name.text = @"Unsent research label"; [name sendActionsForControlEvents:UIControlEventEditingChanged];
    country.text = @"US"; [country sendActionsForControlEvents:UIControlEventEditingChanged];
    role.selectedSegmentIndex = 2; [role sendActionsForControlEvents:UIControlEventValueChanged];
    [nav pushViewController:[UIViewController new] animated:NO]; Pump();
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"RBXSimpleWizardDraft"];
    Check([saved[@"nickname"] isEqual:name.text] && [saved[@"country"] isEqual:@"US"] && [saved[@"role"] isEqual:@"warmup"], @"Unsent form survives navigation to setup without submitting");
    Check(!saved[@"container"] && !saved[@"proxyURL"] && Requests.count == 0, @"Unsent form saves metadata only and sends no work");
    w = [[RBXSimpleWizardViewController alloc] initWithAppType:@"reddit"];
    [nav setViewControllers:@[w] animated:NO]; Pump();
    Check([[[w valueForKey:@"nameField"] text] isEqual:@"Unsent research label"] && [[w valueForKey:@"roleControl"] selectedSegmentIndex] == 2, @"Reopened form restores name and role");
    Check([w respondsToSelector:NSSelectorFromString(@"toggleDetails")], @"Simple creation offers optional Details instead of mandatory technical fields");
    Check([[w valueForKey:@"detailsStack"] isHidden] && [[[w valueForKey:@"defaultsLabel"] text] containsString:@"US"], @"Optional controls start collapsed while chosen defaults remain visible");
    [w toggleDetails];
    Check(![[w valueForKey:@"detailsStack"] isHidden] && Requests.count == 0, @"Details exposes existing country and role fields without changing identity or sending work");
    [NSUserDefaults.standardUserDefaults setObject:@{@"container":@"p-interrupted-preview",@"nickname":@"Interrupted preview",@"country":@"",@"role":@"default",@"stage":@"preparing"} forKey:@"RBXSimpleWizardDraft"];
    w = [[RBXSimpleWizardViewController alloc] initWithAppType:@"reddit"];
    [nav setViewControllers:@[w] animated:NO]; Pump();
    Check(!Draft(w)[@"container"] && Enabled(w,@"generateButton"), @"Interrupted pre-publication prepare recovers without permanently locking form");
    Check([Draft(w)[@"nickname"] isEqual:@"Interrupted preview"] && Requests.count == 0, @"Interrupted preparation preserves input and never creates or retries automatically");
    [NSUserDefaults.standardUserDefaults setObject:@{@"container":@"p-ambiguous-create",@"nickname":@"Uncertain create",@"stage":@"committing"} forKey:@"RBXSimpleWizardDraft"];
    w = [[RBXSimpleWizardViewController alloc] initWithAppType:@"reddit"];
    [nav setViewControllers:@[w] animated:NO]; Pump();
    [w discardPreview]; [w generate];
    Check([Draft(w)[@"container"] isEqual:@"p-ambiguous-create"] && !Enabled(w,@"generateButton") && Requests.count == 0, @"Ambiguous Create is never reset by preparation recovery or discard");

    w = NewWizard(nav); [w setValue:@NO forKey:@"proxySelected"];
    [w chooseProxy]; Pump();
    SetProxy(@"replacement.fixture.invalid",2);
    ChooseProxyAction(w,@"Use configured device proxy");
    Check(![[w valueForKey:@"proxySelected"] boolValue], @"A stale proxy choice cannot select the previous configuration");
    [w chooseProxy]; Pump(); ChooseProxyAction(w,@"Use configured device proxy");
    Check([[w valueForKey:@"proxySelected"] boolValue], @"Current device proxy can be selected");
    [w chooseProxy]; Pump(); ChooseProxyAction(w,@"Cancel");
    Check([[w valueForKey:@"proxySelected"] boolValue] && Requests.count == 0, @"Cancelling proxy choice preserves current selection without preparing anything");
    SetProxy(@"replacement.fixture.invalid",3); [w refresh];
    NSUInteger count = Requests.count; [w generate];
    Check(![[w valueForKey:@"proxySelected"] boolValue] && Requests.count == count, @"Same-host configuration revision change invalidates selection before preparing with unseen credentials");
    // Reset this scenario even on the old implementation, whose Generate
    // incorrectly publishes after an unseen proxy change.
    [Requests removeAllObjects]; [Results removeAllObjects];
    w = NewWizard(nav); [w setValue:@NO forKey:@"proxySelected"];
    [w chooseProxy]; Pump(); ChooseProxyAction(w,@"Manage saved proxies");
    Check([nav.topViewController isKindOfClass:RBXProxiesViewController.class], @"Proxy management opens the actual library controller");
    // An unrelated library edit also advances the configuration revision; it
    // must not be mistaken for an explicit Use proxy action.
    SetProxy(@"replacement.fixture.invalid",4);
    [nav popViewControllerAnimated:NO]; Pump();
    Check(![[w valueForKey:@"proxySelected"] boolValue] && Requests.count == 0, @"Unrelated library edit without selection does not silently choose a proxy");
    [w chooseProxy]; Pump(); ChooseProxyAction(w,@"Manage saved proxies");
    SetProxy(@"library.fixture.invalid",5);
    RBXProxiesViewController *library = (id)nav.topViewController;
    Check(library.didSelectProxy != nil, @"Wizard listens to explicit library selection only");
    if (library.didSelectProxy) library.didSelectProxy();
    [nav popViewControllerAnimated:NO]; Pump();
    Check([[w valueForKey:@"proxySelected"] boolValue] && [[[w valueForKey:@"proxyLabel"] text] containsString:@"library.fixture.invalid"], @"Returning after selecting a saved proxy updates the wizard selection");
    Check([[[w valueForKey:@"nameField"] text] isEqual:@"Research fixture"], @"Proxy setup retains the entered name");
    Configuration = @{@"configured":@NO,@"readable":@YES,@"disabled":@YES,@"proxyHost":@"library.fixture.invalid",@"updatedAt":@6};
    [w refresh]; [w generate];
    Check(![[w valueForKey:@"proxySelected"] boolValue] && Requests.count == 0, @"Disabled device proxy cannot prepare a draft");
    [Requests removeAllObjects]; [Results removeAllObjects]; SetProxy(@"proxy.fixture.invalid",1);

    w = NewWizard(nav); [w generate];
    NSString *pending = [w valueForKey:@"pendingRequestId"];
    [nav pushViewController:[UIViewController new] animated:NO]; Pump();
    Complete(w,YES,Review(w,1));
    NSUInteger beforeResume = Requests.count;
    w = [[RBXSimpleWizardViewController alloc] initWithAppType:@"reddit"];
    [nav setViewControllers:@[w] animated:NO]; Pump(); [w refresh];
    Check([Draft(w)[@"stage"] isEqual:@"review"] && Requests.count == beforeResume, @"Reopened wizard observes pending preparation receipt instead of resubmitting");
    Check([Results[pending][@"action"] isEqual:@"prepareContainer"] && Enabled(w,@"createButton"), @"Resumed preparation remains an unsaved review until explicit Create");
    [w discardPreview]; Complete(w,YES,nil);
    [Requests removeAllObjects]; [Results removeAllObjects];
}
static void Run(UINavigationController *nav) {
    FlowRecovery(nav);
    RBXSimpleWizardViewController *w = NewWizard(nav);
    [w generate];
    Check([Requests.lastObject[@"action"] isEqual:@"prepareContainer"],@"Prepare does not send createContainer");
    Check([Requests.lastObject[@"values"][@"autoRegion"] isEqual:@YES],@"Default preview uses proxy geography");
    Check([Requests.lastObject[@"values"][@"proxyConfigurationUpdatedAt"] isEqual:Configuration[@"updatedAt"]],@"Prepared request binds the selected proxy revision across queue wait");
    Check(!Enabled(w,@"createButton") && !Enabled(w,@"nameField"),@"Pending preparation disables creation and input changes");
    NSUInteger count = Requests.count; [w generate]; [w commitCreation];
    Check(Requests.count == count,@"Repeated taps cannot create during preparation");
    Complete(w,YES,Review(w,1));
    Check(Enabled(w,@"createButton") && Enabled(w,@"reviewButton"),@"Prepared draft supports review and explicit Create");
    Check([w valueForKey:@"createdRow"] == nil && Rows.count == 0,@"Review has no container row");
    Check([Draft(w)[@"stage"] isEqual:@"review"] && Draft(w)[@"profile"] == nil,@"Persisted UI draft contains no authoritative profile");
    Check([[[w valueForKey:@"reviewLabel"] text] containsString:@"nothing created"],@"Preview explains no container exists");
    [w review]; Pump();
    RBXIdentityViewController *editor = (id)nav.topViewController;
    Check([editor isKindOfClass:RBXIdentityViewController.class] && [editor.creationDraftRevision isEqual:@1] && editor.creationDraftToken.length > 0,@"Review opens real editor bound to exact creation token");
    // End the editor's independent load, then simulate returning after a save.
    for (NSMutableDictionary *r in Requests) if ([r[@"owner"] hasPrefix:@"creation-identity:"]) r[@"pending"] = @NO;
    [nav popViewControllerAnimated:NO]; Pump();
    Check([Requests.lastObject[@"action"] isEqual:@"reviewContainerDraft"],@"Returning reloads the daemon-owned draft revision");
    Complete(w,YES,Review(w,2));
    Check([Draft(w)[@"creationDraftRevision"] isEqual:@2] && [[[w valueForKey:@"reviewLabel"] text] containsString:@"iPhone 15"],@"Review shows edited model and latest revision");
    [w commitCreation];
    Check([Requests.lastObject[@"action"] isEqual:@"createContainer"] && [Requests.lastObject[@"values"][@"creationDraftRevision"] isEqual:@2],@"Only explicit Create sends exact reviewed revision");
    Check([Draft(w)[@"stage"] isEqual:@"committing"],@"Commit ownership persists before completion");
    count = Requests.count; [w commitCreation]; [w discardPreview]; [w generate];
    Check(Requests.count == count,@"Pending Create cannot be duplicated, discarded or regenerated");
    Complete(w,NO,nil);
    Check(![[w valueForKey:@"resetButton"] isHidden],@"Exact failed commit with fresh empty inventory offers explicit reset");
    [w resetFailedDraft];
    Check(Draft(w)[@"container"] == nil && Enabled(w,@"generateButton"),@"Safe reset retains metadata without resubmitting");
    Check(Requests.count == count,@"Failed reset never automatically retries provisioning");
    [w generate]; Complete(w,YES,Review(w,1));
    count = Requests.count; [w discardPreview];
    Check([Requests.lastObject[@"action"] isEqual:@"discardContainerDraft"],@"Discard targets an unsaved daemon draft");
    Complete(w,YES,nil);
    Check(!Draft(w)[@"container"] && Requests.count == count+1,@"Discard drops preview without creating or deleting a container");
    [w generate]; Complete(w,NO,nil);
    Check(Enabled(w,@"generateButton") && Draft(w)[@"container"] == nil,@"Failed proxy preparation permits explicit retry without existing state");
    [w generate]; Complete(w,YES,Review(w,1));
    NSMutableDictionary *expired = Draft(w).mutableCopy; expired[@"expiresAt"] = @(NSDate.date.timeIntervalSince1970-1); [w setValue:expired forKey:@"draft"]; [w refresh];
    count = Requests.count; [w commitCreation];
    Check(!Enabled(w,@"createButton") && Requests.count == count,@"Expired preview cannot create");
    [w discardPreview]; Complete(w,NO,nil);
    Check(Draft(w)[@"container"] == nil,@"Expired daemon token can safely be forgotten");
    RejectSend = YES; [w generate];
    Check(![[w valueForKey:@"pendingRequestId"] length] && Draft(w)[@"container"] == nil,@"Failed prepare publication keeps only editable metadata");
    RejectSend = NO;
    [w generate]; Complete(w,YES,Review(w,1)); [w commitCreation];
    NSString *cid = Draft(w)[@"container"];
    Rows = @[@{@"id":cid,@"identityEditor":Review(w,1)[@"review"]}];
    Complete(w,YES,nil);
    Check([Draft(w)[@"stage"] isEqual:@"committed"] && [w valueForKey:@"createdRow"] != nil,@"Successful commit resolves to real inventory row");
    Check([[w valueForKey:@"createButton"] isHidden] && Enabled(w,@"reviewButton"),@"Created container has review but no repeated Create");
    count=Requests.count; [w discardPreview];
    Check(Requests.count == count,@"Discard preview never deletes an existing container");
}
@interface FixtureApp : UIResponder <UIApplicationDelegate>
@property UIWindow *window;
@end
@implementation FixtureApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    Requests=[NSMutableArray array];Failures=[NSMutableArray array];Results=[NSMutableDictionary dictionary];Rows=@[];SetProxy(@"proxy.fixture.invalid",1);
    method_exchangeImplementations(class_getClassMethod(NSDictionary.class,@selector(dictionaryWithContentsOfFile:)),class_getClassMethod(NSDictionary.class,@selector(creationDictionaryWithContentsOfFile:)));
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:[UIViewController new]];
    self.window.rootViewController=nav;[self.window makeKeyAndVisible];
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:NO block:^(NSTimer *timer){
        @try { Run(nav); } @catch(NSException *e) {[Failures addObject:[NSString stringWithFormat:@"%@ %@",e.name,e.reason]];}
        NSDictionary *result=@{@"ok":@(Failures.count==0),@"checks":@(Checks),@"failures":Failures,@"scope":@"Actual UIKit wizard with inert IPC; no device isolation or network proof"};
        NSString *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        [[NSJSONSerialization dataWithJSONObject:result options:0 error:nil] writeToFile:[docs stringByAppendingPathComponent:@"identity-result.json"] atomically:YES];
    }];return YES;
}
@end
int main(int argc,char *argv[]){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(FixtureApp.class));}}
