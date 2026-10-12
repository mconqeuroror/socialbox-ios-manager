#import "RBXMDMExporter.h"
#import "RBXAppRegistry.h"

@implementation RBXMDMExporter

+ (NSArray<NSURL *> *)exportFilesForContainers:(NSArray<NSDictionary *> *)containers
                                         error:(NSError **)error {
    return [self exportFilesForContainers:containers appType:@"reddit" error:error];
}
+ (NSArray<NSURL *> *)exportFilesForContainers:(NSArray<NSDictionary *> *)containers
                                     appType:(NSString *)appType error:(NSError **)error {
    NSDictionary *descriptor = RBXAppDescriptorForType(appType);
    if (!descriptor || ![descriptor[@"runnable"] boolValue]) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.mdm-export" code:2
            userInfo:@{NSLocalizedDescriptionKey:@"MDM export for this app requires its binary and routing audit."}];
        return nil;
    }
    BOOL reddit = [appType isEqual:@"reddit"];
    NSString *namespace = reddit ? @"com.redditbox.mdm" : [descriptor[@"configNamespace"] stringByAppendingString:@".mdm"];
    NSString *displayName = reddit ? @"RedditBox" : [@"SocialBox " stringByAppendingString:descriptor[@"displayName"]];
    NSMutableArray *bundleIds = [NSMutableArray array];
    NSMutableArray *assignments = [NSMutableArray array];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *vpnUUID = [defaults stringForKey:@"RBXMDMVPNUUID"];
    if (!vpnUUID.length) {
        vpnUUID = NSUUID.UUID.UUIDString.uppercaseString;
        [defaults setObject:vpnUUID forKey:@"RBXMDMVPNUUID"];
    }
    for (NSDictionary *container in containers) {
        if (![RBXAppDescriptorForProfile(container)[@"appType"] isEqual:descriptor[@"appType"]]) continue;
        NSString *bundleId = container[@"bundleIdentifier"];
        NSString *profileId = container[@"id"];
        if ((bundleId && ![bundleId isKindOfClass:NSString.class]) ||
            (profileId && ![profileId isKindOfClass:NSString.class])) {
            if (error) *error = [NSError errorWithDomain:@"com.redditbox.mdm-export" code:3
                userInfo:@{NSLocalizedDescriptionKey:@"A container has invalid profile or bundle identifiers. Refresh its diagnostics before exporting MDM setup."}];
            return nil;
        }
        if (!bundleId.length || !profileId.length) continue;
        if (![bundleId isEqual:RBXAppBundleIdentifier(descriptor, profileId)]) {
            if (error) *error = [NSError errorWithDomain:@"com.redditbox.mdm-export" code:3
                userInfo:@{NSLocalizedDescriptionKey:@"A container bundle does not match its app and profile ID. Refresh its diagnostics before exporting MDM setup."}];
            return nil;
        }
        [bundleIds addObject:bundleId];
        [assignments addObject:@{
            @"profileId": profileId,
            @"bundleIdentifier": bundleId,
            @"Attributes": @{@"VPNUUID": vpnUUID},
        }];
    }
    if (!bundleIds.count) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.mdm-export"
            code:1 userInfo:@{NSLocalizedDescriptionKey:
                @"Create at least one container before exporting MDM setup."}];
        return nil;
    }
    [bundleIds addObject:descriptor[@"sourceBundleIdentifier"]];
    [assignments addObject:@{
        @"profileId": descriptor[@"originalDenyProfileId"],
        @"bundleIdentifier": descriptor[@"sourceBundleIdentifier"],
        @"Attributes": @{@"VPNUUID": vpnUUID},
    }];
    NSDictionary *vpnPayload = @{
        @"PayloadType": @"com.apple.vpn.managed.applayer",
        @"PayloadVersion": @1,
        @"PayloadIdentifier": [namespace stringByAppendingString:@".per-app-vpn"],
        @"PayloadUUID": NSUUID.UUID.UUIDString.uppercaseString,
        @"PayloadDisplayName": [displayName stringByAppendingString:@" Per-App VPN"],
        @"UserDefinedName": [displayName stringByAppendingString:@" Per-App VPN"],
        @"VPNType": @"VPN",
        @"VPNSubType": @"com.redditbox.firewall",
        @"VPN": @{
            @"ProviderType": @"app-proxy",
            @"ProviderBundleIdentifier": @"com.redditbox.firewall.PacketTunnel",
            @"RemoteAddress": @"RedditBox default-deny firewall",
            @"OnDemandEnabled": @1,
            @"OnDemandRules": @[@{@"Action": @"Connect"}],
        },
        @"VPNUUID": vpnUUID,
        @"OnDemandMatchAppEnabled": @1,
        @"SafariDomains": reddit ? @[
            @"reddit.com", @".reddit.com", @"redd.it", @".redd.it",
            @"redditstatic.com", @".redditstatic.com",
        ] : @[], // No Facebook browser-auth routing claim without device evidence.
        @"VendorConfig": @{
            @"policyVersion": @2,
            @"scope": @"per-app",
            @"outOfProcessAuthCovered": @NO, // Requested SafariDomains are not routing proof.
            @"managedBundleIdentifiers": bundleIds,
        },
    };
    NSDictionary *mobileconfig = @{
        @"PayloadType": @"Configuration",
        @"PayloadVersion": @1,
        @"PayloadIdentifier": namespace,
        @"PayloadUUID": NSUUID.UUID.UUIDString.uppercaseString,
        @"PayloadDisplayName": [displayName stringByAppendingString:@" Managed Per-App VPN"],
        @"PayloadRemovalDisallowed": @YES,
        @"PayloadContent": @[vpnPayload],
    };
    NSData *profileData = [NSPropertyListSerialization dataWithPropertyList:mobileconfig
        format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    NSData *mappingData = [NSJSONSerialization dataWithJSONObject:@{
        @"vpnUUID": vpnUUID, @"assignments": assignments}
        options:NSJSONWritingPrettyPrinted error:error];
    if (!profileData || !mappingData) return nil;
    NSString *directory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:descriptor[@"mdmExportDirectory"]];
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:nil error:error];
    NSString *profilePath = [directory
        stringByAppendingPathComponent:descriptor[@"mdmProfileFilename"]];
    NSString *mappingPath = [directory
        stringByAppendingPathComponent:descriptor[@"mdmMappingFilename"]];
    if (![profileData writeToFile:profilePath options:NSDataWritingAtomic error:error] ||
        ![mappingData writeToFile:mappingPath options:NSDataWritingAtomic error:error]) {
        return nil;
    }
    return @[[NSURL fileURLWithPath:profilePath],
             [NSURL fileURLWithPath:mappingPath]];
}

@end
