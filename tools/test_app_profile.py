#!/usr/bin/env python3
"""Run shipped registry admission/ownership methods with inert service boundaries.

Actual generator/catalog behavior is covered by test_device_catalog.sh. These
fixtures use isolated registry headers and never read/write production paths,
change network state, call LaunchServices or provision an app.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
registry = (ROOT / 'daemon/RBXContainerRegistry.m').read_text()
main = (ROOT / 'daemon/main.m').read_text()

def span(start, end):
    return registry.split(start, 1)[1].split(end, 1)[0]

create = '- (NSString *)createContainerWithId:' + span('- (NSString *)createContainerWithId:', '- (BOOL)deleteContainer:')
ensure = '- (BOOL)ensureAppCloneForContainer:' + span('- (BOOL)ensureAppCloneForContainer:', '- (NSDictionary *)_validatedIdentityCandidate:')
candidate = '- (NSDictionary *)_identityCandidateForContainer:' + span('- (NSDictionary *)_identityCandidateForContainer:', '- (NSDictionary *)identityEditorStateForContainer:')
check_choices = '- (BOOL)_checkIdentityChoices:' + span('- (BOOL)_checkIdentityChoices:', '- (NSDictionary *)validatedProfileForContainer:')
def main_function(signature):
    assert main.count(signature) == 1
    start = main.index(signature)
    # Function bodies use an unindented closing brace. Added neighboring
    # helpers must not silently become part of this fixture's dependency scope.
    function = main[start:main.index('\n}\n', start) + 3]
    assert '\nstatic ' not in function
    return function

operation_receipt = main_function('static void publishLauncherOperation(NSDictionary *pending, NSString *action, NSString *containerId,\n                                     BOOL ok, NSString *message) {')
identity_receipt = main_function('static void publishIdentityResult(NSDictionary *pending, NSString *containerId, NSString *requestId,\n                                  BOOL ok, BOOL applied, NSDictionary *preview,\n                                  NSString *message) {')
export = main.split('if ([action isEqualToString:@"exportCloneIPA"]) {', 1)[1].split('if ([action isEqualToString:@"configureCloud"])', 1)[0]
assert 'RBXAppDescriptorForProfile(profile)' in export
assert 'initWithAppType:descriptor[@"appType"] operationContext:RBXOperationContext.currentContext' in export
assert 'scoped[@"appType"] = @"facebook"' in export
draft_marker = '    if ([@[@"loadIdentityEditor", @"randomizeIdentityEditor"] containsObject:action]) {'
assert main.count(draft_marker) == 1
draft_start = main.index(draft_marker)
draft_receipt = main[draft_start:main.index('\n    }\n', draft_start) + len('\n    }\n')]
assert '? @{@"containerId":container, @"draftReady":@(ok), @"appType":@"facebook"}' in draft_receipt
assert ': @{@"containerId":container, @"draftReady":@(ok)}' in draft_receipt

# main's preflight precedes queue dispatch and proxy lookup; operational process
# and global lease code is intentionally outside this bounded ownership change.
handler = main.split('static void handleContainerAction(NSDictionary *pending) {', 1)[1].split('static void ', 1)[0]
assert handler.index('canCreateContainerForAppType:') < handler.index('dispatchRequest(') < handler.index('detectRegionForContainer:')
assert 'createContainerWithId:cid appType:pending[@"appType"] ?: @"reddit"' in handler
assert 'appType:descriptor[@"appType"] proxyCountry:country' in candidate
# Owner preservation is asserted by executing candidate construction below;
# test_identity_choices.py also covers real generation and profile decoding.

fixture = r'''
#import <Foundation/Foundation.h>
#import "RBXAppRegistry.h"
#import "RBXAppAdmission.h"
#import "RBXProfileIdentifier.h"
#import "RBXContainerRegistry.h"
#import "RBXProfileGenerator.h"
#import "RBXCloneManager.h"
#import "RBXOperationContext.h"
#import "RBXCentralStore.h"
#import "RBXProfileIO.h"
#import "RBXDeviceCatalog.h"
#import "RBXConsistencyValidator.h"
#import "RBXProxyManager.h"
#import "RBXABTestFramework.h"
#import "RBXMGOverrides.h"
static BOOL SourceReady;
static NSUInteger OperationChecks, Mutations, InventoryReads, SourceReads, Generated;
static NSString *LastCloneType, *LastGeneratorType;
static NSDictionary *LoadedProfile, *WrittenProfile, *LastDetails;
static NSMutableDictionary *Document;
static NSString *const kProfilesDir = @"/fixture-never-written/profiles", *const kDeletionRoot = @"/fixture-never-read/deletions";
NSString *const RBXProfileIOErrorDomain = @"fixture-profile-io";
static NSError *RBXDeletionError(NSString *message) { return [NSError errorWithDomain:@"fixture" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]; }
static BOOL RBXRegistryCheckOperation(BOOL mutation, NSError **error) { OperationChecks++; if (error) *error = RBXDeletionError(@"fixture operation boundary"); return NO; }
static NSArray *RBXLegacyRetiredIDs(NSError **error) { Mutations++; return @[]; }
static NSString *RBXRegistryValue(NSDictionary *profile, NSString *path) {
 id value = profile; for (NSString *key in [path componentsSeparatedByString:@"."]) value = [value isKindOfClass:NSDictionary.class] ? value[key] : nil;
 return [value isKindOfClass:NSString.class] ? value : @"";
}
NSDictionary *RBXBuildMGOverrides(NSDictionary *profile) { return @{}; }
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RBXOperationContext
+ (instancetype)currentContext { return nil; }
@end
@implementation RBXCloneManager
- (instancetype)initWithAppType:(NSString *)appType operationContext:(RBXOperationContext *)context {
 if ((self = [super init])) { LastCloneType = [appType copy]; } return self;
}
- (NSDictionary *)sourceStatus { SourceReads++; return @{@"decrypted":@(SourceReady)}; }
- (NSDictionary *)ensureCloneForContainer:(NSString *)identifier profile:(NSDictionary *)profile nickname:(NSString *)name error:(NSError **)error {
 if (![RBXAppDescriptorForType(LastCloneType)[@"runnable"] boolValue]) { if (error) *error = RBXDeletionError(@"inactive app"); return nil; }
 NSDictionary *descriptor = RBXAppDescriptorForType(LastCloneType);
 NSString *bundle = RBXAppBundleIdentifier(descriptor, identifier);
 NSMutableDictionary *app = [@{@"bundleIdentifier":bundle, @"keychainAccessGroup":RBXAppKeychainGroup(descriptor,bundle)} mutableCopy];
 [app addEntriesFromDictionary:RBXAppKeychainMetadata(descriptor,bundle)];
 return app;
}
- (BOOL)validateCloneForProfile:(NSDictionary *)profile error:(NSError **)error { return [RBXAppDescriptorForType(LastCloneType)[@"runnable"] boolValue]; }
- (BOOL)syncProfile:(NSDictionary *)profile error:(NSError **)error { WrittenProfile = profile; return YES; }
@end
@implementation RBXCentralStore
+ (instancetype)sharedStore { return [self new]; }
- (NSMutableDictionary *)dictionary { return Document; }
- (void)update:(void (^)(NSMutableDictionary *))block { Mutations++; block(Document); }
@end
@implementation RBXProfileGenerator
+ (NSDictionary *)generateProfileForContainerId:(NSString *)identifier appType:(NSString *)appType proxyCountry:(NSString *)country existingProfiles:(NSArray *)existing productType:(NSString *)product iosVersion:(NSString *)version error:(NSError **)error {
 Generated++; LastGeneratorType = appType;
 NSMutableDictionary *profile = [@{@"containerId":identifier,@"device":@{},@"proxy":@{@"country":country},@"validation":@{},@"security":@{}} mutableCopy];
 if (![appType isEqual:@"reddit"]) profile[@"appType"] = appType;
 return profile;
}
+ (NSDictionary *)generateProfileForContainerId:(NSString *)identifier appType:(NSString *)appType proxyCountry:(NSString *)country existingProfiles:(NSArray *)existing error:(NSError **)error {
 return [self generateProfileForContainerId:identifier appType:appType proxyCountry:country existingProfiles:existing productType:nil iosVersion:nil error:error];
}
@end
@implementation RBXDeviceCatalog @end
@implementation RBXProfileIO @end
@implementation RBXConsistencyValidator
+ (NSDictionary *)validatedProfile:(NSDictionary *)profile error:(NSError **)error { return profile; }
@end
@implementation RBXProxyManager
+ (void)registerUpstream:(NSString *)proxy forContainer:(NSString *)identifier { Mutations++; }
@end
@implementation RBXABTestFramework
+ (void)assignGroupForContainer:(NSString *)identifier { Mutations++; }
@end
@interface RBXContainerRegistry ()
- (BOOL)_allowsContainer:(NSString *)identifier error:(NSError **)error;
- (NSDictionary *)_load:(NSString *)identifier error:(NSError **)error;
- (BOOL)_writeProfile:(NSDictionary *)profile container:(NSString *)identifier error:(NSError **)error;
- (NSArray *)_otherProfilesExcluding:(NSString *)identifier error:(NSError **)error;
- (NSDictionary *)_validatedCandidate:(NSDictionary *)profile container:(NSString *)identifier error:(NSError **)error;
- (NSDictionary *)_validatedIdentityCandidate:(NSDictionary *)profile excluding:(NSString *)identifier error:(NSError **)error;
- (BOOL)_checkIdentityChoices:(NSDictionary *)choices error:(NSError **)error;
@end
@implementation RBXContainerRegistry
- (BOOL)_allowsContainer:(NSString *)identifier error:(NSError **)error { return YES; }
- (NSDictionary *)_load:(NSString *)identifier error:(NSError **)error { return LoadedProfile; }
- (BOOL)_writeProfile:(NSDictionary *)profile container:(NSString *)identifier error:(NSError **)error { WrittenProfile = profile; Mutations++; return YES; }
- (NSArray *)containerIdsWithError:(NSError **)error { InventoryReads++; return @[]; }
- (NSArray *)_otherProfilesExcluding:(NSString *)identifier error:(NSError **)error { return @[]; }
- (BOOL)reserveIdentityForProfile:(NSDictionary *)profile error:(NSError **)error { Mutations++; return YES; }
- (NSDictionary *)_validatedCandidate:(NSDictionary *)profile container:(NSString *)identifier error:(NSError **)error { return profile; }
- (NSDictionary *)_validatedIdentityCandidate:(NSDictionary *)profile excluding:(NSString *)identifier error:(NSError **)error { return profile; }
CHECK_CHOICES
CREATE
ENSURE
CANDIDATE
@end
static void completeRequest(NSDictionary *request, BOOL ok, NSString *message, NSDictionary *details) { LastDetails = details; }
OPERATION_RECEIPT
IDENTITY_RECEIPT
static void Check(BOOL ok, NSString *message) { if (!ok) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); } }
int main(void) { @autoreleasepool {
 Document = [@{@"containers":@{}} mutableCopy]; RBXContainerRegistry *registry = [RBXContainerRegistry new];
 BOOL active = [RBXAppDescriptorForType(@"facebook")[@"runnable"] boolValue];
 for (NSNumber *ready in @[@NO,@YES]) {
  SourceReady = ready.boolValue; OperationChecks = Mutations = InventoryReads = Generated = 0; NSError *error = nil;
  Check(![registry createContainerWithId:nil appType:@"facebook" proxyCountry:@"US" proxyURL:@"http://fixture.invalid" nickname:@"Facebook" regionSuggestion:@{} error:&error], @"fixture never creates a container");
  if (!active || !SourceReady) {
   Check(error && [error.localizedDescription containsString:SourceReady ? @"audit" : @"No Facebook source imported"], @"inactive/missing FB source explains its own app failure");
   Check(OperationChecks == 0 && Mutations == 0 && InventoryReads == 0 && Generated == 0, @"early FB rejection reaches no operation, ID inventory, identity, store, proxy, pool or file mutation");
  } else Check(OperationChecks == 1 && Mutations == 0 && InventoryReads == 0, @"ready active descriptor reaches existing bounded operation admission");
 }
 for (id appType in @[@"unknown",NSNull.null]) {
  NSError *error = nil; OperationChecks = Mutations = InventoryReads = SourceReads = 0;
  Check(![registry createContainerWithId:@"invalid" appType:appType proxyCountry:@"US" proxyURL:nil nickname:nil error:&error] && error, @"unknown/malformed create scope rejected");
  Check(OperationChecks == 0 && Mutations == 0 && InventoryReads == 0 && SourceReads == 0, @"invalid scope has zero service effects");
 }
 OperationChecks = SourceReads = 0;
 Check(![registry createContainerWithId:@"typed-nil" appType:nil proxyCountry:@"US" proxyURL:nil nickname:nil error:nil] && OperationChecks == 0 && SourceReads == 0, @"explicit nil scope cannot silently select Reddit");
 Check(![registry createContainerWithId:@"legacy" proxyCountry:@"US" proxyURL:nil nickname:nil error:nil] && OperationChecks == 1 && SourceReads == 0, @"legacy Reddit wrapper retains operation-first behavior and no added source check");
 for (id type in @[@"legacy",@"reddit",@"facebook",@"unknown"]) {
  NSMutableDictionary *profile = [@{@"containerId":@"profile",@"proxy":@{@"country":@"US"},@"validation":@{},@"app":@{@"old":@YES}} mutableCopy];
  if (![type isEqual:@"legacy"]) profile[@"appType"] = type;
  LoadedProfile = profile; LastCloneType = nil; WrittenProfile = nil;
  NSError *error = nil; BOOL ensured = [registry ensureAppCloneForContainer:@"profile" error:&error];
  BOOL admitted = ![type isEqual:@"unknown"] && (![type isEqual:@"facebook"] || active);
  Check(ensured == admitted, @"ensure respects owner and capability");
  Check([type isEqual:@"unknown"] ? !LastCloneType : [LastCloneType isEqual:([type isEqual:@"legacy"] ? @"reddit" : type)], @"ensure binds manager to persisted owner, never selector/default");
  if (ensured) Check([WrittenProfile[@"app"][@"bundleIdentifier"] isEqual:RBXAppBundleIdentifier(RBXAppDescriptorForProfile(profile), @"profile")], @"owner's exact clone bundle is published");
  LastCloneType = nil; WrittenProfile = nil;
  Check([registry syncProfileToCloneForContainer:@"profile" error:nil] == admitted, @"sync follows owner and capability");
  if (admitted) Check(WrittenProfile == LoadedProfile, @"sync passes original owned profile unchanged");
  LastGeneratorType = nil; Generated = 0;
  NSDictionary *candidate = [registry _identityCandidateForContainer:@"profile" choices:@{@"mode":@"random",@"country":@"US"} error:&error];
  Check((candidate != nil) == ![type isEqual:@"unknown"], @"random draft rejects unknown owners");
  if (candidate) {
   Check([type isEqual:@"legacy"] ? !candidate[@"appType"] : [candidate[@"appType"] isEqual:type], @"random fill preserves explicit ownership and legacy absence");
   Check([LastGeneratorType isEqual:([type isEqual:@"legacy"] ? @"reddit" : type)], @"random fill forwards persisted type to generator");
   Check([candidate[@"app"] isEqual:profile[@"app"]], @"random draft preserves clone metadata");
   NSUInteger generated = Generated;
   Check(![registry _identityCandidateForContainer:@"profile" choices:@{@"mode":@"random",@"appType":([type isEqual:@"facebook"] ? @"reddit" : @"facebook")} error:nil] && Generated == generated, @"choices cannot retype profile before generation");
  }
 }
 for (NSString *type in @[@"legacy",@"reddit",@"facebook"]) {
  NSMutableDictionary *pending = [@{@"requestId":@"request"} mutableCopy];
  if (![type isEqual:@"legacy"]) pending[@"appType"] = type;
  publishLauncherOperation(pending, @"createContainer", @"profile", NO, @"fixture message");
  NSDictionary *operation = Document[@"device"][@"launcherOperation"];
  NSMutableDictionary *expectedOperation = [@{@"requestId":@"request",@"action":@"createContainer",@"containerId":@"profile",@"ok":@NO,@"message":@"fixture message",@"updatedAt":operation[@"updatedAt"]} mutableCopy];
  NSMutableDictionary *expectedDetails = [@{@"containerId":@"profile"} mutableCopy];
  if ([type isEqual:@"facebook"]) { expectedOperation[@"appType"] = type; expectedDetails[@"appType"] = type; }
  Check([operation isEqual:expectedOperation] && [LastDetails isEqual:expectedDetails], @"actual operation publication preserves Reddit shape and tags FB durable details");
  NSDictionary *summary = @{@"country":@"US"};
  publishIdentityResult(pending, @"profile", @"request", YES, NO, @{@"summary":summary}, @"fixture identity");
  NSDictionary *identity = Document[@"device"][@"launcherIdentityResult"];
  NSMutableDictionary *expectedIdentity = [@{@"containerId":@"profile",@"requestId":@"request",@"ok":@YES,@"applied":@NO,@"message":@"fixture identity",@"summary":summary,@"updatedAt":identity[@"updatedAt"]} mutableCopy];
  if ([type isEqual:@"facebook"]) expectedIdentity[@"appType"] = type;
  Check([identity isEqual:expectedIdentity] && [LastDetails isEqual:expectedIdentity], @"actual identity publication preserves legacy payload and tags FB ownership");
 }
 puts("PASS actual registry app ownership, random-fill preservation, zero-side-effect create rejection and typed main receipts");
} return 0; }
'''.replace('CHECK_CHOICES', check_choices).replace('CREATE', create).replace('ENSURE', ensure).replace('CANDIDATE', candidate).replace('OPERATION_RECEIPT', operation_receipt).replace('IDENTITY_RECEIPT', identity_receipt)

with tempfile.TemporaryDirectory(prefix='rbx-app-profile-') as directory:
    directory = Path(directory)
    (directory / 'fixture.m').write_text(fixture)
    for active in (False, True):
        headers = directory / ('active' if active else 'inactive')
        headers.mkdir()
        for name in ('RBXAppRegistry.h','RBXAppRegistryData.h','RBXAppAdmission.h','RBXAppProfileIdentity.h','RBXAppKeychainPolicy.h'):
            (headers / name).write_bytes((ROOT / 'shared' / name).read_bytes())
        generated = headers / 'RBXAppRegistryData.h'
        before, facebook = generated.read_text().split('@"appType": @"facebook",', 1)
        facebook, count = re.subn(r'@"runnable": @(YES|NO),', '@"runnable": @' + ('YES' if active else 'NO') + ',', facebook, count=1)
        assert count == 1
        generated.write_text(before + '@"appType": @"facebook",' + facebook)
        binary = headers / 'fixture'
        subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-nullability-completeness','-I'+str(headers),'-I'+str(ROOT/'daemon'),'-I'+str(ROOT/'shared'),'-framework','Foundation',str(directory/'fixture.m'),'-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True)
