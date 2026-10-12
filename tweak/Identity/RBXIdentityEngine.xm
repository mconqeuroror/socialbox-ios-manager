#import "RBXHookInstallation.h"
#import "RBXIdentityEngine.h"
#import "RBXContainerManager.h"
#import "RBXProfile.h"
#import "RBXLog.h"
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <dlfcn.h>
#import <string.h>
#import <stdlib.h>
#import <stdint.h>
#import <limits.h>
#import <errno.h>
#if __has_include(<ptrauth.h>)
#import <ptrauth.h>
#endif

// MGCopyAnswer_internal hook (MGSpoof / Lessica pattern).
// We resolve the internal function that follows the public MGCopyAnswer symbol and hook it.
// This covers protected AND unprotected MobileGestalt keys, which is what makes UDID /
// serial / IMEI spoofing possible at all. All ~130 profile fields flow through here.
//
// The public symbol is a two-instruction stub (`mov x1, #0` + tail branch), so the internal
// function takes a second argument in x1. MGGetBoolAnswer and the other typed accessors use
// this same provider, so hooking it also covers Boolean answers.

typedef CFPropertyListRef (*RBXMGCopyAnswerInternal)(CFStringRef key,
                                                     uint32_t *outTypeCode);
typedef CFTypeRef (*RBXMGCopyAnswerPublic)(CFStringRef key,
                                           CFDictionaryRef options);

static RBXMGCopyAnswerInternal orig_MGCopyAnswer_internal;
static void *sMobileGestaltHandle;
static BOOL sMobileGestaltVerified;
static NSDictionary<NSString *, NSDictionary *> *sMGContracts;
static NSDictionary<NSString *, id> *sMGAnswers;
static BOOL sMGFailureWritesCode, sMGContractReady;
static uint32_t sMGFailureCode;
static unsigned long sMGCalls;
static SInt32 (*orig_MGGetSInt32Answer)(CFStringRef, SInt32);
static SInt64 (*orig_MGGetSInt64Answer)(CFStringRef, SInt64);
static Float32 (*orig_MGGetFloat32Answer)(CFStringRef, Float32);
static bool (*orig_MGGetBoolAnswer)(CFStringRef);
static CFStringRef (*orig_MGGetStringAnswer)(CFStringRef);

// Private result codes are opaque. Observe a target call with two distinct
// sentinels; never substitute CFGetTypeID for its out parameter.
static BOOL RBXMGObserve(RBXMGCopyAnswerInternal provider, CFStringRef key,
                         CFTypeID *type, uint32_t *code, BOOL *writes) {
    uint32_t a = 0x51A07E13, b = 0xB2618F24;
    CFTypeRef first = provider(key, &a), second = provider(key, &b);
    BOOL same = (!first && !second) ||
        (first && second && CFGetTypeID(first) == CFGetTypeID(second));
    *type = first ? CFGetTypeID(first) : 0;
    BOOL unchanged = a == 0x51A07E13 && b == 0xB2618F24;
    *writes = !unchanged;
    *code = a;
    if (first) CFRelease(first);
    if (second) CFRelease(second);
    return same && (unchanged || a == b);
}

static id RBXMGNormalize(id answer, CFTypeID type) {
    if (!answer) return nil;
    CFTypeID actual = CFGetTypeID((__bridge CFTypeRef)answer);
    if (actual == type) return answer;
    // Catalog numbers are often JSON strings. Parse the complete signed value;
    // reject overflow instead of wrapping an identity into a different number.
    if (type == CFNumberGetTypeID() && [answer isKindOfClass:NSString.class]) {
        const char *input = [answer UTF8String]; char *end = NULL;
        if (!input || !*input || (*input != '-' && (*input < '0' || *input > '9'))) return nil;
        errno = 0; long long value = strtoll(input, &end, 10);
        if (errno || !end || *end) return nil;
        return @(value);
    }
    return nil;
}

