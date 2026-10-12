#import "../Containers/LBXContainerRootPendingStore.h"
#import "../Containers/LBXContainerRootMutationOwner.h"
#import "../Containers/LBXContainerConfigurationStore.h"
#import "../Containers/LBXContainerConfiguration.h"
#import "../Containers/LBXContainerMutationIPC.h"
#import "../Authorization/LBXLicenseOwner.h"
#import "../Authorization/LBXLicenseVault.h"
#import "../Authorization/LBXLicenseIPC.h"
#import "../../tests/RBXLicenseTestSupport.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <mach/mach_time.h>

// Signed synthetic host admission and actual temporary files only. The test
// assembly opens a pristine, unprepared host namespace through existing test
// seams; this is not installation authority, platform trust or device evidence.
// No fixture dictionary or private setup value is printed.
static NSUInteger checks, failures, requests;
static NSString *signedStatus = @"active";
static void Check(BOOL value, NSString *why) {
    checks++;
    if (!value) { failures++; fprintf(stderr, "FAIL: %s\n", why.UTF8String); }
}
static double Continuous(void) {
    mach_timebase_info_data_t scale; mach_timebase_info(&scale);
    return (double)mach_continuous_time() * scale.numer / scale.denom / 1e9;
}
@interface RetirementProtocol : NSURLProtocol @end
@implementation RetirementProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { (void)request; return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)stopLoading {}
- (void)startLoading {
    requests++; NSData *body = self.request.HTTPBody;
    if (!body && self.request.HTTPBodyStream) {
        NSInputStream *stream = self.request.HTTPBodyStream; [stream open];
        NSMutableData *bytes = [NSMutableData data]; char buffer[1024]; NSInteger length;
        while ((length = [stream read:(uint8_t *)buffer maxLength:sizeof(buffer)]) > 0)
            [bytes appendBytes:buffer length:(NSUInteger)length];
        [stream close]; body = bytes;
    }
    NSDictionary *request = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    NSMutableDictionary *claims = TestLicenseClaims(@"AAAA-BBBB-CCCC-DDDD", request[@"nonce"], NSDate.date.timeIntervalSince1970);
    claims[@"iss"] = @"https://redditspoof.vercel.app";
    claims[@"deviceBinding"] = [RBXLicenseToken fingerprint:request[@"deviceIdentity"]];
    claims[@"status"] = signedStatus;
    NSDictionary *reply = @{@"licenseToken":TestLicenseJWT(claims, nil), @"deviceId":@"fixture-device",
        @"token":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0]};
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200
        HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil]];
    [self.client URLProtocolDidFinishLoading:self];
}
@end
static LBXLicenseOwner *Source(LBXLicenseVault *vault) {
    LBXLicenseOwner *owner = [[LBXLicenseOwner alloc] initWithVault:vault];
    [owner testUseProtocol:RetirementProtocol.class publicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];
    return owner;
}
static NSDictionary *License(LBXLicenseOwner *owner, NSString *operation) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0); __block NSDictionary *reply;
    [owner handleRequest:LBXLicenseIPCRequest(operation, [operation isEqual:@"activate"] ? @"AAAA-BBBB-CCCC-DDDD" : nil)
        completion:^(NSDictionary *result) { reply = result; dispatch_semaphore_signal(done); }];
    Check(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)), @"bounded signed fixture license response");
    return reply;
}
static void Authorize(LBXLicenseOwner *owner) {
    signedStatus = @"active";
    Check([License(owner, @"validate")[@"result"] isEqual:@"active"] && owner.sourceAuthorizationCurrent,
        @"fresh signed source fence for exact owner");
}
static NSDictionary *RawSend(LBXContainerRootMutationOwner *owner, NSDictionary *request) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0); __block NSDictionary *reply; __block NSUInteger count = 0;
    [owner handleRequest:request completion:^(NSDictionary *result) { reply = result; count++; dispatch_semaphore_signal(done); }];
    Check(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) && count == 1,
        @"one bounded root metadata reply");
    return reply;
}
static NSDictionary *Send(LBXContainerRootMutationOwner *owner, NSDictionary *request) {
    Check(request && LBXContainerMutationIPCValidateRequest(request, LBXContainerMutationIPCClock()), @"strict typed retirement fixture request");
    NSDictionary *reply = RawSend(owner, request);
    Check(LBXContainerMutationIPCValidateReply(reply, request, LBXContainerMutationIPCClock()), @"typed reply correlation and runtimeAccepted false");
    return reply;
}
static NSDictionary *Call(LBXContainerRootMutationOwner *owner, NSString *operation, NSDictionary *arguments) {
    return Send(owner, LBXContainerMutationIPCRequest(operation, arguments));
}
static NSDictionary *Read(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}
static BOOL Write(NSString *path, id value, NSJSONWritingOptions options) {
    NSData *data = [value isKindOfClass:NSData.class] ? value : [NSJSONSerialization dataWithJSONObject:value options:options error:nil];
    return data && [data writeToFile:path atomically:NO] && !chmod(path.fileSystemRepresentation, 0600);
}
static NSDictionary *Snapshot(NSString *path) {
    struct stat st; if (lstat(path.fileSystemRepresentation, &st)) return nil;
    return @{@"bytes":[NSData dataWithContentsOfFile:path] ?: NSData.data, @"device":@(st.st_dev), @"inode":@(st.st_ino),
        @"mode":@(st.st_mode), @"links":@(st.st_nlink), @"uid":@(st.st_uid), @"gid":@(st.st_gid)};
}
static BOOL StrictBoolean(id value, BOOL expected) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() && [value boolValue] == expected;
}
static BOOL Tombstone(NSDictionary *record, NSDictionary *original) {
    return [record isKindOfClass:NSDictionary.class] &&
        [[NSSet setWithArray:record.allKeys] isEqual:[NSSet setWithArray:@[@"storageVersion", @"configuration", @"allocationReserved", @"retired"]]] &&
        [record[@"storageVersion"] isEqual:@2] && !StrictBoolean(record[@"storageVersion"], YES) &&
        [record[@"configuration"] isEqual:original] && StrictBoolean(record[@"allocationReserved"], NO) && StrictBoolean(record[@"retired"], YES);
}
static NSDictionary *Token(NSDictionary *slot) { return @{@"token":slot[@"token"], @"epoch":slot[@"epoch"]}; }
static NSDictionary *Choices(NSString *name) {
    return @{@"name":name, @"applications":@[@"com.burbn.instagram"], @"manualIdentifiers":NSNull.null, @"proxyReference":@""};
}
@interface RetirementFixture : NSObject
@property NSString *base, *configPath, *pendingPath, *statePath;
@property LBXLicenseVault *vault;
@property LBXLicenseOwner *source;
@property LBXContainerConfigurationStore *store;
@property LBXContainerRootPendingStore *pending;
@property LBXContainerRootMutationOwner *owner;
@end
@implementation RetirementFixture @end
static RetirementFixture *NewFixture(NSString *base, NSString *name) {
    signedStatus = @"active"; // A revoked fixture cannot affect a later fixture.
    RetirementFixture *f = [RetirementFixture new]; f.base = [base stringByAppendingPathComponent:name];
    Check(!mkdir(f.base.fileSystemRepresentation, 0700), @"fresh private fixture directory");
    f.vault = [LBXLicenseVault openDirectory:[f.base stringByAppendingPathComponent:@"vault"] error:nil];
    [f.vault testUsePublicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()]; f.source = Source(f.vault);
    Check([License(f.source, @"activate")[@"result"] isEqual:@"active"], @"synthetic signed pairing without external transport");
    f.configPath = [f.base stringByAppendingPathComponent:@"configurations"];
    f.store = [LBXContainerConfigurationStore openDirectory:f.configPath licenseOwner:f.source create:YES error:nil];
    f.pendingPath = [f.base stringByAppendingPathComponent:@"pending"]; f.statePath = [f.pendingPath stringByAppendingPathComponent:@"state.json"];
    double deadline = LBXLicenseIPCClock()+3;
    Check([f.source performSourceOperation:^BOOL(NSError **error) {
        f.pending = [LBXContainerRootPendingStore openDirectory:f.pendingPath licenseOwner:f.source configurationStore:f.store
            create:YES beforeDeadline:deadline error:error]; return f.pending != nil;
    } beforeDeadline:deadline error:nil], @"trusted host-only pristine root journal assembly");
    f.owner = [[LBXContainerRootMutationOwner alloc] initWithLicenseOwner:f.source configurationStore:f.store pendingDirectory:f.pendingPath];
    Check(f.owner && Read(f.statePath), @"actual root pending owner and durable state assembled"); return f;
}
static NSString *Record(RetirementFixture *f, NSDictionary *document) {
    return [f.configPath stringByAppendingPathComponent:[document[@"identifier"] stringByAppendingString:@".json"]];
}
static NSDictionary *StageCreate(RetirementFixture *f, NSString *name) {
    NSDictionary *state = Call(f.owner, @"status", @{})[@"state"];
    Check(state[@"pending"] == NSNull.null, @"actual empty slot before old create command");
    NSDictionary *reply = Call(f.owner, @"stage-create", @{@"expectedEmptyEpoch":state[@"epoch"],
        @"stageRequestID":NSUUID.UUID.UUIDString.lowercaseString, @"choices":Choices(name)});
    Check([reply[@"result"] isEqual:@"staged"], @"old create stages real full authored metadata"); return reply[@"state"][@"pending"];
}
static NSDictionary *Save(RetirementFixture *f, NSString *name) {
    NSDictionary *slot = StageCreate(f, name), *reply = Call(f.owner, @"execute", Token(slot));
    Check([reply[@"result"] isEqual:@"saved"] && [reply[@"configuration"] isEqual:slot[@"configuration"]], @"old execute genuinely saves fixture metadata");
    return reply[@"configuration"];
}
static NSDictionary *RetireArguments(RetirementFixture *f, NSDictionary *document) {
    return @{@"expectedEmptyEpoch":Call(f.owner, @"status", @{})[@"state"][@"epoch"],
        @"stageRequestID":NSUUID.UUID.UUIDString.lowercaseString, @"expected":document};
}
static NSDictionary *StageRetire(RetirementFixture *f, NSDictionary *document) {
    NSDictionary *reply = Call(f.owner, @"stage-retire", RetireArguments(f, document));
    Check([reply[@"result"] isEqual:@"retirement_staged"], @"distinct retirement stage for exact full current document");
    return reply[@"state"][@"pending"];
}
static LBXContainerConfiguration *Configuration(NSDictionary *document) { return [LBXContainerConfiguration fromDictionary:document error:nil]; }
static BOOL DirectRetire(RetirementFixture *f, NSDictionary *document) {
    double deadline = LBXLicenseIPCClock()+3;
    return [f.source performSourceOperation:^BOOL(NSError **error) {
        return [f.store retireConfiguration:Configuration(document) inCurrentSourceOperationBeforeDeadline:deadline error:error];
    } beforeDeadline:deadline error:nil];
}

