#import "../Containers/LBXContainerConfigurationStore.h"
#import "../Containers/LBXContainerConfiguration.h"
#import "../Authorization/LBXLicenseOwner.h"
#import "../Authorization/LBXLicenseVault.h"
#import "../Authorization/LBXLicenseIPC.h"
#import "../../tests/RBXLicenseTestSupport.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <math.h>
#include <mach/mach_time.h>

// Actual store/owner/vault with fresh temporary files and an ephemeral signing
// key. NSURLProtocol is the sole transport. Testing role macros do not prove
// production root/image provenance. No UI, IPC retirement or pending consumer
// is exercised; opaque sibling fixtures establish preservation only.
static NSUInteger checks,failures,requests;
static NSString *signedStatus=@"active";
static void Check(BOOL value,NSString *label){checks++;if(!value){failures++;fprintf(stderr,"FAIL: %s\n",label.UTF8String);}}
@interface RetirementProtocol:NSURLProtocol @end
@implementation RetirementProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request{(void)request;return YES;}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request{return request;}
- (void)stopLoading{}
- (void)startLoading {
    requests++;NSData *body=self.request.HTTPBody;
    if(!body&&self.request.HTTPBodyStream){NSInputStream *stream=self.request.HTTPBodyStream;[stream open];NSMutableData *data=[NSMutableData data];uint8_t buffer[1024];NSInteger n;while((n=[stream read:buffer maxLength:sizeof(buffer)])>0)[data appendBytes:buffer length:(NSUInteger)n];[stream close];body=data;}
    NSDictionary *request=body?[NSJSONSerialization JSONObjectWithData:body options:0 error:nil]:nil;
    NSMutableDictionary *claims=TestLicenseClaims(@"AAAA-BBBB-CCCC-DDDD",request[@"nonce"],NSDate.date.timeIntervalSince1970);
    claims[@"iss"]=@"https://redditspoof.vercel.app";claims[@"deviceBinding"]=[RBXLicenseToken fingerprint:request[@"deviceIdentity"]];claims[@"status"]=signedStatus;
    NSDictionary *reply=@{@"licenseToken":TestLicenseJWT(claims,nil),@"deviceId":@"fixture-device",@"token":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0]};
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil]];[self.client URLProtocolDidFinishLoading:self];
}
@end
static LBXLicenseOwner *NewOwner(LBXLicenseVault *vault){LBXLicenseOwner *owner=[[LBXLicenseOwner alloc] initWithVault:vault];[owner testUseProtocol:RetirementProtocol.class publicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];return owner;}
static NSDictionary *Send(LBXLicenseOwner *owner,NSString *operation){dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSDictionary *reply=nil;
    [owner handleRequest:LBXLicenseIPCRequest(operation,[operation isEqual:@"activate"]?@"AAAA-BBBB-CCCC-DDDD":nil) completion:^(NSDictionary *value){reply=value;dispatch_semaphore_signal(done);}];
    Check(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)),@"bounded inert signed owner reply");return reply;}
static void Authorize(LBXLicenseOwner *owner){signedStatus=@"active";Check([Send(owner,@"validate")[@"result"] isEqual:@"active"]&&[owner sourceAuthorizationCurrent],@"fresh synthetic signed admission");}
static NSString *Join(NSString *path,NSString *leaf){return [path stringByAppendingPathComponent:leaf];}
static NSString *RecordPath(NSString *path,LBXContainerConfiguration *record){return Join(path,[record.identifier stringByAppendingString:@".json"]);}
static NSDictionary *Read(NSString *path){NSData *data=[NSData dataWithContentsOfFile:path];return data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;}
static BOOL Put(NSString *path,id value){NSData *data=[value isKindOfClass:NSData.class]?value:[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];return data&&[data writeToFile:path atomically:NO]&&!chmod(path.fileSystemRepresentation,0600);}
static NSDictionary *Snapshot(NSString *path){struct stat node;NSData *data=[NSData dataWithContentsOfFile:path];if(lstat(path.fileSystemRepresentation,&node)||!data)return nil;
    return @{@"bytes":data,@"device":@(node.st_dev),@"inode":@(node.st_ino),@"mode":@(node.st_mode),@"links":@(node.st_nlink),@"owner":@(node.st_uid),@"group":@(node.st_gid)};}