static BOOL RBXMGLearnContracts(RBXMGCopyAnswerInternal provider, RBXDeviceProfile *profile) {
    CFTypeID failureType = 0;
    NSString *missing = [@"__RBX_missing_" stringByAppendingString:NSUUID.UUID.UUIDString];
    if (!RBXMGObserve(provider, (__bridge CFStringRef)missing, &failureType,
                      &sMGFailureCode, &sMGFailureWritesCode) || failureType) return NO;
    NSMutableDictionary *contracts = [NSMutableDictionary dictionary];
    NSMutableDictionary *answers = [NSMutableDictionary dictionary];
    for (NSString *key in profile.overrides) {
        CFTypeID type = 0; uint32_t code = 0; BOOL writes = NO;
        BOOL observed = RBXMGObserve(provider, (__bridge CFStringRef)key, &type, &code, &writes);
        id answer = observed && type && writes ? RBXMGNormalize([profile mgAnswer:key], type) : nil;
        if (answer) {
            contracts[key] = @{ @"type": @(type), @"code": @(code) };
            answers[key] = answer;
        } else {
            // Unsupported/protected keys stay unavailable, never physical.
            RBXLog("MobileGestalt override unavailable on target: %@", key);
        }
    }
    sMGContracts = [contracts copy]; sMGAnswers = [answers copy];
    return YES;
}

static BOOL RBXMobileGestaltKeyIsIdentitySensitive(NSString *key) {
    NSString *lower = key.lowercaseString;
    for (NSString *fragment in @[
        @"serial", @"unique", @"udid", @"uuid", @"imei", @"meid", @"iccid",
        @"macaddress", @"wifiaddress", @"bluetoothaddress", @"deviceid",
        @"chipid", @"baseband", @"mlb", @"nonce", @"activation"
    ]) {
        if ([lower containsString:fragment]) return YES;
    }
    return NO;
}

static const void *RBXReadableFunctionPointer(const void *pointer) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(pointer, ptrauth_key_function_pointer);
#else
    return pointer;
#endif
}

static void *RBXCallableFunctionPointer(const void *pointer) {
#if __has_feature(ptrauth_calls)
    return (void *)ptrauth_sign_unauthenticated(
        ptrauth_strip(pointer, ptrauth_key_function_pointer),
        ptrauth_key_function_pointer,
        0);
#else
    return (void *)pointer;
#endif
}

static CFPropertyListRef replaced_MGCopyAnswer_internal(CFStringRef key,
                                                        uint32_t *outTypeCode) {
    __atomic_fetch_add(&sMGCalls, 1, __ATOMIC_RELAXED);
    NSString *name = (__bridge NSString *)key;
    RBXDeviceProfile *profile = RBXContainerManager.sharedManager.currentProfile;
    id answer = sMGAnswers[name];
    NSDictionary *contract = sMGContracts[name];
    if (sMGContractReady && answer && contract &&
        CFGetTypeID((__bridge CFTypeRef)answer) == [contract[@"type"] unsignedLongValue]) {
        if (outTypeCode) *outTypeCode = [contract[@"code"] unsignedIntValue];
        return (__bridge_retained CFPropertyListRef)answer;
    }
    if (!sMGContractReady || [profile mgAnswer:name] || RBXMobileGestaltKeyIsIdentitySensitive(name)) {
        if (outTypeCode && sMGFailureWritesCode) *outTypeCode = sMGFailureCode;
        return NULL;
    }
    return orig_MGCopyAnswer_internal(key, outTypeCode);
}

static BOOL RBXMGIsProfileKey(CFStringRef key) {
    NSString *name = (__bridge NSString *)key;
    return !sMGContractReady || (name &&
        ([RBXContainerManager.sharedManager.currentProfile mgAnswer:name] ||
         RBXMobileGestaltKeyIsIdentitySensitive(name)));
}

