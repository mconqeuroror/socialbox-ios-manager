#import "RBXFacebookStorageHooks.h"
#import "RBXFacebookStoragePolicy.h"
#import "RBXFacebookPrivateGroupStore.h"
#import "RBXAppRuntime.h"
#import "RBXContainerManager.h"
#import "RBXHookInstallation.h"
#import "RBXLog.h"

static NSString *fbstore_bundle, *fbstore_container;
static BOOL fbstore_attempted, fbstore_enabled;
static BOOL fbstore_ready(void) { return __atomic_load_n(&fbstore_enabled,__ATOMIC_ACQUIRE); }

static NSString *fbstore_domain(id domain, BOOL persistentWrite) {
    if (!fbstore_ready()) return nil;
    NSString *mapped=nil;
    if (!RBXFacebookMapStorageDomain(fbstore_bundle, domain, &mapped)) return nil;
    if (persistentWrite && ![mapped isEqual:fbstore_bundle] &&
        ![mapped hasPrefix:[fbstore_bundle stringByAppendingString:@".sbx-storage.v1."]]) return nil;
    return mapped;
}
static NSString *fbstore_cfDomain(CFStringRef domain, BOOL writing) {
    if (!fbstore_ready() || !domain || CFGetTypeID(domain)!=CFStringGetTypeID()) return NULL;
    if (CFEqual(domain,kCFPreferencesCurrentApplication)) return fbstore_bundle;
    if (CFEqual(domain,kCFPreferencesAnyApplication)) return writing ? nil : (__bridge NSString *)domain;
    return fbstore_domain((__bridge id)domain,writing);
}
static BOOL fbstore_cfOwner(CFStringRef user, CFStringRef host) {
    return user && host && CFEqual(user,kCFPreferencesCurrentUser) &&
        (CFEqual(host,kCFPreferencesAnyHost)||CFEqual(host,kCFPreferencesCurrentHost));
}
// Domain-only adapters: key/value bytes, native types, return ownership and
// caller-supplied host scopes stay intact. Unknown/foreign domains never retry.
static CFPropertyListRef (*fbstore_orig_CopyAppValue)(CFStringRef,CFStringRef);
static void (*fbstore_orig_SetAppValue)(CFStringRef,CFPropertyListRef,CFStringRef);
static Boolean (*fbstore_orig_AppSynchronize)(CFStringRef);
static Boolean (*fbstore_orig_GetAppBooleanValue)(CFStringRef,CFStringRef,Boolean *);
static CFIndex (*fbstore_orig_GetAppIntegerValue)(CFStringRef,CFStringRef,Boolean *);
static CFPropertyListRef (*fbstore_orig_CopyValue)(CFStringRef,CFStringRef,CFStringRef,CFStringRef);
static void (*fbstore_orig_SetValue)(CFStringRef,CFPropertyListRef,CFStringRef,CFStringRef,CFStringRef);
static CFDictionaryRef (*fbstore_orig_CopyMultiple)(CFArrayRef,CFStringRef,CFStringRef,CFStringRef);
static void (*fbstore_orig_SetMultiple)(CFDictionaryRef,CFArrayRef,CFStringRef,CFStringRef,CFStringRef);
static CFArrayRef (*fbstore_orig_CopyKeyList)(CFStringRef,CFStringRef,CFStringRef);
static Boolean (*fbstore_orig_Synchronize)(CFStringRef,CFStringRef,CFStringRef);
static void (*fbstore_orig_AddSuitePreferencesToApp)(CFStringRef,CFStringRef);
static void (*fbstore_orig_RemoveSuitePreferencesFromApp)(CFStringRef,CFStringRef);
static Boolean (*fbstore_orig_AppValueIsForced)(CFStringRef,CFStringRef);
static CFPropertyListRef fbstore_CopyAppValue(CFStringRef key,CFStringRef app) {
    NSString *mapped=fbstore_cfDomain(app,NO);
    return mapped && fbstore_orig_CopyAppValue ? fbstore_orig_CopyAppValue(key,(__bridge CFStringRef)mapped) : NULL;
}
static void fbstore_SetAppValue(CFStringRef key,CFPropertyListRef value,CFStringRef app) {
    NSString *mapped=fbstore_cfDomain(app,YES);
    if(mapped && fbstore_orig_SetAppValue) fbstore_orig_SetAppValue(key,value,(__bridge CFStringRef)mapped);
}
static Boolean fbstore_AppSynchronize(CFStringRef app) {
    NSString *mapped=fbstore_cfDomain(app,YES);
    return mapped && fbstore_orig_AppSynchronize ? fbstore_orig_AppSynchronize((__bridge CFStringRef)mapped) : false;
}
static Boolean fbstore_GetAppBooleanValue(CFStringRef key,CFStringRef app,Boolean *valid) {
    NSString *mapped=fbstore_cfDomain(app,NO);
    if(mapped && fbstore_orig_GetAppBooleanValue) return fbstore_orig_GetAppBooleanValue(key,(__bridge CFStringRef)mapped,valid);
    if(valid)*valid=false;return false;
}
static CFIndex fbstore_GetAppIntegerValue(CFStringRef key,CFStringRef app,Boolean *valid) {
    NSString *mapped=fbstore_cfDomain(app,NO);
    if(mapped && fbstore_orig_GetAppIntegerValue) return fbstore_orig_GetAppIntegerValue(key,(__bridge CFStringRef)mapped,valid);
    if(valid)*valid=false;return 0;
}
static CFPropertyListRef fbstore_CopyValue(CFStringRef key,CFStringRef app,CFStringRef user,CFStringRef host) {
    NSString *mapped=fbstore_cfDomain(app,NO);
    return mapped && fbstore_cfOwner(user,host) && fbstore_orig_CopyValue ? fbstore_orig_CopyValue(key,(__bridge CFStringRef)mapped,user,host) : NULL;
}
static void fbstore_SetValue(CFStringRef key,CFPropertyListRef value,CFStringRef app,CFStringRef user,CFStringRef host) {
    NSString *mapped=fbstore_cfDomain(app,YES);
    if(mapped && fbstore_cfOwner(user,host) && fbstore_orig_SetValue)fbstore_orig_SetValue(key,value,(__bridge CFStringRef)mapped,user,host);
}
static CFDictionaryRef fbstore_CopyMultiple(CFArrayRef keys,CFStringRef app,CFStringRef user,CFStringRef host) {
    NSString *mapped=fbstore_cfDomain(app,NO);
    return mapped && fbstore_cfOwner(user,host) && fbstore_orig_CopyMultiple ? fbstore_orig_CopyMultiple(keys,(__bridge CFStringRef)mapped,user,host) : NULL;
}
static void fbstore_SetMultiple(CFDictionaryRef values,CFArrayRef removed,CFStringRef app,CFStringRef user,CFStringRef host) {
    NSString *mapped=fbstore_cfDomain(app,YES);
    if(mapped && fbstore_cfOwner(user,host) && fbstore_orig_SetMultiple)fbstore_orig_SetMultiple(values,removed,(__bridge CFStringRef)mapped,user,host);
}
static CFArrayRef fbstore_CopyKeyList(CFStringRef app,CFStringRef user,CFStringRef host) {
    NSString *mapped=fbstore_cfDomain(app,NO);
    return mapped && fbstore_cfOwner(user,host) && fbstore_orig_CopyKeyList ? fbstore_orig_CopyKeyList((__bridge CFStringRef)mapped,user,host) : NULL;
}
static Boolean fbstore_Synchronize(CFStringRef app,CFStringRef user,CFStringRef host) {
    NSString *mapped=fbstore_cfDomain(app,YES);
    return mapped && fbstore_cfOwner(user,host) && fbstore_orig_Synchronize ? fbstore_orig_Synchronize((__bridge CFStringRef)mapped,user,host) : false;
}
static void fbstore_AddSuitePreferencesToApp(CFStringRef app,CFStringRef suite) {
    NSString *parent=fbstore_cfDomain(app,YES), *child=fbstore_cfDomain(suite,NO);
    if(parent && child && fbstore_orig_AddSuitePreferencesToApp)fbstore_orig_AddSuitePreferencesToApp((__bridge CFStringRef)parent,(__bridge CFStringRef)child);
}
static void fbstore_RemoveSuitePreferencesFromApp(CFStringRef app,CFStringRef suite) {
    NSString *parent=fbstore_cfDomain(app,YES), *child=fbstore_cfDomain(suite,NO);
    if(parent && child && fbstore_orig_RemoveSuitePreferencesFromApp)fbstore_orig_RemoveSuitePreferencesFromApp((__bridge CFStringRef)parent,(__bridge CFStringRef)child);
}
static Boolean fbstore_AppValueIsForced(CFStringRef key,CFStringRef app) {
    NSString *mapped=fbstore_cfDomain(app,NO);
    return mapped && fbstore_orig_AppValueIsForced ? fbstore_orig_AppValueIsForced(key,(__bridge CFStringRef)mapped) : false;
}

