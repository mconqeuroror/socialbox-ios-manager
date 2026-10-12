#import <Foundation/Foundation.h>
#import "../shared/RBXAppRegistry.h"

// Compile the actual exporter while replacing only preferences and the output
// root. This fixture never reads or writes the user's real preferences.
static NSMutableDictionary *FixtureDefaults;
static NSString *FixtureRoot;
@interface RBXMDMFixtureDefaults : NSObject
+ (instancetype)standardUserDefaults;
- (NSString *)stringForKey:(NSString *)key;
- (void)setObject:(id)value forKey:(NSString *)key;
@end
@implementation RBXMDMFixtureDefaults
+ (instancetype)standardUserDefaults { return [self new]; }
- (NSString *)stringForKey:(NSString *)key { return FixtureDefaults[key]; }
- (void)setObject:(id)value forKey:(NSString *)key { FixtureDefaults[key] = value; }
@end
static NSString *RBXMDMFixtureTemporaryDirectory(void) { return FixtureRoot; }
#define NSUserDefaults RBXMDMFixtureDefaults
#define NSTemporaryDirectory RBXMDMFixtureTemporaryDirectory
#import "../launcher/RBXMDMExporter.m"
#undef NSTemporaryDirectory
#undef NSUserDefaults

static void Check(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static NSDictionary *ReadJSON(NSURL *url) {
    return [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:url] options:0 error:nil];
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    Check(argc == 2, @"isolated scratch output root supplied");
    FixtureRoot = [NSString stringWithUTF8String:argv[1]];
    NSString *vpnUUID = @"7C24751F-45A6-4C54-9717-1AC93CD65254";
    FixtureDefaults = [@{@"RBXMDMVPNUUID":vpnUUID} mutableCopy];
    NSString *bundleA = @"com.redditbox.profile.p975819681a395537";
    NSString *bundleB = @"com.redditbox.profile.p4d5116f596b217c0";
    NSDictionary *legacy = @{@"id":@"test",@"bundleIdentifier":bundleA};
    NSDictionary *explicitReddit = @{@"id":@"hello-world",@"bundleIdentifier":bundleB,@"appType":@"reddit"};
    NSDictionary *facebook = @{@"id":@"test",@"bundleIdentifier":@"socialbox.profile.fb.p975819681a395537",@"appType":@"facebook"};

    NSError *error = nil;
    NSArray<NSURL *> *files = [RBXMDMExporter exportFilesForContainers:
        @[legacy,explicitReddit,facebook,@{},@{@"id":@"no-clone"},@{@"bundleIdentifier":bundleA}] error:&error];
    Check(files.count == 2 && !error, @"legacy wrapper exports selected Reddit rows and skips absent IDs");
    Check([files[0].path isEqual:[FixtureRoot stringByAppendingPathComponent:@"RedditBox-MDM/redditbox-per-app-vpn.mobileconfig"]] &&
        [files[1].path isEqual:[FixtureRoot stringByAppendingPathComponent:@"RedditBox-MDM/redditbox-mdm-app-mapping.json"]], @"legacy directory and both filenames unchanged");
    NSDictionary *mapping = ReadJSON(files[1]);
    NSArray *assignments = @[
        @{@"profileId":@"test",@"bundleIdentifier":bundleA,@"Attributes":@{@"VPNUUID":vpnUUID}},
        @{@"profileId":@"hello-world",@"bundleIdentifier":bundleB,@"Attributes":@{@"VPNUUID":vpnUUID}},
        @{@"profileId":@"__original_reddit_deny_only__",@"bundleIdentifier":@"com.reddit.Reddit",@"Attributes":@{@"VPNUUID":vpnUUID}},
    ];
    Check([mapping isEqual:@{@"vpnUUID":vpnUUID,@"assignments":assignments}], @"exact legacy assignments, order and original-source deny-only entry");
    NSMutableDictionary *mobileconfig = [[NSDictionary dictionaryWithContentsOfURL:files[0]] mutableCopy];
    NSMutableDictionary *payload = [mobileconfig[@"PayloadContent"][0] mutableCopy];
    Check([[NSUUID alloc] initWithUUIDString:mobileconfig[@"PayloadUUID"]] != nil &&
        [[NSUUID alloc] initWithUUIDString:payload[@"PayloadUUID"]] != nil, @"fresh payload UUIDs are valid");
    // Only the two intentionally random payload UUIDs are normalized. All other
    // legacy output keys and values are compared against fixed baseline values.
    mobileconfig[@"PayloadUUID"] = @"RANDOM"; payload[@"PayloadUUID"] = @"RANDOM";
    mobileconfig[@"PayloadContent"] = @[payload];
    NSDictionary *expectedPayload = @{
        @"PayloadType":@"com.apple.vpn.managed.applayer", @"PayloadVersion":@1,
        @"PayloadIdentifier":@"com.redditbox.mdm.per-app-vpn", @"PayloadUUID":@"RANDOM",
        @"PayloadDisplayName":@"RedditBox Per-App VPN", @"UserDefinedName":@"RedditBox Per-App VPN",
        @"VPNType":@"VPN", @"VPNSubType":@"com.redditbox.firewall",
        @"VPN":@{@"ProviderType":@"app-proxy",@"ProviderBundleIdentifier":@"com.redditbox.firewall.PacketTunnel",
            @"RemoteAddress":@"RedditBox default-deny firewall",@"OnDemandEnabled":@1,@"OnDemandRules":@[@{@"Action":@"Connect"}]},
        @"VPNUUID":vpnUUID,@"OnDemandMatchAppEnabled":@1,
        @"SafariDomains":@[@"reddit.com",@".reddit.com",@"redd.it",@".redd.it",@"redditstatic.com",@".redditstatic.com"],
        @"VendorConfig":@{@"policyVersion":@2,@"scope":@"per-app",@"outOfProcessAuthCovered":@NO,
            @"managedBundleIdentifiers":@[bundleA,bundleB,@"com.reddit.Reddit"]},
    };
    Check([mobileconfig isEqual:@{@"PayloadType":@"Configuration",@"PayloadVersion":@1,
        @"PayloadIdentifier":@"com.redditbox.mdm",@"PayloadUUID":@"RANDOM",
        @"PayloadDisplayName":@"RedditBox Managed Per-App VPN",@"PayloadRemovalDisallowed":@YES,
        @"PayloadContent":@[expectedPayload]}], @"complete legacy MDM payload unchanged, including SafariDomains and provider policy");
    NSData *profileBytes = [NSData dataWithContentsOfURL:files[0]], *mappingBytes = [NSData dataWithContentsOfURL:files[1]];
    for (NSDictionary *bad in @[
        @{@"id":@"test",@"bundleIdentifier":@"socialbox.profile.fb.p975819681a395537"},
        @{@"id":@"test",@"bundleIdentifier":@"socialbox.profile.fb.p975819681a395537",@"appType":@"reddit"},
        @{@"id":@"test",@"bundleIdentifier":bundleB},
        @{@"id":@"test",@"bundleIdentifier":@"com.reddit.Reddit"},
        @{@"id":@"test",@"bundleIdentifier":@"com.redditbox.launcher"},
        @{@"id":@"test",@"bundleIdentifier":NSNull.null},
        @{@"id":@42,@"bundleIdentifier":bundleA},
    ]) {
        error = nil;
        Check(![RBXMDMExporter exportFilesForContainers:@[legacy,bad] appType:@"reddit" error:&error],
            @"foreign, mistagged or wrong-container bundle must reject the whole selected-app export");
        Check([error.localizedDescription containsString:@"bundle"], @"mismatched bundle reports an actionable error");
        Check([[NSData dataWithContentsOfURL:files[0]] isEqual:profileBytes] &&
            [[NSData dataWithContentsOfURL:files[1]] isEqual:mappingBytes], @"rejected export preserves existing files byte-for-byte");
    }
    NSDictionary *defaultsBefore = [FixtureDefaults copy];
    NSArray *denied = [RBXAppDescriptorForType(@"facebook")[@"runnable"] boolValue] ? @[@"unknown"] : @[@"facebook",@"unknown"];
    for (NSString *appType in denied) {
        error = nil;
        Check(![RBXMDMExporter exportFilesForContainers:@[facebook] appType:appType error:&error] &&
            [error.localizedDescription containsString:@"audit"], @"inactive and unregistered app exports fail closed");
    }
    Check([FixtureDefaults isEqual:defaultsBefore], @"inactive export never changes VPN preferences");
    if ([RBXAppDescriptorForType(@"facebook")[@"runnable"] boolValue]) {
        NSDictionary *fbDescriptor = RBXAppDescriptorForType(@"facebook");
        error = nil;
        NSArray<NSURL *> *fbFiles = [RBXMDMExporter exportFilesForContainers:@[legacy,explicitReddit,facebook] appType:@"facebook" error:&error];
        Check(fbFiles.count == 2 && !error, @"runnable FB exports independently");
        Check([fbFiles[0].lastPathComponent isEqual:fbDescriptor[@"mdmProfileFilename"]] &&
            [fbFiles[1].lastPathComponent isEqual:fbDescriptor[@"mdmMappingFilename"]], @"FB export names come from descriptor");
        NSDictionary *fbMapping = ReadJSON(fbFiles[1]);
        NSArray *fbAssignments = @[
            @{@"profileId":@"test", @"bundleIdentifier":facebook[@"bundleIdentifier"], @"Attributes":@{@"VPNUUID":vpnUUID}},
            @{@"profileId":fbDescriptor[@"originalDenyProfileId"], @"bundleIdentifier":fbDescriptor[@"sourceBundleIdentifier"], @"Attributes":@{@"VPNUUID":vpnUUID}},
        ];
        Check([fbMapping isEqual:@{@"vpnUUID":vpnUUID,@"assignments":fbAssignments}], @"exact FB clone and source-deny mapping; no Reddit bundle");
        NSDictionary *fbConfig = [NSDictionary dictionaryWithContentsOfURL:fbFiles[0]], *fbPayload = fbConfig[@"PayloadContent"][0];
        Check([fbConfig[@"PayloadIdentifier"] isEqual:@"com.socialbox.facebook.mdm"] &&
            [fbPayload[@"PayloadIdentifier"] isEqual:@"com.socialbox.facebook.mdm.per-app-vpn"], @"FB profile cannot overwrite Reddit profile identifier");
        Check([fbPayload[@"VPNUUID"] isEqual:vpnUUID] && [fbPayload[@"VPN"] isEqual:expectedPayload[@"VPN"]], @"shared default-deny provider and VPN UUID unchanged");
        Check([fbPayload[@"SafariDomains"] count] == 0 && [fbPayload[@"VendorConfig"][@"outOfProcessAuthCovered"] isEqual:@NO], @"no unsupported Facebook browser-auth routing promise");
        Check([fbPayload[@"VendorConfig"][@"managedBundleIdentifiers"] isEqual:@[facebook[@"bundleIdentifier"],fbDescriptor[@"sourceBundleIdentifier"]]], @"FB VPN bundle allowlist exact");
        NSData *fbProfileBytes = [NSData dataWithContentsOfURL:fbFiles[0]], *fbMappingBytes = [NSData dataWithContentsOfURL:fbFiles[1]];
        for (NSDictionary *bad in @[
            @{@"id":@"test",@"appType":@"facebook",@"bundleIdentifier":bundleA},
            @{@"id":@"another",@"appType":@"facebook",@"bundleIdentifier":facebook[@"bundleIdentifier"]},
            @{@"id":@"test",@"appType":@"facebook",@"bundleIdentifier":@"com.facebook.Facebook"},
        ]) {
            error = nil;
            Check(![RBXMDMExporter exportFilesForContainers:@[facebook,bad] appType:@"facebook" error:&error] && error.code == 3, @"FB rejects wrong profile and foreign/source bundle as a clone");
            Check([[NSData dataWithContentsOfURL:fbFiles[0]] isEqual:fbProfileBytes] && [[NSData dataWithContentsOfURL:fbFiles[1]] isEqual:fbMappingBytes], @"rejected FB export never replaces previous files");
        }
        Check([[NSData dataWithContentsOfURL:files[0]] isEqual:profileBytes] && [[NSData dataWithContentsOfURL:files[1]] isEqual:mappingBytes], @"FB export leaves Reddit artifacts unchanged");
    }
    error = nil;
    Check(![RBXMDMExporter exportFilesForContainers:@[facebook,@{}] error:&error] && error.code == 1,
        @"foreign app rows are filtered; empty legacy selection retains existing error");
    [FixtureDefaults removeAllObjects];
    error = nil;
    NSArray *fresh = [RBXMDMExporter exportFilesForContainers:@[legacy] error:&error];
    Check(fresh.count == 2 && [[NSUUID alloc] initWithUUIDString:FixtureDefaults[@"RBXMDMVPNUUID"]] != nil,
        @"legacy first export still creates a valid VPN UUID");
    Check([ReadJSON(fresh[1])[@"vpnUUID"] isEqual:FixtureDefaults[@"RBXMDMVPNUUID"]], @"fresh mapping uses the stored VPN UUID");
    puts("PASS: actual MDM exporter retains legacy payload and rejects foreign or wrong-container bundle assignments");
} return 0; }
