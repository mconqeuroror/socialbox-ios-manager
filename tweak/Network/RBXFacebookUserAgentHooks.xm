#import "RBXFacebookUserAgentHooks.h"
#import "RBXFacebookUserAgent.h"
#import "RBXAppRuntime.h"
#import "RBXHookInstallation.h"
#import "RBXContainerManager.h"
#import "RBXProfile.h"
#import "RBXLog.h"
#import <dlfcn.h>

static NSString *(*fbua_original)(uintptr_t flavor);
static NSDictionary *fbua_values;
static NSString *fbua_bundle, *fbua_container;
static BOOL fbua_attempted, fbua_installed;

// FBUA-001: the audited C producer takes a flavor word and returns an
// autoreleased NSString. Preserve every flavor bit and call the producer once.
static NSString *fbua_userAgent(uintptr_t flavor) {
    NSString *(*original)(uintptr_t);
    NSDictionary *values;
    @synchronized (RBXContainerManager.class) {
        if (!fbua_installed) return nil;
        original = fbua_original;
        values = fbua_values;
    }
    if (!original) return nil;
    NSString *produced = original(flavor);
    if (!produced) return nil;
    NSString *rewritten = RBXRewriteFacebookUserAgent(produced, values);
    if (!rewritten) {
        static dispatch_once_t warning;
        dispatch_once(&warning, ^{
            RBXLogErr("RBX_FACEBOOK_UA unsupported producer output; physical UA withheld");
        });
    }
    return rewritten;
}

BOOL RBXInstallFacebookUserAgentHooks(RBXDeviceProfile *profile) {
    @synchronized (RBXContainerManager.class) {
        RBXContainerManager *manager = RBXContainerManager.sharedManager;
        NSDictionary *raw = profile.rawProfile;
        NSDictionary *descriptor = RBXAppDescriptorForProfile(raw);
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        if (!manager.validatedProfileLoaded || manager.currentProfile != profile ||
            ![descriptor[@"appType"] isEqual:@"facebook"] || ![descriptor[@"runnable"] boolValue] ||
            !RBXAppRuntimeProfileMatchesBundle(raw, bundle) ||
            ![manager.containerId isEqual:raw[@"containerId"]]) return NO;
        NSDictionary *app = raw[@"app"];
        // Exact source/version boundary: a later Facebook binary needs new
        // producer evidence before this ABI or output grammar is reused.
        if (![app[@"sourceVersion"] isEqual:@"578.1.0"] ||
            ![app[@"sourceBuild"] isEqual:@"1063022819"] ||
            ![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:@"578.1.0"] ||
            ![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:@"1063022819"]) return NO;
        NSDictionary *values = RBXFacebookUAValuesForProfile(raw);
        if (!values) return NO;
        if (fbua_attempted) return fbua_installed && [fbua_values isEqual:values] &&
            [fbua_bundle isEqual:bundle] && [fbua_container isEqual:manager.containerId];
        void *producer = dlsym(RTLD_DEFAULT, "FBUserAgent");
        Dl_info info = {};
        if (!producer || !dladdr(producer, &info) || !info.dli_fname) return NO;
        NSString *image = [NSString stringWithUTF8String:info.dli_fname];
        NSString *expected = [NSBundle.mainBundle.bundlePath
            stringByAppendingPathComponent:@"Frameworks/FBSharedFramework.framework/FBSharedFramework"];
        if (!image.length || !expected.length ||
            ![image.stringByResolvingSymlinksInPath isEqual:expected.stringByResolvingSymlinksInPath]) return NO;
        // Bind copies before interception and never layer a second hook over a
        // failed attempt. Both installation and wrapper publication share a lock.
        NSMutableDictionary *immutableValues = [NSMutableDictionary dictionary];
        for (NSString *key in values) immutableValues[key] = [values[key] copy];
        fbua_values = immutableValues.copy;
        fbua_bundle = bundle.copy;
        fbua_container = manager.containerId.copy;
        fbua_attempted = YES;
        MSHookFunction(producer, (void *)fbua_userAgent, (void **)&fbua_original);
        fbua_installed = RBXHookInstallationPassed();
        return fbua_installed;
    }
}
