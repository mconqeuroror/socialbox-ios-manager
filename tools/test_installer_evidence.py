#!/usr/bin/env python3
"""Actual installer method and evidence helpers; synthetic process provider, real private files."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "daemon/RBXCloneManager.m").read_text()
start = source.index("- (BOOL)_installIPA:", source.index("@implementation RBXCloneManager"))
opening = source.index("{", start)
depth = 1
end = opening + 1
while depth:
    depth += (source[end] == "{") - (source[end] == "}")
    end += 1
method = source[start:end]
marker = "// Private evidence for this installer invocation only."
helpers = source[source.index(marker):source.index("// End installer evidence helpers.")] if marker in source else ""

fixture = r'''
#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <signal.h>
#import <unistd.h>
#import <errno.h>
#import <math.h>
#import "RBXAppLifecycle.h"
#define RBX_INSTALL_EVIDENCE_TESTING 1
static NSString *RBXTransactionsRoot, *CurrentDirectory;
static BOOL Succeed, Fenced, ReceiptBeforeFence, WrongOwner;
static NSUInteger Calls, MaximumBytes;
static NSString *Capture;
static NSDictionary *FailureDetails;
static NSError *ProviderError;
static NSUInteger Checks;
static NSDictionary *FixtureDescriptor;
static void Check(BOOL ok, NSString *message) {
    Checks++;
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static NSArray *Evidence(NSString *extension) {
    NSMutableArray *found = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:CurrentDirectory error:nil])
        if ([name hasPrefix:@"installer-"] && [name.pathExtension isEqual:extension]) [found addObject:name];
    return found;
}
@interface RBXOperationContext : NSObject
+ (instancetype)currentContext;
- (BOOL)markUnsafeWithReason:(NSString *)reason error:(NSError **)error;
@end
@implementation RBXOperationContext
+ (instancetype)currentContext { static id context; if (!context) context = [self new]; return context; }
- (BOOL)markUnsafeWithReason:(NSString *)reason error:(NSError **)error {
    (void)reason; (void)error;
    ReceiptBeforeFence = Evidence(@"plist").count > 0; Fenced = YES; return YES;
}
@end
static NSError *RBXCloneError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.redditbox.clone" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL RBXCloneMayMutate(NSError **error) { (void)error; return YES; }
static NSString *RBXExecutable(NSString *name) { (void)name; return @"/private/fixture/appinst"; }
static BOOL Run(NSString *executable, NSArray *arguments, NSString *output, NSUInteger maximum, NSError **error) {
    (void)executable; (void)arguments; Calls++; Capture = output; MaximumBytes = maximum;
    if (output) {
        int fd = open(output.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        Check(fd >= 0, @"capture is unique and does not replace an existing object");
        const char bytes[] = "private installer output: synthetic account, path, identifier\n";
        Check(write(fd, bytes, sizeof(bytes) - 1) == sizeof(bytes) - 1, @"synthetic bounded stdout written");
        close(fd);
    }
    if (!Succeed && error) *error = ProviderError;
    return Succeed;
}
static BOOL RBXSpawnAndWait(NSString *executable, NSArray *arguments, NSError **error) {
    return Run(executable, arguments, nil, 0, error);
}
@interface RBXBoundedProcess : NSObject
+ (BOOL)runExecutable:(NSString *)executable arguments:(NSArray *)arguments context:(id)context
    outputPath:(NSString *)path maximumOutputBytes:(NSUInteger)maximum error:(NSError **)error;
@end
@implementation RBXBoundedProcess
+ (BOOL)runExecutable:(NSString *)executable arguments:(NSArray *)arguments context:(id)context
    outputPath:(NSString *)path maximumOutputBytes:(NSUInteger)maximum error:(NSError **)error {
    (void)context; return Run(executable, arguments, path, maximum, error);
}
@end
static int TestFstat(int fd, struct stat *info) {
    int result = fstat(fd, info); if (!result && WrongOwner) info->st_uid++; return result;
}
#define fstat TestFstat
__HELPERS__
#undef fstat
@interface Installer : NSObject
@property NSDictionary *appDescriptor;
- (BOOL)_installIPA:(NSString *)ipa error:(NSError **)error;
@end
@implementation Installer
__METHOD__
@end
static NSString *MakeTransaction(NSString *name) {
    CurrentDirectory = [RBXTransactionsRoot stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    Check([NSFileManager.defaultManager createDirectoryAtPath:CurrentDirectory withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions:@0700} error:nil], @"create private transaction");
    NSString *ipa = [CurrentDirectory stringByAppendingPathComponent:name];
    Check([[@"synthetic IPA" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:ipa atomically:NO], @"write owned IPA");
    chmod(ipa.fileSystemRepresentation, 0600);
    NSString *journal = [CurrentDirectory stringByAppendingPathComponent:@"transaction.plist"];
    NSMutableDictionary *record=[RBXAppInstallationRecord(FixtureDescriptor,@"installer-fixture") mutableCopy];
    record[@"state"]=@"install-attempted";
    record[@"hadPreviousInstall"]=@NO;
    Check([record writeToFile:journal atomically:NO], @"write owned journal");
    chmod(journal.fileSystemRepresentation, 0600);
    Calls = 0; Fenced = ReceiptBeforeFence = NO; Capture = nil; MaximumBytes = 0;
    return ipa;
}
static void Rejected(Installer *installer, NSString *ipa) {
    NSUInteger calls = Calls; NSError *error = nil;
    Check(![installer _installIPA:ipa error:&error] && error && Calls == calls && !Fenced,
        @"unowned or malformed transaction is refused before installer execution");
    Check(![error.description containsString:ipa], @"refusal does not disclose the private path");
}
int main(void) { @autoreleasepool {
    char temporary[] = "/tmp/redditbox-installer-evidence.XXXXXX";
    Check(mkdtemp(temporary) != NULL, @"private fixture root");
    NSString *root = [NSString stringWithUTF8String:temporary];
    RBXTransactionsRoot = [root stringByAppendingPathComponent:@"transactions"];
    Check([NSFileManager.defaultManager createDirectoryAtPath:RBXTransactionsRoot withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions:@0700} error:nil], @"private transaction root");
    Installer *installer = [Installer new];
    FixtureDescriptor=RBXRedditAppDescriptor();installer.appDescriptor=FixtureDescriptor;
    for (NSString *name in @[@"clone.ipa", @"previous.ipa"]) {
        NSString *ipa = MakeTransaction(name);
        FailureDetails = @{NSLocalizedDescriptionKey:@"Helper exited unsuccessfully", @"childStarted":@YES,
            @"childQuiescent":@YES, @"exitCode":@19, @"untrusted":@"private value"};
        ProviderError = [NSError errorWithDomain:@"fixture.provider" code:7 userInfo:FailureDetails];
        NSError *error = nil;
        Check(![installer _installIPA:ipa error:&error] && error == ProviderError, @"installer keeps the exact original failure");
        Check(Capture.length && MaximumBytes == 65536 && Calls == 1, @"only installer stdout is captured once with a 64 KiB cap");
        Check([Capture.stringByDeletingLastPathComponent isEqual:CurrentDirectory] && Evidence(@"stdout").count == 1,
            @"failed stdout remains within its exact transaction");
        Check(Fenced && ReceiptBeforeFence, @"failure receipt is durably published before the existing installer fence");
        Check(Evidence(@"plist").count == 1, @"one private receipt for each failed installer invocation");
        NSString *receiptPath = [CurrentDirectory stringByAppendingPathComponent:Evidence(@"plist").firstObject];
        NSDictionary *receipt = [NSDictionary dictionaryWithContentsOfFile:receiptPath];
        Check([receipt isEqual:@{@"formatVersion":@1,@"childStarted":@YES,@"childQuiescent":@YES,@"exitCode":@19}],
            @"private receipt retains only normalized numeric termination fields");
        struct stat info;
        Check(lstat(receiptPath.fileSystemRepresentation,&info) == 0 && S_ISREG(info.st_mode) && !(info.st_mode & 0077), @"receipt is private");
        Check(lstat(Capture.fileSystemRepresentation,&info) == 0 && S_ISREG(info.st_mode) && !(info.st_mode & 0077), @"stdout is private");
    }
    NSArray *statusCases = @[
        @{@"childStarted":@YES,@"childQuiescent":@YES,@"terminationSignal":@(SIGTERM)},
        @{@"childStarted":@NO,@"childQuiescent":@YES},
        @{@"childStarted":@YES,@"childQuiescent":@NO,@"exitCode":@19},
        @{@"childStarted":@YES,@"childQuiescent":@YES,@"exitCode":@19,@"terminationSignal":@(SIGTERM)},
        @{@"childStarted":@YES,@"childQuiescent":@YES,@"exitCode":@1.5},
        @{@"childStarted":@YES,@"childQuiescent":@YES,@"exitCode":@YES},
        @{@"childStarted":@YES,@"childQuiescent":@YES,@"exitCode":@256},
        @{@"childStarted":@YES,@"childQuiescent":@YES,@"terminationSignal":@0},
        @{@"childStarted":@"unknown",@"childQuiescent":[NSNull null],@"exitCode":@19}
    ];
    for (NSUInteger index = 0; index < statusCases.count; index++) {
        NSString *ipa = MakeTransaction(@"clone.ipa");
        NSDictionary *input = statusCases[index];
        ProviderError = [NSError errorWithDomain:@"fixture.provider" code:7 userInfo:input];
        NSError *error = nil;
        Check(![installer _installIPA:ipa error:&error] && error == ProviderError && Calls == 1,
            @"status sanitation never reruns or replaces the original installer failure");
        NSDictionary *receipt = [NSDictionary dictionaryWithContentsOfFile:
            [CurrentDirectory stringByAppendingPathComponent:Evidence(@"plist").firstObject]];
        NSMutableDictionary *expected = [@{@"formatVersion":@1} mutableCopy];
        if (index < statusCases.count - 1) {
            expected[@"childStarted"] = input[@"childStarted"]; expected[@"childQuiescent"] = input[@"childQuiescent"];
        }
        if (!index) expected[@"terminationSignal"] = @(SIGTERM);
        Check([receipt isEqual:expected], @"unknown, unreaped, contradictory and malformed numeric status is never inferred");
        Check(Fenced == ![@NO isEqual:input[@"childStarted"]], @"original child-started fence semantics are unchanged");
    }
    NSString *ipa = MakeTransaction(@"clone.ipa"); Succeed = YES; NSError *error = nil;
    Check([installer _installIPA:ipa error:&error] && Calls == 1 && !Fenced && !error, @"successful install preserves behavior");
    Check(Evidence(@"stdout").count == 0 && Evidence(@"plist").count == 0, @"successful capture is removed without deleting the transaction");
    Check([NSFileManager.defaultManager fileExistsAtPath:ipa], @"success does not delete IPA or transaction");
    Succeed = NO;
    ipa = MakeTransaction(@"unexpected.ipa"); Rejected(installer, ipa);
    ipa = MakeTransaction(@"clone.ipa"); WrongOwner = YES; Rejected(installer, ipa); WrongOwner = NO;
    chmod(CurrentDirectory.fileSystemRepresentation, 0777); Rejected(installer, ipa); chmod(CurrentDirectory.fileSystemRepresentation, 0700);
    chmod(RBXTransactionsRoot.fileSystemRepresentation, 0777); Rejected(installer, ipa); chmod(RBXTransactionsRoot.fileSystemRepresentation, 0700);
    NSString *outside = [root stringByAppendingPathComponent:@"outside.ipa"];
    Check(rename(ipa.fileSystemRepresentation, outside.fileSystemRepresentation) == 0, @"move fixture IPA");
    Check(symlink(outside.fileSystemRepresentation, ipa.fileSystemRepresentation) == 0, @"symlink IPA fixture");
    Rejected(installer, ipa); unlink(ipa.fileSystemRepresentation);
    Check(link(outside.fileSystemRepresentation, ipa.fileSystemRepresentation) == 0, @"hardlink IPA fixture");
    Rejected(installer, ipa); unlink(ipa.fileSystemRepresentation);
    Check(rename(outside.fileSystemRepresentation, ipa.fileSystemRepresentation) == 0, @"restore fixture IPA");
    Rejected(installer, [root stringByAppendingPathComponent:@"clone.ipa"]);
    NSString *parked = [root stringByAppendingPathComponent:@"parked"];
    Check(rename(CurrentDirectory.fileSystemRepresentation, parked.fileSystemRepresentation) == 0 &&
        symlink(parked.fileSystemRepresentation, CurrentDirectory.fileSystemRepresentation) == 0, @"symlink parent fixture");
    Rejected(installer, ipa);
    unlink(CurrentDirectory.fileSystemRepresentation);
    Check(rename(parked.fileSystemRepresentation, CurrentDirectory.fileSystemRepresentation) == 0, @"restore parent fixture");
    NSString *journal = [CurrentDirectory stringByAppendingPathComponent:@"transaction.plist"];
    chmod(journal.fileSystemRepresentation,0666); Rejected(installer,ipa); chmod(journal.fileSystemRepresentation,0600);
    Check([[@"malformed" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:journal atomically:NO], @"malformed journal fixture");
    Rejected(installer,ipa);
    Check([[NSMutableData dataWithLength:65537] writeToFile:journal atomically:NO], @"oversized journal fixture");
    Rejected(installer,ipa);
    Check([@{@"formatVersion":@2,@"state":@"prepared"} writeToFile:journal atomically:NO], @"unattempted journal fixture");
    Rejected(installer,ipa);
    Check(unlink(journal.fileSystemRepresentation) == 0, @"remove fixture journal"); Rejected(installer, ipa);
    FixtureDescriptor=RBXAppDescriptorForType(@"facebook");
    for(NSString *name in @[@"clone.ipa",@"previous.ipa"]) {
        ipa=MakeTransaction(name); Succeed=YES;
        installer.appDescriptor=RBXRedditAppDescriptor();Rejected(installer,ipa);
        installer.appDescriptor=FixtureDescriptor;
        Check([installer _installIPA:ipa error:nil] && Calls==1,@"Facebook own format-3 journal reaches existing bounded installer");
        for(NSString *key in @[@"appType",@"sourceBundleIdentifier",@"containerId",@"bundleIdentifier",@"keychainAccessGroup",@"keychainPolicyVersion",@"keychainAccessGroups"]) {
            ipa=MakeTransaction(name);
            NSString *p=[CurrentDirectory stringByAppendingPathComponent:@"transaction.plist"];
            NSMutableDictionary *record=[[NSDictionary dictionaryWithContentsOfFile:p] mutableCopy];
            [record removeObjectForKey:key];Check([record writeToFile:p atomically:NO],@"incomplete Facebook journal fixture");
            Rejected(installer,ipa);
        }
    }
    Check([NSFileManager.defaultManager removeItemAtPath:root error:nil], @"remove synthetic fixture only");
    printf("Installer evidence: %lu checks passed (actual installer method, synthetic process provider)\n", (unsigned long)Checks);
    return 0;
} }
'''.replace("__HELPERS__", helpers).replace("__METHOD__", method)
with tempfile.TemporaryDirectory(prefix="redditbox-installer-build-") as build:
    path = Path(build) / "fixture.m"
    path.write_text(fixture)
    executable = Path(build) / "fixture"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                    "-Werror=misleading-indentation", "-Wno-unused-function", "-Wno-unused-variable",
                    "-I"+str(ROOT/'shared'), "-framework", "Foundation", "-framework", "Security", str(path), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
