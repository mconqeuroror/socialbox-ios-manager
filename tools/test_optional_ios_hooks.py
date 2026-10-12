#!/usr/bin/env python3
"""Run generated production Logos methods against observable iOS API fixtures.

The WKPreferences selectors are from iOS 16.7.16 runtime enumeration. Test both
presence and absence of the optional UIApplication registration API. This is
API behavior coverage, not WebKit network process or APNs device acceptance.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
THEOS = Path(os.environ["THEOS"])
base = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CommonCrypto/CommonDigest.h>
#import "RBXHookInstallation.h"
#undef MSHookMessageEx
#undef MSHookFunction
void MSHookFunction(void *s, void *r, void **o) { *o = s; }
void MSHookMessageEx(Class c, SEL s, IMP r, IMP *o) {
    Method m = class_getInstanceMethod(c,s);
    if(!m) { *o=NULL; return; }
    *o=method_getImplementation(m);
    class_replaceMethod(c,s,r,method_getTypeEncoding(m));
}
#define MSHookMessageEx RBXCheckedHookMessage
#define MSHookFunction RBXCheckedHookFunction
#define RBXLog(...) ((void)0)
#define RBXLogErr(...) ((void)0)
static void Check(BOOL ok, const char *reason) {
    if(!ok) { fprintf(stderr,"FAIL: %s\n",reason); exit(1); }
}
@interface RBXContainerManager : NSObject
@property NSString *containerId;
+ (instancetype)sharedManager;
@end
@implementation RBXContainerManager
+ (instancetype)sharedManager { static id obj=[self new]; return obj; }
@end
'''
web = r'''
static BOOL lease,auth;
static unsigned requestCalls;
static BOOL RBXNetworkLeaseAllowsCurrentContainer(void) { return lease; }
static BOOL RBXSystemFirewallCoversOutOfProcessAuth(void) { return auth; }
@interface WKPreferences : NSObject
@property BOOL peer,media;
- (BOOL)_peerConnectionEnabled;
- (void)_setPeerConnectionEnabled:(BOOL)b;
- (BOOL)_mediaDevicesEnabled;
- (void)_setMediaDevicesEnabled:(BOOL)b;
@end
@implementation WKPreferences
- (BOOL)_peerConnectionEnabled { return _peer; }
- (void)_setPeerConnectionEnabled:(BOOL)b { _peer=b; }
- (BOOL)_mediaDevicesEnabled { return _media; }
- (void)_setMediaDevicesEnabled:(BOOL)b { _media=b; }
@end
@interface WKWebViewConfiguration : NSObject
@property WKPreferences *preferences;
@end
@implementation WKWebViewConfiguration
@end
@interface WKNavigation : NSObject @end
@implementation WKNavigation @end
@interface WKWebView : NSObject
- (WKNavigation *)loadRequest:(NSURLRequest *)r;
- (WKNavigation *)loadHTMLString:(NSString *)s baseURL:(NSURL *)u;
@end
@implementation WKWebView
- (WKNavigation *)loadRequest:(NSURLRequest *)r { requestCalls++; return [WKNavigation new]; }
- (WKNavigation *)loadHTMLString:(NSString *)s baseURL:(NSURL *)u { Check(!u,"HTML cannot inherit network base URL"); return nil; }
@end
@interface ASWebAuthenticationSession : NSObject
@property BOOL prefersEphemeralWebBrowserSession;
- (BOOL)start;
@end
@implementation ASWebAuthenticationSession
- (BOOL)start { return YES; }
@end
// GENERATED
int main(void) { @autoreleasepool {
    Check(RBXInstallWebStorageHooks(),"actual iOS underscore WebKit selectors install successfully");
    WKPreferences *p=[WKPreferences new]; p.peer=p.media=YES;
    WKWebViewConfiguration *c=[WKWebViewConfiguration new]; c.preferences=p;
    Check(!c.preferences.peer&&!c.preferences.media,"configuration disables underlying native capabilities");
    [p _setPeerConnectionEnabled:YES]; [p _setMediaDevicesEnabled:YES];
    Check(!p.peer&&!p.media&&![p _peerConnectionEnabled]&&![p _mediaDevicesEnabled],"app cannot reenable native WebRTC preferences");
    WKWebView *w=[WKWebView new]; Check(![w loadRequest:nil]&&!requestCalls,"CLOSED request withheld");
    lease=YES; Check([w loadRequest:nil]&&requestCalls==1,"leased request forwarded");
    [w loadHTMLString:@"x" baseURL:[NSURL URLWithString:@"https://example.test"]];
    ASWebAuthenticationSession *s=[ASWebAuthenticationSession new]; Check(![s start],"uncovered out-of-process auth denied");
    auth=YES; Check([s start]&&s.prefersEphemeralWebBrowserSession,"covered auth forced ephemeral");
    [s setPrefersEphemeralWebBrowserSession:NO]; Check(s.prefersEphemeralWebBrowserSession,"ephemeral cannot be disabled");
    puts("PASS actual WebKit selectors, underlying capability suppression, lease gate and ephemeral authentication");
} }
'''
push = r'''
static BOOL RBXAppRuntimeHooksEnabled(void) { return NO; }
static unsigned registrations;
@interface UIApplication : NSObject
@property id delegate;
+ (instancetype)sharedApplication;
- (void)registerForRemoteNotifications;
- (BOOL)isRegisteredForRemoteNotifications;
@end
@implementation UIApplication
+ (instancetype)sharedApplication { static id a=[self new]; return a; }
- (void)registerForRemoteNotifications { registrations++; }
- (BOOL)isRegisteredForRemoteNotifications { return YES; }
@end
typedef NSString *PKPushType;
@interface PKPushRegistry : NSObject
@property NSSet<PKPushType> *desiredPushTypes;
- (NSData *)pushTokenForType:(PKPushType)t;
@end
@implementation PKPushRegistry
- (NSData *)pushTokenForType:(PKPushType)t { return [@"physical" dataUsingEncoding:NSUTF8StringEncoding]; }
@end
static void NativeMatching(id s,SEL cmd,NSInteger options,void (^completion)(NSError *)) { registrations++; }
// GENERATED
int main(int argc,char **argv) { @autoreleasepool {
    BOOL available=argc==2&&!strcmp(argv[1],"present");
    SEL optional=NSSelectorFromString(@"registerForRemoteNotificationsMatching:completionHandler:");
    if(available)class_addMethod(UIApplication.class,optional,(IMP)NativeMatching,"v@:q@?");
    Check(RBXInstallPushHooks(),"push readiness accepts absent optional API; all installed methods verified");
    Check([UIApplication instancesRespondToSelector:optional]==available,"absent API is not invented by hook installation");
    UIApplication *a=UIApplication.sharedApplication;
    [a registerForRemoteNotifications];Check(!registrations&&![a isRegisteredForRemoteNotifications],"normal push registration remains suppressed");
    if(available) { __block BOOL called=NO; void (^completion)(NSError *)=^(NSError *e){ called=e.code==1; };
        ((void(*)(id,SEL,NSInteger,id))[a methodForSelector:optional])(a,optional,7,completion);
        Check(called&&!registrations,"optional API reports failure and never registers"); }
    PKPushRegistry *p=[PKPushRegistry new];p.desiredPushTypes=[NSSet setWithObject:@"voip"];
    Check(p.desiredPushTypes.count==0&&![p pushTokenForType:@"voip"],"PushKit registration and hardware token blocked");
    puts("PASS push API availability, registration suppression and PushKit boundary");
} }
'''
with tempfile.TemporaryDirectory(prefix="rbx-ios-hooks-") as temp:
    directory = Path(temp)
    for name, path, fixture, modes in [
        ("web", "tweak/Container/RBXWebStorageHooks.xm", web, ["default"]),
        ("push", "tweak/LeakDetection/RBXPushHooks.xm", push, ["absent", "present"]),
    ]:
        generated = subprocess.check_output(["perl", str(THEOS / "bin/logos.pl"), str(ROOT / path)], text=True)
        body = "\n".join(line for line in generated.splitlines() if not line.startswith(("#import", "#include <substrate.h>", '__asm__(".linker_option')))
        source = directory / (name + ".mm")
        source.write_text(base + fixture.replace("// GENERATED", body))
        binary = directory / name
        subprocess.run(["xcrun", "clang++", "-std=c++17", "-fobjc-arc", "-fblocks",
                        "-Wno-deprecated-declarations", "-Wno-nullability-completeness",
                        "-I" + str(THEOS / "vendor/include"), "-F" + str(THEOS / "vendor/lib"),
                        "-I" + str(ROOT / "tweak/Common"), "-framework", "Foundation",
                        str(source), "-o", str(binary)], check=True)
        for mode in modes:
            subprocess.run([str(binary), mode], check=True)
