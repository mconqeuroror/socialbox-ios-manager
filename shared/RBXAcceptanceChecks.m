#import "RBXAcceptanceChecks.h"
#import "RBXLicensePresentation.h"
#include <math.h>

static NSDictionary *RBXAcceptanceDictionary(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
static BOOL RBXAcceptanceFresh(id value, NSTimeInterval now, NSTimeInterval maximumAge) {
    if (![value isKindOfClass:NSNumber.class] || !isfinite(now)) return NO;
    double age = now - [value doubleValue];
    return isfinite(age) && age >= 0 && age <= maximumAge;
}
static NSDictionary *RBXAcceptanceRow(NSString *identifier, NSString *title,
    NSString *status, NSString *detail, NSArray *rows, NSString *evidence) {
    return @{ @"id": identifier, @"title": title, @"status": status,
              @"detail": detail, @"rows": rows, @"evidence": evidence };
}

NSArray<NSDictionary *> *RBXAcceptanceChecks(NSDictionary *launcherState, NSTimeInterval now) {
    NSDictionary *state = RBXAcceptanceDictionary(launcherState);
    BOOL fresh = RBXAcceptanceFresh(state[@"updatedAt"], now, 10);
    NSMutableArray *checks = [NSMutableArray array];
    [checks addObject:RBXAcceptanceRow(@"publication", @"Daemon publication",
        fresh ? @"PASS" : @"NOT_RUN", fresh ? @"The daemon published state within ten seconds."
            : @"No current daemon publication; refresh or open Advanced diagnostics.",
        @[@"ACCEPT-001", @"NET-037"], @"snapshot")];
    NSDictionary *license = RBXAcceptanceDictionary(state[@"license"]);
    // ACCEPT-001/UI-001: a fresh cached Boolean must not extend signed validity.
    BOOL licenseUsable = [RBXLicensePresentationState(state, now)[@"unlocked"] boolValue];
    [checks addObject:RBXAcceptanceRow(@"license", @"Device license",
        !fresh || !license.count ? @"NOT_RUN" : (licenseUsable ? @"PASS" : @"FAIL"),
        @"Current activation state and signed validity window; open License in Settings if locked.", @[@"ACCEPT-001"], @"snapshot")];
    NSDictionary *configuration = RBXAcceptanceDictionary(state[@"configuration"]);
    [checks addObject:RBXAcceptanceRow(@"configuration", @"Proxy saved",
        !fresh || !configuration.count ? @"NOT_RUN" :
            ([configuration[@"configured"] isEqual:@YES] && [configuration[@"readable"] isEqual:@YES] ? @"PASS" : @"FAIL"),
        @"Saved configuration only; a successful connection and country check require Test Configuration.",
        @[@"NET-038", @"ACCEPT-001"], @"snapshot")];
    NSDictionary *source = RBXAcceptanceDictionary(state[@"source"]);
    [checks addObject:RBXAcceptanceRow(@"source", @"Reddit source imported",
        !fresh || !source.count ? @"NOT_RUN" : ([source[@"decrypted"] isEqual:@YES] ? @"PASS" : @"FAIL"),
        @"The published source validation result; this is not a login test.", @[@"LIFE-001", @"LIFE-002"], @"snapshot")];
    [checks addObject:RBXAcceptanceRow(@"lease-state", @"Published lease is OPEN",
        !fresh || !state[@"networkState"] ? @"NOT_RUN" :
            ([state[@"networkState"] isEqual:@"open"] ? @"PASS" : @"NOT_RUN"),
        @"CLOSED is expected during setup. OPEN alone does not prove packet routing or current hook receipts.",
        @[@"LIFE-021", @"NET-036"], @"snapshot")];

    NSDictionary *report = RBXAcceptanceDictionary(state[@"diagnostics"]);
    // Report results describe their recorded inspection, not a later active clone.
    BOOL reportFresh = fresh && RBXAcceptanceFresh(report[@"generatedAt"], now, 120);
    NSMutableDictionary *byID = [NSMutableDictionary dictionary];
    id records = report[@"checks"];
    if ([records isKindOfClass:NSArray.class]) for (id raw in records) {
        NSDictionary *check = RBXAcceptanceDictionary(raw);
        if ([check[@"id"] isKindOfClass:NSString.class]) byID[check[@"id"]] = check;
    }
    NSArray *definitions = @[
        @[@"data-schema", @"Startup recovery", @[@"LIFE-030"]],
        @[@"clone-tools", @"Clone tools installed", @[@"LIFE-010"]],
        @[@"heartbeat", @"Recorded safety heartbeats", @[@"NET-036"]],
        @[@"lease", @"Recorded lease/firewall agreement", @[@"NET-036", @"LIFE-021"]],
        @[@"firewall", @"Recorded provider enforcement", @[@"NET-034"]],
        @[@"vpn-scope", @"Recorded per-app VPN scope", @[@"NET-034"]],
        @[@"clones", @"Recorded clone validation", @[@"LIFE-005", @"LIFE-021"]],
        @[@"hooks", @"Recorded hook groups and behavior checks", @[@"NET-037", @"LIFE-021"]],
        @[@"operation-recovery", @"Unfinished operation fence", @[@"LIFE-030"]],
    ];
    for (NSArray *definition in definitions) {
        NSDictionary *record = byID[definition[0]];
        NSString *status = @"NOT_RUN";
        if (reportFresh && [record[@"status"] isEqual:@"pass"]) status = @"PASS";
        else if (reportFresh && [record[@"status"] isEqual:@"fail"]) status = @"FAIL";
        [checks addObject:RBXAcceptanceRow([@"reported-" stringByAppendingString:definition[0]],
            definition[1], status, reportFresh
                ? @"Result from the last requested diagnostics (at most two minutes old). Run again after switching."
                : @"Run diagnostics now; no recent recorded inspection is available.", definition[2], @"daemon-report")];
    }
    NSArray *manual = @[
        @[@"h02", @"H02 memory budget and import survival", @[@"ACCEPT-003", @"LIFE-002"]],
        @[@"keychain-canary", @"A/B keychain access denial", @[@"OS-008", @"OS-009", @"OS-010"]],
        @[@"sandbox-denial", @"A/B foreign sandbox access denial", @[@"OS-033", @"OS-035"]],
        @[@"login-actions", @"Login, post, upvote and A/B account state", @[@"AUDIT-001"]],
        @[@"oauth-owner", @"External login callback owner", @[@"LIFE-007", @"NET-032", @"NET-033"]],
        @[@"packet-routing", @"VPN assignment and disconnect behavior", @[@"NET-034", @"NET-036"]],
        @[@"public-visibility", @"Logged-out post visibility", @[@"AUDIT-001"]],
        @[@"deletion", @"B keychain and file cleanup after delete", @[@"LIFE-026", @"LIFE-027"]],
    ];
    for (NSArray *definition in manual) [checks addObject:RBXAcceptanceRow(definition[0], definition[1],
        @"NOT_RUN", @"Separate device evidence is required; a readiness report cannot establish this result.",
        definition[2], @"operator")];
    return checks;
}
