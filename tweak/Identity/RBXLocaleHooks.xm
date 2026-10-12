#import "RBXAppRuntime.h"
#import "RBXHookInstallation.h"
#import "RBXLocaleHooks.h"
#import "RBXProfile.h"
#import "RBXContainerManager.h"
#import "RBXLog.h"
#import <Foundation/Foundation.h>

// C1 — locale must match the proxy geo (proxy in DE -> de_DE). currentLocale is
// cached so apps holding a previously returned instance see consistent answers.

static RBXDeviceProfile *rbxProfile(void) {
    return [RBXContainerManager sharedManager].currentProfile;
}

static NSLocale *rbxSpoofedLocale(void) {
    static NSLocale *sLocale;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        RBXDeviceProfile *p = rbxProfile();
        NSString *ident = [p valueForPath:@"device.locale"];
        if (ident.length) {
            sLocale = [[NSLocale alloc] initWithLocaleIdentifier:ident];
            RBXLogDebug("locale spoofed to %@ for container %@", ident, p.containerId);
        }
        if (!sLocale) sLocale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
    });
    return sLocale;
}

%hook NSLocale

+ (NSLocale *)currentLocale {
    NSLocale *l = rbxSpoofedLocale();
    return l;
}

+ (NSLocale *)systemLocale {
    NSLocale *l = rbxSpoofedLocale();
    return l;
}

+ (NSArray<NSString *> *)preferredLanguages {
    RBXDeviceProfile *p = rbxProfile();
    NSString *lang = [p valueForPath:@"device.language"];
    if (!lang.length) {
        NSString *locale = [p valueForPath:@"device.locale"];
        if (locale.length) lang = [locale componentsSeparatedByString:@"_"].firstObject;
    }
    if (lang.length) return @[lang];
    return @[@"en"];
}

- (NSString *)localeIdentifier {
    // Only rewrite the instances we handed out; app-created NSLocales (e.g. an
    // explicit fr_FR used for formatting) keep their own identifier.
    NSLocale *spoofed = rbxSpoofedLocale();
    if (spoofed == self) {
        RBXDeviceProfile *p = rbxProfile();
        NSString *ident = [p valueForPath:@"device.locale"];
        if (ident.length) return ident;
    }
    return %orig;
}

%end

BOOL RBXInstallLocaleHooks(void) {
    static BOOL installed = NO;
    if (installed) return RBXHookInstallationPassed();
    installed = YES;
    %init;
    RBXLog("locale hooks installed for container %@", rbxProfile().containerId);
    return RBXHookInstallationPassed();
}

%ctor {
    @autoreleasepool {
        if (!RBXAppRuntimeHooksEnabled()) return;
        RBXInstallLocaleHooks();
    }
}
