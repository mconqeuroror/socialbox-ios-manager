#import "LBXIsolationAssessment.h"
#include <math.h>

static NSDictionary *LBXCheck(NSString *identifier, NSString *title, NSString *detail) {
    return @{@"id":identifier, @"title":title, @"status":@"NOT_RUN", @"detail":detail};
}

static BOOL LBXCanonicalContextID(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] == 0 || [value length] > 19) return NO;
    long long identifier = [value longLongValue];
    return identifier > 0 && [value isEqualToString:[NSString stringWithFormat:@"%lld", identifier]];
}

NSDictionary *LBXIsolationAssessment(id raw, NSDate *refreshedAt) {
    NSDictionary *snapshot = [raw isKindOfClass:NSDictionary.class] ? raw : @{};
    // The adapter is the only metadata authority. Even an OBSERVED selection
    // cannot become a PASS for data visibility, process teardown or networking.
    NSArray *rawContexts = [snapshot[@"contexts"] isKindOfClass:NSArray.class] ? snapshot[@"contexts"] : nil;
    BOOL metadataAvailable = [snapshot[@"status"] isEqual:@"AVAILABLE"] && rawContexts && rawContexts.count <= 4096;
    NSString *selection = [snapshot[@"activeSelectionStatus"] isKindOfClass:NSString.class] ? snapshot[@"activeSelectionStatus"] : @"UNKNOWN";
    NSString *activeID = LBXCanonicalContextID(snapshot[@"activeContainerID"]) ? snapshot[@"activeContainerID"] : nil;
    BOOL matched = NO;
    NSMutableSet *seen = [NSMutableSet set];
    if (metadataAvailable) for (id context in rawContexts) {
        if (![context isKindOfClass:NSDictionary.class] || !LBXCanonicalContextID(context[@"id"]) || [seen containsObject:context[@"id"]]) {
            metadataAvailable = NO;
            break;
        }
        [seen addObject:context[@"id"]];
        if (activeID && [context[@"id"] isEqual:activeID]) matched = YES;
    }
    NSUInteger count = metadataAvailable ? rawContexts.count : 0;
    BOOL observed = metadataAvailable && [selection isEqual:@"OBSERVED_CACHED_UI"] && matched;
    NSTimeInterval at = [refreshedAt isKindOfClass:NSDate.class] ? refreshedAt.timeIntervalSince1970 : 0;
    if (!isfinite(at) || at <= 0) at = 0;
    NSArray *rows = @[
        LBXCheck(@"keychain", @"Keychain boundaries", @"Needs an A/B/A canary read inside the target app. A launcher read cannot establish which account data the app can access."),
        LBXCheck(@"files", @"Files and shared groups", @"Needs witnessed sibling paths and reads inside the target app after a completed switch. Separate names in this list do not prove access denial."),
        LBXCheck(@"defaults", @"Preferences and SDK storage", @"Needs known canary values across two contexts, including shared suites and a return to the first context."),
        LBXCheck(@"pasteboard", @"Clipboard", @"An empty clipboard is inconclusive without a witnessed marker. No user clipboard data is read or overwritten by this screen."),
        LBXCheck(@"web-storage", @"Cookies and WebKit", @"Needs an in-app A/B/A check of persistent stores and the external authentication flow."),
        LBXCheck(@"network", @"Proxy and direct traffic", @"Needs device packet captures covering IPv4, IPv6, DNS, UDP, proxy failure and network changes. A connected tunnel icon is not proof of containment."),
        LBXCheck(@"switch", @"Switch and interruption recovery", @"Needs process-exit and storage-continuity evidence for rapid switching, interruption and restart."),
        LBXCheck(@"identity", @"Identity consistency", @"Needs observations from the running app. Values displayed by the launcher alone do not prove that every API returns them.")
    ];
    return @{@"schemaVersion":@1, @"implementation":@"recovered-base", @"refreshedAt":@(at),
        @"runtimeProbeStatus":@"NOT_RUN", @"overallStatus":@"NOT_RUN",
        @"metadataStatus":metadataAvailable ? @"AVAILABLE" : @"UNAVAILABLE",
        @"selectionStatus":observed ? @"OBSERVED_CACHED_UI" : @"UNKNOWN", @"contextCount":@(count),
        @"rows":rows};
}

NSDictionary *LBXIsolationPublicReport(NSDictionary *assessment) {
    // Reconstruct from fixed definitions instead of reflecting arbitrary input.
    // This first adapter does not accept unbound receipts from the clone-based
    // daemon: those belong to a different architecture and could mislead users.
    NSDictionary *canonical = LBXIsolationAssessment(nil, [NSDate dateWithTimeIntervalSince1970:0]);
    NSMutableDictionary *report = [canonical mutableCopy];
    NSDictionary *source = [assessment isKindOfClass:NSDictionary.class] ? assessment : @{};
    id time = source[@"refreshedAt"];
    if ([time isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)time) != CFBooleanGetTypeID() && isfinite([time doubleValue]) && [time doubleValue] > 0)
        report[@"refreshedAt"] = time;
    id count = source[@"contextCount"];
    BOOL metadataAvailable = [source[@"metadataStatus"] isEqual:@"AVAILABLE"] &&
        [count isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)count) != CFBooleanGetTypeID() &&
        [count doubleValue] >= 0 && [count doubleValue] <= 4096 && floor([count doubleValue]) == [count doubleValue];
    if (metadataAvailable) {
        report[@"contextCount"] = count;
        report[@"metadataStatus"] = @"AVAILABLE";
    }
    report[@"selectionStatus"] = metadataAvailable && [source[@"selectionStatus"] isEqual:@"OBSERVED_CACHED_UI"] ? @"OBSERVED_CACHED_UI" : @"UNKNOWN";
    report[@"scope"] = @"Management metadata only. No runtime isolation result has been collected by this adapter.";
    return report;
}
