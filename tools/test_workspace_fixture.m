// Shipped UIKit controllers with inert IPC, preferences, Keychain and proxy data.
// This exercises navigation/rendering, not jailbreak enforcement or cloud auth.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "RBXLauncherAppDelegate.h"
#import "RBXLauncherViewController.h"
#import "RBXCloudVaultViewController.h"
#import "RBXSettingsViewController.h"
#import "RBXLicenseViewController.h"
#import "RBXSimpleWizardViewController.h"
#import "RBXWorkspaceNavigation.h"
#import "RBXWorkspaceNavigationController.h"
#import "RBXProxiesViewController.h"
#import "RBXLauncherIPC.h"
#import "RBXPasscodeStore.h"
#import "RBXSecureConfig.h"
#import "RBXProxyLibrary.h"
static NSMutableArray *requests;
static NSMutableDictionary *pendingCloud,*privateCloud,*renamedLabels;
static BOOL stale;
static NSDictionary *renameRow;
static NSUInteger renameRequestsBefore,creationRouteRequestsBefore;
static NSUInteger selectedIndex;
static NSUInteger clipboardWrites,flowRequestsBefore;
static NSDictionary *clipboardOptions;
static NSString *selectionPhase = @"selected";
static NSString *fixtureDirectory;
static NSDictionary *FixtureState(void) {
    NSMutableArray *rows=[NSMutableArray array];
    for (NSUInteger i=0;i<50;i++) [rows addObject:@{@"id":[NSString stringWithFormat:@"p-%032lx",(unsigned long)i+1],@"appType":@"reddit",@"name":renamedLabels[@(i)] ?: [NSString stringWithFormat:@"Research %02lu",(unsigned long)i+1],@"country":@"US",@"identity":@"iPhone 15 Pro",@"proxyStatus":@"configured",@"lastActiveAt":@(1700000000+i),@"launchBlockReason":@"Managed VPN installation is not verified on this phone.",@"identityEditor":@{@"marketingName":@"iPhone 15 Pro",@"iosVersion":@"18.6",@"country":@"US",@"locale":@"en_US",@"timezone":@"America/New_York",@"city":@"Atlanta",@"carrierName":@"T-Mobile",@"proxyCountry":@"US"}}];
    return @{@"updatedAt":@(NSDate.date.timeIntervalSince1970-(stale?60:0)),@"containers":rows,@"license":@{@"unlocked":@YES,@"expiresAt":@(NSDate.date.timeIntervalSince1970+3600),@"paired":@YES},@"networkState":@"closed",@"firewallSetup":@{@"ready":@NO},@"source":@{@"decrypted":@YES},@"sources":@{@"facebook":@{@"decrypted":@YES,@"version":@"578.1.0"}},@"activeContainer":@"",@"workspaceSelection":@{@"formatVersion":@1,@"phase":selectionPhase,@"appType":@"reddit",@"containerId":rows[selectedIndex][@"id"],@"requestId":@"D8ABC51E-AD51-4F62-AC9F-9EED17A7F258"},@"configuration":@{}};
}
@interface NSDictionary (WorkspaceFixture)
+ (id)workspaceDictionaryWithContentsOfFile:(NSString *)path;
@end
@implementation NSDictionary (WorkspaceFixture)
+ (id)workspaceDictionaryWithContentsOfFile:(NSString *)path {
    if ([path isEqual:@"/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist"]) return FixtureState();
    if ([path hasPrefix:@"/var/mobile/"]) return @{};
    return [self workspaceDictionaryWithContentsOfFile:path];
}
@end
@implementation RBXLauncherIPC
+ (NSString *)sendActionReturningRequestId:(NSString *)action values:(NSDictionary *)values notification:(CFStringRef)notification owner:(NSString *)owner appType:(NSString *)appType {
    NSString *identifier=NSUUID.UUID.UUIDString;
    NSDictionary *entry=@{@"action":action,@"owner":owner,@"appType":appType,@"values":values,@"requestId":identifier};
    [requests addObject:entry];
    if([action hasPrefix:@"cloudVault"]) {
        pendingCloud[identifier]=entry;
        privateCloud[identifier]=[action isEqual:@"cloudVaultKey"]?@{@"appType":@"reddit",@"serverURL":@"https://fixture.invalid",@"passphrase":@"synthetic-private-key"}:@{@"appType":@"reddit",@"serverURL":@"https://fixture.invalid",@"backups":@[@{@"id":@"a1",@"name":@"Research 01",@"deviceName":@"Source iPhone",@"size":@3200000,@"createdAt":@"2026-09-17",@"transferScope":@"same-license"},@{@"id":@"a2",@"name":@"Research 12",@"deviceName":@"Second phone",@"size":@890000,@"createdAt":@"2026-09-17",@"transferScope":@"same-license"}]};
    }
    return identifier;
}
+ (NSArray *)pendingRequestsForOwner:(NSString *)owner { return [pendingCloud.allValues filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings){return [row[@"owner"] isEqual:owner];}]]; }
+ (NSDictionary *)requestResultForId:(NSString *)identifier { NSMutableDictionary *row=[pendingCloud[identifier] mutableCopy];row[@"ok"]=@YES;row[@"message"]=@"Private details ready";return row; }
+ (void)finishObservingRequestId:(NSString *)identifier owner:(NSString *)owner { if([pendingCloud[identifier][@"owner"] isEqual:owner])[pendingCloud removeObjectForKey:identifier]; }
+ (void)migrateLegacyRequestStateIfNeeded {}
+ (NSDictionary *)legacySourceImportNotice { return nil; }
@end
@implementation RBXPasscodeStore
+ (BOOL)hasPasscode { return NO; }
@end
@implementation RBXSecureConfig
+ (NSDictionary *)safeSummary { return @{}; }
+ (NSDictionary *)cloudVaultPayloadForIdentifier:(NSString *)identifier response:(BOOL)response error:(NSError **)error { return response?privateCloud[identifier]:nil; }
+ (void)clearCloudVaultPayloadForIdentifier:(NSString *)identifier response:(BOOL)response { if(response)[privateCloud removeObjectForKey:identifier]; }
+ (NSDictionary *)rotationConfiguration:(NSError **)error { return @{}; }
+ (NSString *)accessKey:(NSError **)error { return nil; }
+ (NSDictionary *)identityEditorDraftForRequestID:(NSString *)request container:(NSString *)container error:(NSError **)error { return nil; }
@end
@implementation RBXProxyLibrary
+ (NSArray *)entries:(NSError **)error { return @[@{@"id":@"test-proxy-1",@"name":@"US · research",@"proxyURL":@"http://demo:example@192.0.2.10:8080",@"rotationURL":@""},@{@"id":@"test-proxy-2",@"name":@"DE · research",@"proxyURL":@"http://demo:example@192.0.2.20:8080",@"rotationURL":@""}]; }
+ (NSString *)selectedIdentifier:(NSError **)error { return @"test-proxy-1"; }
@end
// Capture public UIAlertAction callbacks to exercise the real forms without
// private UIKit dispatch APIs. Rendering and controller methods remain shipped.
static char workspaceActionCallback;
@interface UIAlertAction (WorkspaceCallback)
+ (instancetype)workspaceActionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler;
@end
@implementation UIAlertAction (WorkspaceCallback)
+ (instancetype)workspaceActionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler {
    UIAlertAction *action=[self workspaceActionWithTitle:title style:style handler:handler];
    if(handler)objc_setAssociatedObject(action,&workspaceActionCallback,handler,OBJC_ASSOCIATION_COPY_NONATOMIC);
    return action;
}
@end
// Keep sensitive-action fixtures entirely within the test process.
@interface WorkspaceClipboardSpy : NSObject
- (void)setItems:(NSArray *)items options:(NSDictionary *)options;
@end
@implementation WorkspaceClipboardSpy
- (void)setItems:(NSArray *)items options:(NSDictionary *)options { clipboardWrites++;clipboardOptions=options; }
@end
@interface RBXLauncherViewController (WorkspaceFixtureActions)
- (void)loadState;
- (NSString *)requestOwner;
- (void)openSelectedContainer;
- (void)editSelectedContainer;
- (void)updateSelectedCard;
- (void)selectContainer:(NSDictionary *)row;
- (NSDictionary *)selectedContainer;
- (void)renameContainer:(NSDictionary *)row;
- (void)createContainer;
@end
@interface RBXSettingsViewController (WorkspaceFixtureActions)
- (void)openAccount;
@end
@interface RBXCloudVaultViewController (FixtureActions)
- (void)poll;
- (void)chooseBackupContainer;
- (BOOL)send:(NSString *)action values:(NSDictionary *)values;
@end
@interface RBXLauncherAppDelegate (WorkspaceLicenseGate)
- (void)refreshLicenseGate;
@end
@interface WorkspaceTestDelegate : RBXLauncherAppDelegate
@property NSMutableArray *failures;
@property NSUInteger checks;
@end
@implementation WorkspaceTestDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    renamedLabels=[NSMutableDictionary dictionary];requests=[NSMutableArray array];pendingCloud=[NSMutableDictionary dictionary];privateCloud=[NSMutableDictionary dictionary];self.failures=[NSMutableArray array];
    fixtureDirectory=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    method_exchangeImplementations(class_getClassMethod(UIAlertAction.class,@selector(actionWithTitle:style:handler:)),class_getClassMethod(UIAlertAction.class,@selector(workspaceActionWithTitle:style:handler:)));
    // UIPasteboard is a class cluster: intercept only this public write method
    // on the returned instance's class, leaving UIKit keyboard reads intact.
    Method clipboardMethod=class_getInstanceMethod(WorkspaceClipboardSpy.class,@selector(setItems:options:));
    class_replaceMethod(object_getClass(UIPasteboard.generalPasteboard),@selector(setItems:options:),
        method_getImplementation(clipboardMethod),method_getTypeEncoding(clipboardMethod));
    method_exchangeImplementations(class_getClassMethod(NSDictionary.class,@selector(dictionaryWithContentsOfFile:)),class_getClassMethod(NSDictionary.class,@selector(workspaceDictionaryWithContentsOfFile:)));
    BOOL result=[super application:application didFinishLaunchingWithOptions:options];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{[self runStep:0];});return result;
}
- (void)check:(BOOL)ok message:(NSString *)message {self.checks++;if(!ok)[self.failures addObject:message];}
- (void)snapshot:(NSString *)name {
    [self.window layoutIfNeeded];
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:self.window.bounds.size];
    NSData *data=[renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context){[self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:YES];}];
    [data writeToFile:[fixtureDirectory stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
}
- (void)snapshot:(NSString *)name thenDismiss:(UIViewController *)controller {
    // Let the tab/presentation transition commit before recording evidence.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC*3/5),dispatch_get_main_queue(),^{
        [self snapshot:name];[controller dismissViewControllerAnimated:NO completion:nil];
    });
}
- (void)chooseAlertAction:(NSString *)title on:(UIViewController *)controller {
    UIAlertController *alert=(id)controller.presentedViewController;
    UIAlertAction *selected=nil;
    for(UIAlertAction *action in alert.actions)if([action.title isEqual:title])selected=action;
    [self check:selected!=nil message:[@"Real alert exposes " stringByAppendingString:title]];
    void (^handler)(UIAlertAction *)=selected?objc_getAssociatedObject(selected,&workspaceActionCallback):nil;
    // Let UIKit finish the dismissal in its own event-loop turn before invoking
    // the captured callback, as a real action-sheet tap does.
    [alert.presentingViewController ?: controller dismissViewControllerAnimated:NO completion:^{
        if(handler)handler(selected);
    }];
}
- (void)runStep:(NSUInteger)step {
    // Global revocation now discards every app tree; resume subsequent independent
    // workspace cases from a fresh daemon grant instead of retaining a revoked tree.
    if((step==9 || step==14) && stale) {
        stale=NO; [self refreshLicenseGate];
        // The new licensed root must complete its normal appearance/passcode
        // lifecycle before a synthetic tap; do not bypass the unlock guard.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_main_queue(),^{[self runStep:step];});
        return;
    }
    UITabBarController *tabs=[self.window.rootViewController valueForKey:@"redditWorkspace"];
    UINavigationController *nav=(id)tabs.selectedViewController;
    RBXContainerNavigationController *library=(id)tabs.viewControllers[0];
    RBXLauncherViewController *home=library.overviewController;
    if(step<5) {
        [self check:tabs.viewControllers.count==3 message:@"Three independent native sections"];
        [self check:[[tabs.viewControllers valueForKeyPath:@"tabBarItem.title"] isEqual:@[@"Containers",@"Connection",@"Settings"]]
            message:@"Navigation is English and ordered Containers, Connection, Settings"];
        RBXWorkspaceTab routes[]={RBXWorkspaceTabContainers,RBXWorkspaceTabProxies,RBXWorkspaceTabLocation,RBXWorkspaceTabSettings,RBXWorkspaceTabHome};
        [self check:RBXSelectWorkspaceTab(library.containerController,routes[step]) message:@"Unlocked destination route allowed"];
        [self.window layoutIfNeeded];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC*3/4),dispatch_get_main_queue(),^{
        if(step==4) {
            NSDictionary *values=[home valueForKey:@"identityOverviewValues"];
            [self check:values.count==6&&[[values[@"marketingName"] text] isEqual:@"iPhone 15 Pro"]
                message:@"Overview retains the saved selected profile's public summary"];
            [self check:values[@"udid"]==nil&&values[@"serial"]==nil message:@"Overview never widens public identity data"];
        }
            if(step==0) [self check:library.containerController.tableView.indexPathsForVisibleRows.count>0
                message:@"Small-screen Containers leaves a list row visible"];
            [self snapshot:@[@"01-containers",@"02-proxy",@"03-location",@"04-settings",@"05-overview"][step]];
        });
    } else if(step==5) {
        if(library.topViewController!=library.containerController) {
            [self check:RBXSelectWorkspaceTab(library.containerController,RBXWorkspaceTabContainers) message:@"Overview returns to Containers"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_main_queue(),^{[self runStep:step];});
            return;
        }
        RBXSelectWorkspaceTab(library.containerController,RBXWorkspaceTabContainers);
        RBXLauncherViewController *list=library.containerController;
        [self check:tabs.selectedViewController==library&&library.topViewController==list message:@"Containers route displays its actual list"];
        [self check:[list tableView:list.tableView numberOfRowsInSection:0]==50 message:@"All fifty fixture containers are reachable"];
        UISearchController *search=[list valueForKey:@"containerSearch"];search.searchBar.text=@"Research 07";[list loadState];
        [self check:[list tableView:list.tableView numberOfRowsInSection:0]==1 message:@"Search filters the real list"];
        [self snapshot:@"06-search"];
        search.searchBar.text=@"";[list loadState];
        NSArray *rows=[list valueForKey:@"allContainers"];
        for(NSUInteger i=0;i<40;i++) {
            NSDictionary *row=rows[i];[list selectContainer:row];
            [self check:[requests.lastObject[@"action"] isEqual:@"selectContainer"] &&
                [requests.lastObject[@"values"][@"container"] isEqual:row[@"id"]]
                message:@"Forty UI selections send the exact chosen target"];
            // Simulate a daemon publication, not a real device switch.
            selectedIndex=[FixtureState()[@"containers"] indexOfObjectPassingTest:^BOOL(NSDictionary *candidate,NSUInteger index,BOOL *stop){return [candidate[@"id"] isEqual:row[@"id"]];}];selectionPhase=@"switching";[home loadState];
            [self check:home.selectedContainer==nil message:@"Pending switch has no fallback account in Home"];
            [self check:[[[home valueForKey:@"identityOverviewValues"][@"marketingName"] text] isEqual:@"Not selected"]
                message:@"Pending switch clears Home identity instead of showing the previous account"];
            selectionPhase=@"selected";[home loadState];
            [self check:[home.selectedContainer[@"id"] isEqual:row[@"id"]]
                message:@"Home follows the latest daemon-confirmed selection"];
        }

        NSUInteger beforeMenu = requests.count;
        [list tableView:list.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        UIAlertController *menu = (id)list.presentedViewController;
        NSArray *menuTitles = [menu.actions valueForKey:@"title"];
        [self check:[menuTitles containsObject:@"Rename"] && [menuTitles containsObject:@"Configure identity"] && [menuTitles containsObject:@"Cloud backups"]
            message:@"Container menu exposes genuine identity and Cloud destinations"];
        [self check:requests.count == beforeMenu && ![menuTitles containsObject:@"Link Proxy"]
            message:@"Opening a menu neither switches containers nor claims device proxy selection is assignment"];
        RBXLauncherViewController *location=((RBXConnectionNavigationController *)tabs.viewControllers[1]).locationController;
        NSSet *owners=[NSSet setWithArray:@[home.requestOwner,list.requestOwner,location.requestOwner]];
        [self check:owners.count==3 message:@"Each page owns separate durable receipts"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
            [self.window.rootViewController dismissViewControllerAnimated:NO completion:^{
                [self check:RBXSelectWorkspaceTab(list,RBXWorkspaceTabSettings) && tabs.selectedViewController.tabBarItem.tag==RBXWorkspaceTabSettings message:@"Setup route lands on Settings"];
                [self check:RBXSelectWorkspaceTab(list,RBXWorkspaceTabProxies) && tabs.selectedViewController.tabBarItem.tag==RBXWorkspaceTabConnection message:@"Proxy route lands on Connection"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_main_queue(),^{[self runStep:6];});
            }];
        });
        return;
    } else if(step==6) {
        RBXSelectWorkspaceTab(library.containerController,RBXWorkspaceTabHome);
        [home loadState]; [home openSelectedContainer];
        [self check:[home.presentedViewController isKindOfClass:UIAlertController.class] message:@"Blocked Open displays its reason"];
        [self snapshot:@"07-blocked-open" thenDismiss:home];
        [self check:[requests filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"action != 'selectContainer'"]].count==1 && [requests.firstObject[@"action"] isEqual:@"refreshLauncher"] message:@"Browsing three sections and Overview and blocked Open never mutate profiles or start traffic"];
    } else if(step==7) {
        self.window.overrideUserInterfaceStyle=UIUserInterfaceStyleLight;[self snapshot:@"08-home-light"];
    } else if(step==8) {
        stale=YES;[home loadState];
        [self check:[[home valueForKey:@"allContainers"] count]==0 message:@"Expired publication cannot retain actionable containers"];
        [self refreshLicenseGate];
        [self check:[self.window.rootViewController isKindOfClass:UINavigationController.class] &&
            [((UINavigationController *)self.window.rootViewController).topViewController isKindOfClass:RBXLicenseViewController.class]
            message:@"Stale publication replaces the complete workspace with activation"];
        [self snapshot:@"09-stale-publication"];
    } else if(step==9) {
        stale=NO;RBXSelectWorkspaceTab(library.containerController,RBXWorkspaceTabHome);
        RBXCloudVaultViewController *cloud=[[RBXCloudVaultViewController alloc] initWithAppType:@"reddit"];
        [home.navigationController pushViewController:cloud animated:NO];
    } else if(step==10) {
        RBXCloudVaultViewController *cloud=(id)nav.topViewController;[cloud poll];
        [self check:[cloud tableView:cloud.tableView numberOfRowsInSection:0]==2 message:@"Private cloud receipt supplies both authorized backups"];
        [self check:privateCloud.count==0 message:@"Private response consumed after display"];
        [self snapshot:@"10-cloud"];
        UISearchController *search=[cloud valueForKey:@"search"];search.searchBar.text=@"Second phone";[(id<UISearchResultsUpdating>)cloud updateSearchResultsForSearchController:search];
        [self check:[cloud tableView:cloud.tableView numberOfRowsInSection:0]==1 message:@"Cloud searches source phone as well as name"];
        [cloud chooseBackupContainer];
    } else if(step==11) {
        UITableViewController *picker=(id)nav.topViewController;
        [self check:[picker tableView:picker.tableView numberOfRowsInSection:0]==50 message:@"Cloud picker handles fifty containers without an action sheet"];
        [self snapshot:@"11-cloud-container-picker"];
        UISearchController *search=[picker valueForKey:@"search"];search.searchBar.text=@"Research 07";[(id<UISearchResultsUpdating>)picker updateSearchResultsForSearchController:search];
        [self check:[picker tableView:picker.tableView numberOfRowsInSection:0]==1 message:@"Cloud container picker search narrows target"];
        [picker tableView:picker.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    } else if(step==12) {
        RBXCloudVaultViewController *cloud=(id)nav.topViewController;
        [self check:[cloud.presentedViewController.title isEqual:@"Create encrypted backup"] message:@"Picking a container requires explicit backup confirmation"];
        [self check:![requests filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"action == 'export'"]].count message:@"Picking never uploads without confirmation"];
        [self snapshot:@"12-cloud-backup-confirmation"];
        [cloud dismissViewControllerAnimated:NO completion:nil];[cloud send:@"cloudVaultKey" values:@{}];
    } else if(step==13) {
        RBXCloudVaultViewController *cloud=(id)nav.topViewController;[cloud poll];
        UIAlertController *alert=(id)cloud.presentedViewController;
        [self check:[alert isKindOfClass:UIAlertController.class]&&[alert.textFields.firstObject isSecureTextEntry] message:@"Private key is masked and requires explicit copy"];
        UIAlertAction *copyAction=nil;for(UIAlertAction *action in alert.actions)if([action.title isEqual:@"Copy key"])copyAction=action;
        void (^copyCallback)(UIAlertAction *)=objc_getAssociatedObject(copyAction,&workspaceActionCallback);
        [self check:copyCallback!=nil message:@"Cloud key fixture invokes the shipped Copy key callback"];
        NSUInteger beforeAuthorizedCopy=clipboardWrites;if(copyCallback)copyCallback(copyAction);
        [self check:clipboardWrites==beforeAuthorizedCopy+1 && [clipboardOptions[UIPasteboardOptionLocalOnly] isEqual:@YES] &&
            [clipboardOptions[UIPasteboardOptionExpirationDate] timeIntervalSinceNow]>55 &&
            [clipboardOptions[UIPasteboardOptionExpirationDate] timeIntervalSinceNow]<=60 && alert.textFields.firstObject.text.length==0
            message:@"Authorized key copy is local, expires within one minute, and clears the displayed key"];
        // Recreate a displayed key before invalidation to exercise the race;
        // no real clipboard or private service is involved in this fixture.
        alert.textFields.firstObject.text=@"synthetic-private-key";
        stale=YES;[cloud poll];
        [self check:alert.textFields.firstObject.text.length==0 message:@"Expired device publication clears displayed private key"];
        [self check:[cloud tableView:cloud.tableView numberOfRowsInSection:0]==0 message:@"Expired license publication removes cloud actions and metadata"];
        NSUInteger beforeCopy=clipboardWrites;if(copyCallback)copyCallback(copyAction);
        [self check:clipboardWrites==beforeCopy message:@"Delayed Copy callback cannot disclose a key after activation expires"];
        [self refreshLicenseGate];
    } else if(step==14) {
        stale=NO;
        UIViewController *selector=self.window.rootViewController;
        [selector dismissViewControllerAnimated:NO completion:nil];
        [library popToRootViewControllerAnimated:NO];
        RBXSelectWorkspaceTab(library.containerController,RBXWorkspaceTabHome);
        [home loadState];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_main_queue(),^{[self snapshot:@"06b-fortieth-selected"];});
    } else if(step==15) {
        for(NSString *url in @[@"socialbox://open/facebook?container=other",@"socialbox://open/reddit",@"socialbox://open/facebook#x",@"https://open/facebook"]) {
            [self check:![self application:UIApplication.sharedApplication openURL:[NSURL URLWithString:url] options:@{}]
                message:@"Shared entry rejects alternate paths, injected IDs and fragments"];
        }
        [self check:[self application:UIApplication.sharedApplication openURL:[NSURL URLWithString:@"socialbox://open/facebook"] options:@{}]
            message:@"Exact shared Facebook URL is accepted"];
    } else if(step==16) {
        UIViewController *selector=self.window.rootViewController;
        UISegmentedControl *appSelector=[selector valueForKey:@"appSelector"];
        [self check:[[appSelector titleForSegmentAtIndex:appSelector.selectedSegmentIndex] isEqual:@"Facebook"]
            message:@"Shared entry selects Facebook workspace"];
        [self check:![requests filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"action == 'launchSelectedContainer' OR action == 'launchContainer'"]].count
            message:@"Inactive Facebook and missing MDM never enqueue launch"];
        [self snapshot:@"13-shared-facebook-blocked"];
    } else if(step==17) {
        UISegmentedControl *selector=[self.window.rootViewController valueForKey:@"appSelector"];
        selector.selectedSegmentIndex=0;[selector sendActionsForControlEvents:UIControlEventValueChanged];
        RBXSelectWorkspaceTab(library.containerController,RBXWorkspaceTabContainers);
    } else if(step>=18 && step<=28) {
        RBXLauncherViewController *list=(id)((UINavigationController *)tabs.selectedViewController).viewControllers.firstObject;
        if(step==18) {
            [list loadState];renameRow=[[list valueForKey:@"containers"] firstObject];renameRequestsBefore=requests.count;
            [list tableView:list.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        } else if(step==19) {
            [self chooseAlertAction:@"Rename" on:list];
        } else if(step==20) {
            UIAlertController *form=(id)list.presentedViewController;
            [self check:[form.title isEqual:@"Rename container"] && form.textFields.count==1 &&
                [form.textFields.firstObject.text isEqual:renameRow[@"name"]] message:@"Rename form starts from existing label only"];
            form.textFields.firstObject.text=@"   Reviewed label   ";[self snapshot:@"14-rename"];
            [self chooseAlertAction:@"Save" on:list];
        } else if(step==21) {
            [self check:requests.count==renameRequestsBefore+1 && [requests.lastObject[@"action"] isEqual:@"updateMetadata"] &&
                [requests.lastObject[@"appType"] isEqual:@"reddit"] &&
                [requests.lastObject[@"values"] isEqual:@{@"container":renameRow[@"id"],@"nickname":@"Reviewed label"}]
                message:@"Rename submits only chosen container and trimmed label; no identity or clone mutation"];
            [self check:[[[list valueForKey:@"containers"] firstObject][@"name"] isEqual:renameRow[@"name"]]
                message:@"Rename does not optimistically rewrite authoritative daemon data"];
            renameRequestsBefore=requests.count;[list renameContainer:renameRow];
        } else if(step==22) {
            [self chooseAlertAction:@"Cancel" on:list];
        } else if(step==23) {
            [self check:requests.count==renameRequestsBefore message:@"Cancelled rename is read only"];
            [list renameContainer:renameRow];
        } else if(step==24) {
            [self chooseAlertAction:@"Save" on:list];
        } else if(step==25) {
            [self check:requests.count==renameRequestsBefore message:@"Unchanged rename is read only"];
            [list renameContainer:renameRow];
        } else if(step==26) {
            UIAlertController *form=(id)list.presentedViewController;form.textFields.firstObject.text=@"";
            [self chooseAlertAction:@"Save" on:list];
        } else if(step==27) {
            [self check:requests.count==renameRequestsBefore && [list.presentedViewController.title isEqual:@"Name not saved"]
                message:@"Invalid name shows an error without sending a request"];
            [list dismissViewControllerAnimated:NO completion:nil];
        } else if(step==28) {
            NSUInteger index=[FixtureState()[@"containers"] indexOfObjectPassingTest:^BOOL(NSDictionary *item,NSUInteger index,BOOL *stop){return [item[@"id"] isEqual:renameRow[@"id"]];}];
            renamedLabels[@(index)]=@"Reviewed label";[list loadState];
            UISearchController *search=[list valueForKey:@"containerSearch"];search.searchBar.text=@"Reviewed label";[list loadState];
            [self check:[list tableView:list.tableView numberOfRowsInSection:0]==1 &&
                [[list valueForKey:@"containers"][0][@"id"] isEqual:renameRow[@"id"]]
                message:@"Confirmed name publication remains searchable with the same canonical ID"];
            [self snapshot:@"15-renamed-search"];
        }
    } else if(step==29 || step==31) {
        RBXSelectWorkspaceTab(library.containerController,step==29?RBXWorkspaceTabHome:RBXWorkspaceTabContainers);
        RBXLauncherViewController *screen=(id)((UINavigationController *)tabs.selectedViewController).topViewController;
        creationRouteRequestsBefore=requests.count;
        [screen createContainer];
    } else if(step==30 || step==32) {
        UINavigationController *current=(id)tabs.selectedViewController;
        [self check:[current.topViewController isKindOfClass:RBXSimpleWizardViewController.class]
            message:@"Reddit Overview and Containers New both open the actual prepare/review wizard"];
        [self check:requests.count==creationRouteRequestsBefore
            message:@"Entering creation from either Reddit route sends no creation or preparation request"];
        [self snapshot:step==30?@"16-reddit-home-creation-preview":@"17-reddit-containers-creation-preview"];
        [current popToRootViewControllerAnimated:NO];
    } else if(step==33) {
        RBXSelectWorkspaceTab(library.containerController,RBXWorkspaceTabSettings);
        UINavigationController *settingsNav=(id)tabs.selectedViewController;
        RBXSettingsViewController *settings=(id)settingsNav.viewControllers.firstObject;
        flowRequestsBefore=requests.count;[settings openAccount];
        [self check:[settingsNav.topViewController isKindOfClass:RBXLicenseViewController.class]
            message:@"Account & license opens licensing for Reddit, not an unrelated username lookup"];
        [self check:[[[settingsNav.topViewController valueForKey:@"appDescriptor"] objectForKey:@"appType"] isEqual:@"reddit"] &&
            !settingsNav.topViewController.navigationItem.hidesBackButton message:@"Reddit licensing retains app scope and a way back to Settings"];
        [self check:requests.count==flowRequestsBefore message:@"Opening license information is read only"];
    } else if(step>=34 && step<=37) {
        [(UINavigationController *)tabs.viewControllers.lastObject popToRootViewControllerAnimated:NO];
        RBXSelectWorkspaceTab(library.containerController,RBXWorkspaceTabContainers);
        RBXLauncherViewController *list=(id)((UINavigationController *)tabs.selectedViewController).viewControllers.firstObject;
        NSMutableDictionary *row=[FixtureState()[@"containers"][0] mutableCopy];
        NSString *expected=nil;
        if(step==34){row[@"profileError"]=@{@"message":@"Synthetic profile recovery required"};expected=@"Diagnostics";}
        if(step==35){row[@"deletionState"]=@{@"message":@"Synthetic cleanup interrupted"};expected=@"Retry Delete";}
        if(step>=36){row[@"replacementState"]=@{@"oldId":step==36?@"original":row[@"id"],@"newId":step==36?row[@"id"]:@"candidate",@"phase":@"prepared"};expected=@"Resume Replace";}
        [list setValue:@[row] forKey:@"containers"];
        [list tableView:list.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        UIAlertController *alert=(id)list.presentedViewController;NSArray *titles=[alert.actions valueForKey:@"title"];
        [self check:[titles containsObject:expected] && ![titles containsObject:@"Use this container"] && ![titles containsObject:@"Configure identity"]
            message:@"Simple mode routes unreadable, deleting and both replacement profiles to recovery"];
        [self check:requests.count==flowRequestsBefore message:@"Opening recovery choices never deletes, replaces or starts a session"];
        [self snapshot:[NSString stringWithFormat:@"%lu-simple-recovery",(unsigned long)step] thenDismiss:list];
        if(step==37){
            row[@"id"]=FixtureState()[@"containers"][selectedIndex][@"id"];
            [home setValue:@[row] forKey:@"allContainers"];[home updateSelectedCard];
            [self check:![[home valueForKey:@"selectedEdit"] isEnabled] message:@"Home cannot configure an unfinished replacement"];
            UIViewController *before=home.navigationController.topViewController;[home editSelectedContainer];
            [self check:home.navigationController.topViewController==before message:@"Direct Home edit also refuses replacement recovery rows"];
        }
    } else if(step==38) {
        RBXSelectWorkspaceTab(library.containerController,RBXWorkspaceTabHome);
        [home loadState]; [home openSelectedContainer];
        UIAlertController *alert=(id)home.presentedViewController;
        [self check:[[alert.actions valueForKey:@"title"] containsObject:@"Open Settings"]
            message:@"Blocked Home Open offers a direct route to required setup"];
        [self check:[alert.message containsString:@"Managed VPN installation"] message:@"Blocked Home Open keeps the authoritative reason"];
        [self chooseAlertAction:@"Open Settings" on:home];
    } else if(step==39) {
        [self check:tabs.selectedViewController.tabBarItem.tag==RBXWorkspaceTabSettings message:@"Blocked Open recovery reaches Settings"];
        [self check:requests.count==flowRequestsBefore message:@"Setup recovery never queues a launch request"];
        [self snapshot:@"39-setup-recovery"];
    } else if(step==40) {
        // Facebook execution is still inactive. Exercise the real app-scoped
        // Settings method in a separate UIKit stack without inventing a tab.
        RBXSettingsViewController *settings=[[RBXSettingsViewController alloc] initWithAppType:@"facebook" proxyMode:NO];
        UINavigationController *settingsNav=[[UINavigationController alloc] initWithRootViewController:settings];
        NSUInteger before=requests.count;[settings openAccount];
        [self check:[settingsNav.topViewController isKindOfClass:RBXLicenseViewController.class] &&
            [[[settingsNav.topViewController valueForKey:@"appDescriptor"] objectForKey:@"appType"] isEqual:@"facebook"]
            message:@"Settings license method keeps Facebook scope without activating its workspace"];
        [self check:requests.count==before && !settingsNav.topViewController.navigationItem.hidesBackButton
            message:@"Facebook license navigation is read only and can return to Settings"];
    } else if(step==41) {
        NSUInteger before=requests.count;
        [self check:RBXSelectWorkspaceTab(library.containerController,RBXWorkspaceTabProxies) message:@"Connection proxy route remains reachable"];
        RBXConnectionNavigationController *connection=(id)tabs.selectedViewController;
        [self check:connection.topViewController==connection.proxyController&&connection.pageSelector.selectedSegmentIndex==0
            message:@"Proxy route selects the correct internal page"];
        UIViewController *editor=[UIViewController new];[connection pushViewController:editor animated:NO];
        [self check:!RBXSelectWorkspaceTab(library.containerController,RBXWorkspaceTabLocation)&&connection.topViewController==editor
            message:@"Location routing cannot discard an unfinished proxy editor"];
        [connection popToRootViewControllerAnimated:NO];
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Synthetic pending confirmation" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [connection.proxyController presentViewController:alert animated:NO completion:nil];
        [self check:!RBXSelectWorkspaceTab(library.containerController,RBXWorkspaceTabLocation) message:@"Connection preserves a pending confirmation"];
        [connection.proxyController dismissViewControllerAnimated:NO completion:nil];
        [self check:requests.count==before message:@"Blocked routes are read only"];
    } else if(step==42) {
        RBXConnectionNavigationController *connection=(id)tabs.viewControllers[1];NSUInteger before=requests.count;
        connection.pageSelector.selectedSegmentIndex=1;[connection.pageSelector sendActionsForControlEvents:UIControlEventValueChanged];
        [self check:connection.topViewController==connection.locationController&&connection.pageSelector.selectedSegmentIndex==1
            message:@"Actual Location segment changes page through the guarded route"];
        connection.pageSelector.selectedSegmentIndex=0;[connection.pageSelector sendActionsForControlEvents:UIControlEventValueChanged];
        [self check:connection.topViewController==connection.proxyController message:@"Actual Proxy segment switches back without losing its controller"];
        [self check:RBXSelectWorkspaceTab(library.containerController,RBXWorkspaceTabContainers) message:@"Containers remains the stable primary section"];
        UIViewController *editor=[UIViewController new];[library pushViewController:editor animated:NO];
        [self check:!RBXSelectWorkspaceTab(library.containerController,RBXWorkspaceTabHome)&&library.topViewController==editor
            message:@"Overview routing cannot replace an unfinished creation/identity screen"];
        [library popToRootViewControllerAnimated:NO];
        [self check:!RBXSelectWorkspaceTab(library.containerController,(RBXWorkspaceTab)999) message:@"Unknown destinations are rejected"];
        [self check:requests.count==before message:@"Segment and guarded detail navigation send no service operations"];
    } else {
        NSDictionary *result=@{@"ok":@(self.failures.count==0),@"checks":@(self.checks),@"failures":self.failures,@"evidence":@"Shipped UIKit, inert IPC and synthetic data. No device isolation or cloud transfer claim."};
        [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[fixtureDirectory stringByAppendingPathComponent:@"workspace-result.json"] atomically:YES];return;
    }
    (void)nav;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{[self runStep:step+1];});
}
@end
int main(int argc,char *argv[]) {@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(WorkspaceTestDelegate.class));}}
