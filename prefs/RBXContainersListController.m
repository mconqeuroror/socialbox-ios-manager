#import "RBXContainersListController.h"
#import "RBXDataSchema.h"
#import "RBXMGOverrides.h"
#import <UIKit/UIKit.h>

static NSString *const kProfilesDir = @"/var/mobile/Library/Preferences/com.redditbox.profiles";
static NSString *const kPendingPath = @"/var/mobile/Library/Preferences/com.redditbox.pending.plist";
static NSString *const kStorePath = @"/var/mobile/Library/Preferences/com.redditbox.store.json";

static NSArray<NSString *> *RBXListContainerIds(void) {
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kProfilesDir error:nil];
    NSMutableArray *ids = [NSMutableArray array];
    for (NSString *f in files) {
        if ([f hasSuffix:@".json"]) [ids addObject:[f stringByDeletingPathExtension]];
    }
    return [ids sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

static NSDictionary *RBXLoadProfile(NSString *containerId, NSData **bytes) {
    NSString *path = [[kProfilesDir stringByAppendingPathComponent:containerId]
                      stringByAppendingPathExtension:@"json"];
    NSData *data = RBXSchemaReadBytes(path, NULL, nil);
    if (bytes) *bytes = data;
    NSDictionary *profile = RBXSchemaDecode(data, RBXDataProfile, nil);
    return [profile[@"containerId"] isEqual:containerId] ? profile : nil;
}

static BOOL RBXWriteProfile(NSString *containerId, NSDictionary *profile, NSData *expected) {
    NSString *path = [[kProfilesDir stringByAppendingPathComponent:containerId]
                      stringByAppendingPathExtension:@"json"];
    NSMutableDictionary *complete = [profile mutableCopy];
    complete[@"mgOverrides"] = RBXBuildMGOverrides(complete);
    return expected && RBXSchemaWriteJSONExpected(complete, path, RBXDataProfile, expected, nil);
}

static void RBXFireContainerAction(NSDictionary *fields) {
    [fields writeToFile:kPendingPath atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          CFSTR("com.redditbox.containerAction"),
                                          NULL, NULL, TRUE);
}

static NSString *RBXNickname(NSString *containerId) {
    NSData *data = [NSData dataWithContentsOfFile:kStorePath];
    NSDictionary *doc = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (!RBXSchemaValidate(doc, RBXDataStore, nil)) return containerId;
    NSString *nick = doc[@"containers"][containerId][@"nickname"];
    return [nick isKindOfClass:[NSString class]] && nick.length ? nick : containerId;
}

@implementation RBXContainersListController

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *specs = [NSMutableArray array];

    PSSpecifier *addName = [PSSpecifier preferenceSpecifierNamed:@"New id / nickname"
        target:self set:@selector(setDraft:specifier:) get:@selector(readDraft:)
        detail:nil cell:PSEditTextCell edit:nil];
    [addName setIdentifier:@"draftId"];
    [addName setProperty:@"" forKey:@"default"];
    [specs addObject:addName];

    PSSpecifier *country = [PSSpecifier preferenceSpecifierNamed:@"Proxy country"
        target:self set:@selector(setDraft:specifier:) get:@selector(readDraft:)
        detail:nil cell:PSEditTextCell edit:nil];
    [country setIdentifier:@"draftCountry"];
    [country setProperty:@"US" forKey:@"default"];
    [specs addObject:country];

    PSSpecifier *addBtn = [PSSpecifier preferenceSpecifierNamed:@"Add container"
        target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    [addBtn setButtonAction:@selector(didTapAdd:)];
    [addBtn setProperty:@YES forKey:@"enabled"];
    [specs addObject:addBtn];

    for (NSString *cid in RBXListContainerIds()) {
        NSDictionary *profile = RBXLoadProfile(cid, NULL);
        NSString *posture = profile[@"ids"][@"posture"];
        NSString *purl = profile[@"proxy"][@"url"];
        if (![purl isKindOfClass:[NSString class]]) purl = @"";
        NSString *title = [NSString stringWithFormat:@"%@  ·  %@  ·  %@",
                           RBXNickname(cid),
                           [posture isEqualToString:@"zeroWithATTDenied"] ? @"IDFA zero" : @"IDFA random",
                           purl.length ? @"proxy set" : @"no proxy"];
        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:title
            target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        [row setButtonAction:@selector(didTapContainer:)];
        [row setProperty:cid forKey:@"containerId"];
        [row setProperty:@YES forKey:@"enabled"];
        [specs addObject:row];
    }

    if (RBXListContainerIds().count == 0) {
        PSSpecifier *empty = [PSSpecifier preferenceSpecifierNamed:@"No containers yet — add one above"
            target:self set:nil get:nil detail:nil cell:PSStaticTextCell edit:nil];
        [specs addObject:empty];
    }

    _specifiers = specs;
    return _specifiers;
}

- (id)readDraft:(PSSpecifier *)specifier {
    return [specifier propertyForKey:@"_draft"] ?: [specifier propertyForKey:@"default"];
}

- (void)setDraft:(id)value specifier:(PSSpecifier *)specifier {
    [specifier setProperty:value ?: @"" forKey:@"_draft"];
}

- (NSString *)_draftValue:(NSString *)identifier fallback:(NSString *)fallback {
    for (PSSpecifier *s in self.specifiers) {
        if ([s.identifier isEqualToString:identifier]) {
            id v = [s propertyForKey:@"_draft"];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
        }
    }
    return fallback;
}

- (void)didTapAdd:(PSSpecifier *)specifier {
    (void)specifier;
    NSString *cid = [self _draftValue:@"draftId" fallback:@""];
    NSString *country = [self _draftValue:@"draftCountry" fallback:@"US"];
    NSMutableDictionary *fields = [@{
        @"action": @"createContainer",
        @"country": country,
        @"proxyURL": @"",
        @"nickname": cid,
    } mutableCopy];
    if (cid.length) fields[@"container"] = cid;
    RBXFireContainerAction(fields);
    [self _toast:@"Creating container — pull this page to refresh"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self->_specifiers = nil;
        [self reloadSpecifiers];
    });
}

