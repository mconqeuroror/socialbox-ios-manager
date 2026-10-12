#import "RBXCloudListController.h"
#import <UIKit/UIKit.h>

#import "RBXCloudOrigin.h"
// Legacy preferences pane. The shipped preferences bundle opens SocialBox.
//
// The pane reads/writes /var/mobile/Library/Preferences/com.redditbox.cloud.plist
// and rings the daemon's doorbell ("com.redditbox.cloudAction"). The daemon
// (RBXCloudSync) performs all network + crypto work; this bundle only edits
// fields and fires actions. Result feedback goes to the central store alerts
// + the daemon's NSLog, so the dashboard stays the single source of status.

static NSString *const kCloudPlist = @"/var/mobile/Library/Preferences/com.redditbox.cloud.plist";

static NSDictionary *RBXCloudRead(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kCloudPlist];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

static void RBXCloudWrite(NSMutableDictionary *d) {
    [d writeToFile:kCloudPlist atomically:YES];
}

static NSString *RBXCloudString(NSDictionary *d, NSString *key, NSString *fallback) {
    id v = d[key];
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
    return fallback;
}

// Write an action into the cloud plist (replacing any previous pending action)
// and ring the daemon's doorbell.
static void RBXCloudFireAction(NSDictionary *fields) {
    NSMutableDictionary *d = [RBXCloudRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    [d removeObjectForKey:@"action"];
    [d removeObjectForKey:@"pairingCode"];
    [d removeObjectForKey:@"backupId"];
    [d removeObjectForKey:@"containerId"];
    [d addEntriesFromDictionary:fields];
    [d writeToFile:kCloudPlist atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          CFSTR("com.redditbox.cloudAction"),
                                          NULL, NULL, TRUE);
}

@implementation RBXCloudListController

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _specifiers = nil;   // rebuild (pairing state / passphrase may have changed)
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;

    NSDictionary *d = RBXCloudRead();
    NSMutableArray *specs = [NSMutableArray array];

    // ---- Server URL -------------------------------------------------------
    PSSpecifier *server = [PSSpecifier preferenceSpecifierNamed:@"Server URL"
        target:self
        set:@selector(setCloudValue:specifier:)
        get:@selector(readCloudValue:)
        detail:nil
        cell:PSEditTextCell
        edit:nil];
    [server setIdentifier:@"serverURL"];
    [server setProperty:RBXCloudProductionOrigin forKey:@"placeholder"];
    [server setProperty:RBXCloudProductionOrigin forKey:@"default"];
    [specs addObject:server];

    PSSpecifier *accessKey = [PSSpecifier preferenceSpecifierNamed:@"Access Key"
        target:self
        set:@selector(setCloudValue:specifier:)
        get:@selector(readCloudValue:)
        detail:nil
        cell:PSEditTextCell
        edit:nil];
    [accessKey setIdentifier:@"accessKey"];
    [accessKey setProperty:@"XXXX-XXXX-XXXX-XXXX" forKey:@"placeholder"];
    [accessKey setProperty:@"" forKey:@"default"];
    [specs addObject:accessKey];

    BOOL locked = NO;
    id lockedVal = d[@"licenseLocked"];
    if ([lockedVal isKindOfClass:[NSNumber class]]) locked = [lockedVal boolValue];
    NSString *licStatus = RBXCloudString(d, @"licenseStatus", nil);
    NSString *licLine;
    if (!RBXCloudString(d, @"accessKey", nil)) {
        licLine = @"License: no access key — RedditBox locked";
    } else if (locked || [licStatus isEqualToString:@"invalid"]) {
        licLine = @"License: invalid — RedditBox locked";
    } else if ([licStatus isEqualToString:@"valid"]) {
        licLine = @"License: valid";
    } else {
        licLine = @"License: not checked yet";
    }
    PSSpecifier *licSpec = [PSSpecifier preferenceSpecifierNamed:licLine
        target:self
        set:nil
        get:nil
        detail:nil
        cell:PSStaticTextCell
        edit:nil];
    [specs addObject:licSpec];

    // ---- Pairing ------------------------------------------------------------
    PSSpecifier *codeField = [PSSpecifier preferenceSpecifierNamed:@"Pairing code"
        target:self
        set:@selector(setCloudValue:specifier:)
        get:@selector(readCloudValue:)
        detail:nil
        cell:PSEditTextCell
        edit:nil];
    [codeField setIdentifier:@"pairingCode"];
    [codeField setProperty:@"" forKey:@"placeholder"];
    [codeField setProperty:@"" forKey:@"default"];
    [specs addObject:codeField];

    PSSpecifier *pairBtn = [PSSpecifier preferenceSpecifierNamed:@"Pair device"
        target:self
        set:nil
        get:nil
        detail:nil
        cell:PSButtonCell
        edit:nil];
    [pairBtn setButtonAction:@selector(didTapPair:)];
    [pairBtn setProperty:@YES forKey:@"enabled"];
    [specs addObject:pairBtn];

    // ---- Device status -------------------------------------------------------
    NSString *deviceName = RBXCloudString(d, @"deviceName", nil);
    NSString *deviceId = RBXCloudString(d, @"deviceId", nil);
    NSString *token = RBXCloudString(d, @"deviceToken", nil);
    NSString *status = token ? [NSString stringWithFormat:@"Paired: %@ (%@)",
                                 deviceName ?: @"device", deviceId ?: @"no id"]
                            : @"Not paired";
    PSSpecifier *statusSpec = [PSSpecifier preferenceSpecifierNamed:status
        target:self
        set:nil
        get:nil
        detail:nil
        cell:PSStaticTextCell
        edit:nil];
    [specs addObject:statusSpec];

    // ---- Passphrase ---------------------------------------------------------
    // Shown so the operator can copy it to the other phone manually. Never
    // leaves the device (it only ever encrypts/decrypts local blobs).
    NSString *passphrase = RBXCloudString(d, @"passphrase", nil);
    PSSpecifier *ppSpec = [PSSpecifier preferenceSpecifierNamed:@"Passphrase"
        target:self
        set:nil
        get:@selector(readPassphraseValue:)
        detail:nil
        cell:PSEditTextCell
        edit:nil];
    [ppSpec setIdentifier:@"passphrase"];
    [ppSpec setProperty:passphrase ?: @"(daemon not started yet)" forKey:@"placeholder"];
    [ppSpec setProperty:passphrase ?: @"" forKey:@"default"];
    // Read-only display: PSEditTextView's "editable" can't be forced off for
    // PSEditTextCell reliably across iOS versions, so the getter is the source
    // and any manual edit is simply overwritten by the daemon (it never reads
    // user input here). The copyable text field is the point.
    [specs addObject:ppSpec];

    PSSpecifier *regenBtn = [PSSpecifier preferenceSpecifierNamed:@"Regenerate passphrase"
        target:self
        set:nil
        get:nil
        detail:nil
        cell:PSButtonCell
        edit:nil];
    [regenBtn setButtonAction:@selector(didTapRegeneratePassphrase:)];
    [regenBtn setProperty:@YES forKey:@"enabled"];
    [specs addObject:regenBtn];

    // ---- Export ---------------------------------------------------------------
    PSSpecifier *contField = [PSSpecifier preferenceSpecifierNamed:@"Container id (optional)"
        target:self
        set:@selector(setCloudValue:specifier:)
        get:@selector(readCloudValue:)
        detail:nil
        cell:PSEditTextCell
        edit:nil];
    [contField setIdentifier:@"containerId"];
    [contField setProperty:@"" forKey:@"placeholder"];
    [contField setProperty:@"" forKey:@"default"];
    [specs addObject:contField];

    PSSpecifier *exportBtn = [PSSpecifier preferenceSpecifierNamed:@"Export active container"
        target:self
        set:nil
        get:nil
        detail:nil
        cell:PSButtonCell
        edit:nil];
    [exportBtn setButtonAction:@selector(didTapExport:)];
    [exportBtn setProperty:@YES forKey:@"enabled"];
    [specs addObject:exportBtn];

    // ---- Import ---------------------------------------------------------------
    PSSpecifier *importBtn = [PSSpecifier preferenceSpecifierNamed:@"Import newest backup"
        target:self
        set:nil
        get:nil
        detail:nil
        cell:PSButtonCell
        edit:nil];
    [importBtn setButtonAction:@selector(didTapImportNewest:)];
    [importBtn setProperty:@YES forKey:@"enabled"];
    [specs addObject:importBtn];

    PSSpecifier *backupField = [PSSpecifier preferenceSpecifierNamed:@"Backup id"
        target:self
        set:@selector(setCloudValue:specifier:)
        get:@selector(readCloudValue:)
        detail:nil
        cell:PSEditTextCell
        edit:nil];
    [backupField setIdentifier:@"backupId"];
    [backupField setProperty:@"" forKey:@"placeholder"];
    [backupField setProperty:@"" forKey:@"default"];
    [specs addObject:backupField];

    PSSpecifier *importIdBtn = [PSSpecifier preferenceSpecifierNamed:@"Import by ID"
        target:self
        set:nil
        get:nil
        detail:nil
        cell:PSButtonCell
        edit:nil];
    [importIdBtn setButtonAction:@selector(didTapImportById:)];
    [importIdBtn setProperty:@YES forKey:@"enabled"];
    [specs addObject:importIdBtn];

    // ---- Options ---------------------------------------------------------------
    PSSpecifier *stale = [PSSpecifier preferenceSpecifierNamed:@"Allow stale imports (>72h)"
        target:self
        set:@selector(setCloudValue:specifier:)
        get:@selector(readCloudValue:)
        detail:nil
        cell:PSSwitchCell
        edit:nil];
    [stale setIdentifier:@"allowStale"];
    [stale setProperty:@NO forKey:@"default"];
    [specs addObject:stale];

    PSSpecifier *attest = [PSSpecifier preferenceSpecifierNamed:@"Worker attest policy: authentic (re-attest)"
        target:self
        set:@selector(setCloudValue:specifier:)
        get:@selector(readCloudValue:)
        detail:nil
        cell:PSSwitchCell
        edit:nil];
    [attest setIdentifier:@"workerAttestPolicy"];
    [attest setProperty:@YES forKey:@"default"];   // YES = "re-attest"; NO = "off"
    [specs addObject:attest];

    _specifiers = specs;
    return _specifiers;
}

