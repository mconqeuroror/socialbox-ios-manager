#import "RBXContainerManager.h"
#import "RBXDataSchema.h"
#import "RBXAppRuntime.h"
#import "RBXProfile.h"
#import "RBXLog.h"
#import "RBXMGOverrides.h"
#import "RBXCloneAcceptanceProbe.h"
#import <dlfcn.h>
#import <Security/Security.h>

// Validate structure before any chained subscript or entitlement probe. A corrupt
// clone-local JSON file must enter the blocked fallback, not throw in the ctor.
static BOOL RBXCloneProfileHasSafeShape(id profile) {
    if (!RBXSchemaValidate(profile, RBXDataProfile, nil) ||
        ![profile[@"containerId"] isKindOfClass:NSString.class]) return NO;
    for (NSString *key in @[@"device", @"serials", @"ids", @"timing", @"security",
        @"proxy", @"reddit", @"facebook", @"validation", @"mgOverrides", @"app"])
        if (profile[key] && ![profile[key] isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[@"carrier", @"screen", @"location"])
        if (profile[@"device"][key] && ![profile[@"device"][key] isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[@"bundleIdentifier", @"keychainAccessGroup"])
        if (profile[@"app"][key] && ![profile[@"app"][key] isKindOfClass:NSString.class]) return NO;
    if (profile[@"app"][@"keychainAccessGroups"] && ![profile[@"app"][@"keychainAccessGroups"] isKindOfClass:NSArray.class]) return NO;
    if (profile[@"app"][@"keychainPolicyVersion"] && ![profile[@"app"][@"keychainPolicyVersion"] isKindOfClass:NSNumber.class]) return NO;
    for (NSString *key in @[@"appAttest", @"systemClipboard"])
        if (profile[@"security"][key] && ![profile[@"security"][key] isKindOfClass:NSString.class]) return NO;
    return YES;
}

static NSString *RBXRandomHex(NSUInteger length) {
    static const char chars[] = "0123456789ABCDEF";
    NSMutableString *value = [NSMutableString stringWithCapacity:length];
    for (NSUInteger i = 0; i < length; i++) {
        [value appendFormat:@"%c", chars[arc4random_uniform(16)]];
    }
    return value;
}

static NSString *RBXRandomDigits(NSUInteger length) {
    NSMutableString *value = [NSMutableString stringWithCapacity:length];
    for (NSUInteger i = 0; i < length; i++) {
        [value appendFormat:@"%u", arc4random_uniform(10)];
    }
    return value;
}

static NSString *RBXLuhnIMEI(void) {
    NSString *base = [@"35672811" stringByAppendingString:RBXRandomDigits(6)];
    NSInteger sum = 0;
    for (NSUInteger i = 0; i < base.length; i++) {
        NSInteger n = [base characterAtIndex:i] - '0';
        if (i % 2 == 1) { n *= 2; if (n > 9) n -= 9; }
        sum += n;
    }
    return [base stringByAppendingFormat:@"%ld", (long)((10 - sum % 10) % 10)];
}

static NSString *RBXRandomUUID(void) {
    return NSUUID.UUID.UUIDString.uppercaseString;
}

static NSString *RBXRandomMAC(void) {
    return [NSString stringWithFormat:@"A4:83:E7:%@:%@:%@",
            RBXRandomHex(2), RBXRandomHex(2), RBXRandomHex(2)];
}

static NSDictionary *RBXGenerateFallbackProfile(NSString *containerId, NSDictionary *descriptor) {
    NSDictionary *profile = @{
        @"profileVersion": @(RBX_PROFILE_SCHEMA_VERSION),
        @"containerId": containerId,
        @"device": @{
            @"productType": @"iPhone14,5", @"marketingName": @"iPhone 13",
            @"modelNumber": @"MLMLL/A", @"hwModelStr": @"D17AP",
            @"regulatoryModel": @"A2482", @"iosVersion": @"17.5.1",
            @"buildVersion": @"21F90", @"darwinRelease": @"23.5.0",
            @"ramBytes": @"4294967296", @"gpuName": @"Apple A15 GPU",
            @"deviceName": @"iPhone",
            @"deviceClass": @"iPhone", @"regionCode": @"US",
            @"language": @"en", @"locale": @"en_US",
            @"timezone": @"America/New_York",
            @"screen": @{@"w": @"1170", @"h": @"2532", @"scale": @"3", @"fps": @"60"},
            @"carrier": @{@"name": @"T-Mobile", @"mcc": @"310", @"mnc": @"260"},
            @"location": @{@"city": @"New York", @"lat": @"40.7128", @"lon": @"-74.0060"},
        },
        @"serials": @{
            @"serialNumber": [RBXRandomDigits(2) stringByAppendingString:RBXRandomHex(8)],
            @"udid": [@"00008101-" stringByAppendingString:RBXRandomHex(16)],
            @"imei1": RBXLuhnIMEI(), @"wifiMac": RBXRandomMAC(), @"btMac": RBXRandomMAC(),
            @"platformUUID": RBXRandomUUID(), @"mlb": [RBXRandomHex(4) stringByAppendingString:RBXRandomDigits(1)],
        },
        @"ids": @{@"posture": @"zeroWithATTDenied",
                   @"idfa": @"00000000-0000-0000-0000-000000000000",
                   @"idfv": RBXRandomUUID()},
        @"timing": @{@"bootTimeOffsetSeconds": [NSString stringWithFormat:@"%u", arc4random_uniform(1209600)],
                      @"syntheticBootEpoch": [NSString stringWithFormat:@"%.0f",
                          NSDate.date.timeIntervalSince1970 -
                          (3600 + arc4random_uniform(1206000))],
                      @"batteryOffsetPercent": [NSString stringWithFormat:@"%d", (int)arc4random_uniform(17) - 8]},
        @"security": @{
            @"appAttest": @"blocked", @"deviceCheck": @"blocked",
            @"localNetworking": @"blocked", @"sensorAccess": @"blocked",
            @"networkMetadata": @"blocked", @"thirdPartyNetwork": @"blocked",
            @"strictTiming": @"enabled"
        },
        @"proxy": @{@"url": @"", @"country": @"US"},
        @"reddit": @{@"installId": RBXRandomUUID(), @"externalInstallationId": RBXRandomUUID(),
                      @"installTimestampMs": [NSString stringWithFormat:@"%.0f",
                          ([NSDate.date timeIntervalSince1970] - 86400.0 * 30.0) * 1000.0],
                      @"deviceName": @"Apple;iPhone14,5"},
        @"validation": @{@"proxyCountry": @"US", @"geoConsistent": @NO,
                         @"fallbackIdentity": @YES},
    };
    NSMutableDictionary *complete = [profile mutableCopy];
    if (descriptor && ![descriptor[@"appType"] isEqual:@"reddit"]) {
        complete[@"appType"] = descriptor[@"appType"];
        [complete removeObjectForKey:@"reddit"];
    }
    complete[@"mgOverrides"] = RBXBuildMGOverrides(complete);
    return complete;
}

static BOOL RBXCloneEntitlementsMatchProfile(NSDictionary *profile) {
    typedef CFTypeRef (*CreateTaskFn)(CFAllocatorRef);
    typedef CFTypeRef (*CopyEntitlementFn)(CFTypeRef, CFStringRef, CFErrorRef *);
    void *security = dlopen("/System/Library/Frameworks/Security.framework/Security",
                           RTLD_NOW);
    CreateTaskFn createTask = security
        ? (CreateTaskFn)dlsym(security, "SecTaskCreateFromSelf") : NULL;
    CopyEntitlementFn copyValue = security
        ? (CopyEntitlementFn)dlsym(security, "SecTaskCopyValueForEntitlement") : NULL;
    if (!createTask || !copyValue) {
        if (security) dlclose(security);
        return NO;
    }
    CFTypeRef task = createTask(kCFAllocatorDefault);
    if (!task) {
        dlclose(security);
        return NO;
    }
    id applicationIdentifier = CFBridgingRelease(copyValue(
        task, CFSTR("application-identifier"), NULL));
    id teamIdentifier = CFBridgingRelease(copyValue(
        task, CFSTR("com.apple.developer.team-identifier"), NULL));
    id keychainGroups = CFBridgingRelease(copyValue(
        task, CFSTR("keychain-access-groups"), NULL));
    id appGroups = CFBridgingRelease(copyValue(
        task, CFSTR("com.apple.security.application-groups"), NULL));
    id aps = CFBridgingRelease(copyValue(task, CFSTR("aps-environment"), NULL));
    id ubiquity = CFBridgingRelease(copyValue(
        task, CFSTR("com.apple.developer.ubiquity-container-identifiers"), NULL));
    id ubiquityKVS = CFBridgingRelease(copyValue(
        task, CFSTR("com.apple.developer.ubiquity-kvstore-identifier"), NULL));
    id iCloudContainers = CFBridgingRelease(copyValue(
        task, CFSTR("com.apple.developer.icloud-container-identifiers"), NULL));
    id iCloudServices = CFBridgingRelease(copyValue(
        task, CFSTR("com.apple.developer.icloud-services"), NULL));
    id associatedDomains = CFBridgingRelease(copyValue(
        task, CFSTR("com.apple.developer.associated-domains"), NULL));
    id appAttest = CFBridgingRelease(copyValue(
        task, CFSTR("com.apple.developer.devicecheck.appattest-environment"), NULL));
    id getTaskAllow = CFBridgingRelease(copyValue(
        task, CFSTR("get-task-allow"), NULL));
    CFRelease(task);
    dlclose(security);
    NSString *expected = profile[@"app"][@"keychainAccessGroup"];
    NSDictionary *descriptor = RBXAppDescriptorForProfile(profile);
    NSArray *expectedGroups = RBXAppKeychainGroups(descriptor, profile[@"app"][@"bundleIdentifier"]);
    BOOL appAttestExpected =
        [profile[@"security"][@"appAttest"] isEqualToString:@"enabled"];
    return expected.length &&
        [applicationIdentifier isEqual:expected] &&
        [teamIdentifier isEqual:descriptor[@"teamIdentifier"]] &&
        [keychainGroups isEqual:expectedGroups] &&
        appGroups == nil && aps == nil && ubiquity == nil &&
        ubiquityKVS == nil && iCloudContainers == nil && iCloudServices == nil &&
        associatedDomains == nil &&
        getTaskAllow == nil &&
        (appAttestExpected ? [appAttest isEqualToString:@"production"]
                           : appAttest == nil);
}

static BOOL RBXCloneKeychainProbeGroup(NSString *group, NSString *container) {
    if (!group.length || !container.length) return NO;
    NSData *expected = [container dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *identity = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccessGroup: group,
        (__bridge id)kSecAttrService: @"com.redditbox.clone.selftest",
        (__bridge id)kSecAttrAccount: @"shared-probe",
    };
    SecItemDelete((__bridge CFDictionaryRef)identity);
    NSMutableDictionary *add = [identity mutableCopy];
    add[(__bridge id)kSecValueData] = expected;
    add[(__bridge id)kSecAttrSynchronizable] = @NO;
    if (SecItemAdd((__bridge CFDictionaryRef)add, NULL) != errSecSuccess) return NO;
    NSMutableDictionary *query = [identity mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    NSData *actual = CFBridgingRelease(result);
    OSStatus cleanupStatus = SecItemDelete((__bridge CFDictionaryRef)identity);
    return status == errSecSuccess && cleanupStatus == errSecSuccess && [actual isEqualToData:expected];
}

static BOOL RBXCloneKeychainProbe(NSDictionary *profile) {
    NSArray *groups = RBXAppKeychainGroups(RBXAppDescriptorForProfile(profile), profile[@"app"][@"bundleIdentifier"]);
    if (!groups.count) return NO;
    for (NSString *group in groups)
        if (!RBXCloneKeychainProbeGroup(group, profile[@"containerId"])) return NO;
    return YES;
}

static BOOL RBXAcceptanceOwnDefaults(NSString *nonce, BOOL cleanup) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *key = [@"RBXAcceptanceCanary." stringByAppendingString:nonce];
    id existing = [defaults objectForKey:key];
    if (existing && ![existing isEqual:nonce]) return NO;
    if (cleanup) [defaults removeObjectForKey:key];
    else [defaults setObject:nonce forKey:key];
    [defaults synchronize];
    return cleanup ? [defaults objectForKey:key] == nil : [[defaults objectForKey:key] isEqual:nonce];
}

@implementation RBXContainerManager {
    RBXDeviceProfile *_profile;
    NSString *_containerId;
    NSString *_containerDir;
    BOOL _validatedProfileLoaded;
}

+ (instancetype)sharedManager {
    static RBXContainerManager *mgr;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mgr = [[self alloc] init]; });
    return mgr;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    // Clone identity is self-describing. Never trust the old shared active-container
    // file: an app process must only consume the profile provisioned into its own
    // OS data container (or the signed bootstrap copy in its app bundle).
    _containerId = @"";
    _profile = [self _loadProfile];
    return self;
}