// Some native typed accessors abort when the provider reports an unavailable
// type, even if their caller supplied a default (observed for ChipID on iOS 16).
// Keep unsupported identities unavailable without invoking that abort path.
// Only profile-controlled/sensitive keys take this path; other native queries
// retain their original implementation. Conversion failure never reads hardware.
static SInt32 replaced_MGGetSInt32Answer(CFStringRef key, SInt32 fallback) {
    if (!RBXMGIsProfileKey(key)) return orig_MGGetSInt32Answer(key, fallback);
    CFTypeRef value = replaced_MGCopyAnswer_internal(key, NULL); SInt32 result = fallback;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID() &&
        !CFNumberGetValue((CFNumberRef)value, kCFNumberSInt32Type, &result)) result = fallback;
    if (value) CFRelease(value);
    return result;
}
static SInt64 replaced_MGGetSInt64Answer(CFStringRef key, SInt64 fallback) {
    if (!RBXMGIsProfileKey(key)) return orig_MGGetSInt64Answer(key, fallback);
    CFTypeRef value = replaced_MGCopyAnswer_internal(key, NULL); SInt64 result = fallback;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID() &&
        !CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &result)) result = fallback;
    if (value) CFRelease(value);
    return result;
}
static Float32 replaced_MGGetFloat32Answer(CFStringRef key, Float32 fallback) {
    if (!RBXMGIsProfileKey(key)) return orig_MGGetFloat32Answer(key, fallback);
    CFTypeRef value = replaced_MGCopyAnswer_internal(key, NULL); Float32 result = fallback;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID() &&
        !CFNumberGetValue((CFNumberRef)value, kCFNumberFloat32Type, &result)) result = fallback;
    if (value) CFRelease(value);
    return result;
}
static bool replaced_MGGetBoolAnswer(CFStringRef key) {
    if (!RBXMGIsProfileKey(key)) return orig_MGGetBoolAnswer(key);
    CFTypeRef value = replaced_MGCopyAnswer_internal(key, NULL);
    bool result = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)value);
    if (value) CFRelease(value);
    return result;
}
static CFStringRef replaced_MGGetStringAnswer(CFStringRef key) {
    if (!RBXMGIsProfileKey(key)) return orig_MGGetStringAnswer(key);
    CFTypeRef value = replaced_MGCopyAnswer_internal(key, NULL);
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) return (CFStringRef)value;
    if (value) CFRelease(value);
    return NULL;
}

