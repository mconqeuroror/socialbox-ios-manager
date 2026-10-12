#import <Foundation/Foundation.h>
#define RBX_CATALOG_TESTING 1
#import "RBXDeviceCatalog.m"
#import "RBXProxyRegion.h"

static void Check(BOOL ok, NSString *message) { if (!ok) { NSLog(@"FAIL: %@", message); exit(1); } }
int main(int argc, const char **argv) { @autoreleasepool {
    RBXCatalogTestPaths = @[[NSString stringWithUTF8String:argv[1]]];
    NSDictionary *input = @{@"ip":@"203.0.113.10", @"country":@"US", @"city":@"Los Angeles",
        @"timezone":@"America/Los_Angeles", @"org":@"AS64500 Example Hosting"};
    NSError *error = nil;
    NSDictionary *region = RBXProxyRegionSuggestion(input, &error);
    Check(region && !error, @"valid response accepted");
    Check([region[@"timezone"] isEqual:@"America/Los_Angeles"] && [region[@"city"] isEqual:@"Los Angeles"], @"western city does not inherit New York timezone");
    Check([region[@"carrierSource"] isEqual:@"catalog-suggestion"] && [region[@"networkName"] isEqual:input[@"org"]], @"network owner is never called a detected SIM carrier");
    Check(!region[@"ip"] && !region[@"loc"] && !region[@"proxyURL"], @"result excludes exit address, coordinates and credentials");
    NSMutableDictionary *changed = [input mutableCopy]; changed[@"city"] = @"Unknown suburb";
    region = RBXProxyRegionSuggestion(changed, &error);
    Check([region[@"city"] isEqual:@"Los Angeles"] && [region[@"citySource"] isEqual:@"catalog-suggestion"] && [region[@"observedCity"] isEqual:@"Unknown suburb"], @"unsupported city is explicitly a catalog suggestion in observed timezone");
    for (NSDictionary *change in @[@{@"ip":@"invalid"}, @{@"country":@"ZZ"}, @{@"country":@42}, @{@"timezone":@"Europe/London"}, @{@"city":@[]}, @{@"org":@"bad\nvalue"}]) {
        changed = [input mutableCopy]; [changed addEntriesFromDictionary:change]; error = nil;
        Check(!RBXProxyRegionSuggestion(changed, &error) && error, @"malformed or unsupported response must fail, not default to US");
    }
    region = RBXProxyRegionSuggestion(@{@"ip":@"2001:db8::1",@"country":@"GB"}, &error);
    Check(region && [region[@"timezoneSource"] isEqual:@"catalog-suggestion"] && [region[@"citySource"] isEqual:@"catalog-suggestion"], @"country-only response labels every inferred field");
    Check(!RBXProxyRegionSuggestion(@[], &error), @"non-dictionary rejected");
    puts("PASS: native proxy region parsing, geography, provenance and malformed-response tests");
} }
