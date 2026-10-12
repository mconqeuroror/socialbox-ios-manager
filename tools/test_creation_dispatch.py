"""Run the shipped daemon creation-draft handlers with inert service providers.

The authority store and handler bodies are real. Source/Keychain/cloud/region and
registry providers are controlled fixtures: this proves dispatch boundaries, not
on-device source decryption, proxy routing, or clone isolation. The registry's
generation and clone-commit behavior have separate native tests.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "daemon/main.m").read_text()
start = source.index("static NSDictionary *creationDraftBinding(")
end = source.index("static void rotateDarwinCallback(", start)
handlers = source[start:end]

fixture = r'''
#import <Foundation/Foundation.h>
#import "RBXCreationDraftStore.h"
#import "RBXAppRegistry.h"
#import "RBXProfileMetadata.h"

static NSMutableDictionary *sCreationDrafts;
static NSDictionary *Source, *Configuration, *Region, *Receipt, *PrivateEditor, *LastChoices;
static NSString *Server, *Account;
static BOOL Decrypted, ConfigFailure, Allowed, ContextOK, PrepareFailure, EditFailure, SaveFailure;
static NSUInteger Checks, GeoCalls, PrepareCalls, EditCalls, EditorWrites;
static NSUInteger CloneWrites, MetadataWrites, CloudCalls, StatePublications;
static BOOL RegistryCreateFailure, MetadataFailure, Paired, CloudFailure;
static NSDictionary *CreatedArguments, *MetadataArguments;
static NSString *ExpectedToken;
static void (^DuringGeo)(void);
static NSDictionary *PersistedProfiles;
static NSError *Failure(void) { return RBXCreationDraftError(@"Fixture provider unavailable"); }
static void Check(BOOL ok, NSString *reason) {
    Checks++; if (!ok) { fprintf(stderr, "FAIL: %s\n", reason.UTF8String); exit(1); }
}

@interface RBXOperationContext : NSObject
+ (instancetype)currentContext;
- (BOOL)check:(NSError **)error;
@end
@implementation RBXOperationContext
+ (instancetype)currentContext { static id value; if (!value) value=[self new]; return value; }
- (BOOL)check:(NSError **)error { if (!ContextOK && error) *error=Failure(); return ContextOK; }
@end

@interface RBXCloneManager : NSObject
- (instancetype)initWithAppType:(NSString *)type operationContext:(RBXOperationContext *)context;
- (NSDictionary *)creationSourceBinding;
- (NSDictionary *)sourceStatus;
@end
@implementation RBXCloneManager
- (instancetype)initWithAppType:(NSString *)type operationContext:(RBXOperationContext *)context { return [super init]; }
- (NSDictionary *)creationSourceBinding { return Source; }
- (NSDictionary *)sourceStatus { return @{@"decrypted":@(Decrypted)}; }
@end

@interface RBXSecureConfig : NSObject
+ (NSDictionary *)rotationConfiguration:(NSError **)error;
+ (BOOL)saveIdentityEditorDraft:(NSDictionary *)draft requestID:(NSString *)requestID error:(NSError **)error;
@end
@implementation RBXSecureConfig
+ (NSDictionary *)rotationConfiguration:(NSError **)error {
    if (ConfigFailure) { if (error) *error=Failure(); return nil; } return Configuration;
}
+ (BOOL)saveIdentityEditorDraft:(NSDictionary *)draft requestID:(NSString *)requestID error:(NSError **)error {
    if (SaveFailure) { if (error) *error=Failure(); return NO; }
    EditorWrites++; PrivateEditor=RBXCreationImmutableCopy(draft); return YES;
}
@end

@interface RBXCloudSync : NSObject
+ (instancetype)sharedSync;
@property (readonly) NSString *serverURL;
@property (readonly) NSString *deviceToken;
@property (readonly) BOOL paired;
- (void)syncProfileInventoryWithContext:(RBXOperationContext *)context completion:(void (^)(BOOL, NSString *))completion;
@end
@implementation RBXCloudSync
+ (instancetype)sharedSync { static id value; if (!value) value=[self new]; return value; }
- (NSString *)serverURL { return Server; }
- (NSString *)deviceToken { return Account; }
- (BOOL)paired { return Paired; }
- (void)syncProfileInventoryWithContext:(RBXOperationContext *)context completion:(void (^)(BOOL, NSString *))completion {
    CloudCalls++; completion(!CloudFailure,CloudFailure ? @"Fixture cloud unavailable" : @"Synchronized");
}
@end

@interface RBXProfileIO : NSObject
+ (BOOL)isSafeContainerIdentifier:(id)container;
@end
@implementation RBXProfileIO
+ (BOOL)isSafeContainerIdentifier:(id)container {
    return [container isKindOfClass:NSString.class] && [container length] > 0 &&
        [container rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyz0123456789-"] invertedSet]].location == NSNotFound;
}
@end

@interface FixtureRegistry : NSObject
- (BOOL)canCreateContainerForAppType:(NSString *)app error:(NSError **)error;
- (NSDictionary *)prepareCreationForContainer:(NSString *)cid appType:(NSString *)app proxyCountry:(NSString *)country regionSuggestion:(NSDictionary *)region error:(NSError **)error;
- (NSDictionary *)creationProfileByApplyingChoices:(NSDictionary *)choices toPreparedProfile:(NSDictionary *)envelope error:(NSError **)error;
- (NSDictionary *)creationIdentityEditorDraftForProfile:(NSDictionary *)profile error:(NSError **)error;
- (NSString *)createContainerWithId:(NSString *)cid appType:(NSString *)app proxyCountry:(NSString *)country proxyURL:(NSString *)url nickname:(NSString *)nickname regionSuggestion:(NSDictionary *)region preparedProfile:(NSDictionary *)prepared error:(NSError **)error;
- (BOOL)updateMetadata:(NSDictionary *)metadata forContainer:(NSString *)cid local:(BOOL)local error:(NSError **)error;
- (BOOL)discardMetadataChangesForContainer:(NSString *)cid error:(NSError **)error;
- (BOOL)deleteContainer:(NSString *)cid error:(NSError **)error;
@end
@implementation FixtureRegistry
- (BOOL)canCreateContainerForAppType:(NSString *)app error:(NSError **)error {
    BOOL result=Allowed && RBXAppDescriptorForType(app); if (!result && error) *error=Failure(); return result;
}
- (NSDictionary *)prepareCreationForContainer:(NSString *)cid appType:(NSString *)app proxyCountry:(NSString *)country regionSuggestion:(NSDictionary *)region error:(NSError **)error {
    PrepareCalls++;
    if (PrepareFailure) { if (error) *error=Failure(); return nil; }
    return @{@"formatVersion":@1, @"preparedAt":@(NSDate.date.timeIntervalSince1970),
        @"profile":@{@"containerId":cid,@"appType":app,@"secretIdentifier":@"PRIVATE-ID-NEVER-IN-RECEIPT",@"country":country,@"model":@"baseline"},
        @"review":@{@"model":@"baseline",@"country":country}};
}
- (NSDictionary *)creationProfileByApplyingChoices:(NSDictionary *)choices toPreparedProfile:(NSDictionary *)envelope error:(NSError **)error {
    EditCalls++; LastChoices=choices;
    if (EditFailure) { if (error) *error=Failure(); return nil; }
    NSMutableDictionary *updated=[envelope mutableCopy], *profile=[envelope[@"profile"] mutableCopy], *review=[envelope[@"review"] mutableCopy];
    NSString *model=[choices[@"mode"] isEqual:@"random"] ? @"randomized" : choices[@"model"] ?: @"edited";
    profile[@"model"]=model; review[@"model"]=model;
    updated[@"profile"]=profile; updated[@"review"]=review; return updated;
}
- (NSDictionary *)creationIdentityEditorDraftForProfile:(NSDictionary *)profile error:(NSError **)error {
    return profile ? @{@"profile":profile} : nil;
}
- (NSString *)createContainerWithId:(NSString *)cid appType:(NSString *)app proxyCountry:(NSString *)country proxyURL:(NSString *)url nickname:(NSString *)nickname regionSuggestion:(NSDictionary *)region preparedProfile:(NSDictionary *)prepared error:(NSError **)error {
    CloneWrites++;
    Check(!ExpectedToken || !sCreationDrafts[ExpectedToken],@"review token consumed before registry clone side effects");
    CreatedArguments=@{@"container":cid ?: @"",@"appType":app,@"country":country,@"proxyURL":url,@"nickname":nickname ?: @"",@"region":region ?: NSNull.null,@"prepared":prepared ?: NSNull.null};
    if (RegistryCreateFailure) { if (error) *error=Failure(); return nil; }
    NSMutableDictionary *persisted=PersistedProfiles.mutableCopy; persisted[cid]=CreatedArguments; PersistedProfiles=persisted;
    return cid;
}
- (BOOL)updateMetadata:(NSDictionary *)metadata forContainer:(NSString *)cid local:(BOOL)local error:(NSError **)error {
    MetadataWrites++; MetadataArguments=metadata;
    if (MetadataFailure) { if (error) *error=Failure(); return NO; } return YES;
}
- (BOOL)discardMetadataChangesForContainer:(NSString *)cid error:(NSError **)error { Check(NO,@"unrelated metadata discard not called"); return NO; }
- (BOOL)deleteContainer:(NSString *)cid error:(NSError **)error { Check(NO,@"unrelated delete not called"); return NO; }
@end
static FixtureRegistry *sRegistry;

@interface FixtureProxies : NSObject
- (void)detectRegionForContainer:(NSString *)cid context:(RBXOperationContext *)context completion:(void (^)(NSDictionary *))completion;
@end
@implementation FixtureProxies
- (void)detectRegionForContainer:(NSString *)cid context:(RBXOperationContext *)context completion:(void (^)(NSDictionary *))completion {
    GeoCalls++; if (DuringGeo) DuringGeo(); completion(Region);
}
@end
static FixtureProxies *sProxies;

@interface RBXReplacement : NSObject
+ (NSString *)replaceContainer:(NSString *)cid registry:(id)registry proxies:(id)proxies context:(RBXOperationContext *)context error:(NSError **)error;
+ (BOOL)userDeletionAllowedForContainer:(NSString *)cid error:(NSError **)error;
@end
@implementation RBXReplacement
+ (NSString *)replaceContainer:(NSString *)cid registry:(id)registry proxies:(id)proxies context:(RBXOperationContext *)context error:(NSError **)error { Check(NO,@"unrelated replacement not called"); return nil; }
+ (BOOL)userDeletionAllowedForContainer:(NSString *)cid error:(NSError **)error { Check(NO,@"unrelated delete admission not called"); return NO; }
@end
@interface RBXLauncherState : NSObject
+ (void)publishWithRegistry:(id)registry;
@end
@implementation RBXLauncherState
+ (void)publishWithRegistry:(id)registry { StatePublications++; }
@end

static void dispatchRequest(NSDictionary *pending, void (^block)(void)) { block(); }
static NSDictionary *waitForOperationReply(void (^request)(void (^)(NSDictionary *))) {
    __block NSDictionary *reply; request(^(NSDictionary *value){reply=value;}); return reply;
}
static NSDictionary *waitForCloudOperation(void (^request)(void (^)(BOOL, NSString *))) {
    __block NSDictionary *reply; request(^(BOOL ok,NSString *message){reply=@{@"ok":@(ok),@"message":message ?: @""};}); return reply;
}
static void completeRequest(NSDictionary *pending, BOOL ok, NSString *message, NSDictionary *details) {
    Receipt=@{@"ok":@(ok),@"message":message ?: @"",@"details":details ?: @{}};
    Check(![Receipt.description containsString:@"PRIVATE-"],@"receipt never includes identifier/proxy/account secrets");
}
static void publishLauncherOperation(NSDictionary *pending,NSString *action,NSString *cid,BOOL ok,NSString *message) {
    completeRequest(pending,ok,message,@{@"containerId":cid ?: @"",@"action":action});
}

__HANDLERS__

static void Reset(void) {
    sCreationDrafts=[NSMutableDictionary dictionary];
    Source=@{@"sourceHash":@"source-1",@"bundle":@"com.reddit.Reddit",@"revision":@1};
    Configuration=@{@"proxyURL":@"http://user:PRIVATE-PROXY@127.0.0.1:8080",@"selectedProxyId":@"proxy-a",@"updatedAt":@1,@"proxyDisabled":@NO};
    Region=@{@"ok":@YES,@"country":@"US"}; Server=@"https://fixture.invalid"; Account=@"PRIVATE-ACCOUNT";
    Decrypted=Allowed=ContextOK=YES; ConfigFailure=PrepareFailure=EditFailure=SaveFailure=NO;
    GeoCalls=PrepareCalls=EditCalls=EditorWrites=0; Receipt=PrivateEditor=LastChoices=nil; DuringGeo=nil;
    CloneWrites=MetadataWrites=CloudCalls=StatePublications=0;
    RegistryCreateFailure=MetadataFailure=Paired=CloudFailure=NO;
    CreatedArguments=MetadataArguments=nil; ExpectedToken=nil;
    PersistedProfiles=@{@"existing":@{@"identity":@"unchanged"}};
}
static NSDictionary *Prepare(NSDictionary *extra) {
    NSMutableDictionary *pending=[@{@"action":@"prepareContainer",@"container":@"draft-1",@"nickname":@"My container",@"role":@"default",@"appType":@"reddit",@"requestId":NSUUID.UUID.UUIDString} mutableCopy];
    [pending addEntriesFromDictionary:extra ?: @{}]; Receipt=nil;
    handleCreationDraftAction(pending);
    return Receipt;
}
static NSDictionary *Request(NSString *action, NSDictionary *review, NSDictionary *extra) {
    NSMutableDictionary *pending=[@{@"action":action,@"container":review[@"containerId"] ?: @"draft-1",@"appType":review[@"appType"] ?: @"reddit",@"requestId":NSUUID.UUID.UUIDString} mutableCopy];
    if (review[@"creationDraftToken"]) pending[@"creationDraftToken"]=review[@"creationDraftToken"];
    if (review[@"creationDraftRevision"]) pending[@"creationDraftRevision"]=review[@"creationDraftRevision"];
    [pending addEntriesFromDictionary:extra ?: @{}]; Receipt=nil;
    if ([action isEqual:@"createContainer"]) handleContainerAction(pending); else handleCreationDraftAction(pending);
    return Receipt;
}
static NSDictionary *PreparedReview(void) {
    NSDictionary *receipt=Prepare(nil); Check([receipt[@"ok"] boolValue],@"fixture prepared through real handler"); return receipt[@"details"];
}
static NSDictionary *Record(NSDictionary *review) { return sCreationDrafts[review[@"creationDraftToken"]]; }
static void CheckNoCloneWrites(void) {
    Check(!CloneWrites && !MetadataWrites && !CloudCalls && !StatePublications &&
        [PersistedProfiles isEqual:@{@"existing":@{@"identity":@"unchanged"}}],@"draft-only provider methods leave persisted profiles untouched");
}

int main(void) { @autoreleasepool {
    sRegistry=[FixtureRegistry new]; sProxies=[FixtureProxies new]; Reset();
    NSDictionary *review=PreparedReview();
    Check(sCreationDrafts.count==1 && GeoCalls==1 && PrepareCalls==1 && !EditorWrites,@"prepare stores one draft and no private editor write");
    Check([review[@"creationDraftRevision"] isEqual:@1] && [review[@"review"][@"country"] isEqual:@"US"],@"prepare emits safe revision and verified country");
    Check([Record(review)[@"metadata"][@"nickname"] isEqual:@"My container"],@"review binds original creation metadata");
    Check(!review[@"profile"] && !review[@"binding"] && !review[@"proxyURL"],@"public receipt excludes profile and authority binding");
    CheckNoCloneWrites();

    // The simple wizard selects a specific secure-configuration revision before
    // enqueue. A later queue execution must not silently use a different proxy.
    Reset();
    NSMutableDictionary *laterConfiguration=Configuration.mutableCopy;
    laterConfiguration[@"updatedAt"]=@2;
    laterConfiguration[@"proxyURL"]=@"http://other:PRIVATE-NEW-PROXY@127.0.0.1:8080";
    Configuration=laterConfiguration;
    Check(![Prepare(@{@"proxyConfigurationUpdatedAt":@1})[@"ok"] boolValue] &&
        GeoCalls==0 && PrepareCalls==0 && !sCreationDrafts.count,
        @"queued preview rejects changed selected proxy before outbound geography lookup");
    CheckNoCloneWrites();
    for (id invalid in @[@"2",@YES,@0,@-1,@3,NSNull.null]) {
        Reset();
        Check(![Prepare(@{@"proxyConfigurationUpdatedAt":invalid})[@"ok"] boolValue] && !GeoCalls && !PrepareCalls,
            @"invalid or stale proxy expectation cannot start geography lookup");
    }
    Reset();
    Check([Prepare(@{@"proxyConfigurationUpdatedAt":@1})[@"ok"] boolValue] && GeoCalls==1,
        @"matching selected proxy revision prepares normally");

    for (NSString *kind in @[@"source",@"configuration",@"selection",@"timestamp",@"account",@"cloud",@"disabled",@"encrypted",@"read-failure"]) {
        Reset(); review=PreparedReview();
        if ([kind isEqual:@"source"]) Source=@{@"sourceHash":@"source-2"};
        if ([kind isEqual:@"configuration"]) Configuration=@{@"proxyURL":@"http://different.invalid:8080"};
        if ([kind isEqual:@"selection"] || [kind isEqual:@"timestamp"] || [kind isEqual:@"disabled"]) {
            NSMutableDictionary *value=[Configuration mutableCopy];
            if ([kind isEqual:@"selection"]) value[@"selectedProxyId"]=@"same-endpoint-other-proxy";
            if ([kind isEqual:@"timestamp"]) value[@"updatedAt"]=@2;
            if ([kind isEqual:@"disabled"]) value[@"proxyDisabled"]=@YES;
            Configuration=value;
        }
        if ([kind isEqual:@"account"]) Account=@"PRIVATE-OTHER-ACCOUNT";
        if ([kind isEqual:@"cloud"]) Server=@"https://other.invalid";
        if ([kind isEqual:@"encrypted"]) Decrypted=NO;
        if ([kind isEqual:@"read-failure"]) ConfigFailure=YES;
        Check(![Request(@"reviewContainerDraft",review,nil)[@"ok"] boolValue], [@"authority change invalidates review: " stringByAppendingString:kind]);
        Check(![Request(@"applyIdentity",review,@{@"choices":@{@"model":@"should-not-apply"}})[@"ok"] boolValue] && EditCalls==0 && EditorWrites==0,@"invalidated review cannot mutate draft or editor");
    }

    for (NSString *kind in @[@"no-source",@"encrypted",@"disabled",@"read-failure",@"unregistered",@"admission",@"bad-id",@"bad-name",@"bad-role"]) {
        Reset(); NSDictionary *extra=@{};
        if ([kind isEqual:@"no-source"]) Source=nil;
        if ([kind isEqual:@"encrypted"]) Decrypted=NO;
        if ([kind isEqual:@"disabled"]) Configuration=@{@"proxyDisabled":@YES};
        if ([kind isEqual:@"read-failure"]) ConfigFailure=YES;
        if ([kind isEqual:@"unregistered"]) extra=@{@"appType":@"unknown"};
        if ([kind isEqual:@"admission"]) Allowed=NO;
        if ([kind isEqual:@"bad-id"]) extra=@{@"container":@"../unsafe"};
        if ([kind isEqual:@"bad-name"]) extra=@{@"nickname":@""};
        if ([kind isEqual:@"bad-role"]) extra=@{@"role":@"not-a-role"};
        Check(![Prepare(extra)[@"ok"] boolValue] && GeoCalls==0 && PrepareCalls==0 && !sCreationDrafts.count,[@"invalid preparation denied before proxy lookup: " stringByAppendingString:kind]);
    }

    for (NSString *kind in @[@"lookup-failure",@"lookup-timeout",@"country-mismatch",@"source-race",@"proxy-race",@"account-race",@"context-cancel",@"generator-failure"]) {
        Reset(); NSDictionary *extra=@{};
        if ([kind isEqual:@"lookup-failure"]) Region=@{@"ok":@NO,@"message":@"Proxy unavailable"};
        if ([kind isEqual:@"lookup-timeout"]) Region=nil;
        if ([kind isEqual:@"country-mismatch"]) extra=@{@"country":@"FR"};
        if ([kind isEqual:@"source-race"]) DuringGeo=^{Source=@{@"sourceHash":@"changed-during-lookup"};};
        if ([kind isEqual:@"proxy-race"]) DuringGeo=^{Configuration=@{@"proxyURL":@"http://changed.invalid:8080"};};
        if ([kind isEqual:@"account-race"]) DuringGeo=^{Account=@"PRIVATE-CHANGED";};
        if ([kind isEqual:@"context-cancel"]) DuringGeo=^{ContextOK=NO;};
        if ([kind isEqual:@"generator-failure"]) PrepareFailure=YES;
        Check(![Prepare(extra)[@"ok"] boolValue] && !sCreationDrafts.count && !EditorWrites,[@"preparation failure retains no authority: " stringByAppendingString:kind]);
        Check(GeoCalls==1,@"proxy lookup occurs once; no direct fallback retry");
        CheckNoCloneWrites();
    }

    Reset(); review=PreparedReview(); NSDictionary *original=Record(review);
    for (NSDictionary *scope in @[@{@"container":@"sibling"},@{@"appType":@"facebook"},@{@"creationDraftToken":@"forged"},@{@"creationDraftRevision":@0},@{@"creationDraftRevision":@2},@{@"creationDraftRevision":@"1"}]) {
        Check(![Request(@"loadIdentityEditor",review,scope)[@"ok"] boolValue] && !EditorWrites,@"scope/token/revision validation occurs before private editor write");
    }
    Check([Request(@"reviewContainerDraft",review,@{@"creationDraftRevision":@999})[@"ok"] boolValue],@"read-only review can reload latest revision");
    Check([Request(@"loadIdentityEditor",review,nil)[@"ok"] boolValue] && EditorWrites==1 && [PrivateEditor[@"profile"] isEqual:original[@"envelope"][@"profile"]],@"private editor uses daemon-held profile");
    Check([Record(review) isEqual:original],@"load and read-only review do not change draft");

    NSDictionary *preview=Request(@"previewIdentity",review,@{@"choices":@{@"model":@"chosen"},@"profile":@{@"secretIdentifier":@"FORGED"}});
    Check([preview[@"ok"] boolValue] && ![preview[@"details"][@"applied"] boolValue] && [preview[@"details"][@"summary"][@"model"] isEqual:@"chosen"],@"preview returns candidate summary without claiming save");
    Check([Record(review) isEqual:original],@"preview leaves authoritative envelope and revision unchanged");
    NSDictionary *applied=Request(@"applyIdentity",review,@{@"choices":@{@"model":@"chosen"}});
    Check([applied[@"ok"] boolValue] && [applied[@"details"][@"applied"] boolValue] && [applied[@"details"][@"creationDraftRevision"] isEqual:@2],@"apply changes only draft and increments revision");
    Check([Record(review)[@"envelope"][@"profile"][@"secretIdentifier"] isEqual:@"PRIVATE-ID-NEVER-IN-RECEIPT"],@"launcher cannot replace authoritative identity payload");
    Check([Record(review)[@"envelope"][@"preparedAt"] isEqual:original[@"envelope"][@"preparedAt"]],@"editing does not extend lifetime");
    NSUInteger before=EditCalls;
    Check(![Request(@"applyIdentity",review,@{@"choices":@{}})[@"ok"] boolValue] && EditCalls==before,@"stale write revision denied before registry edit");
    review=Request(@"reviewContainerDraft",review,nil)[@"details"];
    Check([review[@"creationDraftRevision"] isEqual:@2],@"parent review reload receives editor's updated revision");
    NSDictionary *random=Request(@"randomizeIdentityEditor",review,@{@"selection":@{@"automatic":@YES,@"model":@"requested"}});
    Check([random[@"ok"] boolValue] && [random[@"details"][@"creationDraftRevision"] isEqual:@3] && [LastChoices[@"mode"] isEqual:@"random"] && !LastChoices[@"automatic"],@"randomize uses bound-region choice path and writes next revision");
    Check([PrivateEditor[@"profile"][@"model"] isEqual:@"randomized"],@"randomized draft is available in private editor");
    CheckNoCloneWrites();

    review=random[@"details"]; original=Record(review); EditFailure=YES;
    Check(![Request(@"applyIdentity",review,@{@"choices":@{}})[@"ok"] boolValue] && [Record(review) isEqual:original],@"registry rejection keeps previous review intact");
    EditFailure=NO; SaveFailure=YES; before=EditorWrites;
    Check(![Request(@"loadIdentityEditor",review,nil)[@"ok"] boolValue] && EditorWrites==before,@"private editor write failure never reports ready");
    SaveFailure=NO; ContextOK=NO;
    Check(![Request(@"loadIdentityEditor",review,nil)[@"ok"] boolValue] && EditorWrites==before,@"cancelled operation never stores private editor");
    ContextOK=YES;
    Check([Request(@"discardContainerDraft",review,nil)[@"ok"] boolValue] && !sCreationDrafts.count,@"discard consumes draft without container changes");
    Check(![Request(@"reviewContainerDraft",review,nil)[@"ok"] boolValue],@"discarded token cannot replay");

    Reset(); review=PreparedReview();
    NSMutableDictionary *expired=[Record(review) mutableCopy], *old=[expired[@"envelope"] mutableCopy];
    old[@"preparedAt"]=@(NSDate.date.timeIntervalSince1970-301); expired[@"envelope"]=old;
    sCreationDrafts[review[@"creationDraftToken"]]=RBXCreationImmutableCopy(expired);
    Check(![Request(@"reviewContainerDraft",review,nil)[@"ok"] boolValue] && !sCreationDrafts.count,@"expired preview rejected and pruned by real request handler");
    Reset();
    Check([Prepare(@{@"country":@"us"})[@"ok"] boolValue],@"explicit matching country is normalized and accepted");
    CheckNoCloneWrites();
    Reset(); review=PreparedReview(); original=Record(review); ExpectedToken=review[@"creationDraftToken"];
    NSDictionary *created=Request(@"createContainer",review,@{@"nickname":@"Unreviewed name",@"role":@"spam",@"country":@"FR",@"notes":@"Unreviewed notes",@"autoRegion":@YES,@"preparedProfile":@{@"forged":@YES}});
    Check([created[@"ok"] boolValue]&&CloneWrites==1&&MetadataWrites==1&&StatePublications==1&&!sCreationDrafts.count,@"reviewed create commits once and consumes authority");
    Check([CreatedArguments[@"prepared"] isEqual:original[@"envelope"]]&&[CreatedArguments[@"nickname"] isEqual:@"My container"]&&[CreatedArguments[@"country"] isEqual:@"US"],@"create uses daemon-held envelope and reviewed metadata, ignoring client tampering");
    Check([MetadataArguments isEqual:@{@"role":@"default",@"notes":@""}],@"role and notes derive from reviewed metadata");
    Check(GeoCalls==1&&CreatedArguments[@"region"]==NSNull.null&&[CreatedArguments[@"proxyURL"] isEqual:@""],@"reviewed create neither reruns proxy lookup nor accepts client proxy authority");
    Check([PersistedProfiles[@"existing"] isEqual:@{@"identity":@"unchanged"}],@"create retains sibling profiles");
    Check(![Request(@"createContainer",review,nil)[@"ok"] boolValue]&&CloneWrites==1&&MetadataWrites==1,@"consumed token replay cannot clone again");

    for (NSString *kind in @[@"revision",@"account",@"source",@"proxy",@"expiry",@"admission",@"container",@"app"]) {
        Reset(); review=PreparedReview(); ExpectedToken=review[@"creationDraftToken"]; NSDictionary *extra=@{};
        if ([kind isEqual:@"revision"]) extra=@{@"creationDraftRevision":@2};
        if ([kind isEqual:@"account"]) Account=@"PRIVATE-ACCOUNT-CHANGED";
        if ([kind isEqual:@"source"]) Source=@{@"sourceHash":@"changed"};
        if ([kind isEqual:@"proxy"]) Configuration=@{@"proxyURL":@"http://different.invalid:80"};
        if ([kind isEqual:@"admission"]) Allowed=NO;
        if ([kind isEqual:@"container"]) extra=@{@"container":@"sibling"};
        if ([kind isEqual:@"app"]) extra=@{@"appType":@"facebook"};
        if ([kind isEqual:@"expiry"]) {
            NSMutableDictionary *expired=[Record(review) mutableCopy],*envelope=[expired[@"envelope"] mutableCopy];
            envelope[@"preparedAt"]=@(NSDate.date.timeIntervalSince1970-301);expired[@"envelope"]=envelope;sCreationDrafts[ExpectedToken]=expired;
        }
        Check(![Request(@"createContainer",review,extra)[@"ok"] boolValue]&&!CloneWrites&&!MetadataWrites&&!CloudCalls&&!StatePublications,[@"stale or inadmissible create blocked before mutation: " stringByAppendingString:kind]);
    }
    Reset(); review=PreparedReview(); ExpectedToken=review[@"creationDraftToken"]; RegistryCreateFailure=YES;
    Check(![Request(@"createContainer",review,nil)[@"ok"] boolValue]&&CloneWrites==1&&!MetadataWrites&&!CloudCalls&&!sCreationDrafts.count,@"failed registry create still consumes one-shot review before side effects");
    Check(!PersistedProfiles[@"draft-1"]&&[PersistedProfiles[@"existing"] isEqual:@{@"identity":@"unchanged"}],@"fixture failed create keeps previously committed profiles");
    RegistryCreateFailure=NO;
    Check(![Request(@"createContainer",review,nil)[@"ok"] boolValue]&&CloneWrites==1,@"failure cannot silently retry a consumed identity");
    Reset(); review=PreparedReview(); ExpectedToken=review[@"creationDraftToken"]; MetadataFailure=YES; Paired=YES;
    Check(![Request(@"createContainer",review,nil)[@"ok"] boolValue]&&PersistedProfiles[@"draft-1"]&&CloneWrites==1&&MetadataWrites==1&&!CloudCalls&&!sCreationDrafts.count,@"metadata failure retains created clone without retrying or claiming success");
    MetadataFailure=NO;
    Check(![Request(@"createContainer",review,nil)[@"ok"] boolValue]&&CloneWrites==1,@"partial-create replay blocked for inventory reconciliation");
    Reset(); review=PreparedReview(); ExpectedToken=review[@"creationDraftToken"]; Paired=CloudFailure=YES;
    Check([Request(@"createContainer",review,nil)[@"ok"] boolValue]&&CloneWrites==1&&CloudCalls==1&&PersistedProfiles[@"draft-1"]&&[Receipt[@"message"] containsString:@"created locally"],@"cloud failure retains successful local creation and reports pending sync");

    Reset();
    Check([Request(@"createContainer",@{},@{@"nickname":@"Legacy",@"country":@"GB",@"role":@"warmup",@"notes":@"existing path"})[@"ok"] boolValue],@"legacy no-token create still dispatches");
    Check(CreatedArguments[@"prepared"]==NSNull.null&&[CreatedArguments[@"nickname"] isEqual:@"Legacy"]&&[CreatedArguments[@"country"] isEqual:@"GB"]&&[MetadataArguments[@"role"] isEqual:@"warmup"]&&!GeoCalls&&!PrepareCalls,@"legacy arguments remain unchanged without new draft preparation");
    Reset();
    Check([Request(@"createContainer",@{},@{@"autoRegion":@YES})[@"ok"] boolValue]&&GeoCalls==1&&[CreatedArguments[@"region"] isEqual:Region],@"legacy explicit automatic region path retained");
    Reset();Region=@{@"ok":@NO,@"message":@"Unavailable"};
    Check(![Request(@"createContainer",@{},@{@"autoRegion":@YES})[@"ok"] boolValue]&&!CloneWrites,@"legacy failed region lookup still prevents create");
    printf("PASS actual creation dispatch: %lu checks; private authority, scope/revision/expiry, binding, draft-only edits, reviewed create consumption, replay/faults and legacy path.\n",(unsigned long)Checks);
}}
'''.replace("__HANDLERS__", handlers)

with tempfile.TemporaryDirectory(prefix="rbx-creation-dispatch-") as tmp:
    path = Path(tmp)
    (path / "test.m").write_text(fixture)
    subprocess.run([
        "xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
        "-Wno-unused-parameter", "-I" + str(ROOT / "shared"), "-I" + str(ROOT / "daemon"),
        "-framework", "Foundation", str(path / "test.m"), "-o", str(path / "test"),
    ], check=True)
    subprocess.run([str(path / "test")], check=True)