- (BOOL)isContainerized {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
    return RBXAppOwnsCloneBundleIdentifier(RBXAppDescriptorForBundleIdentifier(bundle), bundle);
}

- (RBXDeviceProfile *)_loadProfile {
    NSString *localPath = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Application Support/RedditBox/profile.json"];
    NSString *bootstrapPath = [[NSBundle mainBundle] pathForResource:@"RedditBoxProfile"
                                                              ofType:@"json"];
    NSData *data = [NSData dataWithContentsOfFile:localPath];
    if (!data) data = [NSData dataWithContentsOfFile:bootstrapPath];
    NSDictionary *dict = data.length
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (!RBXCloneProfileHasSafeShape(dict)) dict = nil;
    NSString *actualBundle = NSBundle.mainBundle.bundleIdentifier;
    NSDictionary *actualApp = RBXAppDescriptorForBundleIdentifier(actualBundle);
    NSString *profileContainer = [dict[@"containerId"] isKindOfClass:[NSString class]]
        ? dict[@"containerId"] : @"";
    _containerId = profileContainer;
    NSDictionary *mg = [dict isKindOfClass:[NSDictionary class]] ? RBXBuildMGOverrides(dict) : @{};
    BOOL identityComplete =
        RBXAppRuntimeProfileMatchesBundle(dict, actualBundle) &&
        profileContainer.length > 0 &&
        RBXCloneEntitlementsMatchProfile(dict) &&
        RBXCloneKeychainProbe(dict) &&
        [mg[@"UniqueDeviceID"] isKindOfClass:[NSString class]] &&
        [mg[@"SerialNumber"] isKindOfClass:[NSString class]] &&
        [mg[@"ProductType"] isKindOfClass:[NSString class]] &&
        [mg[@"ProductVersion"] isKindOfClass:[NSString class]] &&
        [dict[@"ids"][@"idfv"] isKindOfClass:[NSString class]];
    _validatedProfileLoaded = identityComplete;
    if (![dict isKindOfClass:[NSDictionary class]] || !identityComplete) {
        if (_containerId.length == 0) _containerId = actualBundle ?: @"invalid-clone";
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/Application Support/RedditBox"];
        NSString *fallbackPath = [dir stringByAppendingPathComponent:@".rbx-identity.json"];
        NSData *fallbackData = [NSData dataWithContentsOfFile:fallbackPath];
        NSDictionary *fallback = fallbackData.length
            ? [NSJSONSerialization JSONObjectWithData:fallbackData options:0 error:nil] : nil;
        if (!RBXCloneProfileHasSafeShape(fallback) ||
            (actualApp && ![RBXAppDescriptorForProfile(fallback)[@"appType"] isEqual:actualApp[@"appType"]])) {
            fallback = RBXGenerateFallbackProfile(_containerId, actualApp);
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            // Preserve an existing corrupt/newer fallback; use the generated
            // fail-safe only in memory while traffic remains blocked.
            if (!fallbackData) RBXSchemaWriteJSON(fallback, fallbackPath, RBXDataProfile, nil);
            RBXLogErr("profile %@ missing — generated persistent fail-safe identity; network remains blocked",
                      _containerId);
        } else {
            RBXLogErr("profile %@ missing — loaded persistent fail-safe identity; network remains blocked",
                      _containerId);
        }
        dict = fallback;
    }
    return [[RBXDeviceProfile alloc] initWithDictionary:dict error:nil];
}

