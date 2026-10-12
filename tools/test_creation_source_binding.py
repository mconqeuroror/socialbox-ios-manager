"""Run CloneManager's shipped source-binding method against temporary files.

Exercises filesystem identity and invalid source shapes. The fixture executable
is inert bytes: this is not a Mach-O decryption or whole-bundle audit test.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "daemon/RBXCloneManager.m").read_text()
start = source.index("- (NSDictionary *)creationSourceBinding {")
end = source.index("- (NSDictionary *)sourceStatus {", start)
method = source[start:end]

fixture = r'''
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

static NSUInteger Checks;
static NSFileManager *FM;
static NSString *Root;
static void Check(BOOL ok, NSString *reason) {
    Checks++; if (!ok) { fprintf(stderr,"FAIL: %s\n",reason.UTF8String); exit(1); }
}
@interface SourceFixture : NSObject
@property(nonatomic, copy) NSString *sourcePath;
- (NSString *)_sourceRedditBundle;
- (NSDictionary *)creationSourceBinding;
@end
@implementation SourceFixture
- (NSString *)_sourceRedditBundle { return self.sourcePath; }
__METHOD__
@end

static NSString *Path(NSString *name) { return [Root stringByAppendingPathComponent:name]; }
static void Remove(NSString *path) { [FM removeItemAtPath:path error:nil]; }
static void Write(NSString *path, NSData *data) {
    Check([data writeToFile:path options:0 error:nil],@"fixture file written");
}
static NSDictionary *Info(id executable) {
    NSMutableDictionary *info=[@{@"CFBundleIdentifier":@"com.reddit.Reddit",@"CFBundleShortVersionString":@"same-version",@"CFBundleVersion":@"42"} mutableCopy];
    if (executable) info[@"CFBundleExecutable"]=executable;
    return info;
}
static void WriteInfo(NSString *bundle, NSDictionary *info) {
    NSData *bytes=[NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    Write([bundle stringByAppendingPathComponent:@"Info.plist"],bytes);
}
static NSString *MakeBundle(NSString *name) {
    NSString *bundle=Path(name);
    Check([FM createDirectoryAtPath:bundle withIntermediateDirectories:YES attributes:nil error:nil],@"fixture bundle made");
    WriteInfo(bundle,Info(@"App"));
    Write([bundle stringByAppendingPathComponent:@"App"],[@"executable-body-a" dataUsingEncoding:NSUTF8StringEncoding]);
    Check(chmod([[bundle stringByAppendingPathComponent:@"App"] fileSystemRepresentation],0700)==0,@"fixture executable permissions set");
    return bundle;
}
static void RewriteInPlace(NSString *path, NSData *bytes) {
    int file=open(path.fileSystemRepresentation,O_WRONLY);
    Check(file>=0,@"fixture opens inode for in-place update");
    struct stat old; Check(fstat(file,&old)==0,@"fixture captures file identity");
    Check(pwrite(file,bytes.bytes,bytes.length,0)==(ssize_t)bytes.length && ftruncate(file,bytes.length)==0,@"fixture content updated without replacing inode");
    struct timespec times[2]={old.st_atimespec,old.st_mtimespec};
    times[1].tv_sec+=1; // Deterministic changed mtime; no sleeps or timestamp-resolution assumptions.
    Check(futimens(file,times)==0,@"fixture marks in-place write timestamp");
    struct stat now; Check(fstat(file,&now)==0&&now.st_ino==old.st_ino,@"in-place fixture retains exact inode");
    close(file);
}
int main(int argc,char **argv) { @autoreleasepool {
    Root=[NSString stringWithUTF8String:argv[1]]; FM=NSFileManager.defaultManager;
    SourceFixture *manager=[SourceFixture new];
    Check(!manager.creationSourceBinding,@"missing source resolution returns no authority");
    manager.sourcePath=Path(@"missing.app");
    Check(!manager.creationSourceBinding,@"nonexistent bundle returns no authority");
    NSString *bundle=MakeBundle(@"Reddit.app"), *plist=[bundle stringByAppendingPathComponent:@"Info.plist"], *exe=[bundle stringByAppendingPathComponent:@"App"];
    manager.sourcePath=bundle;
    NSDictionary *initial=manager.creationSourceBinding;
    Check(initial&&[initial[@"entries"] count]==3&&[initial[@"path"] isEqual:bundle],@"valid bundle binds directory metadata and executable");
    Check([manager.creationSourceBinding isEqual:initial],@"unchanged source binding remains stable");
    Check(![initial.description containsString:@"executable-body"]&&!initial[@"CFBundleVersion"],@"binding includes file identities rather than sensitive file bytes or version-only assertion");

    NSString *link=Path(@"linked.app");
    Check(symlink(bundle.fileSystemRepresentation,link.fileSystemRepresentation)==0,@"fixture source symlink made");
    manager.sourcePath=link;
    Check(!manager.creationSourceBinding,@"symlinked source bundle rejected");
    manager.sourcePath=bundle;
    Check([FM moveItemAtPath:plist toPath:Path(@"real-info.plist") error:nil],@"fixture saves real metadata");
    Check(symlink(Path(@"real-info.plist").fileSystemRepresentation,plist.fileSystemRepresentation)==0,@"fixture metadata symlink made");
    Check(!manager.creationSourceBinding,@"symlinked Info.plist rejected");
    Remove(plist); WriteInfo(bundle,Info(@"App"));
    Check([FM moveItemAtPath:exe toPath:Path(@"real-exe") error:nil],@"fixture saves real executable");
    Check(symlink(Path(@"real-exe").fileSystemRepresentation,exe.fileSystemRepresentation)==0,@"fixture executable symlink made");
    Check(!manager.creationSourceBinding,@"symlinked executable rejected");
    Remove(exe);
    Check(!manager.creationSourceBinding,@"missing executable rejected");
    Write(exe,[@"executable-body-a" dataUsingEncoding:NSUTF8StringEncoding]);

    for (id invalid in @[@"",@"../outside",@"nested/App",@"/absolute",@42]) {
        WriteInfo(bundle,Info(invalid));
        Check(!manager.creationSourceBinding,@"empty nonstring absolute or nested executable name rejected");
    }
    WriteInfo(bundle,Info(nil));
    Check(!manager.creationSourceBinding,@"missing executable metadata rejected");
    Write(plist,[@"not a property list" dataUsingEncoding:NSUTF8StringEncoding]);
    Check(!manager.creationSourceBinding,@"unparseable Info.plist rejected");
    WriteInfo(bundle,Info(@"App"));

    initial=manager.creationSourceBinding;
    NSString *retired=Path(@"Retired.app");
    Check([FM moveItemAtPath:bundle toPath:retired error:nil],@"fixture retains former source");
    bundle=MakeBundle(@"Reddit.app");
    Check(![manager.creationSourceBinding isEqual:initial],@"same-path same-version source replacement invalidates authority");
    plist=[bundle stringByAppendingPathComponent:@"Info.plist"]; exe=[bundle stringByAppendingPathComponent:@"App"];
    initial=manager.creationSourceBinding;
    NSMutableDictionary *updatedInfo=[Info(@"App") mutableCopy]; updatedInfo[@"NewMetadata"]=@"changed";
    RewriteInPlace(plist,[NSPropertyListSerialization dataWithPropertyList:updatedInfo format:NSPropertyListXMLFormat_v1_0 options:0 error:nil]);
    Check(![manager.creationSourceBinding isEqual:initial],@"in-place metadata edit invalidates unchanged source version and inode");
    initial=manager.creationSourceBinding;
    RewriteInPlace(exe,[@"executable-body-b" dataUsingEncoding:NSUTF8StringEncoding]);
    Check(![manager.creationSourceBinding isEqual:initial],@"same-length in-place executable edit invalidates unchanged source version and inode");
    initial=manager.creationSourceBinding;
    Check([FM moveItemAtPath:exe toPath:Path(@"old-executable") error:nil],@"fixture retains prior executable");
    Write(exe,[@"executable-body-b" dataUsingEncoding:NSUTF8StringEncoding]);
    Check(![manager.creationSourceBinding isEqual:initial],@"same-bytes executable replacement invalidates inode binding");

    Remove(exe);
    Check([FM createDirectoryAtPath:exe withIntermediateDirectories:NO attributes:nil error:nil],@"fixture directory at executable name made");
    Check(!manager.creationSourceBinding,@"executable must be a regular file, not a directory");
    Remove(exe);
    for (NSString *invalid in @[@".",@".."]) {
        WriteInfo(bundle,Info(invalid));
        Check(!manager.creationSourceBinding,@"dot executable references are not a source binary");
    }
    printf("PASS actual source binding: %lu checks; missing/invalid/link sources, same-version replacement and in-place metadata/executable changes.\n",(unsigned long)Checks);
}}
'''.replace("__METHOD__", method)

with tempfile.TemporaryDirectory(prefix="rbx-creation-source-") as tmp:
    path = Path(tmp)
    (path / "test.m").write_text(fixture)
    subprocess.run([
        "xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
        "-framework", "Foundation", str(path / "test.m"), "-o", str(path / "test"),
    ], check=True)
    subprocess.run([str(path / "test"), str(path)], check=True)