%group FacebookStorage
%hook NSUserDefaults
- (instancetype)initWithSuiteName:(NSString *)suite {
    if (!fbstore_ready()) return nil;
    if (!suite) return %orig(nil);
    // Suite objects expose unrestricted native setters: only private domains
    // may become mutable objects. Platform values remain available via reads.
    NSString *mapped=fbstore_domain(suite,YES);
    if (!mapped) return nil;
    return %orig(mapped);
}
- (void)addSuiteNamed:(NSString *)suite {
    NSString *mapped=fbstore_domain(suite,NO);
    if (mapped) {
        %orig(mapped);
    }
}
- (void)removeSuiteNamed:(NSString *)suite {
    NSString *mapped=fbstore_domain(suite,NO);
    if (mapped) {
        %orig(mapped);
    }
}
- (NSDictionary *)persistentDomainForName:(NSString *)name {
    NSString *mapped=fbstore_domain(name,NO);
    if (!mapped) return nil;
    return %orig(mapped);
}
- (void)setPersistentDomain:(NSDictionary *)values forName:(NSString *)name {
    NSString *mapped=fbstore_domain(name,YES);
    if (mapped) {
        %orig(values,mapped);
    }
}
- (void)removePersistentDomainForName:(NSString *)name {
    NSString *mapped=fbstore_domain(name,YES);
    if (mapped) {
        %orig(mapped);
    }
}
- (NSDictionary *)volatileDomainForName:(NSString *)name {
    NSString *mapped=fbstore_domain(name,NO);
    if (!mapped) return @{};
    return %orig(mapped);
}
- (void)setVolatileDomain:(NSDictionary *)values forName:(NSString *)name {
    NSString *mapped=fbstore_domain(name,NO);
    if (mapped) {
        %orig(values,mapped);
    }
}
- (void)removeVolatileDomainForName:(NSString *)name {
    NSString *mapped=fbstore_domain(name,NO);
    if (mapped) {
        %orig(mapped);
    }
}
%end
%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)identifier {
    if (!fbstore_ready()) return nil;
    return RBXFacebookPrivateGroupURL(fbstore_bundle,identifier,NSHomeDirectory());
}
%end
%end

