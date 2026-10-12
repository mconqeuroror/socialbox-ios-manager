#import "LBXProxyInput.h"
#import "../Presentation/LBXPresentation.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <os/log.h>

extern void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *original);
static void (*LBXOriginalImport)(id,SEL,id);
static BOOL LBXProxyHookInstalled;
static BOOL LBXProxyCompatible;

static void LBXPresentInputIssue(UIViewController *owner,NSString *message,unsigned attempt) {
    if(!owner.isViewLoaded||!owner.view.window)return;
    UIViewController *target=owner;
    BOOL transitioning=NO;
    for(;;) {
        transitioning|=target.isBeingPresented||target.isBeingDismissed||target.transitionCoordinator!=nil;
        if(!target.presentedViewController)break;
        target=target.presentedViewController;
    }
    if(transitioning) {
        // UIKit can call coordinator completion BEFORE clearing the presented
        // controller. Re-check the hierarchy on a later main-loop turn instead
        // of dropping the error or presenting on the departing input alert.
        if(attempt>=40) {
            os_log_error(OS_LOG_DEFAULT,"LBX_PROXY_INPUT error presentation deferred beyond transition limit");
            return;
        }
        __weak UIViewController *weakOwner=owner;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            LBXPresentInputIssue(weakOwner,message,attempt+1);
        });
        return;
    }
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Check proxy input" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [target presentViewController:alert animated:YES completion:nil];
}
static void LBXInputIssue(UIViewController *owner,NSString *message) {
    // An off-screen programmatic import must not queue an alert for a later tab.
    if(!owner.isViewLoaded||!owner.view.window)return;
    __weak UIViewController *weakOwner=owner;
    dispatch_async(dispatch_get_main_queue(),^{LBXPresentInputIssue(weakOwner,message,0);});
}
static void LBXImportInput(id receiver,SEL command,id input) {
    if(!LBXProxyCompatible||![NSStringFromClass(object_getClass(receiver)) isEqual:@"ProxyViewController"]) {
        LBXOriginalImport(receiver,command,input);return;
    }
    if(!NSThread.isMainThread) {
        id snapshot=[input isKindOfClass:NSString.class]?[input copy]:nil;
        dispatch_async(dispatch_get_main_queue(),^{LBXImportInput(receiver,command,snapshot);});return;
    }
    LBXProxyInputPlan *plan=LBXPlanProxyInput(input);
    if(plan.useOriginalInput) {LBXOriginalImport(receiver,command,input);return;}
    NSError *error=nil;
    if(plan.issue||!LBXDispatchProxyInput(receiver,plan,&error))LBXInputIssue(receiver,plan.issue?:error.localizedDescription);
}
static BOOL LBXInstallProxyInput(NSDictionary *metadata) {
    if(LBXProxyHookInstalled)return YES;
    if(!LBXPresentationMetadataSupported(metadata,NULL))return NO;
    Class cls=NSClassFromString(@"ProxyViewController");
    if(!cls||![cls isSubclassOfClass:UIViewController.class])return NO;
    SEL sel=NSSelectorFromString(@"importFromInput:");Method found=NULL;unsigned count=0;
    Method *methods=class_copyMethodList(cls,&count);
    for(unsigned i=0;i<count;i++)if(method_getName(methods[i])==sel){found=methods[i];break;}
    free(methods);
    if(!found||strcmp(method_getTypeEncoding(found),"v24@0:8@16"))return NO;
    Dl_info image={0};
    if(!dladdr((void *)method_getImplementation(found),&image)||!image.dli_fname)return NO;
    if(![[@(image.dli_fname) stringByResolvingSymlinksInPath] isEqual:[NSBundle.mainBundle.executablePath stringByResolvingSymlinksInPath]])return NO;
    IMP previous=method_getImplementation(found), chained=NULL;
    LBXOriginalImport=(void(*)(id,SEL,id))previous;
    MSHookMessageEx(cls,sel,(IMP)LBXImportInput,&chained);
    if(chained)LBXOriginalImport=(void(*)(id,SEL,id))chained;
    LBXProxyCompatible=chained!=NULL&&method_getImplementation(found)==(IMP)LBXImportInput;
    LBXProxyHookInstalled=LBXProxyCompatible;
    return LBXProxyHookInstalled;
}
#if LBX_PROXY_INPUT_FIXTURE
BOOL LBXInstallProxyInputFixture(NSDictionary *metadata){return LBXInstallProxyInput(metadata);}
#else
__attribute__((constructor)) static void LBXProxyInputInitialize(void) {
    dispatch_async(dispatch_get_main_queue(),^{
        if(!LBXInstallProxyInput(NSBundle.mainBundle.infoDictionary))
            os_log_error(OS_LOG_DEFAULT,"LBX_PROXY_INPUT unsupported host/method; original handler retained");
    });
}
#endif
