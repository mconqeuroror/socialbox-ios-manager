#!/usr/bin/env python3
"""Actual clone recovery methods, real private fixture files, inert iOS services."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'daemon/RBXCloneManager.m').read_text()


def method(signature):
    start = source.index(signature, source.index('@implementation RBXCloneManager'))
    return source[start:source.index('\n}\n', start) + 3]


def function(signature):
    start = source.index(signature)
    return source[start:source.index('\n}\n', start) + 3]


fixture = r'''
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import "RBXAppKeychainPolicy.h"
#import "RBXAppLifecycle.h"
static NSString *RBXTransactionsRoot, *InstalledBundle, *InstalledData, *Transaction;
static NSDictionary *Pending, *Registered, *StoppedDescriptor;
static BOOL CanMutate, CanStop, CanInstall, CanRemove, CanSnapshot, HasPendingRemoval;
static NSUInteger Cases, Stops, Snapshots, Restores, Installs, Removals, Lookups;
static void Check(BOOL ok, NSString *message) {
    Cases++; if (!ok) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); }
}
static NSError *RBXCloneError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"fixture" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL RBXCloneMayMutate(NSError **error) {
    if (!CanMutate && error) *error=RBXCloneError(1,@"cancelled"); return CanMutate;
}
static BOOL RBXContainerAvailable(NSString *container, NSError **error) { return YES; }
static BOOL RBXNoPendingRemoval(NSString *bundle, NSError **error) {
    if (HasPendingRemoval && error) *error=RBXCloneError(1,@"pending removal"); return !HasPendingRemoval;
}
static NSDictionary *RBXReadOwnedPlist(NSString *path, NSError **error) { return Pending; }
static NSDictionary *RBXInstalledApplication(NSString *bundle, NSError **error) {
    Lookups++; return Registered ?: @{};
}
static NSDictionary *RBXCaptureRemoval(id proxy, NSString *bundle, NSString *expected, NSError **error) {
    return @{ @"bundlePath":InstalledBundle, @"dataPath":InstalledData, @"pluginIDs":@[] };
}
__JOURNAL_WRITER__
@interface RBXProcessController : NSObject
@property NSDictionary *appDescriptor;
- (instancetype)initWithAppDescriptor:(NSDictionary *)descriptor;
- (BOOL)killAllAndWait:(NSTimeInterval)timeout;
@end
@implementation RBXProcessController
- (instancetype)init { self=[super init]; if(self) _appDescriptor=RBXRedditAppDescriptor(); return self; }
- (instancetype)initWithAppDescriptor:(NSDictionary *)descriptor { self=[self init]; if(self) _appDescriptor=descriptor; return self; }
- (BOOL)killAllAndWait:(NSTimeInterval)timeout { Stops++; StoppedDescriptor=self.appDescriptor; return CanStop; }
@end
@interface RBXCloneManager : NSObject
@property NSDictionary *appDescriptor;
+ (NSString *)bundleIdentifierForContainer:(NSString *)container;
- (NSNumber *)fixturePreviousForDestination:(NSString *)destination;
- (BOOL)_recoverTransaction:(NSString *)root error:(NSError **)error;
- (BOOL)_recoverInterruptedTransactions:(NSError **)error;
- (BOOL)_copyBundleAtPath:(NSString *)source toPath:(NSString *)target error:(NSError **)error;
- (BOOL)_snapshotData:(NSString *)source toPath:(NSString *)target error:(NSError **)error;
- (BOOL)_restoreData:(NSString *)source toContainer:(NSString *)target error:(NSError **)error;
- (BOOL)_installIPA:(NSString *)ipa error:(NSError **)error;
- (BOOL)_uninstallBundleIdentifier:(NSString *)bundle expectedBundlePath:(NSString *)path error:(NSError **)error;
- (NSString *)_installedBundleForIdentifier:(NSString *)bundle;
- (NSString *)dataContainerForBundleIdentifier:(NSString *)bundle;
@end
@implementation RBXCloneManager
- (NSNumber *)fixturePreviousForDestination:(NSString *)destination {
 NSMutableDictionary *journal=[NSMutableDictionary dictionary];
 __PREVIOUS_PRODUCTION_ASSIGNMENT__
 return journal[@"hadPreviousInstall"];
}
+ (NSString *)bundleIdentifierForContainer:(NSString *)container { return RBXAppBundleIdentifier(RBXRedditAppDescriptor(),container); }
- (BOOL)_copyBundleAtPath:(NSString *)source toPath:(NSString *)target error:(NSError **)error {
    if ([NSFileManager.defaultManager fileExistsAtPath:target]) [NSFileManager.defaultManager removeItemAtPath:target error:nil];
    return [NSFileManager.defaultManager copyItemAtPath:source toPath:target error:error];
}
- (BOOL)_snapshotData:(NSString *)source toPath:(NSString *)target error:(NSError **)error {
    Snapshots++; if(!CanSnapshot) { if(error)*error=RBXCloneError(1,@"snapshot failed"); return NO; }
    return [self _copyBundleAtPath:source toPath:target error:error];
}
- (BOOL)_restoreData:(NSString *)source toContainer:(NSString *)target error:(NSError **)error {
    Restores++; return [self _copyBundleAtPath:source toPath:target error:error];
}
- (BOOL)_installIPA:(NSString *)ipa error:(NSError **)error {
    Installs++; if(!CanInstall) { if(error)*error=RBXCloneError(1,@"installer failed"); return NO; }
    NSString *saved=[Transaction stringByAppendingPathComponent:[@"backup/Payload" stringByAppendingPathComponent:self.appDescriptor[@"sourceBundleName"]]];
    return [self _copyBundleAtPath:saved toPath:InstalledBundle error:error];
}
- (BOOL)_uninstallBundleIdentifier:(NSString *)bundle expectedBundlePath:(NSString *)path error:(NSError **)error {
    Removals++; if(!CanRemove) { if(error)*error=RBXCloneError(1,@"uninstall failed"); return NO; }
    Registered=nil; return YES;
}
- (NSString *)_installedBundleForIdentifier:(NSString *)bundle { return Registered ? InstalledBundle : nil; }
- (NSString *)dataContainerForBundleIdentifier:(NSString *)bundle { return Registered ? InstalledData : nil; }
__RECOVERY__
@end
static void Write(NSString *path, id data) {
    Check([NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil],@"fixture parent created");
    if([data isKindOfClass:NSDictionary.class]) Check([data writeToFile:path atomically:YES],@"fixture plist written");
    else Check([data writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil],@"fixture text written");
}
static NSMutableDictionary *Record(NSDictionary *descriptor, NSString *phase, BOOL hadPrevious) {
    NSString *bundle=RBXAppBundleIdentifier(descriptor,@"recovery-fixture");
    NSMutableDictionary *journal=[@{@"formatVersion":@2,@"containerId":@"recovery-fixture",@"bundleIdentifier":bundle,
        @"state":phase,@"hadPreviousInstall":@(hadPrevious)} mutableCopy];
    if(RBXAppKeychainMappingEnabled(descriptor)) {
        journal[@"formatVersion"]=@3; journal[@"appType"]=descriptor[@"appType"];
        journal[@"sourceBundleIdentifier"]=descriptor[@"sourceBundleIdentifier"];
        journal[@"keychainAccessGroup"]=RBXAppKeychainGroup(descriptor,bundle);
        [journal addEntriesFromDictionary:RBXAppKeychainMetadata(descriptor,bundle)];
    }
    return journal;
}
static NSMutableDictionary *FixtureMarker(NSDictionary *descriptor) {
    NSString *bundle=RBXAppBundleIdentifier(descriptor,@"recovery-fixture");
    NSMutableDictionary *marker=[@{@"formatVersion":@1,@"containerId":@"recovery-fixture",@"bundleIdentifier":bundle,
        @"installationTransaction":Transaction.lastPathComponent,@"sourceBundleIdentifier":descriptor[@"sourceBundleIdentifier"],
        @"keychainAccessGroup":RBXAppKeychainGroup(descriptor,bundle)} mutableCopy];
    if(RBXAppKeychainMappingEnabled(descriptor)) {
        marker[@"formatVersion"]=@2;marker[@"appType"]=descriptor[@"appType"];
        [marker addEntriesFromDictionary:RBXAppKeychainMetadata(descriptor,bundle)];
    }
    return marker;
}
static NSMutableDictionary *Setup(NSDictionary *descriptor, NSString *phase, BOOL previous) {
    Transaction=[RBXTransactionsRoot stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    InstalledBundle=[RBXTransactionsRoot.stringByDeletingLastPathComponent stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".app"]];
    InstalledData=[InstalledBundle stringByAppendingString:@"-data"];
    NSMutableDictionary *journal=Record(descriptor,phase,previous);
    NSMutableDictionary *identity=journal.mutableCopy;[identity removeObjectForKey:@"state"];[identity removeObjectForKey:@"hadPreviousInstall"];
    Check([identity isEqual:RBXAppInstallationRecord(descriptor,@"recovery-fixture")],@"produced journal tuple exactly matches independently constructed legacy or versioned fixture");
    Write([Transaction stringByAppendingPathComponent:@"transaction.plist"],journal);
    Write([InstalledBundle stringByAppendingPathComponent:@".redditbox-clone.plist"],FixtureMarker(descriptor));
    Write([InstalledBundle stringByAppendingPathComponent:@"Info.plist"],@{@"CFBundleIdentifier":journal[@"bundleIdentifier"]});
    Write([InstalledBundle stringByAppendingPathComponent:@"binary"],@"synthetic app bytes");
    Write([InstalledData stringByAppendingPathComponent:@"state"],@"synthetic app state");
    Write([InstalledData stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"],@{@"MCMMetadataIdentifier":journal[@"bundleIdentifier"]});
    if(previous) {
        NSString *saved=[Transaction stringByAppendingPathComponent:[@"backup/Payload" stringByAppendingPathComponent:descriptor[@"sourceBundleName"]]];
        Check([NSFileManager.defaultManager createDirectoryAtPath:saved.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil],@"snapshot parent created");
        Check([NSFileManager.defaultManager copyItemAtPath:InstalledBundle toPath:saved error:nil],@"previous bundle copied");
        Check([NSFileManager.defaultManager copyItemAtPath:InstalledData toPath:[Transaction stringByAppendingPathComponent:@"previous-data"] error:nil],@"previous data copied");
        Write([Transaction stringByAppendingPathComponent:@"previous.ipa"],@"synthetic archive");
    }
    Pending=nil;Registered=@{@"proxy":@YES};CanMutate=CanStop=CanInstall=CanRemove=CanSnapshot=YES;HasPendingRemoval=NO;
    Stops=Snapshots=Restores=Installs=Removals=Lookups=0;StoppedDescriptor=nil;
    return journal;
}
static NSDictionary *SavedJournal(void) { return [NSDictionary dictionaryWithContentsOfFile:[Transaction stringByAppendingPathComponent:@"transaction.plist"]]; }
static BOOL Recover(RBXCloneManager *manager) { NSError *error=nil;return [manager _recoverTransaction:Transaction error:&error]; }
int main(int argc,char **argv) { @autoreleasepool {
    RBXTransactionsRoot=[[NSString stringWithUTF8String:argv[1]] stringByAppendingPathComponent:@"transactions"];
    for(NSDictionary *descriptor in @[RBXRedditAppDescriptor(),RBXAppDescriptorForType(@"facebook")]) {
        RBXCloneManager *manager=[RBXCloneManager new];manager.appDescriptor=descriptor;
        for(id destination in @[NSNull.null,@"/fixture/previous.app"]) {
            NSNumber *value=[manager fixturePreviousForDestination:destination==NSNull.null?nil:destination];
            BOOL boolean=CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID();
            Check(boolean==RBXAppKeychainMappingEnabled(descriptor),@"actual production previous-install expression uses typed Facebook boolean and legacy Reddit numeric representation");
        }

        for(NSString *phase in @[@"prepared",@"committed"]) {
            Setup(descriptor,phase,NO);
            Check(Recover(manager),@"both app owners recover completed/pre-install journal");
            Check(![NSFileManager.defaultManager fileExistsAtPath:Transaction] && !Stops && !Removals && !Installs,@"safe terminal cleanup performs no app service mutation");
        }
        Setup(descriptor,@"install-attempted",NO);
        Check(Recover(manager) && Removals==1 && Snapshots==1,@"new failed install snapshots data then removes its exact clone");
        Check([StoppedDescriptor isEqual:descriptor],@"recovery stops processes belonging to the journal app");
        Check([SavedJournal()[@"recoveryState"] isEqual:@"complete"],@"completed recovery durably recorded");
        Check([NSFileManager.defaultManager fileExistsAtPath:[Transaction stringByAppendingPathComponent:@"failed-install-data/state"]],@"failed-install user data retained");
        Check(Recover(manager) && Removals==1,@"completed rollback does not repeat uninstall");
        Setup(descriptor,@"installed",YES);
        Check(Recover(manager) && !Installs && !Removals && !Restores,@"byte-identical previous app and data need no reinstall or restore");
        Setup(descriptor,@"installed",YES);
        Write([InstalledBundle stringByAppendingPathComponent:@"binary"],@"failed update bytes");
        Write([InstalledData stringByAppendingPathComponent:@"state"],@"failed update data");
        Check(Recover(manager) && Installs==1 && Restores==1 && !Removals,@"previous app restored in place without uninstalling existing identity");
        Check([[NSString stringWithContentsOfFile:[InstalledData stringByAppendingPathComponent:@"state"] encoding:NSUTF8StringEncoding error:nil] isEqual:@"synthetic app state"],@"original app data restored");
        Check([NSFileManager.defaultManager fileExistsAtPath:[Transaction stringByAppendingPathComponent:@"previous-data/state"]] &&
            [NSFileManager.defaultManager fileExistsAtPath:[Transaction stringByAppendingPathComponent:@"failed-install-data/state"]],@"both snapshots retained after rollback");
        for(NSString *fault in @[@"stop",@"snapshot",@"remove",@"cancel"]) {
            Setup(descriptor,@"install-attempted",NO);
            if([fault isEqual:@"stop"])CanStop=NO;if([fault isEqual:@"snapshot"])CanSnapshot=NO;
            if([fault isEqual:@"remove"])CanRemove=NO;if([fault isEqual:@"cancel"])CanMutate=NO;
            Check(!Recover(manager) && ![SavedJournal()[@"recoveryState"] isEqual:@"complete"],@"failed boundary retains incomplete journal");
            CanMutate=CanStop=CanSnapshot=CanRemove=YES;
            Check(Recover(manager),@"retained journal can resume after boundary recovers");
        }
        Setup(descriptor,@"installed",YES);[NSFileManager.defaultManager removeItemAtPath:[Transaction stringByAppendingPathComponent:@"previous.ipa"] error:nil];
        Check(!Recover(manager) && !Removals && !Installs,@"incomplete previous snapshot forbids destructive recovery");
        Setup(descriptor,@"installed",NO);
        NSMutableDictionary *foreign=FixtureMarker(descriptor);foreign[@"installationTransaction"]=NSUUID.UUID.UUIDString;
        Write([InstalledBundle stringByAppendingPathComponent:@".redditbox-clone.plist"],foreign);
        Check(!Recover(manager) && !Removals && !Snapshots,@"foreign transaction cannot authorize snapshot or removal");
        for(NSDictionary *change in @[@{@"formatVersion":@99},@{@"containerId":@"sibling"},@{@"bundleIdentifier":@"com.apple.mobilesafari"},@{@"appType":@"unknown"}]) {
            NSMutableDictionary *journal=Setup(descriptor,@"prepared",NO);[journal addEntriesFromDictionary:change];
            Write([Transaction stringByAppendingPathComponent:@"transaction.plist"],journal);
            Check(!Recover(manager) && !Stops && !Lookups && [NSFileManager.defaultManager fileExistsAtPath:Transaction],@"malformed/foreign owner retained before service side effects");
        }
        if(RBXAppKeychainMappingEnabled(descriptor)) {
            for(NSNumber *legacy in @[@0,@1]) {
                NSMutableDictionary *journal=Setup(descriptor,@"installed",legacy.boolValue);
                journal[@"hadPreviousInstall"]=legacy;Write([Transaction stringByAppendingPathComponent:@"transaction.plist"],journal);
                Check(Recover(manager),@"valid version-3 legacy integer flag is recovered with exact ownership");
                NSNumber *canonical=SavedJournal()[@"hadPreviousInstall"];
                Check(CFGetTypeID((__bridge CFTypeRef)canonical)==CFBooleanGetTypeID() && canonical.boolValue==legacy.boolValue,@"legacy flag canonicalized durably without changing meaning");
            }
            for(NSDictionary *change in @[@{@"hadPreviousInstall":@"false"},@{@"hadPreviousInstall":@2},@{@"hadPreviousInstall":@-1},@{@"hadPreviousInstall":@0.5},
                @{@"state":@"unknown"},@{@"recoveryStarted":@"yes"},@{@"recoveryState":@"unexpected"}]) {
                NSMutableDictionary *journal=Setup(descriptor,@"prepared",NO);[journal addEntriesFromDictionary:change];
                Write([Transaction stringByAppendingPathComponent:@"transaction.plist"],journal);
                Check(!Recover(manager) && !Stops && [NSFileManager.defaultManager fileExistsAtPath:Transaction],@"Facebook recovery flags must be typed and recognized before prepared cleanup");
            }
            for(NSString *key in @[@"appType",@"sourceBundleIdentifier",@"keychainAccessGroup",@"keychainAccessGroups",@"keychainPolicyVersion"]) {
                NSMutableDictionary *journal=Setup(descriptor,@"prepared",NO);[journal removeObjectForKey:key];
                Write([Transaction stringByAppendingPathComponent:@"transaction.plist"],journal);
                Check(!Recover(manager) && !Stops,@"Facebook journal requires complete immutable tuple even for prepared cleanup");
            }
            Setup(descriptor,@"installed",NO);NSMutableDictionary *bad=FixtureMarker(descriptor);[bad removeObjectForKey:@"keychainAccessGroups"];
            Write([InstalledBundle stringByAppendingPathComponent:@".redditbox-clone.plist"],bad);
            Check(!Recover(manager) && !Snapshots && !Removals,@"transaction UUID alone cannot authorize incomplete Facebook marker");
        }
    }
    RBXTransactionsRoot=[RBXTransactionsRoot.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"mixed-transactions"];
    Setup(RBXRedditAppDescriptor(),@"prepared",NO);NSString *redditTransaction=Transaction;
    Setup(RBXAppDescriptorForType(@"facebook"),@"prepared",NO);NSString *facebookTransaction=Transaction;
    RBXCloneManager *manager=[RBXCloneManager new];manager.appDescriptor=RBXRedditAppDescriptor();
    Check([manager _recoverInterruptedTransactions:nil] && ![NSFileManager.defaultManager fileExistsAtPath:redditTransaction] &&
        [NSFileManager.defaultManager fileExistsAtPath:facebookTransaction],@"Reddit recovery leaves a validated Facebook journal untouched");
    Check(![manager _recoverTransaction:facebookTransaction error:nil],@"direct recovery cannot consume a foreign app journal");
    manager.appDescriptor=RBXAppDescriptorForType(@"facebook");
    Check([manager _recoverInterruptedTransactions:nil] && ![NSFileManager.defaultManager fileExistsAtPath:facebookTransaction],@"Facebook recovery handles its own journal");
    NSMutableDictionary *bad=Setup(RBXRedditAppDescriptor(),@"prepared",NO);bad[@"appType"]=@"unknown";
    Write([Transaction stringByAppendingPathComponent:@"transaction.plist"],bad);
    Check(![manager _recoverInterruptedTransactions:nil] && [NSFileManager.defaultManager fileExistsAtPath:Transaction],@"unknown owner prevents unattended recovery and retains evidence");
    Check([NSFileManager.defaultManager removeItemAtPath:RBXTransactionsRoot.stringByDeletingLastPathComponent error:nil],@"fixture files removed");
    printf("PASS: %lu actual per-app installation recovery assertions\n",(unsigned long)Cases);
    return 0;
} }
'''
fixture = fixture.replace('__JOURNAL_WRITER__', function('static BOOL RBXWriteJournal('))
fixture = fixture.replace('__RECOVERY__', method('- (BOOL)_recoverTransaction:') + method('- (BOOL)_recoverInterruptedTransactions:'))
start=source.index('        journal[@"hadPreviousInstall"] =', source.index('- (NSDictionary *)_ensureCloneForContainer:', source.index('@implementation RBXCloneManager')))
assignment=source[start:source.index(';',start)+1]
fixture=fixture.replace('__PREVIOUS_PRODUCTION_ASSIGNMENT__',assignment)

with tempfile.TemporaryDirectory(prefix='socialbox-recovery-') as directory:
    build = Path(directory)
    (build / 'test.m').write_text(fixture)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wno-unused-parameter',
                    '-Wno-incompatible-pointer-types', '-I' + str(ROOT / 'shared'),
                    '-framework', 'Foundation', '-framework', 'Security', str(build / 'test.m'),
                    '-o', str(build / 'test')], check=True)
    subprocess.run([str(build / 'test'), str(build / 'data')], check=True)