static void LifecycleTests(NSString *base) {
    RetirementFixture *f = NewFixture(base, @"lifecycle");
    NSDictionary *original = Save(f, @"Original authored metadata"), *sibling = Save(f, @"Preserved sibling");
    NSString *path = Record(f, original); NSDictionary *recordBefore = Snapshot(path), *siblingBefore = Snapshot(Record(f, sibling));
    NSDictionary *args = RetireArguments(f, original), *stageRequest = LBXContainerMutationIPCRequest(@"stage-retire", args);
    NSUInteger network = requests; NSDictionary *reply = Send(f.owner, stageRequest), *slot = reply[@"state"][@"pending"];
    Check([reply[@"result"] isEqual:@"retirement_staged"] && [slot[@"operation"] isEqual:@"retire"] &&
        [slot[@"configuration"] isEqual:original] && [slot[@"expected"] isEqual:original], @"retirement retains full original with unchanged revision and identifiers");
    NSDictionary *staged = Snapshot(f.statePath);
    Check([Snapshot(path) isEqual:recordBefore] && [Snapshot(Record(f, sibling)) isEqual:siblingBefore], @"staging changes no metadata record or sibling");
    reply = Call(f.owner, @"stage-retire", args);
    Check([reply[@"result"] isEqual:@"retirement_staged"] && [reply[@"state"][@"pending"] isEqual:slot] && [Snapshot(f.statePath) isEqual:staged], @"exact stage retry preserves journal bytes inode token and document");
    NSMutableDictionary *other = [args mutableCopy], *renamed = [original mutableCopy]; renamed[@"name"] = @"Different full expected name"; other[@"expected"] = renamed;
    Check([Call(f.owner, @"stage-retire", other)[@"result"] isEqual:@"conflict"] && [Snapshot(f.statePath) isEqual:staged], @"same stage identifier with changed full expected document conflicts");
    reply = Call(f.owner, @"reconcile-retire", Token(slot));
    Check([reply[@"result"] isEqual:@"retirement_retry_required"] && [Snapshot(f.statePath) isEqual:staged] && [Snapshot(path) isEqual:recordBefore], @"active exact unreserved record permits explicit retirement retry only");
    for (NSString *op in @[@"execute", @"reconcile"]) {
        Check([Call(f.owner, op, Token(slot))[@"result"] isEqual:@"conflict"] && [Snapshot(f.statePath) isEqual:staged] && [Snapshot(path) isEqual:recordBefore], @"old generic save command cannot act on a retirement slot");
    }
    reply = Call(f.owner, @"execute-retire", Token(slot));
    Check([reply[@"result"] isEqual:@"retired"] && reply[@"state"][@"pending"] == NSNull.null &&
        [reply[@"state"][@"completed"] isEqual:slot] && Tombstone(Read(path), original), @"strict durable tombstone precedes exact completed retirement receipt");
    NSDictionary *finished = Snapshot(f.statePath), *retired = Snapshot(path);
    for (NSString *op in @[@"execute-retire", @"reconcile-retire"]) {
        reply = Call(f.owner, op, Token(slot));
        Check([reply[@"result"] isEqual:@"retired"] && [reply[@"configuration"] isEqual:original] && [Snapshot(f.statePath) isEqual:finished] && [Snapshot(path) isEqual:retired], @"completed retry proves exact retirement without rewriting either node");
    }
    reply = Call(f.owner, @"stage-retire", args);
    Check([reply[@"result"] isEqual:@"retired"] && [Snapshot(f.statePath) isEqual:finished] && [Snapshot(path) isEqual:retired], @"delayed exact stage request reconciles completion read-only");
    Check([Call(f.owner, @"read", @{@"identifier":original[@"identifier"]})[@"result"] isEqual:@"conflict"], @"retired UUID is occupied rather than missing active metadata");
    Check(!f.source.sourceAuthorizationCurrent && requests == network, @"failed retired active lookup closes admission without implicit license refresh");
    Check([Call(f.owner, @"list", @{@"after":@""})[@"result"] isEqual:@"authorization_required"] &&
        [Snapshot(path) isEqual:retired] && [Snapshot(Record(f, sibling)) isEqual:siblingBefore], @"closed source fence preserves retired and active records before explicit validation");
    Authorize(f.source); network = requests;
    reply = Call(f.owner, @"list", @{@"after":@""});
    Check([reply[@"result"] isEqual:@"listed"] && [reply[@"entries"] count] == 1, @"fresh signed inventory hides valid retired metadata");
    Check([reply[@"entries"][0][@"identifier"] isEqual:sibling[@"identifier"]] && [Snapshot(Record(f, sibling)) isEqual:siblingBefore], @"fresh active list preserves exact sibling identity bytes and inode");
    Check(requests == network, @"active list sends no implicit refresh after explicit fixture validation");

    LBXLicenseVault *vault = [LBXLicenseVault openExistingDirectory:[f.base stringByAppendingPathComponent:@"vault"] error:nil];
    [vault testUsePublicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()]; LBXLicenseOwner *source = Source(vault);
    LBXContainerConfigurationStore *store = [LBXContainerConfigurationStore openDirectory:f.configPath licenseOwner:source create:NO error:nil];
    LBXContainerRootMutationOwner *owner = [[LBXContainerRootMutationOwner alloc] initWithLicenseOwner:source configurationStore:store pendingDirectory:f.pendingPath];
    Check([Call(owner, @"status", @{})[@"result"] isEqual:@"authorization_required"] && [Snapshot(f.statePath) isEqual:finished], @"restart never treats retirement history as signed admission");
    Authorize(source); reply = Call(owner, @"reconcile-retire", Token(slot));
    Check([reply[@"result"] isEqual:@"retired"] && [Snapshot(f.statePath) isEqual:finished] && [Snapshot(path) isEqual:retired], @"fresh validated owner reopens exact completed retirement without rewriting");
    LBXContainerConfiguration *edit = [Configuration(original) configurationByUpdatingName:@"Forbidden reuse" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];
    NSDictionary *state = Call(owner, @"status", @{})[@"state"];
    Check([Call(owner, @"stage-update", @{@"expectedEmptyEpoch":state[@"epoch"], @"stageRequestID":NSUUID.UUID.UUIDString.lowercaseString,
        @"expected":original, @"configuration":edit.privateDictionary})[@"result"] isEqual:@"conflict"] && [Snapshot(f.statePath) isEqual:finished], @"old update staging cannot reopen retired UUID");
    Authorize(source);
    Check(![store commitConfiguration:Configuration(original) replacing:nil beforeDeadline:LBXLicenseIPCClock()+3 error:nil] && [Snapshot(path) isEqual:retired], @"direct create cannot reuse permanent retired UUID");
}

