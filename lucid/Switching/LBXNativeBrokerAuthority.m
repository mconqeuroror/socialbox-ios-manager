#import "LBXNativeBrokerAuthority.h"
#import "LBXNativeIsolationJournal.h"
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <mach/mach_time.h>
#include <math.h>
#include <string.h>
#include <unistd.h>
#ifndef LBX_NATIVE_BROKER_TESTING
#define LBX_NATIVE_BROKER_TESTING 0
#endif

static NSString *const Instagram=@"com.burbn.instagram";
static NSString *const Facebook=@"com.facebook.Facebook";
double LBXNativeBrokerClock(void){mach_timebase_info_data_t scale;mach_timebase_info(&scale);return scale.denom?(double)mach_continuous_time()*scale.numer/scale.denom/1e9:NAN;}
static BOOL Fail(NSError **error,NSInteger code){
    if(error)*error=[NSError errorWithDomain:@"com.socialbox.native-broker-authority" code:code userInfo:@{NSLocalizedDescriptionKey:
        code==2?@"Root broker journal is required":code==3?@"Broker admission is closed":code==4?@"Process or code identity is not current":code==5?@"Broker deadline exceeded":code==6?@"Process already carries an immutable assignment":@"Broker authority refused the operation"}];
    return NO;
}
static BOOL Budget(double deadline){double now=LBXNativeBrokerClock();return isfinite(now)&&isfinite(deadline)&&deadline>now&&deadline-now<=120;}
static NSDictionary *Immutable(id value){if(![NSJSONSerialization isValidJSONObject:value])return nil;NSData *bytes=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];return bytes.length&&bytes.length<=8*1024*1024?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;}
static BOOL AppID(NSString *value){return [value isEqual:Instagram]||[value isEqual:Facebook];}
static BOOL CID(NSString *value){if(![value isKindOfClass:NSString.class]||!value.length||value.length>19)return NO;if([value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location!=NSNotFound)return NO;if(value.length>1&&[value hasPrefix:@"0"])return NO;return YES;}
static NSString *Hex(const unsigned char *digest,NSUInteger length){NSMutableString *hex=[NSMutableString string];for(NSUInteger i=0;i<length;i++)[hex appendFormat:@"%02x",digest[i]];return hex;}
static NSString *FileDigest(NSString *path){
    if(![path isKindOfClass:NSString.class]||![path hasPrefix:@"/"]||path.length>=4096)return nil;
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);struct stat s;if(fd<0||fstat(fd,&s)||!S_ISREG(s.st_mode)||s.st_nlink!=1||s.st_size<=0||s.st_size>64*1024*1024){if(fd>=0)close(fd);return nil;}
    CC_SHA256_CTX hash;CC_SHA256_Init(&hash);char buffer[65536];uint64_t offset=0;unsigned interrupts=0;
    while(offset<(uint64_t)s.st_size){ssize_t n=read(fd,buffer,sizeof(buffer));if(n<0&&errno==EINTR&&++interrupts<=4)continue;if(n<=0){close(fd);return nil;}CC_SHA256_Update(&hash,buffer,(CC_LONG)n);offset+=(uint64_t)n;}
    close(fd);unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(digest,&hash);return Hex(digest,sizeof(digest));
}
static NSString *TokenKey(audit_token_t token){unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256((const unsigned char *)&token,sizeof(token),digest);return Hex(digest,sizeof(digest));}
#if LBX_NATIVE_BROKER_TESTING
static NSDictionary *(^KernelObserver)(audit_token_t);
static NSString *TestBoot;
static NSDictionary *TestObservation(audit_token_t token){NSDictionary *(^observer)(audit_token_t);NSString *boot;@synchronized(LBXNativeBrokerProcess.class){observer=KernelObserver;boot=TestBoot;}NSDictionary *raw=observer?observer(token):nil;if(![raw isKindOfClass:NSDictionary.class])return nil;
    NSMutableDictionary *row=[raw mutableCopy];if(boot.length)row[@"bootIdentity"]=boot;return Immutable(row);}
