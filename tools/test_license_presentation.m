#import <Foundation/Foundation.h>
#import "RBXLicensePresentation.h"

static NSDictionary *Snapshot(NSDictionary *overrides, id published) {
    NSMutableDictionary *license = [@{@"unlocked": @YES, @"offlineGrace": @NO,
        @"expiresAt": @2000, @"status": @"active", @"reason": @"A signed entitlement is valid.",
        @"paired": @YES, @"serverURL": @"https://licenses.example", @"retryAt": @1200} mutableCopy];
    [license addEntriesFromDictionary:overrides];
    return @{@"license": license, @"updatedAt": published};
}

int main(void) { @autoreleasepool {
    const NSTimeInterval now = 1000;
    NSCAssert(![RBXLicensePresentationState(nil, now)[@"unlocked"] boolValue], @"No cached state is locked");
    NSCAssert(![RBXLicensePresentationState(@{}, now)[@"unlocked"] boolValue], @"First run is locked");
    NSCAssert(![RBXLicensePresentationState((id)@[], now)[@"unlocked"] boolValue], @"Malformed root is locked");
    NSCAssert(![RBXLicensePresentationState(@{@"license": @[], @"updatedAt": @1000}, now)[@"unlocked"] boolValue], @"Malformed license is locked");

    NSDictionary *online = Snapshot(@{}, @1000);
    NSCAssert([RBXLicensePresentationState(online, now)[@"unlocked"] boolValue], @"Valid online grant");
    NSDictionary *grace = RBXLicensePresentationState(Snapshot(@{@"offlineGrace": @YES}, @1000), now);
    NSCAssert([grace[@"unlocked"] boolValue] && [grace[@"offlineGrace"] boolValue], @"Valid signed grace");
    NSCAssert([RBXLicensePresentationState(Snapshot(@{}, @990), now)[@"unlocked"] boolValue], @"Ten seconds old is allowed");
    NSCAssert(![RBXLicensePresentationState(Snapshot(@{}, @989.999), now)[@"unlocked"] boolValue], @"Older snapshot expires");
    NSCAssert([RBXLicensePresentationState(Snapshot(@{}, @1002), now)[@"unlocked"] boolValue], @"Two seconds future tolerance");
    NSCAssert(![RBXLicensePresentationState(Snapshot(@{}, @1002.001), now)[@"unlocked"] boolValue], @"Clock rollback cannot prolong the snapshot");
    NSCAssert(![RBXLicensePresentationState(Snapshot(@{@"expiresAt": @1000}, @1000), now)[@"unlocked"] boolValue], @"Exact signed expiry is closed");
    NSCAssert([RBXLicensePresentationState(Snapshot(@{@"expiresAt": @1000.001}, @1000), now)[@"unlocked"] boolValue], @"Before signed expiry remains valid");
    NSCAssert(![RBXLicensePresentationState(Snapshot(@{@"offlineGrace": @YES, @"expiresAt": @999}, @1000), now)[@"unlocked"] boolValue], @"Expired grace is closed");

    for (id malformed in @[@"1000", NSNull.null, @YES, @(NAN), @(INFINITY), @(-1)]) {
        NSCAssert(![RBXLicensePresentationState(Snapshot(@{}, malformed), now)[@"unlocked"] boolValue], @"Invalid publication timestamp is locked");
        NSCAssert(![RBXLicensePresentationState(Snapshot(@{@"expiresAt": malformed}, @1000), now)[@"unlocked"] boolValue], @"Invalid expiry is locked");
    }
    for (id malformed in @[@"yes", NSNull.null, @[], @2, @(NAN)])
        NSCAssert(![RBXLicensePresentationState(Snapshot(@{@"unlocked": malformed}, @1000), now)[@"unlocked"] boolValue], @"Malformed grant cannot unlock");
    NSMutableDictionary *missingExpiry = [online[@"license"] mutableCopy];
    [missingExpiry removeObjectForKey:@"expiresAt"];
    NSCAssert(![RBXLicensePresentationState(@{@"license": missingExpiry, @"updatedAt": @1000}, now)[@"unlocked"] boolValue], @"Missing signed expiry is locked");
    [missingExpiry removeObjectForKey:@"unlocked"];
    NSCAssert([RBXLicensePresentationState(@{@"license": missingExpiry, @"updatedAt": @1000}, now)[@"status"] isEqual:@"invalid-status"], @"Missing grant flag cannot retain an active status");
    for (NSNumber *badNow in @[@(NAN), @(INFINITY), @(-1)])
        NSCAssert(![RBXLicensePresentationState(online, badNow.doubleValue)[@"unlocked"] boolValue], @"Invalid clock remains locked");
    NSDictionary *revoked = RBXLicensePresentationState(Snapshot(@{@"unlocked": @NO, @"status": @"revoked", @"reason": @"License revoked"}, @1000), now);
    NSCAssert([revoked[@"reason"] isEqual:@"License revoked"] && ![revoked[@"unlocked"] boolValue], @"Published denial remains visible");

    NSMutableDictionary *originalLicense = [Snapshot(@{@"deviceToken": @"must-not-copy", @"key": @"must-not-copy"}, @1000)[@"license"] mutableCopy];
    NSMutableDictionary *original = [@{@"license": originalLicense, @"updatedAt": @1000} mutableCopy];
    NSData *before = [NSPropertyListSerialization dataWithPropertyList:original format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSDictionary *stale = RBXLicensePresentationState(original, 1011);
    NSData *after = [NSPropertyListSerialization dataWithPropertyList:original format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSCAssert([before isEqual:after], @"Presentation never mutates persisted state");
    NSCAssert(!stale[@"deviceToken"] && !stale[@"key"], @"Only safe presentation fields are returned");
    NSCAssert([stale[@"paired"] boolValue] && [stale[@"serverURL"] isEqual:@"https://licenses.example"] && [stale[@"retryAt"] isEqual:@1200], @"Offline screen retains safe setup/retry fields");
    NSDictionary *sanitized = RBXLicensePresentationState(Snapshot(@{@"paired": @"yes", @"serverURL": @42, @"retryAt": @"1200"}, @989), now);
    NSCAssert(![sanitized[@"paired"] boolValue] && !sanitized[@"serverURL"] && [sanitized[@"retryAt"] isEqual:@0], @"Invalid safe field types are removed");
    puts("license presentation Foundation tests passed");
} return 0; }
