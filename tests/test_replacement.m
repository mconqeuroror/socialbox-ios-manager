// Execute the actual transition engine with injected device/service failures.
#define RBX_REPLACEMENT_TESTING 1
#import "../daemon/RBXReplacement.m"
#import "RBXAppLifecycle.h"
static NSString *FixtureApp = @"reddit";

static void Check(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"ReplacementTestFailure" reason:message userInfo:nil];
}

@interface FakeReplacement : NSObject <RBXReplacementBackend>
@property(nonatomic, strong) NSDictionary *journal;
@property(nonatomic, strong) NSDictionary *inventory;
@property(nonatomic, strong) NSMutableArray *events;
@property(nonatomic, copy) NSString *fail;
@property(nonatomic) BOOL oldPresent;
@property(nonatomic) BOOL candidatePresent;
@property(nonatomic) BOOL candidateRotated;
@property(nonatomic) BOOL targetActive;
@property(nonatomic) BOOL commitThenFail;
@property(nonatomic) NSUInteger creates;
@end
@implementation FakeReplacement
- (instancetype)init {
    if ((self = [super init])) { _events = [NSMutableArray array]; _oldPresent = YES; }
    return self;
}
- (BOOL)event:(NSString *)event error:(NSError **)error {
    [self.events addObject:event];
    if ([self.fail isEqual:event]) {
        if (error) *error = RBXReplacementError([@"Injected " stringByAppendingString:event]); return NO;
    }
    return YES;
}
- (BOOL)replacementAllowedForContainer:(NSString *)container error:(NSError **)error {
    NSDictionary *journals = self.inventory ?: (self.journal ? @{@"old-id": self.journal} : @{});
    return RBXReplacementMutationAllowed(journals, container, RBXReplacementStartOrResume, error);
}
- (NSDictionary *)journalForContainer:(NSString *)container error:(NSError **)error {
    return [self event:@"read" error:error] ? self.journal : nil;
}
- (NSDictionary *)prepareJournalForContainer:(NSString *)container error:(NSError **)error {
    if (![self event:@"prepare" error:error] || self.targetActive) {
        if (error && !*error) *error = RBXReplacementError(@"Target active"); return nil;
    }
    NSMutableDictionary *journal=[RBXAppReplacementJournalIdentity(RBXAppDescriptorForType(FixtureApp),container,@"fresh-id") mutableCopy];
    [journal addEntriesFromDictionary:@{@"phase":@"prepared",@"name":@"Same name",@"role":@"warmup",@"country":@"US",@"previousExitIP":@"192.0.2.1"}];return journal;
}
- (BOOL)persistJournal:(NSDictionary *)journal error:(NSError **)error {
    NSString *event = [@"persist:" stringByAppendingString:journal[@"phase"]];
    if ([self.fail isEqual:event] && self.commitThenFail) self.journal = [journal copy];
    if (![self event:event error:error]) return NO;
    self.journal = [journal copy]; return YES;
}
- (BOOL)establishClosureForJournal:(NSDictionary *)journal error:(NSError **)error {
    if (self.targetActive) { if (error) *error = RBXReplacementError(@"Target active on retry"); return NO; }
    return [self event:@"closed" error:error];
}
- (BOOL)createCandidateForJournal:(NSDictionary *)journal error:(NSError **)error {
    Check([journal[@"newId"] isEqual:@"fresh-id"], @"Retry changed candidate identity");
    Check(self.oldPresent, @"Original disappeared before creation");
    if (!self.candidatePresent) self.creates++;
    self.candidatePresent = YES; // installer side effect before a possible failure
    return [self event:@"create" error:error];
}
- (NSString *)rotateCandidateForJournal:(NSDictionary *)journal error:(NSError **)error {
    Check(self.oldPresent, @"Original disappeared before rotation");
    Check(self.candidatePresent, @"Rotation preceded candidate creation");
    if (![self event:@"rotate" error:error]) return nil;
    self.candidateRotated = YES; return @"192.0.2.2";
}
- (BOOL)validateCandidateForJournal:(NSDictionary *)journal error:(NSError **)error {
    if (![self event:@"validate" error:error]) return NO;
    if (!self.candidatePresent || !self.candidateRotated) {
        if (error) *error = RBXReplacementError(@"Candidate missing or not rotated"); return NO;
    }
    return YES;
}
- (BOOL)deleteOriginalForJournal:(NSDictionary *)journal error:(NSError **)error {
    Check([self.journal[@"phase"] isEqual:@"deleting"], @"Deletion preceded durable deleting phase");
    Check(self.candidatePresent && self.candidateRotated, @"Deletion preceded a valid rotated candidate");
    if (![self event:@"delete" error:error]) return NO;
    self.oldPresent = NO; return YES;
}
@end

static NSString *Run(FakeReplacement *backend) {
    NSError *error = nil;
    NSString *result = RBXRunReplacement(@"old-id", backend, &error);
    Check(result || error, @"Failure omitted its diagnostic");
    return result;
}