static BOOL RBXMGVerifyAnswers(void *publicEntry, void *providerEntry) {
    RBXMGCopyAnswerPublic copy = (RBXMGCopyAnswerPublic)publicEntry;
    RBXMGCopyAnswerInternal provider = (RBXMGCopyAnswerInternal)providerEntry;
    // Verify every supported override through the public and typed provider ABI.
    for (NSString *key in sMGAnswers) {
        unsigned long before = __atomic_load_n(&sMGCalls, __ATOMIC_RELAXED);
        CFTypeRef value = copy((__bridge CFStringRef)key, NULL);
        uint32_t code = ~[sMGContracts[key][@"code"] unsignedIntValue];
        CFTypeRef typed = provider((__bridge CFStringRef)key, &code);
        BOOL matches = value && typed && CFEqual(value, (__bridge CFTypeRef)sMGAnswers[key]) &&
            CFEqual(typed, value) && code == [sMGContracts[key][@"code"] unsignedIntValue] &&
            __atomic_load_n(&sMGCalls, __ATOMIC_RELAXED) >= before + 2;
        if (value) CFRelease(value); if (typed) CFRelease(typed);
        if (!matches) return NO;
    }
    NSMutableSet *unavailable = [NSMutableSet setWithArray:
        RBXContainerManager.sharedManager.currentProfile.overrides.allKeys];
    [unavailable addObjectsFromArray:@[@"ChipID", @"UniqueDeviceIDData"]];
    [unavailable minusSet:[NSSet setWithArray:sMGAnswers.allKeys]];
    for (NSString *key in unavailable) {
        unsigned long before = __atomic_load_n(&sMGCalls, __ATOMIC_RELAXED);
        uint32_t sentinel = ~sMGFailureCode, code = sentinel;
        CFTypeRef value = copy((__bridge CFStringRef)key, NULL);
        CFTypeRef typed = provider((__bridge CFStringRef)key, &code);
        BOOL denied = !value && !typed && code == (sMGFailureWritesCode ? sMGFailureCode : sentinel) &&
            __atomic_load_n(&sMGCalls, __ATOMIC_RELAXED) >= before + 2;
        if (value) CFRelease(value); if (typed) CFRelease(typed);
        if (!denied) return NO;
    }
    if (!sMGAnswers[@"ProductType"] || !sMGAnswers[@"IsSimulator"]) return NO;
    void *image = sMobileGestaltHandle ?: RTLD_DEFAULT;
    auto stringAnswer = (CFStringRef (*)(CFStringRef))dlsym(image, "MGGetStringAnswer");
    auto boolAnswer = (bool (*)(CFStringRef))dlsym(image, "MGGetBoolAnswer");
    auto intAnswer = (SInt32 (*)(CFStringRef, SInt32))dlsym(image, "MGGetSInt32Answer");
    auto longAnswer = (SInt64 (*)(CFStringRef, SInt64))dlsym(image, "MGGetSInt64Answer");
    auto floatAnswer = (Float32 (*)(CFStringRef, Float32))dlsym(image, "MGGetFloat32Answer");
    if (!stringAnswer || !boolAnswer || !intAnswer || !longAnswer || !floatAnswer) return NO;
    unsigned long before = __atomic_load_n(&sMGCalls, __ATOMIC_RELAXED);
    CFStringRef string = stringAnswer(CFSTR("ProductType"));
    BOOL stringOK = string && CFEqual(string, (__bridge CFTypeRef)sMGAnswers[@"ProductType"]);
    if (string) CFRelease(string);
    NSNumber *chip = sMGAnswers[@"ChipID"];
    SInt32 expected32 = 918; SInt64 expected64 = -919; Float32 expectedFloat = 9.25f;
    if (chip) {
        if (CFGetTypeID((__bridge CFTypeRef)chip) != CFNumberGetTypeID()) return NO;
        if (!CFNumberGetValue((__bridge CFNumberRef)chip, kCFNumberSInt32Type, &expected32)) expected32 = 918;
        if (!CFNumberGetValue((__bridge CFNumberRef)chip, kCFNumberSInt64Type, &expected64)) expected64 = -919;
        if (!CFNumberGetValue((__bridge CFNumberRef)chip, kCFNumberFloat32Type, &expectedFloat)) expectedFloat = 9.25f;
    }
    BOOL typedOK =
        boolAnswer(CFSTR("IsSimulator")) == [sMGAnswers[@"IsSimulator"] boolValue] &&
        intAnswer(CFSTR("ChipID"), 918) == expected32 && longAnswer(CFSTR("ChipID"), -919) == expected64 &&
        floatAnswer(CFSTR("ChipID"), 9.25f) == expectedFloat;
    return stringOK && typedOK && __atomic_load_n(&sMGCalls, __ATOMIC_RELAXED) >= before + 5;
}

static void *RBXResolveMGCopyAnswer(void **outHandle, const char **outImagePath) {
    // MGCopyAnswer is exported by libMobileGestalt itself. MobileGestaltHelper is an
    // out-of-process XPC helper, not the image that provides the client API.
    static const char *paths[] = {
        "/usr/lib/libMobileGestalt.dylib",
        "/System/Library/PrivateFrameworks/MobileGestalt.framework/MobileGestalt",
    };

    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        void *handle = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
        if (!handle) continue;

        // dlsym takes the C export name. The leading "_" is only used by Mach-O symbol
        // table APIs such as MSFindSymbol and makes dlsym return NULL.
        void *symbol = dlsym(handle, "MGCopyAnswer");
        if (symbol) {
            *outHandle = handle;
            *outImagePath = paths[i];
            return symbol;
        }
        dlclose(handle);
    }

    // The image can already be present in the shared cache under a different install name.
    void *symbol = dlsym(RTLD_DEFAULT, "MGCopyAnswer");
    if (symbol) {
        *outHandle = NULL;
        *outImagePath = "RTLD_DEFAULT";
    }
    return symbol;
}

