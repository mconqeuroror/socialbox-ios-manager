#pragma once
#import "RBXAppScope.h"

// Read-only presentation. Import readiness, implementation admission and network
// readiness are separate; none of these strings authorizes a daemon operation.
static inline NSDictionary *RBXAppSetupStatus(id document, NSDictionary *descriptor) {
    BOOL registered = RBXAppDescriptorIsRegistered(descriptor);
    NSString *name = registered ? descriptor[@"displayName"] : @"App";
    NSDictionary *state = RBXAppScopedLauncherState(document, descriptor);
    NSDictionary *source = [state[@"source"] isKindOfClass:NSDictionary.class] ? state[@"source"] : @{};
    BOOL imported = [source[@"decrypted"] isKindOfClass:NSNumber.class] && [source[@"decrypted"] boolValue];
    NSString *version = [source[@"version"] isKindOfClass:NSString.class] ? source[@"version"] : @"";
    NSDictionary *vpn = [state[@"firewallSetup"] isKindOfClass:NSDictionary.class] ? state[@"firewallSetup"] : @{};
    double age = [state[@"updatedAt"] isKindOfClass:NSNumber.class]
        ? NSDate.date.timeIntervalSince1970 - [state[@"updatedAt"] doubleValue] : -1;
    BOOL network = age >= 0 && age <= 15 && [vpn[@"ready"] isKindOfClass:NSNumber.class] &&
        [vpn[@"ready"] boolValue] && [state[@"firewallScope"] isEqual:@"per-app"];
    BOOL enabled = registered && [descriptor[@"runnable"] boolValue];
    NSString *sourceTitle = imported ? [NSString stringWithFormat:@"%@ IPA imported%@", name,
        version.length ? [NSString stringWithFormat:@" · v%@", version] : @""] :
        [NSString stringWithFormat:@"%@ IPA not imported", name];
    return @{@"sourceReady":@(imported), @"networkReady":@(network), @"executionEnabled":@(enabled),
        @"sourceTitle":sourceTitle,
        @"sourceAction":imported ? @"Source details" : @"Import IPA",
        @"importAction":[NSString stringWithFormat:@"%@ %@ IPA from Files", imported ? @"Replace" : @"Import", name],
        @"sourceDetail":imported ? @"Your source is already stored on this phone. Importing it again will not unlock container launch." : @"Import your decrypted IPA to prepare this app's source.",
        @"executionTitle":enabled ? @"Container support enabled" : [NSString stringWithFormat:@"%@ containers are not enabled in this build",name],
        @"executionDetail":enabled ? @"Each container must still pass its launch checks." : @"App-specific isolation and launch verification are unfinished. This requires a SocialBox update; it cannot be fixed by repeating the import.",
        @"networkTitle":network ? @"Device VPN setup reported ready" : @"Network protection not verified",
        @"networkDetail":network ? @"Each container still needs its own verified managed routing before launch." : @"This build needs managed per-app VPN setup through an MDM service. A proxy address or SocialBox license alone does not configure it."};
}