static void OlderPendingTests(NSString *base) {
    for (NSString *kind in @[@"create", @"update"]) {
        RetirementFixture *f = NewFixture(base, [@"older-pending-" stringByAppendingString:kind]);
        NSDictionary *original = Save(f, @"Retirement target"); NSDictionary *slot;
        if ([kind isEqual:@"create"]) slot = StageCreate(f, @"Unfinished original create");
        else {
            LBXContainerConfiguration *edit = [Configuration(original) configurationByUpdatingName:@"Unfinished original update" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];
            NSDictionary *state = Call(f.owner, @"status", @{})[@"state"];
            slot = Call(f.owner, @"stage-update", @{@"expectedEmptyEpoch":state[@"epoch"], @"stageRequestID":NSUUID.UUID.UUIDString.lowercaseString,
                @"expected":original, @"configuration":edit.privateDictionary})[@"state"][@"pending"];
        }
        NSDictionary *before = Snapshot(f.statePath), *record = Snapshot(Record(f, original));
        Check([Call(f.owner, @"stage-retire", RetireArguments(f, original))[@"result"] isEqual:@"conflict"] && [Snapshot(f.statePath) isEqual:before], @"retirement staging never discards unfinished old create or update");
        for (NSString *op in @[@"execute-retire", @"reconcile-retire"]) {
            Check([Call(f.owner, op, Token(slot))[@"result"] isEqual:@"conflict"] && [Snapshot(f.statePath) isEqual:before] && [Snapshot(Record(f, original)) isEqual:record], @"new retirement verbs conflict on old pending kinds without effects");
        }
        NSDictionary *reply = Call(f.owner, @"execute", Token(slot));
        Check([reply[@"result"] isEqual:@"saved"] && [reply[@"configuration"] isEqual:slot[@"configuration"]], @"retirement refusal leaves old exact pending candidate executable");
        Check([Call(f.owner, @"reconcile-retire", Token(slot))[@"result"] isEqual:@"conflict"], @"new retirement verb cannot confirm old completed save");
    }
    RetirementFixture *f = NewFixture(base, @"unknown-pending-preserved"); NSDictionary *original = Save(f, @"Known target");
    NSDictionary *slot = StageCreate(f, @"Unfinished unknown fixture"), *state = Read(f.statePath);
    NSMutableDictionary *bad = [state mutableCopy], *pending = [state[@"pending"] mutableCopy], *wrongSlot = [slot mutableCopy];
    wrongSlot[@"operation"] = @"unknown"; pending[@"slot"] = wrongSlot; bad[@"pending"] = pending;
    Check(Write(f.statePath, bad, NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes), @"test-only unknown pending kind installed in existing journal");
    NSDictionary *before = Snapshot(f.statePath), *record = Snapshot(Record(f, original));
    Check([Call(f.owner, @"status", @{})[@"result"] isEqual:@"unconfirmed"] && [Snapshot(f.statePath) isEqual:before], @"unknown pending schema cannot become fake empty status");
    Authorize(f.source);
    NSDictionary *args = @{@"expectedEmptyEpoch":state[@"epoch"], @"stageRequestID":NSUUID.UUID.UUIDString.lowercaseString, @"expected":original};
    Check([Call(f.owner, @"stage-retire", args)[@"result"] isEqual:@"unconfirmed"] && [Snapshot(f.statePath) isEqual:before] && [Snapshot(Record(f, original)) isEqual:record], @"unknown unfinished work is preserved without repair retirement or adoption");
}

