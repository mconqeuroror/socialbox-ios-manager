#import <Foundation/Foundation.h>
#import "../lucid/Switching/LBXNativeBrokerAuthority.h"
#import "../lucid/Switching/LBXNativeIsolationJournal.h"
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static NSUInteger Checks;
static void Check(BOOL ok,NSString *label){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",label.UTF8String);exit(1);}}
static NSString *Join(NSString *a,NSString *b){return [a stringByAppendingPathComponent:b];}
static void Dir(NSString *p){Check([NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil],@"fixture directory");}
static NSString *Exec(NSString *dir,NSString *name){NSString *path=Join(dir,name);Check([[@"socialbox-broker-fixture\n" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:NO]&&!chmod(path.fileSystemRepresentation,0755),@"fixture executable");return path;}
@interface Fixture:NSObject
@property NSString *base,*path,*ig,*fb;
@end
@implementation Fixture
- (instancetype)init {if((self=[super init])){NSString *raw=Join(NSTemporaryDirectory(),[@"socialbox-broker-" stringByAppendingString:NSUUID.UUID.UUIDString]);Dir(raw);char *p=realpath(raw.fileSystemRepresentation,NULL);Check(p!=NULL,@"canonical fixture root");_base=@(p);free(p);_path=Join(_base,@"journal");_ig=Exec(_base,@"instagram");_fb=Exec(_base,@"facebook");}return self;}
- (void)dealloc{[LBXNativeBrokerProcess testSetKernelObservation:nil];[LBXNativeBrokerProcess testSetBootIdentity:nil];[NSFileManager.defaultManager removeItemAtPath:_base error:nil];}
@end
static audit_token_t Token(uint32_t n){audit_token_t token;memset(&token,0,sizeof(token));token.val[0]=n;return token;}
static void Observe(Fixture *f,NSString *app,NSString *path,uint32_t pid){
    [LBXNativeBrokerProcess testSetBootIdentity:@"boot-a"];
    [LBXNativeBrokerProcess testSetKernelObservation:^NSDictionary *(audit_token_t token){
        return @{@"pid":@(token.val[0]),@"pidversion":@1,@"birth":@100,@"executable":[app isEqual:@"com.burbn.instagram"]?f.ig:f.fb,@"bootIdentity":@"boot-a"};
    }];
    (void)path;(void)pid;
}
static LBXNativeBrokerAuthority *Open(Fixture *f){LBXNativeIsolationJournal *j=[LBXNativeIsolationJournal testOpenDirectory:f.path create:YES error:nil];Check(j!=nil,@"broker child journal");LBXNativeBrokerAuthority *a=[LBXNativeBrokerAuthority testOpenJournal:j error:nil];Check(a!=nil,@"open broker authority");return a;}
static LBXNativeBrokerProcess *Proc(Fixture *f,NSString *app,uint32_t pid){
    NSString *path=[app isEqual:@"com.burbn.instagram"]?f.ig:f.fb;
    Observe(f,app,path,pid);
    LBXNativeBrokerCodeBinding *code=[LBXNativeBrokerCodeBinding testObserveApplication:app executable:path error:nil];
    Check(code!=nil,@"code binding");
    LBXNativeBrokerProcess *process=[LBXNativeBrokerProcess observeAuditToken:Token(pid) codeBinding:code error:nil];
    Check(process!=nil,@"process observation");return process;
}
int main(void){@autoreleasepool{
    Fixture *f=[Fixture new];double deadline=LBXNativeBrokerClock()+30;
    Check([LBXNativeBrokerCodeBinding testObserveApplication:@"com.atebits.Tweetie2" executable:f.ig error:nil]==nil,@"unsupported app refused");
    Check([LBXNativeBrokerCodeBinding testObserveApplication:@"com.burbn.instagram" executable:@"/tmp/missing-socialbox-exec" error:nil]==nil,@"missing executable refused");
    LBXNativeBrokerAuthority *a=Open(f);Check([a.safeStatus[@"admissionOpen"] isEqual:@NO]&&[a.safeStatus[@"runtimeAccepted"] isEqual:@NO],@"restart opens with closed admission");
    Check(![a.description containsString:f.ig]&&![a.debugDescription containsString:@"boot-a"],@"authority description omits identities");
    Check([a prepareContainerID:@"01" beforeDeadline:deadline error:nil]==nil,@"leading-zero CID refused");
    LBXNativeBrokerEpoch *ig=[a prepareContainerID:@"0" beforeDeadline:deadline error:nil];Check(ig&&[ig.containerID isEqual:@"0"],@"prepare Instagram default CID");
    Check(![a admitEpoch:ig beforeDeadline:deadline authorization:^BOOL{return NO;} error:nil],@"failed authorization cannot admit");
    Check([a admitEpoch:ig beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"admit prepared epoch");
    Check([a.safeStatus[@"admissionOpen"] isEqual:@YES],@"admission open after admit");
    Check([a prepareContainerID:@"1" beforeDeadline:deadline error:nil]==nil,@"prepare refused while admission open");
    LBXNativeBrokerProcess *pIG=Proc(f,@"com.burbn.instagram",501);
    Check([a assignVerifiedLaunch:pIG epoch:ig beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"assign Instagram launch");
    Check(![a assignVerifiedLaunch:pIG epoch:ig beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"existing process cannot be relabelled");
    LBXNativeBrokerLease *lease=[a beginRequestForProcess:pIG beforeDeadline:deadline error:nil];Check(lease&&[lease.applicationID isEqual:@"com.burbn.instagram"]&&[lease.containerID isEqual:@"0"],@"Instagram lease under admitted CID");
    Check([a closeAdmissionBeforeDeadline:deadline error:nil],@"close admission while a lease is outstanding");
    Check([a beginRequestForProcess:pIG beforeDeadline:deadline error:nil]==nil,@"closed admission refuses new leases");
    Check([a waitForLeasesBeforeDeadline:LBXNativeBrokerClock()+0.05 error:nil]==NO,@"lost in-flight lease does not satisfy close barrier");
    Check([a endRequest:lease error:nil]&&[a waitForLeasesBeforeDeadline:deadline error:nil],@"explicit lease completion unblocks wait");
    Check(![a endRequest:lease error:nil],@"double-complete lease refused");
    Check([a closeAdmissionBeforeDeadline:deadline error:nil],@"idempotent close");
    LBXNativeBrokerEpoch *fb=[a prepareContainerID:@"109" beforeDeadline:deadline error:nil];Check(fb&&[a admitEpoch:fb beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"prepare and admit Facebook CID");
    LBXNativeBrokerProcess *pFB=Proc(f,@"com.facebook.Facebook",502);
    Check(![a assignVerifiedLaunch:pFB epoch:fb beforeDeadline:deadline authorization:^BOOL{return NO;} error:nil],@"Facebook assign requires authorization");
    Check([a assignVerifiedLaunch:pFB epoch:fb beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"assign Facebook launch to 109");
    LBXNativeBrokerLease *fbLease=[a beginRequestForProcess:pFB beforeDeadline:deadline error:nil];Check([fbLease.containerID isEqual:@"109"],@"Facebook request stays on 109");
    Check([a beginRequestForProcess:pIG beforeDeadline:deadline error:nil]==nil,@"Instagram process cannot use Facebook epoch");
    Check([a endRequest:fbLease error:nil],@"complete Facebook lease");
    Check([a closeAdmissionBeforeDeadline:deadline error:nil],@"close after Facebook");
    Fixture *g=[Fixture new];LBXNativeIsolationJournal *j1=[LBXNativeIsolationJournal testOpenDirectory:g.path create:YES error:nil];
    LBXNativeBrokerAuthority *first=[LBXNativeBrokerAuthority testOpenJournal:j1 error:nil];
    LBXNativeBrokerEpoch *e=[first prepareContainerID:@"0" beforeDeadline:deadline error:nil];
    Check([first admitEpoch:e beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"first lifetime admit");
    LBXNativeBrokerProcess *p=Proc(g,@"com.burbn.instagram",7);
    Check([first assignVerifiedLaunch:p epoch:e beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"first lifetime assignment");
    [j1 close];first=nil;
    LBXNativeIsolationJournal *j2=[LBXNativeIsolationJournal testOpenDirectory:g.path create:NO error:nil];
    LBXNativeBrokerAuthority *second=[LBXNativeBrokerAuthority testOpenJournal:j2 error:nil];
    Check([second.safeStatus[@"admissionOpen"] isEqual:@NO]&&[second.safeStatus[@"tombstoneCount"] isEqual:@1],@"restart closes admission and tombstones assignments");
    LBXNativeBrokerEpoch *e2=[second prepareContainerID:@"0" beforeDeadline:deadline error:nil];
    Check([second admitEpoch:e2 beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"new epoch after restart");
    Check(![second assignVerifiedLaunch:p epoch:e2 beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"tombstoned process cannot be relabelled after restart");
    LBXNativeBrokerProcess *fresh=Proc(g,@"com.burbn.instagram",8);
    Check([second assignVerifiedLaunch:fresh epoch:e2 beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"new process birth can join new epoch");
    Check(![second.safeStatus[@"brokerIsolationVerified"] boolValue],@"component never claims installed broker isolation");
    printf("PASS: %lu native broker authority assertions for Instagram/Facebook epochs\n",(unsigned long)Checks);return 0;
}}
