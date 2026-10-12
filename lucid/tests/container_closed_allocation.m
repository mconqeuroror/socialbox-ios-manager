#import "../Containers/LBXContainerClosedAllocation.h"
#import "../Containers/LBXContainerConfiguration.h"
#import "../Containers/LBXContainerConfigurationStore.h"
#import "../Containers/LBXContainerIdentitySpecification.h"
#import "../Authorization/LBXLicenseOwner.h"
#import "../Authorization/LBXLicenseVault.h"
#import "../Authorization/LBXLicenseIPC.h"
#import "../../tests/RBXLicenseTestSupport.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/acl.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>
#include <membership.h>
#include <mach/mach_time.h>

static NSUInteger checks,failures,requests;
static NSString *mode=@"active";
static void Check(BOOL good,NSString *why){checks++;if(!good){failures++;fprintf(stderr,"FAIL: %s\n",why.UTF8String);}}
@interface AllocationProtocol:NSURLProtocol @end
@implementation AllocationProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request{(void)request;return YES;}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request{return request;}
- (void)stopLoading{}
- (void)startLoading {
    requests++;NSData *body=self.request.HTTPBody;
    if(!body&&self.request.HTTPBodyStream){NSInputStream *stream=self.request.HTTPBodyStream;[stream open];NSMutableData *data=[NSMutableData data];uint8_t bytes[1024];NSInteger n;while((n=[stream read:bytes maxLength:sizeof(bytes)])>0)[data appendBytes:bytes length:(NSUInteger)n];[stream close];body=data;}
    NSDictionary *request=[NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    NSMutableDictionary *claims=TestLicenseClaims(@"AAAA-BBBB-CCCC-DDDD",request[@"nonce"],NSDate.date.timeIntervalSince1970);
    claims[@"iss"]=@"https://redditspoof.vercel.app";claims[@"deviceBinding"]=[RBXLicenseToken fingerprint:request[@"deviceIdentity"]];claims[@"status"]=mode;
    NSDictionary *reply=@{@"licenseToken":TestLicenseJWT(claims,nil),@"deviceId":@"fixture-device",@"token":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0]};
    NSHTTPURLResponse *http=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    [self.client URLProtocol:self didReceiveResponse:http cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil]];[self.client URLProtocolDidFinishLoading:self];
}
@end
static NSDictionary *Context(void){return @{@"machine":@"iPhone10,6",@"model":@"D221AP",@"osBuild":@"20H392",@"osRelease":@"22.6.0",@"memoryBytes":@3119919104,@"osVersion":@{@"major":@16,@"minor":@7,@"patch":@16}};}
static LBXLicenseOwner *NewOwner(LBXLicenseVault *vault){LBXLicenseOwner *owner=[[LBXLicenseOwner alloc] initWithVault:vault];[owner testUseProtocol:AllocationProtocol.class publicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];return owner;}
static NSDictionary *License(LBXLicenseOwner *owner,NSString *operation){
    __block NSDictionary *reply;dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [owner handleRequest:LBXLicenseIPCRequest(operation,[operation isEqual:@"activate"]?@"AAAA-BBBB-CCCC-DDDD":nil) completion:^(NSDictionary *value){reply=value;dispatch_semaphore_signal(done);}];
    Check(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)),@"bounded real signed owner reply");return reply;
}
static void Authorize(LBXLicenseOwner *owner){mode=@"active";Check([License(owner,@"validate")[@"result"] isEqual:@"active"],@"fresh real signed source authorization");}
static LBXContainerConfiguration *NewConfiguration(LBXContainerConfigurationStore *store){
    LBXContainerConfiguration *record=[LBXContainerConfiguration createWithName:@"Private allocation fixture" applications:@[@"com.burbn.instagram"] manualIdentifiers:nil proxyReference:nil error:nil];
    Check(record&&[store commitConfiguration:record replacing:nil beforeDeadline:LBXLicenseIPCClock()+3 error:nil],@"source configuration saved before allocation");return record;
}
static NSDictionary *Ensure(LBXContainerClosedAllocation *allocation,LBXContainerConfiguration *record,NSError **error){return [allocation ensureClosedAllocationForConfiguration:record beforeDeadline:LBXLicenseIPCClock()+3 error:error];}
static NSString *Journal(NSString *root,LBXContainerConfiguration *record){return [[root stringByAppendingPathComponent:@"journals"] stringByAppendingPathComponent:[record.identifier stringByAppendingString:@".json"]];}
static NSString *Leaf(NSString *root,LBXContainerConfiguration *record){return [[root stringByAppendingPathComponent:@"resources"] stringByAppendingPathComponent:record.identifier];}
static NSString *ConfigurationPath(NSString *root,LBXContainerConfiguration *record){return [root stringByAppendingPathComponent:[record.identifier stringByAppendingString:@".json"]];}
static NSDictionary *Read(NSString *path){NSData *data=[NSData dataWithContentsOfFile:path];return data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;}
static double Continuous(void){mach_timebase_info_data_t scale;mach_timebase_info(&scale);return (double)mach_continuous_time()*scale.numer/scale.denom/1e9;}
static BOOL SetACL(NSString *path,BOOL populated){
    acl_t acl=acl_init(populated?1:0);BOOL valid=acl!=NULL;
    if(populated){uuid_t subject;acl_entry_t entry;acl_permset_t permissions;
        valid=valid&&!mbr_uid_to_uuid(geteuid(),subject)&&!acl_create_entry(&acl,&entry)&&
            !acl_set_tag_type(entry,ACL_EXTENDED_ALLOW)&&!acl_set_qualifier(entry,subject)&&
            !acl_get_permset(entry,&permissions)&&!acl_add_perm(permissions,ACL_READ_DATA);
    }
    if(valid)valid=acl_set_file(path.fileSystemRepresentation,ACL_TYPE_EXTENDED,acl)==0;
    if(acl)acl_free(acl);return valid;
}
static void Write(NSString *path,NSDictionary *record){NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:nil];Check([data writeToFile:path atomically:NO],@"private malformed fixture write");chmod(path.fileSystemRepresentation,0600);}
static void Inspect(NSDictionary *result,NSString *root,LBXContainerConfiguration *record){
    Check([result[@"phase"] isEqual:@"closed"]&&[result[@"runtimeAccepted"] isEqual:@NO]&&[result[@"configuration"] isEqual:record.privateDictionary],@"closed result retains exact complete configuration without runtime grant");
    for(NSString *key in @[@"allocation",@"data",@"groups"]){NSString *path=Leaf(root,record);if(![key isEqual:@"allocation"])path=[path stringByAppendingPathComponent:key];struct stat s;NSDictionary *node=result[@"resources"][key];
        Check(!lstat(path.fileSystemRepresentation,&s)&&S_ISDIR(s.st_mode)&&(s.st_mode&07777)==0700&&s.st_uid==geteuid()&&s.st_gid==getegid(),@"allocated namespace stays private and closed under host UID role");
        Check(s.st_dev==[node[@"device"] longLongValue]&&s.st_ino==[node[@"inode"] unsignedLongLongValue],@"exact persisted directory device/inode binding");
    }
}
static void ReservationBoundaryTests(LBXContainerConfigurationStore *store,LBXLicenseOwner *owner,LBXLicenseVault *vault,NSString *base,NSString *storePath){
    Authorize(owner);LBXContainerConfiguration *record=NewConfiguration(store);NSString *root=[base stringByAppendingPathComponent:@"reserved-no-journal"],*file=ConfigurationPath(storePath,record);NSError *error=nil;
    LBXContainerClosedAllocation *instance=[LBXContainerClosedAllocation openDirectory:root configurationStore:store licenseOwner:owner create:YES error:nil];[instance testStopAfterBoundary:@"configuration_reserved"];
    Check(!Ensure(instance,record,&error)&&[Read(file)[@"allocationReserved"] isEqual:@YES]&&![NSFileManager.defaultManager fileExistsAtPath:Journal(root,record)]&&![NSFileManager.defaultManager fileExistsAtPath:Leaf(root,record)],@"interruption after real reservation freezes exact record before any journal/resource effect");NSData *reservedBytes=[NSData dataWithContentsOfFile:file];
    Authorize(owner);LBXContainerConfiguration *edit=[record configurationByUpdatingName:@"Interrupted reservation cannot edit" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];LBXContainerConfigurationStore *peer=[LBXContainerConfigurationStore openDirectory:storePath licenseOwner:owner create:NO error:nil];
    Check(![peer commitConfiguration:edit replacing:record beforeDeadline:LBXLicenseIPCClock()+3 error:&error]&&error.code==2&&[[NSData dataWithContentsOfFile:file] isEqual:reservedBytes],@"reserved no-journal configuration blocks independent-store edit");
    LBXLicenseOwner *restart=NewOwner(vault);LBXContainerConfigurationStore *reopenedStore=[LBXContainerConfigurationStore openDirectory:storePath licenseOwner:restart create:NO error:nil];Authorize(restart);
    Check(![reopenedStore commitConfiguration:edit replacing:record beforeDeadline:LBXLicenseIPCClock()+3 error:&error]&&error.code==2&&[[NSData dataWithContentsOfFile:file] isEqual:reservedBytes],@"real owner/store restart cannot thaw interrupted reservation");Authorize(restart);
    LBXContainerClosedAllocation *reopened=[LBXContainerClosedAllocation openDirectory:root configurationStore:reopenedStore licenseOwner:restart create:NO error:nil];NSDictionary *recovered=Ensure(reopened,record,&error);
    Check(recovered&&[recovered[@"configuration"] isEqual:record.privateDictionary]&&[[NSData dataWithContentsOfFile:file] isEqual:reservedBytes],@"exact revalidated allocator reconciles reserved no-journal record without metadata rewrite");if(recovered)Inspect(recovered,root,record);Authorize(owner);
    LBXContainerConfiguration *legacy=NewConfiguration(store);NSString *legacyRoot=[base stringByAppendingPathComponent:@"legacy-no-journal"],*legacyFile=ConfigurationPath(storePath,legacy);Write(legacyFile,legacy.privateDictionary);NSData *legacyBytes=[NSData dataWithContentsOfFile:legacyFile];
    LBXContainerConfiguration *legacyEdit=[legacy configurationByUpdatingName:@"Old allocation unknown" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];
    Check(![store commitConfiguration:legacyEdit replacing:legacy beforeDeadline:LBXLicenseIPCClock()+3 error:&error]&&error.code==2&&[[NSData dataWithContentsOfFile:legacyFile] isEqual:legacyBytes],@"bare legacy record cannot silently become editable");Authorize(owner);
    LBXContainerClosedAllocation *legacyAllocation=[LBXContainerClosedAllocation openDirectory:legacyRoot configurationStore:store licenseOwner:owner create:YES error:nil];NSDictionary *legacyResult=Ensure(legacyAllocation,legacy,&error);
    Check(legacyResult&&[Read(legacyFile)[@"allocationReserved"] isEqual:@YES]&&[Read(legacyFile)[@"configuration"] isEqual:legacy.privateDictionary],@"new no-journal trusted allocator upgrades exact bare record only to frozen true");
    NSData *frozenLegacy=[NSData dataWithContentsOfFile:legacyFile],*journalBytes=[NSData dataWithContentsOfFile:Journal(legacyRoot,legacy)];
    for(NSNumber *bare in @[@YES,@NO]){Authorize(owner);NSDictionary *downgrade=bare.boolValue?legacy.privateDictionary:@{@"storageVersion":@1,@"configuration":legacy.privateDictionary,@"allocationReserved":@NO};Write(legacyFile,downgrade);NSData *downgraded=[NSData dataWithContentsOfFile:legacyFile];
        Check(!Ensure(legacyAllocation,legacy,&error)&&error.code==2&&[[NSData dataWithContentsOfFile:legacyFile] isEqual:downgraded]&&[[NSData dataWithContentsOfFile:Journal(legacyRoot,legacy)] isEqual:journalBytes],@"prior journal with bare/false marker refuses without refreezing or altering journal");
        Check([frozenLegacy writeToFile:legacyFile atomically:NO]&&!chmod(legacyFile.fileSystemRepresentation,0600),@"fixture restores only exact original frozen envelope");}
    Authorize(owner);Check(Ensure(legacyAllocation,legacy,&error)!=nil,@"restored exact true marker allows known allocation recovery");
    LBXContainerConfiguration *late=NewConfiguration(store);NSString *lateRoot=[base stringByAppendingPathComponent:@"final-marker-downgrade"],*lateFile=ConfigurationPath(storePath,late);LBXContainerClosedAllocation *lateAllocation=[LBXContainerClosedAllocation openDirectory:lateRoot configurationStore:store licenseOwner:owner create:YES error:nil];__block BOOL armed=NO,downgraded=NO;
    [owner testUseAuthorizationClock:^double(BOOL continuous){if(!continuous&&armed&&!downgraded&&[Read(Journal(lateRoot,late))[@"phase"] isEqual:@"closed"]){NSMutableDictionary *envelope=[Read(lateFile) mutableCopy];envelope[@"allocationReserved"]=@NO;Write(lateFile,envelope);downgraded=[Read(lateFile)[@"allocationReserved"] isEqual:@NO];}return continuous?Continuous():NSDate.date.timeIntervalSince1970;}];
    Authorize(owner);armed=YES;Check(!Ensure(lateAllocation,late,&error)&&downgraded&&[Read(lateFile)[@"allocationReserved"] isEqual:@NO],@"actual final marker downgrade after resources close invalidates acceptance without refreeze");armed=NO;
    NSData *lateJournal=[NSData dataWithContentsOfFile:Journal(lateRoot,late)],*lateMetadata=[NSData dataWithContentsOfFile:lateFile];[owner testUseAuthorizationClock:^double(BOOL continuous){return continuous?Continuous():NSDate.date.timeIntervalSince1970;}];Authorize(owner);
    Check(!Ensure(lateAllocation,late,&error)&&error.code==2&&[[NSData dataWithContentsOfFile:lateFile] isEqual:lateMetadata]&&[[NSData dataWithContentsOfFile:Journal(lateRoot,late)] isEqual:lateJournal],@"late-downgrade journal remains conflict without repair on exact retry");Authorize(owner);
}
static void IndependentStoreRaces(LBXContainerConfigurationStore *store,LBXLicenseOwner *owner,NSString *base,NSString *storePath){
    LBXLicenseVault *peerVault=[LBXLicenseVault openDirectory:[base stringByAppendingPathComponent:@"race-independent-license"] error:nil];[peerVault testUsePublicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];LBXLicenseOwner *peerOwner=NewOwner(peerVault);Check([License(peerOwner,@"activate")[@"result"] isEqual:@"active"],@"independent competitor gets separately paired synthetic-signed admission");LBXContainerConfigurationStore *peer=[LBXContainerConfigurationStore openDirectory:storePath licenseOwner:peerOwner create:NO error:nil];Check(peer!=nil,@"independent owner/store shares actual configuration.lock");NSUInteger editWins=0,allocationWins=0;
    for(NSUInteger i=0;i<16;i++){@autoreleasepool{Authorize(owner);Authorize(peerOwner);LBXContainerConfiguration *record=NewConfiguration(store),*edit=[record configurationByUpdatingName:@"Concurrent metadata edit" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];NSString *root=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"independent-race-%lu",(unsigned long)i]];LBXContainerClosedAllocation *instance=[LBXContainerClosedAllocation openDirectory:root configurationStore:store licenseOwner:owner create:YES error:nil];
        Check([owner sourceAuthorizationCurrent]&&[peerOwner sourceAuthorizationCurrent],@"both independent owner assessments are truly current before concurrent launch");dispatch_semaphore_t ready=dispatch_semaphore_create(0),go=dispatch_semaphore_create(0);dispatch_group_t done=dispatch_group_create();__block NSDictionary *allocated=nil;__block BOOL edited=NO;__block NSError *allocationError=nil,*editError=nil;
        dispatch_group_enter(done);dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{dispatch_semaphore_signal(ready);if(!dispatch_semaphore_wait(go,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC)))allocated=Ensure(instance,record,&allocationError);dispatch_group_leave(done);});
        dispatch_group_enter(done);dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{dispatch_semaphore_signal(ready);if(!dispatch_semaphore_wait(go,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC)))edited=[peer commitConfiguration:edit replacing:record beforeDeadline:LBXLicenseIPCClock()+3 error:&editError];dispatch_group_leave(done);});
        Check(!dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))&&!dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC)),@"two independent-owner host threads reach real operation barrier");dispatch_semaphore_signal(go);dispatch_semaphore_signal(go);Check(!dispatch_group_wait(done,dispatch_time(DISPATCH_TIME_NOW,6*NSEC_PER_SEC)),@"independent store/allocator race completes within fixed bound");LBXContainerConfiguration *current=[store configurationWithIdentifier:record.identifier error:nil];NSDictionary *envelope=Read(ConfigurationPath(storePath,record));
        if(allocated){allocationWins++;Check(!edited&&editError.code==2&&[current.privateDictionary isEqual:record.privateDictionary]&&[envelope[@"allocationReserved"] isEqual:@YES]&&[allocated[@"configuration"] isEqual:record.privateDictionary]&&[Read(Journal(root,record))[@"phase"] isEqual:@"closed"],@"allocation winner freezes exact old snapshot while cached competing edit conflicts");}
        else if(edited){editWins++;Check(allocationError.code==2&&[current.privateDictionary isEqual:edit.privateDictionary]&&[envelope[@"allocationReserved"] isEqual:@NO]&&![NSFileManager.defaultManager fileExistsAtPath:Journal(root,record)]&&![NSFileManager.defaultManager fileExistsAtPath:Leaf(root,record)],@"edit winner stays editable and stale allocator creates no journal or namespace");}
        else Check(NO,@"race must have one healthy winner rather than strand or deny both");
    }}Check(editWins+allocationWins==16,@"all16 independent-owner/store host-thread races preserve one-winner invariant");NSLog(@"Independent host-thread races: %lu edit winners, %lu allocation winners; physical simultaneous processes NOT_RUN",(unsigned long)editWins,(unsigned long)allocationWins);
    // This additional competing execution deterministically holds the allocator
    // after real reservation and after configuration.lock is released, before
    // journal publication. The independent owner can therefore actually finish
    // its stale edit while allocation remains in progress, without a queue cycle.
    Authorize(owner);Authorize(peerOwner);LBXContainerConfiguration *record=NewConfiguration(store),*edit=[record configurationByUpdatingName:@"Cached edit after reservation" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];NSString *root=[base stringByAppendingPathComponent:@"independent-reservation-winner"],*file=ConfigurationPath(storePath,record),*lockPath=[storePath stringByAppendingPathComponent:@"configuration.lock"];LBXContainerClosedAllocation *instance=[LBXContainerClosedAllocation openDirectory:root configurationStore:store licenseOwner:owner create:YES error:nil];
    dispatch_semaphore_t reserved=dispatch_semaphore_create(0),editDone=dispatch_semaphore_create(0);__block BOOL armed=NO,paused=NO,editCompletedWhilePaused=NO;
    [owner testUseAuthorizationClock:^double(BOOL continuous){if(!continuous&&armed&&!paused&&[Read(file)[@"allocationReserved"] isEqual:@YES]&&![NSFileManager.defaultManager fileExistsAtPath:Journal(root,record)]){int held=open(lockPath.fileSystemRepresentation,O_RDWR|O_NOFOLLOW);if(held>=0){BOOL free=!flock(held,LOCK_EX|LOCK_NB);if(free)flock(held,LOCK_UN);close(held);if(free){paused=YES;dispatch_semaphore_signal(reserved);editCompletedWhilePaused=!dispatch_semaphore_wait(editDone,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC));}}}return continuous?Continuous():NSDate.date.timeIntervalSince1970;}];
    Authorize(owner);Check([owner sourceAuthorizationCurrent]&&[peerOwner sourceAuthorizationCurrent],@"both independent synthetic-signed owners are admitted before deterministic concurrent reserve winner");armed=YES;
    dispatch_group_t done=dispatch_group_create();__block NSDictionary *allocated=nil;__block BOOL edited=NO;__block NSError *allocationError=nil,*editError=nil;
    dispatch_group_enter(done);dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{allocated=Ensure(instance,record,&allocationError);dispatch_group_leave(done);});
    dispatch_group_enter(done);dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{if(!dispatch_semaphore_wait(reserved,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC)))edited=[peer commitConfiguration:edit replacing:record beforeDeadline:LBXLicenseIPCClock()+3 error:&editError];dispatch_semaphore_signal(editDone);dispatch_group_leave(done);});
    Check(!dispatch_group_wait(done,dispatch_time(DISPATCH_TIME_NOW,6*NSEC_PER_SEC)),@"deterministic independent-owner concurrent reserve winner completes within bound");armed=NO;
    Check(paused&&editCompletedWhilePaused&&allocated&&!allocationError&&!edited&&editError.code==2&&[Read(file)[@"allocationReserved"] isEqual:@YES]&&[Read(file)[@"configuration"] isEqual:record.privateDictionary]&&[Read(Journal(root,record))[@"phase"] isEqual:@"closed"],@"actual concurrent cached edit conflicts while real allocation remains paused after reservation and resumes closed");
    [owner testUseAuthorizationClock:^double(BOOL continuous){return continuous?Continuous():NSDate.date.timeIntervalSince1970;}];Authorize(owner);Authorize(peerOwner);Check([store configurationWithIdentifier:record.identifier error:nil]!=nil,@"deterministic winner remains readable after both source owners revalidate");NSLog(@"Deterministic host-thread allocation winner: PASS; physical simultaneous processes NOT_RUN");
}
int main(void){@autoreleasepool {
    [LBXContainerIdentitySpecification testUsePhysicalContext:Context()];char temporary[]="/tmp/socialbox-closed-allocation.XXXXXX";Check(mkdtemp(temporary)!=NULL,@"private allocation fixture parent");
    char physical[PATH_MAX];Check(realpath(temporary,physical)!=NULL,@"POSIX physical path retains the real no-follow temporary ancestor");
    NSString *base=[NSString stringWithUTF8String:physical],*storePath=[base stringByAppendingPathComponent:@"configurations"],*path=[base stringByAppendingPathComponent:@"allocation"];
    Check(!chown(base.fileSystemRepresentation,geteuid(),getegid()),@"host private parent uses the declared test owner/group");
    LBXLicenseVault *vault=[LBXLicenseVault openDirectory:[base stringByAppendingPathComponent:@"license"] error:nil];[vault testUsePublicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];
    LBXLicenseOwner *owner=NewOwner(vault);LBXContainerConfigurationStore *store=[LBXContainerConfigurationStore openDirectory:storePath licenseOwner:owner create:YES error:nil];
    Check([License(owner,@"activate")[@"result"] isEqual:@"active"],@"real signed activation before source configuration publication");
    LBXContainerConfiguration *original=NewConfiguration(store);NSError *error=nil;
    Check(![LBXContainerClosedAllocation openDirectory:path configurationStore:store licenseOwner:owner create:NO error:&error]&&![NSFileManager.defaultManager fileExistsAtPath:path],@"open-only never invents allocation infrastructure");
    Check(![LBXContainerClosedAllocation openDirectory:path configurationStore:store licenseOwner:NewOwner(vault) create:YES error:&error]&&![NSFileManager.defaultManager fileExistsAtPath:path],@"mismatched source/store ownership rejected before setup");
    LBXContainerClosedAllocation *allocation=[LBXContainerClosedAllocation openDirectory:path configurationStore:store licenseOwner:owner create:YES error:&error];Check(allocation!=nil,@"explicit root-private allocation infrastructure");
    LBXLicenseOwner *closed=NewOwner(vault);LBXContainerConfigurationStore *closedStore=[LBXContainerConfigurationStore openDirectory:storePath licenseOwner:closed create:NO error:nil];
    LBXContainerClosedAllocation *unlicensed=[LBXContainerClosedAllocation openDirectory:path configurationStore:closedStore licenseOwner:closed create:NO error:nil];
    NSUInteger calls=requests;Check(!Ensure(unlicensed,original,&error)&&![NSFileManager.defaultManager fileExistsAtPath:Journal(path,original)]&&requests==calls,@"closed owner cannot allocate or implicitly contact licensing");
    NSDictionary *result=Ensure(allocation,original,&error);Check(result!=nil,@"licensed allocation completes");if(result)Inspect(result,path,original);
    NSDictionary *captured=result[@"identitySpecification"];NSString *journal=Journal(path,original);NSData *saved=[NSData dataWithContentsOfFile:journal];struct stat before,after;lstat(journal.fileSystemRepresentation,&before);
    result=Ensure(allocation,original,&error);lstat(journal.fileSystemRepresentation,&after);
    Check(result&&[result[@"identitySpecification"] isEqual:captured]&&[[NSData dataWithContentsOfFile:journal] isEqual:saved]&&before.st_ino==after.st_ino,@"exact retry preserves captured specification and journal without rewriting");
    Check(![result isKindOfClass:NSMutableDictionary.class]&&![result[@"resources"] isKindOfClass:NSMutableDictionary.class],@"returned private snapshot has no mutable aliases");
    for(NSString *secret in @[original.identifier,original.name,original.identifiers[@"idfa"],path])Check(![allocation.description containsString:secret]&&![[allocation.safeStatus description] containsString:secret],@"safe projection omits private identity and paths");
    Authorize(closed);result=[unlicensed recoverClosedAllocationForConfiguration:original beforeDeadline:LBXLicenseIPCClock()+3 error:&error];
    Check(result&&[result[@"identitySpecification"] isEqual:captured]&&[[NSData dataWithContentsOfFile:journal] isEqual:saved],@"restart revalidation returns exact durable captured allocation");
    Authorize(owner);
    NSMutableDictionary *changedContext=[Context() mutableCopy];changedContext[@"osBuild"]=@"20H393";[LBXContainerIdentitySpecification testUsePhysicalContext:changedContext];
    Check(!Ensure(allocation,original,&error)&&error.code==2&&[[NSData dataWithContentsOfFile:journal] isEqual:saved],@"changed trusted current physical context cannot reuse binding");[LBXContainerIdentitySpecification testUsePhysicalContext:Context()];Authorize(owner);
    LBXContainerConfiguration *edit=[original configurationByUpdatingName:@"Changed saved document" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];
    NSData *configurationBytes=[NSData dataWithContentsOfFile:ConfigurationPath(storePath,original)];LBXContainerConfigurationStore *independentStore=[LBXContainerConfigurationStore openDirectory:storePath licenseOwner:owner create:NO error:nil];
    Check(![independentStore commitConfiguration:edit replacing:original beforeDeadline:LBXLicenseIPCClock()+3 error:&error]&&error.code==2&&[[NSData dataWithContentsOfFile:ConfigurationPath(storePath,original)] isEqual:configurationBytes],@"allocated source snapshot is frozen across independent store before any newer revision publication");Authorize(owner);
    Check(Ensure(allocation,original,&error)!=nil&&[[NSData dataWithContentsOfFile:journal] isEqual:saved],@"denied metadata edit leaves exact original allocation recoverable");
    Check(!Ensure(allocation,edit,&error)&&error.code==2&&[[NSData dataWithContentsOfFile:journal] isEqual:saved],@"unsaved newer snapshot cannot silently rebind allocated resources");Authorize(owner);
    LBXContainerConfiguration *other=NewConfiguration(store);NSMutableDictionary *aliases=[original.identifiers mutableCopy];aliases[@"idfa"]=[aliases[@"idfa"] lowercaseString];aliases[@"serialNumber"]=[aliases[@"serialNumber"] lowercaseString];
    LBXContainerConfiguration *alias=[LBXContainerConfiguration createWithName:@"Aliased identifiers" applications:@[@"com.burbn.instagram"] manualIdentifiers:aliases proxyReference:nil error:nil];
    Check(alias&&[store commitConfiguration:alias replacing:nil beforeDeadline:LBXLicenseIPCClock()+3 error:nil],@"valid syntactic alias configuration fixture");
    Check(!Ensure(allocation,alias,&error)&&error.code==2&&![NSFileManager.defaultManager fileExistsAtPath:Journal(path,alias)]&&![NSFileManager.defaultManager fileExistsAtPath:Leaf(path,alias)]&&[Read(ConfigurationPath(storePath,alias))[@"allocationReserved"] isEqual:@NO],@"normalized cross-configuration identity aliases fail before reservation or allocation effects");Authorize(owner);
    LBXContainerConfiguration *aliasEdit=[alias configurationByUpdatingName:@"Alias conflict remains editable" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];Check([store commitConfiguration:aliasEdit replacing:alias beforeDeadline:LBXLicenseIPCClock()+3 error:nil],@"failed alias attempt does not freeze source metadata");
    for(NSString *field in @[@"idfv",@"wifiMac"]){
        LBXContainerConfiguration *fresh=[LBXContainerConfiguration createWithName:@"Cross-field alias fixture" applications:@[@"com.burbn.instagram"] manualIdentifiers:nil proxyReference:nil error:nil];
        NSMutableDictionary *identifiers=[fresh.identifiers mutableCopy];identifiers[field]=[field isEqual:@"idfv"]?[original.identifiers[@"idfa"] lowercaseString]:[original.identifiers[@"bluetoothMac"] uppercaseString];
        LBXContainerConfiguration *cross=[LBXContainerConfiguration createWithName:@"Cross-field alias fixture" applications:@[@"com.burbn.instagram"] manualIdentifiers:identifiers proxyReference:nil error:nil];
        Check(cross&&[store commitConfiguration:cross replacing:nil beforeDeadline:LBXLicenseIPCClock()+3 error:nil],@"valid UUID/MAC cross-field alias fixture saved");
        Check(!Ensure(allocation,cross,&error)&&error.code==2&&![NSFileManager.defaultManager fileExistsAtPath:Journal(path,cross)]&&[Read(ConfigurationPath(storePath,cross))[@"allocationReserved"] isEqual:@NO],@"shared UUID/MAC namespaces reject cross-field aliases before reservation or effects");Authorize(owner);
        LBXContainerConfiguration *crossEdit=[cross configurationByUpdatingName:@"Cross-field conflict editable" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];Check([store commitConfiguration:crossEdit replacing:cross beforeDeadline:LBXLicenseIPCClock()+3 error:nil],@"cross-field identity conflict leaves metadata genuinely editable");
    }
    Check(Ensure(allocation,other,&error)!=nil,@"unrelated identity gets its own closed allocation");
    LBXContainerConfiguration *unsupported=[LBXContainerConfiguration createWithName:@"Unsupported selection" applications:@[@"com.burbn.instagram",@"com.facebook.Facebook"] manualIdentifiers:nil proxyReference:nil error:nil];
    Check([store commitConfiguration:unsupported replacing:nil beforeDeadline:LBXLicenseIPCClock()+3 error:nil]&&!Ensure(allocation,unsupported,&error)&&error.code==3&&[Read(ConfigurationPath(storePath,unsupported))[@"allocationReserved"] isEqual:@NO],@"multiple app membership has no allocation support and cannot freeze its saved configuration");
    LBXContainerConfiguration *supportedEdit=[unsupported configurationByUpdatingName:@"Selection can be corrected" applications:@[@"com.burbn.instagram"] manualIdentifiers:nil proxyReference:nil error:nil];Check([store commitConfiguration:supportedEdit replacing:unsupported beforeDeadline:LBXLicenseIPCClock()+3 error:nil],@"unsupported selection remains editable before real allocation");
    unsupported=[LBXContainerConfiguration createWithName:@"Unsupported proxy" applications:@[@"com.burbn.instagram"] manualIdentifiers:nil proxyReference:NSUUID.UUID.UUIDString.lowercaseString error:nil];
    Check([store commitConfiguration:unsupported replacing:nil beforeDeadline:LBXLicenseIPCClock()+3 error:nil]&&!Ensure(allocation,unsupported,&error)&&error.code==3&&[Read(ConfigurationPath(storePath,unsupported))[@"allocationReserved"] isEqual:@NO],@"unresolved proxy cannot freeze a saved allocation candidate");
    supportedEdit=[unsupported configurationByUpdatingName:@"Proxy can be cleared" applications:nil manualIdentifiers:nil proxyReference:@"" error:nil];Check([store commitConfiguration:supportedEdit replacing:unsupported beforeDeadline:LBXLicenseIPCClock()+3 error:nil],@"unsupported proxy choice remains editable");
    for(NSNumber *deadline in @[@(NAN),@(-1),@(LBXLicenseIPCClock()-1),@(LBXLicenseIPCClock()+30)])Check(![allocation ensureClosedAllocationForConfiguration:other beforeDeadline:deadline.doubleValue error:&error],@"invalid expired/excessive absolute deadline refused");
    mode=@"revoked";Check([License(owner,@"validate")[@"result"] isEqual:@"revoked"],@"real signed revocation fixture");
    Check(!Ensure(allocation,other,&error),@"revocation denies even exact allocated retry");Authorize(owner);
    NSString *lockPath=[path stringByAppendingPathComponent:@"allocation.lock"];int lock=open(lockPath.fileSystemRepresentation,O_RDWR);Check(lock>=0&&!flock(lock,LOCK_EX|LOCK_NB),@"independent file description owns actual allocation lock");
    double start=LBXLicenseIPCClock();Check(![allocation ensureClosedAllocationForConfiguration:other beforeDeadline:start+.04 error:&error]&&LBXLicenseIPCClock()-start<.5,@"lock wait consumes deadline without effects");flock(lock,LOCK_UN);close(lock);Authorize(owner);
    NSString *orphan=[[path stringByAppendingPathComponent:@"resources"] stringByAppendingPathComponent:NSUUID.UUID.UUIDString.lowercaseString];mkdir(orphan.fileSystemRepresentation,0700);
    Check(!Ensure(allocation,other,&error),@"untracked resource namespace blocks allocation inventory");rmdir(orphan.fileSystemRepresentation);Authorize(owner);
    NSString *unknown=[[path stringByAppendingPathComponent:@"journals"] stringByAppendingPathComponent:@"pending-unknown"];[@"orphan" writeToFile:unknown atomically:NO encoding:NSUTF8StringEncoding error:nil];chmod(unknown.fileSystemRepresentation,0600);
    Check(!Ensure(allocation,other,&error),@"orphan journal stage is not silently ignored");unlink(unknown.fileSystemRepresentation);Authorize(owner);
    NSArray *boundaries=@[@"intent_committed",@"allocation_created",@"allocation_synced",@"allocation_bound_committed",@"data_intent_committed",@"data_created",@"data_synced",@"data_bound_committed",@"groups_intent_committed",@"groups_created",@"groups_synced",@"resources_bound_committed",@"closing_committed",@"directories_closed",@"closed_committed"];
    NSSet *unbound=[NSSet setWithArray:@[@"allocation_created",@"allocation_synced",@"data_created",@"data_synced",@"groups_created",@"groups_synced"]];
    NSUInteger fixture=0;
    for(NSString *boundary in boundaries){
        Authorize(owner);LBXContainerConfiguration *record=NewConfiguration(store);NSString *root=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"interruption-%lu",(unsigned long)fixture++]];
        LBXContainerClosedAllocation *instance=[LBXContainerClosedAllocation openDirectory:root configurationStore:store licenseOwner:owner create:YES error:nil];[instance testStopAfterBoundary:boundary];
        Check(!Ensure(instance,record,&error),@"failure-only seam interrupts exact journal/effect boundary");NSDictionary *pending=Read(Journal(root,record));NSDictionary *spec=pending[@"identitySpecification"];NSData *priorBytes=[NSData dataWithContentsOfFile:Journal(root,record)];
        Check(spec!=nil&&[pending[@"configuration"] isEqual:record.privateDictionary],@"every interrupted effect has preceding exact intent and identity reservation");
        if([boundary isEqual:@"intent_committed"]){
            Authorize(owner);NSMutableDictionary *duplicate=[record.privateDictionary mutableCopy];duplicate[@"identifier"]=NSUUID.UUID.UUIDString.lowercaseString;
            LBXContainerConfiguration *reserved=[LBXContainerConfiguration fromDictionary:duplicate error:nil];Check([store commitConfiguration:reserved replacing:nil beforeDeadline:LBXLicenseIPCClock()+3 error:nil],@"pending-reservation alias fixture saved");
            Check(!Ensure(instance,reserved,&error)&&error.code==2&&[[NSData dataWithContentsOfFile:Journal(root,record)] isEqual:priorBytes]&&![NSFileManager.defaultManager fileExistsAtPath:Journal(root,reserved)],@"valid pending intent reserves identifiers before any resource exists");
        }
        Authorize(owner);LBXContainerClosedAllocation *reopened=[LBXContainerClosedAllocation openDirectory:root configurationStore:store licenseOwner:owner create:NO error:nil];
        NSDictionary *recovered=[reopened recoverClosedAllocationForConfiguration:record beforeDeadline:LBXLicenseIPCClock()+3 error:&error];
        if([unbound containsObject:boundary]){Check(!recovered&&[[NSData dataWithContentsOfFile:Journal(root,record)] isEqual:priorBytes],@"post-create unbound node is preserved and not silently adopted/replaced");
            Authorize(owner);NSMutableDictionary *duplicate=[record.privateDictionary mutableCopy];duplicate[@"identifier"]=NSUUID.UUID.UUIDString.lowercaseString;LBXContainerConfiguration *reserved=[LBXContainerConfiguration fromDictionary:duplicate error:nil];
            Check([store commitConfiguration:reserved replacing:nil beforeDeadline:LBXLicenseIPCClock()+3 error:nil]&&!Ensure(reopened,reserved,&error)&&![NSFileManager.defaultManager fileExistsAtPath:Journal(root,reserved)],@"pending journal cannot be evaded with a new configuration UUID");
        }else {Check(recovered&&[recovered[@"identitySpecification"] isEqual:spec],@"only proven absent/assigned nodes resume with exact original captured specification");if(recovered)Inspect(recovered,root,record);}
    }
    Authorize(owner);LBXContainerConfiguration *safeRecord=NewConfiguration(store);NSString *safeRoot=[base stringByAppendingPathComponent:@"unsafe-cases"];
    LBXContainerClosedAllocation *safeAllocation=[LBXContainerClosedAllocation openDirectory:safeRoot configurationStore:store licenseOwner:owner create:YES error:nil];NSDictionary *safeResult=Ensure(safeAllocation,safeRecord,&error);Check(safeResult!=nil,@"unsafe-counterexample baseline allocated");
    NSString *safeJournal=Journal(safeRoot,safeRecord);NSData *safeBytes=[NSData dataWithContentsOfFile:safeJournal];NSString *safeLeaf=Leaf(safeRoot,safeRecord),*data=[safeLeaf stringByAppendingPathComponent:@"data"],*moved=[base stringByAppendingPathComponent:@"held-data"];
    rename(data.fileSystemRepresentation,moved.fileSystemRepresentation);mkdir(data.fileSystemRepresentation,0700);Check(!Ensure(safeAllocation,safeRecord,&error),@"assigned node replacement never becomes a new binding");rmdir(data.fileSystemRepresentation);rename(moved.fileSystemRepresentation,data.fileSystemRepresentation);Authorize(owner);
    rename(data.fileSystemRepresentation,moved.fileSystemRepresentation);symlink(moved.fileSystemRepresentation,data.fileSystemRepresentation);Check(!Ensure(safeAllocation,safeRecord,&error),@"resource symlink refuses without adopting target");unlink(data.fileSystemRepresentation);rename(moved.fileSystemRepresentation,data.fileSystemRepresentation);Authorize(owner);
    chmod(data.fileSystemRepresentation,0755);Check(!Ensure(safeAllocation,safeRecord,&error),@"public resource permissions refuse instead of silently repaired");chmod(data.fileSystemRepresentation,0700);Authorize(owner);
    for(NSString *role in @[@"data",@"groups"]){NSString *extra=[[safeLeaf stringByAppendingPathComponent:role] stringByAppendingPathComponent:@"unknown-child"];
        [@"unknown private bytes" writeToFile:extra atomically:NO encoding:NSUTF8StringEncoding error:nil];chmod(extra.fileSystemRepresentation,0600);
        Check(!Ensure(safeAllocation,safeRecord,&error)&&[NSFileManager.defaultManager fileExistsAtPath:extra]&&[[NSData dataWithContentsOfFile:safeJournal] isEqual:safeBytes],@"unknown nested resource nodes block exact retry without cleanup or rewrite");unlink(extra.fileSystemRepresentation);Authorize(owner);
    }
    Check(SetACL(data,YES),@"Darwin qualifier/ACL construction on host succeeds");
    Check(!Ensure(safeAllocation,safeRecord,&error)&&[[NSData dataWithContentsOfFile:safeJournal] isEqual:safeBytes],@"ACL-bearing resource refuses without modifying the original binding");
    Check(SetACL(data,NO),@"host fixture removes only its added ACL");Authorize(owner);
    NSString *hard=[base stringByAppendingPathComponent:@"journal-hardlink"];link(safeJournal.fileSystemRepresentation,hard.fileSystemRepresentation);Check(!Ensure(safeAllocation,safeRecord,&error),@"hard-linked journal is unavailable");unlink(hard.fileSystemRepresentation);Authorize(owner);
    chmod(safeJournal.fileSystemRepresentation,0644);Check(!Ensure(safeAllocation,safeRecord,&error),@"public-readable private journal is unavailable");chmod(safeJournal.fileSystemRepresentation,0600);Authorize(owner);
    NSString *heldJournal=[base stringByAppendingPathComponent:@"held-journal"];rename(safeJournal.fileSystemRepresentation,heldJournal.fileSystemRepresentation);symlink(heldJournal.fileSystemRepresentation,safeJournal.fileSystemRepresentation);
    Check(!Ensure(safeAllocation,safeRecord,&error)&&[[NSData dataWithContentsOfFile:heldJournal] isEqual:safeBytes],@"journal symlink cannot be adopted or overwritten");unlink(safeJournal.fileSystemRepresentation);rename(heldJournal.fileSystemRepresentation,safeJournal.fileSystemRepresentation);Authorize(owner);
    chmod(base.fileSystemRepresentation,0777);Check(!Ensure(safeAllocation,safeRecord,&error)&&[[NSData dataWithContentsOfFile:safeJournal] isEqual:safeBytes],@"writable held ancestor blocks even exact closed retry");chmod(base.fileSystemRepresentation,0700);Authorize(owner);
    Check(SetACL(base,YES),@"host ACL-bearing ancestor fixture created");Check(!Ensure(safeAllocation,safeRecord,&error),@"held ancestor ACL blocks mutation without repair");Check(SetACL(base,NO),@"host fixture removes its ancestor ACL");Authorize(owner);
    NSMutableDictionary *malformed=[Read(safeJournal) mutableCopy];malformed[@"runtimeAccepted"]=@1;Write(safeJournal,malformed);Check(!Ensure(safeAllocation,safeRecord,&error),@"integer Boolean journal corruption cannot authorize repair");[safeBytes writeToFile:safeJournal atomically:NO];chmod(safeJournal.fileSystemRepresentation,0600);Authorize(owner);
    NSString *backupLock=[base stringByAppendingPathComponent:@"saved-allocation-lock"],*safeLock=[safeRoot stringByAppendingPathComponent:@"allocation.lock"];rename(safeLock.fileSystemRepresentation,backupLock.fileSystemRepresentation);
    Check(![LBXContainerClosedAllocation openDirectory:safeRoot configurationStore:store licenseOwner:owner create:YES error:nil]&&!Ensure(safeAllocation,safeRecord,&error),@"existing missing lock is not recreated");rename(backupLock.fileSystemRepresentation,safeLock.fileSystemRepresentation);Authorize(owner);
    NSString *rootBackup=[base stringByAppendingPathComponent:@"held-allocation-root"];rename(safeRoot.fileSystemRepresentation,rootBackup.fileSystemRepresentation);mkdir(safeRoot.fileSystemRepresentation,0700);Check(!Ensure(safeAllocation,safeRecord,&error),@"held root descriptor does not authorize replacement namespace");rmdir(safeRoot.fileSystemRepresentation);rename(rootBackup.fileSystemRepresentation,safeRoot.fileSystemRepresentation);Authorize(owner);
    Check(Ensure(safeAllocation,safeRecord,&error)!=nil&&[[NSData dataWithContentsOfFile:safeJournal] isEqual:safeBytes],@"rejected counterexamples preserve original closed identity/node journal bytes");
    for(NSNumber *replaceRoot in @[@NO,@YES]){
        Authorize(owner);LBXContainerConfiguration *record=NewConfiguration(store);NSString *root=[base stringByAppendingPathComponent:[replaceRoot boolValue]?@"inflight-root":@"inflight-lock"];
        LBXContainerClosedAllocation *instance=[LBXContainerClosedAllocation openDirectory:root configurationStore:store licenseOwner:owner create:YES error:nil];
        NSString *target=[replaceRoot boolValue]?root:[root stringByAppendingPathComponent:@"allocation.lock"],*backup=[base stringByAppendingPathComponent:[replaceRoot boolValue]?@"inflight-root-held":@"inflight-lock-held"];
        __block BOOL armed=NO,replaced=NO;
        [owner testUseAuthorizationClock:^double(BOOL continuous){
            if(!continuous&&armed&&!replaced&&[Read(Journal(root,record))[@"phase"] isEqual:@"intent"]){
                if(!rename(target.fileSystemRepresentation,backup.fileSystemRepresentation)){
                    if([replaceRoot boolValue])replaced=mkdir(target.fileSystemRepresentation,0700)==0;
                    else {int fd=open(target.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600);replaced=fd>=0;if(fd>=0)close(fd);}
                }
            }
            return continuous?Continuous():NSDate.date.timeIntervalSince1970;
        }];
        Authorize(owner);armed=YES;Check(!Ensure(instance,record,&error)&&replaced,@"held lock/ancestor substitution interrupts the in-flight source operation");armed=NO;
        NSString *heldRoot=[replaceRoot boolValue]?backup:root;NSDictionary *intent=Read(Journal(heldRoot,record));
        Check([intent[@"phase"] isEqual:@"intent"]&&![NSFileManager.defaultManager fileExistsAtPath:Leaf(heldRoot,record)],@"held lock/ancestor replacement permits no next mkdir or phase publication");
        if([replaceRoot boolValue])rmdir(target.fileSystemRepresentation);else unlink(target.fileSystemRepresentation);rename(backup.fileSystemRepresentation,target.fileSystemRepresentation);
        [owner testUseAuthorizationClock:^double(BOOL continuous){return continuous?Continuous():NSDate.date.timeIntervalSince1970;}];Authorize(owner);
        Check(Ensure(instance,record,&error)!=nil,@"restoring the exact original pinned lock/ancestor allows licensed intent recovery");
    }
    Authorize(owner);LBXContainerConfiguration *postCreate=NewConfiguration(store);NSString *postRoot=[base stringByAppendingPathComponent:@"post-create-unsafe"];
    LBXContainerClosedAllocation *post=[LBXContainerClosedAllocation openDirectory:postRoot configurationStore:store licenseOwner:owner create:YES error:nil];[post testStopAfterBoundary:@"allocation_created"];
    Check(!Ensure(post,postCreate,&error),@"interruption leaves an explicitly unbound created node");NSString *postLeaf=Leaf(postRoot,postCreate);chmod(postLeaf.fileSystemRepresentation,0755);struct stat publicBefore,publicAfter;lstat(postLeaf.fileSystemRepresentation,&publicBefore);
    [post testStopAfterBoundary:nil];Authorize(owner);Check(!Ensure(post,postCreate,&error)&&!lstat(postLeaf.fileSystemRepresentation,&publicAfter)&&publicBefore.st_ino==publicAfter.st_ino&&(publicAfter.st_mode&07777)==0755,@"unexpected post-create public node is neither repaired nor rebound");
    ReservationBoundaryTests(store,owner,vault,base,storePath);
    IndependentStoreRaces(store,owner,base,storePath);
    Check(requests>=1,@"actual transport/vault/signature path was used by the fixture");[LBXContainerIdentitySpecification testUsePhysicalContext:nil];
    [NSFileManager.defaultManager removeItemAtPath:base error:nil];NSLog(@"%@: %lu closed allocation checks, %lu failures",failures?@"FAIL":@"PASS",(unsigned long)checks,(unsigned long)failures);return failures?1:0;
}}
