#import "LBXContainerRootPendingStore.h"
#import "LBXContainerConfiguration.h"
#import "LBXContainerConfigurationStore.h"
#import "LBXContainerMutationIPC.h"
#import "../Authorization/LBXLicenseOwner.h"
#import "../Authorization/LBXLicenseInstallationEstablishment.h"
#import "../../shared/RBXStorageGate.h"
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/file.h>
#include <dirent.h>
#include <limits.h>
#include <string.h>

#if LBX_CONTAINER_ROOT_PENDING_TESTING
static NSString *EstablishmentStop;
#endif
static BOOL EstablishmentBoundary(NSString *name,NSError **error);
static BOOL Fail(NSError **error,NSInteger code){
    if(error){*error=[NSError errorWithDomain:@"com.socialbox.root-pending" code:code
        userInfo:@{NSLocalizedDescriptionKey:code==2?@"Exact pending state changed":code==3?@"Invalid pending state":code==4?@"Fresh paired root operation is required":@"Private root pending state is unavailable"}];}
    return NO;
}
static BOOL EstablishmentBoundary(NSString *name,NSError **error){
#if LBX_CONTAINER_ROOT_PENDING_TESTING
    if([EstablishmentStop isEqual:name])return Fail(error,1);
#else
    (void)name;(void)error;
#endif
    return YES;
}
static uid_t Owner(void){
#if LBX_CONTAINER_ROOT_PENDING_TESTING
    return geteuid();
#else
    return 0;
#endif
}
static BOOL Caller(void){
#if LBX_CONTAINER_ROOT_PENDING_TESTING
    return getuid()==geteuid();
#else
    return getuid()==0&&geteuid()==0;
#endif
}
static BOOL Exact(id v,NSArray *keys){if(![v isKindOfClass:NSDictionary.class]||[v count]!=keys.count)return NO;
    for(id key in v)if(![key isKindOfClass:NSString.class])return NO;return [[NSSet setWithArray:[v allKeys]] isEqual:[NSSet setWithArray:keys]];}
static BOOL Integer(id n){return [n isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)n)!=CFBooleanGetTypeID()&&
    !CFNumberIsFloatType((__bridge CFNumberRef)n)&&[n longLongValue]>=0&&[n unsignedLongLongValue]<=LLONG_MAX;}
static BOOL Epoch(id v){return [v isKindOfClass:NSString.class]&&[v length]<=19&&
    NSEqualRanges([v rangeOfString:@"[1-9][0-9]*" options:NSRegularExpressionSearch],NSMakeRange(0,[v length]))&&
    [v longLongValue]>0&&[[NSString stringWithFormat:@"%lld",[v longLongValue]] isEqual:v];}
static NSString *Next(NSString *v){return Epoch(v)&&v.longLongValue<LLONG_MAX?[NSString stringWithFormat:@"%lld",v.longLongValue+1]:nil;}
static NSData *JSON(id v){return [NSJSONSerialization isValidJSONObject:v]?[NSJSONSerialization dataWithJSONObject:v options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:nil]:nil;}
static NSDictionary *Copy(id v){NSData *d=JSON(v);return d.length&&d.length<=65536?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:nil;}
static NSString *SHA(id v){NSData *d=JSON(v);if(!d)return nil;unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(d.bytes,(CC_LONG)d.length,hash);
    NSMutableString *s=[NSMutableString string];for(NSUInteger i=0;i<sizeof(hash);i++)[s appendFormat:@"%02x",hash[i]];return s;}