static NSDictionary *Journal(NSString *original, NSString *candidate, NSString *phase) {
    return @{@"formatVersion":@1, @"oldId":original, @"newId":candidate, @"phase":phase,
        @"name":@"Keep name", @"role":@"warmup", @"country":@"US", @"previousExitIP":@"192.0.2.1"};
}

static NSUInteger OwnershipCases(void) {
    NSUInteger cases = 0;
    for (NSString *phase in @[@"prepared", @"created", @"rotated", @"deleting", @"committed"]) {
        NSDictionary *journal = Journal(@"old-id", @"fresh-id", phase), *inventory = @{@"old-id":journal};
        BOOL committed = [phase isEqual:@"committed"];
        for (NSString *target in @[@"old-id", @"fresh-id"]) {
            NSError *error = nil;
            BOOL allowed = RBXReplacementMutationAllowed(inventory, target, RBXReplacementUserDelete, &error);
            Check(allowed == committed && (allowed || error), @"User deletion did not respect both transaction participants"); cases++;
        }
        NSError *error = nil;
        Check(RBXReplacementMutationAllowed(inventory, @"old-id", RBXReplacementStartOrResume, &error),
            @"Exact original must remain resumable"); cases++;
        Check(RBXReplacementMutationAllowed(inventory, @"fresh-id", RBXReplacementStartOrResume, &error) == committed,
            @"Pending candidate must not become a second original"); cases++;
        Check(RBXReplacementMutationAllowed(inventory, @"unrelated-id", RBXReplacementUserDelete, &error) &&
            RBXReplacementMutationAllowed(inventory, @"unrelated-id", RBXReplacementStartOrResume, &error),
            @"Valid pending replacement must not prevent unrelated user operations"); cases++;
        if (!committed) {
            FakeReplacement *nested = [FakeReplacement new]; nested.inventory = inventory;
            Check(!RBXRunReplacement(@"fresh-id", nested, &error) && error && nested.oldPresent &&
                !nested.candidatePresent && !nested.journal && !nested.events.count,
                @"Nested replacement mutated profiles or journal before rejecting candidate"); cases++;
        }
    }
    for (id invalid in @[@[], @{@"old-id":@{}},
        @{@"old-id":Journal(@"other-id",@"fresh-id",@"prepared")},
        @{@"old-id":Journal(@"old-id",@"fresh-id",@"unknown")},
        @{@"old-id":Journal(@"old-id",@"fresh-id",@"prepared"), @"another-id":Journal(@"another-id",@"fresh-id",@"committed")},
        @{@"old-id":Journal(@"old-id",@"fresh-id",@"created"), @"fresh-id":Journal(@"fresh-id",@"third-id",@"created")}]) {
        for (NSNumber *operation in @[@(RBXReplacementUserDelete), @(RBXReplacementStartOrResume)]) {
            NSError *error = nil;
            Check(!RBXReplacementMutationAllowed(invalid, @"unrelated-id", operation.integerValue, &error) && error,
                @"Malformed or overlapping inventory permitted an unrelated mutation"); cases++;
        }
    }
    NSDictionary *chain = @{@"old-id":Journal(@"old-id",@"fresh-id",@"committed"),
        @"fresh-id":Journal(@"fresh-id",@"third-id",@"created")};
    NSError *error = nil;
    Check(!RBXReplacementMutationAllowed(chain, @"fresh-id", RBXReplacementUserDelete, &error) &&
        RBXReplacementMutationAllowed(chain, @"fresh-id", RBXReplacementStartOrResume, &error) &&
        !RBXReplacementMutationAllowed(chain, @"third-id", RBXReplacementStartOrResume, &error),
        @"Committed predecessor masked ownership in the current pending replacement"); cases++;
    NSMutableDictionary *booleanVersion = [Journal(@"old-id",@"fresh-id",@"prepared") mutableCopy];
    booleanVersion[@"formatVersion"] = @YES; error = nil;
    Check(!RBXReplacementMutationAllowed(@{@"old-id":booleanVersion}, @"old-id", RBXReplacementUserDelete, &error) && error,
        @"Boolean journal version was treated as an integer schema version"); cases++;
    return cases;
}

