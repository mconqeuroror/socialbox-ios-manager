#!/usr/bin/env python3
"""Run the production metadata mutation methods with an inert single-profile store.

No jailbreak, clone creation, signing, cloud or live device is accessed. The full
saved profile must remain equal except the explicit organizational fields.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'daemon/RBXContainerRegistry.m').read_text()
def method(signature):
    start = source.index(signature)
    return source[start:source.index('\n}\n', start) + 3]
fixture = r'''
#import <Foundation/Foundation.h>
#import "RBXProfileMetadata.h"
static NSMutableDictionary *Saved;
static BOOL Allowed=YES,WriteSucceeds=YES;
static NSUInteger Checks,Reads,Writes;
static void Check(BOOL ok,NSString *message){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}}
static NSError *RBXDeletionError(NSString *message){return [NSError errorWithDomain:@"fixture" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];}
@interface RBXProfileIO:NSObject
+ (NSDictionary *)loadProfileForContainer:(NSString *)container error:(NSError **)error;
@end
@implementation RBXProfileIO
+ (NSDictionary *)loadProfileForContainer:(NSString *)container error:(NSError **)error{Reads++;return Saved[container];}
@end
@interface Registry:NSObject
- (BOOL)_allowsContainer:(NSString *)container error:(NSError **)error;
- (BOOL)_writeProfile:(NSDictionary *)profile container:(NSString *)container error:(NSError **)error;
- (BOOL)updateMetadata:(NSDictionary *)metadata forContainer:(NSString *)container local:(BOOL)local error:(NSError **)error;
- (BOOL)discardMetadataChangesForContainer:(NSString *)container error:(NSError **)error;
@end
@implementation Registry
- (BOOL)_allowsContainer:(NSString *)container error:(NSError **)error{return Allowed && [@[@"reddit-fixture",@"facebook-fixture"] containsObject:container];}
- (BOOL)_writeProfile:(NSDictionary *)profile container:(NSString *)container error:(NSError **)error{
    Writes++;if(!WriteSucceeds)return NO;Saved[container]=[profile copy];return YES;
}
__METHODS__
@end
int main(void){@autoreleasepool{
    Saved=NSMutableDictionary.dictionary;Registry *registry=Registry.new;
    for(NSString *app in @[@"reddit",@"facebook"]){
        NSString *container=[app stringByAppendingString:@"-fixture"];
        NSDictionary *original=@{@"containerId":container,@"appType":app,@"bundleIdentifier":@"synthetic.bundle",
            @"device":@{@"productType":@"synthetic-device",@"iosVersion":@"18.6"},@"ids":@{@"idfv":@"unchanged-id"},
            @"keychainAccessGroup":@"synthetic-group",@"proxy":@{@"country":@"US",@"url":@"http://fixture.invalid:80"},
            @"paths":@{@"data":@"synthetic-data"},@"role":@"warmup",@"notes":@"keep notes",@"metadataRevision":@4,@"metadataDirty":@NO};
        Saved[container]=original;NSDictionary *allBefore=[Saved copy];NSUInteger before=Writes;
        Check([registry updateMetadata:@{@"nickname":@"Reviewed name",@"ids":@{@"idfv":@"forged"},@"containerId":@"forged"} forContainer:container local:YES error:nil],@"name-only edit accepted in both app namespaces");
        NSMutableDictionary *expected=original.mutableCopy;expected[@"nickname"]=@"Reviewed name";expected[@"metadataDirty"]=@YES;
        Check([Saved[container] isEqual:expected] && Writes==before+1,@"one write changes only the name and dirty bit; identity, proxy, IDs, paths and role/notes unchanged");
        for(NSString *other in allBefore)if(![other isEqual:container])Check([Saved[other] isEqual:allBefore[other]],@"sibling profile unaffected");
        Check([RBXProfileDisplayName(Saved[container],@"Legacy install name",container) isEqual:@"Reviewed name"],@"published name prioritizes reviewed profile label");
        Check([registry updateMetadata:@{@"role":@"signup",@"notes":@"changed note"} forContainer:container local:YES error:nil],@"existing role/notes operation stays supported");
        Check([Saved[container][@"nickname"] isEqual:@"Reviewed name"],@"role edits preserve explicit name");
        NSDictionary *saved=[Saved[container] copy];before=Writes;
        for(id bad in @[@{},@{@"nickname":@""},@{@"nickname":@"bad\nname"},@{@"nickname":@42},@{@"nickname":@" space "},@{@"nickname":@"Good",@"role":@"unknown"},@{@"nickname":@"Good",@"notes":@42}])
            Check(![registry updateMetadata:bad forContainer:container local:YES error:nil],@"malformed metadata rejected");
        Check(Writes==before && [Saved[container] isEqual:saved],@"invalid edits never write");
        Allowed=NO;NSUInteger reads=Reads;
        Check(![registry updateMetadata:@{@"nickname":@"denied"} forContainer:container local:YES error:nil] && ![registry discardMetadataChangesForContainer:container error:nil],@"admission denial also protects discard");
        Check(Reads==reads && Writes==before,@"retired or unowned container fails before any read or write");Allowed=YES;
        Check(![registry updateMetadata:@{@"nickname":@"denied"} forContainer:@"sibling-unowned" local:YES error:nil],@"another owner cannot rename");
        WriteSucceeds=NO;Check(![registry updateMetadata:@{@"nickname":@"write failure"} forContainer:container local:YES error:nil],@"persistence failure returned");WriteSucceeds=YES;
        Check([Saved[container] isEqual:saved],@"persistence failure preserves full old profile");
        before=Writes;
        Check(![registry updateMetadata:@{@"nickname":@"cloud",@"metadataRevision":@5} forContainer:container local:NO error:nil],@"partial cloud snapshot cannot clear existing fields");
        Check(![registry updateMetadata:@{@"role":@"warmup",@"notes":@"",@"metadataRevision":@-1} forContainer:container local:NO error:nil],@"invalid cloud revision rejected");
        Check(Writes==before,@"invalid cloud snapshot never writes");
        Check([registry updateMetadata:@{@"nickname":@"Cloud label",@"role":@"default",@"notes":@"cloud",@"metadataRevision":@5} forContainer:container local:NO error:nil],@"accepted full cloud snapshot carries name");
        Check([Saved[container][@"nickname"] isEqual:@"Cloud label"] && [Saved[container][@"metadataDirty"] isEqual:@NO],@"cloud acknowledged label is clean");
        Check([registry updateMetadata:@{@"nickname":@"Pending"} forContainer:container local:YES error:nil] && [registry discardMetadataChangesForContainer:container error:nil],@"operator can allow later cloud reconciliation");
        Check([Saved[container][@"nickname"] isEqual:@"Pending"] && [Saved[container][@"metadataDirty"] isEqual:@NO],@"discard does not erase label before a successful cloud refresh");
        Check([registry updateMetadata:@{@"role":@"default",@"notes":@"",@"metadataRevision":@6} forContainer:container local:NO error:nil],@"legacy complete cloud snapshot remains valid");
        Check(!Saved[container][@"nickname"] && [RBXProfileDisplayName(Saved[container],@"Legacy install name",container) isEqual:@"Legacy install name"],@"legacy snapshot falls back without rewriting installation metadata");
    }
    printf("PASS: %lu actual metadata rename assertions\n",(unsigned long)Checks);return 0;
}}
'''.replace('__METHODS__','\n'.join(method(signature) for signature in ['- (BOOL)updateMetadata:', '- (BOOL)discardMetadataChangesForContainer:']))
with tempfile.TemporaryDirectory(prefix='socialbox-profile-rename-') as directory:
    target = Path(directory)
    (target/'test.m').write_text(fixture)
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-incompatible-pointer-types','-I'+str(ROOT/'shared'),'-framework','Foundation',str(target/'test.m'),'-o',str(target/'test')],check=True)
    subprocess.run([str(target/'test')],check=True)
