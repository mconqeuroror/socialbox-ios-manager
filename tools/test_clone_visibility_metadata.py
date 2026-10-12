#!/usr/bin/env python3
"""Actual clone rewrite and validator with synthetic signing/OS lookup boundaries.

This verifies produced metadata, not SpringBoard visibility or crash behavior.
"""
from pathlib import Path
import subprocess
import tempfile
import re

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "daemon/RBXCloneManager.m").read_text()


def extract(signature: str, method: bool = True) -> str:
    start = source.index(signature, source.index("@implementation RBXCloneManager") if method else 0)
    return source[start:source.index("\n}\n", start) + 3]


methods = "\n".join(extract(s) for s in (
    "- (NSDictionary *)_entitlementsForBundleIdentifier:",
    "- (BOOL)_rewriteAndSignBundle:",
    "- (BOOL)validateCloneForProfile:",
))
helpers = "\n".join(extract(s, False) for s in (
    "static BOOL RBXBootstrapIsRedacted(",
    "static BOOL RBXBootstrapMatchesIdentity(",
))
fixture = r'''
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>
#import "RBXAppAdmission.h"
#import "RBXAppBundlePolicy.h"
#import "RBXProfileTransport.h"
static NSUInteger Checks, Failures, SignCalls, InspectCalls, OwnershipCalls;
static NSDictionary *SignedEntitlements, *InfoAtSigning;
static void Check(BOOL ok, NSString *message) {
    Checks++; if (!ok) { Failures++; fprintf(stderr,"FAIL: %s\n",message.UTF8String); }
}
static NSError *RBXCloneError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"fixture.clone" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL RBXCloneMayMutate(NSError **error) { (void)error; return YES; }
static BOOL RBXCloneContinue(NSError **error) { (void)error; return YES; }
static BOOL RBXContainerAvailable(NSString *container, NSError **error) { (void)container; (void)error; return YES; }
static NSString *RBXExecutable(NSString *name) { return [@"/synthetic/" stringByAppendingString:name]; }
static BOOL RBXIsMachOAtPath(NSString *path) { (void)path; return NO; }
static int FixtureChown(const char *path, uid_t uid, gid_t gid) {
    Check(uid == 501 && gid == 501 && [[NSString stringWithUTF8String:path].lastPathComponent isEqual:@"RedditBoxProfile.json"],
        @"production rewrite still restricts the bootstrap to the mobile owner");
    OwnershipCalls++; return 0;
}
static BOOL RBXSpawnAndWait(NSString *tool, NSArray *arguments, NSError **error) {
    (void)error; SignCalls++;
    Check([tool isEqual:@"/synthetic/ldid"] && arguments.count == 3, @"actual rewrite uses its original main signing boundary");
    SignedEntitlements = [NSDictionary dictionaryWithContentsOfFile:[arguments[0] substringFromIndex:2]];
    NSString *bundle = [arguments.lastObject stringByDeletingLastPathComponent];
    InfoAtSigning = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]];
    Check(InfoAtSigning[@"SBIconVisibilityDefaultVisible"] == nil, @"unsupported visibility key is absent before signing");
    return YES;
}
static BOOL RBXSpawnCapturingStdout(NSString *tool, NSArray *arguments, NSString *path, NSError **error) {
    (void)error; InspectCalls++;
    Check([tool isEqual:@"/synthetic/ldid"] && [arguments.firstObject isEqual:@"-e"], @"effective entitlements still checked after signing");
    return [SignedEntitlements writeToFile:path atomically:NO];
}
__HELPERS__
@interface RBXCloneManager : NSObject
@property(nonatomic,strong) NSDictionary *appDescriptor;
@property(nonatomic,copy) NSString *installedBundle;
- (NSString *)_installedBundleForIdentifier:(NSString *)identifier;
- (NSString *)dataContainerForBundleIdentifier:(NSString *)identifier;
@end
@implementation RBXCloneManager
- (NSString *)_installedBundleForIdentifier:(NSString *)identifier { (void)identifier; return self.installedBundle; }
- (NSString *)dataContainerForBundleIdentifier:(NSString *)identifier { (void)identifier; return self.installedBundle; }
#define chown FixtureChown
__METHODS__
#undef chown
@end
int main(void) { @autoreleasepool {
    char temporary[] = "/tmp/redditbox-visibility-test.XXXXXX";
    if (!mkdtemp(temporary)) return 2;
    NSString *root = [NSString stringWithUTF8String:temporary];
    for (NSDictionary *descriptor in RBXRegisteredAppDescriptors()) {
    RBXCloneManager *manager = [RBXCloneManager new]; manager.appDescriptor = descriptor;
    BOOL facebook = [descriptor[@"appType"] isEqual:@"facebook"];
    NSString *identifier = RBXAppBundleIdentifier(manager.appDescriptor,@"visibility-fixture");
    NSString *group = RBXAppKeychainGroup(manager.appDescriptor,identifier);
    NSArray *inheritedValues = @[NSNull.null,@YES,@NO,@"inherited-unknown-value"];
    for (id inherited in inheritedValues) {
        NSString *bundle = [root stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"app"]];
        Check([NSFileManager.defaultManager createDirectoryAtPath:bundle withIntermediateDirectories:NO
            attributes:@{NSFilePosixPermissions:@0700} error:nil], @"private synthetic bundle created");
        manager.installedBundle = bundle;
        NSString *main = [bundle stringByAppendingPathComponent:@"Reddit"];
        Check([[@"synthetic executable" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:main atomically:NO] &&
            chmod(main.fileSystemRepresentation,0700) == 0, @"synthetic executable fixture");
        NSArray *callbacks = @[@{@"CFBundleURLName":@"source.callback",@"CFBundleURLSchemes":@[@"reddit"]}];
        NSMutableDictionary *input = [@{@"CFBundleExecutable":@"Reddit",@"CFBundleIdentifier":@"com.reddit.Reddit",
            @"CFBundleURLTypes":callbacks,@"CFBundleVersion":@"664762",@"FixturePreserved":@"unchanged"} mutableCopy];
        input[@"CFBundleIdentifier"] = descriptor[@"sourceBundleIdentifier"];
        if (facebook) input[@"FBKeychainAccessGroup"] = @"T84QZS65DQ.platformFamily";
        if (inherited != NSNull.null) input[@"SBIconVisibilityDefaultVisible"] = inherited;
        NSString *infoPath = [bundle stringByAppendingPathComponent:@"Info.plist"];
        Check([input writeToFile:infoPath atomically:NO], @"source metadata fixture");
        NSMutableDictionary *profile = [@{@"containerId":@"visibility-fixture",@"device":@{},@"serials":@{},@"ids":@{},
            @"timing":@{},@"reddit":@{},@"mgOverrides":@{},@"security":@{@"appAttest":@"blocked"},
            @"installationTransaction":@"synthetic-transaction",@"app":@{@"architecture":@"clonedApp-v2",
                @"bundleIdentifier":identifier,@"bundlePath":bundle,@"keychainAccessGroup":group,
                @"sourceVersion":@"2026.36.0",@"sourceBuild":@"664762"}} mutableCopy];
        NSMutableDictionary *app = [profile[@"app"] mutableCopy];
        [app addEntriesFromDictionary:RBXAppKeychainMetadata(descriptor,identifier)];
        profile[@"app"] = app;
        if (facebook) { profile[@"appType"] = @"facebook"; [profile removeObjectForKey:@"reddit"]; }
        if (facebook) {
            NSMutableDictionary *badProfile = profile.mutableCopy, *badApp = app.mutableCopy;
            [badApp removeObjectForKey:@"keychainAccessGroups"]; badProfile[@"app"] = badApp;
            NSUInteger before = SignCalls;
            Check(![manager _rewriteAndSignBundle:bundle bundleIdentifier:identifier nickname:@"Fixture" profile:badProfile error:nil] && SignCalls == before,
                @"incomplete Facebook bootstrap cannot reach mutation or signing");
        }
        NSUInteger beforeSign = SignCalls, beforeInspect = InspectCalls, beforeOwner = OwnershipCalls;
        NSError *error = nil;
        Check([manager _rewriteAndSignBundle:bundle bundleIdentifier:identifier nickname:@"Fixture" profile:profile error:&error] && !error,
            @"actual full rewrite completes with synthetic signer");
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        Check(!info[@"SBIconVisibilityDefaultVisible"], @"produced metadata excludes both newly added and inherited unsupported visibility flag");
        Check([info[@"SBAppTags"] isEqual:@[@"hidden"]] && [info[@"RBXLauncherOnly"] isEqual:@YES], @"required hidden and launcher metadata retained");
        Check([info[@"CFBundleIdentifier"] isEqual:identifier] && [info[@"FixturePreserved"] isEqual:@"unchanged"] &&
            [info[@"CFBundleVersion"] isEqual:@"664762"], @"bundle identity and unrelated metadata unchanged");
        Check([info[@"CFBundleURLTypes"][0] isEqual:callbacks[0]] && [info[@"CFBundleURLTypes"] count] == 2,
            @"source callback and clone callback policy retained");
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@".redditbox-clone.plist"]];
        Check([metadata[@"launcherOnly"] isEqual:@YES] && [metadata[@"keychainAccessGroup"] isEqual:group] &&
            [metadata[@"containerId"] isEqual:@"visibility-fixture"], @"clone marker and isolated keychain identity retained");
        NSArray *groups = facebook ? @[group,[group stringByAppendingString:@".family"],[group stringByAppendingString:@".app"]] : @[group];
        Check([SignedEntitlements isEqual:@{@"application-identifier":group,@"com.apple.developer.team-identifier":descriptor[@"teamIdentifier"],@"keychain-access-groups":groups}],
            @"Reddit keeps its singleton; Facebook receives three exact groups and no source/shared entitlements");
        NSDictionary *bootstrap = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:
            [bundle stringByAppendingPathComponent:@"RedditBoxProfile.json"]] options:0 error:nil];
        if (facebook) {
            Check([info[@"FBKeychainAccessGroup"] isEqual:group], @"Facebook plist hint rewritten to its own primary");
            Check([metadata[@"formatVersion"] isEqual:@2] && [metadata[@"appType"] isEqual:@"facebook"] &&
                [metadata[@"keychainAccessGroups"] isEqual:groups] && [metadata[@"keychainPolicyVersion"] isEqual:@1],
                @"actual rewrite persists versioned complete group metadata");
            Check([bootstrap[@"app"][@"keychainAccessGroups"] isEqual:groups] && [bootstrap[@"app"][@"keychainPolicyVersion"] isEqual:@1],
                @"actual signed bootstrap carries the same complete group set");
        } else {
            Check([metadata[@"formatVersion"] isEqual:@1] && !metadata[@"appType"] && !metadata[@"keychainAccessGroups"] &&
                !metadata[@"keychainPolicyVersion"] && !bootstrap[@"app"][@"keychainAccessGroups"], @"Reddit marker and bootstrap retain legacy shape");
        }
        Check(SignCalls == beforeSign + 1 && InspectCalls == beforeInspect + 1 && OwnershipCalls == beforeOwner + 1,
            @"rewrite signing, inspection and ownership boundaries unchanged");
        BOOL admitted = [descriptor[@"runnable"] boolValue];
        Check([manager validateCloneForProfile:profile error:&error] == admitted && (admitted ? !error : error != nil), @"actual validator accepts complete clone only when compiled app admission is enabled");
        if (facebook && admitted) {
            for (NSString *key in @[@"formatVersion",@"appType",@"sourceBundleIdentifier",@"keychainAccessGroup",@"keychainPolicyVersion",@"keychainAccessGroups"]) {
                NSMutableDictionary *bad = metadata.mutableCopy; [bad removeObjectForKey:key];
                [bad writeToFile:[bundle stringByAppendingPathComponent:@".redditbox-clone.plist"] atomically:NO];
                Check(![manager validateCloneForProfile:profile error:nil], @"actual clone validator rejects every missing marker ownership/group field");
            }
            [metadata writeToFile:[bundle stringByAppendingPathComponent:@".redditbox-clone.plist"] atomically:NO];
        }
        for (NSString *required in @[@"SBAppTags",@"RBXLauncherOnly"]) {
            NSMutableDictionary *invalid = [info mutableCopy]; [invalid removeObjectForKey:required];
            Check([invalid writeToFile:infoPath atomically:NO], @"tampered metadata fixture"); error = nil;
            Check(![manager validateCloneForProfile:profile error:&error] && error, @"actual validator still rejects missing required hidden or launcher marker");
        }
        Check([info writeToFile:infoPath atomically:NO], @"restore synthetic metadata");
    }
    }
    Check([NSFileManager.defaultManager removeItemAtPath:root error:nil], @"remove synthetic bundles only");
    printf("Clone visibility metadata: %lu checks, %lu failures; no SpringBoard or real signing invoked\n",(unsigned long)Checks,(unsigned long)Failures);
    return Failures ? 1 : 0;
} }
'''.replace("__HELPERS__", helpers).replace("__METHODS__", methods)
with tempfile.TemporaryDirectory(prefix="redditbox-visibility-build-") as build:
    path = Path(build) / "fixture.m"
    path.write_text(fixture)
    for active in (False, True):
        headers = Path(build) / ("active" if active else "inactive")
        headers.mkdir()
        for header in (ROOT / "shared").glob("*.h"):
            (headers / header.name).write_bytes(header.read_bytes())
        registry = headers / "RBXAppRegistryData.h"
        before, facebook = registry.read_text().split('@"appType": @"facebook",', 1)
        facebook, count = re.subn(r'@"runnable": @(YES|NO),', '@"runnable": @' + ('YES' if active else 'NO') + ',', facebook, count=1)
        assert count == 1
        registry.write_text(before + '@"appType": @"facebook",' + facebook)
        executable = headers / "fixture"
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                        "-Werror=misleading-indentation", "-I" + str(headers),
                        "-framework", "Foundation", str(path), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)