static NSMutableDictionary *Change(NSDictionary *value,NSString *key,id replacement){NSMutableDictionary *copy=[value mutableCopy];if(replacement)copy[key]=replacement;else[copy removeObjectForKey:key];return copy;}
static BOOL StrictBoolean(id value,BOOL expected){return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()&&[value boolValue]==expected;}
static BOOL Tombstone(NSDictionary *value,LBXContainerConfiguration *record){id version=value[@"storageVersion"];
    return [value isKindOfClass:NSDictionary.class]&&value.count==4&&[[NSSet setWithArray:value.allKeys] isEqual:[NSSet setWithArray:@[@"storageVersion",@"configuration",@"allocationReserved",@"retired"]]]&&
        [version isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)version)!=CFBooleanGetTypeID()&&!CFNumberIsFloatType((__bridge CFNumberRef)version)&&[version isEqual:@2]&&
        StrictBoolean(value[@"allocationReserved"],NO)&&StrictBoolean(value[@"retired"],YES)&&[value[@"configuration"] isEqual:record.privateDictionary];}
static BOOL Save(LBXContainerConfigurationStore *store,LBXContainerConfiguration *record,LBXContainerConfiguration *prior){return [store commitConfiguration:record replacing:prior beforeDeadline:LBXLicenseIPCClock()+3 error:nil];}
static BOOL Retire(LBXContainerConfigurationStore *store,LBXLicenseOwner *owner,LBXContainerConfiguration *record,NSError **error){double deadline=LBXLicenseIPCClock()+3;
    return [owner performSourceOperation:^BOOL(NSError **failure){return [store retireConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline error:failure];} beforeDeadline:deadline error:error];}
static BOOL Current(LBXContainerConfigurationStore *store,LBXLicenseOwner *owner,LBXContainerConfiguration *record,NSError **error){double deadline=LBXLicenseIPCClock()+3;
    return [owner performSourceOperation:^BOOL(NSError **failure){return [store retirementCurrentForConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline error:failure];} beforeDeadline:deadline error:error];}
@interface RetirementFixture:NSObject
@property(nonatomic,strong) NSString *base,*path;
@property(nonatomic,strong) LBXLicenseVault *vault;
@property(nonatomic,strong) LBXLicenseOwner *owner;
@property(nonatomic,strong) LBXContainerConfigurationStore *store;
@end
@implementation RetirementFixture @end
static RetirementFixture *Fixture(NSString *parent,NSString *name){RetirementFixture *f=[RetirementFixture new];f.base=Join(parent,name);f.path=Join(f.base,@"configurations");
    signedStatus=@"active";
    Check(!mkdir(f.base.fileSystemRepresentation,0700),@"new isolated fixture parent");f.vault=[LBXLicenseVault openDirectory:Join(f.base,@"vault") error:nil];[f.vault testUsePublicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];f.owner=NewOwner(f.vault);
    Check(f.vault&&f.owner&&[Send(f.owner,@"activate")[@"result"] isEqual:@"active"]&&[f.owner sourceAuthorizationCurrent],@"fixture uses actual verified synthetic activation");
    f.store=[LBXContainerConfigurationStore openDirectory:f.path licenseOwner:f.owner create:YES error:nil];Check(f.store!=nil,@"new actual private configuration store");return f;}
static LBXContainerConfiguration *Fresh(RetirementFixture *f){LBXContainerConfiguration *record=[LBXContainerConfiguration createWithName:@"Authored private retirement fixture" applications:@[@"com.burbn.instagram",@"com.facebook.Facebook"] manualIdentifiers:nil proxyReference:@"" error:nil];Check(record&&Save(f.store,record,nil),@"actual strict false configuration persisted before retirement");return record;}