static void *RBXResolveMGProvider(void *MGCopyAnswerPtr) {
    const uint8_t *entry =
        (const uint8_t *)RBXReadableFunctionPointer(MGCopyAnswerPtr);
    if (!entry) return NULL;

    // arm64 MGCopyAnswer is:
    //   mov x1, #0
    //   b   MGCopyAnswer_internal
    // Decode the branch instead of assuming the provider is always exactly entry + 8.
    uint32_t movInstruction = 0;
    uint32_t branchInstruction = 0;
    memcpy(&movInstruction, entry, sizeof(movInstruction));
    memcpy(&branchInstruction, entry + sizeof(uint32_t), sizeof(branchInstruction));

    if (movInstruction != 0xD2800001 ||
        (branchInstruction & 0xFC000000) != 0x14000000) {
        RBXLogErr("unsupported MGCopyAnswer entry: 0x%08x 0x%08x",
                  movInstruction, branchInstruction);
        return NULL;
    }

    int64_t branchOffset = (int64_t)(branchInstruction & 0x03FFFFFF);
    if (branchOffset & 0x02000000) branchOffset |= ~0x03FFFFFFLL;
    branchOffset <<= 2;

    return (void *)(entry + sizeof(uint32_t) + branchOffset);
}

BOOL RBXInstallMobileGestaltHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *imagePath = NULL;
        void *publicEntry =
            RBXResolveMGCopyAnswer(&sMobileGestaltHandle, &imagePath);
        if (!publicEntry) {
            const char *error = dlerror();
            RBXLogErr("MobileGestalt hook not installed: MGCopyAnswer export missing (%s)",
                      error ?: "unknown dlsym error");
            return;
        }

        Dl_info imageInfo = {};
        const char *resolvedImage = imagePath;
        if (dladdr(publicEntry, &imageInfo) && imageInfo.dli_fname) {
            resolvedImage = imageInfo.dli_fname;
        }
        RBXLog("MobileGestalt MGCopyAnswer resolved from %s at %p",
               resolvedImage ?: "unknown image", publicEntry);

        void *provider = RBXResolveMGProvider(publicEntry);
        if (!provider) {
            RBXLogErr("MobileGestalt hook not installed: provider branch unresolved");
            return;
        }

        sMGContractReady = RBXMGLearnContracts(
            (RBXMGCopyAnswerInternal)RBXCallableFunctionPointer(provider),
            RBXContainerManager.sharedManager.currentProfile);
        if (!sMGContractReady) {
            RBXLogErr("MobileGestalt target result ABI could not be established");
            return;
        }

        MSHookFunction(RBXCallableFunctionPointer(provider),
                       (void *)replaced_MGCopyAnswer_internal,
                       (void **)&orig_MGCopyAnswer_internal);
        if (!orig_MGCopyAnswer_internal) {
            RBXLogErr("MobileGestalt hook not installed: Substrate returned no trampoline");
            return;
        }

        RBXLog("MobileGestalt provider hooked at %p (original trampoline %p)",
               provider, orig_MGCopyAnswer_internal);

        void *image = sMobileGestaltHandle ?: RTLD_DEFAULT;
        MSHookFunction(dlsym(image, "MGGetSInt32Answer"), (void *)replaced_MGGetSInt32Answer, (void **)&orig_MGGetSInt32Answer);
        MSHookFunction(dlsym(image, "MGGetSInt64Answer"), (void *)replaced_MGGetSInt64Answer, (void **)&orig_MGGetSInt64Answer);
        MSHookFunction(dlsym(image, "MGGetFloat32Answer"), (void *)replaced_MGGetFloat32Answer, (void **)&orig_MGGetFloat32Answer);
        MSHookFunction(dlsym(image, "MGGetBoolAnswer"), (void *)replaced_MGGetBoolAnswer, (void **)&orig_MGGetBoolAnswer);
        MSHookFunction(dlsym(image, "MGGetStringAnswer"), (void *)replaced_MGGetStringAnswer, (void **)&orig_MGGetStringAnswer);

        sMobileGestaltVerified = RBXHookInstallationPassed() &&
            RBXMGVerifyAnswers(publicEntry, RBXCallableFunctionPointer(provider));
        RBXLog("MobileGestalt value/type/accessor checks %@",
               sMobileGestaltVerified ? @"passed" : @"failed");
    });
    return RBXHookInstallationPassed() && sMobileGestaltVerified;
}

BOOL RBXMobileGestaltHookVerified(void) {
    return sMobileGestaltVerified;
}
