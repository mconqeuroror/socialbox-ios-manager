#import <UIKit/UIKit.h>
#import "RBXProxiesViewController.h"
#import "RBXProxyLibrary.h"
#import "RBXSecureConfig.h"
#import "RBXLauncherIPC.h"
static NSDictionary *Record;
static NSUInteger Writes, Requests;
@implementation RBXSecureConfig
+ (NSDictionary *)rotationConfiguration:(NSError **)error {return Record;}
+ (NSDictionary *)safeSummary {return @{};}
+ (BOOL)saveRotationConfiguration:(NSDictionary *)update error:(NSError **)error {
 Writes++;NSMutableDictionary *next=Record.mutableCopy?:[NSMutableDictionary dictionary];[next addEntriesFromDictionary:update];Record=next;return YES;
}
@end
@implementation RBXLauncherIPC
+ (NSArray *)pendingRequestsForOwner:(NSString *)owner {return @[];}
+ (NSDictionary *)requestResultForId:(NSString *)requestId {return nil;}
+ (void)finishObservingRequestId:(NSString *)requestId owner:(NSString *)owner {}
+ (NSString *)sendActionReturningRequestId:(NSString *)action values:(NSDictionary *)values notification:(CFStringRef)notification owner:(NSString *)owner appType:(NSString *)appType {Requests++;return nil;}
@end
@interface UIViewController (ProxyFixtureSelectors)
- (void)reload;
- (void)importList;
- (void)previewImport;
- (void)confirmImport;
- (void)commitImport;
- (void)textViewDidChange:(UITextView *)textView;
- (void)use:(NSDictionary *)row test:(BOOL)test;
@end
@interface ProxyImportFixture : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property UINavigationController *navigation;
@property NSUInteger checks;
@end
@implementation ProxyImportFixture
- (void)check:(BOOL)ok label:(NSString *)label {
 self.checks++;if(!ok)@throw [NSException exceptionWithName:@"Assertion" reason:label userInfo:nil];
}
- (NSString *)path:(NSString *)name {return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:name];}
- (void)snapshot:(NSString *)name {
 [self.window layoutIfNeeded];UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:self.window.bounds];
 UIImage *image=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context){[self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:YES];}];
 [UIImagePNGRepresentation(image) writeToFile:[self path:[name stringByAppendingString:@".png"]] atomically:YES];
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
 Record=@{@"accessKey":@"fixture-only",@"proxyDisabled":@YES};
 self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];self.window.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
 RBXProxiesViewController *list=[[RBXProxiesViewController alloc] initWithAppType:@"reddit"];
 self.navigation=[[UINavigationController alloc] initWithRootViewController:list];self.window.rootViewController=self.navigation;
 [self.window makeKeyAndVisible];[UIView setAnimationsEnabled:NO];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{[self run:list];});return YES;
}
- (void)run:(RBXProxiesViewController *)list {
 BOOL ok=YES;NSString *failure=@"";
 @try {
  [list reload];[self check:[list tableView:list.tableView numberOfRowsInSection:0]==1 label:@"empty state is reachable"];
  [self check:Writes==0&&Requests==0 label:@"opening library is read-only"];
  [self snapshot:@"01-proxy-empty-fixture"];
  [list importList];UIViewController *importer=self.navigation.topViewController;[importer loadViewIfNeeded];
  [self check:importer!=list label:@"paste list opens importer"];
  UITextView *input=[importer valueForKey:@"input"];UIButton *save=[importer valueForKey:@"importButton"];
  [self check:!save.enabled && input.text.length==0 label:@"no automatic clipboard read or ready import"];
  input.text=@"proxy.example:8080:user:pass\nhttp://user:pass@proxy.example:8080\nsecond.example:80";
  [importer textViewDidChange:input];[importer previewImport];
  NSDictionary *preview=[importer valueForKey:@"preview"];
  [self check:[preview[@"newCount"] isEqual:@2]&&[preview[@"duplicateCount"] isEqual:@1]&&save.enabled label:@"actual UI previews unique rows"];
  [self check:Writes==0&&Requests==0 label:@"review never writes or tests network"];
  [self check:![[[importer valueForKey:@"details"] text] containsString:@"user:pass"] label:@"preview summary omits credentials"];
  [self snapshot:@"02-proxy-import-preview-fixture"];
  input.text=[input.text stringByAppendingString:@"\nsocks5://unsupported.example:90"];
  [importer textViewDidChange:input];[self check:!save.enabled&&![importer valueForKey:@"preview"] label:@"editing invalidates review"];
  [importer previewImport];[self check:!save.enabled&&[[importer valueForKey:@"preview"][@"invalidCount"] isEqual:@1] label:@"unsupported protocol blocks import"];
  [self snapshot:@"03-proxy-import-errors-fixture"];
  input.text=@"proxy.example:8080:user:pass\nsecond.example:80";[importer textViewDidChange:input];[importer previewImport];
  [importer confirmImport];
  [self check:[importer.presentedViewController isKindOfClass:UIAlertController.class] label:@"explicit import confirmation shown"];
  [self check:((UIAlertController *)importer.presentedViewController).actions.count==2&&Writes==0 label:@"confirmation permits cancel without mutation"];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_main_queue(),^{
   [self snapshot:@"04-proxy-import-confirmation-fixture"];
   [importer dismissViewControllerAnimated:NO completion:^{
    [importer commitImport];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_main_queue(),^{[self verifySavedList:list];});
   }];
  });return;
 } @catch(NSException *exception) {ok=NO;failure=exception.reason?:@"fixture failed";}
 [self complete:ok failure:failure];
}
- (void)verifySavedList:(RBXProxiesViewController *)list {
 BOOL ok=YES;NSString *failure=@"";
 @try {
  [list reload];
  [self check:self.navigation.topViewController==list && !self.navigation.presentedViewController label:@"successful import returns to library"];
  [self check:Writes==1&&Requests==0 label:@"confirmed import writes once with no network requests"];
  [self check:[list tableView:list.tableView numberOfRowsInSection:0]==2 label:@"new proxies visible in real list"];
  [self check:![RBXProxyLibrary selectedIdentifier:nil].length&&[Record[@"proxyDisabled"] boolValue] label:@"import never selects or enables a proxy"];
  [self check:[Record[@"accessKey"] isEqual:@"fixture-only"] label:@"license remains unchanged"];
  UISearchController *search=[list valueForKey:@"search"];search.searchBar.text=@"second";[list reload];
  [self check:[list tableView:list.tableView numberOfRowsInSection:0]==1&&[[list valueForKey:@"proxies"] count]==1 label:@"search narrows imported endpoints"];
  search.searchBar.text=@"absent";[list reload];
  [self check:[list tableView:list.tableView numberOfRowsInSection:0]==1&&[[list valueForKey:@"proxies"] count]==0 label:@"search empty state remains accessible"];
  search.searchBar.text=@"";[list reload];[list.view layoutIfNeeded];
  for(NSUInteger row=0;row<2;row++)[self check:[list.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]].size.height>=60 label:@"saved proxy cards keep readable row height"];
  [self snapshot:@"05-proxy-library-fixture"];
  __block NSUInteger selections=0;
  list.didSelectProxy=^{ selections++; };
  NSDictionary *chosen=[RBXProxyLibrary entries:nil].firstObject;
  [list use:chosen test:YES];
  [self check:selections==1&&[[RBXProxyLibrary selectedIdentifier:nil] isEqual:chosen[@"id"]] label:@"successful explicit Use notifies wizard after saving selected proxy"];
  [self check:Writes==2&&Requests==1&&! [Record[@"proxyDisabled"] boolValue] label:@"selection is saved even when network request cannot publish; callback is not a success claim"];
  [list use:@{@"id":@"missing-fixture-proxy"} test:NO];
  [self check:selections==1&&Writes==2&&Requests==1 label:@"failed selection sends no callback or network request"];
 } @catch(NSException *exception) {ok=NO;failure=exception.reason?:@"fixture failed";}
 [self complete:ok failure:failure];
}
- (void)complete:(BOOL)ok failure:(NSString *)failure {
 NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"ok":@(ok),@"checks":@(self.checks),@"failure":failure,@"scope":@"Actual UIKit; inert Keychain and daemon. No physical-device or network evidence."} options:NSJSONWritingPrettyPrinted error:nil];
 [json writeToFile:[self path:@"proxy-import-result.json"] atomically:YES];
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(ProxyImportFixture.class));}}
