#import "RBXDashboardController.h"
#import "RBXDataSchema.h"
#import <UIKit/UIKit.h>

// Operator dashboard (Features 4 + 5).
//
// Reads the central store directly (the prefs process may not have the daemon's
// RBXCentralStore class linked, so this file uses plain JSON reading — the same
// pattern as the tweak-side hooks).

static NSString *const kStorePath = @"/var/mobile/Library/Preferences/com.redditbox.store.json";
static NSString *const kPendingPath = @"/var/mobile/Library/Preferences/com.redditbox.pending.plist";

static NSDictionary *RBXReadStore(NSData **bytes) {
    BOOL missing = NO;
    NSData *data = RBXSchemaReadBytes(kStorePath, &missing, nil);
    if (bytes) *bytes = data;
    return missing ? @{} : RBXSchemaDecode(data, RBXDataStore, nil);
}

static BOOL RBXWriteStore(NSDictionary *doc, NSData *expected) {
    if (!RBXSchemaWriteJSONCompared(doc, kStorePath, RBXDataStore, expected, !expected, nil)) return NO;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.redditbox.storeChanged"), NULL, NULL, TRUE);
    return YES;
}

static void RBXPostDarwin(NSString *name) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge CFStringRef)name,
                                        NULL, NULL, TRUE);
}

static BOOL RBXContainerIsLive(NSDictionary *c) {
    if (![c isKindOfClass:[NSDictionary class]]) return NO;
    NSString *reason = c[@"deathReason"];
    if ([reason isKindOfClass:[NSString class]] && reason.length > 0) return NO;
    if ([c[@"paused"] boolValue]) return NO;
    return YES;
}

@implementation RBXDashboardController {
    NSDictionary *_store;
}

