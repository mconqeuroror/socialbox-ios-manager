#import "../lucid/Diagnostics/LBXIsolationAssessment.h"
#include <math.h>

static NSUInteger assertions;
static void Check(BOOL condition, NSString *message) {
    assertions++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static void NoRuntimeClaim(NSDictionary *result) {
    Check([result[@"overallStatus"] isEqual:@"NOT_RUN"], @"metadata cannot become an isolation pass");
    Check([result[@"runtimeProbeStatus"] isEqual:@"NOT_RUN"], @"refresh is not a runtime probe");
    Check([result[@"rows"] count] == 8, @"all required evidence families stay visible");
    for (NSDictionary *row in result[@"rows"]) Check([row[@"status"] isEqual:@"NOT_RUN"], @"every unmeasured family remains unrun");
}
int main(void) { @autoreleasepool {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1800000000];
    for (id raw in @[NSNull.null, @[], @"not an object", @YES, @{}, @{@"contexts":@"bad"}, @{@"contexts":@[NSNull.null, @3], @"activeSelectionStatus":@[]},
        @{@"overallStatus":@"PASS", @"runtimeProbeStatus":@"PASS", @"rows":@[@{@"status":@"PASS"}]}]) {
        NSDictionary *result = LBXIsolationAssessment(raw, now);
        NoRuntimeClaim(result);
        Check([result[@"selectionStatus"] isEqual:@"UNKNOWN"], @"malformed/unbound metadata not treated as selected");
    }
    NSDictionary *unavailable = LBXIsolationAssessment(@{@"status":@"UNAVAILABLE", @"contexts":@[]}, now);
    Check([unavailable[@"metadataStatus"] isEqual:@"UNAVAILABLE"], @"unavailable list is distinguished from an observed zero count");
    NSDictionary *empty = LBXIsolationAssessment(@{@"status":@"AVAILABLE", @"contexts":@[]}, now);
    Check([empty[@"metadataStatus"] isEqual:@"AVAILABLE"] && [empty[@"contextCount"] isEqual:@0], @"observed empty list is explicitly available");
    NSDictionary *metadata = @{@"status":@"AVAILABLE", @"contexts":@[@{@"id":@"42", @"name":@"PRIVATE-NAME", @"appBundleIDs":@[@"com.example.private"]}],
        @"activeContainerID":@"42", @"activeSelectionStatus":@"OBSERVED_CACHED_UI", @"secret":@"PRIVATE-TOKEN"};
    NSDictionary *result = LBXIsolationAssessment(metadata, now);
    NoRuntimeClaim(result);
    Check([result[@"selectionStatus"] isEqual:@"OBSERVED_CACHED_UI"], @"cached metadata has separate observation class");
    NSMutableDictionary *mismatch = [metadata mutableCopy]; mismatch[@"activeContainerID"] = @"other";
    Check([LBXIsolationAssessment(mismatch, now)[@"selectionStatus"] isEqual:@"UNKNOWN"], @"selection must match an enumerated context");
    mismatch[@"activeContainerID"] = @[];
    Check([LBXIsolationAssessment(mismatch, now)[@"selectionStatus"] isEqual:@"UNKNOWN"], @"selection type checked");
    mismatch = [metadata mutableCopy]; mismatch[@"status"] = @"UNAVAILABLE";
    Check([LBXIsolationAssessment(mismatch, now)[@"selectionStatus"] isEqual:@"UNKNOWN"], @"failed adapter cannot preserve an observed selection");
    for (id invalidID in @[@"0", @"-1", @"01", @"1x", @"9223372036854775808", @"other", @42, NSNull.null]) {
        mismatch = [metadata mutableCopy];
        mismatch[@"contexts"] = @[@{@"id":invalidID}]; mismatch[@"activeContainerID"] = invalidID;
        NSDictionary *invalid = LBXIsolationAssessment(mismatch, now);
        Check([invalid[@"metadataStatus"] isEqual:@"UNAVAILABLE"] && [invalid[@"selectionStatus"] isEqual:@"UNKNOWN"], @"only canonical positive signed 64-bit recovered IDs accepted");
    }
    mismatch = [metadata mutableCopy]; mismatch[@"contexts"] = @[@{@"id":@"42"}, @{@"id":@"42"}];
    Check([LBXIsolationAssessment(mismatch, now)[@"metadataStatus"] isEqual:@"UNAVAILABLE"], @"duplicate contexts invalidate metadata");
    NSMutableArray *oversized = [NSMutableArray array];
    for (NSUInteger i = 0; i < 4097; i++) [oversized addObject:@{@"id":[NSString stringWithFormat:@"%lu", (unsigned long)i+1]}];
    mismatch[@"contexts"] = oversized;
    Check([LBXIsolationAssessment(mismatch, now)[@"metadataStatus"] isEqual:@"UNAVAILABLE"], @"oversized list rejected rather than unbounded iteration or misleading truncated count");
    Check([LBXIsolationAssessment(metadata, (id)NSNull.null)[@"refreshedAt"] isEqual:@0], @"invalid refresh date does not crash");
    NSMutableDictionary *tainted = [result mutableCopy];
    tainted[@"rows"] = @[@{@"status":@"PASS", @"detail":@"PRIVATE-TOKEN"}];
    tainted[@"overallStatus"] = @"PASS"; tainted[@"name"] = @"PRIVATE-NAME";
    NSDictionary *publicReport = LBXIsolationPublicReport(tainted);
    NoRuntimeClaim(publicReport);
    NSData *data = [NSJSONSerialization dataWithJSONObject:publicReport options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    Check(![json containsString:@"PRIVATE"] && ![json containsString:@"com.example.private"], @"report whitelist excludes arbitrary identities/secrets");
    for (id raw in @[NSNull.null, @[], @1, @"bad"]) {
        NSDictionary *report = LBXIsolationPublicReport(raw);
        Check([report[@"metadataStatus"] isEqual:@"UNAVAILABLE"] && [report[@"contextCount"] isEqual:@0], @"malformed report caller cannot crash or fake a known count");
        NoRuntimeClaim(report);
    }
    Check([LBXIsolationPublicReport(unavailable)[@"metadataStatus"] isEqual:@"UNAVAILABLE"], @"report preserves unavailable metadata");
    Check([LBXIsolationPublicReport(empty)[@"metadataStatus"] isEqual:@"AVAILABLE"], @"report distinguishes truly observed empty metadata");
    for (id invalid in @[@YES, @(NAN), @(INFINITY), @(-1), @"secret", NSNull.null]) {
        tainted[@"refreshedAt"] = invalid;
        tainted[@"contextCount"] = invalid;
        NSDictionary *report = LBXIsolationPublicReport(tainted);
        Check([report[@"refreshedAt"] isEqual:@0], @"invalid report timestamp rejected");
        Check([report[@"contextCount"] isEqual:@0], @"invalid count rejected");
        Check([NSJSONSerialization isValidJSONObject:report], @"malformed input still produces serializable report");
    }
    printf("PASS: %lu recovered assessment assertions (metadata only; no device result)\n", (unsigned long)assertions);
} return 0; }
