#!/usr/bin/env python3
"""Actual removal identity guards/capture with temporary metadata and fake LS objects."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'daemon/RBXCloneManager.m').read_text()


def function(signature):
    start = source.index(signature)
    return source[start:source.index('\n}\n', start) + 3]


start = source.index('- (BOOL)_uninstallBundleIdentifier:', source.index('@implementation RBXCloneManager'))
end = source.index('    NSDictionary *registration =', start)
guard = source[start:end] + '    return YES;\n}\n'
fixture = r'''
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <sys/stat.h>
#import <unistd.h>
#import "RBXAppKeychainPolicy.h"
@interface RBXStorageAccess : NSObject
+ (BOOL)ownsClosedHome:(NSString *)home bundleIdentifier:(NSString *)bundle error:(NSError **)error;
@end
@implementation RBXStorageAccess
+ (BOOL)ownsClosedHome:(NSString *)home bundleIdentifier:(NSString *)bundle error:(NSError **)error{return NO;}
@end
static NSUInteger Checks;
static BOOL CanMutate=YES;
static void Check(BOOL ok, NSString *message) {
    Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static NSError *RBXCloneError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"fixture" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL RBXCloneMayMutate(NSError **error){return CanMutate;}
// Only the physical iOS roots/UID check is replaced. Real temporary directories,
// Info/marker/MCM metadata, selector dispatch and inode captures are exercised.
static BOOL RBXManagedRemovalPath(NSString *path, NSArray *roots, BOOL bundle, NSError **error) {
    struct stat info;return path.isAbsolutePath && lstat(path.fileSystemRepresentation,&info)==0 && S_ISDIR(info.st_mode);
}
__FUNCTIONS__
@interface RemovalGuard : NSObject
@property NSDictionary *appDescriptor;
@end
@implementation RemovalGuard
// The unchanged service-side uninstall body is intentionally outside this
// fixture; exercise its shipped pre-service owner/target/path guard verbatim.
__GUARD__
@end
@interface FakeApp : NSObject
@property NSString *bundleIdentifier;
@property NSURL *bundleURL;
@property NSURL *dataContainerURL;
@property NSArray *plugInKitPlugins;
@end
@implementation FakeApp
@end
static void Write(NSString *path, NSDictionary *data) {
    Check([data writeToFile:path atomically:YES],@"fixture metadata written");
}
int main(int argc,char **argv) { @autoreleasepool {
    NSString *root=@(argv[1]);
    for(NSDictionary *descriptor in RBXRegisteredAppDescriptors()) {
        RemovalGuard *guard=[RemovalGuard new];guard.appDescriptor=descriptor;
        for(NSNumber *source in @[@NO,@YES]) {
            NSString *identifier=source.boolValue ? descriptor[@"sourceBundleIdentifier"] : RBXAppBundleIdentifier(descriptor,@"removal-fixture");
            Check(RBXRemovalIdentifierAllowed(identifier),@"only exact registered source or clone identity admitted");
            Check([guard _uninstallBundleIdentifier:identifier expectedBundlePath:nil error:nil],@"own target reaches unchanged uninstall service body");
            NSString *bundle=[root stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".app"]];
            NSString *data=[bundle stringByAppendingString:@"-data"];
            Check([NSFileManager.defaultManager createDirectoryAtPath:bundle withIntermediateDirectories:YES attributes:nil error:nil] &&
                [NSFileManager.defaultManager createDirectoryAtPath:data withIntermediateDirectories:YES attributes:nil error:nil],@"private fixture directories created");
            FakeApp *app=[FakeApp new];app.bundleIdentifier=identifier;app.bundleURL=[NSURL fileURLWithPath:bundle];app.dataContainerURL=[NSURL fileURLWithPath:data];app.plugInKitPlugins=@[];
            Write([bundle stringByAppendingPathComponent:@"Info.plist"],@{@"CFBundleIdentifier":identifier});
            Write([data stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"],@{@"MCMMetadataIdentifier":identifier});
            NSMutableDictionary *marker=nil;
            if(!source.boolValue) {
                marker=[@{@"containerId":@"removal-fixture",@"bundleIdentifier":identifier,@"installationTransaction":NSUUID.UUID.UUIDString} mutableCopy];
                if(RBXAppKeychainMappingEnabled(descriptor)) {
                    marker[@"formatVersion"]=@2;marker[@"appType"]=descriptor[@"appType"];
                    marker[@"sourceBundleIdentifier"]=descriptor[@"sourceBundleIdentifier"];
                    marker[@"keychainAccessGroup"]=RBXAppKeychainGroup(descriptor,identifier);
                    [marker addEntriesFromDictionary:RBXAppKeychainMetadata(descriptor,identifier)];
                }
                Write([bundle stringByAppendingPathComponent:@".redditbox-clone.plist"],marker);
            }
            NSDictionary *capture=RBXCaptureRemoval(app,identifier,bundle,nil);
            Check([capture[@"bundlePath"] isEqual:bundle.stringByResolvingSymlinksInPath] && [capture[@"dataPath"] isEqual:data.stringByResolvingSymlinksInPath] &&
                [capture[@"paths"] count]==2 && capture[@"bundleInode"] && capture[@"dataInode"],@"actual removal capture binds exact app and sandbox metadata/inodes");
            Check([capture[@"installationTransaction"] isEqual:source.boolValue ? @"" : marker[@"installationTransaction"]],@"source and clone transaction identity distinguished");
            Check(!RBXCaptureRemoval(app,identifier,[bundle stringByAppendingString:@"-other"],nil),@"mismatched expected bundle path denied");
            Write([data stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"],@{@"MCMMetadataIdentifier":@"sibling"});
            Check(!RBXCaptureRemoval(app,identifier,bundle,nil),@"sibling data metadata denies capture");
            Write([data stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"],@{@"MCMMetadataIdentifier":identifier});
            if(marker) {
                for(NSString *key in RBXAppKeychainMappingEnabled(descriptor) ?
                    @[@"containerId",@"bundleIdentifier",@"formatVersion",@"appType",@"sourceBundleIdentifier",@"keychainAccessGroup",@"keychainAccessGroups",@"keychainPolicyVersion"] : @[@"containerId",@"bundleIdentifier"]) {
                    NSMutableDictionary *bad=marker.mutableCopy;[bad removeObjectForKey:key];
                    Write([bundle stringByAppendingPathComponent:@".redditbox-clone.plist"],bad);
                    Check(!RBXCaptureRemoval(app,identifier,bundle,nil),@"partial clone identity denies capture");
                }
            }
        }
        for(NSDictionary *other in RBXRegisteredAppDescriptors()) if(![other isEqual:descriptor]) {
            for(NSString *identifier in @[other[@"sourceBundleIdentifier"],RBXAppBundleIdentifier(other,@"removal-fixture")])
                Check(![guard _uninstallBundleIdentifier:identifier expectedBundlePath:nil error:nil],@"app manager cannot remove another registered app or clone");
        }
        for(id identifier in @[@"com.apple.mobilesafari",@"com.redditbox.launcher",@"com.redditbox.firewall",@"com.redditbox.firewall.PacketTunnel",
            [descriptor[@"cloneBundlePrefix"] stringByAppendingString:@"0123456789abcdef.extra"],descriptor[@"cloneBundlePrefix"],@"",NSNull.null]) {
            Check(!RBXRemovalIdentifierAllowed(identifier),@"system, host and prefix lookalikes denied");
            Check(![guard _uninstallBundleIdentifier:identifier expectedBundlePath:nil error:nil],@"unregistered target denied before services");
        }
    }
    Check([NSFileManager.defaultManager removeItemAtPath:root error:nil],@"remove only fixture metadata");
    printf("PASS: %lu actual per-app removal identity assertions\n",(unsigned long)Checks);return 0;
} }
'''
fixture = fixture.replace('__FUNCTIONS__', '\n'.join(function(s) for s in [
    'static BOOL RBXRemovalIdentifierAllowed(', 'static NSString *RBXProxyPath(',
    'static BOOL RBXValidateDataRemovalPath(', 'static NSDictionary *RBXCaptureRemoval('])).replace('__GUARD__', guard)
with tempfile.TemporaryDirectory(prefix='socialbox-removal-') as directory:
    build = Path(directory)
    (build / 'test.m').write_text(fixture)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wno-incompatible-pointer-types',
                    '-I' + str(ROOT / 'shared'), '-framework', 'Foundation', '-framework', 'Security',
                    str(build / 'test.m'), '-o', str(build / 'test')], check=True)
    subprocess.run([str(build / 'test'), str(build / 'data')], check=True)