static void PendingRestartTests(NSString *base) {
    RetirementFixture *f = NewFixture(base, @"pending-restart"); NSDictionary *original = Save(f, @"Exact retirement survives restart"), *slot = StageRetire(f, original);
    NSDictionary *journal = Snapshot(f.statePath), *record = Snapshot(Record(f, original));
    LBXLicenseVault *vault = [LBXLicenseVault openExistingDirectory:[f.base stringByAppendingPathComponent:@"vault"] error:nil];
    [vault testUsePublicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()]; LBXLicenseOwner *source = Source(vault);
    LBXContainerConfigurationStore *store = [LBXContainerConfigurationStore openDirectory:f.configPath licenseOwner:source create:NO error:nil];
    LBXContainerRootMutationOwner *owner = [[LBXContainerRootMutationOwner alloc] initWithLicenseOwner:source configurationStore:store pendingDirectory:f.pendingPath];
    Check([Call(owner, @"execute-retire", Token(slot))[@"result"] isEqual:@"authorization_required"] &&
        [Snapshot(f.statePath) isEqual:journal] && [Snapshot(Record(f, original)) isEqual:record], @"pending restart requires fresh signed owner admission before any effect");
    Authorize(source); NSDictionary *reply = Call(owner, @"status", @{});
    Check([reply[@"state"][@"pending"] isEqual:slot] && [Snapshot(f.statePath) isEqual:journal], @"fresh owner observes same retained retirement slot without rerandomizing or rewriting");
    Check([Call(owner, @"read", @{@"identifier":original[@"identifier"]})[@"configuration"] isEqual:original] &&
        [Call(owner, @"list", @{@"after":@""})[@"entries"] count] == 1, @"staged retirement leaves original active metadata readable until actual publication");
    reply = Call(owner, @"reconcile-retire", Token(slot));
    Check([reply[@"result"] isEqual:@"retirement_retry_required"] && [Snapshot(f.statePath) isEqual:journal], @"restart reconciles active full original as explicit exact retirement retry");
    reply = Call(owner, @"execute-retire", Token(slot));
    Check([reply[@"result"] isEqual:@"retired"] && Tombstone(Read(Record(f, original)), original), @"restarted exact owner executes original retained document only");
}

static void EligibilityTests(NSString *base) {
    for (NSString *kind in @[@"reserved", @"legacy", @"missing", @"changed", @"same-revision-change", @"untracked-tombstone"]) {
        RetirementFixture *f = NewFixture(base, [@"eligibility-" stringByAppendingString:kind]);
        NSDictionary *original = Save(f, @"Original full metadata"), *args = RetireArguments(f, original); NSString *path = Record(f, original);
        LBXContainerConfiguration *configuration = Configuration(original);
        if ([kind isEqual:@"reserved"]) {
            double deadline = LBXLicenseIPCClock()+3;
            Check([f.source performSourceOperation:^BOOL(NSError **error) { return [f.store reserveConfigurationForClosedAllocation:configuration beforeDeadline:deadline error:error]; }
                beforeDeadline:deadline error:nil], @"actual reserved metadata fixture before retirement");
        } else if ([kind isEqual:@"legacy"]) Check(Write(path, original, NSJSONWritingSortedKeys), @"test-only legacy UNKNOWN backing record");
        else if ([kind isEqual:@"missing"]) Check(!rename(path.fileSystemRepresentation, [path stringByAppendingString:@".held"].fileSystemRepresentation), @"test-only original record held without deleting contents");
        else if ([kind isEqual:@"changed"]) {
            LBXContainerConfiguration *edit = [configuration configurationByUpdatingName:@"Changed current document" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];
            Check([f.store commitConfiguration:edit replacing:configuration beforeDeadline:LBXLicenseIPCClock()+3 error:nil], @"actual competing full-document update");
        } else if ([kind isEqual:@"same-revision-change"]) {
            NSMutableDictionary *record = [Read(path) mutableCopy], *document = [original mutableCopy]; document[@"name"] = @"Same revision different full content"; record[@"configuration"] = document;
            Check(Write(path, record, NSJSONWritingSortedKeys), @"test-only full-document mismatch with same UUID and revision");
        } else Check(DirectRetire(f, original), @"trusted direct tombstone without matching pending retirement receipt");
        NSDictionary *before = Snapshot(f.statePath), *recordBefore = Snapshot(path); NSDictionary *reply = Call(f.owner, @"stage-retire", args);
        Check([reply[@"result"] isEqual:@"conflict"] && [Snapshot(f.statePath) isEqual:before] &&
            (recordBefore ? [Snapshot(path) isEqual:recordBefore] : Snapshot(path) == nil), @"reserved legacy missing changed or untracked retired state cannot be staged adopted or reset");
    }
    for (NSString *kind in @[@"reserved", @"legacy", @"missing", @"changed"]) {
        RetirementFixture *f = NewFixture(base, [@"post-stage-" stringByAppendingString:kind]);
        NSDictionary *original = Save(f, @"Originally eligible metadata"), *slot = StageRetire(f, original); NSString *path = Record(f, original);
        if ([kind isEqual:@"reserved"]) {
            double deadline = LBXLicenseIPCClock()+3;
            Check([f.source performSourceOperation:^BOOL(NSError **error) { return [f.store reserveConfigurationForClosedAllocation:Configuration(original) beforeDeadline:deadline error:error]; }
                beforeDeadline:deadline error:nil], @"actual reservation committed after retirement stage");
        } else if ([kind isEqual:@"legacy"]) Check(Write(path, original, NSJSONWritingSortedKeys), @"test-only UNKNOWN record after exact stage");
        else if ([kind isEqual:@"missing"]) Check(!rename(path.fileSystemRepresentation, [path stringByAppendingString:@".held"].fileSystemRepresentation), @"test-only disappearance preserves held original");
        else {
            LBXContainerConfiguration *edit = [Configuration(original) configurationByUpdatingName:@"Changed after stage" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];
            Check([f.store commitConfiguration:edit replacing:Configuration(original) beforeDeadline:LBXLicenseIPCClock()+3 error:nil], @"actual competing update after retirement stage");
        }
        NSDictionary *before = Snapshot(f.statePath), *recordBefore = Snapshot(path);
        for (NSString *op in @[@"reconcile-retire", @"execute-retire"]) {
            NSDictionary *reply = Call(f.owner, op, Token(slot));
            Check([reply[@"result"] isEqual:@"conflict"] && [Snapshot(f.statePath) isEqual:before] &&
                (recordBefore ? [Snapshot(path) isEqual:recordBefore] : Snapshot(path) == nil), @"post-stage eligibility loss preserves exact unfinished retirement and all original bytes");
            Authorize(f.source);
        }
    }
}

