#!/usr/bin/env python3
"""Exercise the shipped IPA metadata/cryptid validator for each registered app."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "daemon/RBXCloneManager.m").read_text()
assert "RBXRewriteAppKeychainInfo(info, self.appDescriptor, bundleIdentifier, error)" in source
assert "RBXAppKeychainInfoMatches(info, self.appDescriptor, bundleIdentifier)" in source
crypto = source[source.index("static BOOL RBXMachOSliceIsEncrypted"):source.index("// No archive-provided")]
validate = source[source.index("static BOOL RBXValidateImportedSource"):source.index("static BOOL RBXSyncImportedTree")]
entitlements = source[source.index("- (NSDictionary *)_entitlementsForBundleIdentifier"):source.index("- (BOOL)_rewriteAndSignBundle")]
fixture = r'''
#import <Foundation/Foundation.h>
#import "RBXAppRegistry.h"
#import "RBXAppKeychainPolicy.h"
#import "RBXAppAdmission.h"
#include <libkern/OSByteOrder.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
static BOOL allowed = YES;
static BOOL RBXCloneMayMutate(NSError **error) { return allowed; }
static NSError *RBXCloneError(NSInteger code, NSString *message) {
 return [NSError errorWithDomain:@"fixture" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
CRYPTO
VALIDATE
@interface AppCloneFixture : NSObject
@property(nonatomic,copy) NSDictionary *appDescriptor;
@end
@implementation AppCloneFixture
ENTITLEMENTS
@end
static void check(BOOL value, NSString *message) { if (!value) { NSLog(@"FAIL: %@",message); exit(1); } }
static void binary(NSString *path, uint32_t cryptid) {
 struct mach_header_64 h = {.magic=MH_MAGIC_64,.ncmds=1,.sizeofcmds=sizeof(struct encryption_info_command_64)};
 struct encryption_info_command_64 c = {.cmd=LC_ENCRYPTION_INFO_64,.cmdsize=sizeof(c),.cryptid=cryptid};
 NSMutableData *data=[NSMutableData dataWithBytes:&h length:sizeof(h)]; [data appendBytes:&c length:sizeof(c)];
 check([data writeToFile:path atomically:YES],@"fixture binary"); chmod(path.fileSystemRepresentation,0600);
}
int main(void) { @autoreleasepool {
 NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 for (NSDictionary *descriptor in RBXRegisteredAppDescriptors()) {
  AppCloneFixture *clone=[AppCloneFixture new]; clone.appDescriptor=descriptor;
  NSString *bundleId=RBXAppBundleIdentifier(descriptor,@"legacy");
  NSString *primary=RBXAppKeychainGroup(descriptor,bundleId);
  NSArray *groups=[descriptor[@"appType"] isEqual:@"facebook"] ? @[primary,[primary stringByAppendingString:@".family"],[primary stringByAppendingString:@".app"]] : @[primary];
  NSDictionary *expected=@{@"application-identifier":primary,
    @"com.apple.developer.team-identifier":descriptor[@"teamIdentifier"],@"keychain-access-groups":groups};
  check([[clone _entitlementsForBundleIdentifier:bundleId profile:@{} mainBundle:YES] isEqual:expected],@"exact signing allowlist retained");
  check(![clone _entitlementsForBundleIdentifier:descriptor[@"sourceBundleIdentifier"] profile:@{} mainBundle:YES],@"source/foreign bundle cannot receive clone group entitlements");
  NSMutableDictionary *attest=[expected mutableCopy]; attest[@"com.apple.developer.devicecheck.appattest-environment"]=@"production";
  check([[clone _entitlementsForBundleIdentifier:bundleId profile:@{@"security":@{@"appAttest":@"enabled"}} mainBundle:YES] isEqual:attest],@"existing optional App Attest signing unchanged");
  NSString *bundle=[root stringByAppendingPathComponent:descriptor[@"sourceBundleName"]];
  [NSFileManager.defaultManager createDirectoryAtPath:bundle withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *infoPath=[bundle stringByAppendingPathComponent:@"Info.plist"], *exe=[bundle stringByAppendingPathComponent:@"App"];
  NSMutableDictionary *info=[@{@"CFBundleIdentifier":descriptor[@"sourceBundleIdentifier"],@"CFBundleExecutable":@"App",
    @"CFBundlePackageType":@"APPL",@"CFBundleShortVersionString":@"1.0",@"CFBundleVersion":@"1",@"MinimumOSVersion":@"1.0"} mutableCopy];
  [info writeToFile:infoPath atomically:YES]; binary(exe,0);
  check(RBXValidateImportedSource(bundle,descriptor,nil),@"decrypted matching app accepted");
  check([NSFileManager.defaultManager isExecutableFileAtPath:exe],@"missing execute bit repaired");
  NSDictionary *other=RBXAppDescriptorForType([descriptor[@"appType"] isEqual:@"reddit"] ? @"facebook" : @"reddit");
  check(!RBXValidateImportedSource(bundle,other,nil),@"other app source rejected");
  binary(exe,1); check(!RBXValidateImportedSource(bundle,descriptor,nil),@"encrypted main rejected"); binary(exe,0);
  NSString *nested=[bundle stringByAppendingPathComponent:@"Nested"];
  binary(nested,1); check(!RBXValidateImportedSource(bundle,descriptor,nil),@"encrypted nested Mach-O rejected");
  [NSFileManager.defaultManager removeItemAtPath:nested error:nil];
  for (id value in @[@"../App",@"/App",@"..",@".",@"App\\bad",@42]) {
   info[@"CFBundleExecutable"]=value; [info writeToFile:infoPath atomically:YES];
   check(!RBXValidateImportedSource(bundle,descriptor,nil),@"invalid executable rejected");
  }
  info[@"CFBundleExecutable"]=@"App";
  for (id value in @[@"",@"newest",@"999.0",@42]) {
   info[@"MinimumOSVersion"]=value; [info writeToFile:infoPath atomically:YES];
   check(!RBXValidateImportedSource(bundle,descriptor,nil),@"invalid/unsupported physical OS rejected");
  }
  info[@"MinimumOSVersion"]=@"1.0"; [info writeToFile:infoPath atomically:YES];
  allowed=NO; check(!RBXValidateImportedSource(bundle,descriptor,nil),@"cancellation remains enforced"); allowed=YES;
 }
 NSDictionary *rd=RBXRedditAppDescriptor(), *fb=RBXAppDescriptorForType(@"facebook");
 check(!RBXAppCloneBlockReason(rd,@{@"containerId":@"legacy"},NO),@"Reddit legacy path unchanged");
 check(RBXAppCloneBlockReason(rd,@{@"appType":@"facebook"},YES)!=nil,@"cross-app clone rejected");
 check([RBXAppCloneBlockReason(fb,@{@"appType":@"facebook"},NO) containsString:@"No Facebook source"],@"missing FB source clear error");
 check([RBXAppCloneBlockReason(fb,@{@"appType":@"facebook"},YES) containsString:@"Phase 2"],@"source never enables unaudited hooks");
 check(!RBXAppRequestBlockReason(@{@"action":@"launchContainer"},@[@{}]),@"legacy request unchanged");
 check(!RBXAppRequestBlockReason(@{@"action":@"import-source",@"appType":@"facebook"},@[]),@"FB import scoped allowed");
 check(RBXAppRequestBlockReason(@{@"action":@"deleteContainer"},@[@{@"appType":@"facebook",@"device":@42}])!=nil,@"legacy request cannot delete malformed FB");
 check(!RBXAppCloneBlockReason(rd,@{@"device":@42},YES),@"malformed legacy Reddit repair remains allowed");
 check(RBXAppRequestBlockReason(@{@"action":@"launchContainer",@"appType":@"facebook"},@[])!=nil,@"FB run blocked");
 check(RBXAppRequestBlockReason(@{@"action":@"import-source",@"appType":NSNull.null},@[])!=nil,@"null scope rejected");
 [NSFileManager.defaultManager removeItemAtPath:root error:nil];
 puts("PASS: actual source validator for Reddit/Facebook, cryptid, nested encryption, metadata, physical OS, cancellation and fail-closed app admission");
} return 0; }
'''.replace("CRYPTO", crypto).replace("VALIDATE", validate).replace("ENTITLEMENTS", entitlements)
with tempfile.TemporaryDirectory(prefix="rbx-app-source-") as folder:
    path = Path(folder)
    (path / "test.m").write_text(fixture)
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-I" + str(ROOT / "shared"),
                    "-framework", "Foundation", str(path / "test.m"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
