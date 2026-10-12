#import "../Authorization/LBXLicenseVault.h"
#import "../Authorization/LBXLicenseOwner.h"
#import "../Authorization/LBXLicenseIPC.h"
#import "../Containers/LBXContainerConfigurationStore.h"
#import "../Containers/LBXContainerConfiguration.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/acl.h>
#include <membership.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

static NSUInteger checks,failures;
static void Check(BOOL good,NSString *why) {checks++;if(!good){failures++;fprintf(stderr,"FAIL: %s\n",why.UTF8String);}}

#if !LBX_LICENSE_VAULT_TESTING
// Unbound private initialization makes no files/admission. A genuine owner
// avoids confounding the production Store role test with a nil owner argument.
@interface LBXLicenseVault (ProductionRoleFixture)
- (instancetype)initPrivate;
@end
#endif

#if LBX_LICENSE_VAULT_TESTING && LBX_CONTAINER_STORE_TESTING
#import "../../tests/RBXLicenseTestSupport.h"
static NSString *const FixtureKey=@"AAAA-BBBB-CCCC-DDDD";
static NSString *SignedStatus=@"active";
@interface InstallationProtocol:NSURLProtocol @end
@implementation InstallationProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {(void)request;return YES;}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {return request;}
- (void)stopLoading {}
- (void)startLoading {
    NSData *body=self.request.HTTPBody;
    if(!body&&self.request.HTTPBodyStream){NSInputStream *stream=self.request.HTTPBodyStream;[stream open];NSMutableData *data=[NSMutableData data];uint8_t buffer[1024];NSInteger n;while((n=[stream read:buffer maxLength:sizeof(buffer)])>0)[data appendBytes:buffer length:(NSUInteger)n];[stream close];body=data;}
    NSDictionary *request=[NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    NSMutableDictionary *claims=TestLicenseClaims(FixtureKey,request[@"nonce"],NSDate.date.timeIntervalSince1970);
    claims[@"iss"]=@"https://redditspoof.vercel.app";claims[@"deviceBinding"]=[RBXLicenseToken fingerprint:request[@"deviceIdentity"]];claims[@"status"]=SignedStatus;
    NSDictionary *reply=@{@"licenseToken":TestLicenseJWT(claims,nil),@"deviceId":@"fixture-device",@"token":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0]};
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil]];[self.client URLProtocolDidFinishLoading:self];
}
@end
static LBXLicenseOwner *NewOwner(LBXLicenseVault *vault) {
    [vault testUsePublicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];
    LBXLicenseOwner *owner=[[LBXLicenseOwner alloc] initWithVault:vault];
    [owner testUseProtocol:InstallationProtocol.class publicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];return owner;
}
static NSDictionary *Send(LBXLicenseOwner *owner,NSString *operation) {
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSDictionary *reply;
    [owner handleRequest:LBXLicenseIPCRequest(operation,[operation isEqual:@"activate"]?FixtureKey:nil) completion:^(NSDictionary *value){reply=value;dispatch_semaphore_signal(done);}];
    Check(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)),@"bounded synthetic signed website reply");return reply;
}
static NSString *Join(NSString *base,NSString *leaf) {return [base stringByAppendingPathComponent:leaf];}
static BOOL PrivateFile(NSString *path,NSData *bytes) {
    int fd=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(fd<0)return NO;BOOL okay=write(fd,bytes.bytes,bytes.length)==(ssize_t)bytes.length;return !close(fd)&&okay;
}
static BOOL ACL(NSString *path,BOOL populated) {
    acl_t acl=acl_init(1);BOOL okay=acl!=NULL;
    if(populated){uuid_t subject;acl_entry_t entry;acl_permset_t permissions;okay=okay&&!mbr_uid_to_uuid(geteuid(),subject)&&!acl_create_entry(&acl,&entry)&&!acl_set_tag_type(entry,ACL_EXTENDED_ALLOW)&&!acl_set_qualifier(entry,subject)&&!acl_get_permset(entry,&permissions)&&!acl_add_perm(permissions,ACL_READ_DATA);}
    okay=okay&&acl_set_file(path.fileSystemRepresentation,ACL_TYPE_EXTENDED,acl)==0;if(acl)acl_free(acl);return okay;
}
static NSDictionary *Snapshot(NSString *path) {
    struct stat node;if(lstat(path.fileSystemRepresentation,&node))return nil;
    NSMutableDictionary *snapshot=[@{@"device":@((unsigned long long)node.st_dev),@"inode":@((unsigned long long)node.st_ino),@"owner":@(node.st_uid),@"group":@(node.st_gid),@"mode":@(node.st_mode),@"links":@(node.st_nlink)} mutableCopy];
    if(S_ISREG(node.st_mode))snapshot[@"bytes"]=[NSData dataWithContentsOfFile:path]?:NSData.data;
    if(S_ISLNK(node.st_mode)){char text[4096];ssize_t n=readlink(path.fileSystemRepresentation,text,sizeof(text));snapshot[@"link"]=n>=0?[NSData dataWithBytes:text length:(NSUInteger)n]:NSData.data;}
    if(S_ISDIR(node.st_mode)){NSMutableDictionary *children=[NSMutableDictionary dictionary];for(NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil])children[name]=Snapshot(Join(path,name))?:@{};snapshot[@"children"]=children;}
    return snapshot;
}
static BOOL SameSchema(NSDictionary *value,NSArray *keys) {return [value isKindOfClass:NSDictionary.class]&&value.count==keys.count&&[[NSSet setWithArray:value.allKeys] isEqual:[NSSet setWithArray:keys]];}
static void Immutable(NSDictionary *context) {
    __block BOOL blocked=NO;@try{[(NSMutableDictionary *)context setObject:@YES forKey:@"unexpected"];}@catch(__unused NSException *exception){blocked=YES;}Check(blocked,@"top-level installer facts cannot mutate");
    for(id value in context.allValues)if([value isKindOfClass:NSDictionary.class])Immutable(value);
}
static void ResetHooks(void) {
    [LBXLicenseVault testPristineBoundaryHandler:nil];[LBXLicenseVault testStopPristineAfterBoundary:nil];
    [LBXContainerConfigurationStore testPristineBoundaryHandler:nil];[LBXContainerConfigurationStore testStopPristineAfterBoundary:nil];
}
static void ExclusiveTests(NSString *base,LBXLicenseOwner *owner) {
    for(NSString *kind in @[@"empty",@"unknown",@"file",@"fifo",@"symlink",@"public",@"acl"]){
        NSString *path=Join(base,[@"existing-" stringByAppendingString:kind]);
        if([kind isEqual:@"file"])Check(PrivateFile(path,[@"unknown" dataUsingEncoding:NSUTF8StringEncoding]),@"existing unknown file fixture");
        else if([kind isEqual:@"fifo"])Check(!mkfifo(path.fileSystemRepresentation,0600),@"existing FIFO fixture");
        else if([kind isEqual:@"symlink"])Check(!symlink("missing",path.fileSystemRepresentation),@"existing symlink fixture");
        else {Check(!mkdir(path.fileSystemRepresentation,0700),@"existing directory fixture");if([kind isEqual:@"unknown"])Check(PrivateFile(Join(path,@"unknown"),NSData.data),@"existing unknown child fixture");if([kind isEqual:@"public"])Check(!chmod(path.fileSystemRepresentation,0777),@"existing public directory fixture");if([kind isEqual:@"acl"])Check(ACL(path,YES),@"existing directory ACL fixture");}
        NSDictionary *before=Snapshot(path);NSError *error=nil;
        Check(![LBXLicenseVault createPristineDirectory:path error:&error]&&error&&[Snapshot(path) isEqual:before],@"pristine vault refuses every EEXIST without modifying any node");
        error=nil;Check(![LBXContainerConfigurationStore createPristineDirectory:path licenseOwner:owner error:&error]&&error&&[Snapshot(path) isEqual:before],@"pristine namespace refuses every EEXIST without modifying any node");
    }
    NSString *parent=Join(base,@"unsafe-parent");Check(!mkdir(parent.fileSystemRepresentation,0700),@"unsafe-parent fixture");
    for(NSString *kind in @[@"public",@"acl"]){if([kind isEqual:@"public"])chmod(parent.fileSystemRepresentation,0777);else Check(ACL(parent,YES),@"parent ACL actually installed");NSDictionary *before=Snapshot(parent);
        Check(![LBXLicenseVault createPristineDirectory:Join(parent,@"vault") error:nil]&&[Snapshot(parent) isEqual:before],@"unsafe parent denies pristine vault before effects");
        Check(![LBXContainerConfigurationStore createPristineDirectory:Join(parent,@"config") licenseOwner:owner error:nil]&&[Snapshot(parent) isEqual:before],@"unsafe parent denies pristine namespace before effects");chmod(parent.fileSystemRepresentation,0700);Check(ACL(parent,NO),@"fixture parent ACL removed");}
    NSString *alias=Join(base,@"parent-alias");Check(!symlink(base.fileSystemRepresentation,alias.fileSystemRepresentation),@"noncanonical parent alias fixture");
    Check(![LBXLicenseVault createPristineDirectory:Join(alias,@"alias-vault") error:nil]&&!Snapshot(Join(base,@"alias-vault")),@"pristine vault rejects nonphysical caller alias before effects");
    Check(![LBXContainerConfigurationStore createPristineDirectory:Join(alias,@"alias-config") licenseOwner:owner error:nil]&&!Snapshot(Join(base,@"alias-config")),@"pristine namespace rejects nonphysical caller alias before effects");
}
static void InterruptionTests(NSString *base,LBXLicenseOwner *owner) {
    for(NSString *boundary in @[@"directory_created",@"lock_created",@"before_seed_publication",@"seed_published"]){NSString *path=Join(base,[@"vault-stop-" stringByAppendingString:boundary]);[LBXLicenseVault testStopPristineAfterBoundary:boundary];
        Check(![LBXLicenseVault createPristineDirectory:path error:nil],@"failure-only vault creation boundary returns no instance");ResetHooks();NSDictionary *partial=Snapshot(path);Check(partial!=nil,@"vault interrupted resources remain preserved");
        Check(![LBXLicenseVault createPristineDirectory:path error:nil]&&[Snapshot(path) isEqual:partial],@"vault retry never adopts or rewrites interrupted partial state");
        NSArray *names=[NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil];NSUInteger count=[boundary isEqual:@"directory_created"]?0:[boundary isEqual:@"lock_created"]?1:2;Check(names.count==count,@"vault interruption preserves exactly completed boundaries");}
    for(NSString *boundary in @[@"directory_created",@"lock_created",@"namespace_published"]){NSString *path=Join(base,[@"config-stop-" stringByAppendingString:boundary]);[LBXContainerConfigurationStore testStopPristineAfterBoundary:boundary];
        Check(![LBXContainerConfigurationStore createPristineDirectory:path licenseOwner:owner error:nil],@"failure-only namespace boundary returns no instance");ResetHooks();NSDictionary *partial=Snapshot(path);Check(partial!=nil,@"namespace interrupted resources remain preserved");
        Check(![LBXContainerConfigurationStore createPristineDirectory:path licenseOwner:owner error:nil]&&[Snapshot(path) isEqual:partial],@"namespace retry never adopts or repairs interrupted state");NSArray *names=[NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil];Check(names.count==([boundary isEqual:@"directory_created"]?0:1),@"namespace interruption preserves exactly completed boundaries");}
}
static void InjectionTests(NSString *base,LBXLicenseOwner *owner) {
    for(NSUInteger type=0;type<2;type++)for(NSString *boundary in (type==0?@[@"directory_created",@"lock_created",@"seed_published"]:@[@"directory_created",@"lock_created",@"namespace_published"])){
        NSString *path=Join(base,[NSString stringWithFormat:@"inject-%lu-%@",(unsigned long)type,boundary]),*unknown=Join(path,@"unknown-node");__block NSDictionary *injected=nil;
        void (^handler)(NSString *)=^(NSString *seen){if([seen isEqual:boundary]){Check(PrivateFile(unknown,[@"untouched" dataUsingEncoding:NSUTF8StringEncoding]),@"unknown node injected at actual creation boundary");injected=Snapshot(unknown);}};
        if(type==0)[LBXLicenseVault testPristineBoundaryHandler:handler];else[LBXContainerConfigurationStore testPristineBoundaryHandler:handler];
        id result=type==0?[LBXLicenseVault createPristineDirectory:path error:nil]:[LBXContainerConfigurationStore createPristineDirectory:path licenseOwner:owner error:nil];ResetHooks();
        Check(!result&&injected&&[Snapshot(unknown) isEqual:injected],@"unknown post-effect node is neither adopted overwritten nor deleted");NSDictionary *partial=Snapshot(path);
        Check(!(type==0?[LBXLicenseVault createPristineDirectory:path error:nil]:[LBXContainerConfigurationStore createPristineDirectory:path licenseOwner:owner error:nil])&&[Snapshot(path) isEqual:partial],@"unknown partial state survives later exclusive retry exactly");
    }
    for(NSUInteger type=0;type<2;type++){
        NSString *path=Join(base,[NSString stringWithFormat:@"substitute-created-%lu",(unsigned long)type]),*held=[path stringByAppendingString:@"-held"];__block NSDictionary *replacement=nil,*original=nil;
        void (^handler)(NSString *)=^(NSString *boundary){if([boundary isEqual:@"directory_created"]){Check(!rename(path.fileSystemRepresentation,held.fileSystemRepresentation)&&!mkdir(path.fileSystemRepresentation,0700),@"opened newly-created directory actually replaced");original=Snapshot(held);replacement=Snapshot(path);}};
        if(type==0)[LBXLicenseVault testPristineBoundaryHandler:handler];else[LBXContainerConfigurationStore testPristineBoundaryHandler:handler];
        id result=type==0?[LBXLicenseVault createPristineDirectory:path error:nil]:[LBXContainerConfigurationStore createPristineDirectory:path licenseOwner:owner error:nil];ResetHooks();
        Check(!result&&[Snapshot(path) isEqual:replacement]&&[Snapshot(held) isEqual:original],@"post-mkdir substitution denies without modifying original or substituted node");
    }
    for(NSUInteger type=0;type<2;type++){
        NSString *path=Join(base,[NSString stringWithFormat:@"substitute-lock-%lu",(unsigned long)type]),*lock=Join(path,type==0?@"owner.lock":@"configuration.lock"),*held=[lock stringByAppendingString:@"-held"];__block NSDictionary *replacement=nil,*original=nil;
        void (^handler)(NSString *)=^(NSString *boundary){if([boundary isEqual:@"lock_created"]){Check(!rename(lock.fileSystemRepresentation,held.fileSystemRepresentation)&&PrivateFile(lock,NSData.data),@"held created lock actually replaced");original=Snapshot(held);replacement=Snapshot(lock);}};
        if(type==0)[LBXLicenseVault testPristineBoundaryHandler:handler];else[LBXContainerConfigurationStore testPristineBoundaryHandler:handler];
        id result=type==0?[LBXLicenseVault createPristineDirectory:path error:nil]:[LBXContainerConfigurationStore createPristineDirectory:path licenseOwner:owner error:nil];ResetHooks();
        Check(!result&&[Snapshot(lock) isEqual:replacement]&&[Snapshot(held) isEqual:original],@"lock substitution denies without seed publication or repair");
    }
    NSString *path=Join(base,@"seed-destination-appeared"),*destination=Join(path,@"pairing.json");__block NSDictionary *unknown=nil;
    [LBXLicenseVault testPristineBoundaryHandler:^(NSString *boundary){if([boundary isEqual:@"before_seed_publication"]){Check(PrivateFile(destination,[@"unknown partial destination" dataUsingEncoding:NSUTF8StringEncoding]),@"unknown pairing destination appears after seed stage fsync");unknown=Snapshot(destination);}}];
    Check(![LBXLicenseVault createPristineDirectory:path error:nil],@"post-stage unknown pairing destination prevents pristine publication");ResetHooks();
    Check(unknown&&[Snapshot(destination) isEqual:unknown]&&[NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil].count==3,@"unknown destination and exact interrupted seed stage both remain preserved");
    NSDictionary *partial=Snapshot(path);Check(![LBXLicenseVault createPristineDirectory:path error:nil]&&[Snapshot(path) isEqual:partial],@"post-stage retry never adopts overwrites or cleans partial nodes");
}
static void ObservationTests(NSString *base,LBXLicenseOwner *owner) {
    for(NSUInteger type=0;type<2;type++)for(NSString *kind in @[@"public-directory",@"public-lock",@"lock-acl",@"directory-acl",@"hardlink",@"lock-replace",@"leaf-replace",@"parent-replace"]){
        NSString *parent=Join(base,[NSString stringWithFormat:@"observe-parent-%lu-%@",(unsigned long)type,kind]);Check(!mkdir(parent.fileSystemRepresentation,0700),@"observation private parent created");NSString *path=Join(parent,@"leaf"),*lock=Join(path,type==0?@"owner.lock":@"configuration.lock");
        LBXLicenseVault *vault=type==0?[LBXLicenseVault createPristineDirectory:path error:nil]:nil;
        LBXContainerConfigurationStore *store=type==1?[LBXContainerConfigurationStore createPristineDirectory:path licenseOwner:owner error:nil]:nil;
        NSDictionary *initial=type==0?[vault installationContextForTrustedInstaller:nil]:[store configurationNamespaceContextForTrustedInstaller:nil];Check(initial!=nil,@"trusted facts observed before real unsafe substitution");
        if([kind isEqual:@"public-directory"])chmod(path.fileSystemRepresentation,0755);
        else if([kind isEqual:@"public-lock"])chmod(lock.fileSystemRepresentation,0644);
        else if([kind isEqual:@"lock-acl"])Check(ACL(lock,YES),@"real lock ACL installed");
        else if([kind isEqual:@"directory-acl"])Check(ACL(path,YES),@"real directory ACL installed");
        else if([kind isEqual:@"hardlink"])Check(!link(lock.fileSystemRepresentation,Join(parent,@"alias").fileSystemRepresentation),@"real lock hardlink installed");
        else if([kind isEqual:@"lock-replace"])Check(!rename(lock.fileSystemRepresentation,Join(parent,@"held-lock").fileSystemRepresentation)&&PrivateFile(lock,NSData.data),@"same-bytes real lock replacement");
        else if([kind isEqual:@"leaf-replace"])Check(!rename(path.fileSystemRepresentation,Join(parent,@"held-leaf").fileSystemRepresentation)&&!mkdir(path.fileSystemRepresentation,0700),@"real leaf replacement");
        else Check(!rename(parent.fileSystemRepresentation,[parent stringByAppendingString:@"-held"].fileSystemRepresentation)&&!mkdir(parent.fileSystemRepresentation,0700),@"real physical parent replacement");
        NSDictionary *before=Snapshot(parent);NSError *error=nil;NSDictionary *observed=type==0?[vault installationContextForTrustedInstaller:&error]:[store configurationNamespaceContextForTrustedInstaller:&error];
        Check(!observed&&error&&[Snapshot(parent) isEqual:before],@"unsafe/replaced observation denies without changing any current file");
    }
    for(NSUInteger type=0;type<2;type++){
        NSString *path=Join(base,[NSString stringWithFormat:@"observe-inflight-%lu",(unsigned long)type]),*lock=Join(path,type==0?@"owner.lock":@"configuration.lock");
        LBXLicenseVault *vault=type==0?[LBXLicenseVault createPristineDirectory:path error:nil]:nil;
        LBXContainerConfigurationStore *store=type==1?[LBXContainerConfigurationStore createPristineDirectory:path licenseOwner:owner error:nil]:nil;__block NSDictionary *substituted=nil;
        void (^handler)(NSString *)=^(NSString *boundary){if([boundary isEqual:type==0?@"installation_observed":@"namespace_observed"]){Check(!rename(lock.fileSystemRepresentation,[lock stringByAppendingString:@"-held"].fileSystemRepresentation)&&PrivateFile(lock,NSData.data),@"lock replaced after observation snapshot while actual flock held");substituted=Snapshot(lock);}};
        if(type==0)[LBXLicenseVault testPristineBoundaryHandler:handler];else[LBXContainerConfigurationStore testPristineBoundaryHandler:handler];
        NSDictionary *result=type==0?[vault installationContextForTrustedInstaller:nil]:[store configurationNamespaceContextForTrustedInstaller:nil];ResetHooks();
        Check(!result&&substituted&&[Snapshot(lock) isEqual:substituted],@"in-flight snapshot rechecks refuse substituted lock without repair");
    }
}
static void ConcurrentTests(NSString *base,LBXLicenseOwner *owner) {
    for(NSUInteger type=0;type<2;type++){
        NSString *path=Join(base,[NSString stringWithFormat:@"race-%lu",(unsigned long)type]);NSObject *guard=[NSObject new];__block NSUInteger winners=0;
        dispatch_apply(12,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t i){(void)i;@autoreleasepool{id value=type==0?[LBXLicenseVault createPristineDirectory:path error:nil]:[LBXContainerConfigurationStore createPristineDirectory:path licenseOwner:owner error:nil];if(value)@synchronized(guard){winners++;}}});
        Check(winners==1,@"twelve concurrent pristine creators produce exactly one genuine creator");NSDictionary *before=Snapshot(path);
        Check(!(type==0?[LBXLicenseVault createPristineDirectory:path error:nil]:[LBXContainerConfigurationStore createPristineDirectory:path licenseOwner:owner error:nil])&&[Snapshot(path) isEqual:before],@"post-race retry leaves exact winner infrastructure unchanged");
    }
}
#endif