static NSArray *Applications(NSArray *v){
    NSMutableArray *a=[NSMutableArray array];
    for(NSString *app in @[@"com.burbn.instagram",@"com.facebook.Facebook",@"com.atebits.Tweetie2"]){
        if([v containsObject:app])[a addObject:app];
    }
    return [a copy];
}
static BOOL SlotInput(id slot,id input){NSDictionary *valid=LBXContainerMutationIPCProjectSlot(slot);if(!valid||![valid isEqual:slot]||
    ![input isKindOfClass:NSDictionary.class]||!Epoch(input[@"expectedEmptyEpoch"])||![input[@"stageRequestID"] isEqual:slot[@"stageRequestID"]]||
    ![Next(input[@"expectedEmptyEpoch"]) isEqual:slot[@"epoch"]])return NO;
    if([slot[@"operation"] isEqual:@"create"]){id c=input[@"choices"];
        return Exact(input,@[@"expectedEmptyEpoch",@"stageRequestID",@"choices"])&&Exact(c,@[@"name",@"applications",@"manualIdentifiers",@"proxyReference"])&&
            LBXContainerConfigurationValidateChoices(c[@"name"],c[@"applications"],c[@"manualIdentifiers"]==NSNull.null?nil:c[@"manualIdentifiers"],c[@"proxyReference"])&&
            [slot[@"configuration"][@"name"] isEqual:c[@"name"]]&&[slot[@"configuration"][@"applications"] isEqual:Applications(c[@"applications"])]&&
            [slot[@"configuration"][@"proxyReference"] isEqual:c[@"proxyReference"]]&&
            (c[@"manualIdentifiers"]==NSNull.null?[slot[@"configuration"][@"identifierMode"] isEqual:@"random"]:
             ([slot[@"configuration"][@"identifierMode"] isEqual:@"manual"]&&[slot[@"configuration"][@"identifiers"] isEqual:c[@"manualIdentifiers"]]));
    }
    if([slot[@"operation"] isEqual:@"retire"])return Exact(input,@[@"expectedEmptyEpoch",@"stageRequestID",@"expected"])&&
        [input[@"expected"] isEqual:slot[@"expected"]]&&[input[@"expected"] isEqual:slot[@"configuration"]];
    return Exact(input,@[@"expectedEmptyEpoch",@"stageRequestID",@"expected",@"configuration"])&&
        [input[@"configuration"] isEqual:slot[@"configuration"]]&&[input[@"expected"] isEqual:slot[@"expected"]];
}
static BOOL Pending(id v){return Exact(v,@[@"slot",@"input",@"attempt"])&&Integer(v[@"attempt"])&&SlotInput(v[@"slot"],v[@"input"]);}
static BOOL Completed(id v){return Exact(v,@[@"slot",@"input",@"proofSHA256"])&&SlotInput(v[@"slot"],v[@"input"])&&[v[@"proofSHA256"] isEqual:SHA(v[@"slot"][@"configuration"])];}
static BOOL State(id v,NSDictionary *context,NSDictionary *marker){if(!Exact(v,@[@"formatVersion",@"context",@"marker",@"epoch",@"pending",@"completed"])||!Integer(v[@"formatVersion"])||
    ![v[@"formatVersion"] isEqual:@1]||![v[@"context"] isEqual:context]||![v[@"marker"] isEqual:marker]||!Epoch(v[@"epoch"]))return NO;
    id p=v[@"pending"],c=v[@"completed"];if(p!=NSNull.null&&(!Pending(p)||[p[@"slot"][@"epoch"] longLongValue]>LLONG_MAX-[p[@"attempt"] longLongValue]||
        [p[@"slot"][@"epoch"] longLongValue]+[p[@"attempt"] longLongValue]!=[v[@"epoch"] longLongValue]))return NO;
    if(p==NSNull.null&&c==NSNull.null&&![v[@"epoch"] isEqual:@"1"])return NO;
    if(c!=NSNull.null&&(!Completed(c)||[c[@"slot"][@"epoch"] longLongValue]>=[v[@"epoch"] longLongValue]))return NO;
    if(p!=NSNull.null&&c!=NSNull.null&&([c[@"slot"][@"epoch"] longLongValue]>=[p[@"slot"][@"epoch"] longLongValue]||[c[@"slot"][@"token"] isEqual:p[@"slot"][@"token"]]||
        [c[@"slot"][@"stageRequestID"] isEqual:p[@"slot"][@"stageRequestID"]]))return NO;
    return YES;
}
static BOOL Transition(NSDictionary *prior,NSDictionary *next){if(![Next(prior[@"epoch"]) isEqual:next[@"epoch"]]||![prior[@"context"] isEqual:next[@"context"]]||![prior[@"marker"] isEqual:next[@"marker"]])return NO;
    id p=prior[@"pending"],q=next[@"pending"],c=prior[@"completed"],d=next[@"completed"];
    if(p==NSNull.null)return q!=NSNull.null&&[q[@"attempt"] isEqual:@0]&&[q[@"slot"][@"epoch"] isEqual:next[@"epoch"]]&&
        [q[@"input"][@"expectedEmptyEpoch"] isEqual:prior[@"epoch"]]&&[c isEqual:d];
    if(q!=NSNull.null)return [p[@"slot"] isEqual:q[@"slot"]]&&[p[@"input"] isEqual:q[@"input"]]&&[c isEqual:d]&&
        [p[@"attempt"] longLongValue]<LLONG_MAX&&[q[@"attempt"] longLongValue]==[p[@"attempt"] longLongValue]+1;
    return d!=NSNull.null&&[d[@"slot"] isEqual:p[@"slot"]]&&[d[@"input"] isEqual:p[@"input"]]&&[d[@"proofSHA256"] isEqual:SHA(p[@"slot"][@"configuration"])];
}
static BOOL Safe(int fd,BOOL dir){struct stat n;return fd>=0&&!fstat(fd,&n)&&(dir?S_ISDIR(n.st_mode):S_ISREG(n.st_mode))&&n.st_uid==Owner()&&
    n.st_gid==getegid()&&(n.st_mode&07777)==(dir?0700:0600)&&(dir||n.st_nlink==1)&&RBXStorageGateNoACL(fd);}