static void TypedBoundaryTests(NSString *base) {
    RetirementFixture *f = NewFixture(base, @"typed-boundaries"); NSDictionary *original = Save(f, @"Exact typed target");
    NSDictionary *args = RetireArguments(f, original), *request = LBXContainerMutationIPCRequest(@"stage-retire", args);
    for (NSString *extra in @[@"configuration", @"choices", @"path", @"allocationReserved", @"retired", @"authority"]) {
        NSMutableDictionary *bad = [args mutableCopy]; bad[extra] = original;
        Check(!LBXContainerMutationIPCRequest(@"stage-retire", bad), @"retirement input has no extra choices path reservation or grant fields");
    }
    for (NSString *field in @[@"name", @"identifier", @"revision", @"formatVersion", @"proxyReference"]) {
        NSMutableDictionary *bad = [args mutableCopy], *document = [original mutableCopy];
        if ([field isEqual:@"name"]) [document removeObjectForKey:field];
        else if ([field isEqual:@"identifier"]) document[field] = [original[field] uppercaseString];
        else if ([field isEqual:@"proxyReference"]) document[field] = @"https://user:password@host";
        else document[field] = @YES;
        bad[@"expected"] = document;
        Check(!LBXContainerMutationIPCRequest(@"stage-retire", bad), @"stage-retire requires canonical complete existing typed document subset");
    }
    NSDictionary *before = Snapshot(f.statePath), *record = Snapshot(Record(f, original));
    for (NSString *field in @[@"operation", @"version", @"deadline", @"extra"]) {
        NSMutableDictionary *bad = [request mutableCopy];
        if ([field isEqual:@"operation"]) bad[field] = @"Stage-retire";
        else if ([field isEqual:@"version"]) bad[field] = @YES;
        else if ([field isEqual:@"deadline"]) bad[field] = @(LBXContainerMutationIPCClock()-1);
        else bad[field] = @YES;
        Check(!LBXContainerMutationIPCValidateRequest(bad, LBXContainerMutationIPCClock()), @"malformed raw command is rejected by typed parser");
        Check([RawSend(f.owner, bad)[@"result"] isEqual:@"invalid_request"] && [Snapshot(f.statePath) isEqual:before] &&
            [Snapshot(Record(f, original)) isEqual:record], @"invalid raw request cannot stage mutate or project private state");
    }
    NSDictionary *reply = Send(f.owner, request), *slot = reply[@"state"][@"pending"];
    NSMutableDictionary *badReply = [reply mutableCopy]; badReply[@"result"] = @"staged";
    Check(!LBXContainerMutationIPCValidateReply(badReply, request, LBXContainerMutationIPCClock()), @"old staged result cannot project retirement slot");
    NSMutableDictionary *badSlot = [slot mutableCopy]; badSlot[@"operation"] = @"update";
    Check(!LBXContainerMutationIPCProjectSlot(badSlot), @"retirement full-original slot is not an incremented update slot");
    badSlot = [slot mutableCopy]; NSMutableDictionary *different = [original mutableCopy]; different[@"name"] = @"Different expected full document";
    badSlot[@"expected"] = different;
    Check(!LBXContainerMutationIPCProjectSlot(badSlot), @"retirement projection requires full expected equals retained configuration");
    badSlot = [slot mutableCopy]; badSlot[@"operation"] = @"unknown";
    Check(!LBXContainerMutationIPCProjectSlot(badSlot), @"unknown operation cannot fall through as update or retirement");
    NSDictionary *staged = Snapshot(f.statePath);
    for (NSDictionary *token in @[@{@"token":NSUUID.UUID.UUIDString.lowercaseString, @"epoch":slot[@"epoch"]},
        @{@"token":slot[@"token"], @"epoch":[NSString stringWithFormat:@"%lld", [slot[@"epoch"] longLongValue]+1]}]) {
        Check([Call(f.owner, @"execute-retire", token)[@"result"] isEqual:@"conflict"] && [Snapshot(f.statePath) isEqual:staged] &&
            [Snapshot(Record(f, original)) isEqual:record], @"wrong exact token or epoch cannot execute or discard pending retirement");
    }
    NSDictionary *reconcile = LBXContainerMutationIPCRequest(@"reconcile-retire", Token(slot)); reply = Send(f.owner, reconcile);
    badReply = [reply mutableCopy]; badReply[@"result"] = @"retry_required";
    Check(!LBXContainerMutationIPCValidateReply(badReply, reconcile, LBXContainerMutationIPCClock()), @"old retry result cannot project retirement uncertainty");
    NSDictionary *execute = LBXContainerMutationIPCRequest(@"execute-retire", Token(slot)); reply = Send(f.owner, execute);
    badReply = [reply mutableCopy]; badReply[@"result"] = @"saved";
    Check(!LBXContainerMutationIPCValidateReply(badReply, execute, LBXContainerMutationIPCClock()), @"active saved result can never confirm retirement completion");
    NSDictionary *oldExecute = LBXContainerMutationIPCRequest(@"execute", Token(slot));
    badReply = [reply mutableCopy]; badReply[@"requestID"] = oldExecute[@"requestID"]; badReply[@"operation"] = @"execute";
    Check(!LBXContainerMutationIPCValidateReply(badReply, oldExecute, LBXContainerMutationIPCClock()), @"retired result cannot satisfy old generic execute request");
    NSDictionary *completed = Snapshot(f.statePath);
    Check([Send(f.owner, oldExecute)[@"result"] isEqual:@"conflict"] && [Snapshot(f.statePath) isEqual:completed], @"old execute conflicts even on completed retirement with exact token");
    for (NSString *field in @[@"requestID", @"operation", @"runtimeAccepted", @"configuration"]) {
        badReply = [reply mutableCopy];
        if ([field isEqual:@"requestID"]) badReply[field] = NSUUID.UUID.UUIDString.lowercaseString;
        else if ([field isEqual:@"operation"]) badReply[field] = @"reconcile-retire";
        else if ([field isEqual:@"runtimeAccepted"]) badReply[field] = @YES;
        else badReply[field] = different;
        Check(!LBXContainerMutationIPCValidateReply(badReply, execute, LBXContainerMutationIPCClock()), @"retirement receipt binds exact request full document operation and false runtime flag");
    }
}

