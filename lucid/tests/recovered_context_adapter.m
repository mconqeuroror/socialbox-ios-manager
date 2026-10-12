#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import "../Diagnostics/LBXRecoveredContextAdapter.h"

static NSUInteger checks, failures, forbiddenReads, mutations, contextReads;
static void Check(BOOL condition, NSString *label) {
    checks++;
    if (!condition) { failures++; fprintf(stderr, "FAIL %s\n", label.UTF8String); }
}

// These mocks deliberately use the recovered class/selector names and encodings.
// Their image is this native test executable, supplied solely through the test seam.
@interface _Xv8i : NSObject
@property long long fixtureID;
@property (strong) id fixtureName;
@property (strong) id fixtureApps;
@property BOOL throwOnName;
@end
@implementation _Xv8i
- (long long)containerID { return self.fixtureID; }
#if defined(LBX_WRONG_ROW_SIGNATURE)
- (NSInteger)name { forbiddenReads++; return 1; }
#else
- (id)name {
    if (self.throwOnName) @throw [NSException exceptionWithName:@"private" reason:@"secret marker" userInfo:nil];
    return self.fixtureName;
}
#endif
- (id)apps { return self.fixtureApps; }
- (id)spoofProfile { forbiddenReads++; return @{@"secret": @"DO_NOT_READ"}; }
- (id)proxyUUID { forbiddenReads++; return @"DO_NOT_READ"; }
- (id)toDictionary { forbiddenReads++; return @{}; }
@end

@interface _Xc9m : NSObject
@property (strong) id fixtureRows;
@property long long fixtureActive;
@property NSUInteger activeReads;
@property BOOL changeOnSecondRead;
@end
@implementation _Xc9m
- (id)containers { contextReads++; return self.fixtureRows; }
#if defined(LBX_WRONG_CONTROLLER_SIGNATURE)
- (id)activeContainerID { forbiddenReads++; return @1; }
#else
- (long long)activeContainerID {
    self.activeReads++;
    return self.fixtureActive + ((self.changeOnSecondRead && self.activeReads > 1) ? 1 : 0);
}
#endif
- (void)loadData { mutations++; }
- (void)setActiveContainerID:(long long)value { mutations++; }
- (void)switchToContainer:(id)value { mutations++; }
@end
@interface UnexpectedSubclass : _Xc9m @end
@implementation UnexpectedSubclass @end
@interface UnexpectedRowSubclass : _Xv8i @end
@implementation UnexpectedRowSubclass @end

static NSString *ImagePath(void) { return NSBundle.mainBundle.executablePath; }
static NSDictionary *Snapshot(id controller) {
    return LBXRecoveredContextSnapshotForTesting(controller, @"com.socialbox.app", @"3.1.0", @"1", ImagePath());
}
static _Xv8i *Row(long long identifier) {
    _Xv8i *row = [_Xv8i new]; row.fixtureID = identifier;
    row.fixtureName = [NSString stringWithFormat:@"Container %lld", identifier];
    row.fixtureApps = @[@"com.reddit.Reddit", @"com.facebook.Facebook"];
    return row;
}
static void Unknown(NSDictionary *snapshot, NSString *label) {
    Check([snapshot[@"processBindingStatus"] isEqual:@"UNBOUND"], [label stringByAppendingString:@" process is unbound"]);
    Check([snapshot[@"identityStatus"] isEqual:@"UNKNOWN"], [label stringByAppendingString:@" identity unknown"]);
    Check([snapshot[@"isolationStatus"] isEqual:@"NOT_RUN"], [label stringByAppendingString:@" isolation not run"]);
    Check([snapshot[@"networkStatus"] isEqual:@"NOT_RUN"], [label stringByAppendingString:@" network not run"]);
}
static void Unavailable(NSDictionary *snapshot, NSString *reason) {
    Check([snapshot[@"status"] isEqual:@"UNAVAILABLE"], reason);
    Check([snapshot[@"reason"] isEqual:reason], [reason stringByAppendingString:@" precise reason"]);
    Check(!snapshot[@"activeContainerID"] && [snapshot[@"contexts"] count] == 0,
          [reason stringByAppendingString:@" no stale or guessed metadata"]);
}

