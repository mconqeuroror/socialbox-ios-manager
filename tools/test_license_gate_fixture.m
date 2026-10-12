// Actual root/license UIKit with synthetic publication and inert IPC/Keychain.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "RBXLauncherAppDelegate.h"
#import "RBXLicenseViewController.h"
#import "RBXLauncherIPC.h"
#import "RBXPasscodeStore.h"
#import "RBXSecureConfig.h"
#import "RBXProxyLibrary.h"
#import "RBXWorkspaceNavigationController.h"
static NSDictionary *publication;
static BOOL passcodeConfigured;
static NSMutableArray *requests;
static NSDictionary *Grant(void) {
    double now=NSDate.date.timeIntervalSince1970;
    return @{@"updatedAt":@(now),@"license":@{@"unlocked":@YES,@"paired":@YES,@"expiresAt":@(now+3600)},@"containers":@[],@"networkState":@"closed"};
}
@interface NSDictionary (GateFixture)
+ (id)gateDictionaryWithContentsOfFile:(NSString *)path;
@end
@implementation NSDictionary (GateFixture)
+ (id)gateDictionaryWithContentsOfFile:(NSString *)path {
    if([path isEqual:@"/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist"])return publication;
    if([path hasPrefix:@"/var/mobile/"])return @{};
    return [self gateDictionaryWithContentsOfFile:path];
}
@end
@implementation RBXLauncherIPC
+ (NSString *)sendActionReturningRequestId:(NSString *)action values:(NSDictionary *)values notification:(CFStringRef)n owner:(NSString *)owner appType:(NSString *)appType {
    [requests addObject:@{@"action":action,@"values":values ?: @{},@"owner":owner ?: @"",@"appType":appType ?: @""}];return NSUUID.UUID.UUIDString;
}
+ (NSString *)sendActionReturningRequestId:(NSString *)action values:(NSDictionary *)values notification:(CFStringRef)n owner:(NSString *)owner {return [self sendActionReturningRequestId:action values:values notification:n owner:owner appType:@"reddit"];}
+ (NSArray *)pendingRequestsForOwner:(NSString *)owner {return @[];}
+ (NSDictionary *)requestResultForId:(NSString *)request {return nil;}
+ (void)finishObservingRequestId:(NSString *)request owner:(NSString *)owner {}
+ (void)migrateLegacyRequestStateIfNeeded {}
+ (NSDictionary *)legacySourceImportNotice {return nil;}
@end
@implementation RBXPasscodeStore
+ (BOOL)hasPasscode {return passcodeConfigured;}
@end
@implementation RBXSecureConfig
+ (NSDictionary *)safeSummary {return @{};}
+ (NSDictionary *)rotationConfiguration:(NSError **)error {return @{};}
+ (NSString *)accessKey:(NSError **)error {return nil;}
@end
@implementation RBXProxyLibrary
+ (NSArray *)entries:(NSError **)error {return @[];}
+ (NSString *)selectedIdentifier:(NSError **)error {return nil;}
@end
@interface RBXLauncherAppDelegate (GateActions)
- (void)refreshLicenseGate;
@end
@interface LicenseGateTestDelegate : RBXLauncherAppDelegate
@property NSMutableArray *failures;
@property NSUInteger checks;
@property UIViewController *retiredRoot;
@property UIAlertController *retiredAlert;
@end
static void Walk(UIView *v, NSMutableArray *views) {if(!v)return;[views addObject:v];for(UIView *child in v.subviews)Walk(child,views);}
@implementation LicenseGateTestDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.failures=[NSMutableArray array];requests=[NSMutableArray array];publication=nil;
    method_exchangeImplementations(class_getClassMethod(NSDictionary.class,@selector(dictionaryWithContentsOfFile:)),class_getClassMethod(NSDictionary.class,@selector(gateDictionaryWithContentsOfFile:)));
    BOOL result=[super application:application didFinishLaunchingWithOptions:options];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_main_queue(),^{[self step:0];});return result;
}
- (void)check:(BOOL)ok message:(NSString *)message {self.checks++;if(!ok)[self.failures addObject:message];}
- (BOOL)isActivationRoot {
    UIViewController *root=self.window.rootViewController;
    if(![root isKindOfClass:UINavigationController.class])return NO;
    UINavigationController *nav=(id)root;
    return nav.viewControllers.count==1&&[nav.topViewController isKindOfClass:RBXLicenseViewController.class];
}
- (void)checkLocked:(NSString *)label {
    [self.window layoutIfNeeded];
    [self check:[self isActivationRoot] message:[label stringByAppendingString:@": license is the whole root"]];
    NSMutableArray *views=[NSMutableArray array];Walk(self.window,views);
    NSUInteger fields=0,buttons=0;BOOL cleanHierarchy=YES,correctFields=YES,correctButtons=YES;
    for(UIView *v in views) {
        cleanHierarchy &= ![v isKindOfClass:UITabBar.class]&&![v isKindOfClass:UISegmentedControl.class];
        if([v isKindOfClass:UITextField.class]) {
            UITextField *field=(id)v;fields++;
            correctFields &= [field.placeholder isEqual:@"License key"]&&field.secureTextEntry;
        }
        if([v isKindOfClass:UIButton.class]&&!v.hidden) {
            UIButton *button=(id)v;if(button.currentTitle.length){buttons++;correctButtons &= [button.currentTitle isEqual:@"Activate"];}
        }
    }
    [self check:cleanHierarchy message:[label stringByAppendingString:@": no tabs/app selector in window hierarchy"]];
    [self check:correctFields&&correctButtons message:[label stringByAppendingString:@": only secure license input and activation action"]];
    [self check:fields==1&&buttons==1 message:[label stringByAppendingString:@": exactly one key field and activation button"]];
    if([self isActivationRoot]) {
        UINavigationController *nav=(id)self.window.rootViewController;
        [self check:nav.navigationBarHidden&&!nav.interactivePopGestureRecognizer.enabled message:[label stringByAppendingString:@": no back/swipe escape"]];
    }
}
- (void)snapshot:(NSString *)name {
    [self.window layoutIfNeeded];UIGraphicsImageRenderer *r=[[UIGraphicsImageRenderer alloc]initWithBounds:self.window.bounds];
    UIImage *image=[r imageWithActions:^(UIGraphicsImageRendererContext *ctx){[self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:YES];}];
    [UIImagePNGRepresentation(image) writeToFile:[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
}
- (void)finish {
    NSDictionary *result=@{@"ok":@(self.failures.count==0),@"checks":@(self.checks),@"failures":self.failures,@"evidence":@"Actual root UIKit; synthetic publication and inert IPC. No license bypass, real keys, activation or device isolation claims."};
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil]writeToFile:[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"license-gate-result.json"] atomically:YES];
}
- (void)step:(NSUInteger)step {
    if(step==0) {
        [self checkLocked:@"Missing publication"];
        [self check:requests.count==0 message:@"Unlicensed cold launch does not construct workspace or send its refresh IPC"];
        [self snapshot:@"01-activation-only"];
        if(![self respondsToSelector:@selector(refreshLicenseGate)]||![self isActivationRoot]){[self finish];return;}
        RBXLicenseViewController *license=(id)((UINavigationController *)self.window.rootViewController).topViewController;
        [(UITextField *)[license valueForKey:@"keyField"] setText:@"synthetic-draft"];
        [self refreshLicenseGate];
        [self check:[((UITextField *)[license valueForKey:@"keyField"]).text isEqual:@"synthetic-draft"] message:@"Local polling preserves unfinished key entry"];
        [self check:![self application:UIApplication.sharedApplication openURL:[NSURL URLWithString:@"socialbox://open/facebook"] options:@{}] message:@"Unlicensed deep link cannot construct Facebook"];
        [self check:requests.count==0 message:@"Rejected deep link does not send IPC"];
        publication=Grant();[self refreshLicenseGate];
    } else if(step==1) {
        [self check:![self isActivationRoot]&&[self.window.rootViewController respondsToSelector:NSSelectorFromString(@"openSharedFacebook")] message:@"Only a fresh valid grant admits workspace"];
        UITabBarController *tabs=[self.window.rootViewController valueForKey:@"redditWorkspace"];
        [self check:tabs.viewControllers.count==3 message:@"Licensed workspace has exactly three sections"];
        [self check:[[tabs.viewControllers valueForKeyPath:@"tabBarItem.title"] isEqual:@[@"Containers",@"Connection",@"Settings"]]
            message:@"Independent source workspace uses the agreed English navigation"];
        RBXLicenseViewController *account=[[RBXLicenseViewController alloc] initWithLicenseState:nil];
        [account loadViewIfNeeded];[account viewWillAppear:NO];
        [self check:[[(UILabel *)[account valueForKey:@"stateLabel"] text] isEqual:@"Device access is active"] message:@"Detailed Account reads fresh publication when opened without injected state"];
        [account viewDidDisappear:NO];
        [self check:[requests filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"action == 'activateLicense' OR action == 'validateLicense'"]].count==0 message:@"Gate never sends automatic activation/validation"];
        UISegmentedControl *selector=[self.window.rootViewController valueForKey:@"appSelector"];selector.selectedSegmentIndex=1;[selector sendActionsForControlEvents:UIControlEventValueChanged];
        self.retiredRoot=self.window.rootViewController;
        self.retiredAlert=[UIAlertController alertControllerWithTitle:@"Synthetic private sheet" message:@"Must disappear on revoke" preferredStyle:UIAlertControllerStyleAlert];
        [self.retiredAlert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
        [self.retiredRoot presentViewController:self.retiredAlert animated:NO completion:nil];
    } else if(step==2) {
        publication=@{@"updatedAt":@(NSDate.date.timeIntervalSince1970),@"license":@{@"unlocked":@NO,@"status":@"revoked"}};
        [self refreshLicenseGate];
    } else if(step==3) {
        [self checkLocked:@"Revoked from Facebook and sheet"];
        [self check:self.retiredRoot.view.window==nil&&self.retiredAlert.view.window==nil message:@"Revocation removes previous app tree and modal from visible window"];
        UITabBarController *retiredTabs=[self.retiredRoot valueForKey:@"redditWorkspace"];
        [self check:![(id<UITabBarControllerDelegate>)self tabBarController:retiredTabs shouldSelectViewController:retiredTabs.viewControllers.lastObject] message:@"Late retired Settings selection is rejected while unlicensed"];
        [self snapshot:@"02-revoked-no-workspace"];
        self.retiredRoot=nil;self.retiredAlert=nil;
        for(NSString *scenario in @[@"expired",@"stale",@"future",@"malformed",@"missing-expiry"]) {
            NSMutableDictionary *state=[Grant() mutableCopy],*license=[state[@"license"] mutableCopy];double now=NSDate.date.timeIntervalSince1970;
            if([scenario isEqual:@"expired"])license[@"expiresAt"]=@(now-1);
            if([scenario isEqual:@"stale"])state[@"updatedAt"]=@(now-60);
            if([scenario isEqual:@"future"])state[@"updatedAt"]=@(now+60);
            if([scenario isEqual:@"malformed"])license[@"unlocked"]=@"yes";
            if([scenario isEqual:@"missing-expiry"])[license removeObjectForKey:@"expiresAt"];
            state[@"license"]=license;publication=state;[self refreshLicenseGate];[self check:[self isActivationRoot] message:[scenario stringByAppendingString:@" cannot unlock root"]];
        }
        publication=Grant();[self refreshLicenseGate];
    } else if(step==4) {
        [self check:![self isActivationRoot] message:@"Reactivation reconstructs a licensed workspace"];
        UIViewController *root=self.window.rootViewController;
        UISegmentedControl *selector=[root valueForKey:@"appSelector"];
        [self check:selector.selectedSegmentIndex==0 message:@"Reactivation does not resurrect retired Facebook or private dialogs"];
        UITabBarController *tabs=[root valueForKey:@"redditWorkspace"];tabs.selectedIndex=3;
        [self applicationWillResignActive:UIApplication.sharedApplication];
        UIView *cover=[self valueForKey:@"privacyCover"];
        [self check:cover.superview==self.window&&self.window.subviews.lastObject==cover&&root.view.accessibilityElementsHidden message:@"Background cover hides every tab and VoiceOver content"];
        [self snapshot:@"03-background-privacy"];
        publication=nil;
        [self applicationDidBecomeActive:UIApplication.sharedApplication];
        [self checkLocked:@"Return with missing grant"];
        [self check:[self valueForKey:@"privacyCover"]==nil message:@"Foreground removes cover only after choosing locked root"];
        publication=Grant();[self refreshLicenseGate];
    } else if(step==5) {
        // Mutation after URL enqueue but before its main-queue callback.
        [self check:[self application:UIApplication.sharedApplication openURL:[NSURL URLWithString:@"socialbox://open/facebook"] options:@{}] message:@"Licensed exact link initially accepted"];
        publication=nil;
    } else if(step==6) {
        [self checkLocked:@"Queued link revoked before callback"];
        publication=Grant();[self refreshLicenseGate];
        // Rely on the actual production timer, not a direct method call.
        publication=@{@"updatedAt":@(NSDate.date.timeIntervalSince1970-30),@"license":@{@"unlocked":@YES,@"expiresAt":@(NSDate.date.timeIntervalSince1970+300)}};
    } else if(step==7) {
        [self checkLocked:@"Timer detects stale daemon"];
        [self snapshot:@"04-daemon-stale"];
        passcodeConfigured=YES;publication=Grant();[self refreshLicenseGate];
    } else if(step==8) {
        UIViewController *selector=self.window.rootViewController;
        UITabBarController *tabs=[selector valueForKey:@"redditWorkspace"];
        UIViewController *home=((UINavigationController *)tabs.viewControllers.firstObject).viewControllers.firstObject;
        [self check:[home.presentedViewController isKindOfClass:UIAlertController.class] message:@"Valid license still asks for existing launcher passcode"];
        [self check:![(id<UITabBarControllerDelegate>)self tabBarController:tabs shouldSelectViewController:tabs.viewControllers.lastObject] message:@"License does not bypass passcode into Settings"];
        RBXConnectionNavigationController *connection=(id)tabs.viewControllers[1];
        NSUInteger beforeSegment=requests.count;
        connection.pageSelector.selectedSegmentIndex=1;
        [connection.pageSelector sendActionsForControlEvents:UIControlEventValueChanged];
        [self check:connection.topViewController==connection.proxyController&&connection.pageSelector.selectedSegmentIndex==0
            message:@"Connection segment cannot bypass the configured passcode"];
        [self check:requests.count==beforeSegment message:@"Denied Connection segment sends no service request"];
        UISegmentedControl *apps=[selector valueForKey:@"appSelector"];apps.selectedSegmentIndex=1;[apps sendActionsForControlEvents:UIControlEventValueChanged];
        [self check:apps.selectedSegmentIndex==0 message:@"License does not bypass passcode into Facebook"];
        [self application:UIApplication.sharedApplication openURL:[NSURL URLWithString:@"socialbox://open/facebook"] options:@{}];
    } else if(step==9) {
        UISegmentedControl *apps=[self.window.rootViewController valueForKey:@"appSelector"];
        [self check:apps.selectedSegmentIndex==0 message:@"Queued deep link does not bypass configured passcode"];
        [self finish];return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self step:step+1];});
}
@end
int main(int argc,char *argv[]) {@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(LicenseGateTestDelegate.class));}}
