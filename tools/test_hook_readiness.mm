// Actual MobileGestalt replacement/contract code, with a synthetic provider.
// No physical identifiers or hook engine are accessed by this fixture.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
static void *FixtureLookup(void *, const char *);
#define dlsym FixtureLookup
#import "../tweak/Identity/RBXIdentityEngine.xm"
#undef dlsym
#import "../shared/RBXHookReadiness.h"
#undef MSHookFunction
#undef MSHookMessageEx

static NSDictionary *FixtureAnswers;
static BOOL MissingCode, InconsistentCode, WrongType;
static unsigned ProviderCalls;
static BOOL BypassTyped;
static SInt64 BypassedLong(CFStringRef key, SInt64 fallback) { return fallback; }
static void *FixtureLookup(void *image, const char *name) {
    if (!strcmp(name,"MGGetSInt32Answer")) return (void *)replaced_MGGetSInt32Answer;
    if (!strcmp(name,"MGGetSInt64Answer")) return BypassTyped ? (void *)BypassedLong : (void *)replaced_MGGetSInt64Answer;
    if (!strcmp(name,"MGGetFloat32Answer")) return (void *)replaced_MGGetFloat32Answer;
    if (!strcmp(name,"MGGetBoolAnswer")) return (void *)replaced_MGGetBoolAnswer;
    if (!strcmp(name,"MGGetStringAnswer")) return (void *)replaced_MGGetStringAnswer;
    return NULL;
}
static CFTypeRef PublicAnswer(CFStringRef key, CFDictionaryRef options) {
    return replaced_MGCopyAnswer_internal(key, NULL);
}
static void Check(BOOL ok, NSString *message) {
    if (!ok) @throw [NSException exceptionWithName:@"HookReadinessFixture" reason:message userInfo:nil];
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RBXDeviceProfile
- (NSDictionary *)overrides { return FixtureAnswers; }
- (id)mgAnswer:(NSString *)key { return FixtureAnswers[key]; }
@end
@implementation RBXContainerManager
+ (instancetype)sharedManager { static id manager = [self new]; return manager; }
- (RBXDeviceProfile *)currentProfile { static id profile = [RBXDeviceProfile new]; return profile; }
@end
#pragma clang diagnostic pop
void MSHookFunction(void *symbol, void *hook, void **original) { *original = symbol; }
void MSHookMessageEx(Class target, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(target, selector);
    *original = method_getImplementation(method);
    class_replaceMethod(target, selector, replacement, method_getTypeEncoding(method));
}
@interface ClipboardFixtureBase : NSObject
- (NSString *)read;
@end
@implementation ClipboardFixtureBase
- (NSString *)read { return @"base"; }
@end
@interface ClipboardFixtureSubclass : ClipboardFixtureBase
@end
@implementation ClipboardFixtureSubclass
- (NSString *)read { return @"subclass"; }
@end
static id BlockedRead(id object, SEL selector) { return nil; }

static CFPropertyListRef Provider(CFStringRef key, uint32_t *code) {
    ProviderCalls++;
    NSString *name = (__bridge NSString *)key;
    id value; uint32_t result;
    if ([name isEqual:@"ProductType"]) { value = @"original-model"; result = 901; }
    else if ([name isEqual:@"IsSimulator"]) { value = @YES; result = 607; }
    else if ([name isEqual:@"ChipID"]) { value = WrongType ? (id)@[] : (id)@32; result = 403; }
    else if ([name isEqual:@"UniqueDeviceIDData"]) { value = [@"original" dataUsingEncoding:NSUTF8StringEncoding]; result = 209; }
    else { value = nil; result = 103; }
    if (code && !MissingCode) *code = InconsistentCode ? result + ProviderCalls : result;
    return value ? (__bridge_retained CFPropertyListRef)value : NULL;
}
static void Verify(NSString *key, id expected, uint32_t expectedCode) {
    uint32_t code = UINT32_MAX;
    CFTypeRef value = replaced_MGCopyAnswer_internal((__bridge CFStringRef)key, &code);
    Check(value && CFEqual(value, (__bridge CFTypeRef)expected), @"replacement matches synthetic value");
    Check(code == expectedCode, @"opaque target type code is preserved");
    CFRelease(value);
}
int main(void) {
    @autoreleasepool {
        NSDictionary *receipt = @{@"timestamp": @101};
        Check(RBXHookReceiptTimeMatchesLease(receipt, @{@"state": @"armed", @"openedAt": @100}, 103), @"receipt follows arm");
        Check(RBXHookReceiptTimeMatchesLease(receipt, @{@"state": @"open", @"openedAt": @102}, 103), @"receipt precedes OPEN after daemon verified it while armed");
        Check(!RBXHookReceiptTimeMatchesLease(@{@"timestamp": @104}, @{@"state": @"open", @"openedAt": @102}, 103), @"future receipt rejected");
        Check(!RBXHookReceiptTimeMatchesLease(receipt, @{@"state": @"closed", @"openedAt": @102}, 103), @"closed lease has no active diagnostic receipt");
        Check(!RBXHookReceiptTimeMatchesLease(@{}, @{@"state": @"open", @"openedAt": @102}, 103), @"missing timestamp rejected");
        Check(!RBXHookReceiptTimeMatchesLease(receipt, @{@"state": @"open", @"openedAt": @104}, 103), @"future lease timestamp rejected");
        Check(!RBXHookReceiptTimeMatchesLease(receipt, @{@"state": @"armed", @"openedAt": @102}, 103), @"pre-arm receipt rejected");
        FixtureAnswers = @{@"ProductType": @"synthetic-model", @"IsSimulator": @NO,
            @"ChipID": @"1234", @"UniqueDeviceIDData": [@"synthetic" dataUsingEncoding:NSUTF8StringEncoding],
            @"unsupported-serial": @"must-not-return"};
        RBXDeviceProfile *profile = RBXContainerManager.sharedManager.currentProfile;
        orig_MGCopyAnswer_internal = Provider;
        sMGContractReady = RBXMGLearnContracts(Provider, profile);
        Check(sMGContractReady, @"target contracts learned");
        Verify(@"ProductType", @"synthetic-model", 901);
        Verify(@"IsSimulator", @NO, 607);
        Verify(@"ChipID", @1234, 403);
        Verify(@"UniqueDeviceIDData", FixtureAnswers[@"UniqueDeviceIDData"], 209);
        unsigned calls = ProviderCalls;
        uint32_t code = 0;
        Check(!replaced_MGCopyAnswer_internal(CFSTR("unsupported-serial"), &code) && code == 103,
            @"unavailable override uses observed failure contract");
        Check(!replaced_MGCopyAnswer_internal(CFSTR("new-unique-identifier"), &code) &&
            ProviderCalls == calls, @"unsupported sensitive keys never call physical provider");
        // Production profiles need not contain ChipID or a separate UDIDData
        // override. iOS's typed accessor aborts for an unavailable type code;
        // callers must instead receive their documented fallback, not hardware.
        calls = ProviderCalls;
        Check(replaced_MGGetSInt32Answer(CFSTR("unsupported-serial"), 917) == 917 &&
              replaced_MGGetSInt64Answer(CFSTR("new-unique-identifier"), -918) == -918 &&
              replaced_MGGetFloat32Answer(CFSTR("unsupported-serial"), 9.5f) == 9.5f &&
              !replaced_MGGetBoolAnswer(CFSTR("unsupported-serial")) &&
              !replaced_MGGetStringAnswer(CFSTR("unsupported-serial")) && ProviderCalls == calls,
              @"unavailable typed identities preserve caller defaults without native provider");
        Check(replaced_MGGetSInt64Answer(CFSTR("ChipID"), -1) == 1234 &&
              replaced_MGGetSInt32Answer(CFSTR("ChipID"), -1) == 1234 &&
              !replaced_MGGetBoolAnswer(CFSTR("IsSimulator")), @"typed synthetic values retained");
        Check(RBXMGVerifyAnswers((void *)PublicAnswer, (void *)replaced_MGCopyAnswer_internal),
            @"public, provider and all typed paths verified with complete profile");
        NSMutableDictionary *withoutOptional = [FixtureAnswers mutableCopy];
        [withoutOptional removeObjectsForKeys:@[@"ChipID", @"UniqueDeviceIDData"]];
        NSDictionary *full = FixtureAnswers; FixtureAnswers = withoutOptional;
        sMGContractReady = RBXMGLearnContracts(Provider, profile);
        Check(RBXMGVerifyAnswers((void *)PublicAnswer, (void *)replaced_MGCopyAnswer_internal),
            @"missing optional identity verified by denial and typed defaults, not forced physical values");
        BypassTyped = YES;
        Check(!RBXMGVerifyAnswers((void *)PublicAnswer, (void *)replaced_MGCopyAnswer_internal),
            @"matching default alone does not prove hook interception");
        BypassTyped = NO; FixtureAnswers = full; sMGContractReady = RBXMGLearnContracts(Provider, profile);
        Check(!RBXMGNormalize(@"9223372036854775808", CFNumberGetTypeID()), @"numeric overflow rejected");
        Check(!RBXMGNormalize(@"12x", CFNumberGetTypeID()), @"partial numeric parse rejected");
        Check(!RBXMGNormalize(@"false", CFBooleanGetTypeID()), @"string is not guessed to be Boolean");
        MissingCode = YES;
        Check(RBXMGLearnContracts(Provider, profile) && sMGAnswers.count == 0,
            @"missing successful type code cannot publish any override");
        code = 555;
        Check(!replaced_MGCopyAnswer_internal(CFSTR("ProductType"), &code) && code == 555,
            @"target failure contract can leave output untouched");
        MissingCode = NO; InconsistentCode = YES;
        Check(!RBXMGLearnContracts(Provider, profile), @"unstable target ABI rejected");
        InconsistentCode = NO; WrongType = YES;
        Check(RBXMGLearnContracts(Provider, profile) && !sMGAnswers[@"ChipID"], @"type mismatch denied");
        NSMutableDictionary *installed = [NSMutableDictionary dictionary];
        for (NSString *key in RBXRequiredHookGroups()) installed[key] = @YES;
        Check(RBXRequiredChecksPassed(installed, RBXRequiredHookGroups()), @"complete installation evidence accepted");
        for (NSString *key in RBXRequiredHookGroups()) {
            [installed removeObjectForKey:key];
            Check(!RBXRequiredChecksPassed(installed, RBXRequiredHookGroups()), @"missing group denied");
            installed[key] = @NO;
            Check(!RBXRequiredChecksPassed(installed, RBXRequiredHookGroups()), @"failed group denied");
            installed[key] = @YES;
        }
        Check(!RBXRequiredChecksPassed(@YES, RBXRequiredHookGroups()), @"legacy single-flag receipt denied");
        Check(!RBXRequiredChecksPassed(@{}, RBXRequiredBehaviorChecks()), @"unverified behavior denied");
        // An engine returning the untouched symbol does not constitute a detour.
        RBXHookAttempts = RBXHookFailures = 0; void *original = (void *)Provider;
        RBXCheckedHookFunction((void *)Provider, (void *)replaced_MGCopyAnswer_internal, &original);
        Check(!RBXHookInstallationPassed(), @"no-op hook engine rejected");
        RBXHookAttempts = RBXHookFailures = RBXMessageHookCount = 0;
        IMP originalRead = NULL;
        RBXCheckedHookMessage(ClipboardFixtureBase.class, @selector(read), (IMP)BlockedRead, &originalRead);
        Check(RBXHookInstallationPassed() && ![[ClipboardFixtureBase new] read] &&
            [[[ClipboardFixtureSubclass new] read] isEqual:@"subclass"], @"subclass override bypass reproduced");
        RBXMirrorBlockingHooksToSubclass(ClipboardFixtureBase.class, ClipboardFixtureSubclass.class);
        Check(RBXHookInstallationPassed() && ![[ClipboardFixtureSubclass new] read],
            @"concrete clipboard subclass receives blocking method");
        NSLog(@"Hook readiness and opaque MobileGestalt ABI fixtures passed");
    }
    return 0;
}