BOOL RBXInstallFacebookStorageHooks(RBXContainerManager *manager) {
    @synchronized(RBXContainerManager.class) {
        NSDictionary *raw=manager.currentProfile.rawProfile, *app=raw[@"app"];
        NSDictionary *descriptor=RBXAppDescriptorForProfile(raw);
        NSString *bundle=NSBundle.mainBundle.bundleIdentifier;
        if(!manager.validatedProfileLoaded || ![descriptor[@"appType"] isEqual:@"facebook"] ||
            ![descriptor[@"runnable"] boolValue] || ![manager.containerId isEqual:raw[@"containerId"]] ||
            !RBXAppRuntimeProfileMatchesBundle(raw,bundle) ||
            ![app[@"sourceVersion"] isEqual:@"578.1.0"] || ![app[@"sourceBuild"] isEqual:@"1063022819"] ||
            ![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:app[@"sourceVersion"]] ||
            ![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:app[@"sourceBuild"]]) return NO;
        if(fbstore_attempted)return fbstore_ready() && [fbstore_bundle isEqual:bundle] && [fbstore_container isEqual:manager.containerId];
        fbstore_attempted=YES;fbstore_bundle=bundle.copy;fbstore_container=manager.containerId.copy;
        %init(FacebookStorage);
#define FB_PREF_HOOK(name) MSHookFunction((void *)CFPreferences##name,(void *)fbstore_##name,(void **)&fbstore_orig_##name)
        FB_PREF_HOOK(CopyAppValue); FB_PREF_HOOK(SetAppValue); FB_PREF_HOOK(AppSynchronize);
        FB_PREF_HOOK(GetAppBooleanValue); FB_PREF_HOOK(GetAppIntegerValue);
        FB_PREF_HOOK(CopyValue); FB_PREF_HOOK(SetValue); FB_PREF_HOOK(CopyMultiple); FB_PREF_HOOK(SetMultiple);
        FB_PREF_HOOK(CopyKeyList); FB_PREF_HOOK(Synchronize); FB_PREF_HOOK(AddSuitePreferencesToApp);
        FB_PREF_HOOK(RemoveSuitePreferencesFromApp); FB_PREF_HOOK(AppValueIsForced);
#undef FB_PREF_HOOK
        __atomic_store_n(&fbstore_enabled,RBXHookInstallationPassed(),__ATOMIC_RELEASE);
        RBXLog("RBX_SELF_REPORT group=facebook-storage evidence=installation status=%@",fbstore_ready()?@"CHECKED":@"FAILED");
        return fbstore_ready();
    }
}