static BOOL Parent(int fd){struct stat n;if(fd<0||fstat(fd,&n)||!S_ISDIR(n.st_mode)||!RBXStorageGateNoACL(fd))return NO;
#if LBX_CONTAINER_ROOT_PENDING_TESTING
    return (n.st_uid==0||n.st_uid==Owner())&&(!(n.st_mode&0022)||(n.st_uid==0&&(n.st_mode&S_ISVTX)));
#else
    return n.st_uid==0&&!(n.st_mode&0022);
#endif
}
static NSDictionary *Node(int fd){struct stat n;if(fstat(fd,&n))return nil;return @{@"device":@(n.st_dev),@"inode":@(n.st_ino),@"owner":@(n.st_uid),@"group":@(n.st_gid),@"mode":@(n.st_mode&07777)};}
static NSDictionary *File(int fd){struct stat n;if(fstat(fd,&n))return nil;NSMutableDictionary *v=[Node(fd) mutableCopy];[v addEntriesFromDictionary:@{@"size":@(n.st_size),@"links":@(n.st_nlink),
    @"mtime":@(n.st_mtimespec.tv_sec),@"mtimeNS":@(n.st_mtimespec.tv_nsec),@"ctime":@(n.st_ctimespec.tv_sec),@"ctimeNS":@(n.st_ctimespec.tv_nsec)}];return [v copy];}
static BOOL Same(int dir,NSString *name,int fd){struct stat a,b;return fd>=0&&!fstat(fd,&a)&&!(dir<0?lstat("/",&b):fstatat(dir,name.fileSystemRepresentation,&b,AT_SYMLINK_NOFOLLOW))&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino;}
static NSString *Physical(NSString *path){char value[PATH_MAX];return path.isAbsolutePath&&realpath(path.fileSystemRepresentation,value)?[NSString stringWithUTF8String:value]:nil;}

@interface LBXContainerRootPendingStore ()
- (instancetype)initPrivate;
+ (nullable instancetype)openDirectory:(NSString *)directory licenseOwner:(LBXLicenseOwner *)owner
    configurationStore:(LBXContainerConfigurationStore *)configurations optionalInstallation:(nullable LBXLicenseInstallationEstablishment *)installation
    create:(BOOL)create beforeDeadline:(double)deadline error:(NSError **)error;
- (BOOL)current:(double)deadline;
- (BOOL)lockCurrent:(int)fd deadline:(double)deadline;
- (NSDictionary *)readState:(NSError **)error;
- (NSDictionary *)readStateAllowingStage:(nullable NSString *)stage descriptor:(int)fd error:(NSError **)error;
- (BOOL)publish:(NSDictionary *)next replacing:(NSDictionary *)prior lock:(int)fd deadline:(double)deadline error:(NSError **)error;
@end
@interface LBXContainerRootPendingTransaction ()
- (instancetype)initWithStore:(LBXContainerRootPendingStore *)store state:(NSDictionary *)state lock:(int)lock deadline:(double)deadline;
- (void)invalidate;
@end
@implementation LBXContainerRootPendingTransaction {LBXContainerRootPendingStore *_store;NSDictionary *_privateState;int _lock;double _deadline;BOOL _active;}
- (instancetype)initWithStore:(LBXContainerRootPendingStore *)store state:(NSDictionary *)state lock:(int)lock deadline:(double)deadline {
    if((self=[super init])){_store=store;_privateState=state;_lock=lock;_deadline=deadline;_active=YES;}return self;}