// Test-only publication of an already staged exact tombstone while holding the
// actual pending lock and source fence. This models the durable configuration
// effect that may precede an uncertain clear, not a new authority or IPC route.
static void PublishStagedTombstone(RetirementFixture *f, NSDictionary *slot) {
    double deadline = LBXLicenseIPCClock()+3;
    Check([f.source performSourceOperation:^BOOL(NSError **error) {
        return [f.pending withLockedStateBeforeDeadline:deadline operation:^BOOL(LBXContainerRootPendingTransaction *transaction, NSError **effectError) {
            Check([transaction.privateState[@"pending"][@"slot"] isEqual:slot], @"test publication retains original exact locked pending slot");
            return [f.store retireConfiguration:Configuration(slot[@"configuration"]) inCurrentSourceOperationBeforeDeadline:deadline error:effectError];
        } error:error];
    } beforeDeadline:deadline error:nil], @"actual tombstone publication under same source fence and pending lock");
}
static void PendingPublicationTests(NSString *base) {
    for (NSString *boundary in @[@"state_staged", @"state_renamed", @"state_synced"]) {
        RetirementFixture *f = NewFixture(base, [@"publish-" stringByAppendingString:boundary]);
        NSDictionary *original = Save(f, @"Target before journal interruption"), *args = RetireArguments(f, original);
        NSDictionary *recordBefore = Snapshot(Record(f, original)), *prior = Read(f.statePath); BOOL published = ![boundary isEqual:@"state_staged"];
        [f.owner testStopAfterBoundary:boundary]; NSDictionary *reply = Call(f.owner, @"stage-retire", args), *disk = Read(f.statePath);
        Check([reply[@"result"] isEqual:@"unconfirmed"] && reply[@"state"] == NSNull.null && [Snapshot(Record(f, original)) isEqual:recordBefore], @"failed stage never claims retirement or mutates active record");
        Check(published ? [disk[@"pending"][@"slot"][@"operation"] isEqual:@"retire"] : disk[@"pending"] == NSNull.null, @"pre-publication stage failure retains empty slot while post-publication retains exact retirement");
        Check([disk[@"completed"] isEqual:prior[@"completed"]], @"uncertain retirement stage preserves old completed save history");
        NSDictionary *uncertainSlot = published ? disk[@"pending"][@"slot"] : nil;
        Authorize(f.source); [f.owner testStopAfterBoundary:nil]; reply = Call(f.owner, @"stage-retire", args);
        NSDictionary *slot = reply[@"state"][@"pending"];
        Check([reply[@"result"] isEqual:@"retirement_staged"] && (!uncertainSlot || [slot isEqual:uncertainSlot]), @"exact original stage input reconciles uncertain durable stage without replacement");
        [f.owner testStopAfterBoundary:boundary]; reply = Call(f.owner, @"execute-retire", Token(slot)); disk = Read(f.statePath);
        Check([reply[@"result"] isEqual:@"unconfirmed"] && reply[@"state"] == NSNull.null && [disk[@"pending"][@"slot"] isEqual:slot] &&
            [disk[@"pending"][@"attempt"] isEqual:(published ? @1 : @0)] && [Snapshot(Record(f, original)) isEqual:recordBefore], @"uncertain attempt publication retains immutable retirement and never reaches record mutation");
        Authorize(f.source); [f.owner testStopAfterBoundary:nil]; reply = Call(f.owner, @"execute-retire", Token(slot));
        Check([reply[@"result"] isEqual:@"retired"] && Tombstone(Read(Record(f, original)), original), @"fresh validation executes original retained retirement after attempt interruption");
    }
    for (NSString *boundary in @[@"state_staged", @"state_renamed", @"state_synced"]) {
        RetirementFixture *f = NewFixture(base, [@"clear-" stringByAppendingString:boundary]);
        NSDictionary *original = Save(f, @"Tombstone before uncertain clear"), *slot = StageRetire(f, original);
        PublishStagedTombstone(f, slot); NSDictionary *record = Snapshot(Record(f, original));
        [f.owner testStopAfterBoundary:boundary]; NSDictionary *reply = Call(f.owner, @"reconcile-retire", Token(slot)), *disk = Read(f.statePath);
        BOOL published = ![boundary isEqual:@"state_staged"];
        Check([reply[@"result"] isEqual:@"unconfirmed"] && reply[@"state"] == NSNull.null && [Snapshot(Record(f, original)) isEqual:record], @"failed proof-clear never reports success or rewrites exact tombstone");
        Check(published ? (disk[@"pending"] == NSNull.null && [disk[@"completed"][@"slot"] isEqual:slot]) : [disk[@"pending"][@"slot"] isEqual:slot], @"clear failure preserves either exact pending retirement or exact completed retirement");
        Authorize(f.source); [f.owner testStopAfterBoundary:nil]; reply = Call(f.owner, @"reconcile-retire", Token(slot));
        Check([reply[@"result"] isEqual:@"retired"] && [reply[@"configuration"] isEqual:original] && [Snapshot(Record(f, original)) isEqual:record], @"new signed fence plus pinned exact retirement proof reconciles uncertain clear read-only");
    }
    RetirementFixture *f = NewFixture(base, @"expiry-after-tombstone"); NSDictionary *original = Save(f, @"Published before fence expiry"), *slot = StageRetire(f, original);
    NSString *path = Record(f, original); __block BOOL armed = NO; __block double wall = NSDate.date.timeIntervalSince1970, continuous = Continuous();
    [f.source testUseAuthorizationClock:^double(BOOL monotonic) {
        if (armed && Tombstone(Read(path), original)) { armed = NO; wall += 65; continuous += 65; }
        return monotonic ? continuous : wall;
    }];
    Authorize(f.source); armed = YES; NSDictionary *reply = Call(f.owner, @"execute-retire", Token(slot));
    Check([reply[@"result"] isEqual:@"authorization_required"] && reply[@"state"] == NSNull.null && Tombstone(Read(path), original) &&
        [Read(f.statePath)[@"pending"][@"slot"] isEqual:slot], @"signed expiry after actual tombstone publication preserves exact pending uncertainty and tombstone");
    NSDictionary *record = Snapshot(path), *state = Snapshot(f.statePath);
    Check([Call(f.owner, @"reconcile-retire", Token(slot))[@"result"] isEqual:@"authorization_required"] &&
        [Snapshot(path) isEqual:record] && [Snapshot(f.statePath) isEqual:state], @"expired owner cannot turn retained tombstone into success or repair");
    wall = NSDate.date.timeIntervalSince1970; continuous = Continuous(); Authorize(f.source); reply = Call(f.owner, @"reconcile-retire", Token(slot));
    Check([reply[@"result"] isEqual:@"retired"] && [Snapshot(path) isEqual:record], @"fresh validation independently proves and clears original published retirement without rewriting");
}