int main(void) {@autoreleasepool{
#if LBX_LICENSE_VAULT_TESTING && LBX_CONTAINER_STORE_TESTING
    char temporary[]="/private/tmp/socialbox-installation-producer.XXXXXX";Check(mkdtemp(temporary)!=NULL,@"private fixture parent created");NSString *base=[NSString stringWithUTF8String:temporary];
    NSString *vaultPath=Join(base,@"vault"),*storePath=Join(base,@"config");NSError *error=nil;
    LBXLicenseVault *vault=[LBXLicenseVault createPristineDirectory:vaultPath error:&error];Check(vault&&!error,@"pristine vault returns exact new instance");LBXLicenseOwner *owner=NewOwner(vault);
    LBXContainerConfigurationStore *store=[LBXContainerConfigurationStore createPristineDirectory:storePath licenseOwner:owner error:&error];Check(store&&!error,@"pristine namespace returns exact new instance before pairing");
    NSDictionary *vaultFacts=[vault installationContextForTrustedInstaller:&error],*storeFacts=[store configurationNamespaceContextForTrustedInstaller:&error];
    Check(SameSchema(vaultFacts,@[@"server",@"deviceIdentity",@"vault"])&&SameSchema(vaultFacts[@"vault"],@[@"directory",@"lock"]),@"stable vault facts contain only seed/server/namespace");
    Check(SameSchema(storeFacts,@[@"directory",@"lock"])&&[storeFacts[@"directory"] count]==5&&[storeFacts[@"lock"] count]==5,@"stable namespace facts contain exact bounded descriptor node schema");Immutable(vaultFacts);Immutable(storeFacts);
    Check(![owner sourceAuthorizationCurrent]&&![[vault safeStatus][@"paired"] boolValue],@"pre-pair observation never mints signed admission");
    LBXContainerConfiguration *candidate=[LBXContainerConfiguration createWithName:@"Private synthetic saved fixture" applications:@[@"com.burbn.instagram"] manualIdentifiers:nil proxyReference:@"" error:nil];
    Check(![store commitConfiguration:candidate replacing:nil beforeDeadline:LBXLicenseIPCClock()+2 error:nil]&&[store configurations:nil].count==0,@"installer facts do not authorize source configuration publication");
    Check(![vault pairingContextForSourceOwner:owner beforeDeadline:LBXLicenseIPCClock()+2 error:nil],@"new observations do not relax signed pairing context");
    NSDictionary *vaultBefore=Snapshot(vaultPath),*storeBefore=Snapshot(storePath);
    Check(![LBXLicenseVault createPristineDirectory:vaultPath error:nil]&&[Snapshot(vaultPath) isEqual:vaultBefore],@"valid pristine-created vault EEXIST refuses adoption with exact bytes/inodes intact");
    Check(![LBXContainerConfigurationStore createPristineDirectory:storePath licenseOwner:owner error:nil]&&[Snapshot(storePath) isEqual:storeBefore],@"valid namespace EEXIST refuses adoption with exact bytes/inodes intact");
    Check([Send(owner,@"activate")[@"result"] isEqual:@"active"]&&[owner sourceAuthorizationCurrent],@"actual owner receives genuine synthetic signed activation");
    Check([[vault installationContextForTrustedInstaller:nil] isEqual:vaultFacts]&&[[store configurationNamespaceContextForTrustedInstaller:nil] isEqual:storeFacts],@"stable installer facts remain exactly equal after genuine pairing");
    NSDictionary *paired=[vault configuration:nil];Check([paired[@"deviceId"] length]>0&&[paired[@"revision"] unsignedLongLongValue]>1,@"pairing truly changes private credential/revision state");
    Check([Send(owner,@"validate")[@"result"] isEqual:@"active"],@"fresh synthetic signed validation");
    Check([[[vault configuration:nil] objectForKey:@"revision"] unsignedLongLongValue]>[paired[@"revision"] unsignedLongLongValue]&&[[vault installationContextForTrustedInstaller:nil] isEqual:vaultFacts],@"validation revision advances without invalidating stable seed/node facts");
    double deadline=LBXLicenseIPCClock()+2;__block BOOL recursiveRefused=NO;
    Check([owner performSourceOperation:^BOOL(NSError **failure){
        Check([[vault installationContextForTrustedInstaller:nil] isEqual:vaultFacts],@"vault observation does not nest/reenter source owner fence");
        return [store performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(NSDictionary *context,__unused NSError **setupError){recursiveRefused=[store configurationNamespaceContextForTrustedInstaller:nil]==nil;Check([context isEqual:storeFacts],@"held-empty callback supplies authoritative same namespace without nested observation");return YES;} error:failure];
    } beforeDeadline:deadline error:nil]&&recursiveRefused,@"installer namespace observation immediately refuses recursive held-empty acquisition");
    Check([store commitConfiguration:candidate replacing:nil beforeDeadline:LBXLicenseIPCClock()+2 error:nil],@"unchanged signed consumer path genuinely saves configuration");
    Check([[store configurationNamespaceContextForTrustedInstaller:nil] isEqual:storeFacts],@"namespace facts are stable and do not claim empty after source save");
    SignedStatus=@"revoked";Check([Send(owner,@"validate")[@"result"] isEqual:@"revoked"]&&![owner sourceAuthorizationCurrent],@"genuine synthetic signed denial closes source admission");
    Check([[vault installationContextForTrustedInstaller:nil] isEqual:vaultFacts]&&[[store configurationNamespaceContextForTrustedInstaller:nil] isEqual:storeFacts],@"descriptive root-local origin facts remain available without conveying revoked admission");
    LBXContainerConfiguration *edit=[candidate configurationByUpdatingName:@"Denied synthetic edit" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];NSDictionary *saved=Snapshot(storePath);
    Check(![store commitConfiguration:edit replacing:candidate beforeDeadline:LBXLicenseIPCClock()+2 error:nil]&&[Snapshot(storePath) isEqual:saved],@"new observation cannot override genuine signed denial");
    LBXLicenseVault *reopened=[LBXLicenseVault openExistingDirectory:vaultPath error:nil];LBXLicenseOwner *restart=NewOwner(reopened);LBXContainerConfigurationStore *reopenedStore=[LBXContainerConfigurationStore openDirectory:storePath licenseOwner:restart create:NO error:nil];
    Check([[reopened installationContextForTrustedInstaller:nil] isEqual:vaultFacts]&&[[reopenedStore configurationNamespaceContextForTrustedInstaller:nil] isEqual:storeFacts],@"existing-only reopen recovers exact stable origin facts without source grant");
    ExclusiveTests(base,owner);InterruptionTests(base,owner);InjectionTests(base,owner);ObservationTests(base,owner);ConcurrentTests(base,owner);
    ResetHooks();[NSFileManager.defaultManager removeItemAtPath:base error:nil];
    printf("%s: %lu installer prerequisite assertions, %lu failures (real filesystem; synthetic signed owner)\n",failures?"FAIL":"PASS",(unsigned long)checks,(unsigned long)failures);
#else
    Check(getuid()!=0||geteuid()!=0,@"production host fixture has a genuinely non-root role");
    LBXLicenseVault *unbound=[[LBXLicenseVault alloc] initPrivate];LBXLicenseOwner *owner=[[LBXLicenseOwner alloc] initWithVault:unbound];
    Check(owner!=nil&&!owner.sourceAuthorizationCurrent,@"production namespace role test supplies genuine closed owner");
    NSString *path=@"/private/tmp/socialbox-production-role-must-not-create";
    Check(![LBXLicenseVault createPristineDirectory:path error:nil],@"production pristine vault rejects actual non-root caller");
    Check(![LBXContainerConfigurationStore createPristineDirectory:path licenseOwner:owner error:nil],@"production pristine namespace rejects actual non-root caller");
    Check(![unbound installationContextForTrustedInstaller:nil],@"production installer observation rejects actual non-root caller");
    printf("%s: %lu production role assertions, %lu failures\n",failures?"FAIL":"PASS",(unsigned long)checks,(unsigned long)failures);
#endif
    return failures?1:0;
}}