- (id)init {
    self = [super init];
    if (self) _store = RBXReadStore(NULL);
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _store = RBXReadStore(NULL);
    _specifiers = nil;   // rebuild every time (store may have changed)
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;

    _store = RBXReadStore(NULL);
    NSMutableArray *specs = [NSMutableArray array];

    // ---- Header: device-level status ----------------------------------------
    NSArray *keysUsed = _store[@"device"][@"attestKeysUsed"];
    NSInteger keyCount = [keysUsed isKindOfClass:[NSArray class]] ? keysUsed.count : 0;
    NSInteger budget = [_store[@"device"][@"keyBudget"] integerValue] ?: 100;
    if (budget <= 0) budget = 100;

    NSString *keyTitle = [NSString stringWithFormat:@"🔑 Keys: %ld / ~%ld (device)",
                         (long)keyCount, (long)budget];
    PSSpecifier *keys = [PSSpecifier preferenceSpecifierNamed:keyTitle
        target:self
        set:nil
        get:nil
        detail:nil
        cell:PSStaticTextCell
        edit:nil];
    [keys setProperty:keyTitle forKey:@"title"];
    if (keyCount >= (NSInteger)(budget * 0.95)) {
        [keys setProperty:[UIColor systemRedColor] forKey:@"titleColor"];
    } else if (keyCount >= (NSInteger)(budget * 0.80)) {
        [keys setProperty:[UIColor systemYellowColor] forKey:@"titleColor"];
    }
    [specs addObject:keys];

    NSArray *alerts = _store[@"alerts"];
    NSInteger leakCount = [alerts isKindOfClass:[NSArray class]] ? alerts.count : 0;
    PSSpecifier *leaks = [PSSpecifier preferenceSpecifierNamed:@"Leaks"
        target:self
        set:nil
        get:nil
        detail:nil
        cell:PSStaticTextCell
        edit:nil];
    [leaks setProperty:[NSString stringWithFormat:@"⚠️ Leaks: %ld", (long)leakCount]
                forKey:@"title"];
    if (leakCount > 0) {
        [leaks setProperty:[UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1] forKey:@"titleColor"];
    }
    [specs addObject:leaks];

    NSString *defOn = [_store[@"device"][@"attestDefault"] isEqualToString:@"off"] ? @"OFF" : @"ON";
    PSSpecifier *attest = [PSSpecifier preferenceSpecifierNamed:@"Attest default"
        target:self
        set:nil
        get:nil
        detail:nil
        cell:PSStaticTextCell
        edit:nil];
    [attest setProperty:[NSString stringWithFormat:@"App Attest default: %@", defOn]
                 forKey:@"title"];
    [specs addObject:attest];

    // ---- Containers ----------------------------------------------------------
    NSDictionary *containers = _store[@"containers"];
    if (![containers isKindOfClass:[NSDictionary class]] ||
        containers.count == 0) {
        PSSpecifier *empty = [PSSpecifier preferenceSpecifierNamed:@"No containers yet"
            target:self
            set:nil
            get:nil
            detail:nil
            cell:PSStaticTextCell
            edit:nil];
        [specs addObject:empty];
    } else {
        for (NSString *containerId in [[containers allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            NSDictionary *c = containers[containerId];
            if (![c isKindOfClass:[NSDictionary class]]) continue;

            NSString *status = [c[@"status"] isKindOfClass:[NSString class]] ? c[@"status"] : @"yellow";
            NSString *dot = @"🟡";
            if ([status isEqualToString:@"green"]) dot = @"🟢";
            else if ([status isEqualToString:@"red"]) dot = @"🔴";

            NSString *nickname = [c[@"nickname"] isKindOfClass:[NSString class]] ?
                c[@"nickname"] : containerId;
            NSInteger karma = [c[@"karma"] integerValue];
            NSString *group = [c[@"attest"][@"group"] isEqualToString:@"B"] ? @"B" : @"A";

            // Effective attest: container override, else group default, else global.
            NSString *eff = @"ON";
            NSString *mode = c[@"attest"][@"mode"];
            if ([mode isEqualToString:@"on"]) eff = @"ON";
            else if ([mode isEqualToString:@"off"]) eff = @"OFF";
            else if ([group isEqualToString:@"B"]) eff = @"OFF";

            NSString *detail = [NSString stringWithFormat:@"%@ · karma %ld · group %@ · attest %@",
                               dot, (long)karma, group, eff];
            if ([c[@"paused"] boolValue]) detail = [detail stringByAppendingString:@" · PAUSED"];

            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:[nickname stringByAppendingFormat:@" - %@", detail]
                target:self
                set:nil
                get:nil
                detail:nil
                cell:PSStaticTextCell
                edit:nil];
            [spec setProperty:detail forKey:@"subtitle"];
            [spec setProperty:containerId forKey:@"containerId"];
            [specs addObject:spec];
        }
    }

    // ---- A/B Report (Feature 5) ----------------------------------------------
    [self _appendABReport:specs];

    _specifiers = specs;
    return _specifiers;
}

- (void)_appendABReport:(NSMutableArray *)specs {
    NSDictionary *containers = _store[@"containers"];
    if (![containers isKindOfClass:[NSDictionary class]]) return;

    // per group
    NSArray *groupKeys = @[@"A", @"B"];
    NSInteger winner = -1;
    double bestScore = -1;
    for (NSInteger g = 0; g < 2; g++) {
        double sumDays = 0;
        NSInteger n = 0, missions = 0, bans = 0, total = 0;
        for (NSString *containerId in containers) {
            NSDictionary *c = containers[containerId];
            if (![c isKindOfClass:[NSDictionary class]]) continue;
            NSString *grp = c[@"attest"][@"group"];
            if ((g == 0 && ![grp isEqualToString:@"A"]) ||
                (g == 1 && ![grp isEqualToString:@"B"])) continue;
            total++;
            NSTimeInterval created = [c[@"createdAt"] doubleValue];
            NSTimeInterval died = [c[@"diedAt"] doubleValue];
            if (created > 0) {
                NSTimeInterval end = died > 0 ? died : [[NSDate date] timeIntervalSince1970];
                sumDays += (end - created) / 86400.0;
                n++;
            }
            if ([c[@"missionCompleted"] boolValue]) missions++;
            NSString *reason = c[@"deathReason"];
            if ([reason isEqualToString:@"ban"] || [reason isEqualToString:@"shadowban"]) bans++;
        }
        double avgDays = n > 0 ? sumDays / n : 0;
        double missionPct = total > 0 ? 100.0 * missions / total : 0;
        double banPct = total > 0 ? 100.0 * bans / total : 0;

        PSSpecifier *report = [PSSpecifier preferenceSpecifierNamed:@"A/B Report"
            target:self
            set:nil
            get:nil
            detail:nil
            cell:PSStaticTextCell
            edit:nil];
        [report setProperty:[NSString stringWithFormat:
            @"Group %@: %ld accounts · avg %.1f days · missions %.0f%% · banned %.0f%%",
            groupKeys[g], (long)total, avgDays, missionPct, banPct]
            forKey:@"title"];
        [specs addObject:report];

        if (total >= 30) {
            double score = avgDays * (1.0 - banPct / 100.0);
            if (score > bestScore) {
                bestScore = score;
                winner = g;
            }
        }
    }

    // Winner banner with an action to set the default (Feature 5).
    if (winner >= 0) {
        PSSpecifier *win = [PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:
            @"Winner: group %@ — set as default?", groupKeys[winner]]
            target:self
            set:nil
            get:nil
            detail:nil
            cell:PSButtonCell
            edit:nil];
        [win setProperty:@YES forKey:@"enabled"];
        [win setButtonAction:@selector(didTapWinner:)];
        [win setProperty:groupKeys[winner] forKey:@"winnerGroup"];
        [specs addObject:win];
    }
}

