// Real update UI with local response/URL boundaries. No original app or network.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SBUpdateService.h"
#import "SBBackendAdapter.h"
#import "SBInterfaceCopy.h"

static NSUInteger Checks,Requests;
static NSMutableArray *Failures,*OpenedURLs;
static NSUInteger SuccessfulURLIndex;
static NSData *ResponseData;
static NSTimeInterval ResponseDelay;
static BOOL OpenedDuringPresentation;
static UIApplicationState FixtureApplicationState=UIApplicationStateActive;
static char HandlerKey;
static void Check(BOOL ok,NSString *message){Checks++;if(!ok)[Failures addObject:message];}
static BOOL Wait(BOOL(^predicate)(void)){
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:5];
    while(!predicate()&&end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return predicate();
}
static void Settle(void){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:.15];while(end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];}
static UIView *Find(UIView *view,NSString *identifier){
    if([view.accessibilityIdentifier isEqual:identifier])return view;
    for(UIView *child in view.subviews){UIView *found=Find(child,identifier);if(found)return found;}return nil;
}
static void Tap(UIViewController *owner,NSString *identifier){
    UIButton *button=(id)Find(owner.view,identifier);Check([button isKindOfClass:UIButton.class]&&button.enabled&&!button.hidden,[identifier stringByAppendingString:@" available"]);
    if([button isKindOfClass:UIButton.class]&&button.enabled&&!button.hidden)[button sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
}
static NSDictionary *Manifest(void){
    return @{@"schemaVersion":@1,@"channel":@"stable",@"available":@YES,@"package":@"com.socialbox",
        @"packageVersion":@"3.1.0-1+socialbox.16",@"sequence":@16,@"supportedFrom":@[@"3.1.0-1+socialbox.15"],
        @"architecture":@"iphoneos-arm64",@"minimumIOS":@"16.0",@"publishedAt":@"2026-09-28T12:00:00Z",
        @"notes":@"Local fixture update.",@"sha256":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0],
        @"updateURL":@"https://redditspoof.vercel.app/updates"};
}
static void Reply(NSDictionary *manifest){ResponseData=[NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil];}
@interface UpdateUIProtocol:NSURLProtocol @end
@implementation UpdateUIProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request{(void)request;return YES;}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request{return request;}
- (void)startLoading{
    @synchronized(UpdateUIProtocol.class){Requests++;}
    NSData *body=[ResponseData copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(ResponseDelay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"application/json"}];
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:body];[self.client URLProtocolDidFinishLoading:self];
    });
}
- (void)stopLoading{}
@end
@interface RoleController:UIViewController
@property(nonatomic) SBScreen role;
@end
@implementation RoleController @end
SBScreen SBBackendScreen(id owner){return [owner isKindOfClass:RoleController.class]?[(RoleController *)owner role]:SBScreenUnknown;}
static BOOL HasPresentation(UIViewController *owner){
    if(owner.presentedViewController)return YES;
    for(UIViewController *child in owner.childViewControllers)if(HasPresentation(child))return YES;return NO;
}
@interface UpdateUIApplication:UIApplication @end
@implementation UpdateUIApplication
- (UIApplicationState)applicationState{return FixtureApplicationState;}
- (void)openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenExternalURLOptionsKey,id> *)options completionHandler:(void(^)(BOOL))completion{
    (void)options;
    UIWindow *window=((id<UIApplicationDelegate>)self.delegate).window;
    OpenedDuringPresentation|=HasPresentation(window.rootViewController);
    [OpenedURLs addObject:url.absoluteString];BOOL opened=OpenedURLs.count-1==SuccessfulURLIndex;
    dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(opened);});
}
@end
static id (*OriginalAction)(id,SEL,NSString *,UIAlertActionStyle,void(^)(UIAlertAction *));
static id CaptureAction(id cls,SEL selector,NSString *title,UIAlertActionStyle style,void(^handler)(UIAlertAction *)){
    id action=OriginalAction(cls,selector,title,style,handler);objc_setAssociatedObject(action,&HandlerKey,handler,OBJC_ASSOCIATION_COPY_NONATOMIC);return action;
}
@interface SBUpdateService(Fixture)
- (void)publish:(NSDictionary *)value;
@end
@interface NSObject(FixtureLifecycle)
- (void)offerAvailableUpdate;
@end
@interface UpdateUIApp:UIResponder<UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation UpdateUIApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options{
    (void)application;(void)options;Failures=[NSMutableArray array];OpenedURLs=[NSMutableArray array];
    Method action=class_getClassMethod(UIAlertAction.class,@selector(actionWithTitle:style:handler:));
    OriginalAction=(void *)method_setImplementation(action,(IMP)CaptureAction);
    SBUpdateService *service=SBUpdateService.sharedService;
    [service setValue:@"3.1.0-1+socialbox.15" forKey:@"installedVersion"];
    [service setValue:@"16.7.16" forKey:@"systemVersion"];
    NSURLSessionConfiguration *configuration=[service valueForKey:@"configuration"];configuration.protocolClasses=@[UpdateUIProtocol.class];
    [service setValue:[[NSUserDefaults alloc] initWithSuiteName:NSBundle.mainBundle.bundleIdentifier] forKey:@"defaults"];
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    RoleController *root=[RoleController new];root.role=SBScreenSettings;
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:root];
    self.window.rootViewController=navigation;[self.window makeKeyAndVisible];
    // A timer permits nested run-loop waits to drain the main dispatch queue.
    // Running this entire fixture from a main-queue block would deadlock its
    // own synthetic asynchronous URL and network completions.
    [self performSelector:@selector(runScheduled) withObject:nil afterDelay:.1];return YES;
}
- (void)runScheduled{[self runWithNavigation:(id)self.window.rootViewController service:SBUpdateService.sharedService];}
- (void)runWithNavigation:(UINavigationController *)navigation service:(SBUpdateService *)service{
    SBAppUpdatesViewController *page=[SBAppUpdatesViewController new];[navigation pushViewController:page animated:NO];Settle();
    Check(Requests==0&&OpenedURLs.count==0,@"opening update screen makes no request or external handoff");
    UIColor *blue=((UIButton *)Find(page.view,@"socialbox.updates.check")).configuration.baseBackgroundColor;
    CGFloat red,green,blueComponent,alpha;[blue getRed:&red green:&green blue:&blueComponent alpha:&alpha];
    Check(red==0&&fabs(green-122.0/255.0)<.001&&blueComponent==1&&alpha==1,@"real check button uses exact brand blue");
    NSArray *expected=@[@"sileo://source/https://redditspoof.vercel.app/apt/socialbox/",
        @"zbra://sources/add/https://redditspoof.vercel.app/apt/socialbox/",@"https://redditspoof.vercel.app/updates"];
    for(NSUInteger index=0;index<3;index++){
        [OpenedURLs removeAllObjects];SuccessfulURLIndex=index;Reply(Manifest());NSUInteger before=Requests;
        Tap(page,@"socialbox.updates.check");
        Check(Wait(^BOOL{return [service.snapshot[@"state"] isEqual:@"available"]&&OpenedURLs.count==index+1;}),@"manual check completes handoff");Settle();
        Check(Requests==before+1,@"one user check starts one metadata request");
        Check([OpenedURLs isEqual:[expected subarrayWithRange:NSMakeRange(0,index+1)]],@"manual check tries Sileo, Zebra and web in order");
        [NSNotificationCenter.defaultCenter postNotificationName:SBUpdateStateDidChangeNotification object:service];Settle();
        Check(OpenedURLs.count==index+1,@"later rendering never repeats consumed manual handoff");
    }
    [OpenedURLs removeAllObjects];Reply(@{@"schemaVersion":@1,@"channel":@"stable",@"available":@NO});
    Tap(page,@"socialbox.updates.check");Check(Wait(^BOOL{return [service.snapshot[@"state"] isEqual:@"no-release"];}),@"closed stable release resolves");Settle();
    Check(OpenedURLs.count==0&&Find(page.view,@"socialbox.updates.open").hidden,@"no released update keeps package manager closed");
    SuccessfulURLIndex=0;Tap(page,@"socialbox.updates.instructions");Settle();
    Check([OpenedURLs isEqual:@[expected.lastObject]],@"instructions stay reachable without a release");
    [OpenedURLs removeAllObjects];SuccessfulURLIndex=99;Reply(Manifest());Tap(page,@"socialbox.updates.check");
    Check(Wait(^BOOL{return page.presentedViewController!=nil;}),@"all URL failures display an actionable error");
    Check([OpenedURLs isEqual:expected],@"failed handlers exhaust exactly three fixed URLs");
    [page dismissViewControllerAnimated:NO completion:nil];Settle();
    [OpenedURLs removeAllObjects];SuccessfulURLIndex=0;ResponseDelay=.25;Reply(Manifest());
    Tap(page,@"socialbox.updates.check");[navigation setViewControllers:@[navigation.viewControllers.firstObject] animated:NO];
    Check(Wait(^BOOL{return [service.snapshot[@"state"] isEqual:@"available"];}),@"delayed response still completes after leaving page");Settle();
    Check(OpenedURLs.count==0,@"leaving update page cancels pending external handoff");ResponseDelay=0;
    page=[SBAppUpdatesViewController new];[navigation pushViewController:page animated:NO];Settle();Reply(Manifest());ResponseDelay=.25;
    Tap(page,@"socialbox.updates.check");FixtureApplicationState=UIApplicationStateBackground;
    Check(Wait(^BOOL{return [service.snapshot[@"state"] isEqual:@"available"];}),@"metadata result completes while app is backgrounded");Settle();
    Check(OpenedURLs.count==0,@"backgrounded app cannot start an external handoff");
    FixtureApplicationState=UIApplicationStateActive;ResponseDelay=0;
    [NSNotificationCenter.defaultCenter postNotificationName:SBUpdateStateDidChangeNotification object:service];Settle();
    Check(OpenedURLs.count==0,@"foreground refresh does not resurrect consumed manual action");
    [navigation setViewControllers:@[navigation.viewControllers.firstObject] animated:NO];Settle();

    UITabBarController *tabs=[UITabBarController new];NSMutableArray *entries=[NSMutableArray array];
    for(NSUInteger role=SBScreenHome;role<=SBScreenSettings;role++){RoleController *entry=[RoleController new];entry.role=(SBScreen)role;[entries addObject:[[UINavigationController alloc] initWithRootViewController:entry]];}
    tabs.viewControllers=entries;self.window.rootViewController=tabs;Settle();
    NSObject *lifecycle=[NSClassFromString(@"SBUpdateLifecycle") new];[lifecycle setValue:tabs forKey:@"host"];
    [lifecycle offerAvailableUpdate];UIViewController *visible=((UINavigationController *)tabs.selectedViewController).topViewController;
    Check(Wait(^BOOL{return [visible.presentedViewController isKindOfClass:UIAlertController.class];}),@"available lifecycle update offers a visible prompt");
    UIAlertController *alert=(id)visible.presentedViewController;UIAlertAction *open=alert.actions.lastObject;
    void(^handler)(UIAlertAction *)=objc_getAssociatedObject(open,&HandlerKey);
    Check(handler!=nil&&OpenedURLs.count==0,@"prompt waits for explicit user action");
    if(handler)handler(open);
    Check(Wait(^BOOL{return OpenedURLs.count==1;}),@"accepting alert opens manager after completed dismissal");Settle();
    Check(!visible.presentedViewController&&!OpenedDuringPresentation,@"no external handoff occurs while any alert is presented");
    Check([OpenedURLs isEqual:@[expected.firstObject]],@"accepting available prompt opens Sileo exactly once");
    [lifecycle offerAvailableUpdate];Settle();Check(!visible.presentedViewController&&OpenedURLs.count==1,@"same version is not prompted or opened twice");
    self.window.rootViewController=navigation;page=[SBAppUpdatesViewController new];[navigation pushViewController:page animated:NO];Settle();
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:self.window.bounds];
    UIImage *image=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context){(void)context;[self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:YES];}];
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    [UIImagePNGRepresentation(image) writeToFile:[documents stringByAppendingPathComponent:@"update-ui.png"] atomically:YES];
    NSDictionary *result=@{@"ok":@((BOOL)!Failures.count),@"assertions":@(Checks),@"requests":@(Requests),@"failures":Failures,
        @"originalEngineLoaded":@NO,@"externalURLLaunch":@NO,@"productionNetwork":@NO};
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[documents stringByAppendingPathComponent:@"update-ui-result.json"] atomically:YES];
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,NSStringFromClass(UpdateUIApplication.class),NSStringFromClass(UpdateUIApp.class));}}
