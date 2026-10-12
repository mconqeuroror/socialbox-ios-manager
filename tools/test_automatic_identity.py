#!/usr/bin/env python3
"""Native behavior of shipped draft dispatch/registry, with inert I/O providers.

Real catalog, profile generator, candidate validation and draft methods execute.
Network/configuration/private publication/context are injected provider seams;
no device, network, user preferences, clone or real profile is touched.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
registry = (ROOT / "daemon/RBXContainerRegistry.m").read_text()
main = (ROOT / "daemon/main.m").read_text()


def extract(source, signature):
    start = source.index(signature)
    return source[start:source.index("\n}\n", start) + 3]


start = main.index('    if ([@[@"loadIdentityEditor", @"randomizeIdentityEditor"] containsObject:action]) {')
branch = main[start:main.index('    if ([action isEqualToString:@"previewIdentity"]', start)]
helpers = "\n".join(extract(main, signature) for signature in (
    "static NSDictionary *automaticIdentityInput(", "static NSDictionary *identityEditorDraftForRequest(") if signature in main)
methods = "\n".join(extract(registry, signature) for signature in (
    "- (BOOL)_checkIdentityChoices:", "- (NSDictionary *)_validatedIdentityCandidate:",
    "- (NSDictionary *)_identityCandidateForContainer:", "- (NSDictionary *)_identityCandidateForProfile:",
    "- (NSDictionary *)privateIdentityEditorDraftForContainer:") )
signature = "- (NSDictionary *)privateIdentityEditorDraftForContainer:(NSString *)containerId randomize:(BOOL)randomize selection:(NSDictionary *)selection regionSuggestion:"
if signature in registry:
    methods += "\n" + extract(registry, signature)

fixture = r'''
#import <Foundation/Foundation.h>
#import "RBXProfileGenerator.h"
#import "RBXConsistencyValidator.h"
#import "RBXProfileIO.h"
#import "RBXAppRegistry.h"
#import "RBXAppAdmission.h"
#import "RBXMGOverrides.h"
#define RBX_CATALOG_TESTING 1
#include "RBXDeviceCatalog.m"
#import "RBXProxyRegion.h"
static NSUInteger checks, failures, publications, lookups;
static NSDictionary *privateDraft, *receipt, *providerReply, *generatedProfile;
static NSMutableDictionary *configuration;
static BOOL cancelAfterLookup, changeProxyAfterLookup, freezeAfterLookup, contextAllowed = YES;
static void Check(BOOL ok, NSString *message) {
    checks++; if (!ok) { failures++; fprintf(stderr,"FAIL automatic identity: %s\n",message.UTF8String); }
}
static NSError *RBXDeletionError(NSString *message) {
    return [NSError errorWithDomain:@"fixture" code:400 userInfo:@{NSLocalizedDescriptionKey:message}];
}
__VALUE__
@interface FixtureRegistry : NSObject
@property NSDictionary *original;
@property BOOL locked;
@property NSArray *siblings;
- (NSDictionary *)identityEditorStateForContainer:(NSString *)container error:(NSError **)error;
- (NSDictionary *)privateIdentityEditorDraftForContainer:(NSString *)container randomize:(BOOL)randomize selection:(NSDictionary *)selection error:(NSError **)error;
- (NSDictionary *)privateIdentityEditorDraftForContainer:(NSString *)container randomize:(BOOL)randomize selection:(NSDictionary *)selection regionSuggestion:(NSDictionary *)region error:(NSError **)error;
@end
static FixtureRegistry *sRegistry;
@implementation FixtureRegistry
- (NSDictionary *)_load:(NSString *)container error:(NSError **)error { return self.original; }
- (NSArray *)_otherProfilesExcluding:(NSString *)container error:(NSError **)error { return self.siblings ?: @[]; }
- (NSDictionary *)identityEditorStateForContainer:(NSString *)container error:(NSError **)error {
    NSDictionary *d = self.original[@"device"];
    return @{@"containerId":container,@"locked":@(self.locked),@"lockReason":@"Identity is frozen",
        @"proxyAssigned":@([self.original[@"proxy"][@"url"] length] > 0),
        @"productType":d[@"productType"],@"iosVersion":d[@"iosVersion"],@"country":d[@"regionCode"],
        @"proxyCountry":self.original[@"proxy"][@"country"],@"security":self.original[@"security"]};
}
__METHODS__
@end
@interface RBXOperationContext : NSObject
+ (instancetype)currentContext;
- (BOOL)check:(NSError **)error;
@end
@implementation RBXOperationContext
+ (instancetype)currentContext { static RBXOperationContext *context; if (!context) context=[self new]; return context; }
- (BOOL)check:(NSError **)error { if (!contextAllowed && error) *error=RBXDeletionError(@"Canceled fixture operation"); return contextAllowed; }
@end
@interface FixtureProfileIO : NSObject
+ (NSDictionary *)loadProfileForContainer:(NSString *)container error:(NSError **)error;
@end
@implementation FixtureProfileIO
+ (NSDictionary *)loadProfileForContainer:(NSString *)container error:(NSError **)error { return sRegistry.original; }
@end
@interface RBXSecureConfig : NSObject
+ (NSDictionary *)rotationConfiguration:(NSError **)error;
+ (NSDictionary *)effectiveRotationConfiguration:(NSDictionary *)configuration;
+ (BOOL)saveIdentityEditorDraft:(NSDictionary *)draft requestID:(NSString *)request error:(NSError **)error;
@end
@implementation RBXSecureConfig
+ (NSDictionary *)rotationConfiguration:(NSError **)error { return [configuration copy]; }
+ (NSDictionary *)effectiveRotationConfiguration:(NSDictionary *)value { return value; }
+ (BOOL)saveIdentityEditorDraft:(NSDictionary *)draft requestID:(NSString *)request error:(NSError **)error { publications++; privateDraft=draft; return YES; }
@end
@interface FixtureProxies : NSObject
- (void)detectRegionForContainer:(NSString *)container context:(RBXOperationContext *)context completion:(void (^)(NSDictionary *))done;
@end
@implementation FixtureProxies
- (void)detectRegionForContainer:(NSString *)container context:(RBXOperationContext *)context completion:(void (^)(NSDictionary *))done {
    lookups++;
    if (cancelAfterLookup) contextAllowed=NO;
    if (changeProxyAfterLookup) configuration[@"proxyURL"]=@"http://changed.invalid:8080";
    if (freezeAfterLookup) sRegistry.locked=YES;
    done(providerReply);
}
@end
static FixtureProxies *sProxies;
static NSDictionary *waitForOperationReply(void (^start)(void (^)(NSDictionary *))) {
    __block NSDictionary *result; start(^(NSDictionary *reply){result=reply;}); return result;
}
static void dispatchRequest(NSDictionary *pending, void (^block)(void)) { block(); }
static void completeRequest(NSDictionary *pending, BOOL ok, NSString *message, NSDictionary *details) {
    receipt=@{@"ok":@(ok),@"message":message ?: @"",@"details":details ?: @{}};
}
#define RBXProfileIO FixtureProfileIO
__HELPERS__
#undef RBXProfileIO
static void Execute(NSDictionary *pending) {
    NSString *block=RBXAppRequestBlockReason(pending,@[sRegistry.original]);
    if (block) { completeRequest(pending,NO,block,@{}); return; }
    NSString *action=pending[@"action"];
__BRANCH__
}
static NSDictionary *Request(NSDictionary *selection) {
    return @{@"action":@"randomizeIdentityEditor",@"container":@"auto-fixture",@"requestId":@"private-request",@"appType":@"reddit",@"selection":selection};
}
static void Reset(void) {
    publications=lookups=0; receipt=nil; cancelAfterLookup=changeProxyAfterLookup=freezeAfterLookup=NO; contextAllowed=YES;
    sRegistry.locked=NO; configuration=[@{@"proxyURL":@"http://selected.invalid:8080",@"updatedAt":@1} mutableCopy];
}
int main(int argc, char **argv) { @autoreleasepool {
    RBXCatalogTestPaths=@[[NSString stringWithUTF8String:argv[1]]];
    sRegistry=[FixtureRegistry new]; sProxies=[FixtureProxies new];
    NSMutableDictionary *original=[[RBXProfileGenerator generateProfileForContainerId:@"auto-fixture" proxyCountry:@"US"
        existingProfiles:@[] productType:@"iPhone18,1" iosVersion:@"26.6.2" error:nil] mutableCopy];
    NSMutableDictionary *security=[original[@"security"] mutableCopy]; security[@"systemClipboard"]=@"enabled"; security[@"keychainSync"]=@"local-only"; original[@"security"]=security;
    sRegistry.original=original;
    NSDictionary *snapshot=[NSPropertyListSerialization propertyListWithData:[NSPropertyListSerialization dataWithPropertyList:original format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil] options:0 format:nil error:nil];
    NSMutableDictionary *region=[RBXProxyRegionSuggestion(@{@"ip":@"203.0.113.10",@"country":@"DE",@"timezone":@"Europe/Berlin",@"city":@"Berlin"},nil) mutableCopy];
    Check(region != nil, @"fixture uses a supported observed region");
    region[@"ok"]=@YES; region[@"proxySource"]=@"selected-device"; providerReply=region;
    Reset(); Execute(Request(@{@"automatic":@YES}));
    Check(lookups==1,@"automatic action must obtain live daemon proxy evidence");
    Check(publications==1 && [receipt[@"ok"] isEqual:@YES],@"valid automatic result publishes exactly one private draft");
    Check([privateDraft[@"country"] isEqual:@"DE"] && [privateDraft[@"timezone"] isEqual:@"Europe/Berlin"] &&
        [privateDraft[@"city"] isEqual:@"Berlin"] && [privateDraft[@"locale"] isEqual:region[@"locale"]] &&
        [privateDraft[@"carrierCode"] isEqual:region[@"carrierCode"]],@"every geography field follows compatible daemon region suggestions");
    Check([privateDraft[@"mode"] isEqual:@"manual"] && [privateDraft[@"draftSource"] isEqual:@"automatic"],@"automatic result remains manually reviewable, never a regenerate-on-apply policy");
    Check([privateDraft[@"security"] isEqual:security] && [sRegistry.original isEqual:snapshot],@"automatic draft preserves saved policies and never mutates the profile");
    for (NSString *key in @[@"udid",@"serialNumber",@"wifiMac",@"btMac",@"platformUUID",@"idfa",@"idfv",@"installId",@"externalInstallationId"])
        Check([privateDraft[key] isKindOfClass:NSString.class] && [privateDraft[key] length]>0,@"automatic draft contains every required editable identifier");
    Check(![privateDraft[@"idfv"] isEqual:original[@"ids"][@"idfv"]],@"automatic draft generates new identity values");
    Check([[RBXDeviceCatalog modelForProductType:privateDraft[@"productType"]][@"iosVersions"] containsObject:privateDraft[@"iosVersion"]],@"automatic model and OS are a catalog tuple");
    NSMutableDictionary *manual=[privateDraft mutableCopy], *manualPolicies=[NSMutableDictionary dictionary];
    [privateDraft[@"security"] enumerateKeysAndObjectsUsingBlock:^(NSString *key,id value,BOOL *stop){ manualPolicies[key]=@([value isEqual:@"enabled"]); }];
    manual[@"security"]=manualPolicies;
    NSError *manualError=nil;
    NSDictionary *checked=[sRegistry _identityCandidateForContainer:@"auto-fixture" choices:manual error:&manualError];
    Check(checked!=nil,@"complete automatic draft passes the real subsequent manual candidate check");
    for (NSString *key in @[@"idfa",@"idfv"])
        Check([checked[@"ids"][key] isEqual:privateDraft[key]],@"manual checking retains reviewed IDs without regenerating");
    for (NSString *key in @[@"udid",@"serialNumber",@"wifiMac",@"btMac",@"platformUUID"])
        Check([checked[@"serials"][key] isEqual:privateDraft[key]],@"manual checking retains reviewed hardware identifiers");
    NSMutableDictionary *coveredPaths = [NSMutableDictionary dictionary];
    for (NSString *section in @[@"device",@"serials",@"ids",@"timing",@"reddit",@"mgOverrides"]) {
        NSMutableArray *paths = [NSMutableArray array];
        NSMutableArray *queue = [NSMutableArray arrayWithObject:@{@"path":section,@"value":generatedProfile[section]}];
        while (queue.count) {
            NSDictionary *item = queue.lastObject; [queue removeLastObject];
            if ([item[@"value"] isKindOfClass:NSDictionary.class]) {
                for (NSString *key in item[@"value"])
                    [queue addObject:@{@"path":[item[@"path"] stringByAppendingFormat:@".%@",key],@"value":item[@"value"][key]}];
            } else [paths addObject:item[@"path"]];
        }
        coveredPaths[section] = [paths sortedArrayUsingSelector:@selector(compare:)];
        Check([checked[section] isEqual:generatedProfile[section]],
            [@"EVERY generated field survives manual review in " stringByAppendingString:section]);
    }
    if (argc > 2) [[NSJSONSerialization dataWithJSONObject:coveredPaths options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil]
        writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES];
    NSDictionary *checkedAgain=[sRegistry _identityCandidateForContainer:@"auto-fixture" choices:manual error:nil];
    for (NSString *section in coveredPaths)
        Check([checkedAgain[section] isEqual:checked[section]], @"Check and Apply candidate construction must be deterministic for the complete reviewed draft");
    Check(!receipt[@"details"][@"idfv"] && !receipt[@"details"][@"automaticRegion"] && [receipt[@"details"] count]==2,
        @"durable receipt exposes readiness and ownership only, never private draft values");
    Check(!privateDraft[@"automaticRegion"][@"ip"] && !privateDraft[@"automaticRegion"][@"networkName"] &&
        !privateDraft[@"automaticRegion"][@"proxyURL"] && [privateDraft[@"automaticRegion"][@"proxySource"] isEqual:@"selected-device"],
        @"automatic provenance is the declared geography/source allowlist");
    NSDictionary *first=privateDraft;
    Reset(); Execute(Request(@{@"automatic":@YES,@"productType":@"untrusted-ui-model",@"iosVersion":@"99.0",@"country":@"US"}));
    Check(publications==1 && [privateDraft[@"country"] isEqual:@"DE"] && ![privateDraft[@"idfv"] isEqual:first[@"idfv"]],@"automatic generation ignores UI tuple/country and generates an independent fresh draft");
    NSDictionary *good=privateDraft;
    for (NSDictionary *bad in @[@{@"ok":@NO,@"message":@"Proxy unavailable"}, @{@"ok":@YES},
        @{@"ok":@YES,@"country":@"US",@"timezone":@"Europe/Berlin"}]) {
        Reset(); providerReply=bad; Execute(Request(@{@"automatic":@YES}));
        Check(publications==0 && [privateDraft isEqual:good] && [receipt[@"ok"] isEqual:@NO],@"unavailable or malformed provider result cannot replace the private draft");
    }
    providerReply=region;
    Reset(); contextAllowed=NO; Execute(Request(@{@"automatic":@YES}));
    Check(publications==0 && lookups==0,@"already canceled automatic request invokes no region provider or publication");
    for (NSUInteger failure=0;failure<3;failure++) {
        Reset(); cancelAfterLookup=failure==0; changeProxyAfterLookup=failure==1; freezeAfterLookup=failure==2;
        Execute(Request(@{@"automatic":@YES}));
        Check(publications==0 && [privateDraft isEqual:good] && [receipt[@"ok"] isEqual:@NO],@"cancellation, changed proxy and newly frozen identity stop private publication");
    }
    Reset(); sRegistry.locked=YES; Execute(Request(@{@"automatic":@YES}));
    Check(lookups==0 && publications==0,@"already frozen identity is rejected before lookup");
    Reset(); NSMutableDictionary *assigned=[original mutableCopy]; assigned[@"proxy"]=@{@"url":@"http://assigned.invalid:8080",@"country":@"US"}; sRegistry.original=assigned;
    Execute(Request(@{@"automatic":@YES}));
    Check(publications==0 && [receipt[@"ok"] isEqual:@NO],@"live country mismatch with assigned profile cannot publish a draft");
    sRegistry.original=original;
    Reset(); NSMutableDictionary *stale=[original mutableCopy];
    stale[@"validation"]=@{@"checkedAt":@1,@"geoConsistent":@NO,@"observedProxyCountry":@"CA",@"proxyCountry":@"US"};
    sRegistry.original=stale; Execute(Request(@{@"automatic":@YES}));
    Check(publications==0 && [receipt[@"ok"] isEqual:@NO],@"historical proxy inconsistency fails closed rather than returning a draft that manual check must reject");
    sRegistry.original=original;
    Reset(); Execute(Request(@{@"productType":@"iPhone18,1",@"iosVersion":@"26.6.1"}));
    Check(lookups==0 && publications==1 && [privateDraft[@"productType"] isEqual:@"iPhone18,1"] && [privateDraft[@"iosVersion"] isEqual:@"26.6.1"],@"existing selection-preserving Random fill stays offline and compatible");
    Reset(); Execute(Request(@{@"automatic":@"yes"})); Check(publications==0 && lookups==0,@"malformed automatic flag cannot be treated as a legacy random request");
    Reset(); NSMutableDictionary *fb=[Request(@{@"automatic":@YES}) mutableCopy]; fb[@"appType"]=@"facebook"; Execute(fb);
    Check(publications==0 && lookups==0,@"inactive/foreign Facebook request is rejected before providers");
    Check([sRegistry.original isEqual:snapshot],@"all paths leave the saved profile unchanged");
    for (NSString *model in [RBXDeviceCatalog allModels]) {
        NSDictionary *draft=[sRegistry privateIdentityEditorDraftForContainer:@"auto-fixture" randomize:YES
            selection:@{@"productType":model,@"iosVersion":[RBXDeviceCatalog modelForProductType:model][@"iosVersions"][0]} error:nil];
        NSDictionary *expected=generatedProfile;
        NSMutableDictionary *review=[draft mutableCopy]; review[@"security"]=@{};
        // Real JSON IPC round-trip must retain uint64 ECIDs as exact decimal strings.
        review=[NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:review options:0 error:nil]
            options:NSJSONReadingMutableContainers error:nil];
        NSDictionary *candidate=[sRegistry _identityCandidateForContainer:@"auto-fixture" choices:review error:nil];
        for (NSString *section in coveredPaths)
            Check([candidate[section] isEqual:expected[section]], [NSString stringWithFormat:@"complete random draft survives review/JSON for %@ / %@",model,section]);
    }
    printf("%lu automatic draft checks, %lu failures\n",(unsigned long)checks,(unsigned long)failures);
    return failures ? 1 : 0;
} }
'''
for name, value in {"__VALUE__":extract(registry,"static NSString *RBXRegistryValue("), "__METHODS__":methods,
                    "__HELPERS__":helpers,"__BRANCH__":branch}.items():
    if name == "__METHODS__":
        value = value.replace('    NSMutableDictionary *draft = [state mutableCopy];',
                              '    generatedProfile = profile;\n    NSMutableDictionary *draft = [state mutableCopy];')
    fixture=fixture.replace(name,value)
with tempfile.TemporaryDirectory(prefix="rbx-automatic-identity-") as temp:
    folder=Path(temp); source=folder/"fixture.m"; source.write_text(fixture); executable=folder/"test"
    subprocess.run(["xcrun","clang","-fobjc-arc","-fblocks","-Werror=misleading-indentation","-Wno-incompatible-pointer-types",
        "-Wno-incomplete-implementation","-I"+str(ROOT/"daemon"),"-I"+str(ROOT/"shared"),"-framework","Foundation",
        str(source),str(ROOT/"daemon/RBXProfileGenerator.m"),str(ROOT/"daemon/RBXConsistencyValidator.m"),
        str(ROOT/"daemon/RBXProfileIO.m"),str(ROOT/"shared/RBXMGOverrides.m"),"-o",str(executable)],check=True)
    import os
    arguments = [str(executable),str(ROOT/"profiles/catalog.json")]
    if os.environ.get("RBX_IDENTITY_FIELD_INVENTORY"):
        arguments.append(os.environ["RBX_IDENTITY_FIELD_INVENTORY"])
    subprocess.run(arguments,check=True)