static void TombstoneDenialTests(NSString *base) {
    for (NSString *kind in @[@"noncanonical", @"boolean", @"extra", @"changed-full", @"symlink", @"hardlink", @"mode"]) {
        RetirementFixture *f = NewFixture(base, [@"bad-tombstone-" stringByAppendingString:kind]);
        NSDictionary *original = Save(f, @"Exact pending tombstone target"), *slot = StageRetire(f, original); PublishStagedTombstone(f, slot);
        NSString *path = Record(f, original); NSMutableDictionary *bad = [Read(path) mutableCopy];
        if ([kind isEqual:@"noncanonical"]) {
            NSMutableData *bytes = [[NSData dataWithContentsOfFile:path] mutableCopy]; [bytes appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
            Check(Write(path, bytes, 0), @"test-only alternate valid JSON tombstone spelling");
        } else if ([kind isEqual:@"boolean"]) { bad[@"allocationReserved"] = @0; Check(Write(path, bad, NSJSONWritingSortedKeys), @"test-only numeric false tombstone"); }
        else if ([kind isEqual:@"extra"]) { bad[@"authority"] = @YES; Check(Write(path, bad, NSJSONWritingSortedKeys), @"test-only extra tombstone key"); }
        else if ([kind isEqual:@"changed-full"]) {
            NSMutableDictionary *document = [original mutableCopy]; document[@"name"] = @"Different full retired content"; bad[@"configuration"] = document;
            Check(Write(path, bad, NSJSONWritingSortedKeys), @"test-only valid tombstone with different full document");
        } else if ([kind isEqual:@"symlink"]) {
            NSString *held = [path stringByAppendingString:@".held"];
            Check(!rename(path.fileSystemRepresentation, held.fileSystemRepresentation) && !symlink(held.fileSystemRepresentation, path.fileSystemRepresentation), @"test-only symlink leaf preserves original tombstone target");
        } else if ([kind isEqual:@"hardlink"]) Check(!link(path.fileSystemRepresentation, [path stringByAppendingString:@".held"].fileSystemRepresentation), @"test-only duplicate-link tombstone leaf");
        else Check(!chmod(path.fileSystemRepresentation, 0640), @"test-only unsafe tombstone permissions");
        NSDictionary *before = Snapshot(f.statePath), *record = Snapshot(path); NSDictionary *reply = Call(f.owner, @"reconcile-retire", Token(slot));
        Check(([@[@"unconfirmed", @"conflict"] containsObject:reply[@"result"]]) && [Snapshot(f.statePath) isEqual:before] && [Snapshot(path) isEqual:record], @"malformed unsafe or different full tombstone never confirms clears adopts or repairs pending retirement");
    }
}

static void HeldProofTests(NSString *base) {
    RetirementFixture *f = NewFixture(base, @"held-proof"); NSDictionary *original = Save(f, @"Held strict retired proof");
    Check(DirectRetire(f, original), @"actual strict retired backing record for trusted callback");
    NSDictionary *before = Snapshot(Record(f, original)); LBXContainerConfiguration *configuration = Configuration(original);
    double deadline = LBXLicenseIPCClock()+3; __block BOOL entered = NO; __block NSDictionary *escapedContext;
    Check([f.source performSourceOperation:^BOOL(NSError **error) {
        return [f.store performWithExactRetirement:configuration inCurrentSourceOperationBeforeDeadline:deadline
            operation:^BOOL(NSDictionary *context, __unused NSError **proofError) {
                entered = YES; escapedContext = context;
                int fd = open([f.configPath stringByAppendingPathComponent:@"configuration.lock"].fileSystemRepresentation, O_RDWR|O_NOFOLLOW);
                errno = 0; int locked = fd < 0 ? 0 : flock(fd, LOCK_EX|LOCK_NB); int reason = errno;
                Check(fd >= 0 && locked < 0 && reason == EWOULDBLOCK, @"exact retirement callback pins actual configuration flock");
                if (fd >= 0) { if (!locked) flock(fd, LOCK_UN); close(fd); }
                Check([[f.store configurationNamespaceContextInCurrentSourceOperationBeforeDeadline:deadline error:nil] isEqual:context], @"held retirement proof permits exact read-only namespace observation");
                Check(![f.store configurationNamespaceContextInCurrentSourceOperationBeforeDeadline:deadline+1 error:nil], @"held namespace observation cannot widen original deadline");
                BOOL absent = NO;
                Check(![f.store configurationWithIdentifier:configuration.identifier absent:&absent inCurrentSourceOperationBeforeDeadline:deadline error:nil] && !absent, @"held retirement proof grants no active read or absence");
                Check(![f.store configurationsInCurrentSourceOperationBeforeDeadline:deadline error:nil], @"held retirement proof grants no recursive active inventory");
                Check(![f.store isConfigurationEditable:configuration inCurrentSourceOperationBeforeDeadline:deadline error:nil], @"strict retired proof never grants editability");
                Check(![f.store retireConfiguration:configuration inCurrentSourceOperationBeforeDeadline:deadline error:nil], @"retirement publication recursion refused inside held proof");
                Check(![f.store commitConfiguration:configuration replacing:nil inCurrentSourceOperationBeforeDeadline:deadline error:nil], @"active commit recursion refused inside held retirement proof");
                Check(![f.store reserveConfigurationForClosedAllocation:configuration beforeDeadline:deadline error:nil], @"held proof grants no allocation reservation");
                __block BOOL recursive = NO;
                Check(![f.store performWithExactConfiguration:configuration inCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *nested, __unused NSError **nestedError) { recursive = YES; return YES; } error:nil] && !recursive, @"active proof callback cannot recurse from retired proof");
                Check(![f.store performWithExactRetirement:configuration inCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *nested, __unused NSError **nestedError) { recursive = YES; return YES; } error:nil] && !recursive, @"retirement proof callback cannot recurse or transfer lock authority");
                return YES;
            } error:error];
    } beforeDeadline:deadline error:nil] && entered && escapedContext && [Snapshot(Record(f, original)) isEqual:before], @"bounded read-only retired callback retains exact tombstone bytes and inode");
    __block BOOL outside = NO;
    Check(![f.store performWithExactRetirement:configuration inCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *context, __unused NSError **error) { outside = YES; return YES; } error:nil] && !outside,
        @"escaped namespace data does not supply a current source fence");

    for (NSString *kind in @[@"full-document-drift", @"lock-replaced", @"source-expired", @"callback-failed"]) {
        RetirementFixture *caseFixture = NewFixture(base, [@"held-" stringByAppendingString:kind]);
        NSDictionary *document = Save(caseFixture, @"Retired callback final checks"); Check(DirectRetire(caseFixture, document), @"strict tombstone before final callback checks");
        NSString *path = Record(caseFixture, document); NSDictionary *recordBefore = Snapshot(path); __block BOOL effect = NO;
        __block double wall = NSDate.date.timeIntervalSince1970, continuous = Continuous();
        if ([kind isEqual:@"source-expired"]) {
            [caseFixture.source testUseAuthorizationClock:^double(BOOL monotonic) { return monotonic ? continuous : wall; }]; Authorize(caseFixture.source);
        }
        double caseDeadline = LBXLicenseIPCClock()+3;
        BOOL succeeded = [caseFixture.source performSourceOperation:^BOOL(NSError **error) {
            return [caseFixture.store performWithExactRetirement:Configuration(document) inCurrentSourceOperationBeforeDeadline:caseDeadline
                operation:^BOOL(__unused NSDictionary *context, __unused NSError **proofError) {
                    effect = YES;
                    if ([kind isEqual:@"full-document-drift"]) {
                        NSMutableDictionary *record = [Read(path) mutableCopy], *different = [document mutableCopy];
                        different[@"name"] = @"Root fixture mutation during held callback"; record[@"configuration"] = different;
                        Check(Write(path, record, NSJSONWritingSortedKeys), @"test-only full-record mutation during synchronous proof callback");
                    } else if ([kind isEqual:@"lock-replaced"]) {
                        NSString *lock = [caseFixture.configPath stringByAppendingPathComponent:@"configuration.lock"];
                        Check(!rename(lock.fileSystemRepresentation, [lock stringByAppendingString:@".held"].fileSystemRepresentation), @"test-only original locked inode retained");
                        int fd = open(lock.fileSystemRepresentation, O_CREAT|O_EXCL|O_RDWR, 0600);
                        Check(fd >= 0, @"test-only replacement lock inode"); if (fd >= 0) close(fd);
                    } else if ([kind isEqual:@"source-expired"]) { wall += 65; continuous += 65; }
                    return ![kind isEqual:@"callback-failed"];
                } error:error];
        } beforeDeadline:caseDeadline error:nil];
        Check(!succeeded && effect, @"post-callback full record namespace signed fence or callback failure cannot become success");
        if ([kind isEqual:@"full-document-drift"]) Check(![Snapshot(path) isEqual:recordBefore] && [Read(path)[@"configuration"][@"name"] isEqual:@"Root fixture mutation during held callback"], @"failed final proof preserves observed callback effect instead of resetting record");
        else Check([Snapshot(path) isEqual:recordBefore], @"other callback failure retains original exact tombstone bytes and inode");
        if ([kind isEqual:@"callback-failed"]) {
            Authorize(caseFixture.source); double retryDeadline = LBXLicenseIPCClock()+3;
            Check([caseFixture.source performSourceOperation:^BOOL(NSError **error) {
                return [caseFixture.store performWithExactRetirement:Configuration(document) inCurrentSourceOperationBeforeDeadline:retryDeadline
                    operation:^BOOL(__unused NSDictionary *context, __unused NSError **proofError) { return YES; } error:error];
            } beforeDeadline:retryDeadline error:nil], @"callback failure releases proof scope and flock for fresh exact retry");
        }
    }
}

int main(void) {
    @autoreleasepool {
        char path[] = "/tmp/socialbox-root-retirement.XXXXXX";
        Check(mkdtemp(path) != NULL, @"real private host fixture parent");
        NSString *base = [[NSString stringWithUTF8String:path] stringByResolvingSymlinksInPath];
        Check(!chown(base.fileSystemRepresentation, getuid(), getegid()) && !chmod(base.fileSystemRepresentation, 0700), @"fixture parent matches strict synthetic host role");
        LifecycleTests(base); OlderPendingTests(base); PendingRestartTests(base); EligibilityTests(base); TypedBoundaryTests(base);
        PendingPublicationTests(base); TombstoneDenialTests(base); HeldProofTests(base);
        [NSFileManager.defaultManager removeItemAtPath:base error:nil];
        NSLog(@"%@: %lu root retirement assertions, %lu failures (signed synthetic source + actual temporary files; no device or provisioning acceptance)",
            failures ? @"FAIL" : @"PASS", (unsigned long)checks, (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
