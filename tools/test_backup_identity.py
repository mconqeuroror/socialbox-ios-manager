#!/usr/bin/env python3
"""LIFE-014: exercise the actual backup manifest validator with synthetic IDs.

Compile the Foundation-only functions verbatim from RBXCloudSync.m, together
with the real profile decoder. No phone, account, network or user files are used.
The legacy signature adapter permits this regression to reproduce the original
acceptance of a valid envelope belonging to a different selected backup.
"""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "daemon/RBXCloudSync.m").read_text()


def function(name):
    start = SOURCE.index("static ", SOURCE.index(name) - 24)
    # Functions in this file put their closing brace at column zero. Extract
    # source verbatim; the test must not duplicate the validation algorithm.
    end = SOURCE.index("\n}\n", start) + 3
    return SOURCE[start:end]


validator = function("RBXCloudValidateManifest")
current = "selectedContainerId" in validator.split("{")[0]
invocation = ("RBXCloudValidateManifest(manifest, selected, error)" if current else
              "RBXCloudValidateManifest(manifest, error)")
fixture = r'''
#import <Foundation/Foundation.h>
#import "RBXProfileIO.h"
#import "RBXAppRegistry.h"
__FUNCTIONS__
static BOOL Validate(NSDictionary *manifest, NSString *selected, NSError **error) {
    (void)selected;
    return __INVOCATION__;
}
static unsigned Cases, Failures;
static void Check(BOOL condition, NSString *label) {
    Cases++;
    if (!condition) { Failures++; fprintf(stderr, "FAIL: %s\n", label.UTF8String); }
}
int main(void) { @autoreleasepool {
    NSDictionary *manifest = @{ @"containerId": @"account-a" };
    NSError *error = nil;
    Check(Validate(manifest, @"account-a", &error) && !error,
          @"same logical source identity accepted; no regeneration required");
    for (id selected in @[@"account-b", @"", @"../account-a", @"ACCOUNT-A", @42, NSNull.null]) {
        error = nil;
        Check(!Validate(manifest, selected, &error) && error,
              [NSString stringWithFormat:@"reject selected identity %@ before restore", selected]);
    }
    error = nil;
    Check(!Validate(manifest, nil, &error) && error, @"missing selected owner rejected");
    for (id bad in @[@{}, @{ @"containerId": @42 }, @{ @"containerId": @"../account-a" },
                      @{ @"containerId": @"account-a", @"profileSeed": @42 }]) {
        error = nil;
        Check(!Validate(bad, @"account-a", &error) && error, @"existing manifest validation retained");
    }
    // The old schema is still accepted when its ownership is well formed.
    error = nil;
    Check(Validate(@{@"containerId":@"legacy-profile", @"profileSeed":@{}},
                   @"legacy-profile", &error) && !error, @"legacy seed with exact selected owner accepted");
    // APP-003: backup restoration still reconstructs Reddit profiles. It must
    // not silently discard another app's type and import its data into Reddit.
    // Validate the actual shipped manifest helper, including the real decoder.
    for (NSString *placement in @[@"manifest", @"profile", @"profileSeed"]) {
        NSMutableDictionary *typed = [manifest mutableCopy];
        if ([placement isEqual:@"manifest"]) typed[@"appType"] = @"reddit";
        else typed[placement] = @{@"containerId":@"account-a", @"appType":@"reddit"};
        NSData *before = [NSJSONSerialization dataWithJSONObject:typed options:NSJSONWritingSortedKeys error:nil];
        error = nil;
        Check(Validate(typed,@"account-a",&error) && !error,
            [NSString stringWithFormat:@"explicit Reddit %@ retains legacy restore",placement]);
        Check([before isEqual:[NSJSONSerialization dataWithJSONObject:typed options:NSJSONWritingSortedKeys error:nil]],
            @"validation does not rewrite profile or envelope bytes");
        for (id appType in @[@"facebook", @"instagram", @"unknown", @"", @"Reddit", @42, @YES, @[], @{}, NSNull.null]) {
            if ([placement isEqual:@"manifest"]) typed[@"appType"] = appType;
            else typed[placement] = @{@"containerId":@"account-a", @"appType":appType};
            error = nil;
            Check(!Validate(typed,@"account-a",&error) && error,
                [NSString stringWithFormat:@"reject %@ appType %@ before restore",placement,appType]);
        }
    }
    error = nil;
    Check(!Validate(@{@"containerId":@"account-a", @"appType":@"reddit",
        @"profile":@{@"containerId":@"account-a",@"appType":@"facebook"}}, @"account-a", &error) && error,
        @"outer Reddit declaration cannot override foreign profile ownership");
    printf("%s: %u backup owner/manifest cases\n", Failures ? "FAIL" : "PASS", Cases);
    return Failures ? 1 : 0;
} }
'''
fixture = fixture.replace("__FUNCTIONS__", "\n".join([
    function("RBXCloudInputError"), function("RBXCloudOptionalStrings"), function("RBXCloudBackupDescriptor"), validator]))
fixture = fixture.replace("__INVOCATION__", invocation)
with tempfile.TemporaryDirectory(prefix="rbx-backup-identity-") as directory:
    source = pathlib.Path(directory) / "test.m"
    binary = pathlib.Path(directory) / "test"
    source.write_text(fixture)
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wno-nullability-completeness",
                    "-Wno-deprecated-declarations", "-I" + str(ROOT / "daemon"),
                    "-I" + str(ROOT / "shared"), "-framework", "Foundation",
                    str(source), str(ROOT / "daemon/RBXProfileIO.m"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