- (NSString *)containerDataDirectory {
    if (_containerDir) return _containerDir;

    // The whole OS-assigned app container is the profile boundary.
    _containerDir = NSHomeDirectory();
    return _containerDir;
}

- (NSString *)containerKeychainAccessGroupSuffix {
    return [_profile valueForPath:@"app.keychainAccessGroup"];
}

- (NSString *)currentProxyURL {
    return _profile.proxyURL;
}

- (RBXDeviceProfile *)currentProfile {
    return _profile;
}

- (void)runAcceptanceProbeIfRequested {
    if (!_validatedProfileLoaded || !self.isContainerized || geteuid() == 0) return;
    NSString *home = NSHomeDirectory(), *bundle = NSBundle.mainBundle.bundleIdentifier;
    NSString *group = [_profile valueForPath:@"app.keychainAccessGroup"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            RBXAcceptanceSecurity api = {SecItemAdd, SecItemCopyMatching, SecItemDelete, RBXAcceptanceOwnDefaults};
            @try {
                RBXAcceptanceRun(home, bundle, group, @"/private/var/mobile/Containers/Data/Application",
                    0, getuid(), getpid(), NSDate.date.timeIntervalSince1970, api);
            } @catch (NSException *exception) {
                // Diagnostic failure must never change ordinary readiness/lease.
                RBXLogErr("optional acceptance probe failed; no launch state was changed");
            }
        }
    });
}

@end