static NSUInteger AppIdentityCases(void) {
    NSUInteger cases=0;
    for(NSDictionary *descriptor in RBXRegisteredAppDescriptors()) {
        NSDictionary *identity=RBXAppReplacementJournalIdentity(descriptor,@"old-id",@"fresh-id");
        Check([RBXAppReplacementJournalDescriptor(identity) isEqual:descriptor],@"replacement tuple independently derives app owner");cases++;
        Check(!RBXAppReplacementJournalIdentity(descriptor,@"old-id",@"old-id"),@"replacement needs distinct clone identities");cases++;
        if([descriptor[@"appType"] isEqual:@"reddit"]) {
            Check([identity isEqual:@{@"formatVersion":@1,@"oldId":@"old-id",@"newId":@"fresh-id"}],@"Reddit journal identity field shape stays identical");cases++;
        } else {
            Check(![[NSSet setWithArray:identity[@"oldTarget"][@"keychainAccessGroups"]] intersectsSet:[NSSet setWithArray:identity[@"newTarget"][@"keychainAccessGroups"]]],@"old and candidate group sets are disjoint");cases++;
            for(NSString *key in @[@"appType",@"sourceBundleIdentifier",@"oldTarget",@"newTarget"]) {
                NSMutableDictionary *bad=identity.mutableCopy;[bad removeObjectForKey:key];Check(!RBXAppReplacementJournalDescriptor(bad),@"partial Facebook tuple denied");cases++;
            }
            for(NSString *target in @[@"oldTarget",@"newTarget"]) for(NSString *key in @[@"bundleIdentifier",@"containerId",@"keychainAccessGroup",@"keychainAccessGroups",@"keychainPolicyVersion"]) {
                NSMutableDictionary *bad=identity.mutableCopy,*partial=[identity[target] mutableCopy];[partial removeObjectForKey:key];bad[target]=partial;
                Check(!RBXAppReplacementJournalDescriptor(bad),@"both complete group-bound targets are mandatory");cases++;
            }
        }
        for(id app in @[@"unknown",NSNull.null,@123]) {
            NSMutableDictionary *bad=identity.mutableCopy;bad[@"appType"]=app;Check(!RBXAppReplacementJournalDescriptor(bad),@"unknown replacement app never defaults to Reddit");cases++;
        }
    }
    return cases;
}

int main(void) { @autoreleasepool {
    NSUInteger ownershipCases = OwnershipCases();
    NSLog(@"PASS %lu per-app replacement identity cases",(unsigned long)AppIdentityCases());
    for (NSString *app in @[@"reddit",@"facebook"]) { FixtureApp=app;
    FakeReplacement *happy = [FakeReplacement new];
    Check([Run(happy) isEqual:@"fresh-id"] && !happy.oldPresent, @"Happy replacement failed");
    NSArray *expected = @[@"read", @"prepare", @"persist:prepared", @"closed", @"create", @"persist:created",
        @"rotate", @"persist:rotated", @"validate", @"persist:deleting", @"delete", @"persist:committed"];
    Check([happy.events isEqual:expected], @"Replacement ordering changed");
    Check([happy.journal[@"name"] isEqual:@"Same name"] && [happy.journal[@"role"] isEqual:@"warmup"], @"Metadata inheritance changed");

    NSUInteger cases = 1;
    for (NSString *point in @[@"read", @"prepare", @"persist:prepared", @"closed", @"create",
        @"persist:created", @"rotate", @"persist:rotated", @"validate", @"persist:deleting", @"delete", @"persist:committed"]) {
        FakeReplacement *backend = [FakeReplacement new]; backend.fail = point;
        Check(!Run(backend), [@"Failure unexpectedly succeeded: " stringByAppendingString:point]);
        if (![point isEqual:@"persist:committed"]) Check(backend.oldPresent, @"Failure destroyed original too early");
        if ([@[@"read", @"prepare", @"persist:prepared"] containsObject:point])
            Check(!backend.candidatePresent, @"Candidate created without durable prepared journal");
        backend.fail = nil;
        Check([Run(backend) isEqual:@"fresh-id"], [@"Retry failed: " stringByAppendingString:point]);
        Check(backend.creates == 1, @"Retry generated a second candidate"); cases++;
    }
    for (NSString *phase in @[@"prepared", @"created", @"rotated", @"deleting", @"committed"]) {
        FakeReplacement *backend = [FakeReplacement new];
        backend.fail = [@"persist:" stringByAppendingString:phase]; backend.commitThenFail = YES;
        Check(!Run(backend), @"Uncertain persistence unexpectedly succeeded");
        backend.fail = nil;
        Check([Run(backend) isEqual:@"fresh-id"] && backend.creates == 1, @"Uncertain phase replay was unsafe"); cases++;
    }
    FakeReplacement *active = [FakeReplacement new]; active.targetActive = YES;
    Check(!Run(active) && active.oldPresent && !active.candidatePresent && !active.journal, @"Active target mutated"); cases++;
    FakeReplacement *retryActive = [FakeReplacement new]; retryActive.fail = @"rotate";
    Check(!Run(retryActive), @"Injected rotation failure was ignored");
    retryActive.fail = nil; retryActive.targetActive = YES;
    Check(!Run(retryActive) && retryActive.oldPresent, @"Active retry deleted original"); cases++;
    FakeReplacement *corrupt = [FakeReplacement new]; corrupt.journal = @{@"oldId": @"old-id", @"phase": @"rotated"};
    Check(!Run(corrupt) && corrupt.oldPresent && !corrupt.candidatePresent, @"Corrupt journal authorized effects"); cases++;
    NSLog(@"PASS %@: %lu replacement transition cases and %lu transaction ownership cases", app, (unsigned long)cases, (unsigned long)ownershipCases);
    }
} return 0; }