#endif
static NSDictionary *LiveObservation(audit_token_t token){
#if LBX_NATIVE_BROKER_TESTING
    return TestObservation(token);
#else
    (void)token;return nil;
#endif
}
@interface LBXNativeBrokerCodeBinding ()
@property(nonatomic,copy)NSString *applicationID,*executable,*digest;
@property(nonatomic)BOOL testing;
- (instancetype)initPrivate;
@end
@interface LBXNativeBrokerProcess ()
@property(nonatomic,copy)NSString *applicationID,*processKey,*bootIdentity,*executable;
@property(nonatomic,copy)NSDictionary *observation;
@property(nonatomic,strong)LBXNativeBrokerCodeBinding *binding;
@property(nonatomic)audit_token_t token;
@property(nonatomic)BOOL testing;
- (instancetype)initPrivate;
@end
@interface LBXNativeBrokerEpoch ()
@property(nonatomic,copy)NSString *containerID,*epochID;
- (instancetype)initPrivate;
@end
@interface LBXNativeBrokerLease ()
@property(nonatomic,copy)NSString *containerID,*epochID,*applicationID,*leaseID,*processKey;
- (instancetype)initPrivate;
@end
@implementation LBXNativeBrokerCodeBinding
- (instancetype)initPrivate{return [super init];}
- (BOOL)matchesCurrentCode:(NSError **)error {
    NSString *digest=FileDigest(_executable);if(!digest||![digest isEqual:_digest])return Fail(error,4);
#if !LBX_NATIVE_BROKER_TESTING
    if(!_testing){NSDictionary *live=[self.class liveRegistration:_applicationID];if(![live[@"executable"] isEqual:_executable])return Fail(error,4);}
#endif
    return YES;
}
+ (NSDictionary *)liveRegistration:(NSString *)bundleID {
    static dispatch_once_t once;dispatch_once(&once,^{if(!dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices",RTLD_NOW))dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",RTLD_NOW);});
    Class cls=NSClassFromString(@"LSApplicationProxy");SEL lookup=NSSelectorFromString(@"applicationProxyForIdentifier:"),executable=NSSelectorFromString(@"canonicalExecutablePath");
    if(![cls respondsToSelector:lookup])return nil;id proxy=((id(*)(id,SEL,id))objc_msgSend)(cls,lookup,bundleID);
    id path=[proxy respondsToSelector:executable]?((id(*)(id,SEL))objc_msgSend)(proxy,executable):nil;
    NSString *normalized=[path isKindOfClass:NSString.class]?([path hasPrefix:@"/var/"]?[@"/private" stringByAppendingString:path]:path):nil;
    return normalized?@{@"executable":normalized}:nil;
}
static LBXNativeBrokerCodeBinding *Binding(NSString *bundleID,NSString *path,BOOL testing,NSError **error){
    if(!AppID(bundleID)||!path.length){Fail(error,1);return nil;}NSString *digest=FileDigest(path);if(!digest){Fail(error,4);return nil;}
    LBXNativeBrokerCodeBinding *binding=[[LBXNativeBrokerCodeBinding alloc] initPrivate];binding.applicationID=bundleID;binding.executable=path;binding.digest=digest;binding.testing=testing;return binding;
}
+ (instancetype)observeApplication:(NSString *)bundleID error:(NSError **)error {
    if(error)*error=nil;NSDictionary *live=[self liveRegistration:bundleID];return Binding(bundleID,live[@"executable"],NO,error);
}
#if LBX_NATIVE_BROKER_TESTING
+ (instancetype)testObserveApplication:(NSString *)bundleID executable:(NSString *)path error:(NSError **)error {if(error)*error=nil;return Binding(bundleID,path,YES,error);}
#endif
@end
@implementation LBXNativeBrokerProcess
- (instancetype)initPrivate{return [super init];}
- (BOOL)matchesCurrentProcess:(NSError **)error {
    if(![_binding matchesCurrentCode:error])return NO;NSDictionary *live=LiveObservation(_token);if(!live||![live isEqual:_observation])return Fail(error,4);return YES;
}
+ (instancetype)observeAuditToken:(audit_token_t)token codeBinding:(LBXNativeBrokerCodeBinding *)binding error:(NSError **)error {
    if(error)*error=nil;if(!binding){Fail(error,1);return nil;}NSDictionary *live=LiveObservation(token);if(!live){Fail(error,4);return nil;}
    if(![live[@"executable"] isEqual:binding.executable]||![binding matchesCurrentCode:error])return nil;
    NSString *boot=live[@"bootIdentity"];if(![boot isKindOfClass:NSString.class]||!boot.length){Fail(error,4);return nil;}
    NSDictionary *keyMaterial=Immutable(@{@"token":TokenKey(token),@"bootIdentity":boot,@"pid":live[@"pid"],@"pidversion":live[@"pidversion"],@"birth":live[@"birth"],@"applicationID":binding.applicationID,@"digest":binding.digest});
    if(!keyMaterial){Fail(error,1);return nil;}unsigned char digest[CC_SHA256_DIGEST_LENGTH];NSData *bytes=[NSJSONSerialization dataWithJSONObject:keyMaterial options:NSJSONWritingSortedKeys error:nil];CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest);
    LBXNativeBrokerProcess *process=[[LBXNativeBrokerProcess alloc] initPrivate];process.token=token;process.binding=binding;process.applicationID=binding.applicationID;process.observation=live;process.bootIdentity=boot;process.executable=binding.executable;process.processKey=Hex(digest,sizeof(digest));