#pragma mark - Value storage (cloud plist)

- (id)readCloudValue:(PSSpecifier *)specifier {
    NSDictionary *d = RBXCloudRead();
    id value = d[[specifier identifier]];
    if ([specifier.identifier isEqualToString:@"workerAttestPolicy"]) {
        // Stored as a string policy; switch reads it as BOOL (default re-attest).
        return @(![RBXCloudString(d, @"workerAttestPolicy", @"re-attest") isEqualToString:@"off"]);
    }
    return value ?: [specifier propertyForKey:@"default"];
}

- (void)setCloudValue:(id)value specifier:(PSSpecifier *)specifier {
    NSMutableDictionary *d = [RBXCloudRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    if ([specifier.identifier isEqualToString:@"workerAttestPolicy"]) {
        d[@"workerAttestPolicy"] = [value boolValue] ? @"re-attest" : @"off";
    } else {
        d[[specifier identifier]] = value;
    }
    RBXCloudWrite(d);
}

// Passphrase display is read-only; always re-read from the plist.
- (id)readPassphraseValue:(PSSpecifier *)specifier {
    (void)specifier;
    return RBXCloudString(RBXCloudRead(), @"passphrase", @"");
}

#pragma mark - Actions (doorbell to the daemon)

- (void)didTapPair:(PSSpecifier *)specifier {
    NSString *code = RBXCloudString(RBXCloudRead(), @"pairingCode", nil);
    if (!code) {
        [self _toast:@"Enter a pairing code first"];
        return;
    }
    RBXCloudFireAction(@{ @"action": @"pair", @"pairingCode": code });
    [self _toast:@"Pairing — see Dashboard alerts/Log for the result"];
}

- (void)didTapRegeneratePassphrase:(PSSpecifier *)specifier {
    RBXCloudFireAction(@{ @"action": @"regeneratePassphrase" });
    [self _toast:@"Passphrase regenerated (old exports can no longer be decrypted here)"];
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)didTapExport:(PSSpecifier *)specifier {
    NSString *containerId = RBXCloudString(RBXCloudRead(), @"containerId", nil);
    NSMutableDictionary *fields = [@{ @"action": @"export" } mutableCopy];
    if (containerId) fields[@"containerId"] = containerId;
    RBXCloudFireAction(fields);
    [self _toast:@"Exporting — see Dashboard alerts/Log for the result"];
}

- (void)didTapImportNewest:(PSSpecifier *)specifier {
    RBXCloudFireAction(@{ @"action": @"importNewest" });
    [self _toast:@"Importing newest — see Dashboard alerts/Log for the result"];
}

- (void)didTapImportById:(PSSpecifier *)specifier {
    NSString *backupId = RBXCloudString(RBXCloudRead(), @"backupId", nil);
    if (!backupId) {
        [self _toast:@"Enter a backup id first"];
        return;
    }
    RBXCloudFireAction(@{ @"action": @"importById", @"backupId": backupId });
    [self _toast:@"Importing — see Dashboard alerts/Log for the result"];
}

- (void)_toast:(NSString *)text {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                     message:text
                                                              preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];

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
        [top presentViewController:alert animated:YES completion:nil];
    });
}

@end