- (void)didTapContainer:(PSSpecifier *)specifier {
    NSString *cid = [specifier propertyForKey:@"containerId"];
    if (![cid isKindOfClass:[NSString class]] || !cid.length) return;

    NSData *expected = nil;
    NSDictionary *profile = RBXLoadProfile(cid, &expected);
    if (!profile) { [self _toast:@"Profile is unreadable or needs a newer build; data retained"]; return; }
    BOOL zero = [profile[@"ids"][@"posture"] isEqualToString:@"zeroWithATTDenied"];
    BOOL appAttestEnabled = [profile[@"security"][@"appAttest"] isEqualToString:@"enabled"];
    BOOL deviceCheckEnabled = [profile[@"security"][@"deviceCheck"] isEqualToString:@"enabled"];
    BOOL sensorAccessEnabled = [profile[@"security"][@"sensorAccess"] isEqualToString:@"enabled"];
    BOOL localNetworkingEnabled = [profile[@"security"][@"localNetworking"] isEqualToString:@"enabled"];
    BOOL networkMetadataEnabled = [profile[@"security"][@"networkMetadata"] isEqualToString:@"enabled"];
    BOOL thirdPartyNetworkEnabled = [profile[@"security"][@"thirdPartyNetwork"] isEqualToString:@"enabled"];
    BOOL strictTimingEnabled = [profile[@"security"][@"strictTiming"] isEqualToString:@"enabled"];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:cid
        message:RBXNickname(cid)
        preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:zero ? @"IDFA: switch to random" : @"IDFA: switch to zero + ATT denied"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a;
            NSMutableDictionary *p = [profile mutableCopy];
            NSMutableDictionary *ids = [p[@"ids"] isKindOfClass:[NSDictionary class]]
                ? [p[@"ids"] mutableCopy] : [NSMutableDictionary dictionary];
            if (zero) {
                ids[@"posture"] = @"random";
                if (![ids[@"idfa"] isKindOfClass:[NSString class]] ||
                    [ids[@"idfa"] hasPrefix:@"00000000"]) {
                    ids[@"idfa"] = [[NSUUID UUID] UUIDString];
                }
            } else {
                ids[@"posture"] = @"zeroWithATTDenied";
                ids[@"idfa"] = @"00000000-0000-0000-0000-000000000000";
            }
            p[@"ids"] = ids;
            if (!RBXWriteProfile(cid, p, expected)) { [self _toast:@"Profile changed or could not be saved; reopen it and retry"]; return; }
            self->_specifiers = nil;
            [self reloadSpecifiers];
        }]];

    void (^setSecurityPolicy)(NSString *, NSString *, NSString *) =
        ^(NSString *key, NSString *value, NSString *message) {
            NSMutableDictionary *p = [profile mutableCopy];
            NSMutableDictionary *security = [p[@"security"] mutableCopy] ?:
                [NSMutableDictionary dictionary];
            security[key] = value;
            p[@"security"] = security;
            if (!RBXWriteProfile(cid, p, expected)) { [self _toast:@"Profile changed or could not be saved; reopen it and retry"]; return; }
            [self _toast:message];
        };

    [sheet addAction:[UIAlertAction actionWithTitle:
        sensorAccessEnabled ? @"Sensors: block (safer)" : @"Sensors: enable (leaks hardware motion)"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            setSecurityPolicy(@"sensorAccess", sensorAccessEnabled ? @"blocked" : @"enabled",
                sensorAccessEnabled ? @"Physical sensors blocked after relaunch" :
                @"Physical sensors enabled: containers can be correlated by motion");
        }]];

    [sheet addAction:[UIAlertAction actionWithTitle:
        localNetworkingEnabled ? @"Local network: block (safer)" :
                                 @"Local network: enable for compatibility"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            setSecurityPolicy(@"localNetworking", localNetworkingEnabled ? @"blocked" : @"enabled",
                localNetworkingEnabled ? @"Loopback/local networking blocked after relaunch" :
                @"Loopback enabled: another local process may become a cross-container channel");
        }]];

    [sheet addAction:[UIAlertAction actionWithTitle:
        strictTimingEnabled ? @"Timing virtualization: disable for compatibility" :
                              @"Timing virtualization: enable (safer)"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            setSecurityPolicy(@"strictTiming", strictTimingEnabled ? @"blocked" : @"enabled",
                strictTimingEnabled ? @"Real monotonic clocks exposed after relaunch" :
                @"Monotonic clocks virtualized after relaunch");
        }]];

    [sheet addAction:[UIAlertAction actionWithTitle:
        networkMetadataEnabled ? @"Wi-Fi/interface metadata: block (safer)" :
                                 @"Wi-Fi/interface metadata: enable"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            setSecurityPolicy(@"networkMetadata",
                networkMetadataEnabled ? @"blocked" : @"enabled",
                networkMetadataEnabled ? @"SSID/BSSID/interfaces blocked after relaunch" :
                @"Network metadata enabled: SSID, BSSID and local IP may link containers");
        }]];

    [sheet addAction:[UIAlertAction actionWithTitle:
        thirdPartyNetworkEnabled ? @"Third-party SDK network: block (safer)" :
                                   @"Third-party SDK network: enable for login test"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            setSecurityPolicy(@"thirdPartyNetwork",
                thirdPartyNetworkEnabled ? @"blocked" : @"enabled",
                thirdPartyNetworkEnabled ? @"Non-Reddit SDK hosts blocked after relaunch" :
                @"Third-party hosts enabled: analytics/crash SDKs may transmit fingerprints");
        }]];

    [sheet addAction:[UIAlertAction actionWithTitle:
        appAttestEnabled ? @"App Attest: block (safer)" : @"App Attest: enable for login test"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a;
            NSMutableDictionary *p = [profile mutableCopy];
            NSMutableDictionary *security = [p[@"security"] mutableCopy] ?:
                [NSMutableDictionary dictionary];
            security[@"appAttest"] = appAttestEnabled ? @"blocked" : @"enabled";
            p[@"security"] = security;
            if (!RBXWriteProfile(cid, p, expected)) { [self _toast:@"Profile changed or could not be saved; reopen it and retry"]; return; }
            [self _toast:appAttestEnabled ? @"App Attest blocked" :
                @"App Attest enabled: this exposes a physical-device attestation signal"];
        }]];

    [sheet addAction:[UIAlertAction actionWithTitle:
        deviceCheckEnabled ? @"DeviceCheck: block (safer)" : @"DeviceCheck: enable for login test"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a;
            NSMutableDictionary *p = [profile mutableCopy];
            NSMutableDictionary *security = [p[@"security"] mutableCopy] ?:
                [NSMutableDictionary dictionary];
            security[@"deviceCheck"] = deviceCheckEnabled ? @"blocked" : @"enabled";
            p[@"security"] = security;
            if (!RBXWriteProfile(cid, p, expected)) { [self _toast:@"Profile changed or could not be saved; reopen it and retry"]; return; }
            [self _toast:deviceCheckEnabled ? @"DeviceCheck blocked" :
                @"DeviceCheck enabled: this exposes a physical-device token"];
        }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) {
            (void)a;
            RBXFireContainerAction(@{ @"action": @"deleteContainer", @"container": cid });
            [self _toast:@"Deleting — pull this page to refresh"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                self->_specifiers = nil;
                [self reloadSpecifiers];
            });
        }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self _present:sheet];
}

- (void)_toast:(NSString *)text {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                 message:text
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self _present:alert];
}

- (void)_present:(UIAlertController *)alert {
    UIWindow *window = nil;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindow *w = ((UIWindowScene *)scene).keyWindow;
            if (w) { window = w; break; }
        }
    }
    if (!window) window = [UIApplication sharedApplication].keyWindow;
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (alert.preferredStyle == UIAlertControllerStyleActionSheet && top.view.bounds.size.width > 500) {
        alert.popoverPresentationController.sourceView = top.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(top.view.bounds.size.width / 2,
                                                                    top.view.bounds.size.height / 2, 1, 1);
    }
    [top presentViewController:alert animated:YES completion:nil];
}

@end
