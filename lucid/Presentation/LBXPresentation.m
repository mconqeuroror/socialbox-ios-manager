#import "LBXPresentation.h"
#import "LBXWorkspace.h"
#import "LBXDisplayCopy.h"
#import "SBBackendAdapter.h"
#import "SBWorkspaceCoordinator.h"
#import "SBDesign.h"
#import "SBSecondaryScreens.h"
#import "SBSwitchProgress.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <os/log.h>

// This version pin is the original UI ABI, not the derivative package version.
// Never infer support for another binary from its branding or a similar class.
// Explicit recovered screen contract; no discovery by class-name substring.
// The first five are the established shell. Optional detail screens fail
// individually so an unsupported sheet cannot disable the original shell.
static NSDictionary<NSString *,NSDictionary *> *LBXScreens(void) { return SBBackendCompatibilityScreensDictionary(); }
static NSArray<NSString *> *LBXEnabledClasses;
static NSMutableArray<NSString *> *LBXIssues;
static BOOL LBXInstalled;
static char LBXActionKey, LBXDiagnosticContextKey;
#if LBX_PRESENTATION_FIXTURE
static NSDictionary *LBXFixtureMetadata;
void LBXPresentationFixtureMetadata(NSDictionary *metadata) { LBXFixtureMetadata = [metadata copy]; SBBackendFixtureConfigure(metadata,NSBundle.mainBundle.executablePath); }
#endif
static NSDictionary *LBXMetadata(void) {
#if LBX_PRESENTATION_FIXTURE
    if (LBXFixtureMetadata) return LBXFixtureMetadata;
#endif
    return NSBundle.mainBundle.infoDictionary ?: @{};
}
static void LBXReport(NSString *reason) {
    @synchronized (NSProcessInfo.class) {
        if (!LBXIssues) LBXIssues = [NSMutableArray array];
        if ([LBXIssues containsObject:reason]) return;
        if (LBXIssues.count < 32) [LBXIssues addObject:reason];
    }
    os_log_error(OS_LOG_DEFAULT, "LBX_PRESENTATION %{public}@", reason);
}
NSDictionary *LBXPresentationStatus(void) {
    NSString *reason = nil;
    BOOL supported = LBXPresentationMetadataSupported(LBXMetadata(), &reason);
    @synchronized (NSProcessInfo.class) {
        return @{@"schemaVersion": @1, @"module": @"presentation", @"installed": @(LBXInstalled),
                 @"baseMetadataSupported": @(supported), @"baseCompatibilityReason": reason ?: @"supported",
                 @"scope": @"source-owned workspace with original backend actions", @"workspace": LBXWorkspaceStatus(), @"isolationVerified": @NO,
                 @"styledScreenClasses": LBXEnabledClasses ?: @[], @"issues": [LBXIssues copy] ?: @[]};
    }
}
BOOL LBXPresentationMetadataSupported(NSDictionary *metadata, NSString **reason) { return SBBackendMetadataSupported(metadata,reason); }
static BOOL LBXTypeMatches(const char *actual, const char *expected) {
    if (!actual || !expected) return NO;
    while (strchr("rnNoORV", *actual) && *actual) actual++;
    return expected[0] == '@' ? actual[0] == '@' : strcmp(actual, expected) == 0;
}
BOOL LBXPresentationMethodMatches(Class cls, SEL selector, const char *returnType, const char *argumentType) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != (argumentType ? 3u : 2u)) return NO;
    char *ret = method_copyReturnType(method);
    BOOL valid = LBXTypeMatches(ret, returnType);
    free(ret);
    if (argumentType) {
        char *arg = method_copyArgumentType(method, 2);
        valid = valid && LBXTypeMatches(arg, argumentType);
        free(arg);
    }
    return valid;
}
static BOOL LBXKnownController(UIViewController *controller) {
    return [LBXEnabledClasses containsObject:NSStringFromClass(object_getClass(controller))];
}
// Reject same-named injected replacements for recovered getter implementations.
// UIKit owns the inherited table getter; other presentation getters must reside
// in the pinned host executable. These are provenance checks, not signature trust.
static BOOL LBXHostClass(Class cls) {
    const char *path = class_getImageName(cls);
    return path && [[@(path) stringByResolvingSymlinksInPath] isEqual:[NSBundle.mainBundle.executablePath stringByResolvingSymlinksInPath]];
}
static BOOL LBXGetterImage(Class cls, SEL selector) {
    Method method = class_getInstanceMethod(cls, selector); Dl_info info = {0};
    if (!method || !dladdr((const void *)method_getImplementation(method), &info) || !info.dli_fname) return NO;
    NSString *path = @(info.dli_fname);
    if (selector == @selector(tableView) && [cls isSubclassOfClass:UITableViewController.class]) {
        // These four recovered picker classes inherit UIKit's table getter.
        // Compare the class image, never another potentially replaced IMP.
        const char *systemImage = class_getImageName(UITableViewController.class);
        return systemImage && [path isEqual:@(systemImage)];
    }
    return [[path stringByResolvingSymlinksInPath] isEqual:[NSBundle.mainBundle.executablePath stringByResolvingSymlinksInPath]];
}
@interface LBXIsolationAction : NSObject
@property(nonatomic, weak) UIViewController *owner;
@property(nonatomic, strong) UIBarButtonItem *item;
- (void)openChecks:(id)sender;
@end
@implementation LBXIsolationAction
- (void)openChecks:(id)sender {
    (void)sender;
    UIViewController *owner = self.owner;
    if (!owner || SBBackendScreen(owner)!=SBScreenSettings
        || !LBXPresentationMetadataSupported(LBXMetadata(), NULL)) return;
    Class cls = NSClassFromString(@"LBXIsolationViewController");
    if (!cls || ![cls isSubclassOfClass:UIViewController.class]) {
        LBXReport(@"diagnostics controller unavailable; no navigation performed");
        return;
    }
    UINavigationController *navigation = owner.navigationController;
    // Never replace a license/modal root or interrupt an existing pushed flow.
    if (!navigation || navigation.topViewController != owner || owner.presentedViewController) return;
    UIViewController *checks = [[cls alloc] init];
    if (![checks isKindOfClass:UIViewController.class]) { LBXReport(@"diagnostics initialization failed"); return; }
    checks.hidesBottomBarWhenPushed = NO;
    [navigation pushViewController:checks animated:YES];
}
@end
static void LBXAddChecks(UIViewController *controller) {
    Class cls = NSClassFromString(@"LBXIsolationViewController");
    if (!cls || ![cls isSubclassOfClass:UIViewController.class]) {
        LBXReport(@"diagnostics controller unavailable; Settings unchanged");
        return;
    }
    LBXIsolationAction *action = objc_getAssociatedObject(controller, &LBXActionKey);
    if (!action) {
        action = [LBXIsolationAction new]; action.owner = controller;
        action.item = [[UIBarButtonItem alloc] initWithImage:SBGlyph(@"settings")
                                                     style:UIBarButtonItemStylePlain target:action action:@selector(openChecks:)];
        action.item.accessibilityLabel = @"Isolation checks";
        action.item.accessibilityHint = @"View evidence and checks that still need testing";
        action.item.accessibilityIdentifier = @"socialbox.isolation-checks";
        objc_setAssociatedObject(controller, &LBXActionKey, action, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSArray *items = controller.navigationItem.rightBarButtonItems ?: @[];
    if (![items containsObject:action.item]) controller.navigationItem.rightBarButtonItems = [items arrayByAddingObject:action.item];
}

static void LBXApply(UIViewController *controller) {
    if(!NSThread.isMainThread || !LBXInstalled || !LBXKnownController(controller)
        || !LBXPresentationMetadataSupported(LBXMetadata(),NULL) || !controller.isViewLoaded)return;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    if(!LBXWorkspaceApply(controller))SBShowUnavailable(controller,@"SB-UI-SCREEN");
    controller.view.tintColor=SBAccent();
    UINavigationBar *bar=controller.navigationController.navigationBar;
    UINavigationBarAppearance *nav=[UINavigationBarAppearance new];[nav configureWithOpaqueBackground];nav.backgroundColor=SBInk();nav.shadowColor=UIColor.clearColor;
    nav.titleTextAttributes=@{NSForegroundColorAttributeName:UIColor.whiteColor,NSFontAttributeName:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]};nav.largeTitleTextAttributes=nav.titleTextAttributes;
    bar.standardAppearance=nav;bar.scrollEdgeAppearance=nav;bar.compactAppearance=nav;bar.tintColor=SBAccent();
    if(SBBackendScreen(controller)==SBScreenSettings)LBXAddChecks(controller);
    LBXDisplayCopyApply(controller);SBWorkspaceCoordinate(controller);
    [CATransaction commit];
}
#if LBX_PRESENTATION_FIXTURE
void LBXPresentationApplyFixture(UIViewController *controller) { LBXApply(controller); }
#endif

typedef void (*LBXHookFunction)(Class, SEL, IMP, IMP *);
static void LBXInstallHook(Class cls, SEL selector, LBXHookFunction hook, BOOL animatedArgument) {
    __block IMP original = NULL;
    IMP replacement;
    if (animatedArgument) replacement = imp_implementationWithBlock(^(UIViewController *self, BOOL animated) {
        ((void (*)(id, SEL, BOOL))original)(self, selector, animated);
        LBXApply(self);
    });
    else replacement = imp_implementationWithBlock(^(UIViewController *self) {
        ((void (*)(id, SEL))original)(self, selector);
        LBXApply(self);
    });
    hook(cls, selector, replacement, &original);
}
static BOOL LBXInstallPresentationHooks(void) {
    if (!NSThread.isMainThread) { LBXReport(@"installation requires main thread"); return NO; }
    if (LBXInstalled) return YES;
    NSString *reason = nil;
    if (!LBXPresentationMetadataSupported(LBXMetadata(), &reason)) { LBXReport(reason); return NO; }
    // Check each complete screen contract before registering its lifecycle hooks.
    // Required shell mismatch rejects installation; optional forms remain original.
    NSMutableArray<NSString *> *supported = [NSMutableArray array];
    for (NSString *name in [[LBXScreens() allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        Class cls = NSClassFromString(name);
        BOOL valid = cls && [cls isSubclassOfClass:UIViewController.class] && LBXHostClass(cls)
            && LBXPresentationMethodMatches(cls, @selector(viewDidLoad), "v", NULL)
            && LBXPresentationMethodMatches(cls, @selector(viewDidLayoutSubviews), "v", NULL)
            && LBXPresentationMethodMatches(cls, @selector(viewWillAppear:), "v", @encode(BOOL));
        // Object/getter contracts are checked after construction. A mismatched
        // getter receives our unavailable screen rather than revealing legacy UI.
        if (!valid) {
            LBXReport([name stringByAppendingString:@": unsupported screen ABI; presentation unchanged"]);

        } else [supported addObject:name];
    }
    LBXHookFunction hook = (LBXHookFunction)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!hook) { LBXReport(@"compatible message-hook runtime unavailable; overlay disabled"); return NO; }
    // Do not mark an early load complete before the pinned startup class is
    // registered. The main-queue attempt below can retry without partial hooks.
    if (![supported containsObject:SBBackendSupportedClassName(SBScreenStartup)]) return NO;
    LBXEnabledClasses = [supported copy];
    for (NSString *name in LBXEnabledClasses) {
        Class cls = NSClassFromString(name);
        LBXInstallHook(cls, @selector(viewDidLoad), hook, NO);
        LBXInstallHook(cls, @selector(viewWillAppear:), hook, YES);
        LBXInstallHook(cls, @selector(viewDidLayoutSubviews), hook, NO);
        if ([LBXScreens()[name][@"type"] isEqual:@"UITableView"]) {
            SEL display = @selector(tableView:willDisplayCell:forRowAtIndexPath:);
            Method method = class_getInstanceMethod(cls, display);
            NSMethodSignature *signature = method ? [cls instanceMethodSignatureForSelector:display] : nil;
            BOOL valid = !method || (signature.numberOfArguments == 5 && !strcmp(signature.methodReturnType, "v")
                && [signature getArgumentTypeAtIndex:2][0] == '@' && [signature getArgumentTypeAtIndex:3][0] == '@'
                && [signature getArgumentTypeAtIndex:4][0] == '@');
            if (valid) {
                __block IMP original = NULL;
                IMP replacement = imp_implementationWithBlock(^(UIViewController *owner, UITableView *table, UITableViewCell *cell, NSIndexPath *index) {
                    if (original) ((void(*)(id,SEL,id,id,id))original)(owner,display,table,cell,index);
                    if (LBXKnownController(owner) && LBXPresentationMetadataSupported(LBXMetadata(), NULL)) SBSecondaryStyleTableCell(owner,table,cell,index);
                });
                if (method) hook(cls, display, replacement, &original);
                else class_addMethod(cls, display, replacement, "v40@0:8@16@24@32");
            }
            SEL headerDisplay = @selector(tableView:willDisplayHeaderView:forSection:);
            Method headerMethod = class_getInstanceMethod(cls, headerDisplay);
            // UIKit can report the protocol signature even when a concrete
            // method has a different encoding. Validate the implementation ABI.
            NSMethodSignature *headerSignature = headerMethod ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(headerMethod)] : nil;
            BOOL headerValid = !headerMethod || (headerSignature.numberOfArguments == 5
                && !strcmp(headerSignature.methodReturnType,"v")
                && !strcmp([headerSignature getArgumentTypeAtIndex:2],"@")
                && !strcmp([headerSignature getArgumentTypeAtIndex:3],"@")
                && !strcmp([headerSignature getArgumentTypeAtIndex:4],@encode(NSInteger)));
            if (headerValid) {
                __block IMP originalHeader = NULL;
                IMP replacementHeader = imp_implementationWithBlock(^(UIViewController *owner, UITableView *table, UIView *header, NSInteger section) {
                    if(originalHeader) ((void(*)(id,SEL,id,id,NSInteger))originalHeader)(owner,headerDisplay,table,header,section);
                    if(LBXKnownController(owner) && LBXPresentationMetadataSupported(LBXMetadata(),NULL))
                        SBSecondaryStyleTableHeader(owner,table,header);
                });
                if(headerMethod) hook(cls,headerDisplay,replacementHeader,&originalHeader);
                else class_addMethod(cls,headerDisplay,replacementHeader,"v40@0:8@16@24q32");
            }
        }
        // Begin reviewed native alert tint.
        if(!LBXDisplayCopyInstallNativeAccent()) LBXReport(@"native UI accent getter unavailable; alert tint remains enabled");
        SEL present = @selector(presentViewController:animated:completion:);
        NSMethodSignature *signature = [cls instanceMethodSignatureForSelector:present];
        if (signature.numberOfArguments == 5 && !strcmp(signature.methodReturnType, "v")
            && [signature getArgumentTypeAtIndex:2][0] == '@'
            && !strcmp([signature getArgumentTypeAtIndex:3], @encode(BOOL))
            && [signature getArgumentTypeAtIndex:4][0] == '@') {
            __block IMP original = NULL;
            IMP replacement = imp_implementationWithBlock(^(UIViewController *owner, UIViewController *presented, BOOL animated, void(^completion)(void)) {
                BOOL tintAlert=NO;
                if (LBXKnownController(owner) && LBXPresentationMetadataSupported(LBXMetadata(), NULL)) {
                    UIViewController *content=[presented isKindOfClass:UINavigationController.class]?((UINavigationController *)presented).viewControllers.firstObject:presented;
                    SBScreen role=SBBackendScreen(content);
                    if(role==SBScreenGuide) {
                        SBGuideViewController *guide=[SBGuideViewController new];
                        presented=[[UINavigationController alloc] initWithRootViewController:guide];
                    } else if(role==SBScreenMarket || role==SBScreenCheckout) {
                        UIViewController *page=[UIViewController new];[page loadViewIfNeeded];
                        SBShowUnavailable(page,@"SB-UI-EXTERNAL-STORE");presented=page;
                    }
                    if([objc_getAssociatedObject(owner,&LBXDiagnosticContextKey) boolValue]) LBXDisplayCopyDiagnosticAlert(presented);
                    else LBXDisplayCopyAlert(presented);
                    tintAlert=[presented isKindOfClass:UIAlertController.class];
                }
                void(^forwardedCompletion)(void)=completion;
                if(tintAlert) {
                    UIViewController *alert=presented;
                    forwardedCompletion=^{
                        LBXDisplayCopyAlertTint(alert);
                        @try { if(completion)completion(); }
                        @finally { LBXDisplayCopyAlertTint(alert); }
                    };
                }
                ((void(*)(id, SEL, id, BOOL, id))original)(owner, present, presented, animated, forwardedCompletion);
                // The original presenter may set an explicit legacy tint after
                // calling UIKit. Keep both synchronous and completed display blue.
                if(tintAlert)LBXDisplayCopyAlertTint(presented);
            });
            hook(cls, present, replacement, &original);
        }
        // End reviewed native alert tint.

    }
    for(NSDictionary *entry in SBBackendDiagnosticHooks()) {
        NSString *name=entry[@"className"];Class cls=NSClassFromString(name);SEL selector=NSSelectorFromString(entry[@"selector"]);
        Method method=class_getInstanceMethod(cls,selector);
        if(![LBXEnabledClasses containsObject:name] || !LBXPresentationMethodMatches(cls,selector,"v","@") ||
           !method || strcmp(method_getTypeEncoding(method),[entry[@"encoding"] UTF8String]) || !LBXGetterImage(cls,selector))continue;
        __block IMP original=NULL;
        IMP replacement=imp_implementationWithBlock(^(UIViewController *owner,id argument){
            BOOL classify=NSThread.isMainThread && LBXKnownController(owner) && LBXPresentationMetadataSupported(LBXMetadata(),NULL);
            if(!classify) { ((void(*)(id,SEL,id))original)(owner,selector,argument);return; }
            id previous=objc_getAssociatedObject(owner,&LBXDiagnosticContextKey);
            objc_setAssociatedObject(owner,&LBXDiagnosticContextKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            @try { ((void(*)(id,SEL,id))original)(owner,selector,argument); }
            @finally { objc_setAssociatedObject(owner,&LBXDiagnosticContextKey,previous,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        });
        hook(cls,selector,replacement,&original);
    }
    for(NSDictionary *entry in SBBackendRefreshHooks()) {
        NSString *name=entry[@"className"];Class cls=NSClassFromString(name);SEL selector=NSSelectorFromString(entry[@"selector"]);
        BOOL hasArgument=[entry[@"argumentType"] length]>0;
        const char *argument=hasArgument?[entry[@"argumentType"] UTF8String]:NULL;
        if(![LBXEnabledClasses containsObject:name] || !LBXPresentationMethodMatches(cls,selector,"v",argument) || !LBXGetterImage(cls,selector))continue;
        __block IMP original=NULL;IMP replacement;
        if(hasArgument)replacement=imp_implementationWithBlock(^(UIViewController *owner,BOOL value){((void(*)(id,SEL,BOOL))original)(owner,selector,value);LBXWorkspaceRefresh(owner);});
        else replacement=imp_implementationWithBlock(^(UIViewController *owner){((void(*)(id,SEL))original)(owner,selector);LBXWorkspaceRefresh(owner);});
        hook(cls,selector,replacement,&original);
    }
    LBXInstalled = YES;
    // Optional decoration; a loader contract mismatch leaves the original UI.
    SBSwitchProgressInstall();
    os_log(OS_LOG_DEFAULT, "LBX_PRESENTATION installed: known app UI only; no isolation assertion");
    return YES;
}
static void LBXAdoptLoadedAdmissionScreens(void) {
    // A late injector may arrive after startup or the locked license page loads.
    // Adopt only an already-loaded, registered admission screen. Never construct a view,
    // replace the root, or invoke the delegate's license/launch operations.
    UIApplication *application=UIApplication.sharedApplication;
    NSMutableSet<UIWindow *> *windows=[NSMutableSet set];
    for(UIScene *scene in application.connectedScenes)
        if([scene isKindOfClass:UIWindowScene.class]) [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    id<UIApplicationDelegate> delegate=application.delegate;
    if([delegate respondsToSelector:@selector(window)] && [delegate.window isKindOfClass:UIWindow.class]) [windows addObject:delegate.window];
    NSMutableArray<UIViewController *> *pending=[NSMutableArray array];
    for(UIWindow *window in windows) if(!window.hidden && window.rootViewController) [pending addObject:window.rootViewController];
    NSMutableSet *seen=[NSMutableSet set];
    while(pending.count && seen.count<128) {
        UIViewController *controller=pending.lastObject;[pending removeLastObject];
        if([seen containsObject:controller])continue;[seen addObject:controller];
        if(!controller.isViewLoaded)continue;
        SBScreen screen=SBBackendScreen(controller);
        if(LBXKnownController(controller) && (screen==SBScreenStartup || screen==SBScreenLicense)) LBXApply(controller);
        [pending addObjectsFromArray:controller.childViewControllers];
        if(controller.presentedViewController) [pending addObject:controller.presentedViewController];
    }
}
BOOL LBXPresentationInstall(void) {
    if(!LBXInstallPresentationHooks())return NO;
    LBXAdoptLoadedAdmissionScreens();return YES;
}
#if !LBX_PRESENTATION_FIXTURE
__attribute__((constructor)) static void LBXPresentationLoad(void) {
    @autoreleasepool {
        // The filter is repeated here so accidental loading in another process
        // cannot install even one UIKit hook.
        NSString *reason = nil;
        if (!LBXPresentationMetadataSupported(LBXMetadata(), &reason)) { LBXReport(reason); return; }
        // Install lifecycle hooks before the app builds its first controller.
        // Do not access UIApplication or create UIKit objects in the constructor.
        if(NSThread.isMainThread) LBXInstallPresentationHooks();
        dispatch_async(dispatch_get_main_queue(), ^{ LBXPresentationInstall(); });
    }
}
#endif
