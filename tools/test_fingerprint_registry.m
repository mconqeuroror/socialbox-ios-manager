// Run the real fingerprint computation/refresh with in-memory dependencies.
// File parsing and catalog validation have separate actual-loader fixtures.
#import <Foundation/Foundation.h>
#import "../daemon/RBXCentralStore.h"
#import "../daemon/RBXContainerRegistry.h"
#import "../daemon/RBXProfileIO.h"
#include "../daemon/RBXFingerprintRegistry.m"

static NSMutableDictionary *Document;
static NSDictionary *Profiles;
static NSSet *Retired;
static NSUInteger Failures;
static BOOL InsideStoreUpdate;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RBXCentralStore
+ (instancetype)sharedStore { static id value; if (!value) value = [self new]; return value; }
- (NSMutableDictionary *)dictionary {
    if (InsideStoreUpdate) { NSLog(@"FAIL: recursive store read would trap on the production serial queue"); Failures++; }
    return Document;
}
- (void)update:(void (^)(NSMutableDictionary *))block {
    InsideStoreUpdate = YES; @try { block(Document); } @finally { InsideStoreUpdate = NO; }
}
@end
@implementation RBXContainerRegistry
- (NSDictionary *)deletionStateForContainer:(NSString *)containerId {
    // Match the production deletion lookup's central-store read.
    (void)[[RBXCentralStore sharedStore] dictionary];
    return [Retired containsObject:containerId] ? @{@"phase": @"prepared"} : nil;
}
@end
@implementation RBXProfileIO
+ (BOOL)isSafeContainerIdentifier:(id)value {
    return [value isKindOfClass:NSString.class] && [value length] &&
        [value rangeOfString:@"/"].location == NSNotFound;
}
+ (NSDictionary *)loadProfileForContainer:(NSString *)containerId error:(NSError **)error {
    NSDictionary *profile = Profiles[containerId];
    if (!profile && error) *error = [NSError errorWithDomain:@"fixture" code:2
        userInfo:@{NSLocalizedDescriptionKey: @"Fixture profile missing."}];
    return profile;
}
@end
#pragma clang diagnostic pop

static void Check(BOOL condition, NSString *name) {
    if (!condition) { NSLog(@"FAIL: %@", name); Failures++; }
}
static NSMutableDictionary *Container(id fingerprint) {
    return [@{@"fingerprint": fingerprint, @"paused": @NO} mutableCopy];
}
int main(void) {
    @autoreleasepool {
        NSDictionary *valid = @{@"device": @{
            @"productType": @"iPhone14,7", @"screen": @{@"w": @"1170", @"h": @"2532", @"scale": @"3", @"fps": @"60"},
            @"locale": @"en_US", @"timezone": @"America/New_York"}};
        Check([RBXFingerprintRegistry bundleHashForProfile:nil observedUA:nil] == nil, @"nil profile rejected");
        Check([RBXFingerprintRegistry bundleHashForProfile:(id)@[] observedUA:nil] == nil, @"array profile rejected");
        Check([RBXFingerprintRegistry bundleHashForProfile:@{@"device": NSNull.null} observedUA:nil] == nil, @"null device rejected");
        Check([RBXFingerprintRegistry bundleHashForProfile:valid observedUA:(id)@1] == nil, @"non-string UA rejected");
        Check([RBXFingerprintRegistry bundleHashForProfile:@{@"device": @{@"productType": @1}} observedUA:nil] == nil, @"malformed fields rejected");
        NSMutableDictionary *reverse = [valid[@"device"] mutableCopy];
        reverse[@"screen"] = @{@"unexpected": @"x"};
        Check([RBXFingerprintRegistry bundleHashForProfile:@{@"device": reverse} observedUA:nil] == nil,
            @"missing screen fields rejected");
        reverse[@"screen"] = @{@"scale": @"3", @"h": @"2532", @"w": @"1170", @"fps": @"60"};
        NSString *hash = [RBXFingerprintRegistry bundleHashForProfile:valid observedUA:@"Fixture-UA"];
        Check(hash.length == 16 && [hash isEqualToString:[RBXFingerprintRegistry
            bundleHashForProfile:@{@"device": reverse} observedUA:@"Fixture-UA"]], @"valid hash order is stable");
        Profiles = @{@"good-a": valid, @"good-b": valid, @"retired": valid,
            @"bad-root": (id)@[], @"bad-ua": valid};
        Retired = [NSSet setWithObject:@"retired"];
        Document = [@{@"containers": [@{
            @"good-a": Container(@{@"userAgent": @"Fixture-UA"}),
            @"good-b": Container(@{@"userAgent": @"Fixture-UA"}),
            @"missing-a": Container(@{@"bundleHash": @"stale"}),
            @"missing-b": Container(NSNull.null),
            @"bad-root": Container(@{}),
            @"bad-ua": Container(@{@"userAgent": @3}),
            @"retired": Container(@{@"bundleHash": @"stale"}),
        } mutableCopy], @"alerts": [@[NSNull.null, @{@"type": @2, @"key": @[]}] mutableCopy]} mutableCopy];
        [[RBXFingerprintRegistry new] refreshAndCheck];
        NSDictionary *containers = Document[@"containers"];
        for (NSString *containerId in @[@"missing-a", @"missing-b", @"bad-root", @"bad-ua", @"retired"]) {
            NSDictionary *fingerprint = containers[containerId][@"fingerprint"];
            Check(!fingerprint[@"bundleHash"] && [fingerprint[@"validationError"] length],
                [@"unavailable fingerprint cleared: " stringByAppendingString:containerId]);
        }
        NSUInteger duplicates = 0;
        for (id alert in Document[@"alerts"]) {
            if ([alert isKindOfClass:NSDictionary.class] && [alert[@"type"] isEqual:@"FINGERPRINT DUP"]) {
                duplicates++;
                Check([alert[@"key"] isEqual:@"good-a+good-b"], @"only valid profiles collide");
            }
        }
        Check(duplicates == 1, @"one valid collision alert");
        [[RBXFingerprintRegistry new] refreshAndCheck];
        Check([Document[@"alerts"] count] == 3, @"repeat refresh does not duplicate the alert");
        NSLog(@"Fingerprint registry fixtures: %@", Failures ? @"FAILED" : @"PASS");
        return Failures ? 1 : 0;
    }
}