- (NSDictionary *)privateState{return _privateState;}
- (void)invalidate{_active=NO;_lock=-1;_store=nil;}
- (BOOL)publishState:(NSDictionary *)next error:(NSError **)error {if(!_active)return Fail(error,4);NSDictionary *copy=Copy(next);
    if(!copy)return Fail(error,3);if(![_store publish:copy replacing:_privateState lock:_lock deadline:_deadline error:error])return NO;_privateState=copy;return YES;}
- (NSString *)description{return @"<LBXContainerRootPendingTransaction: private synchronous metadata>";}
- (NSString *)debugDescription{return self.description;}
@end
@implementation LBXContainerRootPendingStore {LBXLicenseInstallationEstablishment *_installation;LBXLicenseOwner *_owner;LBXContainerConfigurationStore *_configurations;NSDictionary *_context,*_rootNode,*_lockNode,*_markerNode,*_markerFile;
    NSString *_path,*_physical,*_leaf,*_marker;NSArray *_parents,*_names,*_nodes;int _root,_markerFD;
#if LBX_CONTAINER_ROOT_PENDING_TESTING
    NSString *_stop;
#endif
}
- (instancetype)initPrivate{if((self=[super init])){_root=-1;_markerFD=-1;}return self;}
- (void)dealloc{for(NSNumber *fd in _parents)close(fd.intValue);if(_root>=0)close(_root);if(_markerFD>=0)close(_markerFD);}
- (NSString *)description{return @"<LBXContainerRootPendingStore: private root metadata; runtimeAccepted=false>";}
- (NSString *)debugDescription{return self.description;}
- (BOOL)usesLicenseOwner:(LBXLicenseOwner *)owner configurationStore:(LBXContainerConfigurationStore *)configurations{return _owner==owner&&_configurations==configurations;}
- (BOOL)boundary:(NSString *)name error:(NSError **)error{
#if LBX_CONTAINER_ROOT_PENDING_TESTING
    if([_stop isEqual:name])return Fail(error,1);
#else
    (void)name;(void)error;
#endif
    return YES;}
- (BOOL)ancestry{if(!Caller()||![Physical(_path) isEqual:_physical]||!Safe(_root,YES)||![Node(_root) isEqual:_rootNode]||!Same([_parents.lastObject intValue],_leaf,_root))return NO;
    for(NSUInteger i=0;i<_parents.count;i++){
        if(!Parent([_parents[i] intValue])||![Node([_parents[i] intValue]) isEqual:_nodes[i]]||
            !Same(i?[_parents[i-1] intValue]:-1,i?_names[i-1]:@"/",[_parents[i] intValue]))return NO;
    }
    return YES;
}
- (BOOL)current:(double)deadline{return [self ancestry]&&Safe(_markerFD,NO)&&Same([_parents.lastObject intValue],_marker,_markerFD)&&[File(_markerFD) isEqual:_markerFile]&&
    [_owner sourceOperationCurrentBeforeDeadline:deadline]&&
    [[_owner sourcePairingContextBeforeDeadline:deadline error:nil] isEqual:_context[@"pairing"]]&&
    [[_configurations configurationNamespaceContextInCurrentSourceOperationBeforeDeadline:deadline error:nil] isEqual:_context[@"namespace"]]&&
    (!_installation||[[_installation privatePreparedWitnessForLicenseOwner:_owner configurationStore:_configurations pendingDirectory:_path
        inCurrentSourceOperationBeforeDeadline:deadline error:nil] isEqual:_context[@"prepared"]]);}
- (BOOL)lockCurrent:(int)fd deadline:(double)deadline{return [self current:deadline]&&Safe(fd,NO)&&Same(_root,@"pending.lock",fd)&&[Node(fd) isEqual:_lockNode];}
- (NSDictionary *)readFile:(NSString *)name directory:(int)directory{int fd=openat(directory,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);NSDictionary *before=fd>=0?File(fd):nil;
    if(!Safe(fd,NO)||!Same(directory,name,fd)||[before[@"size"] longLongValue]<=0||[before[@"size"] unsignedLongLongValue]>65536){if(fd>=0)close(fd);return nil;}
    NSMutableData *data=[NSMutableData data];char buffer[4096];ssize_t n;unsigned interruptions=0;
    for(;;){n=read(fd,buffer,sizeof(buffer));if(n<0&&errno==EINTR&&++interruptions<=4)continue;if(n<=0)break;
        if(data.length+(NSUInteger)n>65536){n=-1;break;}[data appendBytes:buffer length:(NSUInteger)n];}
    BOOL valid=n==0&&data.length==[before[@"size"] unsignedLongLongValue]&&Safe(fd,NO)&&Same(directory,name,fd)&&[File(fd) isEqual:before];close(fd);
    id value=valid?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;return [value isKindOfClass:NSDictionary.class]&&[JSON(value) isEqual:data]?value:nil;}
