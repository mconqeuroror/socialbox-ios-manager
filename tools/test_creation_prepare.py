#!/usr/bin/env python3
"""Execute the shipping creation preparation/commit methods with real identities.

Catalog, generator, validation and candidate construction execute natively.
Clone/store/profile effects are counted providers; filesystem work uses a
fresh temporary directory only. No device, account, network or Keychain used.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
registry = (ROOT / 'daemon/RBXContainerRegistry.m').read_text()
def extract(signature):
    start = registry.index(signature)
    return registry[start:registry.index('\n}\n', start) + 3]

create = registry[registry.index('- (NSString *)createContainerWithId:'):registry.index('- (BOOL)deleteContainer:')]
methods = '\n'.join(extract(x) for x in (
    '- (BOOL)_checkIdentityChoices:', '- (NSDictionary *)_validatedCandidate:',
    '- (NSDictionary *)_validatedIdentityCandidate:', '- (NSDictionary *)_identityCandidateForProfile:'))
fixture = r'''
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import "RBXAppRegistry.h"
#import "RBXAppAdmission.h"
#import "RBXProfileIdentifier.h"
#import "RBXContainerRegistry.h"
#import "RBXProfileGenerator.h"
#import "RBXProfileIO.h"
#import "RBXConsistencyValidator.h"
#import "RBXCloneManager.h"
#import "RBXOperationContext.h"
#import "RBXCentralStore.h"
#import "RBXProxyManager.h"
#import "RBXABTestFramework.h"
#import "RBXMGOverrides.h"
#define RBX_CATALOG_TESTING 1
#import "RBXDeviceCatalog.m"
#import "RBXProxyRegion.h"
static NSUInteger Checks, Mutations, Reservations, Clones, SourceReads;
static NSMutableDictionary *Store, *HeldReservations;
static NSArray *Siblings, *Identifiers, *Retired;
static NSDictionary *LastWritten, *CloneInput;
static NSString *kProfilesDir, *kDeletionRoot;
static BOOL Allowed = YES, SourceReady = YES;
static NSError *RBXDeletionError(NSString *message) { return [NSError errorWithDomain:@"fixture" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]; }
static BOOL RBXRegistryCheckOperation(BOOL mutation, NSError **error) { if (!Allowed && error) *error=RBXDeletionError(@"Canceled fixture operation"); return Allowed; }
static NSArray *RBXLegacyRetiredIDs(NSError **error) { return Retired ?: @[]; }
static NSDictionary *RBXCheckedIdentityReservations(NSError **error) { return HeldReservations; }
__VALUE__
__HASHES__
static void Check(BOOL ok,NSString *message) { Checks++; if(!ok) { fprintf(stderr,"FAIL creation preparation: %s\n",message.UTF8String); exit(1); } }
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RBXOperationContext
+ (instancetype)currentContext { return nil; }
@end
@implementation RBXCloneManager
- (instancetype)initWithAppType:(NSString *)type operationContext:(RBXOperationContext *)context { return [super init]; }
- (NSDictionary *)sourceStatus { SourceReads++; return @{@"decrypted":@(SourceReady)}; }
- (NSDictionary *)ensureCloneForContainer:(NSString *)container profile:(NSDictionary *)profile nickname:(NSString *)name error:(NSError **)error {
    Clones++; Mutations++; CloneInput=profile;
    return @{@"bundleIdentifier":RBXAppBundleIdentifier(RBXAppDescriptorForProfile(profile),container)};
}
@end
@implementation RBXCentralStore
+ (instancetype)sharedStore { static id store; if (!store) store=[self new]; return store; }
- (NSDictionary *)dictionary { return Store; }
- (void)update:(void (^)(NSMutableDictionary *))block { Mutations++; block(Store); }
@end
@implementation RBXProxyManager
+ (void)registerUpstream:(NSString *)url forContainer:(NSString *)container { Mutations++; }
@end
@implementation RBXABTestFramework
+ (void)assignGroupForContainer:(NSString *)container { Mutations++; }
@end
@interface RBXContainerRegistry ()
- (BOOL)_allowsContainer:(NSString *)container error:(NSError **)error;
- (NSDictionary *)_validatedCandidate:(NSDictionary *)profile container:(NSString *)container error:(NSError **)error;
- (NSDictionary *)_validatedIdentityCandidate:(NSDictionary *)profile excluding:(NSString *)container error:(NSError **)error;
- (BOOL)_writeProfile:(NSDictionary *)profile container:(NSString *)container error:(NSError **)error;
- (NSArray *)_otherProfilesExcluding:(NSString *)container error:(NSError **)error;
@end
@implementation RBXContainerRegistry
- (NSArray *)containerIdsWithError:(NSError **)error { return Identifiers ?: @[]; }
- (BOOL)_allowsContainer:(NSString *)container error:(NSError **)error { return Allowed && RBXCanonicalProfileIdentifier(container) && ![Retired containsObject:container]; }
- (NSArray *)_otherProfilesExcluding:(NSString *)container error:(NSError **)error { return Siblings ?: @[]; }
- (BOOL)_writeProfile:(NSDictionary *)profile container:(NSString *)container error:(NSError **)error { Mutations++; LastWritten=profile; return YES; }
- (BOOL)reserveIdentityForProfile:(NSDictionary *)profile error:(NSError **)error {
    Reservations++; Mutations++;
    for (NSString *hash in RBXIdentityHashes(profile)) HeldReservations[hash]=profile[@"containerId"];
    return YES;
}
__METHODS__
__CREATE__
@end
static void Reset(void) {
    Store=[@{@"containers":[NSMutableDictionary dictionary]} mutableCopy]; HeldReservations=[NSMutableDictionary dictionary];
    Siblings=Identifiers=Retired=@[]; LastWritten=CloneInput=nil; Allowed=SourceReady=YES;
    Mutations=Reservations=Clones=SourceReads=0;
}
static NSDictionary *Region(void) {
    NSMutableDictionary *region=[RBXProxyRegionSuggestion(@{@"ip":@"203.0.113.1",@"country":@"US",@"timezone":@"America/New_York",@"city":@"New York"},nil) mutableCopy];
    region[@"ok"]=@YES; region[@"proxySource"]=@"selected-device"; return region;
}
static NSString *Commit(RBXContainerRegistry *registry,NSDictionary *prepared) {
    return [registry createContainerWithId:@"draft-one" appType:@"reddit" proxyCountry:@"US" proxyURL:@""
        nickname:@"Reviewed container" regionSuggestion:nil preparedProfile:prepared error:nil];
}
static NSDictionary *DeepCopy(NSDictionary *value) {
    return [NSPropertyListSerialization propertyListWithData:[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil] options:0 format:nil error:nil];
}
int main(int argc,char **argv) { @autoreleasepool {
    RBXCatalogTestPaths=@[@(argv[1])]; NSString *root=@(argv[2]);
    kProfilesDir=[root stringByAppendingPathComponent:@"profiles"];
    kDeletionRoot=[root stringByAppendingPathComponent:@"deletions"];
    RBXContainerRegistry *registry=[RBXContainerRegistry new]; Reset();
    NSDictionary *prepared=[registry prepareCreationForContainer:@"draft-one" appType:@"reddit" proxyCountry:@"US" regionSuggestion:Region() error:nil];
    Check(prepared && Mutations==0 && Reservations==0 && Clones==0,@"prepare returns a full identity without any publication, reservation or clone");
    Check(![NSFileManager.defaultManager fileExistsAtPath:kProfilesDir] && Store[@"containers"] && ![Store[@"containers"] count],@"prepare leaves the filesystem and inventory empty");
    NSDictionary *original=DeepCopy(prepared);
    NSDictionary *profile=prepared[@"profile"], *review=prepared[@"review"];
    Check([profile[@"device"][@"location"][@"city"] isEqual:@"New York"] &&
        [profile[@"device"][@"timezone"] isEqual:@"America/New_York"],@"candidate uses the daemon-observed coherent city/timezone");
    Check([review[@"marketingName"] length] && !review[@"serialNumber"] && !review[@"idfv"] && !review[@"proxyURL"] && !review[@"profile"],@"public review exposes only named summary fields");
    NSMutableDictionary *editor=[[registry creationIdentityEditorDraftForProfile:profile error:nil] mutableCopy];
    Check([editor[@"udid"] isEqual:profile[@"serials"][@"udid"]] && [editor[@"idfv"] isEqual:profile[@"ids"][@"idfv"]],@"private editor projects the exact reviewed identifiers");
    for (NSString *key in RBXAdditionalIdentityFields()) Check(editor[key]!=nil,@"private editor includes every non-derived generated field");
    NSMutableDictionary *policies=[NSMutableDictionary dictionary];
    [profile[@"security"] enumerateKeysAndObjectsUsingBlock:^(NSString *key,id value,BOOL *stop){policies[key]=@([value isEqual:@"enabled"]);}];
    editor[@"security"]=policies; editor[@"deviceName"]=@"Reviewed device";
    NSDictionary *edited=[registry creationProfileByApplyingChoices:editor toPreparedProfile:prepared error:nil];
    Check(edited && [edited[@"profile"][@"device"][@"deviceName"] isEqual:@"Reviewed device"] &&
        [edited[@"profile"][@"serials"] isEqual:profile[@"serials"]] && [edited[@"profile"][@"ids"] isEqual:profile[@"ids"]],@"draft editing retains unrelated identifiers and changes the chosen field");
    Check([prepared isEqual:original] && [edited[@"preparedAt"] isEqual:prepared[@"preparedAt"]] && Mutations==0,@"editing neither mutates the original nor refreshes observation lifetime nor publishes");
    NSDictionary *modelEdit=[registry creationProfileByApplyingChoices:@{@"mode":@"random",@"country":@"US",
        @"productType":@"iPhone18,1",@"iosVersion":@"26.6.1"} toPreparedProfile:prepared error:nil];
    Check(modelEdit && [modelEdit[@"profile"][@"device"][@"productType"] isEqual:@"iPhone18,1"] &&
        [modelEdit[@"profile"][@"device"][@"iosVersion"] isEqual:@"26.6.1"] && Mutations==0,@"model picker prepares matching identifiers without publishing");
    for (NSString *key in @[@"locale",@"language",@"timezone",@"carrier",@"location"])
        Check([modelEdit[@"profile"][@"device"][key] isEqual:profile[@"device"][key]],@"model/OS preparation preserves reviewed proxy geography");
    editor[@"country"]=@"GB";
    Check(![registry creationProfileByApplyingChoices:editor toPreparedProfile:prepared error:nil] && Mutations==0,@"manual country cannot leave the bound proxy country");
    editor[@"country"]=@"US"; editor[@"appType"]=@"facebook";
    Check(![registry creationProfileByApplyingChoices:editor toPreparedProfile:prepared error:nil] && Mutations==0,@"editing cannot change ownership");
    Check([Commit(registry,edited) isEqual:@"draft-one"] && Clones==1 && Reservations==1,@"only final Create provisions and reserves");
    for (NSString *key in @[@"identityPolicy",@"device",@"serials",@"ids",@"timing",@"reddit",@"security"])
        Check([CloneInput[key] isEqual:edited[@"profile"][key]] && [LastWritten[key] isEqual:edited[@"profile"][key]],@"final clone and saved profile retain exact reviewed values without regeneration");
    Check([Store[@"containers"][@"draft-one"][@"nickname"] isEqual:@"Reviewed container"],@"commit publishes requested nickname");
    for (id age in @[@(-1),@301,@(NAN)]) {
        Reset(); NSMutableDictionary *stale=[prepared mutableCopy]; stale[@"preparedAt"]=@(NSDate.date.timeIntervalSince1970-[age doubleValue]);
        Check(!Commit(registry,stale) && Mutations==0,@"future/expired/NaN observations fail before effects");
    }
    for (NSDictionary *change in @[@{@"containerId":@"other"},@{@"appType":@"facebook"},@{@"app":@{}},@{@"proxy":@{@"country":@"US",@"url":@"http://unreviewed.invalid:8"}}]) {
        Reset(); NSMutableDictionary *bad=[prepared mutableCopy], *candidate=[profile mutableCopy];
        [candidate addEntriesFromDictionary:change]; bad[@"profile"]=candidate;
        Check(!Commit(registry,bad) && Mutations==0,@"wrong identity/app/installed metadata/proxy bytes fail without effects");
    }
    Reset(); Identifiers=@[@"DRAFT-ONE"];
    Check(!Commit(registry,prepared) && Mutations==0,@"case-insensitive newly existing profile blocks a retained draft");
    Reset(); Retired=@[@"DRAFT-ONE"];
    Check(!Commit(registry,prepared) && Mutations==0,@"case-insensitive newly retired profile blocks a retained draft");
    Reset(); Store[@"cloudRetiredContainers"]=@{@"DRAFT-ONE":@{}};
    Check(!Commit(registry,prepared) && Mutations==0,@"new remote retirement blocks a retained draft");
    Reset(); NSMutableDictionary *sibling=[profile mutableCopy]; sibling[@"containerId"]=@"sibling"; Siblings=@[sibling];
    Check(!Commit(registry,prepared) && Mutations==0,@"new live identity collision blocks before reserving even sibling identities");
    Reset(); NSString *hash=[RBXIdentityHashes(profile) allKeys].firstObject; HeldReservations[hash]=@"retired-sibling";
    Check(!Commit(registry,prepared) && Mutations==0,@"new historical reservation invalidates a retained draft");
    Reset(); Allowed=NO;
    Check(!Commit(registry,prepared) && Mutations==0,@"operation cancellation prevents publication");
    Reset(); NSMutableDictionary *badRegion=[Region() mutableCopy]; badRegion[@"checkedAt"]=@(NSDate.date.timeIntervalSince1970-61);
    Check(![registry prepareCreationForContainer:@"draft-two" appType:@"reddit" proxyCountry:@"US" regionSuggestion:badRegion error:nil] && Mutations==0,@"stale region cannot prepare new identity");
    for (id region in @[NSNull.null,@"bad",@{},@{@"ok":@YES,@"country":NSNull.null}]) {
        Reset(); Check(![registry prepareCreationForContainer:@"draft-one" appType:@"reddit" proxyCountry:@"US" regionSuggestion:region error:nil] && Mutations==0,@"malformed observations fail without effects or a crash");
    }
    for (id envelope in @[NSNull.null,@"bad",@{},@{@"profile":NSNull.null}]) {
        Reset(); Check(!Commit(registry,envelope) && Mutations==0,@"malformed daemon candidate envelopes fail without effects or a crash");
    }
    Reset(); Identifiers=@[@"DRAFT-ONE"];
    Check(![registry prepareCreationForContainer:@"draft-one" appType:@"reddit" proxyCountry:@"US" regionSuggestion:nil error:nil] && Mutations==0,@"prepare cannot use an existing profile's identifier");
    Reset();
    Check(![registry prepareCreationForContainer:@"draft-one" appType:@"facebook" proxyCountry:@"US" regionSuggestion:nil error:nil] && Mutations==0,@"inactive app cannot be made available by creation preview");
    Check(![registry prepareCreationForContainer:@"../draft" appType:@"reddit" proxyCountry:@"US" regionSuggestion:nil error:nil] && Mutations==0,@"unsafe draft ID rejected");
    Reset(); Check([registry createContainerWithId:@"legacy" appType:@"reddit" proxyCountry:@"US" proxyURL:@"" nickname:@"Legacy" error:nil]!=nil && Clones==1,@"legacy no-draft caller still follows its generator/provisioning path");
    printf("PASS %lu native creation preparation/edit/commit assertions\n",(unsigned long)Checks);
    return 0;
}}
'''
fixture = fixture.replace('__VALUE__',extract('static NSString *RBXRegistryValue(')).replace('__HASHES__',extract('static NSDictionary *RBXIdentityHashes('))
fixture = fixture.replace('__METHODS__',methods).replace('__CREATE__',create)
with tempfile.TemporaryDirectory(prefix='rbx-creation-prepare-') as temp:
    folder=Path(temp); src=folder/'fixture.m'; src.write_text(fixture); executable=folder/'test'
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-incompatible-pointer-types','-Wno-deprecated-declarations','-Wno-nullability-completeness',
        '-I'+str(ROOT/'daemon'),'-I'+str(ROOT/'shared'),'-framework','Foundation',str(src),
        str(ROOT/'daemon/RBXProfileGenerator.m'),str(ROOT/'daemon/RBXConsistencyValidator.m'),
        str(ROOT/'daemon/RBXProfileIO.m'),str(ROOT/'shared/RBXMGOverrides.m'),'-o',str(executable)],check=True)
    subprocess.run([str(executable),str(ROOT/'profiles/catalog.json'),str(folder/'effects')],check=True)
