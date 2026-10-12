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
#include <math.h>
#include <mach/mach_time.h>
#include <errno.h>

static NSUInteger checks,failures,requests;
static NSString *mode=@"active";
static void Check(BOOL good,NSString *why){checks++;if(!good){failures++;fprintf(stderr,"FAIL: %s\n",why.UTF8String);}}
@interface ConfigurationProtocol:NSURLProtocol @end
@implementation ConfigurationProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request{(void)request;return YES;}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request{return request;}
- (void)stopLoading{}
- (void)startLoading {
    requests++;NSData *body=self.request.HTTPBody;
    if(!body&&self.request.HTTPBodyStream){NSInputStream *stream=self.request.HTTPBodyStream;[stream open];NSMutableData *data=[NSMutableData data];uint8_t buffer[1024];NSInteger n;while((n=[stream read:buffer maxLength:sizeof(buffer)])>0)[data appendBytes:buffer length:(NSUInteger)n];[stream close];body=data;}
    NSDictionary *request=[NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    NSMutableDictionary *claims=TestLicenseClaims(@"AAAA-BBBB-CCCC-DDDD",request[@"nonce"],NSDate.date.timeIntervalSince1970);
    claims[@"iss"]=@"https://redditspoof.vercel.app";claims[@"deviceBinding"]=[RBXLicenseToken fingerprint:request[@"deviceIdentity"]];claims[@"status"]=mode;
    NSDictionary *reply=@{@"licenseToken":TestLicenseJWT(claims,nil),@"deviceId":@"fixture-device",@"token":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0]};
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil]];[self.client URLProtocolDidFinishLoading:self];
}
@end
static LBXLicenseOwner *NewOwner(LBXLicenseVault *vault){LBXLicenseOwner *owner=[[LBXLicenseOwner alloc] initWithVault:vault];[owner testUseProtocol:ConfigurationProtocol.class publicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];return owner;}
static NSDictionary *Send(LBXLicenseOwner *owner,NSString *operation){
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSDictionary *reply;
    [owner handleRequest:LBXLicenseIPCRequest(operation,[operation isEqual:@"activate"]?@"AAAA-BBBB-CCCC-DDDD":nil) completion:^(NSDictionary *value){reply=value;dispatch_semaphore_signal(done);}];
    Check(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)),@"bounded signed owner reply");return reply;
}
static void Authorize(LBXLicenseOwner *owner){mode=@"active";Check([Send(owner,@"validate")[@"result"] isEqual:@"active"]&&[owner sourceAuthorizationCurrent],@"fresh signed admission for store write");}
static BOOL Save(LBXContainerConfigurationStore *store,LBXContainerConfiguration *candidate,LBXContainerConfiguration *prior){return [store commitConfiguration:candidate replacing:prior beforeDeadline:LBXLicenseIPCClock()+2 error:nil];}
static NSString *RecordPath(NSString *store,LBXContainerConfiguration *record){return [store stringByAppendingPathComponent:[record.identifier stringByAppendingString:@".json"]];}
static NSDictionary *ReadDisk(NSString *file){NSData *data=[NSData dataWithContentsOfFile:file];return data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;}
static BOOL WriteDisk(NSString *file,id record){NSData *data=[record isKindOfClass:NSData.class]?record:[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];return data&&[data writeToFile:file atomically:NO]&&!chmod(file.fileSystemRepresentation,0600);}
static NSMutableDictionary *ReplaceDisk(NSDictionary *record,NSString *key,id value){NSMutableDictionary *copy=[record mutableCopy];if(value)copy[key]=value;else[copy removeObjectForKey:key];return copy;}
static BOOL Reserve(LBXContainerConfigurationStore *store,LBXLicenseOwner *owner,LBXContainerConfiguration *record,NSError **error){double deadline=LBXLicenseIPCClock()+2;return [owner performSourceOperation:^BOOL(NSError **operationError){return [store reserveConfigurationForClosedAllocation:record beforeDeadline:deadline error:operationError];} beforeDeadline:deadline error:error];}
static LBXContainerConfiguration *Fresh(LBXContainerConfigurationStore *store){LBXContainerConfiguration *record=[LBXContainerConfiguration createWithName:@"Reservation private fixture" applications:@[@"com.burbn.instagram"] manualIdentifiers:nil proxyReference:nil error:nil];Check(record&&Save(store,record,nil),@"genuine unallocated source record saved before reservation tests");return record;}
static double ContinuousClock(void){mach_timebase_info_data_t scale;mach_timebase_info(&scale);return (double)mach_continuous_time()*scale.numer/scale.denom/1e9;}
static void ReservationTests(LBXContainerConfigurationStore *store,LBXContainerConfigurationStore *peer,LBXLicenseOwner *owner,LBXLicenseVault *vault,NSString *path){
    Authorize(owner);peer=[LBXContainerConfigurationStore openDirectory:path licenseOwner:owner create:NO error:nil];Check(peer!=nil,@"reservation fixture has independent store bound to exact current owner");LBXContainerConfiguration *record=Fresh(store);NSString *file=RecordPath(path,record);NSDictionary *disk=ReadDisk(file);
    Check(disk.count==3&&[disk[@"storageVersion"] isEqual:@1]&&[disk[@"configuration"] isEqual:record.privateDictionary]&&CFGetTypeID((__bridge CFTypeRef)disk[@"allocationReserved"])==CFBooleanGetTypeID()&&![disk[@"allocationReserved"] boolValue],@"normal persistence uses exact versioned envelope and Boolean false reservation");
    NSData *initial=[NSData dataWithContentsOfFile:file];NSError *error=nil;double deadline=LBXLicenseIPCClock()+2;
    Check(![owner sourceOperationCurrentBeforeDeadline:deadline],@"live signed admission alone is not same-operation authority");
    Check(![store reserveConfigurationForClosedAllocation:record beforeDeadline:deadline error:&error]&&error.code==4&&[[NSData dataWithContentsOfFile:file] isEqual:initial],@"root-local reservation outside synchronous owner fence is denied without writes");
    __block BOOL exact=NO,foreign=YES,mismatch=YES;LBXLicenseOwner *different=NewOwner(vault);
    Check([owner performSourceOperation:^BOOL(NSError **operationError){(void)operationError;exact=[owner sourceOperationCurrentBeforeDeadline:deadline];foreign=[different sourceOperationCurrentBeforeDeadline:deadline];mismatch=[owner sourceOperationCurrentBeforeDeadline:deadline+.01];return YES;} beforeDeadline:deadline error:&error]&&exact&&!foreign&&!mismatch,@"operation query binds exact owner queue and exact captured deadline");
    Check(!Reserve([LBXContainerConfigurationStore openDirectory:path licenseOwner:different create:NO error:nil],different,record,&error)&&[[NSData dataWithContentsOfFile:file] isEqual:initial],@"unlicensed independent owner cannot reserve existing record");
    deadline=LBXLicenseIPCClock()+.025;__block NSError *insideError=nil;__block BOOL late=YES;
    Check(![owner performSourceOperation:^BOOL(NSError **operationError){usleep(45000);late=[store reserveConfigurationForClosedAllocation:record beforeDeadline:deadline error:&insideError];if(operationError)*operationError=insideError;return late;} beforeDeadline:deadline error:&error]&&!late&&insideError.code==4&&[[NSData dataWithContentsOfFile:file] isEqual:initial],@"expired active operation cannot publish a reservation");Authorize(owner);
    LBXContainerConfiguration *newer=[record configurationByUpdatingName:@"Pre-reservation edit" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];Check(Save(peer,newer,record),@"all ordinary exact edits remain available before reservation");NSData *newerBytes=[NSData dataWithContentsOfFile:file];
    Check(!Reserve(store,owner,record,&error)&&error.code==2&&[[NSData dataWithContentsOfFile:file] isEqual:newerBytes]&&[ReadDisk(file)[@"allocationReserved"] isEqual:@NO],@"stale full-document reservation CAS neither freezes nor rewrites newer record");Authorize(owner);
    LBXContainerConfiguration *latest=[newer configurationByUpdatingName:@"Still editable after stale reserve" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];Check(Save(peer,latest,newer),@"failed stale reservation leaves newer record genuinely editable");
    Check(Reserve(store,owner,latest,&error)&&!error,@"same-owner current synchronous fence durably reserves exact latest record");NSData *reserved=[NSData dataWithContentsOfFile:file];struct stat before,after;lstat(file.fileSystemRepresentation,&before);
    Check([ReadDisk(file)[@"configuration"] isEqual:latest.privateDictionary]&&[ReadDisk(file)[@"allocationReserved"] isEqual:@YES],@"reservation changes only private envelope while preserving full source document");
    Check(Reserve(peer,owner,latest,&error)&&!lstat(file.fileSystemRepresentation,&after)&&before.st_ino==after.st_ino&&[[NSData dataWithContentsOfFile:file] isEqual:reserved],@"exact reservation retry confirms existing state without publication");
    double inspectionDeadline=LBXLicenseIPCClock()+2;
    Check([owner performSourceOperation:^BOOL(NSError **inspectionError){return [peer allocationReservationCurrentForConfiguration:latest beforeDeadline:inspectionDeadline error:inspectionError];} beforeDeadline:inspectionDeadline error:&error]&&[[NSData dataWithContentsOfFile:file] isEqual:reserved],@"read-only exact reservation assertion confirms true marker without refreeze or write");
    Check(![peer allocationReservationCurrentForConfiguration:latest beforeDeadline:inspectionDeadline error:&error]&&error.code==4&&[[NSData dataWithContentsOfFile:file] isEqual:reserved],@"read-only reservation assertion also requires exact owning live operation");
    NSMutableDictionary *manual=[latest.identifiers mutableCopy];manual[@"serialNumber"]=@"editabc12345";
    NSArray *edits=@[[latest configurationByUpdatingName:@"Denied name" applications:nil manualIdentifiers:nil proxyReference:nil error:nil],
        [latest configurationByUpdatingName:nil applications:@[@"com.facebook.Facebook"] manualIdentifiers:nil proxyReference:nil error:nil],
        [latest configurationByUpdatingName:nil applications:nil manualIdentifiers:manual proxyReference:nil error:nil],
        [latest configurationByUpdatingName:nil applications:nil manualIdentifiers:nil proxyReference:NSUUID.UUID.UUIDString.lowercaseString error:nil],
        [latest configurationByUpdatingName:nil applications:nil manualIdentifiers:nil proxyReference:nil error:nil]];
    for(LBXContainerConfiguration *candidate in edits){error=nil;Check(![peer commitConfiguration:candidate replacing:latest beforeDeadline:LBXLicenseIPCClock()+2 error:&error]&&error.code==2&&[[NSData dataWithContentsOfFile:file] isEqual:reserved],@"every metadata/revision edit of reserved record is refused across independent store with bytes unchanged");Authorize(owner);}
    LBXLicenseOwner *restart=NewOwner(vault);LBXContainerConfigurationStore *reopened=[LBXContainerConfigurationStore openDirectory:path licenseOwner:restart create:NO error:nil];Authorize(restart);
    Check([[[reopened configurationWithIdentifier:latest.identifier error:nil] privateDictionary] isEqual:latest.privateDictionary],@"reserved record remains a normal private read after owner/store restart");
    error=nil;Check(![reopened commitConfiguration:edits[0] replacing:latest beforeDeadline:LBXLicenseIPCClock()+2 error:&error]&&error.code==2&&[[NSData dataWithContentsOfFile:file] isEqual:reserved],@"reservation freeze survives real owner and store restart");Authorize(owner);

    LBXContainerConfiguration *legacy=Fresh(store);NSString *legacyFile=RecordPath(path,legacy);Check(WriteDisk(legacyFile,legacy.privateDictionary),@"genuine legacy bare source record fixture written");
    Check([[[peer configurationWithIdentifier:legacy.identifier error:nil] privateDictionary] isEqual:legacy.privateDictionary],@"legacy bare configuration remains readable and unallocated");
    NSData *legacyBytes=[NSData dataWithContentsOfFile:legacyFile];LBXContainerConfiguration *legacyEdit=[legacy configurationByUpdatingName:@"Legacy unknown allocation" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];
    Check([peer configurations:nil]!=nil&&!Save(peer,legacyEdit,legacy)&&[[NSData dataWithContentsOfFile:legacyFile] isEqual:legacyBytes],@"legacy flat records remain listable but unknown reservation prevents every ordinary edit");Authorize(owner);
    Check(Reserve(store,owner,legacy,&error)&&[ReadDisk(legacyFile)[@"allocationReserved"] isEqual:@YES]&&[ReadDisk(legacyFile)[@"configuration"] isEqual:legacy.privateDictionary],@"trusted exact reservation migrates legacy only to frozen true envelope");NSData *legacyReserved=[NSData dataWithContentsOfFile:legacyFile];
    Check(Reserve(peer,owner,legacy,&error)&&[[NSData dataWithContentsOfFile:legacyFile] isEqual:legacyReserved],@"legacy upgraded reservation retry never rewrites or thaws");

    LBXContainerConfiguration *valid=Fresh(store);NSString *validFile=RecordPath(path,valid);NSDictionary *envelope=ReadDisk(validFile);NSData *validBytes=[NSData dataWithContentsOfFile:validFile];
    NSMutableArray *malformed=[NSMutableArray array];for(NSString *key in envelope)[malformed addObject:ReplaceDisk(envelope,key,nil)];
    [malformed addObject:ReplaceDisk(envelope,@"unknown",@YES)];
    for(id version in @[@YES,@0,@2,@(-1),@"1",NSNull.null])[malformed addObject:ReplaceDisk(envelope,@"storageVersion",version)];
    NSString *encoded=[[NSString alloc] initWithData:validBytes encoding:NSUTF8StringEncoding];NSString *floatingVersion=[encoded stringByReplacingOccurrencesOfString:@"\"storageVersion\":1" withString:@"\"storageVersion\":1.0"];
    Check(![floatingVersion isEqual:encoded],@"raw JSON floating version fixture retains explicit decimal syntax instead of Foundation integer coercion");[malformed addObject:[floatingVersion dataUsingEncoding:NSUTF8StringEncoding]];
    for(id reservation in @[@0,@1,@"true",@"false",NSNull.null,@[],@{}])[malformed addObject:ReplaceDisk(envelope,@"allocationReserved",reservation)];
    for(id configuration in @[NSNull.null,@YES,@42,@[],@{},@"bad",ReplaceDisk(valid.privateDictionary,@"name",NSNull.null),ReplaceDisk(valid.privateDictionary,@"identifier",NSUUID.UUID.UUIDString.lowercaseString)])
        [malformed addObject:ReplaceDisk(envelope,@"configuration",configuration)];
    LBXContainerConfiguration *next=[valid configurationByUpdatingName:@"Corruption cannot thaw" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];
    for(id corrupt in malformed){Check(WriteDisk(validFile,corrupt),@"malformed strict envelope fixture genuinely replaces disk bytes");NSData *corruptBytes=[NSData dataWithContentsOfFile:validFile];BOOL absent=YES;error=nil;
        Check(![peer configurationWithIdentifier:valid.identifier absent:&absent error:&error]&&!absent&&error&&![peer configurations:nil],@"malformed envelope is unavailable rather than missing or readable legacy data");
        Check(!Reserve(store,owner,valid,&error)&&[[NSData dataWithContentsOfFile:validFile] isEqual:corruptBytes],@"malformed envelope cannot be reserved repaired or thawed");Authorize(owner);
        Check(!Save(peer,next,valid)&&[[NSData dataWithContentsOfFile:validFile] isEqual:corruptBytes],@"normal edit cannot overwrite malformed reservation state");Authorize(owner);
        Check([validBytes writeToFile:validFile atomically:NO]&&!chmod(validFile.fileSystemRepresentation,0600),@"test restores only its own original valid envelope after rejection");
    }
    Check(Save(peer,next,valid)&&[ReadDisk(validFile)[@"allocationReserved"] isEqual:@NO],@"strict malformed-envelope counterexamples leave restored valid record editable");
    LBXContainerConfiguration *lateRecord=Fresh(store);NSString *lateFile=RecordPath(path,lateRecord);double lateDeadline=LBXLicenseIPCClock()+.08;__block BOOL didReserve=NO;
    Check(![owner performSourceOperation:^BOOL(NSError **operationError){didReserve=[store reserveConfigurationForClosedAllocation:lateRecord beforeDeadline:lateDeadline error:operationError];if(didReserve)usleep(120000);return didReserve;} beforeDeadline:lateDeadline error:&error]&&didReserve&&error.code==3&&[ReadDisk(lateFile)[@"allocationReserved"] isEqual:@YES],@"failed final deadline after actual publication preserves durable reservation rather than thawing");
    NSData *lateBytes=[NSData dataWithContentsOfFile:lateFile];LBXLicenseOwner *lateRestart=NewOwner(vault);LBXContainerConfigurationStore *lateStore=[LBXContainerConfigurationStore openDirectory:path licenseOwner:lateRestart create:NO error:nil];Authorize(lateRestart);
    LBXContainerConfiguration *lateEdit=[lateRecord configurationByUpdatingName:@"Late publication cannot thaw" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];
    Check(!Save(lateStore,lateEdit,lateRecord)&&[[NSData dataWithContentsOfFile:lateFile] isEqual:lateBytes],@"reopened owner/store keeps deadline-failed published reservation frozen");Authorize(owner);
    LBXContainerConfiguration *lockRecord=Fresh(store);NSString *lockFile=RecordPath(path,lockRecord),*lockPath=[path stringByAppendingPathComponent:@"configuration.lock"],*held=[path.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"reservation-held-lock"];NSData *lockBytes=[NSData dataWithContentsOfFile:lockFile];
    __block BOOL armed=NO,replaced=NO;
    [owner testUseAuthorizationClock:^double(BOOL continuous){if(!continuous&&armed&&!replaced){int probe=open(lockPath.fileSystemRepresentation,O_RDWR|O_NOFOLLOW);if(probe>=0){int acquired=flock(probe,LOCK_EX|LOCK_NB);int savedErrno=errno;if(acquired==0)flock(probe,LOCK_UN);close(probe);if(acquired<0&&(savedErrno==EWOULDBLOCK||savedErrno==EAGAIN)&&!rename(lockPath.fileSystemRepresentation,held.fileSystemRepresentation)){int substitute=open(lockPath.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600);replaced=substitute>=0;if(substitute>=0)close(substitute);}}}return continuous?ContinuousClock():NSDate.date.timeIntervalSince1970;}];
    Authorize(owner);armed=YES;Check(!Reserve(store,owner,lockRecord,&error)&&replaced&&[[NSData dataWithContentsOfFile:lockFile] isEqual:lockBytes],@"real replacement of held configuration lock before publication denies reservation with exact record bytes unchanged");armed=NO;
    Check(![peer configurations:nil]&&!Reserve(peer,owner,lockRecord,&error),@"another already-open store cannot adopt replacement ownership lock");
    unlink(lockPath.fileSystemRepresentation);Check(!rename(held.fileSystemRepresentation,lockPath.fileSystemRepresentation),@"test restores exact original pinned configuration lock inode");
    [owner testUseAuthorizationClock:^double(BOOL continuous){return continuous?ContinuousClock():NSDate.date.timeIntervalSince1970;}];Authorize(owner);
    Check([[[peer configurationWithIdentifier:lockRecord.identifier error:nil] privateDictionary] isEqual:lockRecord.privateDictionary]&&Reserve(store,owner,lockRecord,&error),@"original pinned lock restoration allows explicit exact reservation recovery");
}
static void ActiveFenceTests(NSString *base,LBXLicenseOwner *owner,LBXLicenseVault *vault) {
    NSString *path=[base stringByAppendingPathComponent:@"active-foundations"];
    LBXContainerConfigurationStore *store=[LBXContainerConfigurationStore openDirectory:path licenseOwner:owner create:YES error:nil];
    LBXContainerConfiguration *candidate=[LBXContainerConfiguration createWithName:@"Active source fixture" applications:@[@"com.burbn.instagram"] manualIdentifiers:nil proxyReference:@"" error:nil];
    NSString *file=RecordPath(path,candidate);NSError *error=nil;double deadline=LBXLicenseIPCClock()+2;BOOL absent=YES;
    Check(store&&candidate,@"fresh real private namespace for active-source foundation checks");
    Check(![store commitConfiguration:candidate replacing:nil inCurrentSourceOperationBeforeDeadline:deadline error:&error]&&error.code==4&&!ReadDisk(file),@"active commit outside exact owner fence refuses every effect");
    Check(![store configurationWithIdentifier:candidate.identifier absent:&absent inCurrentSourceOperationBeforeDeadline:deadline error:&error]&&!absent&&error.code==4,@"active read outside fence never returns confirmed absence");
    Check(![store configurationsInCurrentSourceOperationBeforeDeadline:deadline error:&error]&&error.code==4,@"active inventory outside fence unavailable");
    Check(![store configurationNamespaceContextInCurrentSourceOperationBeforeDeadline:deadline error:&error]&&error.code==4,@"namespace identity is private to exact source operation");
    __block NSUInteger callbacks=0;Check(![store performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *context,__unused NSError **failure){callbacks++;return YES;} error:&error]&&error.code==4&&callbacks==0,@"outside-fence bootstrap has no callback or publication");
    Authorize(owner);__block NSDictionary *namespace=nil;__block BOOL missing=NO;deadline=LBXLicenseIPCClock()+2;
    Check([owner performSourceOperation:^BOOL(NSError **failure){
        namespace=[store configurationNamespaceContextInCurrentSourceOperationBeforeDeadline:deadline error:failure];
        Check(namespace.count==2&&[namespace[@"directory"] count]==5&&[namespace[@"lock"] count]==5,@"descriptor namespace exposes only bounded directory/lock identity facts");
        BOOL absentNow=NO;NSError *readError=nil;Check(![store configurationWithIdentifier:candidate.identifier absent:&absentNow inCurrentSourceOperationBeforeDeadline:deadline error:&readError]&&absentNow&&!readError,@"active exact read distinguishes verified missing record");missing=absentNow;
        Check([store configurationsInCurrentSourceOperationBeforeDeadline:deadline error:nil].count==0,@"active genuine empty inventory before mutation");
        return [store performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(NSDictionary *context,__unused NSError **bootstrapError){callbacks++;Check([context isEqual:namespace],@"pristine callback receives same pinned namespace context");return YES;} error:failure];
    } beforeDeadline:deadline error:&error]&&missing&&callbacks==1,@"held-empty initial callback succeeds only in same live licensed fence");
    __block BOOL immutable=NO;@try{[(NSMutableDictionary *)namespace[@"lock"] setObject:@1 forKey:@"inode"];}@catch(__unused NSException *exception){immutable=YES;}Check(immutable,@"namespace observation has immutable nested ownership");
    LBXLicenseOwner *foreign=NewOwner(vault);LBXContainerConfigurationStore *other=[LBXContainerConfigurationStore openDirectory:path licenseOwner:foreign create:NO error:nil];deadline=LBXLicenseIPCClock()+2;
    Check([owner performSourceOperation:^BOOL(__unused NSError **failure){
        NSError *denied=nil;Check(![other commitConfiguration:candidate replacing:nil inCurrentSourceOperationBeforeDeadline:deadline error:&denied]&&denied.code==4,@"different bound owner cannot borrow active commit authority");
        BOOL missingNow=YES;Check(![other configurationWithIdentifier:candidate.identifier absent:&missingNow inCurrentSourceOperationBeforeDeadline:deadline error:&denied]&&!missingNow&&denied.code==4,@"different owner cannot borrow active read/absence authority");
        Check(![other configurationsInCurrentSourceOperationBeforeDeadline:deadline error:nil]&&![other configurationNamespaceContextInCurrentSourceOperationBeforeDeadline:deadline error:nil],@"different owner cannot borrow inventory or namespace context");
        Check(![store commitConfiguration:candidate replacing:nil inCurrentSourceOperationBeforeDeadline:deadline+.01 error:&denied]&&denied.code==4,@"changed deadline cannot borrow commit fence");
        __block BOOL escaped=YES;dispatch_sync(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{escaped=[store commitConfiguration:candidate replacing:nil inCurrentSourceOperationBeforeDeadline:deadline error:nil];});Check(!escaped,@"already-active store authority cannot escape source queue");return YES;
    } beforeDeadline:deadline error:&error]&&!ReadDisk(file),@"wrong-context counterexamples leave candidate genuinely unsaved");
    deadline=LBXLicenseIPCClock()+2;Check([owner performSourceOperation:^BOOL(NSError **failure){return [store commitConfiguration:candidate replacing:nil inCurrentSourceOperationBeforeDeadline:deadline error:failure];} beforeDeadline:deadline error:&error],@"already-active exact create publishes without nested source fence");
    NSData *saved=[NSData dataWithContentsOfFile:file];deadline=LBXLicenseIPCClock()+2;
    Check([owner performSourceOperation:^BOOL(__unused NSError **failure){
        BOOL loadedAbsent=NO;LBXContainerConfiguration *loaded=[store configurationWithIdentifier:candidate.identifier absent:&loadedAbsent inCurrentSourceOperationBeforeDeadline:deadline error:nil];Check([loaded.privateDictionary isEqual:candidate.privateDictionary],@"active read returns exact saved random identifiers and complete candidate");
        Check([store configurationsInCurrentSourceOperationBeforeDeadline:deadline error:nil].count==1,@"active inventory returns immutable committed model");
        Check([[store configurationNamespaceContextInCurrentSourceOperationBeforeDeadline:deadline error:nil] isEqual:namespace],@"namespace facts remain stable across source record publication");return YES;
    } beforeDeadline:deadline error:&error],@"saved candidate can be reconciled inside same exact owner fence");
    deadline=LBXLicenseIPCClock()+2;Check(![owner performSourceOperation:^BOOL(NSError **failure){return [store commitConfiguration:candidate replacing:nil inCurrentSourceOperationBeforeDeadline:deadline error:failure];} beforeDeadline:deadline error:&error]&&error.code==2&&[[NSData dataWithContentsOfFile:file] isEqual:saved],@"active commit preserves strict duplicate CAS; reconciliation does not rewrite saved bytes");Authorize(owner);
    LBXContainerConfiguration *edit=[candidate configurationByUpdatingName:@"Active exact edit" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];deadline=LBXLicenseIPCClock()+2;
    Check([owner performSourceOperation:^BOOL(NSError **failure){return [store commitConfiguration:edit replacing:candidate inCurrentSourceOperationBeforeDeadline:deadline error:failure];} beforeDeadline:deadline error:&error]&&[ReadDisk(file)[@"configuration"] isEqual:edit.privateDictionary],@"active full-document exact update advances once retaining identifier values");
    saved=[NSData dataWithContentsOfFile:file];deadline=LBXLicenseIPCClock()+2;Check(![owner performSourceOperation:^BOOL(NSError **failure){return [store commitConfiguration:edit replacing:candidate inCurrentSourceOperationBeforeDeadline:deadline error:failure];} beforeDeadline:deadline error:&error]&&error.code==2&&[[NSData dataWithContentsOfFile:file] isEqual:saved],@"active stale update/retry cannot overwrite current complete envelope");Authorize(owner);
    Check(Reserve(store,owner,edit,&error),@"active fixture frozen through genuine current source reservation");saved=[NSData dataWithContentsOfFile:file];LBXContainerConfiguration *frozenEdit=[edit configurationByUpdatingName:@"Frozen cannot edit" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];deadline=LBXLicenseIPCClock()+2;
    Check(![owner performSourceOperation:^BOOL(NSError **failure){return [store commitConfiguration:frozenEdit replacing:edit inCurrentSourceOperationBeforeDeadline:deadline error:failure];} beforeDeadline:deadline error:&error]&&error.code==2&&[[NSData dataWithContentsOfFile:file] isEqual:saved],@"already-active commit respects durable all-field allocation freeze");Authorize(owner);
    callbacks=0;deadline=LBXLicenseIPCClock()+2;Check(![owner performSourceOperation:^BOOL(NSError **failure){return [store performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *context,__unused NSError **bootstrapError){callbacks++;return YES;} error:failure];} beforeDeadline:deadline error:&error]&&callbacks==0,@"existing configuration namespace cannot be adopted by initial pending bootstrap");Authorize(owner);
    for(NSString *kind in @[@"pending-stage",@"unknown",@"directory",@"fifo",@"symlink"]){
        NSString *emptyPath=[base stringByAppendingPathComponent:[@"bootstrap-" stringByAppendingString:kind]],*extra=[emptyPath stringByAppendingPathComponent:kind];LBXContainerConfigurationStore *empty=[LBXContainerConfigurationStore openDirectory:emptyPath licenseOwner:owner create:YES error:nil];
        if([kind isEqual:@"directory"])mkdir(extra.fileSystemRepresentation,0700);else if([kind isEqual:@"fifo"])mkfifo(extra.fileSystemRepresentation,0600);else if([kind isEqual:@"symlink"])symlink("configuration.lock",extra.fileSystemRepresentation);else WriteDisk(extra,@{});
        callbacks=0;deadline=LBXLicenseIPCClock()+2;Check(![owner performSourceOperation:^BOOL(NSError **failure){return [empty performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *context,__unused NSError **bootstrapError){callbacks++;return YES;} error:failure];} beforeDeadline:deadline error:&error]&&callbacks==0&&[NSFileManager.defaultManager fileExistsAtPath:extra],@"every non-lock inventory node blocks pristine bootstrap without inspection cleanup or adoption");Authorize(owner);
    }
    NSString *changedPath=[base stringByAppendingPathComponent:@"bootstrap-final-change"],*publication=[base stringByAppendingPathComponent:@"durable-bootstrap-publication"],*extra=[changedPath stringByAppendingPathComponent:@"pending-interruption"];
    LBXContainerConfigurationStore *changed=[LBXContainerConfigurationStore openDirectory:changedPath licenseOwner:owner create:YES error:nil];deadline=LBXLicenseIPCClock()+2;
    Check(![owner performSourceOperation:^BOOL(NSError **failure){return [changed performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *context,__unused NSError **bootstrapError){WriteDisk(publication,@{@"published":@YES});WriteDisk(extra,@{});return YES;} error:failure];} beforeDeadline:deadline error:&error]&&[NSFileManager.defaultManager fileExistsAtPath:publication]&&[NSFileManager.defaultManager fileExistsAtPath:extra],@"callback publication plus final namespace drift is failed without rollback or deletion");Authorize(owner);
    NSString *exceptionPath=[base stringByAppendingPathComponent:@"bootstrap-exception"];LBXContainerConfigurationStore *exceptionStore=[LBXContainerConfigurationStore openDirectory:exceptionPath licenseOwner:owner create:YES error:nil];deadline=LBXLicenseIPCClock()+2;
    Check(![owner performSourceOperation:^BOOL(NSError **failure){return [exceptionStore performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *context,__unused NSError **bootstrapError){[NSException raise:@"private fixture" format:@"private fixture"];return YES;} error:failure];} beforeDeadline:deadline error:&error],@"callback exception is caught by owner after releasing held configuration lock");Authorize(owner);deadline=LBXLicenseIPCClock()+2;
    Check([owner performSourceOperation:^BOOL(NSError **failure){return [exceptionStore performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *context,__unused NSError **bootstrapError){return YES;} error:failure];} beforeDeadline:deadline error:&error],@"exception does not strand flock for a later trusted pristine callback");
    LBXContainerConfiguration *late=[LBXContainerConfiguration createWithName:@"Durable final expiry" applications:@[@"com.burbn.instagram"] manualIdentifiers:nil proxyReference:@"" error:nil];NSString *lateFile=RecordPath(path,late);deadline=LBXLicenseIPCClock()+.08;__block BOOL published=NO;
    Check(![owner performSourceOperation:^BOOL(NSError **failure){published=[store commitConfiguration:late replacing:nil inCurrentSourceOperationBeforeDeadline:deadline error:failure];if(published)usleep(120000);return published;} beforeDeadline:deadline error:&error]&&published&&error.code==3&&[ReadDisk(lateFile)[@"configuration"] isEqual:late.privateDictionary],@"already-active commit followed by final deadline failure preserves exact durable candidate for reconciliation");Authorize(owner);
    NSString *emptyExpiryPath=[base stringByAppendingPathComponent:@"bootstrap-final-expiry"],*expiryPublication=[base stringByAppendingPathComponent:@"bootstrap-expiry-publication"];LBXContainerConfigurationStore *emptyExpiry=[LBXContainerConfigurationStore openDirectory:emptyExpiryPath licenseOwner:owner create:YES error:nil];deadline=LBXLicenseIPCClock()+.04;
    Check(![owner performSourceOperation:^BOOL(NSError **failure){return [emptyExpiry performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *context,__unused NSError **bootstrapError){WriteDisk(expiryPublication,@{});usleep(60000);return YES;} error:failure];} beforeDeadline:deadline error:&error]&&[NSFileManager.defaultManager fileExistsAtPath:expiryPublication],@"expired initial callback cannot report success or erase prior publication");Authorize(owner);
    deadline=LBXLicenseIPCClock()+.02;Check(![owner performSourceOperation:^BOOL(NSError **failure){usleep(35000);BOOL lateAbsent=YES;NSError *readError=nil;Check(![store configurationWithIdentifier:NSUUID.UUID.UUIDString.lowercaseString absent:&lateAbsent inCurrentSourceOperationBeforeDeadline:deadline error:&readError]&&!lateAbsent&&readError.code==4,@"expired active read does not grant missing-candidate retry proof");return [store commitConfiguration:frozenEdit replacing:edit inCurrentSourceOperationBeforeDeadline:deadline error:failure];} beforeDeadline:deadline error:&error],@"expired same-owner context cannot publish a new configuration");Authorize(owner);
}
static void ExactProofTests(NSString *base,LBXLicenseOwner *owner) {
    Authorize(owner);NSString *path=[base stringByAppendingPathComponent:@"exact-proof-foundations"],*lockPath=[path stringByAppendingPathComponent:@"configuration.lock"];
    LBXContainerConfigurationStore *store=[LBXContainerConfigurationStore openDirectory:path licenseOwner:owner create:YES error:nil];LBXContainerConfiguration *record=Fresh(store),*next=[record configurationByUpdatingName:@"Different proof document" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];NSString *file=RecordPath(path,record);NSData *bytes=[NSData dataWithContentsOfFile:file];NSError *error=nil;double deadline=LBXLicenseIPCClock()+3;__block NSUInteger callbacks=0;
    Check(![store isConfigurationEditable:record inCurrentSourceOperationBeforeDeadline:deadline error:&error]&&error.code==4,@"edit eligibility outside source fence conveys no mutable grant");Check(![store performWithExactConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *context,__unused NSError **failure){callbacks++;return YES;} error:&error]&&error.code==4&&callbacks==0,@"exact proof callback never runs outside same owner's live fence");
    Check([owner performSourceOperation:^BOOL(NSError **failure){return [store performWithExactConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(NSDictionary *context,__unused NSError **proofError){
        callbacks++;Check([[store configurationNamespaceContextInCurrentSourceOperationBeforeDeadline:deadline error:nil] isEqual:context],@"proof callback reuses exactly held namespace lock without recursive acquisition");
        Check([store isConfigurationEditable:record inCurrentSourceOperationBeforeDeadline:deadline error:nil],@"only exact same proof record is edit-eligible under held lock");NSError *denied=nil;
        Check(![store isConfigurationEditable:next inCurrentSourceOperationBeforeDeadline:deadline error:&denied]&&denied.code==4,@"different record cannot borrow held proof eligibility");
        Check(![store configurationNamespaceContextInCurrentSourceOperationBeforeDeadline:deadline+.01 error:&denied]&&denied.code==4,@"changed deadline cannot borrow scoped namespace observation");
        BOOL absent=YES;Check(![store configurationWithIdentifier:record.identifier absent:&absent inCurrentSourceOperationBeforeDeadline:deadline error:&denied]&&!absent&&denied.code==4,@"normal exact read is refused inside proof callback");
        Check(![store configurationsInCurrentSourceOperationBeforeDeadline:deadline error:&denied]&&denied.code==4,@"normal inventory is refused inside proof callback");
        Check(![store commitConfiguration:next replacing:record inCurrentSourceOperationBeforeDeadline:deadline error:&denied]&&denied.code==4,@"normal write cannot nest under proof lock");
        Check(![store reserveConfigurationForClosedAllocation:record beforeDeadline:deadline error:&denied]&&denied.code==4,@"reservation cannot nest under proof lock");
        Check(![store performWithExactConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *nested,__unused NSError **nestedError){return YES;} error:&denied]&&denied.code==4,@"nested proof callback refused without new lock or grant");
        Check(![store performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *nested,__unused NSError **nestedError){return YES;} error:&denied]&&denied.code==4,@"initial bootstrap cannot enter normal proof scope");
        int other=open(lockPath.fileSystemRepresentation,O_RDWR|O_NOFOLLOW);int acquired=other>=0?flock(other,LOCK_EX|LOCK_NB):0;int saved=errno;Check(other>=0&&acquired<0&&(saved==EWOULDBLOCK||saved==EAGAIN),@"actual independent descriptor proves configuration lock held during pending publication");if(other>=0){if(!acquired)flock(other,LOCK_UN);close(other);}
        __block BOOL escaped=YES;dispatch_sync(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{escaped=[store isConfigurationEditable:record inCurrentSourceOperationBeforeDeadline:deadline error:nil];});Check(!escaped,@"same-record proof eligibility cannot escape owning synchronous queue");return YES;
    } error:failure];} beforeDeadline:deadline error:&error]&&callbacks==1&&[[NSData dataWithContentsOfFile:file] isEqual:bytes],@"read-only exact proof completes without changing record or reservation");
    deadline=LBXLicenseIPCClock()+3;Check([owner performSourceOperation:^BOOL(__unused NSError **failure){return [store isConfigurationEditable:record inCurrentSourceOperationBeforeDeadline:deadline error:nil];} beforeDeadline:deadline error:&error],@"explicit unallocated exact record is eligible outside nested proof scope but inside owner fence");
    Check(Reserve(store,owner,record,&error),@"trusted actual durable freeze before known eligibility rejection");NSData *frozen=[NSData dataWithContentsOfFile:file];deadline=LBXLicenseIPCClock()+3;Check(![owner performSourceOperation:^BOOL(NSError **failure){return [store isConfigurationEditable:record inCurrentSourceOperationBeforeDeadline:deadline error:failure];} beforeDeadline:deadline error:&error]&&error.code==2&&[[NSData dataWithContentsOfFile:file] isEqual:frozen],@"reserved record conflicts before staging and is never rewritten");Authorize(owner);deadline=LBXLicenseIPCClock()+3;
    Check([owner performSourceOperation:^BOOL(NSError **failure){return [store performWithExactConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *context,__unused NSError **proofError){NSError *denied=nil;Check(![store isConfigurationEditable:record inCurrentSourceOperationBeforeDeadline:deadline error:&denied]&&denied.code==2,@"same held exact frozen proof is readable but never edit-eligible");return YES;} error:failure];} beforeDeadline:deadline error:&error],@"saved exact proof may reconcile frozen metadata without providing edit/runtime grant");
    LBXContainerConfiguration *legacy=Fresh(store);NSString *legacyFile=RecordPath(path,legacy);WriteDisk(legacyFile,legacy.privateDictionary);NSData *legacyBytes=[NSData dataWithContentsOfFile:legacyFile];deadline=LBXLicenseIPCClock()+3;
    Check(![owner performSourceOperation:^BOOL(NSError **failure){return [store isConfigurationEditable:legacy inCurrentSourceOperationBeforeDeadline:deadline error:failure];} beforeDeadline:deadline error:&error]&&error.code==2&&[[NSData dataWithContentsOfFile:legacyFile] isEqual:legacyBytes],@"legacy UNKNOWN reservation conflicts before staging without implicit conversion");Authorize(owner);
    LBXContainerConfiguration *changed=Fresh(store),*foreign=[changed configurationByUpdatingName:@"Actual unexpected root edit" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];NSString *changedFile=RecordPath(path,changed),*publication=[base stringByAppendingPathComponent:@"proof-effect"];deadline=LBXLicenseIPCClock()+3;
    Check(![owner performSourceOperation:^BOOL(NSError **failure){return [store performWithExactConfiguration:changed inCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *context,__unused NSError **proofError){WriteDisk(publication,@{});WriteDisk(changedFile,@{@"storageVersion":@1,@"configuration":foreign.privateDictionary,@"allocationReserved":@NO});return YES;} error:failure];} beforeDeadline:deadline error:&error]&&error.code==2&&[NSFileManager.defaultManager fileExistsAtPath:publication]&&[ReadDisk(changedFile)[@"configuration"] isEqual:foreign.privateDictionary],@"full envelope drift after callback denies success without rolling back prior effects or repairing outside writer");Authorize(owner);
    deadline=LBXLicenseIPCClock()+3;Check(![owner performSourceOperation:^BOOL(NSError **failure){return [store performWithExactConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *context,__unused NSError **proofError){[NSException raise:@"private proof fixture" format:@"private proof fixture"];return YES;} error:failure];} beforeDeadline:deadline error:&error],@"proof callback exception releases exact held lock and scoped reentry authority");Authorize(owner);deadline=LBXLicenseIPCClock()+3;Check([owner performSourceOperation:^BOOL(NSError **failure){return [store performWithExactConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *context,__unused NSError **proofError){return YES;} error:failure];} beforeDeadline:deadline error:&error],@"later exact proof succeeds after exception with no stranded lock");
    deadline=LBXLicenseIPCClock()+.04;Check(![owner performSourceOperation:^BOOL(NSError **failure){return [store performWithExactConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(__unused NSDictionary *context,__unused NSError **proofError){WriteDisk(publication,@{@"second":@YES});usleep(60000);return YES;} error:failure];} beforeDeadline:deadline error:&error]&&[ReadDisk(publication)[@"second"] isEqual:@YES]&&[[NSData dataWithContentsOfFile:file] isEqual:frozen],@"expired exact proof after callback publication fails with durable effect and frozen record preserved");Authorize(owner);
}
int main(void){@autoreleasepool {
    char temporary[]="/tmp/socialbox-configuration-store.XXXXXX";Check(mkdtemp(temporary)!=NULL,@"private fixture parent");
    NSString *base=[NSString stringWithUTF8String:temporary],*path=[base stringByAppendingPathComponent:@"configurations"];
    LBXLicenseVault *vault=[LBXLicenseVault openDirectory:[base stringByAppendingPathComponent:@"license"] error:nil];[vault testUsePublicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];
    LBXLicenseOwner *owner=NewOwner(vault);
    Check(![LBXContainerConfigurationStore openDirectory:path licenseOwner:owner create:NO error:nil]&&![NSFileManager.defaultManager fileExistsAtPath:path],@"open-only never creates missing storage");
    LBXContainerConfigurationStore *store=[LBXContainerConfigurationStore openDirectory:path licenseOwner:owner create:YES error:nil];
    Check(store!=nil&&[store configurations:nil].count==0,@"explicit private first-install setup is empty");
    BOOL absent=NO;NSError *readError=nil;
    Check(![store configurationWithIdentifier:NSUUID.UUID.UUIDString.lowercaseString absent:&absent error:&readError]&&absent&&!readError,@"exact absence is distinct from unavailable storage");
    absent=YES;Check(![store configurationWithIdentifier:@"../outside" absent:&absent error:&readError]&&!absent&&readError.code==3,@"invalid identifier cannot become confirmed absence");
    Check([store usesLicenseOwner:owner]&&![store usesLicenseOwner:NewOwner(vault)],@"store assembly binds its exact source owner");
    struct stat node;Check(!lstat(path.fileSystemRepresentation,&node)&&(node.st_mode&0777)==0700,@"configuration directory private mode");
    NSString *lockPath=[path stringByAppendingPathComponent:@"configuration.lock"];
    Check(!lstat(lockPath.fileSystemRepresentation,&node)&&(node.st_mode&0777)==0600,@"configuration lock private mode");
    LBXContainerConfiguration *original=[LBXContainerConfiguration createWithName:@"Private fixture name" applications:@[@"com.burbn.instagram"] manualIdentifiers:nil proxyReference:NSUUID.UUID.UUIDString.lowercaseString error:nil];
    NSString *file=RecordPath(path,original);NSUInteger before=requests;
    Check(!Save(store,original,nil)&&![NSFileManager.defaultManager fileExistsAtPath:file]&&requests==before,@"unlicensed creation has zero record writes and no implicit network");
    Check([Send(owner,@"activate")[@"result"] isEqual:@"active"],@"actual signed fixture activation before storage effects");
    Check(Save(store,original,nil),@"licensed source configuration creation persists");
    Check(!lstat(file.fileSystemRepresentation,&node)&&(node.st_mode&0777)==0600&&node.st_nlink==1,@"record private mode and single link");
    Check([[[store configurationWithIdentifier:original.identifier error:nil] privateDictionary] isEqual:original.privateDictionary],@"saved generated identifiers round-trip exactly");
    LBXContainerConfigurationStore *peer=[LBXContainerConfigurationStore openDirectory:path licenseOwner:owner create:NO error:nil];
    Check([[[peer configurations:nil].firstObject privateDictionary] isEqual:original.privateDictionary],@"another store instance reopens the same durable configuration");
    LBXContainerConfiguration *edited=[original configurationByUpdatingName:@"Changed fixture" applications:@[@"com.atebits.Tweetie2",@"com.facebook.Facebook",@"com.burbn.instagram"] manualIdentifiers:nil proxyReference:@"" error:nil];
    Check(Save(peer,edited,original),@"exact-CAS edit stores three requested apps and clears proxy reference");
    Check([edited.identifiers isEqual:original.identifiers]&&edited.proxyReference.length==0&&edited.revision==2,@"edit retains randomized identifiers and advances once");
    NSData *saved=[NSData dataWithContentsOfFile:file];
    Check(!Save(store,edited,original)&&[[NSData dataWithContentsOfFile:file] isEqual:saved],@"stale competing edit cannot overwrite current bytes");
    Authorize(owner);Check(!Save(store,original,nil)&&[[NSData dataWithContentsOfFile:file] isEqual:saved],@"initial ID cannot replace an existing record");
    Authorize(owner);
    NSMutableDictionary *sameRevision=[edited.privateDictionary mutableCopy];sameRevision[@"name"]=@"Different same-revision bytes";
    LBXContainerConfiguration *wrongExpected=[LBXContainerConfiguration fromDictionary:sameRevision error:nil];
    LBXContainerConfiguration *next=[edited configurationByUpdatingName:@"Third version" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];
    Check(!Save(store,next,wrongExpected)&&[[NSData dataWithContentsOfFile:file] isEqual:saved],@"CAS compares complete prior record beyond revision number");
    Authorize(owner);Check(Save(store,next,edited),@"current exact prior record can edit after conflict revalidation");
    edited=next;saved=[NSData dataWithContentsOfFile:file];
    LBXLicenseOwner *restarted=NewOwner(vault);LBXContainerConfigurationStore *afterRestart=[LBXContainerConfigurationStore openDirectory:path licenseOwner:restarted create:NO error:nil];
    next=[edited configurationByUpdatingName:@"Denied restart" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];
    Check(!Save(afterRestart,next,edited)&&[[NSData dataWithContentsOfFile:file] isEqual:saved],@"restarted owner retains records but has no cached grant");
    Authorize(restarted);Check(Save(afterRestart,next,edited),@"revalidated owner can edit its retained configuration");
    owner=restarted;store=afterRestart;edited=next;saved=[NSData dataWithContentsOfFile:file];
    mode=@"revoked";Check([Send(owner,@"validate")[@"result"] isEqual:@"revoked"],@"real signed revocation reaches owner");
    next=[edited configurationByUpdatingName:@"Denied revocation" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];
    Check(!Save(store,next,edited)&&[[NSData dataWithContentsOfFile:file] isEqual:saved],@"signed revocation blocks publication and preserves prior record");
    Authorize(owner);
    for(NSNumber *deadline in @[@(NAN),@(-1),@(LBXLicenseIPCClock()-1),@(LBXLicenseIPCClock()+30)])Check(![store commitConfiguration:next replacing:edited beforeDeadline:deadline.doubleValue error:nil]&&[[NSData dataWithContentsOfFile:file] isEqual:saved],@"invalid expired or excessive deadline cannot publish");
    int lock=open(lockPath.fileSystemRepresentation,O_RDWR);Check(lock>=0&&!flock(lock,LOCK_EX|LOCK_NB),@"independent file description holds actual store lock");
    double start=LBXLicenseIPCClock();Check(![store commitConfiguration:next replacing:edited beforeDeadline:start+.04 error:nil]&&LBXLicenseIPCClock()-start<.5&&[[NSData dataWithContentsOfFile:file] isEqual:saved],@"lock wait consumes caller deadline without late write");
    flock(lock,LOCK_UN);close(lock);Authorize(owner);
    NSString *safe=[base stringByAppendingPathComponent:@"saved-record"];Check(!rename(file.fileSystemRepresentation,safe.fileSystemRepresentation)&&!symlink(safe.fileSystemRepresentation,file.fileSystemRepresentation),@"record symlink counterexample established");
    Check(![store configurationWithIdentifier:edited.identifier error:nil]&&![store configurations:nil],@"symlink record makes read and inventory unavailable");
    absent=YES;readError=nil;Check(![store configurationWithIdentifier:edited.identifier absent:&absent error:&readError]&&!absent&&readError,@"unsafe symlink is never reported missing");
    Check(!Save(store,next,edited)&&[[NSData dataWithContentsOfFile:safe] isEqual:saved],@"symlink cannot be replaced as a missing record");
    unlink(file.fileSystemRepresentation);rename(safe.fileSystemRepresentation,file.fileSystemRepresentation);Authorize(owner);
    NSString *hard=[base stringByAppendingPathComponent:@"hardlink"];Check(!link(file.fileSystemRepresentation,hard.fileSystemRepresentation),@"record hardlink established");
    Check(![store configurationWithIdentifier:edited.identifier error:nil]&&!Save(store,next,edited),@"multi-link record read and write refused");unlink(hard.fileSystemRepresentation);Authorize(owner);
    chmod(file.fileSystemRepresentation,0644);Check(![store configurations:nil]&&!Save(store,next,edited),@"public-readable private record refused");chmod(file.fileSystemRepresentation,0600);Authorize(owner);
    [@"{invalid-json" writeToFile:file atomically:NO encoding:NSUTF8StringEncoding error:nil];
    Check(![store configurations:nil]&&!Save(store,next,edited),@"corrupt prior record never repaired by a normal save");
    absent=YES;readError=nil;Check(![store configurationWithIdentifier:edited.identifier absent:&absent error:&readError]&&!absent&&readError,@"corrupt JSON is never reported missing");
    [saved writeToFile:file atomically:NO];chmod(file.fileSystemRepresentation,0600);Authorize(owner);
    NSString *movedLock=[base stringByAppendingPathComponent:@"saved-lock"];rename(lockPath.fileSystemRepresentation,movedLock.fileSystemRepresentation);
    Check(![LBXContainerConfigurationStore openDirectory:path licenseOwner:owner create:YES error:nil]&&!Save(store,next,edited),@"missing ownership lock cannot be silently recreated");
    rename(movedLock.fileSystemRepresentation,lockPath.fileSystemRepresentation);Authorize(owner);
    NSString *moved=[base stringByAppendingPathComponent:@"moved-store"];Check(!rename(path.fileSystemRepresentation,moved.fileSystemRepresentation)&&!mkdir(path.fileSystemRepresentation,0700),@"directory replacement counterexample established");
    Check(![store configurations:nil]&&!Save(store,next,edited)&&[[NSData dataWithContentsOfFile:RecordPath(moved,edited)] isEqual:saved],@"held directory inode cannot write after leaf replacement");
    absent=YES;readError=nil;Check(![store configurationWithIdentifier:NSUUID.UUID.UUIDString.lowercaseString absent:&absent error:&readError]&&!absent&&readError,@"replaced directory cannot manufacture confirmed absence");
    rmdir(path.fileSystemRepresentation);rename(moved.fileSystemRepresentation,path.fileSystemRepresentation);Authorize(owner);
    NSString *pending=[path stringByAppendingPathComponent:[@"pending-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString]];
    [@"unfinished private stage" writeToFile:pending atomically:NO encoding:NSUTF8StringEncoding error:nil];chmod(pending.fileSystemRepresentation,0600);
    Check([store configurations:nil].count==1,@"interrupted staging file never enters committed inventory");
    Check(Save(store,next,edited)&&[[store configurationWithIdentifier:edited.identifier error:nil].identifiers isEqual:original.identifiers],@"healthy current state survives all rejected experiments");
    NSMutableDictionary *manual=[original.identifiers mutableCopy];manual[@"serialNumber"]=@"manualabc123";manual[@"wifiMac"]=@"02:ab:cd:ef:01:23";manual[@"idfv"]=NSUUID.UUID.UUIDString.lowercaseString;
    LBXContainerConfiguration *manualEdit=[next configurationByUpdatingName:nil applications:@[@"com.facebook.Facebook"] manualIdentifiers:manual proxyReference:NSUUID.UUID.UUIDString.lowercaseString error:nil];
    Check(manualEdit!=nil&&Save(store,manualEdit,next),@"complete manually selected identifiers persist under the same stable configuration ID");
    LBXContainerConfiguration *loaded=[peer configurationWithIdentifier:manualEdit.identifier error:nil];
    Check([loaded.identifiers isEqual:manual]&&[loaded.identifierMode isEqual:@"manual"]&&[loaded.proxyReference isEqual:manualEdit.proxyReference],@"manual values and assigned proxy reference round-trip exactly");
    LBXContainerConfiguration *manualRename=[loaded configurationByUpdatingName:@"Retained manual identity" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];
    Check(Save(store,manualRename,loaded)&&[[store configurationWithIdentifier:manualRename.identifier error:nil].identifiers isEqual:manual],@"later rename retains every manual identifier without regeneration");
    ReservationTests(store,peer,owner,vault,path);
    ActiveFenceTests(base,owner,vault);
    ExactProofTests(base,owner);
    for(NSString *secret in @[original.name,original.identifier,original.proxyReference,original.identifiers[@"idfv"]])Check(![store.description containsString:secret]&&![[store debugDescription] containsString:secret],@"store descriptions exclude private values");
    before=requests;[store configurations:nil];Check(requests==before,@"reading metadata performs no licensing network operation");
    [NSFileManager.defaultManager removeItemAtPath:base error:nil];
    NSLog(@"%@: %lu configuration store assertions, %lu failures",failures?@"FAIL":@"PASS",(unsigned long)checks,(unsigned long)failures);return failures?1:0;
}}
