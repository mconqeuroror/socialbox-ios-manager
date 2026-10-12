#!/usr/bin/env python3
"""Exercise actual profile decoding and clone wrappers against foreign metadata.

Only the operation/context and sandbox lookup boundaries are inert fixtures;
control publication executes the actual implementation into a temporary sandbox.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'daemon/RBXCloneManager.m').read_text()

def method(signature):
    begin = source.index(signature)
    return source[begin:source.index('\n}\n', begin) + 3]

fixture = r'''
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>
#import "RBXProfileIO.h"
#import "RBXAppAdmission.h"
#import "RBXAppBundlePolicy.h"
static NSUInteger entries, mutations, lookups, failures, cases;
static void Check(BOOL ok, NSString *message) {
    cases++; if (!ok) { failures++; fprintf(stderr, "FAIL: %s\n", message.UTF8String); }
}
static NSError *RBXCloneError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"fixture.clone" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL RBXCloneMayMutate(NSError **error) { return YES; }
static BOOL RBXCloneContinue(NSError **error) { return YES; }
static BOOL RBXContainerAvailable(NSString *container, NSError **error) { return YES; }
static BOOL RBXBootstrapIsRedacted(NSString *path) { return YES; }
static BOOL RBXBootstrapMatchesIdentity(NSString *path, NSDictionary *profile) { return YES; }
@interface RBXOperationContext : NSObject
@property(nonatomic) BOOL inspectionOnly;
+ (instancetype)currentContext;
- (BOOL)beginWork:(NSError **)error;
- (BOOL)check:(NSError **)error;
- (void)performBlock:(dispatch_block_t)block;
- (void)endWork;
@end
@implementation RBXOperationContext
+ (instancetype)currentContext { return [self new]; }
- (BOOL)beginWork:(NSError **)error { entries++; return YES; }
- (BOOL)check:(NSError **)error { return YES; }
- (void)performBlock:(dispatch_block_t)block { block(); }
- (void)endWork {}
@end
@interface RBXCloneManager : NSObject
@property(nonatomic,strong) RBXOperationContext *operationContext;
@property(nonatomic,strong) NSDictionary *appDescriptor;
@property(nonatomic,copy) NSString *sandbox;
@property(nonatomic,copy) NSString *installedBundle;
- (NSString *)_installedBundleForIdentifier:(NSString *)identifier;
- (NSDictionary *)sourceStatus;
- (NSString *)dataContainerForBundleIdentifier:(NSString *)identifier;
- (NSDictionary *)_operation_ensureCloneForContainer:(NSString *)container profile:(NSDictionary *)profile nickname:(NSString *)nickname error:(NSError **)error;
- (BOOL)_operation_syncProfile:(NSDictionary *)profile error:(NSError **)error;
- (BOOL)_operation_writeControlPlist:(NSDictionary *)document profile:(NSDictionary *)profile name:(NSString *)name error:(NSError **)error;
@end
@implementation RBXCloneManager
- (NSDictionary *)sourceStatus { return @{@"decrypted":@YES}; }
- (NSString *)_installedBundleForIdentifier:(NSString *)identifier { return self.installedBundle; }
- (NSString *)dataContainerForBundleIdentifier:(NSString *)identifier { lookups++; return self.sandbox; }
- (NSDictionary *)_operation_ensureCloneForContainer:(NSString *)container profile:(NSDictionary *)profile nickname:(NSString *)nickname error:(NSError **)error { mutations++; return @{}; }
- (BOOL)_operation_syncProfile:(NSDictionary *)profile error:(NSError **)error { mutations++; return YES; }
#define chmod(...) 0
#define chown(...) 0
__METHODS__
#undef chmod
#undef chown
@end
// Exercise the shipped descriptor guard before any filesystem enumeration.
// This manager exposes no real files or metadata to the lookup implementation.
@interface RBXLookupFilesystem : NSObject
+ (instancetype)defaultManager;
- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error;
@end
@implementation RBXLookupFilesystem
+ (instancetype)defaultManager { return [self new]; }
- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error { lookups++; return @[]; }
@end
@interface RBXLookupController : NSObject
@property(nonatomic,strong) NSDictionary *appDescriptor;
@end
@implementation RBXLookupController
#define NSFileManager RBXLookupFilesystem
__LOOKUP__
#undef NSFileManager
@end
static NSDictionary *Profile(NSString *container, NSString *bundle) {
    NSMutableDictionary *p = [@{@"containerId":container} mutableCopy];
    if (bundle) p[@"app"] = @{@"bundleIdentifier":bundle};
    return p;
}
static NSDictionary *Decode(NSDictionary *profile, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:profile options:0 error:nil];
    return [RBXProfileIO profileDictionaryFromData:data containerId:profile[@"containerId"] error:error];
}
int main(int argc, char **argv) { @autoreleasepool {
    NSString *sandbox = [NSString stringWithUTF8String:argv[1]];
    NSDictionary *reddit = RBXRedditAppDescriptor(), *facebook = RBXAppDescriptorForType(@"facebook");
    NSString *ownBundle = RBXAppBundleIdentifier(reddit,@"a");
    RBXCloneManager *manager = [RBXCloneManager new]; manager.appDescriptor = reddit; manager.sandbox = sandbox;
    NSDictionary *own = Profile(@"a",ownBundle);
    NSError *error = nil;
    Check([Decode(own,&error) isEqual:own] && !error, @"exact clone metadata decodes without rewriting");
    Check([Decode(Profile(@"a",nil),nil) isEqual:Profile(@"a",nil)], @"legacy profile without app metadata remains valid");
    for (NSString *bundle in @[RBXAppBundleIdentifier(reddit,@"b"),RBXAppBundleIdentifier(facebook,@"a"),
        reddit[@"sourceBundleIdentifier"],@"com.apple.mobilesafari",@""]) {
        NSDictionary *foreign = Profile(@"a",bundle);
        error = nil;
        Check(!Decode(foreign,&error) && error, @"decoder rejects metadata naming another clone, app or source");
        entries = mutations = lookups = 0; error = nil;
        Check(![manager syncProfile:foreign error:&error] && error && !entries && !mutations && !lookups,
            @"foreign sync is rejected before operation ownership or sandbox lookup");
        NSString *control = [sandbox stringByAppendingPathComponent:@"Library/Preferences/control.plist"];
        [NSFileManager.defaultManager removeItemAtPath:control error:nil];
        entries = mutations = lookups = 0; error = nil;
        BOOL wrote = [manager writeControlPlist:@{@"owner":@"a"} profile:foreign name:@"control.plist" error:&error];
        Check(!wrote && error && !entries && !lookups && ![NSFileManager.defaultManager fileExistsAtPath:control],
            @"foreign control metadata cannot publish A state into B sandbox");
    }
    entries = mutations = lookups = 0; error = nil;
    Check(![manager ensureCloneForContainer:@"b" profile:own nickname:nil error:&error] && error && !entries && !mutations,
        @"ensure explicit target must equal immutable profile container before side effects");
    for (id target in @[@"",@42,NSNull.null]) {
        entries = mutations = 0; error = nil;
        Check(![manager ensureCloneForContainer:target == NSNull.null ? nil : target profile:own nickname:nil error:&error]
            && error && !entries && !mutations, @"missing or malformed explicit clone target is rejected before side effects");
    }
    entries = mutations = 0; error = nil;
    Check([manager ensureCloneForContainer:@"a" profile:Profile(@"a",nil) nickname:nil error:&error] && !error && mutations == 1,
        @"legacy initial creation without clone metadata remains admitted");
    error = nil;
    Check([manager syncProfile:own error:&error] && !error, @"same-container synchronization remains admitted");
    Check([manager writeControlPlist:@{@"owner":@"a"} profile:own name:@"control.plist" error:nil],
        @"same-container control publication remains admitted");
    RBXLookupController *lookup = [RBXLookupController new]; lookup.appDescriptor = reddit;
    for (id identifier in @[facebook[@"sourceBundleIdentifier"],RBXAppBundleIdentifier(facebook,@"a"),
        reddit[@"sourceBundleIdentifier"],@"com.apple.mobilesafari",@"",NSNull.null]) {
        lookups = 0;
        Check(![lookup dataContainerForBundleIdentifier:identifier] && !lookups,
            @"arbitrary or foreign-app data lookup stops before filesystem enumeration");
    }
    lookups = 0;
    [lookup dataContainerForBundleIdentifier:ownBundle];
    Check(lookups > 0, @"own clone family retains existing data lookup");
    // Both paths contain otherwise acceptable metadata; only the registration
    // seam identifies A as installed. A forged B path must not pass validation.
    NSString *appA = [sandbox stringByAppendingPathComponent:@"AppA.app"];
    NSString *appB = [sandbox stringByAppendingPathComponent:@"AppB.app"];
    NSString *group = RBXAppKeychainGroup(reddit,ownBundle);
    for (NSString *path in @[appA,appB]) {
        [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
        [@{@"CFBundleIdentifier":ownBundle,@"SBAppTags":@[@"hidden"],@"RBXLauncherOnly":@YES}
            writeToFile:[path stringByAppendingPathComponent:@"Info.plist"] atomically:YES];
        [@{@"containerId":@"a",@"installer":@"appinst",@"launcherOnly":@YES,@"keychainAccessGroup":group}
            writeToFile:[path stringByAppendingPathComponent:@".redditbox-clone.plist"] atomically:YES];
    }
    manager.installedBundle = appA;
    for (NSString *path in @[appA,appB,[appA stringByAppendingPathComponent:@"../AppB.app"]]) {
        NSDictionary *profile = @{@"containerId":@"a",@"app":@{@"bundleIdentifier":ownBundle,
            @"bundlePath":path,@"architecture":@"clonedApp-v2",@"keychainAccessGroup":group}};
        BOOL valid = [manager validateCloneForProfile:profile error:nil];
        Check(valid == [path isEqual:appA], @"clone validation rejects foreign or traversing bundle path despite copied metadata");
    }
    printf("%s: %lu clone/profile ownership cases\n", failures ? "FAIL" : "PASS", (unsigned long)cases);
    return failures ? 1 : 0;
}}
'''
fixture = fixture.replace('__METHODS__', '\n'.join(method(s) for s in [
    '- (NSDictionary *)ensureCloneForContainer:', '- (BOOL)syncProfile:',
    '- (BOOL)writeControlPlist:', '- (BOOL)_operation_writeControlPlist:', '- (BOOL)validateCloneForProfile:']))
fixture = fixture.replace('__LOOKUP__', method('- (NSString *)dataContainerForBundleIdentifier:'))
with tempfile.TemporaryDirectory(prefix='rbx-clone-profile-owner-') as directory:
    path = Path(directory)
    (path/'test.m').write_text(fixture)
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-nullability-completeness',
        '-Wno-deprecated-declarations','-Wno-incompatible-pointer-types','-I'+str(ROOT/'daemon'),
        '-I'+str(ROOT/'shared'),'-framework','Foundation',str(path/'test.m'),
        str(ROOT/'daemon/RBXProfileIO.m'),'-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test'),str(path/'sandbox-b')],check=True)