static void ExactAndProjectionTests(NSString *base){RetirementFixture *f=Fixture(base,@"exact");LBXContainerConfiguration *record=Fresh(f),*sibling=Fresh(f);NSString *file=RecordPath(f.path,record),*siblingFile=RecordPath(f.path,sibling);
    NSDictionary *siblingBefore=Snapshot(siblingFile);NSString *interrupted=Join(f.path,@"pending-opaque-interruption");Check(Put(interrupted,@{@"unresolved":@YES}),@"opaque interrupted-stage fixture established");NSDictionary *interruptedBefore=Snapshot(interrupted);
    // These are deliberately opaque sibling bytes, not accepted root-pending
    // documents. No pending emptiness, validity or clear policy is inferred.
    NSString *pending=Join(f.base,@"opaque-pending-state.json"),*marker=Join(f.base,@"opaque-pending-marker.json");
    Check(Put(pending,@{@"pending":@{@"uncertainty":@"retain"},@"completed":@{@"prior":@"retain"}})&&Put(marker,@{@"owner":@"retain"}),@"opaque pending/completed and marker siblings established");NSDictionary *pendingBefore=Snapshot(pending),*markerBefore=Snapshot(marker);
    NSError *error=nil;NSUInteger before=requests;Check(Retire(f.store,f.owner,record,&error)&&!error&&Tombstone(Read(file),record),@"exact strict false row retires into same-UUID four-key v2 tombstone");Check(requests==before,@"retirement sends no license request or other transport");
    NSDictionary *retired=Snapshot(file);struct stat node;Check(!lstat(file.fileSystemRepresentation,&node)&&(node.st_mode&0777)==0600&&node.st_nlink==1,@"published tombstone remains private single-link file");
    BOOL absent=YES;error=nil;Check(![f.store configurationWithIdentifier:record.identifier absent:&absent error:&error]&&!absent&&error.code==2,@"retired lookup is conflict and occupied, never ordinary missing");
    error=nil;Check(![f.store configurationWithIdentifier:record.identifier error:&error]&&error.code==2,@"convenience active lookup also refuses retired row");NSArray *rows=[f.store configurations:&error];Check(rows&&rows.count==1&&[[rows.firstObject privateDictionary] isEqual:sibling.privateDictionary],@"ordinary list hides only valid retired row and retains sibling");
    LBXContainerConfigurationStore *peer=[LBXContainerConfigurationStore openDirectory:f.path licenseOwner:f.owner create:NO error:nil];Check(peer&&Retire(peer,f.owner,record,&error)&&Current(peer,f.owner,record,&error)&&[Snapshot(file) isEqual:retired],@"independent store exact retry and assertion preserve bytes and inode");
    LBXLicenseOwner *restart=NewOwner(f.vault);LBXContainerConfigurationStore *reopened=[LBXContainerConfigurationStore openDirectory:f.path licenseOwner:restart create:NO error:nil];
    Check(reopened&&!Retire(reopened,restart,record,&error)&&[Snapshot(file) isEqual:retired],@"fresh owner has no cached retirement authority despite retained tombstone");Authorize(restart);
    Check(Retire(reopened,restart,record,&error)&&Current(reopened,restart,record,&error)&&[Snapshot(file) isEqual:retired],@"freshly revalidated owner confirms permanent exact retirement without publication");
    Check([Snapshot(siblingFile) isEqual:siblingBefore]&&[Snapshot(interrupted) isEqual:interruptedBefore]&&[Snapshot(pending) isEqual:pendingBefore]&&[Snapshot(marker) isEqual:markerBefore],@"retirement and retries preserve active sibling, opaque stage and pending/completed/marker bytes and inodes");
    for(NSString *privateValue in @[record.name,record.identifier,record.identifiers[@"idfv"]])Check(![reopened.description containsString:privateValue]&&![reopened.debugDescription containsString:privateValue],@"store descriptions do not disclose retired private values");
}
static void FullDocumentAndEligibilityTests(NSString *base){RetirementFixture *f=Fixture(base,@"full-document");LBXContainerConfiguration *record=Fresh(f);NSString *file=RecordPath(f.path,record);NSDictionary *original=Snapshot(file);NSError *error=nil;
    NSMutableDictionary *identifiers=[record.identifiers mutableCopy];identifiers[@"serialNumber"]=@"fixture12345";
    NSArray *variants=@[Change(record.privateDictionary,@"name",@"Different same revision"),Change(record.privateDictionary,@"applications",@[@"com.burbn.instagram"]),Change(record.privateDictionary,@"identifiers",identifiers),Change(record.privateDictionary,@"identifierMode",@"manual"),Change(record.privateDictionary,@"proxyReference",NSUUID.UUID.UUIDString.lowercaseString),Change(record.privateDictionary,@"revision",@2)];
    for(NSDictionary *variant in variants){LBXContainerConfiguration *expected=[LBXContainerConfiguration fromDictionary:variant error:nil];Check(expected!=nil,@"full-document conflict candidate is independently valid");
        Check(!Retire(f.store,f.owner,expected,&error)&&error.code==2&&[Snapshot(file) isEqual:original],@"retirement rejects full expected-document drift without publication");Authorize(f.owner);}
    NSDictionary *active=Read(file);NSMutableArray *invalidActive=[NSMutableArray array];for(id flag in @[@0,@1,@"false",NSNull.null])[invalidActive addObject:Change(active,@"allocationReserved",flag)];[invalidActive addObject:Change(active,@"storageVersion",@YES)];
    for(NSDictionary *malformed in invalidActive){Check(Put(file,malformed),@"actual invalid v1 eligibility envelope");NSDictionary *before=Snapshot(file);Check(!Retire(f.store,f.owner,record,&error)&&error.code==1&&[Snapshot(file) isEqual:before],@"retirement requires strict v1 integer version and Boolean false, never numeric/string coercion");Authorize(f.owner);Check(Put(file,original[@"bytes"]),@"fixture restores its exact authored v1 bytes");}
    Check(!Current(f.store,f.owner,record,&error)&&error.code==2&&[Snapshot(file) isEqual:original],@"read-only retirement assertion cannot retire a still-active false record");Authorize(f.owner);
    Check(Retire(f.store,f.owner,record,&error),@"exact unchanged original retires after refused conflicts");NSDictionary *retired=Snapshot(file);
    for(NSDictionary *variant in variants){LBXContainerConfiguration *expected=[LBXContainerConfiguration fromDictionary:variant error:nil];Check(!Retire(f.store,f.owner,expected,&error)&&error.code==2&&[Snapshot(file) isEqual:retired],@"retired retry still requires full exact original document");Authorize(f.owner);Check(!Current(f.store,f.owner,expected,&error)&&error.code==2&&[Snapshot(file) isEqual:retired],@"retirement assertion also compares full exact original");Authorize(f.owner);}
    LBXContainerConfiguration *reserved=Fresh(f);NSString *reservedFile=RecordPath(f.path,reserved);double deadline=LBXLicenseIPCClock()+3;
    Check([f.owner performSourceOperation:^BOOL(NSError **failure){return [f.store reserveConfigurationForClosedAllocation:reserved beforeDeadline:deadline error:failure];} beforeDeadline:deadline error:&error],@"actual reserved-true fixture");NSDictionary *reservedBefore=Snapshot(reservedFile);
    Check(!Retire(f.store,f.owner,reserved,&error)&&error.code==2&&[Snapshot(reservedFile) isEqual:reservedBefore],@"reserved true cannot be retired or thawed");Authorize(f.owner);
    LBXContainerConfiguration *legacy=Fresh(f);NSString *legacyFile=RecordPath(f.path,legacy);Check(Put(legacyFile,legacy.privateDictionary),@"actual legacy bare UNKNOWN fixture");NSDictionary *legacyBefore=Snapshot(legacyFile);
    Check(!Retire(f.store,f.owner,legacy,&error)&&error.code==2&&[Snapshot(legacyFile) isEqual:legacyBefore],@"legacy UNKNOWN cannot infer false reservation or retire");Authorize(f.owner);deadline=LBXLicenseIPCClock()+3;
    Check([f.owner performSourceOperation:^BOOL(NSError **failure){return [f.store reserveConfigurationForClosedAllocation:legacy beforeDeadline:deadline error:failure];} beforeDeadline:deadline error:&error]&&StrictBoolean(Read(legacyFile)[@"allocationReserved"],YES)&&[Read(legacyFile)[@"configuration"] isEqual:legacy.privateDictionary],@"existing trusted legacy reservation-to-frozen behavior remains intact");
    legacyBefore=Snapshot(legacyFile);Check(!Retire(f.store,f.owner,legacy,&error)&&error.code==2&&[Snapshot(legacyFile) isEqual:legacyBefore],@"legacy subsequently frozen true still cannot retire");
}
static void ActiveEntryPointTests(NSString *base){RetirementFixture *f=Fixture(base,@"entry-points");LBXContainerConfiguration *record=Fresh(f);NSError *error=nil;Check(Retire(f.store,f.owner,record,&error),@"entry-point refusal tombstone published");NSString *file=RecordPath(f.path,record);NSDictionary *retired=Snapshot(file);LBXContainerConfiguration *edit=[record configurationByUpdatingName:@"Forbidden active rewrite" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];
    Check(![f.store commitConfiguration:record replacing:nil beforeDeadline:LBXLicenseIPCClock()+3 error:&error]&&error.code==2&&[Snapshot(file) isEqual:retired],@"ordinary create cannot reuse permanently occupied UUID");Authorize(f.owner);
    Check(![f.store commitConfiguration:edit replacing:record beforeDeadline:LBXLicenseIPCClock()+3 error:&error]&&error.code==2&&[Snapshot(file) isEqual:retired],@"ordinary exact edit cannot replace retirement");Authorize(f.owner);double deadline=LBXLicenseIPCClock()+3;
    Check([f.owner performSourceOperation:^BOOL(__unused NSError **failure){NSError *denied=nil;BOOL absent=YES;__block NSUInteger callbacks=0;
        Check(![f.store commitConfiguration:record replacing:nil inCurrentSourceOperationBeforeDeadline:deadline error:&denied]&&denied.code==2,@"already-fenced create also refuses retired UUID");
        Check(![f.store commitConfiguration:edit replacing:record inCurrentSourceOperationBeforeDeadline:deadline error:&denied]&&denied.code==2,@"already-fenced edit also refuses retirement");
        Check(![f.store reserveConfigurationForClosedAllocation:record beforeDeadline:deadline error:&denied]&&denied.code==2,@"closed allocation reservation cannot reserve retired metadata");
        Check(![f.store allocationReservationCurrentForConfiguration:record beforeDeadline:deadline error:&denied]&&denied.code==2,@"retirement is not a current allocation reservation");
        Check(![f.store isConfigurationEditable:record inCurrentSourceOperationBeforeDeadline:deadline error:&denied]&&denied.code==2,@"retired original is not editable");
        Check(![f.store performWithExactConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *context,__unused NSError **proofError){callbacks++;return YES;} error:&denied]&&denied.code==2&&callbacks==0,@"retired original never supplies exact active proof or invokes callback");
        Check(![f.store configurationWithIdentifier:record.identifier absent:&absent inCurrentSourceOperationBeforeDeadline:deadline error:&denied]&&!absent&&denied.code==2,@"already-fenced active read keeps retired UUID occupied");
        NSArray *rows=[f.store configurationsInCurrentSourceOperationBeforeDeadline:deadline error:&denied];Check(rows&&rows.count==0,@"already-fenced inventory hides valid tombstone");return YES;
    } beforeDeadline:deadline error:&error]&&[Snapshot(file) isEqual:retired],@"all active entry-point refusals preserve exact tombstone bytes and inode");
    LBXContainerConfiguration *missing=[LBXContainerConfiguration createWithName:@"Never committed" applications:@[@"com.burbn.instagram"] manualIdentifiers:nil proxyReference:@"" error:nil];NSString *missingFile=RecordPath(f.path,missing);
    Check(!Retire(f.store,f.owner,missing,&error)&&error.code==2&&!Snapshot(missingFile),@"retirement of absent UUID never creates a tombstone");Authorize(f.owner);Check(!Current(f.store,f.owner,missing,&error)&&error.code==2&&!Snapshot(missingFile),@"missing UUID is not prior retirement proof");
}
static void MalformedTests(NSString *base){RetirementFixture *f=Fixture(base,@"malformed");LBXContainerConfiguration *record=Fresh(f);NSError *error=nil;Check(Retire(f.store,f.owner,record,&error),@"canonical malformed-test tombstone");NSString *file=RecordPath(f.path,record);NSDictionary *tombstone=Read(file);NSData *original=[NSData dataWithContentsOfFile:file];NSMutableArray *bad=[NSMutableArray array];
    for(NSString *key in tombstone)[bad addObject:Change(tombstone,key,nil)];[bad addObject:Change(tombstone,@"extra",@YES)];
    for(id version in @[@YES,@0,@1,@3,@(-1),@2.5,@"2",NSNull.null])[bad addObject:Change(tombstone,@"storageVersion",version)];
    NSString *encoded=[[NSString alloc] initWithData:original encoding:NSUTF8StringEncoding];NSString *decimal=[encoded stringByReplacingOccurrencesOfString:@"\"storageVersion\":2" withString:@"\"storageVersion\":2.0"];Check(![decimal isEqual:encoded],@"floating version fixture preserves raw decimal syntax");[bad addObject:[decimal dataUsingEncoding:NSUTF8StringEncoding]];
    [bad addObject:[[encoded stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    NSString *duplicate=[[encoded substringToIndex:encoded.length-1] stringByAppendingString:@",\"retired\":true}"];[bad addObject:[duplicate dataUsingEncoding:NSUTF8StringEncoding]];
    for(id flag in @[@NO,@0,@1,@"true",NSNull.null,@[],@{}])[bad addObject:Change(tombstone,@"retired",flag)];
    for(id flag in @[@YES,@0,@1,@"false",NSNull.null,@[],@{}])[bad addObject:Change(tombstone,@"allocationReserved",flag)];
    NSArray *documents=@[NSNull.null,@YES,@42,@[],@{},@"bad",Change(record.privateDictionary,@"name",NSNull.null),Change(record.privateDictionary,@"revision",@YES),Change(record.privateDictionary,@"identifier",NSUUID.UUID.UUIDString.lowercaseString),Change(record.privateDictionary,@"identifier",record.identifier.uppercaseString),Change(record.privateDictionary,@"name",nil),Change(record.privateDictionary,@"applications",@[@"com.facebook.Facebook",@"com.burbn.instagram"])];
    for(id document in documents)[bad addObject:Change(tombstone,@"configuration",document)];
    LBXContainerConfiguration *edit=[record configurationByUpdatingName:@"No malformed repair" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];
    for(id corrupt in bad){Check(Put(file,corrupt),@"actual malformed tombstone bytes written in isolated fixture");NSDictionary *before=Snapshot(file);double deadline=LBXLicenseIPCClock()+3;
        Check([f.owner performSourceOperation:^BOOL(__unused NSError **failure){NSError *denied=nil;BOOL absent=YES;__block NSUInteger callbacks=0;
            Check(![f.store configurationWithIdentifier:record.identifier absent:&absent error:&denied]&&!absent&&denied.code==1,@"malformed retirement is unsafe, never missing or valid retired conflict");
            Check(![f.store configurations:&denied]&&denied.code==1,@"ordinary inventory cannot silently hide malformed retirement");
            Check(![f.store retireConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline error:&denied]&&denied.code==1,@"malformed retirement cannot be repaired or adopted by retire");
            Check(![f.store retirementCurrentForConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline error:&denied]&&denied.code==1,@"malformed retirement never supplies idempotent retry proof");
            Check(![f.store commitConfiguration:edit replacing:record inCurrentSourceOperationBeforeDeadline:deadline error:&denied],@"active edit cannot overwrite malformed retirement");
            Check(![f.store reserveConfigurationForClosedAllocation:record beforeDeadline:deadline error:&denied],@"reserve cannot adopt malformed retirement");
            Check(![f.store performWithExactConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *context,__unused NSError **proofError){callbacks++;return YES;} error:&denied]&&callbacks==0,@"malformed retirement cannot invoke active proof callback");return YES;
        } beforeDeadline:deadline error:&error]&&[Snapshot(file) isEqual:before],@"all malformed refusals preserve exact bytes and inode");
        Check(Put(file,original),@"fixture restores only its own retained canonical tombstone bytes");
    }
    Check(Current(f.store,f.owner,record,&error)&&Retire(f.store,f.owner,record,&error)&&Tombstone(Read(file),record),@"canonical restored tombstone remains exact retryable after all malformed refusals");
}
static void UnsafeNodeTests(NSString *base){for(NSString *state in @[@"active",@"retired"])for(NSString *kind in @[@"mode",@"hardlink",@"symlink",@"dangling",@"directory",@"fifo",@"lock-replacement",@"directory-replacement"]){RetirementFixture *f=Fixture(base,[NSString stringWithFormat:@"unsafe-%@-%@",state,kind]);LBXContainerConfiguration *record=Fresh(f);NSError *error=nil;
        if([state isEqual:@"retired"])Check(Retire(f.store,f.owner,record,&error),@"unsafe exact-retry fixture begins with actual canonical retirement");
        NSString *file=RecordPath(f.path,record),*held=Join(f.base,@"held-original"),*lock=Join(f.path,@"configuration.lock");NSDictionary *original=Snapshot(file);BOOL changed=NO;
        if([kind isEqual:@"mode"])changed=!chmod(file.fileSystemRepresentation,0644);
        else if([kind isEqual:@"hardlink"])changed=!link(file.fileSystemRepresentation,held.fileSystemRepresentation);
        else if([kind isEqual:@"symlink"]||[kind isEqual:@"dangling"])changed=!rename(file.fileSystemRepresentation,held.fileSystemRepresentation)&&!symlink(([kind isEqual:@"symlink"]?held:Join(f.base,@"no-target")).fileSystemRepresentation,file.fileSystemRepresentation);
        else if([kind isEqual:@"directory"]||[kind isEqual:@"fifo"])changed=!rename(file.fileSystemRepresentation,held.fileSystemRepresentation)&&([kind isEqual:@"directory"]?!mkdir(file.fileSystemRepresentation,0700):!mkfifo(file.fileSystemRepresentation,0600));
        else if([kind isEqual:@"lock-replacement"]){changed=!rename(lock.fileSystemRepresentation,held.fileSystemRepresentation);int fd=changed?open(lock.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600):-1;changed=changed&&fd>=0;if(fd>=0)close(fd);}
        else changed=!rename(f.path.fileSystemRepresentation,held.fileSystemRepresentation)&&!mkdir(f.path.fileSystemRepresentation,0700);
        Check(changed,@"actual unsafe node or established namespace replacement");NSString *preserved=[kind isEqual:@"directory-replacement"]?RecordPath(held,record):([@[@"symlink",@"dangling",@"directory",@"fifo"] containsObject:kind]?held:file);NSDictionary *unsafeBefore=Snapshot(preserved);double deadline=LBXLicenseIPCClock()+3;
        Check([f.owner performSourceOperation:^BOOL(__unused NSError **failure){NSError *denied=nil;BOOL absent=YES;
            Check(![f.store retireConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline error:&denied]&&denied.code==1,@"unsafe node refuses retirement without replacement");
            Check(![f.store retirementCurrentForConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline error:&denied]&&denied.code==1,@"unsafe node refuses retirement proof");
            Check(![f.store configurationWithIdentifier:record.identifier absent:&absent error:&denied]&&!absent&&denied.code==1,@"unsafe node cannot manufacture confirmed absence");return YES;
        } beforeDeadline:deadline error:&error]&&[Snapshot(preserved) isEqual:unsafeBefore],@"unsafe refusals preserve actual original node and bytes");
        if([kind isEqual:@"mode"])chmod(file.fileSystemRepresentation,0600);
        else if([kind isEqual:@"hardlink"])unlink(held.fileSystemRepresentation);
        else if([@[@"symlink",@"dangling",@"fifo"] containsObject:kind]){unlink(file.fileSystemRepresentation);rename(held.fileSystemRepresentation,file.fileSystemRepresentation);}
        else if([kind isEqual:@"directory"]){rmdir(file.fileSystemRepresentation);rename(held.fileSystemRepresentation,file.fileSystemRepresentation);}
        else if([kind isEqual:@"lock-replacement"]){unlink(lock.fileSystemRepresentation);rename(held.fileSystemRepresentation,lock.fileSystemRepresentation);}
        else {rmdir(f.path.fileSystemRepresentation);rename(held.fileSystemRepresentation,f.path.fileSystemRepresentation);}
        Check([Snapshot(file) isEqual:original],@"fixture restores its exact original node rather than minting replacement state");Check(Retire(f.store,f.owner,record,&error)&&Tombstone(Read(file),record),@"restored original safe fixture can retire after unsafe refusal");
    }}
static void FenceTests(NSString *base){RetirementFixture *f=Fixture(base,@"fences");LBXContainerConfiguration *record=Fresh(f);NSString *file=RecordPath(f.path,record);NSDictionary *original=Snapshot(file);NSError *error=nil;double deadline=LBXLicenseIPCClock()+3;
    Check(![f.store retireConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline error:&error]&&error.code==4,@"signed admission alone does not authorize retirement outside active fence");
    Check(![f.store retirementCurrentForConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline error:&error]&&error.code==4&&[Snapshot(file) isEqual:original],@"retirement assertion also requires active owner context");
    RetirementFixture *foreign=Fixture(base,@"foreign-owner");deadline=LBXLicenseIPCClock()+3;
    Check([foreign.owner performSourceOperation:^BOOL(__unused NSError **failure){NSError *denied=nil;Check(![f.store retireConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline error:&denied]&&denied.code==4,@"independently signed foreign owner fence cannot authorize this store");return YES;} beforeDeadline:deadline error:&error]&&[Snapshot(file) isEqual:original],@"foreign owner refusal preserves exact original");
    deadline=LBXLicenseIPCClock()+3;Check([f.owner performSourceOperation:^BOOL(__unused NSError **failure){__block NSError *denied=nil;
        Check(![f.store retireConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline+.01 error:&denied]&&denied.code==4,@"changed deadline cannot borrow owning source fence");
        for(NSNumber *bad in @[@(NAN),@(-1),@(deadline+30)])Check(![f.store retirementCurrentForConfiguration:record inCurrentSourceOperationBeforeDeadline:bad.doubleValue error:&denied]&&denied.code==4,@"invalid or foreign deadline conveys no retirement proof");
        __block BOOL escaped=YES;dispatch_sync(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{escaped=[f.store retireConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline error:nil];});Check(!escaped,@"retirement cannot escape active owning serial queue");
        Check(![f.owner performSourceOperation:^BOOL(__unused NSError **nested){return YES;} beforeDeadline:deadline error:&denied]&&denied.code==2,@"reentrant owner operation cannot mint nested retirement fence");
        return [f.store performWithExactConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *context,__unused NSError **proofError){
            Check(![f.store retireConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline error:&denied]&&denied.code==4,@"held active proof cannot recursively publish retirement");
            Check(![f.store retirementCurrentForConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline error:&denied]&&denied.code==4,@"held active proof cannot borrow retirement assertion lock");return YES;
        } error:nil];
    } beforeDeadline:deadline error:&error]&&[Snapshot(file) isEqual:original],@"recursive, escaped and changed-context refusals preserve active record");
    deadline=LBXLicenseIPCClock()+.025;__block BOOL late=YES;Check(![f.owner performSourceOperation:^BOOL(NSError **failure){usleep(45000);late=[f.store retireConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline error:failure];return late;} beforeDeadline:deadline error:&error]&&!late&&[Snapshot(file) isEqual:original],@"expired original operation cannot retire after waiting");Authorize(f.owner);
    int lock=open(Join(f.path,@"configuration.lock").fileSystemRepresentation,O_RDWR);Check(lock>=0&&!flock(lock,LOCK_EX|LOCK_NB),@"independent actual lock contention fixture");deadline=LBXLicenseIPCClock()+.04;double started=LBXLicenseIPCClock();Check(![f.owner performSourceOperation:^BOOL(NSError **failure){return [f.store retireConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline error:failure];} beforeDeadline:deadline error:&error]&&LBXLicenseIPCClock()-started<.8&&[Snapshot(file) isEqual:original],@"held lock consumes deadline and permits no late publication");if(lock>=0){flock(lock,LOCK_UN);close(lock);}Authorize(f.owner);
    signedStatus=@"revoked";Check([Send(f.owner,@"validate")[@"result"] isEqual:@"revoked"]&&![f.owner sourceAuthorizationCurrent],@"actual signed synthetic revocation closes owner admission");NSUInteger before=requests;
    Check(!Retire(f.store,f.owner,record,&error)&&!Current(f.store,f.owner,record,&error)&&[Snapshot(file) isEqual:original]&&requests==before,@"revocation denies retirement and proof without implicit validation or file effect");
}
static double Continuous(void){mach_timebase_info_data_t scale;mach_timebase_info(&scale);return scale.denom?(double)mach_continuous_time()*scale.numer/scale.denom/1e9:NAN;}
static void PublicationFailureTests(NSString *base){RetirementFixture *f=Fixture(base,@"published-expiry");LBXContainerConfiguration *record=Fresh(f);NSString *file=RecordPath(f.path,record);__block BOOL armed=NO,observedPublication=NO;__block double wall=NSDate.date.timeIntervalSince1970,continuous=Continuous();
    [f.owner testUseAuthorizationClock:^double(BOOL monotonic){if(armed&&!observedPublication&&Tombstone(Read(file),record)){observedPublication=YES;wall+=65;continuous+=65;}return monotonic?continuous:wall;}];Authorize(f.owner);armed=YES;NSError *error=nil;
    Check(!Retire(f.store,f.owner,record,&error)&&observedPublication&&error.code==4&&Tombstone(Read(file),record)&&![f.owner sourceAuthorizationCurrent],@"genuine synthetic signed-fence expiry after observed rename reports failure and retains durable full tombstone");NSDictionary *retired=Snapshot(file);armed=NO;
    Check(!Retire(f.store,f.owner,record,&error)&&[Snapshot(file) isEqual:retired],@"closed owner cannot turn failed publication into an authorized retry");wall=NSDate.date.timeIntervalSince1970;continuous=Continuous();Authorize(f.owner);
    Check(Current(f.store,f.owner,record,&error)&&Retire(f.store,f.owner,record,&error)&&[Snapshot(file) isEqual:retired],@"fresh signed validation reconciles exact retained tombstone without rollback or rewrite");
    LBXLicenseOwner *restart=NewOwner(f.vault);LBXContainerConfigurationStore *store=[LBXContainerConfigurationStore openDirectory:f.path licenseOwner:restart create:NO error:nil];Authorize(restart);Check(Current(store,restart,record,&error)&&[Snapshot(file) isEqual:retired],@"published failure retirement survives actual fresh owner and store reopen");
}
static void NonPristineTests(NSString *base){RetirementFixture *f=Fixture(base,@"tombstone-only");LBXContainerConfiguration *record=Fresh(f);NSError *error=nil;Check(Retire(f.store,f.owner,record,&error),@"actual tombstone-only namespace");NSString *file=RecordPath(f.path,record);NSDictionary *retired=Snapshot(file);NSArray *rows=[f.store configurations:&error];Check(rows&&rows.count==0,@"empty active list does not imply empty physical namespace");double deadline=LBXLicenseIPCClock()+3;__block NSUInteger callbacks=0;
    Check(![f.owner performSourceOperation:^BOOL(NSError **failure){return [f.store performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *context,__unused NSError **callbackError){callbacks++;return YES;} error:failure];} beforeDeadline:deadline error:&error]&&callbacks==0&&[Snapshot(file) isEqual:retired],@"tombstone blocks every pristine-empty callback without cleanup or reset");Authorize(f.owner);
    Check(![LBXContainerConfigurationStore createPristineDirectory:f.path licenseOwner:f.owner error:&error]&&[Snapshot(file) isEqual:retired],@"explicit pristine-directory creation cannot adopt tombstone-only established namespace");
    LBXContainerConfigurationStore *reopened=[LBXContainerConfigurationStore openDirectory:f.path licenseOwner:f.owner create:NO error:nil];Check(reopened&&Current(reopened,f.owner,record,&error)&&[Snapshot(file) isEqual:retired],@"existing-only reopen retains valid retirement despite zero active rows");
}
int main(void){@autoreleasepool{char temporary[]="/tmp/socialbox-configuration-retirement.XXXXXX";Check(mkdtemp(temporary)!=NULL,@"fresh private fixture root");NSString *base=[[NSString stringWithUTF8String:temporary] stringByResolvingSymlinksInPath];
    Check(!chmod(base.fileSystemRepresentation,0700),@"private fixture root mode");ExactAndProjectionTests(base);FullDocumentAndEligibilityTests(base);ActiveEntryPointTests(base);MalformedTests(base);UnsafeNodeTests(base);FenceTests(base);PublicationFailureTests(base);NonPristineTests(base);
    [NSFileManager.defaultManager removeItemAtPath:base error:nil];printf("%s: %lu direct configuration retirement assertions, %lu failures (actual files; synthetic signed owner; UI/IPC/pending validity NOT_RUN)\n",failures?"FAIL":"PASS",(unsigned long)checks,(unsigned long)failures);return failures?1:0;}}