int main(void) { @autoreleasepool {
    _Xc9m *controller = [_Xc9m new]; controller.fixtureRows = @[Row(1)]; controller.fixtureActive = 1;
#if defined(LBX_WRONG_CONTROLLER_SIGNATURE)
    Unavailable(Snapshot(controller), @"UNSUPPORTED_CONTROLLER_CONTRACT");
    Check(contextReads == 0 && forbiddenReads == 0, @"wrong scalar ABI rejected before invoking any getter");
#elif defined(LBX_WRONG_ROW_SIGNATURE)
    Unavailable(Snapshot(controller), @"UNSUPPORTED_CONTEXT_CONTRACT");
    Check(forbiddenReads == 0, @"wrong object ABI rejected before invoking row getter");
#else
    NSDictionary *value = Snapshot(controller);
    Check([value[@"status"] isEqual:@"AVAILABLE"], @"valid recovered mock contract accepted");
    Check([value[@"activeContainerID"] isEqual:@"1"], @"stable member selection projected");
    Check([value[@"activeSelectionStatus"] isEqual:@"OBSERVED_CACHED_UI"], @"selection is explicitly cached UI");
    Check([value[@"freshnessStatus"] isEqual:@"UNKNOWN"], @"snapshot time is not fake metadata freshness");
    Check([value[@"contexts"][0][@"appBundleIDs"] isEqual:@[@"com.reddit.Reddit", @"com.facebook.Facebook"]], @"app membership observed");
    Unknown(value, @"valid");
    Check([NSJSONSerialization isValidJSONObject:value], @"projection JSON compatible");
    Check(![value isKindOfClass:NSMutableDictionary.class] && ![value[@"contexts"] isKindOfClass:NSMutableArray.class], @"projection containers immutable");
    NSString *serialized = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:value options:0 error:NULL] encoding:NSUTF8StringEncoding];
    Check([serialized rangeOfString:@"DO_NOT_READ"].location == NSNotFound &&
          [serialized rangeOfString:@"spoofProfile"].location == NSNotFound &&
          [serialized rangeOfString:@"proxyUUID"].location == NSNotFound, @"no secret-bearing fields projected");
    Unavailable(LBXRecoveredContextSnapshot(controller), @"UNSUPPORTED_HOST_VERSION");
    Unavailable(Snapshot(nil), @"UNSUPPORTED_CONTROLLER_CONTRACT");
    Unavailable(Snapshot([NSObject new]), @"UNSUPPORTED_CONTROLLER_CONTRACT");
    Unavailable(Snapshot([UnexpectedSubclass new]), @"UNSUPPORTED_CONTROLLER_CONTRACT");
    for (id bad in @[@"com.facebook.Facebook", @"com.socialbox.app.untrusted", NSNull.null, @1, @[]]) {
        Unavailable(LBXRecoveredContextSnapshotForTesting(controller, bad, @"3.1.0", @"1", ImagePath()), @"UNSUPPORTED_HOST_VERSION");
    }
    for (id bad in @[@"3.1.1", @"3.1.0 ", NSNull.null, @1]) {
        Unavailable(LBXRecoveredContextSnapshotForTesting(controller, @"com.socialbox.app", bad, @"1", ImagePath()), @"UNSUPPORTED_HOST_VERSION");
    }
    for (id bad in @[@"2", @"01", NSNull.null, @1]) {
        Unavailable(LBXRecoveredContextSnapshotForTesting(controller, @"com.socialbox.app", @"3.1.0", bad, ImagePath()), @"UNSUPPORTED_HOST_VERSION");
    }
    Unavailable(LBXRecoveredContextSnapshotForTesting(controller, @"com.socialbox.app", @"3.1.0", @"1", @"/unrelated/SocialBox"), @"UNSUPPORTED_CONTROLLER_CONTRACT");
    for (id bad in @[NSNull.null, @{}, @1]) {
        controller.fixtureRows = bad; Unavailable(Snapshot(controller), @"INVALID_CONTEXT_LIST");
    }
    controller.fixtureRows = nil; Unavailable(Snapshot(controller), @"INVALID_CONTEXT_LIST");
    NSMutableArray *many = [NSMutableArray array];
    for (NSUInteger i = 0; i < 4097; i++) [many addObject:Row((long long)i+1)];
    controller.fixtureRows = many; Unavailable(Snapshot(controller), @"INVALID_CONTEXT_LIST");
    controller.fixtureRows = @[Row(1), Row(1)]; Unavailable(Snapshot(controller), @"INVALID_CONTEXT_METADATA");
    for (id bad in @[NSNull.null, @{}, [UnexpectedRowSubclass new]]) {
        controller.fixtureRows = @[bad]; Unavailable(Snapshot(controller), @"UNSUPPORTED_CONTEXT_CONTRACT");
    }
    _Xv8i *row = Row(1); controller.fixtureRows = @[row];
    row.fixtureID = 0; Unavailable(Snapshot(controller), @"INVALID_CONTEXT_METADATA");
    row.fixtureID = -1; Unavailable(Snapshot(controller), @"INVALID_CONTEXT_METADATA");
    row.fixtureID = 1;
    for (id bad in @[NSNull.null, @[], @1, @"", @"line\nbreak", [@"x" stringByPaddingToLength:513 withString:@"x" startingAtIndex:0]]) {
        row.fixtureName = bad; Unavailable(Snapshot(controller), @"INVALID_CONTEXT_METADATA");
    }
    row.fixtureName = nil; Unavailable(Snapshot(controller), @"INVALID_CONTEXT_METADATA");
    row.fixtureName = @"Valid";
    for (id bad in @[NSNull.null, @{}, @1, @"com.reddit.Reddit", @[NSNull.null], @[@1], @[@"bad/path"], @[@"nodot"], @[@".bad"], @[@"bad."], @[@"bad..app"], @[@"com.x", @"com.x"]]) {
        row.fixtureApps = bad; Unavailable(Snapshot(controller), @"INVALID_APP_MEMBERSHIP");
    }
    row.fixtureApps = nil; value = Snapshot(controller);
    Check([value[@"status"] isEqual:@"AVAILABLE"] && [value[@"contexts"][0][@"appMembershipStatus"] isEqual:@"UNAVAILABLE"], @"missing apps is unknown, not observed empty");
    row.fixtureApps = @[]; value = Snapshot(controller);
    Check([value[@"contexts"][0][@"appMembershipStatus"] isEqual:@"OBSERVED_CACHED_UI"], @"explicit empty membership distinguished");
    row.throwOnName = YES; Unavailable(Snapshot(controller), @"CONTEXT_READ_FAILED"); row.throwOnName = NO;
    controller.fixtureActive = 99; value = Snapshot(controller);
    Check([value[@"status"] isEqual:@"AVAILABLE"] && !value[@"activeContainerID"], @"missing selected row never guessed");
    controller.fixtureActive = 0; value = Snapshot(controller);
    Check(!value[@"activeContainerID"] && [value[@"activeSelectionStatus"] isEqual:@"UNAVAILABLE"], @"zero not guessed as default or active");
    controller.fixtureActive = 1; controller.changeOnSecondRead = YES; controller.activeReads = 0;
    Unavailable(Snapshot(controller), @"SELECTION_CHANGED_DURING_READ"); controller.changeOnSecondRead = NO;
    NSMutableString *mutableName = [@"Original name" mutableCopy];
    NSMutableString *mutableApp = [@"com.reddit.Reddit" mutableCopy];
    row.fixtureName = mutableName; row.fixtureApps = [NSMutableArray arrayWithObject:mutableApp];
    value = Snapshot(controller); [mutableName appendString:@" modified"]; [mutableApp appendString:@".modified"];
    Check([value[@"contexts"][0][@"name"] isEqual:@"Original name"] && [value[@"contexts"][0][@"appBundleIDs"][0] isEqual:@"com.reddit.Reddit"], @"snapshot copied mutable nested strings");
    NSMutableArray *forty = [NSMutableArray array];
    for (NSUInteger i = 1; i <= 40; i++) [forty addObject:Row((long long)i)];
    controller.fixtureRows = forty; controller.fixtureActive = 40; value = Snapshot(controller);
    Check([value[@"contexts"] count] == 40 && [value[@"activeContainerID"] isEqual:@"40"], @"forty named contexts supported without three-item ceiling");
    controller.fixtureRows = @[]; value = Snapshot(controller);
    Check([value[@"status"] isEqual:@"AVAILABLE"] && [value[@"contexts"] count] == 0 && !value[@"activeContainerID"], @"empty list retains unknown selection");
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *background;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ background = Snapshot(controller); dispatch_semaphore_signal(done); });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    Unavailable(background, @"MAIN_THREAD_REQUIRED");
    Method method = class_getInstanceMethod(_Xc9m.class, @selector(containers));
    IMP prior = method_getImplementation(method);
    IMP external = imp_implementationWithBlock(^id(id object) { forbiddenReads++; return @[]; });
    method_setImplementation(method, external);
    Unavailable(Snapshot(controller), @"UNSUPPORTED_CONTROLLER_CONTRACT");
    method_setImplementation(method, prior); imp_removeBlock(external);
    Check(forbiddenReads == 0, @"identity/proxy/toDictionary/unverified image getters never invoked");
    Check(mutations == 0, @"no initialization refresh switch or mutation invoked");
#endif
    printf("{\"checks\":%lu,\"failures\":%lu}\n", (unsigned long)checks, (unsigned long)failures);
    return failures ? 1 : 0;
} }
