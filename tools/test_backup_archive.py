#!/usr/bin/env python3
"""LIFE-015: real extractor versus harmless hostile tar fixtures in a temp tree.

Baseline support executes the former RBXCloudUntar body verbatim with /usr/bin/tar.
The fixed implementation is included directly; reduced limits make size/entry
boundary tests small. No phone, network, accounts or non-fixture files are used.
"""
import io
import gzip
import os
import pathlib
import subprocess
import tarfile
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
header = ROOT / "daemon/RBXBackupArchive.h"
implementation = r'''
#define RBX_BACKUP_MAX_FILE_BYTES 1024
#define RBX_BACKUP_MAX_TOTAL_BYTES 4096
#define RBX_BACKUP_MAX_ENTRIES 32
#import "RBXBackupArchive.h"
static BOOL Extract(NSString *archive, NSString *stage, BOOL cancelled, NSError **error) {
    __block NSUInteger checks = 0;
    return RBXExtractBackupArchive(archive, stage, @"account-a", ^BOOL(NSError **inner) {
        BOOL stop = cancelled && ++checks >= 4;
        if (stop && inner) *inner = [NSError errorWithDomain:@"fixture" code:1 userInfo:nil];
        return !stop;
    }, error);
}
'''
if not header.exists():
    source = (ROOT / "daemon/RBXCloudSync.m").read_text()
    start = source.index("static BOOL RBXCloudUntar(")
    old = source[start:source.index("\n}\n", start) + 3]
    implementation = r'''
@interface RBXOperationContext : NSObject @end
@implementation RBXOperationContext @end
static BOOL RBXCloudSpawnTar(NSArray *args, RBXOperationContext *context, NSError **error) {
    (void)context; NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/tar"]; task.arguments = args;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:error]) return NO;
    [task waitUntilExit]; return task.terminationStatus == 0;
}
''' + old + r'''
static BOOL Extract(NSString *archive, NSString *stage, BOOL cancelled, NSError **error) {
    (void)cancelled;
    return RBXCloudUntar(archive, stage, nil, error);
}
'''

fixture = r'''
#import <Foundation/Foundation.h>
#import <sys/stat.h>
__IMPLEMENTATION__
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 2) return 2;
    NSString *root = [NSString stringWithUTF8String:argv[1]];
    NSArray *valid = @[@"valid", @"legacy"];
    NSArray *bad = @[@"symlink", @"hardlink", @"traversal", @"absolute", @"duplicate", @"case-alias",
                     @"special", @"overwrite-record", @"oversized", @"expanded", @"entry-count", @"mixed-root",
                     @"sparse", @"truncated", @"preexisting-link"];
    unsigned failures = 0, cases = 0;
    for (NSString *name in [valid arrayByAddingObjectsFromArray:[bad arrayByAddingObject:@"cancelled"]]) {
        NSString *stage = [root stringByAppendingPathComponent:[name stringByAppendingString:@"-stage"]];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:stage withIntermediateDirectories:NO
                      attributes:@{NSFilePosixPermissions:@0700} error:nil];
        NSString *receipt = [stage stringByAppendingPathComponent:@"operation-recovery.plist"];
        [@"retained" writeToFile:receipt atomically:YES encoding:NSUTF8StringEncoding error:nil];
        BOOL cancel = [name isEqual:@"cancelled"];
        BOOL existingLink = [name isEqual:@"preexisting-link"];
        if (existingLink) [fm createSymbolicLinkAtPath:[stage stringByAppendingPathComponent:@"AppData"]
            withDestinationPath:root error:nil];
        NSString *archive = [root stringByAppendingPathComponent:
            [(cancel || existingLink ? @"valid" : name) stringByAppendingString:@".tar.gz"]];
        NSError *error = nil;
        BOOL result = Extract(archive, stage, cancel, &error), expected = [valid containsObject:name];
        BOOL ok = result == expected && [[NSString stringWithContentsOfFile:receipt
            encoding:NSUTF8StringEncoding error:nil] isEqual:@"retained"] &&
            [[NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"outside"]
                encoding:NSUTF8StringEncoding error:nil] isEqual:@"outside-sentinel"];
        if (expected) {
            NSString *path = [stage stringByAppendingPathComponent:[name isEqual:@"legacy"]
                ? @"account-a/Library/Preferences/state.plist" : @"AppData/Library/Preferences/state.plist"];
            ok = ok && [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]
                isEqual:@"same-account-state"];
        }
        cases++;
        if (!ok) { failures++; fprintf(stderr,"FAIL: %s (accepted=%d expected=%d)\n",name.UTF8String,result,expected); }
    }
    printf("%s: %u bounded backup archive cases\n",failures ? "FAIL" : "PASS",cases);
    return failures ? 1 : 0;
} }
'''.replace("__IMPLEMENTATION__", implementation)