#if LBX_NATIVE_BROKER_TESTING
    process.testing=YES;
#endif
    return process;
}
#if LBX_NATIVE_BROKER_TESTING
+ (void)testSetKernelObservation:(NSDictionary *(^)(audit_token_t))observer {@synchronized(self){KernelObserver=[observer copy];}}
+ (void)testSetBootIdentity:(NSString *)boot {@synchronized(self){TestBoot=boot;}}
#endif
@end
@implementation LBXNativeBrokerEpoch
- (instancetype)initPrivate{return [super init];}
@end
@implementation LBXNativeBrokerLease
- (instancetype)initPrivate{return [super init];}
@end
@interface LBXNativeBrokerAuthority ()
@property(nonatomic,strong)LBXNativeIsolationJournal *journal;
@property(nonatomic,copy)NSDictionary *envelope;
@property(nonatomic,strong)NSMutableDictionary *leases;
@property(nonatomic)BOOL testing;
- (instancetype)initPrivate;
@end
@implementation LBXNativeBrokerAuthority
- (instancetype)initPrivate{return [super init];}
- (NSDictionary *)payload {
    NSDictionary *body=_envelope[@"payload"];return [body isKindOfClass:NSDictionary.class]?body:nil;
}
- (NSDictionary *)safeStatus {
    @synchronized(self){NSDictionary *payload=[self payload];
        return Immutable(@{@"kind":@"native-broker-authority",@"admissionOpen":@([payload[@"admissionOpen"] isEqual:@YES]),@"hasPreparedEpoch":@(payload[@"epoch"]!=[NSNull null]&&payload[@"epoch"]!=nil),@"assignmentCount":@([payload[@"assignments"] count]),@"tombstoneCount":@([payload[@"tombstones"] count]),@"leaseCount":@(_leases.count),@"runtimeAccepted":@NO,@"brokerIsolationVerified":@NO})?:@{};}
}
- (NSString *)description{return @"<LBXNativeBrokerAuthority>";}
- (NSString *)debugDescription{return self.description;}
- (BOOL)writePayload:(NSDictionary *)payload error:(NSError **)error {
    NSDictionary *frozen=Immutable(payload);if(!frozen)return Fail(error,1);
    if(![_journal compareRecord:_envelope replaceWith:frozen error:error])return NO;
    _envelope=_journal.currentRecord;return _envelope!=nil;
}
- (BOOL)deadline:(double)deadline error:(NSError **)error {return Budget(deadline)?YES:Fail(error,5);}
static NSArray *MergeTombstones(NSArray *assignments,NSArray *tombstones){
    NSMutableArray *rows=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
    for(NSArray *source in @[tombstones?:@[],assignments?:@[]])for(NSDictionary *row in source){NSString *key=row[@"processKey"];if(![row isKindOfClass:NSDictionary.class]||![key isKindOfClass:NSString.class]||[seen containsObject:key])continue;[seen addObject:key];[rows addObject:row];}
    return [rows copy];
}
static LBXNativeBrokerAuthority *Open(LBXNativeIsolationJournal *journal,BOOL testing,NSError **error){
    if(error)*error=nil;if(!journal){Fail(error,2);return nil;}NSError *readError=nil;NSDictionary *current=[journal validatedCurrentRecord:&readError];if(readError){if(error)*error=readError;return nil;}
    NSDictionary *payload=nil;
    if(!current){
        payload=Immutable(@{@"kind":@"native-broker-authority",@"formatVersion":@1,@"admissionOpen":@NO,@"epoch":[NSNull null],@"assignments":@[],@"tombstones":@[]});
        if(!payload||![journal compareRecord:nil replaceWith:payload error:error])return nil;current=journal.currentRecord;
    }
    NSDictionary *body=current[@"payload"];if(![body isKindOfClass:NSDictionary.class]||![body[@"kind"] isEqual:@"native-broker-authority"]||![body[@"formatVersion"] isEqual:@1]||![body[@"assignments"] isKindOfClass:NSArray.class]||![body[@"tombstones"] isKindOfClass:NSArray.class]){Fail(error,1);return nil;}
    NSArray *tombstones=MergeTombstones(body[@"assignments"],body[@"tombstones"]);
    NSDictionary *closed=Immutable(@{@"kind":@"native-broker-authority",@"formatVersion":@1,@"admissionOpen":@NO,@"epoch":body[@"epoch"]?:[NSNull null],@"assignments":@[],@"tombstones":tombstones});
    if(!closed){Fail(error,1);return nil;}
    if(![body[@"admissionOpen"] isEqual:@NO]||[body[@"assignments"] count]||![tombstones isEqual:body[@"tombstones"]]){
        if(![journal compareRecord:current replaceWith:closed error:error])return nil;current=journal.currentRecord;
    }
    LBXNativeBrokerAuthority *authority=[[LBXNativeBrokerAuthority alloc] initPrivate];authority.journal=journal;authority.envelope=current;authority.leases=[NSMutableDictionary dictionary];authority.testing=testing;return authority;
}
+ (instancetype)openJournal:(LBXNativeIsolationJournal *)journal error:(NSError **)error {return Open(journal,NO,error);}
#if LBX_NATIVE_BROKER_TESTING
+ (instancetype)testOpenJournal:(LBXNativeIsolationJournal *)journal error:(NSError **)error {return Open(journal,YES,error);}
#endif
- (LBXNativeBrokerEpoch *)prepareContainerID:(NSString *)containerID beforeDeadline:(double)deadline error:(NSError **)error {
    @synchronized(self){
        if(error)*error=nil;if(![self deadline:deadline error:error])return nil;NSDictionary *payload=[self payload];
        if([payload[@"admissionOpen"] isEqual:@YES]||_leases.count){Fail(error,3);return nil;}if(!CID(containerID)){Fail(error,1);return nil;}
        NSString *epochID=NSUUID.UUID.UUIDString.lowercaseString;NSDictionary *epoch=@{@"containerID":containerID,@"epochID":epochID,@"admitted":@NO};
        if(![self writePayload:@{@"kind":@"native-broker-authority",@"formatVersion":@1,@"admissionOpen":@NO,@"epoch":epoch,@"assignments":payload[@"assignments"],@"tombstones":payload[@"tombstones"]} error:error])return nil;
        LBXNativeBrokerEpoch *result=[[LBXNativeBrokerEpoch alloc] initPrivate];result.containerID=containerID;result.epochID=epochID;return result;
    }
}
- (BOOL)admitEpoch:(LBXNativeBrokerEpoch *)epoch beforeDeadline:(double)deadline authorization:(BOOL (^)(void))authorization error:(NSError **)error {
    @synchronized(self){
        if(error)*error=nil;if(![self deadline:deadline error:error])return NO;NSDictionary *payload=[self payload];NSDictionary *prepared=payload[@"epoch"];
        if(_leases.count||[payload[@"admissionOpen"] isEqual:@YES])return Fail(error,3);
        if(!epoch||![prepared isKindOfClass:NSDictionary.class]||![prepared[@"containerID"] isEqual:epoch.containerID]||![prepared[@"epochID"] isEqual:epoch.epochID]||[prepared[@"admitted"] isEqual:@YES])return Fail(error,1);
        if(!authorization||!authorization())return Fail(error,1);
        NSDictionary *admitted=@{@"containerID":epoch.containerID,@"epochID":epoch.epochID,@"admitted":@YES};
        return [self writePayload:@{@"kind":@"native-broker-authority",@"formatVersion":@1,@"admissionOpen":@YES,@"epoch":admitted,@"assignments":payload[@"assignments"],@"tombstones":payload[@"tombstones"]} error:error];
    }
}
- (BOOL)assignVerifiedLaunch:(LBXNativeBrokerProcess *)process epoch:(LBXNativeBrokerEpoch *)epoch beforeDeadline:(double)deadline authorization:(BOOL (^)(void))authorization error:(NSError **)error {
    @synchronized(self){
        if(error)*error=nil;if(![self deadline:deadline error:error])return NO;NSDictionary *payload=[self payload];NSDictionary *current=payload[@"epoch"];
        if(![payload[@"admissionOpen"] isEqual:@YES])return Fail(error,3);
        if(!process||!epoch||![current isKindOfClass:NSDictionary.class]||![current[@"admitted"] isEqual:@YES]||![current[@"containerID"] isEqual:epoch.containerID]||![current[@"epochID"] isEqual:epoch.epochID]||![process.applicationID isEqual:process.binding.applicationID])return Fail(error,1);
        if(![process matchesCurrentProcess:error])return NO;if(!authorization||!authorization())return Fail(error,1);
        for(NSArray *source in @[payload[@"assignments"],payload[@"tombstones"]])for(NSDictionary *row in source)if([row[@"processKey"] isEqual:process.processKey])return Fail(error,6);
        NSDictionary *row=Immutable(@{@"processKey":process.processKey,@"applicationID":process.applicationID,@"containerID":epoch.containerID,@"epochID":epoch.epochID,@"bootIdentity":process.bootIdentity});
        if(!row)return Fail(error,1);NSMutableArray *assignments=[payload[@"assignments"] mutableCopy];[assignments addObject:row];
        return [self writePayload:@{@"kind":@"native-broker-authority",@"formatVersion":@1,@"admissionOpen":@YES,@"epoch":current,@"assignments":assignments,@"tombstones":payload[@"tombstones"]} error:error];
    }
}
- (LBXNativeBrokerLease *)beginRequestForProcess:(LBXNativeBrokerProcess *)process beforeDeadline:(double)deadline error:(NSError **)error {
    @synchronized(self){
        if(error)*error=nil;if(![self deadline:deadline error:error])return nil;NSDictionary *payload=[self payload];NSDictionary *current=payload[@"epoch"];
        if(![payload[@"admissionOpen"] isEqual:@YES]||![current isKindOfClass:NSDictionary.class]||![current[@"admitted"] isEqual:@YES]){Fail(error,3);return nil;}
        if(!process||![process matchesCurrentProcess:error])return nil;
        NSDictionary *assignment=nil;for(NSDictionary *row in payload[@"assignments"])if([row[@"processKey"] isEqual:process.processKey])assignment=row;
        if(!assignment||![assignment[@"applicationID"] isEqual:process.applicationID]||![assignment[@"containerID"] isEqual:current[@"containerID"]]||![assignment[@"epochID"] isEqual:current[@"epochID"]]){Fail(error,4);return nil;}
        NSString *leaseID=NSUUID.UUID.UUIDString.lowercaseString;if(_leases[leaseID]){Fail(error,1);return nil;}
        LBXNativeBrokerLease *lease=[[LBXNativeBrokerLease alloc] initPrivate];lease.leaseID=leaseID;lease.applicationID=process.applicationID;lease.containerID=assignment[@"containerID"];lease.epochID=assignment[@"epochID"];lease.processKey=process.processKey;
        _leases[leaseID]=lease;return lease;
    }
}
- (BOOL)endRequest:(LBXNativeBrokerLease *)lease error:(NSError **)error {
    @synchronized(self){
        if(error)*error=nil;if(!lease.leaseID.length||_leases[lease.leaseID]!=lease)return Fail(error,1);[_leases removeObjectForKey:lease.leaseID];return YES;
    }
}
- (BOOL)closeAdmissionBeforeDeadline:(double)deadline error:(NSError **)error {
    @synchronized(self){
        if(error)*error=nil;if(![self deadline:deadline error:error])return NO;NSDictionary *payload=[self payload];
        if([payload[@"admissionOpen"] isEqual:@NO])return YES;
        return [self writePayload:@{@"kind":@"native-broker-authority",@"formatVersion":@1,@"admissionOpen":@NO,@"epoch":payload[@"epoch"],@"assignments":payload[@"assignments"],@"tombstones":payload[@"tombstones"]} error:error];
    }
}
- (BOOL)waitForLeasesBeforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;
    for(;;){@synchronized(self){if(!_leases.count)return YES;if(!Budget(deadline))return Fail(error,5);}usleep(2000);}
}
@end
