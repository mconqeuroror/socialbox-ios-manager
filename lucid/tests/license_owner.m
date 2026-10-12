#import "../Authorization/LBXLicenseOwner.h"
#import "../Authorization/LBXLicenseVault.h"
#import "../Authorization/LBXLicenseIPC.h"
#import "../../tests/RBXLicenseTestSupport.h"
#include <sys/stat.h>
#include <unistd.h>
#include <math.h>
#include <fcntl.h>
#import "../Authorization/LBXLicenseEndpoints.h"

static NSUInteger checks,failures,requests;
static NSString *mode=@"active";
static NSString *const Key=@"AAAA-BBBB-CCCC-DDDD";
static NSString *Bearer(void){return [@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0];}
static void Check(BOOL value,NSString *why){checks++;if(!value){failures++;fprintf(stderr,"FAIL: %s\n",why.UTF8String);}}
static dispatch_semaphore_t held,releaseReply;
@interface OwnerProtocol:NSURLProtocol @end
@implementation OwnerProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request{(void)request;return YES;}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request{return request;}
- (void)stopLoading{}
- (void)startLoading {
    requests++;
    NSData *body=self.request.HTTPBody;
    if(!body&&self.request.HTTPBodyStream){
        NSInputStream *stream=self.request.HTTPBodyStream;[stream open];NSMutableData *bytes=[NSMutableData data];uint8_t buffer[1024];NSInteger n;
        while((n=[stream read:buffer maxLength:sizeof(buffer)])>0)[bytes appendBytes:buffer length:(NSUInteger)n];[stream close];body=bytes;
    }
    NSDictionary *request=[NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if([mode isEqual:@"hold"]||[mode isEqual:@"hold-revoked"]){dispatch_semaphore_signal(held);dispatch_semaphore_wait(releaseReply,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));}
    if([mode isEqual:@"network"]){[self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:-1009 userInfo:@{NSLocalizedDescriptionKey:@"private-server-text"}]];return;}
    NSMutableDictionary *claims=TestLicenseClaims(Key,request[@"nonce"],NSDate.date.timeIntervalSince1970);
    claims[@"iss"]=@"https://redditspoof.vercel.app";claims[@"deviceBinding"]=[RBXLicenseToken fingerprint:request[@"deviceIdentity"]];
    claims[@"status"]=[mode isEqual:@"revoked"]||[mode isEqual:@"hold-revoked"]?@"revoked":@"active";
    if([mode isEqual:@"short"]){claims[@"exp"]=@((long long)NSDate.date.timeIntervalSince1970+10);}
    if([mode isEqual:@"expired"]){claims[@"status"]=@"expired";}
    if([mode isEqual:@"elapsed"]){claims[@"iat"]=@((long long)NSDate.date.timeIntervalSince1970-10);claims[@"exp"]=@((long long)NSDate.date.timeIntervalSince1970-1);}
    if([mode isEqual:@"wrong-device"])claims[@"sub"]=@"foreign-device";
    BOOL claim=[self.request.URL.path isEqual:@"/api/devices/claim"];
    if(!claim)Check([[self.request valueForHTTPHeaderField:@"Authorization"] isEqual:[@"Bearer " stringByAppendingString:Bearer()]],@"paired call uses private bearer");
    NSDictionary *json=@{@"licenseToken":[mode isEqual:@"unsigned"]?@"unsigned":TestLicenseJWT(claims,nil),@"deviceId":@"fixture-device",@"token":Bearer()};
    NSData *response=[NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    NSHTTPURLResponse *http=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:[mode isEqual:@"conflict"]?409:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    [self.client URLProtocol:self didReceiveResponse:http cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:response];[self.client URLProtocolDidFinishLoading:self];
}
@end
static LBXLicenseOwner *Owner(LBXLicenseVault *vault){
    LBXLicenseOwner *owner=[[LBXLicenseOwner alloc] initWithVault:vault];
    [owner testUseProtocol:OwnerProtocol.class publicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];return owner;
}
static NSDictionary *Send(LBXLicenseOwner *owner,NSDictionary *request){
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSDictionary *result;__block NSUInteger replies=0;
    [owner handleRequest:request completion:^(NSDictionary *reply){result=reply;replies++;dispatch_semaphore_signal(done);}];
    Check(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0&&replies==1,@"one bounded owner reply");return result;
}
static NSDictionary *Observe(LBXLicenseOwner *owner) {
    __block NSDictionary *context=nil;double deadline=LBXLicenseIPCClock()+2;
    BOOL observed=[owner performSourceOperation:^BOOL(NSError **error){context=[owner sourcePairingContextBeforeDeadline:deadline error:error];return context!=nil;} beforeDeadline:deadline error:nil];
    return observed?context:nil;
}
static void PairingContextTests(NSString *base) {
    NSString *path=[base stringByAppendingPathComponent:@"foundation-vault"],*missing=[base stringByAppendingPathComponent:@"existing-missing"];
    Check(![LBXLicenseVault openExistingDirectory:missing error:nil]&&![NSFileManager.defaultManager fileExistsAtPath:missing],@"existing factory never creates absent vault leaf");
    NSString *partial=[base stringByAppendingPathComponent:@"existing-partial"];Check(!mkdir(partial.fileSystemRepresentation,0700),@"partial established vault fixture");
    Check(![LBXLicenseVault openExistingDirectory:partial error:nil]&&![LBXLicenseVault openDirectory:partial error:nil]&&![NSFileManager.defaultManager fileExistsAtPath:[partial stringByAppendingPathComponent:@"owner.lock"]],@"existing empty leaf is never adopted as pristine or given a new identity");
    LBXLicenseVault *vault=[LBXLicenseVault openDirectory:path error:nil];[vault testUsePublicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];
    LBXLicenseOwner *owner=Owner(vault);Check([owner usesVault:vault]&&![owner usesVault:[LBXLicenseVault openExistingDirectory:partial error:nil]],@"owner assembly binds exact vault instance");
    double deadline=LBXLicenseIPCClock()+2;NSError *error=nil;
    Check(![owner sourcePairingContextBeforeDeadline:deadline error:&error]&&error,@"unpaired/outside fence exposes no private pairing context");
    mode=@"active";Check([Send(owner,LBXLicenseIPCRequest(@"activate",Key))[@"result"] isEqual:@"active"],@"context fixture has real signed paired admission");
    Check(![owner sourcePairingContextBeforeDeadline:deadline error:nil]&&![vault pairingContextForSourceOwner:owner beforeDeadline:deadline error:nil],@"live admission alone exposes neither owner nor vault context");
    NSDictionary *first=Observe(owner),*configuration=[vault configuration:nil];
    Check(first&&first.count==8&&[first[@"formatVersion"] isEqual:@1]&&[first[@"server"] isEqual:configuration[@"server"]]&&[first[@"deviceIdentity"] isEqual:configuration[@"deviceIdentity"]]&&[first[@"deviceId"] isEqual:configuration[@"deviceId"]],@"context uses actual verified root pairing fields with exact bounded shape");
    Check([first[@"keyFingerprint"] isEqual:[RBXLicenseToken fingerprint:Key]]&&[first[@"bearerFingerprint"] isEqual:[RBXLicenseToken fingerprint:Bearer()]],@"private context contains cryptographic fingerprints instead of credentials");
    Check([first[@"client"] isEqual:@{@"path":@LBX_LICENSE_CLIENT_PATH,@"sha256":@LBX_LICENSE_CLIENT_SHA256,@"size":@(LBX_LICENSE_CLIENT_SIZE)}],@"private client policy is fixed compiled pin");
    Check(!first[@"revision"]&&!first[@"key"]&&!first[@"deviceToken"]&&!first[@"vault"][@"state"],@"stable context excludes revision credentials and replaceable state inode");
    for(NSString *part in @[@"directory",@"lock"])Check([first[@"vault"][part] count]==5&&[first[@"vault"][part][@"inode"] unsignedLongLongValue]>0,@"context binds complete stable descriptor metadata");
    __block BOOL immutable=NO;@try{[(NSMutableDictionary *)first[@"vault"] setObject:@{} forKey:@"directory"];}@catch(__unused NSException *exception){immutable=YES;}
    Check(immutable&&[Observe(owner) isEqual:first],@"nested returned pairing context is immutable and cannot change authority");
    NSString *record=[path stringByAppendingPathComponent:@"pairing.json"];struct stat before,after;lstat(record.fileSystemRepresentation,&before);
    Check([Send(owner,LBXLicenseIPCRequest(@"validate",nil))[@"result"] isEqual:@"active"],@"revalidation advances genuine signed vault generation");lstat(record.fileSystemRepresentation,&after);
    Check(![[vault configuration:nil][@"revision"] isEqual:configuration[@"revision"]]&&before.st_ino!=after.st_ino&&[Observe(owner) isEqual:first],@"stable context remains exact across changing revision and atomic state-file inode");
    LBXLicenseVault *reopened=[LBXLicenseVault openExistingDirectory:path error:nil];[reopened testUsePublicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];LBXLicenseOwner *restart=Owner(reopened);
    Check(reopened&&[Send(restart,LBXLicenseIPCRequest(@"validate",nil))[@"result"] isEqual:@"active"]&&[Observe(restart) isEqual:first],@"existing-only reopen and owner restart retain actual stable pairing context");
    Send(owner,LBXLicenseIPCRequest(@"validate",nil));deadline=LBXLicenseIPCClock()+2;
    Check([owner performSourceOperation:^BOOL(__unused NSError **failure){
        Check(![restart sourcePairingContextBeforeDeadline:deadline error:nil],@"different owner cannot borrow private context from active queue");
        Check(![vault pairingContextForSourceOwner:restart beforeDeadline:deadline error:nil],@"vault context requires same owning source fence");
        for(NSNumber *wrong in @[@(deadline-.01),@(deadline+.01),@(NAN),@(INFINITY)])Check(![owner sourcePairingContextBeforeDeadline:wrong.doubleValue error:nil],@"wrong deadline cannot observe stable pairing context");
        __block NSDictionary *escaped=nil;dispatch_sync(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{escaped=[owner sourcePairingContextBeforeDeadline:deadline error:nil];});
        Check(!escaped,@"private context observation cannot escape its source queue");return YES;
    } beforeDeadline:deadline error:nil],@"context rejection counterexamples do not silently mint authority");
    NSData *saved=[NSData dataWithContentsOfFile:record];NSMutableDictionary *changed=[[NSJSONSerialization JSONObjectWithData:saved options:0 error:nil] mutableCopy];changed[@"deviceId"]=@"changed-pairing";
    deadline=LBXLicenseIPCClock()+2;
    Check(![owner performSourceOperation:^BOOL(__unused NSError **failure){
        [[NSJSONSerialization dataWithJSONObject:changed options:0 error:nil] writeToFile:record atomically:NO];
        Check(![owner sourcePairingContextBeforeDeadline:deadline error:nil],@"changed signed pairing state is denied before context return");return YES;
    } beforeDeadline:deadline error:nil],@"actual pairing drift closes final source fence");
    Check([saved writeToFile:record atomically:NO]&&!chmod(record.fileSystemRepresentation,0600),@"restore exact private fixture pairing after denial");Send(owner,LBXLicenseIPCRequest(@"validate",nil));
    NSString *lock=[path stringByAppendingPathComponent:@"owner.lock"],*held=[base stringByAppendingPathComponent:@"held-foundation-lock"];deadline=LBXLicenseIPCClock()+2;
    Check(![owner performSourceOperation:^BOOL(__unused NSError **failure){
        Check(!rename(lock.fileSystemRepresentation,held.fileSystemRepresentation),@"replace actual pinned vault lock fixture");int substitute=open(lock.fileSystemRepresentation,O_CREAT|O_EXCL|O_WRONLY,0600);Check(substitute>=0,@"create different private lock inode");if(substitute>=0)close(substitute);
        Check(![owner sourcePairingContextBeforeDeadline:deadline error:nil]&&![vault configuration:nil],@"already-open vault does not adopt substituted ownership lock");return YES;
    } beforeDeadline:deadline error:nil],@"actual ownership lock replacement denies final source authority");
    unlink(lock.fileSystemRepresentation);Check(!rename(held.fileSystemRepresentation,lock.fileSystemRepresentation),@"restore exact original owner lock inode");Send(owner,LBXLicenseIPCRequest(@"validate",nil));Check([Observe(owner) isEqual:first],@"exact restored lock permits deliberate fixture recovery without new context");
    NSString *ancestor=[base stringByAppendingPathComponent:@"ancestor-fixture"];mkdir(ancestor.fileSystemRepresentation,0700);NSString *child=[ancestor stringByAppendingPathComponent:@"vault"];
    LBXLicenseVault *nested=[LBXLicenseVault openDirectory:child error:nil];[nested testUsePublicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];LBXLicenseOwner *nestedOwner=Owner(nested);Send(nestedOwner,LBXLicenseIPCRequest(@"activate",Key));
    NSDictionary *nestedContext=Observe(nestedOwner);NSString *moved=[base stringByAppendingPathComponent:@"ancestor-moved"];
    Check(nestedContext&& !rename(ancestor.fileSystemRepresentation,moved.fileSystemRepresentation)&&!mkdir(ancestor.fileSystemRepresentation,0700),@"physical ancestor replacement fixture preserves original tree");
    Check(![nested configuration:nil]&&!Observe(nestedOwner),@"replaced physical vault ancestor cannot be authorized through retained descriptor");rmdir(ancestor.fileSystemRepresentation);rename(moved.fileSystemRepresentation,ancestor.fileSystemRepresentation);
    Send(nestedOwner,LBXLicenseIPCRequest(@"validate",nil));Check([Observe(nestedOwner) isEqual:nestedContext],@"restored exact physical ancestry preserves context");
    deadline=LBXLicenseIPCClock()+.02;Check(![owner performSourceOperation:^BOOL(__unused NSError **failure){usleep(35000);Check(![owner sourcePairingContextBeforeDeadline:deadline error:nil],@"expired exact fence yields no context");return YES;} beforeDeadline:deadline error:nil],@"context observation cannot extend operation deadline");
    Check(![owner.description containsString:configuration[@"deviceIdentity"]]&&![vault.description containsString:Key],@"context authority never leaks through public descriptions");
    unlink(record.fileSystemRepresentation);Check(![LBXLicenseVault openExistingDirectory:path error:nil]&&! [NSFileManager.defaultManager fileExistsAtPath:record],@"existing-only factory preserves missing established identity for explicit recovery");
}
int main(void){@autoreleasepool{
    NSDictionary *request=LBXLicenseIPCRequest(@"activate",@" aaaa-bbbb-cccc-dddd\n");
    Check([request[@"key"] isEqual:Key]&&LBXLicenseIPCValidateRequest(request,LBXLicenseIPCClock()),@"canonical activation request");
    for(id extra in @[@YES,@"1",@1.5]){NSMutableDictionary *bad=[request mutableCopy];bad[@"version"]=extra;Check(!LBXLicenseIPCValidateRequest(bad,LBXLicenseIPCClock()),@"numeric protocol version only");}
    for(NSString *extra in @[@"server",@"deviceIdentity",@"deviceToken",@"receipt",@"path"]){NSMutableDictionary *bad=[request mutableCopy];bad[extra]=@"caller-value";Check(!LBXLicenseIPCValidateRequest(bad,LBXLicenseIPCClock()),@"no private configuration fields in IPC");}
    Check(!LBXLicenseIPCRequest(@"status",Key)&&!LBXLicenseIPCRequest(@"reset",nil)&&!LBXLicenseIPCRequest(@"activate",@"wrong"),@"closed operation set");
    Check(!LBXLicenseIPCValidateRequest(request,[request[@"deadline"] doubleValue]),@"expired request denied");
    Check(!LBXLicenseIPCValidateRequest(request,[request[@"deadline"] doubleValue]-26),@"unbounded request denied");
    NSDictionary *reply=LBXLicenseIPCReply(request,@"active",YES);
    Check(LBXLicenseIPCValidateReply(reply,request,LBXLicenseIPCClock()),@"matching bounded projection");
    Check(!LBXLicenseIPCValidateReply(LBXLicenseIPCReply(request,@"active",NO),request,LBXLicenseIPCClock()),@"active response requires committed pairing");
    for(NSString *field in @[@"key",@"deviceToken",@"licenseToken",@"message"]){NSMutableDictionary *bad=[reply mutableCopy];bad[field]=@"secret";Check(!LBXLicenseIPCValidateReply(bad,request,LBXLicenseIPCClock()),@"no extra server/credential fields in reply");}
    NSMutableDictionary *bad=[reply mutableCopy];bad[@"engineAuthorized"]=@YES;
    Check(!LBXLicenseIPCValidateReply(bad,request,LBXLicenseIPCClock()),@"IPC never claims retained engine admission");
    bad=[reply mutableCopy];bad[@"paired"]=@1;Check(!LBXLicenseIPCValidateReply(bad,request,LBXLicenseIPCClock()),@"paired must be JSON Boolean");
    bad=[reply mutableCopy];bad[@"requestID"]=NSUUID.UUID.UUIDString.lowercaseString;
    Check(!LBXLicenseIPCValidateReply(bad,request,LBXLicenseIPCClock()),@"foreign response denied");
    NSDictionary *status=LBXLicenseIPCRequest(@"status",nil);
    Check(!LBXLicenseIPCValidateReply(LBXLicenseIPCReply(status,@"active",YES),status,LBXLicenseIPCClock()),@"cached status cannot become online active assessment");
    char temporary[]="/tmp/socialbox-owner.XXXXXX";Check(mkdtemp(temporary)!=NULL,@"private fixture directory");
    NSString *base=[NSString stringWithUTF8String:temporary],*path=[base stringByAppendingPathComponent:@"vault"];
    LBXLicenseVault *vault=[LBXLicenseVault openDirectory:path error:nil];[vault testUsePublicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];
    LBXLicenseOwner *owner=Owner(vault);NSDictionary *initial=[vault configuration:nil];
    Check(![owner sourceAuthorizationCurrent],@"a new source owner starts closed");
    reply=Send(owner,status);Check([reply[@"result"] isEqual:@"unchecked"]&&requests==0,@"render/status causes no network or mutation");
    Check([[vault configuration:nil] isEqual:initial],@"status preserves durable generation");
    reply=Send(owner,LBXLicenseIPCRequest(@"validate",nil));Check([reply[@"result"] isEqual:@"activation_required"]&&requests==0,@"empty owner cannot validate");
    bad=[request mutableCopy];bad[@"deviceIdentity"]=@"attacker";
    reply=Send(owner,bad);Check([reply[@"result"] isEqual:@"invalid_request"]&&requests==0,@"invalid owner input cannot reach network");
    reply=Send(owner,(NSDictionary *)@[]);Check([reply[@"result"] isEqual:@"invalid_request"]&&requests==0,@"non-dictionary owner input cannot crash or reach network");
    reply=Send(owner,request);Check([reply[@"result"] isEqual:@"active"]&&[reply[@"paired"] boolValue]&&requests==1,@"actual transport and vault commit before successful owner reply");
    Check([owner sourceAuthorizationCurrent],@"durably committed active signature admits a source consumer");
    // An actual protected side effect in the owned test folder. Authorization
    // is checked by the consumer immediately before opening its output.
    NSString *protected=[base stringByAppendingPathComponent:@"source-operation"];
    BOOL wrote=[owner sourceAuthorizationCurrent]&&[@"owned fixture" writeToFile:protected atomically:NO encoding:NSUTF8StringEncoding error:nil];
    Check(wrote&&[NSFileManager.defaultManager fileExistsAtPath:protected],@"licensed source consumer performs its protected write");
    NSDictionary *pair=[vault configuration:nil];
    Check([pair[@"deviceIdentity"] isEqual:initial[@"deviceIdentity"]]&&[pair[@"deviceToken"] isEqual:Bearer()],@"owner preserves its UUID and stores signed pair");
    Check(![reply.description containsString:Key]&&![reply.description containsString:Bearer()]&&![reply.description containsString:pair[@"deviceIdentity"]],@"no key bearer or identity in public reply");
    reply=Send(owner,LBXLicenseIPCRequest(@"activate",@"EEEE-FFFF-GGGG-HHHH"));
    Check([reply[@"result"] isEqual:@"paired_key_mismatch"]&&requests==1&&[[vault configuration:nil] isEqual:pair],@"mistyped replacement key cannot overwrite paired key");
    owner=Owner(vault);reply=Send(owner,LBXLicenseIPCRequest(@"status",nil));
    Check([reply[@"result"] isEqual:@"unchecked"]&&requests==1,@"new owner requires fresh online assessment");
    Check(![owner sourceAuthorizationCurrent],@"relaunch cannot restore admission from paired or lastStatus metadata");
    reply=Send(owner,LBXLicenseIPCRequest(@"validate",nil));Check([reply[@"result"] isEqual:@"active"]&&requests==2,@"new owner revalidates saved pair");
    for(NSString *kind in @[@"unsigned",@"wrong-device",@"network",@"conflict",@"revoked",@"expired",@"elapsed"]){
        mode=@"active";Send(owner,LBXLicenseIPCRequest(@"validate",nil));
        Check([owner sourceAuthorizationCurrent],@"fresh signature opens before each denial fixture");
        mode=kind;reply=Send(owner,LBXLicenseIPCRequest(@"validate",nil));
        NSString *expected=[kind isEqual:@"revoked"]?@"revoked":([@[@"expired",@"elapsed"] containsObject:kind]?@"expired":([kind isEqual:@"conflict"]?@"recovery_required":@"verification_failed"));
        Check([reply[@"result"] isEqual:expected],[@"own consumer denies " stringByAppendingString:kind]);
        Check([[vault configuration:nil][@"deviceToken"] isEqual:Bearer()],@"failure retains pairing for recovery");
        Check(![reply.description containsString:@"private-server-text"],@"no raw transport error projection");
        Check(![owner sourceAuthorizationCurrent],@"failed validation or signed denial closes source admission");
        unlink(protected.fileSystemRepresentation);
        wrote=[owner sourceAuthorizationCurrent]&&[@"denied fixture" writeToFile:protected atomically:NO encoding:NSUTF8StringEncoding error:nil];
        Check(!wrote&&![NSFileManager.defaultManager fileExistsAtPath:protected],@"denied source consumer has no protected write");
    }
    mode=@"hold";held=dispatch_semaphore_create(0);releaseReply=dispatch_semaphore_create(0);
    dispatch_semaphore_t completed=dispatch_semaphore_create(0);
    [owner handleRequest:LBXLicenseIPCRequest(@"validate",nil) completion:^(NSDictionary *value){Check([value[@"result"] isEqual:@"active"],@"held operation completes once");dispatch_semaphore_signal(completed);}];
    Check(!dispatch_semaphore_wait(held,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)),@"network operation in flight");
    Check(![owner sourceAuthorizationCurrent],@"pending validation closes old admission before networking");
    NSDictionary *reserved=[vault configuration:nil];NSUInteger count=requests;
    reply=Send(owner,LBXLicenseIPCRequest(@"validate",nil));Check([reply[@"result"] isEqual:@"busy"]&&requests==count,@"concurrent mutation refused");
    reply=Send(owner,LBXLicenseIPCRequest(@"status",nil));Check([reply[@"result"] isEqual:@"busy"]&&requests==count,@"status observes busy without sending");
    Check([[vault configuration:nil] isEqual:reserved],@"busy calls do not supersede pending generation");
    dispatch_semaphore_signal(releaseReply);Check(!dispatch_semaphore_wait(completed,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)),@"owned completion resumes");
    Check([owner sourceAuthorizationCurrent],@"completed current validation admits source operations");
    // Wall time and sleep-inclusive monotonic time are independently required.
    __block NSTimeInterval wall=NSDate.date.timeIntervalSince1970,continuous=1000;
    [owner testUseAuthorizationClock:^NSTimeInterval(BOOL monotonic){return monotonic?continuous:wall;}];
    mode=@"active";Send(owner,LBXLicenseIPCRequest(@"validate",nil));
    Check([owner sourceAuthorizationCurrent],@"deterministic lease starts after a real signed transport/commit");
    continuous+=59;Check([owner sourceAuthorizationCurrent],@"admission remains bounded before its deadline");
    continuous+=1;Check(![owner sourceAuthorizationCurrent],@"sleep-inclusive deadline closes at exactly sixty seconds");
    continuous=1000;Check(![owner sourceAuthorizationCurrent],@"rewinding time cannot revive an expired assessment");
    Send(owner,LBXLicenseIPCRequest(@"validate",nil));wall-=1;
    Check(![owner sourceAuthorizationCurrent],@"backward wall-clock movement closes admission");
    wall+=1;Check(![owner sourceAuthorizationCurrent],@"restoring wall time cannot revive closed admission");
    Send(owner,LBXLicenseIPCRequest(@"validate",nil));continuous-=1;
    Check(![owner sourceAuthorizationCurrent],@"backward continuous clock closes admission");continuous+=1;
    Send(owner,LBXLicenseIPCRequest(@"validate",nil));continuous=NAN;
    Check(![owner sourceAuthorizationCurrent],@"invalid continuous clock closes admission");continuous=1000;
    Send(owner,LBXLicenseIPCRequest(@"validate",nil));wall=NAN;
    Check(![owner sourceAuthorizationCurrent],@"invalid wall clock closes admission");wall=NSDate.date.timeIntervalSince1970;
    mode=@"short";Send(owner,LBXLicenseIPCRequest(@"validate",nil));
    Check([owner sourceAuthorizationCurrent],@"short signed expiry starts a bounded assessment");continuous+=11;
    Check(![owner sourceAuthorizationCurrent],@"signed expiry also bounds monotonic lifetime while wall time is held");
    continuous=1000;Send(owner,LBXLicenseIPCRequest(@"validate",nil));wall+=11;
    Check(![owner sourceAuthorizationCurrent],@"forward wall-clock expiry closes admission even without monotonic advancement");
    wall=NSDate.date.timeIntervalSince1970;mode=@"active";Send(owner,LBXLicenseIPCRequest(@"validate",nil));
    NSDictionary *beforeChange=[vault configuration:nil];[vault beginWithKey:nil error:nil];
    Check(![owner sourceAuthorizationCurrent],@"another vault reservation invalidates the exact committed generation");
    Check(![owner.description containsString:Key]&&![owner.description containsString:Bearer()],@"owner description omits credentials");
    Check(![[vault configuration:nil] isEqual:beforeChange],@"external fixture actually changed durable generation");
    Send(owner,LBXLicenseIPCRequest(@"validate",nil));Check([owner sourceAuthorizationCurrent],@"fresh validation can recover current generation");
    mode=@"hold";held=dispatch_semaphore_create(0);releaseReply=dispatch_semaphore_create(0);
    completed=dispatch_semaphore_create(0);
    NSMutableDictionary *late=[LBXLicenseIPCRequest(@"validate",nil) mutableCopy];
    late[@"deadline"]=@(LBXLicenseIPCClock()+0.1);
    [owner handleRequest:late completion:^(NSDictionary *value){Check([value[@"result"] isEqual:@"active"],@"late valid response still preserves authenticated pairing");dispatch_semaphore_signal(completed);}];
    Check(!dispatch_semaphore_wait(held,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)),@"short-deadline fixture owns an in-flight exchange");
    usleep(150000);dispatch_semaphore_signal(releaseReply);
    Check(!dispatch_semaphore_wait(completed,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)),@"late owned exchange durably finishes");
    Check(![owner sourceAuthorizationCurrent]&&[[vault configuration:nil][@"deviceToken"] isEqual:Bearer()],@"expired request cannot authorize new source operations even after a durable successful claim");
    mode=@"active";
    NSString *record=[path stringByAppendingPathComponent:@"pairing.json"];NSData *saved=[NSData dataWithContentsOfFile:record];
    unlink(record.fileSystemRepresentation);count=requests;
    reply=Send(owner,LBXLicenseIPCRequest(@"validate",nil));Check([reply[@"result"] isEqual:@"storage_unavailable"]&&requests==count,@"missing record never sends new claim");
    Check(![owner sourceAuthorizationCurrent],@"missing private state closes live source authorization");
    Check(![NSFileManager.defaultManager fileExistsAtPath:record],@"missing identity not recreated by service owner");
    [saved writeToFile:record atomically:NO];chmod(record.fileSystemRepresentation,0600);
    Check(![owner sourceAuthorizationCurrent],@"restored pairing alone cannot revive closed source admission");
    // Actual synchronous source consumers use the queue-owned fence rather
    // than retaining the result of sourceAuthorizationCurrent outside it.
    __block NSUInteger effects=0;NSError *operationError=nil;
    BOOL performed=[owner performSourceOperation:^(__unused NSError **effectError){effects++;return YES;} beforeDeadline:LBXLicenseIPCClock()+2 error:&operationError];
    Check(!performed&&operationError.code==4&&effects==0,@"closed source fence invokes no effect");
    mode=@"active";Send(owner,LBXLicenseIPCRequest(@"validate",nil));
    performed=[owner performSourceOperation:^(__unused NSError **effectError){
        effects++;
        return [@"fenced source fixture" writeToFile:protected atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } beforeDeadline:LBXLicenseIPCClock()+2 error:&operationError];
    Check(performed&&!operationError&&effects==1&&[NSFileManager.defaultManager fileExistsAtPath:protected],@"real signed commit admits one actual fenced file write");
    unlink(protected.fileSystemRepresentation);
    NSTimeInterval queryDeadline=LBXLicenseIPCClock()+2;
    Check([owner sourceAuthorizationCurrent]&&![owner sourceOperationCurrentBeforeDeadline:queryDeadline],@"licensed caller outside active synchronous queue has no source-operation authority");
    performed=[owner performSourceOperation:^(__unused NSError **effectError){
        Check([owner sourceOperationCurrentBeforeDeadline:queryDeadline],@"current query recognizes its exact owning live synchronous fence");
        for(NSNumber *wrong in @[@(queryDeadline+.01),@(queryDeadline-.01),@(NAN),@(INFINITY)])
            Check(![owner sourceOperationCurrentBeforeDeadline:wrong.doubleValue],@"changed shortened extended or nonfinite caller deadline cannot borrow current operation");
        Check(![Owner(vault) sourceOperationCurrentBeforeDeadline:queryDeadline],@"another owner's instance cannot borrow this exact owner queue");
        __block BOOL escaped=YES;dispatch_sync(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{escaped=[owner sourceOperationCurrentBeforeDeadline:queryDeadline];});
        Check(!escaped,@"current-operation query does not escape to an asynchronous/background caller");return YES;
    } beforeDeadline:queryDeadline error:&operationError];
    Check(performed&&!operationError&&![owner sourceOperationCurrentBeforeDeadline:queryDeadline]&&[owner sourceAuthorizationCurrent],@"successful fence clears operation context while keeping ordinary signed assessment");
    for(NSNumber *deadline in @[@(NAN),@(INFINITY),@(LBXLicenseIPCClock()-1),@(LBXLicenseIPCClock()+26)]) {
        performed=[owner performSourceOperation:^(__unused NSError **effectError){effects++;return YES;} beforeDeadline:deadline.doubleValue error:&operationError];
        Check(!performed&&operationError.code==1&&effects==1,@"invalid or unbounded source deadline has no effect");
    }
    performed=[owner performSourceOperation:nil beforeDeadline:LBXLicenseIPCClock()+2 error:&operationError];
    Check(!performed&&operationError.code==1,@"missing trusted source handler is rejected");
    performed=[owner performSourceOperation:^(__unused NSError **effectError){return NO;} beforeDeadline:LBXLicenseIPCClock()+2 error:&operationError];
    Check(!performed&&operationError.code==5&&![owner sourceAuthorizationCurrent],@"source handler failure closes admission and cannot report successful execution");
    Send(owner,LBXLicenseIPCRequest(@"validate",nil));
    NSError *trustedFailure=[NSError errorWithDomain:@"fixture-private-store" code:42 userInfo:@{NSLocalizedDescriptionKey:@"fixture-private-context"}];
    performed=[owner performSourceOperation:^(NSError **effectError){*effectError=trustedFailure;return NO;} beforeDeadline:LBXLicenseIPCClock()+2 error:&operationError];
    Check(!performed&&operationError==trustedFailure&&![owner sourceAuthorizationCurrent],@"trusted handler error stays in-process and still closes admission");
    Send(owner,LBXLicenseIPCRequest(@"validate",nil));
    count=requests;
    performed=[owner performSourceOperation:^(__unused NSError **effectError){
        NSError *nestedError=nil;
        BOOL nested=[owner performSourceOperation:^(__unused NSError **effectError){effects++;return YES;} beforeDeadline:LBXLicenseIPCClock()+2 error:&nestedError];
        Check(!nested&&nestedError.code==2,@"reentrant synchronous source fence refuses without deadlocking");
        LBXLicenseOwner *differentOwner=Owner(vault);
        nested=[differentOwner performSourceOperation:^(__unused NSError **effectError){effects++;return YES;} beforeDeadline:LBXLicenseIPCClock()+2 error:&nestedError];
        Check(!nested&&nestedError.code==2,@"cross-owner nested fence rejects synchronous queue cycles");
        __block NSDictionary *nestedReply=nil;
        [owner handleRequest:LBXLicenseIPCRequest(@"validate",nil) completion:^(NSDictionary *value){nestedReply=value;}];
        Check([nestedReply[@"result"] isEqual:@"invalid_request"]&&requests==count,@"source handler cannot enqueue or wait on its own license mutation");
        return YES;
    } beforeDeadline:LBXLicenseIPCClock()+2 error:&operationError];
    Check(performed&&!operationError&&effects==1,@"reentrant refusal preserves the outer synchronous operation");
    performed=[owner performSourceOperation:^(__unused NSError **effectError){
        @throw [NSException exceptionWithName:@"fixture-private-name" reason:@"fixture-private-message" userInfo:nil];return YES;
    } beforeDeadline:LBXLicenseIPCClock()+2 error:&operationError];
    Check(!performed&&operationError.code==5&&![operationError.description containsString:@"fixture-private"]&&![owner sourceAuthorizationCurrent],@"handler exception is sanitized and closes source admission");
    Send(owner,LBXLicenseIPCRequest(@"validate",nil));
    // Deliberately stall a fixture handler to prove that a waiting operation
    // does not receive a renewed deadline. Production handlers must not stall.
    dispatch_semaphore_t sourceEntered=dispatch_semaphore_create(0),sourceRelease=dispatch_semaphore_create(0);
    dispatch_semaphore_t firstFinished=dispatch_semaphore_create(0),secondFinished=dispatch_semaphore_create(0);
    __block BOOL firstOK=NO,secondOK=YES;__block NSInteger secondCode=0;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        firstOK=[owner performSourceOperation:^(__unused NSError **effectError){dispatch_semaphore_signal(sourceEntered);dispatch_semaphore_wait(sourceRelease,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC));return YES;}
            beforeDeadline:LBXLicenseIPCClock()+2 error:nil];
        dispatch_semaphore_signal(firstFinished);
    });
    Check(!dispatch_semaphore_wait(sourceEntered,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC)),@"first source fixture owns the serial fence");
    NSTimeInterval waitingDeadline=LBXLicenseIPCClock()+.08;
    dispatch_semaphore_t sourceSubmitted=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *failure=nil;
        dispatch_semaphore_signal(sourceSubmitted);
        secondOK=[owner performSourceOperation:^(__unused NSError **effectError){effects++;return YES;} beforeDeadline:waitingDeadline error:&failure];secondCode=failure.code;
        dispatch_semaphore_signal(secondFinished);
    });
    Check(!dispatch_semaphore_wait(sourceSubmitted,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC)),@"waiting source operation is submitted before its budget expires");
    usleep(150000);dispatch_semaphore_signal(sourceRelease);
    Check(!dispatch_semaphore_wait(firstFinished,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))&&firstOK,@"first source fixture leaves the fence successfully");
    Check(!dispatch_semaphore_wait(secondFinished,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))&&!secondOK&&secondCode==3&&effects==1,@"queue waiting consumes the original deadline without a second effect");
    // A license invalidation queued ahead of a source operation must close
    // admission before that operation, even while its signed HTTP reply is held.
    sourceEntered=dispatch_semaphore_create(0);sourceRelease=dispatch_semaphore_create(0);firstFinished=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        firstOK=[owner performSourceOperation:^(__unused NSError **effectError){dispatch_semaphore_signal(sourceEntered);dispatch_semaphore_wait(sourceRelease,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC));return YES;}
            beforeDeadline:LBXLicenseIPCClock()+2 error:nil];dispatch_semaphore_signal(firstFinished);
    });
    Check(!dispatch_semaphore_wait(sourceEntered,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC)),@"source fixture begins before queued invalidation");
    mode=@"hold-revoked";held=dispatch_semaphore_create(0);releaseReply=dispatch_semaphore_create(0);completed=dispatch_semaphore_create(0);
    [owner handleRequest:LBXLicenseIPCRequest(@"validate",nil) completion:^(NSDictionary *value){Check([value[@"result"] isEqual:@"revoked"],@"queued signed revocation completes");dispatch_semaphore_signal(completed);}];
    secondFinished=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *failure=nil;secondOK=[owner performSourceOperation:^(__unused NSError **effectError){effects++;return YES;} beforeDeadline:LBXLicenseIPCClock()+2 error:&failure];secondCode=failure.code;
        dispatch_semaphore_signal(secondFinished);
    });
    dispatch_semaphore_signal(sourceRelease);
    Check(!dispatch_semaphore_wait(firstFinished,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))&&firstOK,@"already-owned short effect completes before queued validation starts");
    Check(!dispatch_semaphore_wait(held,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC)),@"queued invalidation starts its real signed transport");
    Check(!dispatch_semaphore_wait(secondFinished,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))&&!secondOK&&secondCode==4&&effects==1,@"queued invalidation denies a following source effect during held network");
    dispatch_semaphore_signal(releaseReply);
    Check(!dispatch_semaphore_wait(completed,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC)),@"held revocation finishes after source denial");
    performed=[owner performSourceOperation:^(__unused NSError **effectError){effects++;return YES;} beforeDeadline:LBXLicenseIPCClock()+2 error:&operationError];
    Check(!performed&&operationError.code==4&&effects==1,@"signed revocation leaves source fence closed");
    mode=@"active";wall=NSDate.date.timeIntervalSince1970;continuous=1000;Send(owner,LBXLicenseIPCRequest(@"validate",nil));
    sourceEntered=dispatch_semaphore_create(0);sourceRelease=dispatch_semaphore_create(0);firstFinished=dispatch_semaphore_create(0);secondFinished=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        firstOK=[owner performSourceOperation:^(__unused NSError **effectError){dispatch_semaphore_signal(sourceEntered);dispatch_semaphore_wait(sourceRelease,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC));return YES;}
            beforeDeadline:LBXLicenseIPCClock()+2 error:nil];dispatch_semaphore_signal(firstFinished);
    });
    Check(!dispatch_semaphore_wait(sourceEntered,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC)),@"source fixture owns the queue before lease expiry");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *failure=nil;secondOK=[owner performSourceOperation:^(__unused NSError **effectError){effects++;return YES;} beforeDeadline:LBXLicenseIPCClock()+2 error:&failure];secondCode=failure.code;
        dispatch_semaphore_signal(secondFinished);
    });
    continuous+=60;dispatch_semaphore_signal(sourceRelease);
    Check(!dispatch_semaphore_wait(firstFinished,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))&&!firstOK,@"in-flight fixture cannot report success after its signed lease elapses");
    Check(!dispatch_semaphore_wait(secondFinished,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))&&!secondOK&&secondCode==4&&effects==1,@"lease expiry while queued denies the following handler before any effect");
    continuous=1000;Send(owner,LBXLicenseIPCRequest(@"validate",nil));
    performed=[owner performSourceOperation:^(__unused NSError **effectError){continuous+=60;return YES;} beforeDeadline:LBXLicenseIPCClock()+2 error:&operationError];
    Check(!performed&&operationError.code==4,@"lease expiry during a handler cannot report successful completion");
    continuous=1000;Send(owner,LBXLicenseIPCRequest(@"validate",nil));
    performed=[owner performSourceOperation:^(__unused NSError **effectError){[vault beginWithKey:nil error:nil];return YES;} beforeDeadline:LBXLicenseIPCClock()+2 error:&operationError];
    Check(!performed&&operationError.code==4,@"changed durable generation during a handler invalidates its result");
    Send(owner,LBXLicenseIPCRequest(@"validate",nil));
    NSTimeInterval overrunDeadline=LBXLicenseIPCClock()+.08;
    performed=[owner performSourceOperation:^(__unused NSError **effectError){usleep(120000);Check(![owner sourceOperationCurrentBeforeDeadline:overrunDeadline]&&![owner sourceOperationCurrentBeforeDeadline:overrunDeadline+1],@"late active query is false and extending deadline cannot revive it");return YES;} beforeDeadline:overrunDeadline error:&operationError];
    Check(!performed&&operationError.code==3,@"deadline overrun is reported without claiming rollback of the handler");
    LBXLicenseOwner *restarted=Owner(vault);
    performed=[restarted performSourceOperation:^(__unused NSError **effectError){effects++;return YES;} beforeDeadline:LBXLicenseIPCClock()+2 error:&operationError];
    Check(!performed&&operationError.code==4&&effects==1,@"persisted pairing does not authorize a restarted source executor");
    PairingContextTests(base);
    [NSFileManager.defaultManager removeItemAtPath:base error:nil];
    NSLog(@"%@: %lu license owner/IPC assertions, %lu failures",failures?@"FAIL":@"PASS",(unsigned long)checks,(unsigned long)failures);return failures?1:0;
}}