with tempfile.TemporaryDirectory(prefix="rbx-backup-archive-") as directory:
    folder = pathlib.Path(directory)
    (folder / "outside").write_text("outside-sentinel")

    def archive(name, entries):
        with tarfile.open(folder / (name + ".tar.gz"), "w:gz") as tar:
            for path, kind, value in entries:
                info = tarfile.TarInfo(path)
                if kind == "file":
                    data = value if isinstance(value, bytes) else value.encode()
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))
                else:
                    info.mode = 0o755
                    info.type = {"dir": tarfile.DIRTYPE, "symlink": tarfile.SYMTYPE,
                                 "hardlink": tarfile.LNKTYPE, "fifo": tarfile.FIFOTYPE}[kind]
                    if kind in ("symlink", "hardlink"):
                        info.linkname = value
                    tar.addfile(info)

    archive("valid", [("AppData", "dir", ""), ("AppData/Library/Preferences/state.plist", "file", "same-account-state")])
    archive("legacy", [("account-a/Library/Preferences/state.plist", "file", "same-account-state")])
    archive("symlink", [("AppData/link", "symlink", "../../outside")])
    archive("hardlink", [("AppData/data", "file", "owned"), ("AppData/link", "hardlink", "AppData/data")])
    archive("traversal", [("AppData/../../outside", "file", "changed")])
    archive("absolute", [(str(folder / "outside"), "file", "changed")])
    archive("duplicate", [("AppData/state", "file", "first"), ("AppData/state", "file", "second")])
    archive("case-alias", [("AppData/Library/a", "file", "first"), ("AppData/library/b", "file", "second")])
    archive("special", [("AppData/fifo", "fifo", "")])
    archive("overwrite-record", [("operation-recovery.plist", "file", "forged")])
    archive("oversized", [("AppData/big", "file", b"x" * 1025)])
    archive("expanded", [(f"AppData/item-{i}", "file", b"x" * 1024) for i in range(5)])
    archive("entry-count", [(f"AppData/dir-{i}", "dir", "") for i in range(33)])
    archive("mixed-root", [("AppData/a", "file", "a"), ("account-a/b", "file", "b")])
    info = tarfile.TarInfo("AppData/truncated")
    info.size = 100
    (folder / "truncated.tar.gz").write_bytes(gzip.compress(info.tobuf() + b"incomplete"))
    with tarfile.open(folder / "sparse.tar.gz", "w:gz") as tar:
        info = tarfile.TarInfo("AppData/sparse")
        info.size = 1
        info.pax_headers = {"GNU.sparse.map": "0,1", "GNU.sparse.realsize": "16"}
        tar.addfile(info, io.BytesIO(b"x"))
    source = folder / "test.m"
    source.write_text(fixture)
    binary = folder / "test"
    include = pathlib.Path(os.environ.get("LIBARCHIVE_INCLUDE", "/opt/homebrew/opt/libarchive/include"))
    flags = ["-I" + str(include)] if include.exists() else []
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wno-nullability-completeness",
                    "-I" + str(ROOT / "daemon"), "-I" + str(ROOT / "shared"), *flags,
                    "-framework", "Foundation", str(source), "-larchive", "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(folder)], check=True)