- (BOOL)inventoryAllowingStage:(NSString *)stage descriptor:(int)stageFD{int fd=openat(_root,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *dir=fd>=0?fdopendir(fd):NULL;if(!dir){if(fd>=0)close(fd);return NO;}
    BOOL good=YES;NSUInteger count=0;for(;;){errno=0;struct dirent *e=readdir(dir);if(!e){if(errno)good=NO;break;}if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;
        if(++count>(stage?3:2)){good=NO;break;}if(!strcmp(e->d_name,"state.json")||!strcmp(e->d_name,"pending.lock"))continue;
        NSString *name=[NSString stringWithUTF8String:e->d_name];if(!stage||![name isEqual:stage]||!Safe(stageFD,NO)||!Same(_root,stage,stageFD)){good=NO;break;}}
    closedir(dir);return good&&count==(stage?3:2);}
- (NSDictionary *)readState:(NSError **)error{return [self readStateAllowingStage:nil descriptor:-1 error:error];}
- (NSDictionary *)readStateAllowingStage:(NSString *)stage descriptor:(int)fd error:(NSError **)error {
    if(!Safe(_markerFD,NO)||!Same([_parents.lastObject intValue],_marker,_markerFD)||![File(_markerFD) isEqual:_markerFile]){Fail(error,1);return nil;}
    NSDictionary *marker=[self readFile:_marker directory:[_parents.lastObject intValue]];
    NSDictionary *state=[self readFile:@"state.json" directory:_root];
    if(![self inventoryAllowingStage:stage descriptor:fd]||!Exact(marker,@[@"formatVersion",@"context",@"root"])||!Integer(marker[@"formatVersion"])||![marker[@"formatVersion"] isEqual:@1]||
        ![marker[@"context"] isEqual:_context]||![marker[@"root"] isEqual:_rootNode]||!State(state,_context,_markerFile)||
        !Safe(_markerFD,NO)||!Same([_parents.lastObject intValue],_marker,_markerFD)||![File(_markerFD) isEqual:_markerFile]){Fail(error,1);return nil;}return state;}
- (BOOL)publish:(NSDictionary *)next replacing:(NSDictionary *)prior lock:(int)lock deadline:(double)deadline error:(NSError **)error {
    if(!State(next,_context,_markerFile)||!Transition(prior,next))return Fail(error,3);
    if(![self lockCurrent:lock deadline:deadline])return Fail(error,4);
    NSDictionary *observed=[self readState:error];if(!observed)return NO;if(![observed isEqual:prior])return Fail(error,2);
    NSData *data=JSON(next);if(!data.length||data.length>65536)return Fail(error,3);
    NSString *temporary=[@"stage-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];int fd=openat(_root,temporary.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    BOOL ok=Safe(fd,NO);NSDictionary *held=ok?Node(fd):nil;NSUInteger offset=0;unsigned interruptions=0;
    while(ok&&offset<data.length){ssize_t n=write(fd,(const char *)data.bytes+offset,data.length-offset);if(n<0&&errno==EINTR&&++interruptions<=4)continue;if(n<=0){ok=NO;break;}offset+=(NSUInteger)n;}
    if(ok)ok=!fsync(fd)&&Safe(fd,NO)&&Same(_root,temporary,fd)&&[Node(fd) isEqual:held]&&[self boundary:@"state_staged" error:error];
    if(ok)ok=[self lockCurrent:lock deadline:deadline]&&[[self readStateAllowingStage:temporary descriptor:fd error:error] isEqual:prior];
    if(ok)ok=!renameat(_root,temporary.fileSystemRepresentation,_root,"state.json");
    BOOL published=ok;if(ok)ok=[self boundary:@"state_renamed" error:error]&&!fsync(_root)&&[self boundary:@"state_synced" error:error];
    if(ok)ok=[self lockCurrent:lock deadline:deadline]&&[[self readState:error] isEqual:next];
    if(!published&&fd>=0&&Same(_root,temporary,fd)&&Safe(fd,NO)&&[Node(fd) isEqual:held])unlinkat(_root,temporary.fileSystemRepresentation,0);
    if(fd>=0)close(fd);return ok?YES:Fail(error,1);
}
- (BOOL)withLockedStateBeforeDeadline:(double)deadline operation:(BOOL (^)(LBXContainerRootPendingTransaction *,NSError **))operation error:(NSError **)error {
    if(error)*error=nil;if(!operation||![self current:deadline])return Fail(error,4);
    int lock=openat(_root,"pending.lock",O_RDWR|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(![self lockCurrent:lock deadline:deadline]||flock(lock,LOCK_EX|LOCK_NB)||![self lockCurrent:lock deadline:deadline]){if(lock>=0)close(lock);return Fail(error,1);}
    LBXContainerRootPendingTransaction *transaction=nil;@try{NSDictionary *state=[self readState:error];if(!state)return NO;
        transaction=[[LBXContainerRootPendingTransaction alloc] initWithStore:self state:state lock:lock deadline:deadline];
        BOOL ok=operation(transaction,error);return ok&&[self lockCurrent:lock deadline:deadline];
    }@finally{[transaction invalidate];flock(lock,LOCK_UN);close(lock);}
}
+ (NSDictionary *)projectState:(NSDictionary *)state {id p=state[@"pending"],c=state[@"completed"];
    if(!State(state,state[@"context"],state[@"marker"]))return nil;
    return LBXContainerMutationIPCProjectState(@{@"epoch":state[@"epoch"],@"pending":p==NSNull.null?NSNull.null:p[@"slot"],
        @"completed":c==NSNull.null?NSNull.null:c[@"slot"]});}
+ (instancetype)openDirectory:(NSString *)directory licenseOwner:(LBXLicenseOwner *)owner configurationStore:(LBXContainerConfigurationStore *)configurations
    create:(BOOL)create beforeDeadline:(double)deadline error:(NSError **)error {
    return [self openDirectory:directory licenseOwner:owner configurationStore:configurations optionalInstallation:nil create:create beforeDeadline:deadline error:error];
}
+ (instancetype)openDirectory:(NSString *)directory licenseOwner:(LBXLicenseOwner *)owner configurationStore:(LBXContainerConfigurationStore *)configurations
    preparedInstallation:(LBXLicenseInstallationEstablishment *)installation create:(BOOL)create beforeDeadline:(double)deadline error:(NSError **)error {
    if(!installation||[installation class]!=NSClassFromString(@"LBXLicenseInstallationEstablishment")){Fail(error,4);return nil;}
    return [self openDirectory:directory licenseOwner:owner configurationStore:configurations optionalInstallation:installation create:create beforeDeadline:deadline error:error];
}
+ (instancetype)openDirectory:(NSString *)directory licenseOwner:(LBXLicenseOwner *)owner configurationStore:(LBXContainerConfigurationStore *)configurations
    optionalInstallation:(LBXLicenseInstallationEstablishment *)installation create:(BOOL)create beforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;if(!Caller()||![directory isKindOfClass:NSString.class]||!directory.isAbsolutePath||directory.length>4096||!owner||![configurations usesLicenseOwner:owner]){Fail(error,4);return nil;}
    NSDictionary *pairing=[owner sourcePairingContextBeforeDeadline:deadline error:error];if(!pairing)return nil;
    NSString *parentPath=Physical(directory.stringByDeletingLastPathComponent),*leaf=directory.lastPathComponent;
    if(!parentPath||!NSEqualRanges([leaf rangeOfString:@"[A-Za-z0-9][A-Za-z0-9_-]{0,79}" options:NSRegularExpressionSearch],NSMakeRange(0,leaf.length))){Fail(error,3);return nil;}
    LBXContainerRootPendingStore *store=[[self alloc] initPrivate];store->_installation=installation;store->_owner=owner;store->_configurations=configurations;store->_path=[directory copy];store->_leaf=leaf;
    store->_physical=[parentPath stringByAppendingPathComponent:leaf];store->_marker=[NSString stringWithFormat:@".%@.socialbox-root-pending-v1.json",leaf];
    NSMutableArray *fds=[NSMutableArray array],*names=[NSMutableArray array],*nodes=[NSMutableArray array];int first=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    BOOL valid=Parent(first);if(first>=0){[fds addObject:@(first)];[nodes addObject:Node(first)];}
    NSArray *parts=[parentPath componentsSeparatedByString:@"/"];for(NSUInteger i=1;valid&&i<parts.count;i++){int parent=[fds.lastObject intValue],fd=openat(parent,[parts[i] fileSystemRepresentation],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(fd>=0){[fds addObject:@(fd)];[names addObject:parts[i]];[nodes addObject:Node(fd)];}valid=Parent(fd)&&Same(parent,parts[i],fd);}
    store->_parents=[fds copy];store->_names=[names copy];store->_nodes=[nodes copy];if(!valid){Fail(error,1);return nil;}
    int parent=[fds.lastObject intValue];struct stat node;BOOL leafExists=!fstatat(parent,leaf.fileSystemRepresentation,&node,AT_SYMLINK_NOFOLLOW);int leafError=errno;
    BOOL markerExists=!fstatat(parent,store->_marker.fileSystemRepresentation,&node,AT_SYMLINK_NOFOLLOW);int markerError=errno;
    BOOL fresh=!leafExists&&!markerExists&&leafError==ENOENT&&markerError==ENOENT;
    if(fresh&&create){valid=[configurations performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(NSDictionary *namespaceContext,NSError **setupError){
        if(![[owner sourcePairingContextBeforeDeadline:deadline error:nil] isEqual:pairing])return Fail(setupError,4);
        NSDictionary *prepared=installation?[installation consumeForInitialPendingWithLicenseOwner:owner configurationStore:configurations namespaceContext:namespaceContext
            pendingDirectory:directory inCurrentSourceOperationBeforeDeadline:deadline error:setupError]:nil;
        if(installation&&!prepared)return NO;
        store->_context=Copy(installation?@{@"pairing":pairing,@"namespace":namespaceContext,@"prepared":prepared}:@{@"pairing":pairing,@"namespace":namespaceContext});
        if(installation&&![[installation reserveInitialPendingWithLicenseOwner:owner configurationStore:configurations namespaceContext:namespaceContext
            pendingDirectory:directory inCurrentSourceOperationBeforeDeadline:deadline error:setupError] isEqual:prepared])return NO;
        __block int setupLock=-1;
        BOOL (^pendingNodesCurrent)(void)=^BOOL{
            return (store->_root<0||[store ancestry])&&(setupLock<0||
                (Safe(setupLock,NO)&&Same(store->_root,@"pending.lock",setupLock)&&[Node(setupLock) isEqual:store->_lockNode]));
        };
        BOOL (^setupCurrent)(void)=^BOOL{
            return pendingNodesCurrent()&&[owner sourceOperationCurrentBeforeDeadline:deadline]&&[[owner sourcePairingContextBeforeDeadline:deadline error:nil] isEqual:pairing]&&
                [configurations verifyHeldEmptyNamespaceContext:namespaceContext inCurrentSourceOperationBeforeDeadline:deadline error:nil]&&
                (!installation||[[installation consumeForInitialPendingWithLicenseOwner:owner configurationStore:configurations namespaceContext:namespaceContext
                    pendingDirectory:directory inCurrentSourceOperationBeforeDeadline:deadline error:nil] isEqual:prepared])&&pendingNodesCurrent();
        };
        if(!setupCurrent()||!EstablishmentBoundary(@"before_pending_mkdir",setupError))return NO;
        if(mkdirat(parent,leaf.fileSystemRepresentation,0700))return Fail(setupError,1);
        store->_root=openat(parent,leaf.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(!Safe(store->_root,YES)||!Same(parent,leaf,store->_root))return Fail(setupError,1);
        store->_rootNode=Node(store->_root);if(!EstablishmentBoundary(@"pending_directory_created",setupError)||!setupCurrent())return NO;int lock=openat(store->_root,"pending.lock",O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
        BOOL ok=Safe(lock,NO)&&Same(store->_root,@"pending.lock",lock);store->_lockNode=ok?Node(lock):nil;setupLock=lock;
        ok=ok&&EstablishmentBoundary(@"pending_lock_created",setupError);
        NSDictionary *marker=@{@"formatVersion":@1,@"context":store->_context,@"root":store->_rootNode};
        // Publish the fixed marker first so its physical inode is part of every
        // durable state. Partial establishment remains closed, never adopted.
        for(NSUInteger index=0;index<2&&ok;index++){
            if(!setupCurrent()){ok=NO;break;}
            NSString *name=index?@"state.json":store->_marker;int destination=index?store->_root:parent;
            NSDictionary *value=index?@{@"formatVersion":@1,@"context":store->_context,@"marker":store->_markerFile?:@{},@"epoch":@"1",@"pending":NSNull.null,@"completed":NSNull.null}:marker;
            NSData *data=JSON(value);
            int fd=openat(destination,name.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);NSUInteger offset=0;unsigned interruptions=0;
            ok=ok&&data.length&&data.length<=65536&&Safe(fd,NO)&&Same(destination,name,fd);
            while(ok&&offset<data.length){if(!setupCurrent()){ok=NO;break;}ssize_t n=write(fd,(const char *)data.bytes+offset,data.length-offset);if(n<0&&errno==EINTR&&++interruptions<=4)continue;if(n<=0){ok=NO;break;}offset+=(NSUInteger)n;}
            ok=ok&&setupCurrent()&&!fsync(fd)&&Safe(fd,NO)&&Same(destination,name,fd)&&setupCurrent()&&!fsync(destination);
            if(ok&&!index){store->_markerNode=Node(fd);store->_markerFile=File(fd);store->_markerFD=fd;fd=-1;}
            if(fd>=0)close(fd);if(ok)ok=EstablishmentBoundary(index?@"pending_state_synced":@"pending_marker_synced",setupError);if(!ok)break;}
        ok=ok&&setupCurrent()&&!fsync(lock)&&setupCurrent()&&!fsync(store->_root)&&setupCurrent()&&!fsync(parent)&&[[owner sourcePairingContextBeforeDeadline:deadline error:nil] isEqual:pairing];
        if(ok&&installation)ok=[[installation consumeForInitialPendingWithLicenseOwner:owner configurationStore:configurations namespaceContext:namespaceContext
            pendingDirectory:directory inCurrentSourceOperationBeforeDeadline:deadline error:setupError] isEqual:prepared];
        if(ok)ok=EstablishmentBoundary(@"pending_established",setupError);if(lock>=0)close(lock);
        return ok?YES:Fail(setupError,1);
    } error:error];if(!valid)return nil;
    }else{if(!leafExists||!markerExists){Fail(error,1);return nil;}
        NSDictionary *namespaceContext=[configurations configurationNamespaceContextInCurrentSourceOperationBeforeDeadline:deadline error:error];if(!namespaceContext)return nil;
        NSDictionary *prepared=installation?[installation privatePreparedWitnessForLicenseOwner:owner configurationStore:configurations pendingDirectory:directory
            inCurrentSourceOperationBeforeDeadline:deadline error:error]:nil;if(installation&&!prepared)return nil;
        store->_context=Copy(installation?@{@"pairing":pairing,@"namespace":namespaceContext,@"prepared":prepared}:@{@"pairing":pairing,@"namespace":namespaceContext});store->_root=openat(parent,leaf.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(!Safe(store->_root,YES)||!Same(parent,leaf,store->_root)){Fail(error,1);return nil;}store->_rootNode=Node(store->_root);
        int lock=openat(store->_root,"pending.lock",O_RDWR|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);valid=Safe(lock,NO)&&Same(store->_root,@"pending.lock",lock);store->_lockNode=valid?Node(lock):nil;if(lock>=0)close(lock);if(!valid){Fail(error,1);return nil;}}
    if(store->_markerFD<0){store->_markerFD=openat(parent,store->_marker.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
        if(!Safe(store->_markerFD,NO)||!Same(parent,store->_marker,store->_markerFD)){Fail(error,1);return nil;}
        store->_markerNode=Node(store->_markerFD);store->_markerFile=File(store->_markerFD);}
    if(![store current:deadline]){Fail(error,4);return nil;}__block BOOL checked=NO;
    if(![store withLockedStateBeforeDeadline:deadline operation:^BOOL(LBXContainerRootPendingTransaction *transaction,NSError **checkError){(void)transaction;(void)checkError;checked=YES;return YES;} error:error]||!checked)return nil;return store;
}
#if LBX_CONTAINER_ROOT_PENDING_TESTING
- (void)testStopAfterBoundary:(NSString *)boundary{_stop=[boundary copy];}
+ (void)testStopEstablishmentAfterBoundary:(NSString *)boundary{EstablishmentStop=[boundary copy];}
#endif
@end
