#!/usr/bin/env python3
"""Actual deletion target/phase/backup validators with private filesystem fixtures."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'daemon/RBXCloneManager.m').read_text()


def function(signature):
    start = source.index(signature)
    return source[start:source.index('\n}\n', start) + 3]


fixture = r'''
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>
#import <fcntl.h>
#import <archive.h>
#import <archive_entry.h>
#import <CommonCrypto/CommonDigest.h>
#import "RBXAppLifecycle.h"
static NSString *RBXTransactionsRoot;
static NSDictionary *PhaseJournal;
static BOOL Closed=YES,WrongOwner;
static NSUInteger Checks,Reads;
static void Check(BOOL ok,NSString *message){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}}
static NSError *RBXCloneError(NSInteger code,NSString *message){return [NSError errorWithDomain:@"fixture" code:code userInfo:@{NSLocalizedDescriptionKey:message}];}
static BOOL RBXDeletionContainerID(id value){return RBXCanonicalProfileIdentifier(value);}
static BOOL RBXDeletionClosed(NSString *container,NSError **error){return Closed;}
static BOOL RBXCloneContinue(NSError **error){return YES;}
static NSDictionary *RBXReadOwnedPlist(NSString *path,NSError **error){
    Reads++;if([path hasPrefix:@"/var/mobile/Library/RedditBox/deletions/"])return PhaseJournal;
    return [NSDictionary dictionaryWithContentsOfFile:path];
}
// Production UID checking is exercised under a synthetic root-owner boundary.
// Directory modes, UUID paths and actual inode/device capture remain real.
static int FixtureLstat(const char *path,struct stat *info){int status=lstat(path,info);if(!status)info->st_uid=WrongOwner?501:0;return status;}
#define lstat FixtureLstat
__FUNCTIONS__
#undef lstat
static int FixtureFstat(int fd,struct stat *info){int status=fstat(fd,info);if(!status)info->st_uid=WrongOwner?502:0;return status;}
#define fstat FixtureFstat
__EXPORT__
#undef fstat
static NSMutableDictionary *Target(NSDictionary *descriptor,NSString *container){
    NSMutableDictionary *target=[RBXAppDeletionTargetIdentity(descriptor,container) mutableCopy];target[@"transactions"]=@[];return target;
}
static NSString *SavedTransaction(NSDictionary *descriptor,NSString *container,NSString *phase){
    NSString *root=[RBXTransactionsRoot stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    Check([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil],@"private backup directory created");
    NSMutableDictionary *journal=[RBXAppInstallationRecord(descriptor,container) mutableCopy];journal[@"state"]=phase;journal[@"hadPreviousInstall"]=@NO;
    Check([journal writeToFile:[root stringByAppendingPathComponent:@"transaction.plist"] atomically:YES],@"versioned backup journal written");return root;
}
static void WriteExport(NSString *path,NSDictionary *marker,BOOL duplicate){
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:marker format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    struct archive *archive=archive_write_new();Check(archive_write_set_format_zip(archive)==ARCHIVE_OK && archive_write_open_filename(archive,path.fileSystemRepresentation)==ARCHIVE_OK,@"synthetic IPA writer opened");
    for(NSUInteger i=0;i<(duplicate?2:1);i++){
        struct archive_entry *entry=archive_entry_new();archive_entry_set_pathname(entry,"Payload/Fixture.app/.redditbox-clone.plist");
        archive_entry_set_filetype(entry,AE_IFREG);archive_entry_set_perm(entry,0600);archive_entry_set_size(entry,data.length);
        Check(archive_write_header(archive,entry)==ARCHIVE_OK && archive_write_data(archive,data.bytes,data.length)==data.length,@"synthetic marker archive entry written");archive_entry_free(entry);
    }
    Check(archive_write_close(archive)==ARCHIVE_OK && archive_write_free(archive)==ARCHIVE_OK,@"synthetic IPA completed");
}
int main(int argc,char **argv){@autoreleasepool{
    NSString *base=@(argv[1]);
    for(NSDictionary *descriptor in RBXRegisteredAppDescriptors()){
        NSString *app=descriptor[@"appType"],*container=@"deletion-fixture";
        RBXTransactionsRoot=[base stringByAppendingPathComponent:app];
        NSMutableDictionary *target=Target(descriptor,container);
        Check(RBXDeletionTargetValid(target,nil),@"both canonical app targets validate");
        NSMutableDictionary *journal=[RBXAppDeletionJournalIdentity(target) mutableCopy];journal[@"phase"]=@"prepared";PhaseJournal=journal;
        Check(RBXDeletionPhase(target,descriptor,@"prepared",nil),@"exact app target and retained phase admitted");
        Closed=NO;Check(!RBXDeletionPhase(target,descriptor,@"prepared",nil),@"closed lease is required");Closed=YES;
        Check(!RBXDeletionPhase(target,descriptor,@"keychain-cleared",nil),@"phase cannot advance without durable proof");
        for(NSDictionary *other in RBXRegisteredAppDescriptors())if(![other isEqual:descriptor])
            Check(!RBXDeletionPhase(target,other,@"prepared",nil),@"another app manager cannot consume this target");
        for(NSDictionary *change in @[@{@"containerId":@"sibling"},@{@"bundleIdentifier":@"com.apple.mobilesafari"},@{@"keychainAccessGroup":@"foreign"},@{@"appType":@"unknown"},@{@"transactions":@"invalid"}]){
            NSMutableDictionary *bad=target.mutableCopy;[bad addEntriesFromDictionary:change];
            Check(!RBXDeletionTargetValid(bad,nil),@"forged target tuple or records rejected");
        }
        if(RBXAppKeychainMappingEnabled(descriptor))for(NSString *key in @[@"appType",@"sourceBundleIdentifier",@"keychainAccessGroups",@"keychainPolicyVersion"]){
            NSMutableDictionary *bad=target.mutableCopy;[bad removeObjectForKey:key];Check(!RBXDeletionTargetValid(bad,nil),@"partial Facebook target denied");
        }
        NSString *saved=SavedTransaction(descriptor,container,@"committed");
        NSDictionary *other=RBXAppDescriptorForType([app isEqual:@"reddit"]?@"facebook":@"reddit");
        SavedTransaction(other,@"other-container",@"committed");
        NSArray *records=RBXDeletionTransactions(container,target[@"bundleIdentifier"],nil);
        Check(records.count==1 && [records.firstObject[@"root"] isEqual:saved],@"backup scan selects exact target and preserves other app journals");
        target[@"transactions"]=records;Check(RBXDeletionTargetValid(target,nil),@"captured committed backup accepted");
        for(NSDictionary *change in @[@{@"appType":@"unknown"},@{@"containerId":@"sibling"},@{@"state":@"install-attempted"}]){
            NSMutableDictionary *bad=target.mutableCopy,*record=[records.firstObject mutableCopy],*savedJournal=[record[@"journal"] mutableCopy];
            [savedJournal addEntriesFromDictionary:change];record[@"journal"]=savedJournal;bad[@"transactions"]=@[record];
            Check(!RBXDeletionTargetValid(bad,nil),@"foreign or unfinished retained backup cannot authorize cleanup");
        }
        WrongOwner=YES;Check(!RBXDeletionTransactions(container,target[@"bundleIdentifier"],nil),@"unowned backup directory denies scan");WrongOwner=NO;
        NSMutableDictionary *pending=[[NSDictionary dictionaryWithContentsOfFile:[saved stringByAppendingPathComponent:@"transaction.plist"]] mutableCopy];pending[@"state"]=@"installed";
        Check([pending writeToFile:[saved stringByAppendingPathComponent:@"transaction.plist"] atomically:YES],@"unfinished backup fixture");
        Check(!RBXDeletionTransactions(container,target[@"bundleIdentifier"],nil),@"unfinished installation blocks deletion");
        pending[@"recoveryState"]=@"complete";
        Check([pending writeToFile:[saved stringByAppendingPathComponent:@"transaction.plist"] atomically:YES],@"completed recovery fixture");
        Check(RBXDeletionTransactions(container,target[@"bundleIdentifier"],nil).count==1,@"completed rollback backup accepted for exact-target cleanup");
        Check([NSFileManager.defaultManager removeItemAtPath:[saved stringByAppendingPathComponent:@"transaction.plist"] error:nil],@"orphan backup fixture");
        NSString *marker=[[saved stringByAppendingPathComponent:@"Payload"] stringByAppendingPathComponent:[descriptor[@"sourceBundleName"] stringByAppendingPathComponent:descriptor[@"cloneMarkerName"]]];
        Check([NSFileManager.defaultManager createDirectoryAtPath:marker.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil],@"orphan payload created");
        Check([@{@"bundleIdentifier":target[@"bundleIdentifier"]} writeToFile:marker atomically:YES],@"orphan ownership evidence fixture");
        Check(!RBXDeletionTransactions(container,target[@"bundleIdentifier"],nil),@"app-specific unjournaled payload prevents deletion");
        NSString *ipa=[RBXTransactionsRoot stringByAppendingPathComponent:@"export.ipa"];
        NSDictionary *exportMarker=Target(descriptor,container);WriteExport(ipa,exportMarker,NO);
        NSDictionary *export=RBXExportIdentity(ipa,nil);
        Check([export[@"containerId"] isEqual:container] && [export[@"bundleIdentifier"] isEqual:target[@"bundleIdentifier"]] && [export[@"sha256"] length]==64,
            @"actual ZIP reader proves selected app marker and hashes retained file identity");
        WrongOwner=YES;Check(!RBXExportIdentity(ipa,nil),@"foreign file owner cannot provide export authority");WrongOwner=NO;
        WriteExport(ipa,exportMarker,YES);Check(!RBXExportIdentity(ipa,nil),@"duplicate clone markers deny export ownership");
        NSMutableDictionary *oversized=exportMarker.mutableCopy;oversized[@"padding"]=[@"a" stringByPaddingToLength:70000 withString:@"a" startingAtIndex:0];
        WriteExport(ipa,oversized,NO);Check(!RBXExportIdentity(ipa,nil),@"unknown-header-size ZIP still enforces decoded marker limit");
        for(NSDictionary *change in @[@{@"containerId":@"sibling"},@{@"bundleIdentifier":@"com.apple.mobilesafari"},@{@"keychainAccessGroup":@"foreign"},@{@"appType":@"unknown"}]){
            NSMutableDictionary *bad=exportMarker.mutableCopy;[bad addEntriesFromDictionary:change];WriteExport(ipa,bad,NO);
            Check(!RBXExportIdentity(ipa,nil),@"forged archive marker cannot authorize artifact deletion");
        }
        if(RBXAppKeychainMappingEnabled(descriptor))for(NSString *key in @[@"appType",@"sourceBundleIdentifier",@"keychainAccessGroups",@"keychainPolicyVersion"]){
            NSMutableDictionary *bad=exportMarker.mutableCopy;[bad removeObjectForKey:key];WriteExport(ipa,bad,NO);
            Check(!RBXExportIdentity(ipa,nil),@"partial Facebook group policy in archive denied");
        }
    }
    Check([NSFileManager.defaultManager removeItemAtPath:base error:nil],@"temporary backups removed");
    printf("PASS: %lu actual per-app deletion target/phase/backup assertions\n",(unsigned long)Checks);return 0;
}}
'''.replace('__FUNCTIONS__', '\n'.join(function(s) for s in [
    'static BOOL RBXDeletionTargetValid(', 'static BOOL RBXDeletionPhase(', 'static NSArray *RBXDeletionTransactions(']))
fixture = fixture.replace('__EXPORT__', source[source.index('struct RBXBoundedExportReader {'):source.index('static NSString *RBXExportQuarantineRoot(')])
with tempfile.TemporaryDirectory(prefix='socialbox-deletion-targets-') as directory:
    build = Path(directory)
    (build / 'test.m').write_text(fixture)
    include = os.environ.get('LIBARCHIVE_INCLUDE', '/opt/homebrew/opt/libarchive/include')
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wno-incompatible-pointer-types', '-Wno-deprecated-declarations',
                    '-I' + str(ROOT / 'shared'), '-I' + include, '-larchive', '-framework', 'Foundation', '-framework', 'Security',
                    str(build / 'test.m'), '-o', str(build / 'test')], check=True)
    subprocess.run([str(build / 'test'), str(build / 'data')], check=True)
