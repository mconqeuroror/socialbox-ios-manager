#import "../Containers/LBXContainerOwner.h"
#import "../Containers/LBXContainerIPC.h"
#import "../Containers/LBXContainerConfiguration.h"
#import "../Containers/LBXContainerConfigurationStore.h"
#import "../Authorization/LBXLicenseOwner.h"
#import "../Authorization/LBXLicenseVault.h"
#import "../Authorization/LBXLicenseIPC.h"
#import "../../tests/RBXLicenseTestSupport.h"
#include <sys/stat.h>
#include <unistd.h>

static NSUInteger checks,failures,networkRequests;
static NSString *mode=@"active";
static void Check(BOOL good,NSString *why){checks++;if(!good){failures++;fprintf(stderr,"FAIL: %s\n",why.UTF8String);}}
@interface ContainerProtocol:NSURLProtocol @end
@implementation ContainerProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request{(void)request;return YES;}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request{return request;}
- (void)stopLoading{}
- (void)startLoading {
    networkRequests++;NSData *body=self.request.HTTPBody;
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
static LBXLicenseOwner *NewLicenseOwner(LBXLicenseVault *vault){LBXLicenseOwner *owner=[[LBXLicenseOwner alloc] initWithVault:vault];[owner testUseProtocol:ContainerProtocol.class publicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];return owner;}
static NSDictionary *License(LBXLicenseOwner *owner,NSString *operation){
    __block NSDictionary *reply;dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [owner handleRequest:LBXLicenseIPCRequest(operation,[operation isEqual:@"activate"]?@"AAAA-BBBB-CCCC-DDDD":nil) completion:^(NSDictionary *value){reply=value;dispatch_semaphore_signal(done);}];
    Check(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)),@"bounded signed owner request");return reply;
}
static NSDictionary *Send(LBXContainerOwner *owner,NSDictionary *request,BOOL validate){
    __block NSDictionary *reply;__block NSUInteger replies=0;dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [owner handleRequest:request completion:^(NSDictionary *value){reply=value;replies++;dispatch_semaphore_signal(done);}];
    Check(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))&&replies==1,@"one bounded configuration owner completion");
    if(validate)Check(LBXContainerIPCValidateReply(reply,request,LBXContainerIPCClock()),@"actual owner result validates against exact request context");return reply;
}
static NSDictionary *Operation(LBXContainerOwner *owner,NSString *operation,NSDictionary *arguments){NSDictionary *request=LBXContainerIPCRequest(operation,arguments);Check(request!=nil,@"valid typed request fixture");return Send(owner,request,YES);}
static NSDictionary *Choices(NSString *name,id identifiers){return @{@"name":name,@"applications":@[@"com.burbn.instagram"],@"manualIdentifiers":identifiers?:NSNull.null,@"proxyReference":@""};}
static void Authorize(LBXLicenseOwner *owner){mode=@"active";Check([License(owner,@"validate")[@"result"] isEqual:@"active"],@"signed revalidation restores owner after conservative conflict");}
static BOOL Reserve(LBXContainerConfigurationStore *store,LBXLicenseOwner *owner,LBXContainerConfiguration *record){double deadline=LBXLicenseIPCClock()+2;return [owner performSourceOperation:^BOOL(NSError **error){return [store reserveConfigurationForClosedAllocation:record beforeDeadline:deadline error:error];} beforeDeadline:deadline error:nil];}
static void ReservationOwnerTests(LBXContainerOwner *owner,LBXContainerConfigurationStore *store,LBXLicenseOwner *license,LBXLicenseVault *vault,NSString *path,LBXContainerConfiguration *prior,LBXContainerConfiguration *edited){
    Check(Reserve(store,license,edited),@"root exact operation reserves the actually saved typed-update candidate");NSString *editedFile=[path stringByAppendingPathComponent:[edited.identifier stringByAppendingString:@".json"]];NSData *editedBytes=[NSData dataWithContentsOfFile:editedFile];struct stat before,after;lstat(editedFile.fileSystemRepresentation,&before);
    NSDictionary *reply=Operation(owner,@"update",@{@"expected":prior.privateDictionary,@"configuration":edited.privateDictionary});lstat(editedFile.fileSystemRepresentation,&after);
    Check([reply[@"result"] isEqual:@"saved"]&&before.st_ino==after.st_ino&&[[NSData dataWithContentsOfFile:editedFile] isEqual:editedBytes],@"frozen exact already-published edit retry is still confirmed without new write");
    LBXContainerConfiguration *denied=[edited configurationByUpdatingName:@"Reserved newer metadata" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];reply=Operation(owner,@"update",@{@"expected":edited.privateDictionary,@"configuration":denied.privateDictionary});
    Check([reply[@"result"] isEqual:@"conflict"]&&reply[@"configuration"]==NSNull.null&&[[NSData dataWithContentsOfFile:editedFile] isEqual:editedBytes],@"consumer projects frozen update as safe conflict with no private error or publication");Authorize(license);
    NSDictionary *prepared=Operation(owner,@"prepare",@{@"choices":Choices(@"Frozen creation fixture",nil)})[@"configuration"];reply=Operation(owner,@"create",@{@"configuration":prepared});Check([reply[@"result"] isEqual:@"saved"],@"genuine typed initial create exists before freeze");
    LBXContainerConfiguration *record=[LBXContainerConfiguration fromDictionary:prepared error:nil];NSString *file=[path stringByAppendingPathComponent:[record.identifier stringByAppendingString:@".json"]];Check(Reserve(store,license,record),@"trusted root local reserve freezes revision-one owner record");NSData *bytes=[NSData dataWithContentsOfFile:file];lstat(file.fileSystemRepresentation,&before);
    reply=Operation(owner,@"create",@{@"configuration":prepared});lstat(file.fileSystemRepresentation,&after);Check([reply[@"result"] isEqual:@"saved"]&&before.st_ino==after.st_ino&&[[NSData dataWithContentsOfFile:file] isEqual:bytes],@"frozen exact create retry remains same confirmed UUID/revision and inode");
    reply=Operation(owner,@"read",@{@"identifier":record.identifier});Check([reply[@"result"] isEqual:@"record"]&&[reply[@"configuration"] isEqual:prepared]&&!reply[@"configuration"][@"allocationReserved"]&&!reply[@"configuration"][@"storageVersion"]&&[reply[@"runtimeAccepted"] isEqual:@NO],@"frozen read exposes unchanged private configuration without storage marker or runtime grant");
    LBXLicenseOwner *restart=NewLicenseOwner(vault);LBXContainerConfigurationStore *reopened=[LBXContainerConfigurationStore openDirectory:path licenseOwner:restart create:NO error:nil];LBXContainerOwner *reopenedOwner=[[LBXContainerOwner alloc] initWithLicenseOwner:restart store:reopened];
    reply=Operation(reopenedOwner,@"create",@{@"configuration":prepared});Check([reply[@"result"] isEqual:@"authorization_required"]&&[[NSData dataWithContentsOfFile:file] isEqual:bytes],@"restart does not turn persisted reservation into reusable authorization");Authorize(restart);
    reply=Operation(reopenedOwner,@"create",@{@"configuration":prepared});Check([reply[@"result"] isEqual:@"saved"]&&[[NSData dataWithContentsOfFile:file] isEqual:bytes],@"freshly revalidated restarted owner confirms exact reserved create");
    denied=[record configurationByUpdatingName:@"Restart cannot thaw" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];reply=Operation(reopenedOwner,@"update",@{@"expected":record.privateDictionary,@"configuration":denied.privateDictionary});Check([reply[@"result"] isEqual:@"conflict"]&&[[NSData dataWithContentsOfFile:file] isEqual:bytes],@"restarted metadata consumer cannot publish a new frozen revision");Authorize(restart);
    NSMutableDictionary *malformed=[[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] mutableCopy];malformed[@"allocationReserved"]=@1;NSData *bad=[NSJSONSerialization dataWithJSONObject:malformed options:0 error:nil];Check([bad writeToFile:file atomically:NO]&&!chmod(file.fileSystemRepresentation,0600),@"actual integer reservation-marker corruption fixture written");
    reply=Operation(reopenedOwner,@"read",@{@"identifier":record.identifier});Check([reply[@"result"] isEqual:@"storage_unavailable"]&&reply[@"configuration"]==NSNull.null&&[[NSData dataWithContentsOfFile:file] isEqual:bad],@"unsafe reservation marker projects storage failure without exposing or repairing raw bytes");
    Check([bytes writeToFile:file atomically:NO]&&!chmod(file.fileSystemRepresentation,0600),@"test restores only its exact original reserved envelope");Authorize(license);
}
int main(void){@autoreleasepool {
    char temporary[]="/tmp/socialbox-container-owner.XXXXXX";Check(mkdtemp(temporary)!=NULL,@"private owner fixture parent");NSString *base=[NSString stringWithUTF8String:temporary],*path=[base stringByAppendingPathComponent:@"configurations"];
    LBXLicenseVault *vault=[LBXLicenseVault openDirectory:[base stringByAppendingPathComponent:@"license"] error:nil];[vault testUsePublicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];
    LBXLicenseOwner *license=NewLicenseOwner(vault);LBXContainerConfigurationStore *store=[LBXContainerConfigurationStore openDirectory:path licenseOwner:license create:YES error:nil];
    LBXContainerOwner *owner=[[LBXContainerOwner alloc] initWithLicenseOwner:license store:store];Check(owner!=nil,@"owner assembled with matching live licensing/store binding");
    Check(![[LBXContainerOwner alloc] initWithLicenseOwner:NewLicenseOwner(vault) store:store],@"different owner/store binding rejected");
    NSUInteger calls=networkRequests;NSDictionary *reply=Operation(owner,@"prepare",@{@"choices":Choices(@"Private fixture",nil)});
    Check([reply[@"result"] isEqual:@"authorization_required"]&&[store configurations:nil].count==0&&networkRequests==calls,@"unlicensed prepare reveals no generated identifiers and has no implicit network/writes");
    Check([License(license,@"activate")[@"result"] isEqual:@"active"],@"signed transport and durable commit open source consumer");
    NSMutableDictionary *invalid=[LBXContainerIPCRequest(@"prepare",@{@"choices":Choices(@"Invalid fixture",nil)}) mutableCopy];invalid[@"path"]=@"/private/outside";
    reply=Send(owner,invalid,NO);Check([reply[@"result"] isEqual:@"invalid_request"]&&[store configurations:nil].count==0,@"caller path/extra fields rejected before consumer work");
    reply=Operation(owner,@"prepare",@{@"choices":Choices(@"Private fixture",nil)});NSDictionary *prepared=reply[@"configuration"];
    Check([reply[@"result"] isEqual:@"prepared"]&&[prepared[@"identifierMode"] isEqual:@"random"]&&[store configurations:nil].count==0,@"prepare returns an immutable random preview without publication");
    NSString *identifier=prepared[@"identifier"],*file=[path stringByAppendingPathComponent:[identifier stringByAppendingString:@".json"]];
    reply=Operation(owner,@"read",@{@"identifier":identifier});Check([reply[@"result"] isEqual:@"missing"],@"verified file absence is projected only for read");
    reply=Operation(owner,@"create",@{@"configuration":prepared});Check([reply[@"result"] isEqual:@"saved"]&&[reply[@"configuration"] isEqual:prepared]&&[store configurations:nil].count==1,@"create publishes exact preview under live licensing");
    NSData *saved=[NSData dataWithContentsOfFile:file];struct stat before,after;lstat(file.fileSystemRepresentation,&before);
    reply=Operation(owner,@"create",@{@"configuration":prepared});lstat(file.fileSystemRepresentation,&after);
    Check([reply[@"result"] isEqual:@"saved"]&&[[NSData dataWithContentsOfFile:file] isEqual:saved]&&before.st_ino==after.st_ino&&[store configurations:nil].count==1,@"lost create reply retry confirms same UUID/bytes/revision without a second publication");
    NSMutableDictionary *collision=[prepared mutableCopy];collision[@"name"]=@"Conflicting initial record";
    reply=Operation(owner,@"create",@{@"configuration":collision});Check([reply[@"result"] isEqual:@"conflict"]&&[[NSData dataWithContentsOfFile:file] isEqual:saved],@"different initial bytes cannot replace an existing creation UUID");
    LBXContainerConfiguration *record=[LBXContainerConfiguration fromDictionary:prepared error:nil];NSMutableDictionary *manual=[record.identifiers mutableCopy];manual[@"serialNumber"]=@"manualabc123";manual[@"idfv"]=NSUUID.UUID.UUIDString.lowercaseString;
    LBXContainerConfiguration *edit=[record configurationByUpdatingName:@"Manual saved fixture" applications:@[@"com.burbn.instagram",@"com.facebook.Facebook",@"com.atebits.Tweetie2"] manualIdentifiers:manual proxyReference:NSUUID.UUID.UUIDString.lowercaseString error:nil];
    reply=Operation(owner,@"update",@{@"expected":record.privateDictionary,@"configuration":edit.privateDictionary});Check([reply[@"result"] isEqual:@"saved"],@"typed update persists manual values and three requested app memberships");
    saved=[NSData dataWithContentsOfFile:file];lstat(file.fileSystemRepresentation,&before);
    reply=Operation(owner,@"update",@{@"expected":record.privateDictionary,@"configuration":edit.privateDictionary});lstat(file.fileSystemRepresentation,&after);
    Check([reply[@"result"] isEqual:@"saved"]&&before.st_ino==after.st_ino&&[[NSData dataWithContentsOfFile:file] isEqual:saved],@"lost edit reply retry confirms already-persisted exact candidate without new revision");
    LBXContainerConfiguration *stale=[record configurationByUpdatingName:@"Stale different edit" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];
    reply=Operation(owner,@"update",@{@"expected":record.privateDictionary,@"configuration":stale.privateDictionary});Check([reply[@"result"] isEqual:@"conflict"]&&[[NSData dataWithContentsOfFile:file] isEqual:saved],@"stale competing update refuses without touching committed bytes");
    reply=Operation(owner,@"read",@{@"identifier":identifier});Check([reply[@"configuration"] isEqual:edit.privateDictionary],@"typed private read retains all manual identifiers and proxy reference");
    LBXLicenseOwner *restarted=NewLicenseOwner(vault);LBXContainerConfigurationStore *restartStore=[LBXContainerConfigurationStore openDirectory:path licenseOwner:restarted create:NO error:nil];LBXContainerOwner *restartOwner=[[LBXContainerOwner alloc] initWithLicenseOwner:restarted store:restartStore];
    reply=Operation(restartOwner,@"create",@{@"configuration":prepared});Check([reply[@"result"] isEqual:@"authorization_required"],@"restart requires fresh license even for idempotent saved-record lookup");
    Check([License(restarted,@"validate")[@"result"] isEqual:@"active"],@"restarted consumer validates retained genuine fixture pairing");
    reply=Operation(restartOwner,@"update",@{@"expected":record.privateDictionary,@"configuration":edit.privateDictionary});Check([reply[@"result"] isEqual:@"saved"]&&[[NSData dataWithContentsOfFile:file] isEqual:saved],@"durable exact edit retry works across owner restart after revalidation");
    owner=restartOwner;license=restarted;store=restartStore;
    ReservationOwnerTests(owner,store,license,vault,path,record,edit);
    saved=[NSData dataWithContentsOfFile:file];
    mode=@"revoked";Check([License(license,@"validate")[@"result"] isEqual:@"revoked"],@"actual signed revocation reaches shared consumer owner");
    reply=Operation(owner,@"read",@{@"identifier":identifier});Check([reply[@"result"] isEqual:@"authorization_required"]&&reply[@"configuration"]==NSNull.null,@"revoked owner returns no private saved identity");
    reply=Operation(owner,@"create",@{@"configuration":prepared});Check([reply[@"result"] isEqual:@"authorization_required"]&&[[NSData dataWithContentsOfFile:file] isEqual:saved],@"revoked create cannot publish or confirm private state");
    mode=@"active";Check([License(license,@"validate")[@"result"] isEqual:@"active"],@"fresh validation reopens source-only operations");
    NSString *backup=[base stringByAppendingPathComponent:@"saved-record"];rename(file.fileSystemRepresentation,backup.fileSystemRepresentation);symlink(backup.fileSystemRepresentation,file.fileSystemRepresentation);
    reply=Operation(owner,@"read",@{@"identifier":identifier});Check([reply[@"result"] isEqual:@"storage_unavailable"],@"unsafe record is unavailable rather than missing");
    unlink(file.fileSystemRepresentation);rename(backup.fileSystemRepresentation,file.fileSystemRepresentation);License(license,@"validate");
    calls=networkRequests;
    for(NSUInteger i=0;i<42;i++) {
        NSDictionary *document=[LBXContainerConfiguration createWithName:@"Pagination fixture" applications:@[@"com.burbn.instagram"] manualIdentifiers:nil proxyReference:nil error:nil].privateDictionary;
        reply=Operation(owner,@"create",@{@"configuration":document});Check([reply[@"result"] isEqual:@"saved"],@"real root publication prepares bounded pagination fixture");
    }
    reply=Operation(owner,@"list",@{@"after":@""});NSArray *first=reply[@"entries"];NSString *next=reply[@"next"];
    Check([reply[@"result"] isEqual:@"listed"]&&first.count==40&&[next isEqual:first.lastObject[@"identifier"]],@"first sorted page returns40 bounded projected records and cursor");
    NSUInteger total=[store configurations:nil].count;NSDictionary *second=Operation(owner,@"list",@{@"after":next});Check([second[@"result"] isEqual:@"listed"]&&[second[@"entries"] count]==total-40&&[second[@"next"] isEqual:@""],@"second page excludes first40 and ends after all actually saved records including frozen rows");
    for(NSDictionary *entry in first)Check(entry[@"identifiers"]==nil&&entry[@"proxyReference"]==nil,@"list excludes identifier values and proxy references");
    Check(networkRequests==calls,@"container reads and writes never trigger hidden licensing network operations");
    LBXContainerOwner *missingStore=[[LBXContainerOwner alloc] initWithLicenseOwner:license store:nil];reply=Operation(missingStore,@"list",@{@"after":@""});Check([reply[@"result"] isEqual:@"storage_unavailable"],@"lost store does not silently create new configuration storage");
    Check(![owner.description containsString:identifier]&&![owner.description containsString:@"manualabc123"],@"owner description excludes private record material");
    [NSFileManager.defaultManager removeItemAtPath:base error:nil];NSLog(@"%@: %lu container owner assertions, %lu failures",failures?@"FAIL":@"PASS",(unsigned long)checks,(unsigned long)failures);return failures?1:0;
}}
