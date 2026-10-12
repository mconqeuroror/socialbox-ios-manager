#import "LBXDisplayCopy.h"
#import "SBLegacyDisplayCatalog.h"
#import "SBDesign.h"
#import "SBBackendAdapter.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <ptrauth.h>
#import <math.h>

static IMP NativeAccentOriginal,NativeSystemOrangeOriginal,NativeRGBOriginal;
static BOOL NativeColorCaller(const void *caller) {
    Dl_info origin={0};
    return SBBackendMetadataSupported(SBBackendAppMetadata(),NULL) && dladdr(caller,&origin)
        && origin.dli_fname && [@(origin.dli_fname).stringByResolvingSymlinksInPath
            isEqual:NSBundle.mainBundle.executablePath.stringByResolvingSymlinksInPath];
}
static UIColor *NativeAccent(id theme,SEL selector) {
    if(SBBackendMetadataSupported(SBBackendAppMetadata(),NULL)) return SBAccent();
    return ((UIColor *(*)(id,SEL))NativeAccentOriginal)(theme,selector);
}
static UIColor *NativeSystemOrange(id colorClass,SEL selector) {
    void *caller=__builtin_return_address(0);
#if __has_feature(ptrauth_calls)
    caller=ptrauth_strip(caller,ptrauth_key_return_address);
#endif
    if(NativeColorCaller(caller)) return SBAccent();
    return ((UIColor *(*)(id,SEL))NativeSystemOrangeOriginal)(colorClass,selector);
}
static UIColor *NativeRGB(id colorClass,SEL selector,CGFloat red,CGFloat green,CGFloat blue,CGFloat alpha) {
    void *caller=__builtin_return_address(0);
#if __has_feature(ptrauth_calls)
    caller=ptrauth_strip(caller,ptrauth_key_return_address);
#endif
    // These are the three observed constant triples in the retained native UI:
    // actions/LocSim, the theme/mesh orb and the QR scanner corners/flash.
    BOOL orange=(fabs(red-1)<.000001 && fabs(blue)<.000001
        && (fabs(green-.4)<.000001 || fabs(green-.584)<.000001))
        || (fabs(red-.85)<.000001 && fabs(green-.35)<.000001 && fabs(blue-.15)<.000001);
    if(orange && NativeColorCaller(caller)) { red=0;green=122.0/255.0;blue=1; }
    return ((UIColor *(*)(id,SEL,CGFloat,CGFloat,CGFloat,CGFloat))NativeRGBOriginal)(colorClass,selector,red,green,blue,alpha);
}
BOOL LBXDisplayCopyInstallNativeAccent(void) {
    if(!NSThread.isMainThread || !SBBackendMetadataSupported(SBBackendAppMetadata(),NULL)) return NO;
    if(NativeAccentOriginal || NativeSystemOrangeOriginal || NativeRGBOriginal)
        return NativeAccentOriginal && NativeSystemOrangeOriginal && NativeRGBOriginal;
    // The recovered theme is still used by native creation/proxy dialogs and
    // their containing window. Replace its one orange accent getter, retaining
    // all native presentation, fields, actions and semantic status colors.
    // Recovered 3.1.0/build 1: _Xth1 +primaryColor, arm64 0x10022415c.
    Class theme=NSClassFromString(@"_Xth1");
    SEL selector=NSSelectorFromString(@"primaryColor");
    Method method=theme?class_getClassMethod(theme,selector):NULL;
    const char *image=theme?class_getImageName(theme):NULL;
    Dl_info implementation={0};
    NSString *host=NSBundle.mainBundle.executablePath.stringByResolvingSymlinksInPath;
    if(!method || !image || ![@(image).stringByResolvingSymlinksInPath isEqual:host]
        || strcmp(method_getTypeEncoding(method),"@16@0:8")
        || !dladdr((const void *)method_getImplementation(method),&implementation)
        || !implementation.dli_fname
        || ![@(implementation.dli_fname).stringByResolvingSymlinksInPath isEqual:host]) return NO;
    // Seven recovered native UI call sites also request Apple's orange directly
    // (including the retained map marker and proxy rotation switch). Only a
    // caller in this exact manager executable receives brand blue. UIKit and
    // other images retain the original public system-color getter.
    SEL systemSelector=@selector(systemOrangeColor);
    Method systemMethod=class_getClassMethod(UIColor.class,systemSelector);
    const char *systemImage=class_getImageName(UIColor.class);
    Dl_info systemImplementation={0};
    if(!systemMethod || !systemImage || strcmp(method_getTypeEncoding(systemMethod),"@16@0:8")
        || !dladdr((const void *)method_getImplementation(systemMethod),&systemImplementation)
        || !systemImplementation.dli_fname || strcmp(systemImage,systemImplementation.dli_fname)) return NO;
    SEL rgbSelector=@selector(colorWithRed:green:blue:alpha:);
    Method rgbMethod=class_getClassMethod(UIColor.class,rgbSelector);
    Dl_info rgbImplementation={0};
    if(!rgbMethod || strcmp(method_getTypeEncoding(rgbMethod),"@48@0:8d16d24d32d40")
        || !dladdr((const void *)method_getImplementation(rgbMethod),&rgbImplementation)
        || !rgbImplementation.dli_fname || strcmp(systemImage,rgbImplementation.dli_fname)) return NO;
    void(*hook)(Class,SEL,IMP,IMP *)=(void *)dlsym(RTLD_DEFAULT,"MSHookMessageEx");
    if(!hook) return NO;
    hook(object_getClass(theme),selector,(IMP)NativeAccent,&NativeAccentOriginal);
    hook(object_getClass(UIColor.class),systemSelector,(IMP)NativeSystemOrange,&NativeSystemOrangeOriginal);
    hook(object_getClass(UIColor.class),rgbSelector,(IMP)NativeRGB,&NativeRGBOriginal);
    return NativeAccentOriginal && NativeSystemOrangeOriginal && NativeRGBOriginal;
}

