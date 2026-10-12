#import <Foundation/Foundation.h>
#import "RBXAppRuntime.h"
#import "RBXAppKeychainPolicy.h"
#import "RBXProfile.h"
#import "RBXContainerManager.h"
#import "RBXDataSchema.h"
#import "RBXMGOverrides.h"

static unsigned Checks;
static RBXDeviceProfile *FixtureProfile;
static BOOL FixtureAttestBlocked;
static BOOL RBXAttestBlocked(void) { return FixtureAttestBlocked; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RBXContainerManager
+ (instancetype)sharedManager { static id manager; static dispatch_once_t once; dispatch_once(&once, ^{ manager = [self new]; }); return manager; }
- (RBXDeviceProfile *)currentProfile { return FixtureProfile; }
@end
#pragma clang diagnostic pop
// Extracted unchanged from the actual AppAttest/DeviceCheck hook call boundary.
#include "app-attest-policy.inc"
#include "app-fallback-profile.inc"

static void Check(BOOL condition, NSString *message) {
    Checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static NSMutableDictionary *Profile(NSDictionary *app, NSString *container) {
    NSString *bundle = RBXAppBundleIdentifier(app, container);
    NSMutableDictionary *metadata = [@{@"bundleIdentifier":bundle, @"keychainAccessGroup":RBXAppKeychainGroup(app, bundle)} mutableCopy];
    [metadata addEntriesFromDictionary:RBXAppKeychainMetadata(app, bundle)];
    return [@{@"containerId":container, @"appType":app[@"appType"], @"app":metadata} mutableCopy];
}
static void Policy(NSDictionary *descriptor) {
    NSString *type = descriptor[@"appType"];
    for (id mode in @[@"enabled", @"blocked", @"on", @"auto", @YES, NSNull.null]) {
        FixtureProfile = [[RBXDeviceProfile alloc] initWithDictionary:@{@"containerId":@"policy", @"appType":type,
            @"security":@{@"appAttest":mode, @"deviceCheck":mode}} error:nil];
        FixtureAttestBlocked = NO;
        Check(RBXDeviceCheckShouldBlock() == ![mode isEqual:@"enabled"], @"only explicit per-profile DeviceCheck enable opens its policy");
        Check(RBXAppAttestShouldBlock() == ![mode isEqual:@"enabled"], @"only explicit per-profile AppAttest enable opens its policy");
        FixtureAttestBlocked = YES;
        Check(RBXAppAttestShouldBlock(), @"AppAttest duplicate/missing-store guard overrides per-profile enable");
    }
    FixtureProfile = [[RBXDeviceProfile alloc] initWithDictionary:@{@"containerId":@"legacy", @"appType":type} error:nil];
    FixtureAttestBlocked = NO;
    Check(RBXDeviceCheckShouldBlock() && RBXAppAttestShouldBlock(), @"both integrity APIs default blocked without profile switches");
}
int main(void) { @autoreleasepool {
    NSDictionary *reddit = RBXRedditAppDescriptor(), *facebook = RBXAppDescriptorForType(@"facebook");
    for (NSDictionary *app in RBXRegisteredAppDescriptors()) {
        for (NSString *container in @[@"A", @"B", @"příliš-žluťoučký", @"model-alice"]) {
            NSMutableDictionary *profile = Profile(app, container);
            NSString *bundle = profile[@"app"][@"bundleIdentifier"];
            Check(RBXAppRuntimeProfileMatchesBundle(profile, bundle), @"canonical app/container bootstrap accepted");
            if ([app[@"appType"] isEqual:@"facebook"]) {
                NSMutableDictionary *downgraded = [profile[@"app"] mutableCopy];
                [downgraded removeObjectForKey:@"keychainAccessGroups"];
                NSMutableDictionary *bad = profile.mutableCopy; bad[@"app"] = downgraded;
                Check(!RBXAppRuntimeProfileMatchesBundle(bad, bundle), @"missing Facebook group-set metadata blocks runtime admission");
            }
            Check(!RBXAppRuntimeProfileMatchesBundle(profile, app[@"sourceBundleIdentifier"]), @"original source never receives clone readiness");
            Check(!RBXAppRuntimeProfileMatchesBundle(profile, [bundle stringByAppendingString:@".child"]), @"extension/lookalike suffix rejected");
            Check(!RBXAppRuntimeProfileMatchesBundle(profile, RBXAppBundleIdentifier(app, @"other")), @"another container's bundle rejected");
            NSMutableDictionary *tampered = [profile mutableCopy];
            tampered[@"containerId"] = @"different";
            Check(!RBXAppRuntimeProfileMatchesBundle(tampered, bundle), @"container ID must derive actual bundle");
            tampered = [profile mutableCopy];
            tampered[@"appType"] = [app[@"appType"] isEqual:@"reddit"] ? @"facebook" : @"reddit";
            Check(!RBXAppRuntimeProfileMatchesBundle(tampered, bundle), @"foreign profile tag rejected");
            for (id bad in @[@"T84QZS65DQ.platformFamily", @"", @YES, NSNull.null]) {
                tampered = [profile mutableCopy];
                tampered[@"app"] = @{@"bundleIdentifier":bundle, @"keychainAccessGroup":bad};
                Check(!RBXAppRuntimeProfileMatchesBundle(tampered, bundle), @"foreign/malformed keychain group rejected before entitlement probing");
            }
            [profile removeObjectForKey:@"appType"];
            Check(RBXAppRuntimeProfileMatchesBundle(profile, bundle) == [app[@"appType"] isEqual:@"reddit"], @"missing appType preserves legacy Reddit only");
        }
        NSDictionary *fallback = RBXGenerateFallbackProfile(@"invalid-bootstrap", app);
        Check(RBXCloneProfileHasSafeShape(fallback), @"actual fallback generator remains schema-valid for both apps");
        Check([RBXAppDescriptorForProfile(fallback)[@"appType"] isEqual:app[@"appType"]], @"fallback retains the actual runtime app family");
        Check([fallback[@"security"][@"deviceCheck"] isEqual:@"blocked"] &&
            [fallback[@"security"][@"appAttest"] isEqual:@"blocked"], @"fallback never enables device integrity APIs");
        if ([app[@"appType"] isEqual:@"reddit"])
            Check(!fallback[@"appType"] && [fallback[@"reddit"] isKindOfClass:NSDictionary.class], @"legacy Reddit fallback output shape is unchanged");
        else
            Check(!fallback[@"reddit"] && !fallback[@"facebook"], @"Facebook fallback invents no SDK device or server identifiers");
        Policy(app);
    }
    Check(!RBXAppRuntimeProfileMatchesBundle((id)@[], @"x") && !RBXAppRuntimeProfileMatchesBundle(nil, nil), @"malformed bootstrap is denied without exception");
    Check(RBXAppRuntimeHooksEnabledForBundle(@"com.reddit.Reddit"), @"existing Reddit executable behavior enabled");
    Check(RBXAppRuntimeHooksEnabledForBundle(RBXAppBundleIdentifier(reddit, @"A")), @"legacy Reddit clone hooks enabled");
    Check(RBXAppRuntimeHooksEnabledForBundle(@"com.facebook.Facebook") == [facebook[@"runnable"] boolValue], @"Facebook filter follows compiled runtime admission");
    Check(!RBXAppRuntimeHooksEnabledForBundle(@"com.facebook.Facebook.fake") &&
        !RBXAppRuntimeHooksEnabledForBundle(@"socialbox.profile.fb.pmalformed") &&
        !RBXAppRuntimeHooksEnabledForBundle(@"com.redditbox.launcher"), @"unknown and infrastructure bundle hooks stay inert");
    Check(RBXAppRuntimeWirePolicyAudited(reddit) && !RBXAppRuntimeWirePolicyAudited(facebook), @"Facebook wire/store gap never claims app-specific readiness");
    for (NSString *host in @[@"facebook.com", @"graph.facebook.com", @"GATEWAY.FACEBOOK.COM", @"rupload.facebook.com",
        @"static.xx.fbcdn.net", @"connect.facebook.net", @"prefetch.fbsbx.com"]) {
        Check(RBXAppRuntimeCriticalHostAllowed(facebook, host), @"static FB URL destination root accepted");
        Check(!RBXAppRuntimeCriticalHostAllowed(reddit, host), @"Facebook roots do not expand Reddit policy");
    }
    for (NSString *host in @[@"reddit.com", @"oauth.reddit.com", @"redditmedia.com", @"packaged-media.redd.it"]) {
        Check(RBXAppRuntimeCriticalHostAllowed(reddit, host), @"legacy Reddit root preserved");
        Check(!RBXAppRuntimeCriticalHostAllowed(facebook, host), @"Reddit roots do not enter Facebook policy");
    }
    for (NSString *host in @[@"", @"notfacebook.com", @"graph.facebook.com.attacker.invalid", @"fbcdn.net.attacker.invalid",
        @"facebook.net-attacker.invalid", @"prefetch.fbsbx.com.evil", @"fb.me", @"chat.messenger.com", @"graph.meta.com"]) {
        Check(!RBXAppRuntimeCriticalHostAllowed(facebook, host), @"lookalikes and unselected static roots denied by default");
    }
    Check(!RBXAppRuntimeCriticalHostAllowed(facebook, nil) && !RBXAppRuntimeCriticalHostAllowed(nil, @"facebook.com"), @"missing destination/descriptor denied");
    fprintf(stdout, "PASS: %u app runtime bootstrap, destination, integrity policy and fail-closed coverage checks\n", Checks);
} return 0; }