- (void)didTapWinner:(PSSpecifier *)specifier {
    NSString *group = [specifier propertyForKey:@"winnerGroup"];
    if (![group isKindOfClass:[NSString class]] || group.length == 0) return;

    NSData *expected = nil;
    NSMutableDictionary *doc = [RBXReadStore(&expected) mutableCopy];
    if (![doc isKindOfClass:[NSMutableDictionary class]]) doc = [NSMutableDictionary dictionary];
    NSMutableDictionary *device = [doc[@"device"] isKindOfClass:[NSDictionary class]] ?
        [doc[@"device"] mutableCopy] : [NSMutableDictionary dictionary];
    device[@"attestDefault"] = [group isEqualToString:@"B"] ? @"off" : @"on";
    doc[@"device"] = device;
    if (!RBXWriteStore(doc, expected)) { [self _showPublicationFailure]; return; }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Saved"
        message:[NSString stringWithFormat:@"New accounts will use App Attest %@", [group isEqualToString:@"B"] ? @"OFF" : @"ON"]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self _present:alert];

    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)setDefaultGroup:(NSString *)group {
    // Kept for future programmatic use; the primary path is didTapWinner:.
    (void)group;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // Flat specifier list: section 0, row == index into self.specifiers.
    if (indexPath.section != 0) return;
    if (indexPath.row >= (NSInteger)self.specifiers.count) return;

    PSSpecifier *spec = self.specifiers[indexPath.row];
    if (![spec propertyForKey:@"containerId"]) return;
    [self didTapContainer:spec];
}

- (void)didTapContainer:(PSSpecifier *)specifier {
    NSString *containerId = [specifier propertyForKey:@"containerId"];
    if (![containerId isKindOfClass:[NSString class]] || !containerId.length) return;

    NSDictionary *c = _store[@"containers"][containerId];
    NSString *nickname = [c[@"nickname"] isKindOfClass:[NSString class]] ? c[@"nickname"] : containerId;
    BOOL paused = [c[@"paused"] boolValue];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nickname
        message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"🔄 Refresh health" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
            // Ask the daemon to run the health check for everyone (the daemon
            // checks all eligible containers; a per-container notification
            // payload is not possible with darwin notifications).
            RBXPostDarwin(@"com.redditbox.healthCheck");
        }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"♻️ Rotate container" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
            // Mark current dead (other) + request a new container.
            NSData *expected = nil;
            NSMutableDictionary *doc = [RBXReadStore(&expected) mutableCopy];
            if ([doc isKindOfClass:[NSMutableDictionary class]]) {
                NSMutableDictionary *conts = [doc[@"containers"] isKindOfClass:[NSDictionary class]] ?
                    [doc[@"containers"] mutableCopy] : [NSMutableDictionary dictionary];
                NSMutableDictionary *cont = [conts[containerId] isKindOfClass:[NSDictionary class]] ?
                    [conts[containerId] mutableCopy] : [NSMutableDictionary dictionary];
                cont[@"deathReason"] = @"other";
                cont[@"diedAt"] = @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]);
                cont[@"status"] = @"red";
                conts[containerId] = cont;
                doc[@"containers"] = conts;
                if (!RBXWriteStore(doc, expected)) { [self _showPublicationFailure]; return; }
            }
            NSDictionary *msg = @{@"action": @"createContainer", @"from": containerId};
            [msg writeToFile:kPendingPath atomically:YES];
            RBXPostDarwin(@"com.redditbox.rotate");
        }]];

    [sheet addAction:[UIAlertAction actionWithTitle:paused ? @"▶️ Resume" : @"⏸️ Pause" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
            NSData *expected = nil;
            NSMutableDictionary *doc = [RBXReadStore(&expected) mutableCopy];
            if ([doc isKindOfClass:[NSMutableDictionary class]]) {
                NSMutableDictionary *conts = [doc[@"containers"] isKindOfClass:[NSDictionary class]] ?
                    [doc[@"containers"] mutableCopy] : [NSMutableDictionary dictionary];
                NSMutableDictionary *cont = [conts[containerId] isKindOfClass:[NSDictionary class]] ?
                    [conts[containerId] mutableCopy] : [NSMutableDictionary dictionary];
                cont[@"paused"] = @(!paused);
                conts[containerId] = cont;
                doc[@"containers"] = conts;
                if (!RBXWriteStore(doc, expected)) { [self _showPublicationFailure]; return; }

                _specifiers = nil;
                [self reloadSpecifiers];
            }
        }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self _present:sheet];
}

- (void)_showPublicationFailure {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Not saved"
        message:@"Data changed or could not be saved. Original data is retained; refresh and retry."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self _present:alert];
}

- (void)_present:(UIAlertController *)alert {
    // Present on the prefs window's top-most controller.
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
    if ([alert preferredStyle] == UIAlertControllerStyleActionSheet && top.view.bounds.size.width > 500) {
        // iPad needs a popover anchor.
        alert.popoverPresentationController.sourceView = top.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(top.view.bounds.size.width / 2, top.view.bounds.size.height / 2, 1, 1);
    }
    [top presentViewController:alert animated:YES completion:nil];
}

@end