NSString *LBXDisplayCopy(NSString *text) {
    return SBLegacyFixedDisplayText(text);
}
NSString *LBXDisplayText(NSString *text, LBXDisplayTextRole role) {
    switch(role) {
        case LBXDisplayTextRoleFixed: return SBLegacyFixedDisplayText(text);
        case LBXDisplayTextRoleStatus: return SBLegacyStatusDisplayText(text);
        case LBXDisplayTextRoleDiagnostic: return SBLegacyDiagnosticDisplayText(text);
        case LBXDisplayTextRoleUserData: return text;
    }
    return text;
}
NSString *LBXDisplayActionTitle(NSString *title) {
    return SBLegacyFixedDisplayText(title);
}
static char DisplayRoleKey;
void LBXDisplayCopySetRole(UILabel *label, LBXDisplayTextRole role) {
    if(!label) return;
    objc_setAssociatedObject(label,&DisplayRoleKey,@(role),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    label.text=LBXDisplayText(label.text,role);
}
void LBXDisplayCopyApply(UIViewController *controller) {
    NSMutableArray *pending=[NSMutableArray arrayWithObject:controller.view];
    while(pending.count) {
        UIView *view=pending.lastObject; [pending removeLastObject];
        // Public input/control values and custom user images are never renamed.
        if([view isKindOfClass:UIControl.class] || [view isKindOfClass:UITextView.class]) continue;
        if([view isKindOfClass:UILabel.class] && !view.userInteractionEnabled && !view.gestureRecognizers.count) {
            NSNumber *role=objc_getAssociatedObject(view,&DisplayRoleKey);
            if(!role) continue;
            UILabel *label=(id)view; NSString *mapped=LBXDisplayText(label.text,role.unsignedIntegerValue);
            if(![mapped isEqual:label.text]) label.text=mapped;
        }
        [pending addObjectsFromArray:view.subviews];
    }
}
void LBXDisplayCopyAlertTint(UIViewController *presented) {
    if(!NSThread.isMainThread || ![presented isKindOfClass:UIAlertController.class]) return;
    // Normal and Cancel actions inherit this public tint. Destructive actions
    // retain UIKit's semantic treatment; no readonly/private action field changes.
    presented.view.tintColor=SBAccent();
}
void LBXDisplayCopyAlert(UIViewController *presented) {
    if(![presented isKindOfClass:UIAlertController.class]) return;
    UIAlertController *alert=(id)presented;
    LBXDisplayCopyAlertTint(alert);
    alert.title=SBLegacyFixedDisplayText(alert.title);
    alert.message=SBLegacyReviewedDisplayText(alert.message);
    // UIAlertAction.title is readonly. Preserve the original action objects,
    // handlers, enabled states, preferred action, styles, fields and delegates.
    // Unknown confirmation prose may contain user names; never scrub it.
}
void LBXDisplayCopyDiagnosticAlert(UIViewController *presented) {
    if(![presented isKindOfClass:UIAlertController.class]) return;
    UIAlertController *alert=(id)presented;
    LBXDisplayCopyAlertTint(alert);
    alert.title=SBLegacyStatusDisplayText(alert.title);
    alert.message=SBLegacyDiagnosticDisplayText(alert.message);
}
