#import "LBXContainerClosedAllocation.h"
#import "LBXContainerConfiguration.h"
#import "LBXContainerConfigurationStore.h"
#import "LBXContainerIdentitySpecification.h"
#import "../Authorization/LBXLicenseOwner.h"
#import "../Authorization/LBXLicenseIPC.h"
#import "../../shared/RBXStorageGate.h"
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/file.h>
#include <dirent.h>
#include <limits.h>
#include <math.h>
#include <string.h>

static BOOL Fail(NSError **error,NSInteger code) {
    if(error)*error=[NSError errorWithDomain:@"com.socialbox.closed-allocation" code:code userInfo:@{
        NSLocalizedDescriptionKey:code==2?@"Saved configuration or identity reservation conflicts":
        code==3?@"Closed allocation input is invalid or unsupported":
        code==4?@"Closed allocation is pending; exact recovery is required":
        code==5?@"Fresh source authorization and an unexpired operation are required":
        @"Private closed allocation storage is unavailable; recovery is required"}];
    return NO;
}
static uid_t Owner(void) {
#if LBX_CONTAINER_CLOSED_ALLOCATION_TESTING
    return geteuid();
#else
    return 0;
#endif
}
static gid_t Group(void) {
#if LBX_CONTAINER_CLOSED_ALLOCATION_TESTING
    return getegid();
#else
    return 0;
#endif
}
static BOOL RootCaller(void) {
#if LBX_CONTAINER_CLOSED_ALLOCATION_TESTING
    return YES;
#else
    return getuid()==0&&geteuid()==0;
#endif
}
static BOOL Safe(int fd,BOOL directory) {
    struct stat s;
    return fd>=0&&!fstat(fd,&s)&&(directory?S_ISDIR(s.st_mode):S_ISREG(s.st_mode))&&
        s.st_uid==Owner()&&s.st_gid==Group()&&(s.st_mode&07777)==(directory?0700:0600)&&
        (directory||s.st_nlink==1)&&RBXStorageGateNoACL(fd);
}
static BOOL ParentSafe(int fd) {
    struct stat s;if(fd<0||fstat(fd,&s)||!S_ISDIR(s.st_mode)||!RBXStorageGateNoACL(fd))return NO;
#if LBX_CONTAINER_CLOSED_ALLOCATION_TESTING
    // Host fixtures cannot establish real cross-UID enforcement. The root-owned
    // sticky temporary ancestor is allowed only in this unshipped test build.
    return (s.st_uid==0||s.st_uid==Owner())&&(!(s.st_mode&0022)||(s.st_uid==0&&(s.st_mode&S_ISVTX)));
#else
    return s.st_uid==0&&!(s.st_mode&0022);
#endif
}
static BOOL Same(int parent,const char *name,int fd) {
    struct stat a,b;return fd>=0&&!fstat(fd,&a)&&!fstatat(parent,name,&b,AT_SYMLINK_NOFOLLOW)&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino;
}
static BOOL UUID(id value) {
    return [value isKindOfClass:NSString.class]&&[value length]==36&&
        [[[NSUUID alloc] initWithUUIDString:value].UUIDString.lowercaseString isEqual:value]&&
        ![value isEqual:@"00000000-0000-0000-0000-000000000000"];
}
static BOOL Exact(id value,NSArray *keys) {
    if(![value isKindOfClass:NSDictionary.class]||[value count]!=keys.count)return NO;
    for(id key in value)if(![key isKindOfClass:NSString.class])return NO;
    return [[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]];
}
static BOOL Integer(id value,BOOL positive) {
    if(![value isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()||CFNumberIsFloatType((__bridge CFNumberRef)value))return NO;
    const char *type=[value objCType];return type&&strchr("cislqCISLQ",type[0])&&!type[1]&&
        [value longLongValue]>=(positive?1:0)&&[value unsignedLongLongValue]<=LLONG_MAX;
}
static NSData *JSON(id value) {return [NSJSONSerialization isValidJSONObject:value]?[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:nil]:nil;}
static NSDictionary *Snapshot(id value) {NSData *data=JSON(value);return data.length&&data.length<=32768?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;}
static NSString *Digest(NSDictionary *value) {
    NSData *data=JSON(value);if(!data.length||data.length>16384)return nil;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,hash);
    NSMutableString *result=[NSMutableString string];for(NSUInteger i=0;i<sizeof(hash);i++)[result appendFormat:@"%02x",hash[i]];return [result copy];
}
static NSDictionary *Node(int fd) {struct stat s;if(!Safe(fd,YES)||fstat(fd,&s))return nil;return @{@"device":@(s.st_dev),@"inode":@(s.st_ino)};}
static BOOL NodeShape(id value) {return Exact(value,@[@"device",@"inode"])&&Integer(value[@"device"],NO)&&Integer(value[@"inode"],YES);}
static BOOL Bound(int fd,NSDictionary *node) {struct stat s;return Safe(fd,YES)&&NodeShape(node)&&!fstat(fd,&s)&&s.st_dev==[node[@"device"] longLongValue]&&s.st_ino==[node[@"inode"] unsignedLongLongValue];}
static NSArray *Phases(void) {return @[@"intent",@"allocation_bound",@"data_intent",@"data_bound",@"groups_intent",@"resources_bound",@"closing",@"closed"];}
static NSArray *NodeKeys(NSString *phase) {
    NSUInteger index=[Phases() indexOfObject:phase];if(index==NSNotFound)return nil;
    if(index==0)return @[];if(index<=2)return @[@"allocation"];if(index<=4)return @[@"allocation",@"data"];
    return @[@"allocation",@"data",@"groups"];
}
static LBXContainerConfiguration *Configuration(id value) {
    LBXContainerConfiguration *record=[LBXContainerConfiguration fromDictionary:value error:nil];
    return record&&[record.privateDictionary isEqual:value]&&[record.applications isEqual:@[@"com.burbn.instagram"]]&&!record.proxyReference.length?record:nil;
}
static BOOL JournalShape(id value) {
    if(!Exact(value,@[@"formatVersion",@"configurationIdentifier",@"configuration",@"configurationSHA256",@"phase",@"identitySpecification",@"resources",@"runtimeAccepted"])||
        !Integer(value[@"formatVersion"],YES)||![value[@"formatVersion"] isEqual:@1]||!UUID(value[@"configurationIdentifier"])||
        ![value[@"runtimeAccepted"] isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)value[@"runtimeAccepted"])!=CFBooleanGetTypeID()||[value[@"runtimeAccepted"] boolValue])return NO;
    LBXContainerConfiguration *configuration=Configuration(value[@"configuration"]);
    LBXContainerIdentitySpecification *spec=[LBXContainerIdentitySpecification fromDictionary:value[@"identitySpecification"] error:nil];
    NSArray *keys=NodeKeys(value[@"phase"]);
    if(!configuration||!spec||![configuration.identifier isEqual:value[@"configurationIdentifier"]]||
        ![spec.configurationIdentifier isEqual:configuration.identifier]||spec.configurationRevision!=configuration.revision||
        ![spec.privateDictionary[@"configuration"] isEqual:configuration.privateDictionary]||
        ![value[@"configurationSHA256"] isEqual:Digest(configuration.privateDictionary)]||
        ![spec.configurationSHA256 isEqual:value[@"configurationSHA256"]]||!keys||!Exact(value[@"resources"],keys))return NO;
    NSMutableSet *nodes=[NSMutableSet set];for(NSString *key in keys){NSDictionary *node=value[@"resources"][key];if(!NodeShape(node)||[nodes containsObject:node])return NO;[nodes addObject:node];}
    return YES;
}

@interface LBXContainerClosedAllocation ()
- (instancetype)initPrivate;
@end
@implementation LBXContainerClosedAllocation {
    NSArray<NSNumber *> *_parents;
    NSArray<NSString *> *_parentNames;
    NSString *_leaf;
    int _root,_journals,_resources,_heldLock;
    dev_t _device,_lockDevice;ino_t _lockInode;
    LBXContainerConfigurationStore *_store;LBXLicenseOwner *_owner;
#if LBX_CONTAINER_CLOSED_ALLOCATION_TESTING
    NSString *_stopBoundary;
#endif
}
- (instancetype)initPrivate {if((self=[super init])){_root=_journals=_resources=_heldLock=-1;}return self;}
- (void)dealloc {for(NSNumber *fd in _parents)close(fd.intValue);if(_root>=0)close(_root);if(_journals>=0)close(_journals);if(_resources>=0)close(_resources);}
- (NSDictionary *)safeStatus {return @{@"formatVersion":@1,@"resourceCount":@2,@"runtimeAccepted":@NO,@"opensRuntimeStorage":@NO};}
- (NSString *)description {return @"<LBXContainerClosedAllocation: private closed namespaces; runtimeAccepted=false>";}
- (NSString *)debugDescription {return self.description;}
+ (instancetype)openDirectory:(NSString *)directory configurationStore:(LBXContainerConfigurationStore *)store licenseOwner:(LBXLicenseOwner *)owner create:(BOOL)create error:(NSError **)error {
    if(!RootCaller()||![store isKindOfClass:LBXContainerConfigurationStore.class]||![owner isKindOfClass:LBXLicenseOwner.class]||![store usesLicenseOwner:owner]||
        ![directory isKindOfClass:NSString.class]||!directory.isAbsolutePath||directory.length>4096||[directory rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound){Fail(error,3);return nil;}
    NSArray *parts=[directory componentsSeparatedByString:@"/"];if(parts.count<3||![parts.firstObject isEqual:@""]){Fail(error,3);return nil;}
    for(NSUInteger i=1;i<parts.count;i++)if(![parts[i] length]||[@[@".",@".."] containsObject:parts[i]]){Fail(error,3);return nil;}
    LBXContainerClosedAllocation *allocation=[[self alloc] initPrivate];NSMutableArray *fds=[NSMutableArray array],*names=[NSMutableArray array];
    int first=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(first>=0)[fds addObject:@(first)];
    BOOL valid=ParentSafe(first);
    for(NSUInteger i=1;valid&&i+1<parts.count;i++) {
        int previous=[fds.lastObject intValue],next=openat(previous,[parts[i] fileSystemRepresentation],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(next>=0){[fds addObject:@(next)];[names addObject:parts[i]];}
        valid=ParentSafe(next)&&Same(previous,[parts[i] fileSystemRepresentation],next);
    }
    allocation->_parents=[fds copy];allocation->_parentNames=[names copy];allocation->_leaf=[parts.lastObject copy];
    int parent=[fds.lastObject intValue];BOOL fresh=NO;
    if(valid&&create){if(!mkdirat(parent,allocation->_leaf.fileSystemRepresentation,0700))fresh=YES;else if(errno!=EEXIST)valid=NO;}
    allocation->_root=valid?openat(parent,allocation->_leaf.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):-1;
    valid=valid&&Safe(allocation->_root,YES)&&Same(parent,allocation->_leaf.fileSystemRepresentation,allocation->_root);
    if(valid&&fresh)valid=!mkdirat(allocation->_root,"journals",0700)&&!mkdirat(allocation->_root,"resources",0700);
    allocation->_journals=valid?openat(allocation->_root,"journals",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):-1;
    allocation->_resources=valid?openat(allocation->_root,"resources",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):-1;
    int lock=valid?openat(allocation->_root,"allocation.lock",O_RDWR|O_NOFOLLOW|O_CLOEXEC|(fresh?(O_CREAT|O_EXCL):0),0600):-1;
    struct stat a,b,c,l;
    valid=valid&&Safe(allocation->_journals,YES)&&Safe(allocation->_resources,YES)&&Safe(lock,NO)&&
        Same(allocation->_root,"journals",allocation->_journals)&&Same(allocation->_root,"resources",allocation->_resources)&&Same(allocation->_root,"allocation.lock",lock)&&
        !fstat(allocation->_root,&a)&&!fstat(allocation->_journals,&b)&&!fstat(allocation->_resources,&c)&&!fstat(lock,&l)&&a.st_dev==b.st_dev&&a.st_dev==c.st_dev&&a.st_dev==l.st_dev&&
        a.st_ino!=b.st_ino&&a.st_ino!=c.st_ino&&b.st_ino!=c.st_ino;
    if(valid&&fresh)valid=!fsync(lock)&&!fsync(allocation->_journals)&&!fsync(allocation->_resources)&&!fsync(allocation->_root)&&!fsync(parent);
    if(lock>=0)close(lock);if(!valid){Fail(error,1);return nil;}
    allocation->_device=a.st_dev;allocation->_lockDevice=l.st_dev;allocation->_lockInode=l.st_ino;allocation->_store=store;allocation->_owner=owner;return allocation;
}
- (BOOL)current {
    if(!RootCaller()||!Safe(_root,YES)||!Safe(_journals,YES)||!Safe(_resources,YES)||!Same(_root,"journals",_journals)||!Same(_root,"resources",_resources))return NO;
    for(NSUInteger i=0;i<_parents.count;i++)if(!ParentSafe(_parents[i].intValue)||(i&&!Same(_parents[i-1].intValue,_parentNames[i-1].fileSystemRepresentation,_parents[i].intValue)))return NO;
    return _parents.count&&Same(_parents.lastObject.intValue,_leaf.fileSystemRepresentation,_root);
}
- (int)lock:(double)deadline {
    if(![self current])return -1;int fd=openat(_root,"allocation.lock",O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);struct stat s;
    if(!Safe(fd,NO)||fstat(fd,&s)||s.st_dev!=_lockDevice||s.st_ino!=_lockInode){if(fd>=0)close(fd);return -1;}
    BOOL locked=NO;for(unsigned attempt=0;attempt<100&&LBXLicenseIPCClock()<deadline;attempt++){if(!flock(fd,LOCK_EX|LOCK_NB)){locked=YES;break;}if(errno!=EWOULDBLOCK&&errno!=EINTR)break;usleep(10000);}
    if(!locked||!Safe(fd,NO)||!Same(_root,"allocation.lock",fd)||![self current]){close(fd);return -1;}return fd;
}
- (BOOL)effectCurrent {
    struct stat s;return [self current]&&Safe(_heldLock,NO)&&Same(_root,"allocation.lock",_heldLock)&&
        !fstat(_heldLock,&s)&&s.st_dev==_lockDevice&&s.st_ino==_lockInode;
}
- (BOOL)boundary:(NSString *)name error:(NSError **)error {
#if LBX_CONTAINER_CLOSED_ALLOCATION_TESTING
    if([_stopBoundary isEqual:name])return Fail(error,4);
#else
    (void)name;(void)error;
#endif
    return YES;
}
- (NSDictionary *)readJournal:(NSString *)identifier absent:(BOOL *)absent {
    if(absent)*absent=NO;NSString *file=[identifier stringByAppendingString:@".json"];
    int fd=openat(_journals,file.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(fd<0){if(absent&&errno==ENOENT)*absent=YES;return nil;}
    BOOL valid=Safe(fd,NO)&&Same(_journals,file.fileSystemRepresentation,fd);NSMutableData *data=[NSMutableData data];char buffer[4096];
    while(valid){ssize_t n=read(fd,buffer,sizeof(buffer));if(n<0&&errno==EINTR)continue;if(n<0){valid=NO;break;}if(!n)break;[data appendBytes:buffer length:(NSUInteger)n];if(data.length>32768)valid=NO;}
    valid=valid&&Safe(fd,NO)&&Same(_journals,file.fileSystemRepresentation,fd);close(fd);
    id record=valid?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    return JournalShape(record)&&[record[@"configurationIdentifier"] isEqual:identifier]?record:nil;
}
- (BOOL)writeJournal:(NSDictionary *)record deadline:(double)deadline error:(NSError **)error {
    NSData *data=JournalShape(record)?JSON(record):nil;if(!data.length||data.length>32768)return Fail(error,3);
    if(![self effectCurrent])return Fail(error,1);
    NSString *temporary=[@"pending-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString],*file=[record[@"configurationIdentifier"] stringByAppendingString:@".json"];
    int fd=openat(_journals,temporary.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);BOOL valid=Safe(fd,NO);NSUInteger offset=0;
    while(valid&&offset<data.length){ssize_t n=write(fd,(const char *)data.bytes+offset,data.length-offset);if(n<0&&errno==EINTR)continue;if(n<=0){valid=NO;break;}offset+=(NSUInteger)n;}
    valid=valid&&!fsync(fd)&&Safe(fd,NO)&&Same(_journals,temporary.fileSystemRepresentation,fd);
    BOOL authorized=[_owner sourceAuthorizationCurrent]&&isfinite(deadline)&&LBXLicenseIPCClock()<deadline;
    BOOL published=valid&&authorized&&[self effectCurrent]&&!renameat(_journals,temporary.fileSystemRepresentation,_journals,file.fileSystemRepresentation);
    if(published)valid=[self effectCurrent]&&Same(_journals,file.fileSystemRepresentation,fd)&&!fsync(_journals)&&[[self readJournal:record[@"configurationIdentifier"] absent:NULL] isEqual:record]&&[self effectCurrent];
    else {if(fd>=0&&Same(_journals,temporary.fileSystemRepresentation,fd))unlinkat(_journals,temporary.fileSystemRepresentation,0);valid=NO;}
    if(fd>=0&&close(fd))valid=NO;return valid?YES:Fail(error,authorized?1:5);
}
- (NSArray<NSString *> *)names:(int)directory {
    int fd=openat(directory,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *stream=fd>=0?fdopendir(fd):NULL;if(!stream){if(fd>=0)close(fd);return nil;}
    NSMutableArray *result=[NSMutableArray array];BOOL valid=YES;for(;;){errno=0;struct dirent *entry=readdir(stream);if(!entry){if(errno)valid=NO;break;}if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
        NSString *name=[[NSString alloc] initWithBytes:entry->d_name length:strlen(entry->d_name) encoding:NSUTF8StringEncoding];if(!name||result.count>=4096){valid=NO;break;}[result addObject:name];}
    closedir(stream);return valid?[result copy]:nil;
}
- (BOOL)verifyNodes:(NSDictionary *)record allowUnbound:(BOOL)allow error:(NSError **)error {
    NSString *identifier=record[@"configurationIdentifier"];NSDictionary *nodes=record[@"resources"];struct stat s;
    int leaf=openat(_resources,identifier.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(!nodes.count){if(leaf>=0)close(leaf);if(!fstatat(_resources,identifier.fileSystemRepresentation,&s,AT_SYMLINK_NOFOLLOW))return allow?YES:Fail(error,4);return errno==ENOENT?YES:Fail(error,1);}
    BOOL valid=Bound(leaf,nodes[@"allocation"])&&Same(_resources,identifier.fileSystemRepresentation,leaf)&&[nodes[@"allocation"][@"device"] longLongValue]==_device;
    NSArray *children=valid?[self names:leaf]:nil;if(!children)valid=NO;
    for(NSString *name in children)if(![@[@"data",@"groups"] containsObject:name])valid=NO;
    for(NSString *name in @[@"data",@"groups"]){
        if(nodes[name]){int fd=openat(leaf,name.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);NSArray *contents=fd>=0?[self names:fd]:nil;valid=valid&&Bound(fd,nodes[name])&&Same(leaf,name.fileSystemRepresentation,fd)&&[nodes[name][@"device"] longLongValue]==_device&&contents&&contents.count==0;if(fd>=0)close(fd);}
        else if([children containsObject:name]&&!allow)valid=NO;
    }
    if(leaf>=0)close(leaf);return valid?YES:Fail(error,4);
}
- (NSDictionary *)inventoryFor:(NSString *)selected error:(NSError **)error {
    NSArray *rootNames=[self names:_root],*journalNames=[self names:_journals],*resourceNames=[self names:_resources];
    if(!rootNames||![[NSSet setWithArray:rootNames] isEqual:[NSSet setWithArray:@[@"allocation.lock",@"journals",@"resources"]]]||!journalNames||!resourceNames){Fail(error,1);return nil;}
    NSMutableDictionary *records=[NSMutableDictionary dictionary],*reservations=[NSMutableDictionary dictionary];NSMutableSet *inodes=[NSMutableSet set];
    for(NSString *file in journalNames){NSString *identifier=file.stringByDeletingPathExtension;
        NSDictionary *record=UUID(identifier)&&[file isEqual:[identifier stringByAppendingString:@".json"]]?[self readJournal:identifier absent:NULL]:nil;
        if(!record||![self verifyNodes:record allowUnbound:[identifier isEqual:selected] error:error]){Fail(error,1);return nil;}
        LBXContainerIdentitySpecification *spec=[LBXContainerIdentitySpecification fromDictionary:record[@"identitySpecification"] error:nil];
        for(NSString *key in spec.reservationKeys.allValues){if(reservations[key]&&![reservations[key] isEqual:identifier]){Fail(error,2);return nil;}reservations[key]=identifier;}
        for(NSDictionary *node in [record[@"resources"] allValues]){if([inodes containsObject:node]){Fail(error,1);return nil;}[inodes addObject:node];}
        records[identifier]=record;
    }
    for(NSString *identifier in resourceNames)if(!UUID(identifier)||!records[identifier]){Fail(error,1);return nil;}
    return records;
}
- (BOOL)advance:(NSMutableDictionary *)record phase:(NSString *)phase nodes:(NSDictionary *)nodes deadline:(double)deadline error:(NSError **)error {
    NSMutableDictionary *next=[record mutableCopy];next[@"phase"]=phase;if(nodes)next[@"resources"]=nodes;
    if(![self writeJournal:next deadline:deadline error:error])return NO;[record setDictionary:next];return [self boundary:[phase stringByAppendingString:@"_committed"] error:error];
}
- (BOOL)createNode:(NSString *)name parent:(int)parent record:(NSMutableDictionary *)record key:(NSString *)key phase:(NSString *)phase deadline:(double)deadline error:(NSError **)error {
    struct stat before;if(!fstatat(parent,name.fileSystemRepresentation,&before,AT_SYMLINK_NOFOLLOW))return Fail(error,4);if(errno!=ENOENT)return Fail(error,1);
    if(![_owner sourceAuthorizationCurrent]||LBXLicenseIPCClock()>=deadline)return Fail(error,5);
    BOOL parentCurrent=[key isEqual:@"allocation"]?parent==_resources:
        Bound(parent,record[@"resources"][@"allocation"])&&Same(_resources,[record[@"configurationIdentifier"] fileSystemRepresentation],parent);
    if(!parentCurrent||![self effectCurrent])return Fail(error,4);
    if(!mkdirat(parent,name.fileSystemRepresentation,0700)){
        if(![self effectCurrent])return Fail(error,4);
        if(![self boundary:[key stringByAppendingString:@"_created"] error:error])return NO;
    }else return Fail(error,errno==EEXIST?4:1);
    int fd=openat(parent,name.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    // A fresh directory must already have exact private ownership/mode. Never
    // change an unknown substituted node to make it satisfy this contract.
    BOOL valid=[self effectCurrent]&&Safe(fd,YES)&&Same(parent,name.fileSystemRepresentation,fd)&&!fsync(fd)&&!fsync(parent)&&[self effectCurrent];
    NSDictionary *node=valid?Node(fd):nil;if(fd>=0)close(fd);
    if(!valid||!node)return Fail(error,4);if(![self boundary:[key stringByAppendingString:@"_synced"] error:error])return NO;
    NSMutableDictionary *nodes=[record[@"resources"] mutableCopy];nodes[key]=node;return [self advance:record phase:phase nodes:nodes deadline:deadline error:error];
}
- (BOOL)finish:(NSMutableDictionary *)record deadline:(double)deadline error:(NSError **)error {
    NSString *identifier=record[@"configurationIdentifier"];
    if([record[@"phase"] isEqual:@"intent"]&&![self createNode:identifier parent:_resources record:record key:@"allocation" phase:@"allocation_bound" deadline:deadline error:error])return NO;
    if([record[@"phase"] isEqual:@"allocation_bound"]&&![self advance:record phase:@"data_intent" nodes:nil deadline:deadline error:error])return NO;
    if(![self verifyNodes:record allowUnbound:NO error:error])return NO;
    int leaf=openat(_resources,identifier.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);BOOL result=NO;
    @try {
        if(!Bound(leaf,record[@"resources"][@"allocation"])||!Same(_resources,identifier.fileSystemRepresentation,leaf))return Fail(error,4);
        if([record[@"phase"] isEqual:@"data_intent"]&&![self createNode:@"data" parent:leaf record:record key:@"data" phase:@"data_bound" deadline:deadline error:error])return NO;
        if([record[@"phase"] isEqual:@"data_bound"]&&![self advance:record phase:@"groups_intent" nodes:nil deadline:deadline error:error])return NO;
        if([record[@"phase"] isEqual:@"groups_intent"]&&![self createNode:@"groups" parent:leaf record:record key:@"groups" phase:@"resources_bound" deadline:deadline error:error])return NO;
        if([record[@"phase"] isEqual:@"resources_bound"]&&![self advance:record phase:@"closing" nodes:nil deadline:deadline error:error])return NO;
        if([record[@"phase"] isEqual:@"closing"]){
            if(![self verifyNodes:record allowUnbound:NO error:error]||![_owner sourceAuthorizationCurrent]||LBXLicenseIPCClock()>=deadline)return Fail(error,5);
            RBXStorageGateDirectory entries[3];int data=openat(leaf,"data",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC),groups=openat(leaf,"groups",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            int fds[]={leaf,data,groups};NSArray *keys=@[@"allocation",@"data",@"groups"];BOOL valid=YES;
            for(NSUInteger i=0;i<3;i++){NSDictionary *node=record[@"resources"][keys[i]];entries[i]=(RBXStorageGateDirectory){fds[i],[node[@"device"] longLongValue],[node[@"inode"] unsignedLongLongValue]};valid=valid&&Bound(fds[i],node);}
            valid=valid&&[self effectCurrent]&&RBXStorageGateDirectoryTransition(entries,3,3,Owner(),Group(),501,501,NULL,NULL)&&[self effectCurrent]&&[self verifyNodes:record allowUnbound:NO error:error];
            if(data>=0)close(data);if(groups>=0)close(groups);if(!valid)return Fail(error,4);
            if(![self boundary:@"directories_closed" error:error]||![self advance:record phase:@"closed" nodes:nil deadline:deadline error:error])return NO;
        }
        result=[record[@"phase"] isEqual:@"closed"]&&[self verifyNodes:record allowUnbound:NO error:error];return result;
    } @finally {if(leaf>=0)close(leaf);}
}
- (NSDictionary *)ensureClosedAllocationForConfiguration:(LBXContainerConfiguration *)configuration beforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;
    LBXContainerConfiguration *candidate=[configuration isKindOfClass:LBXContainerConfiguration.class]?Configuration(configuration.privateDictionary):nil;
    if(!candidate||!RootCaller()){Fail(error,3);return nil;}
    __block NSDictionary *result=nil;
    BOOL success=[_owner performSourceOperation:^BOOL(NSError **operationError){
        @synchronized(self){
            int lock=[self lock:deadline];if(lock<0)return Fail(operationError,1);self->_heldLock=lock;
            @try {
                LBXContainerConfiguration *current=[self->_store configurationWithIdentifier:candidate.identifier error:operationError];
                if(!current)return NO;if(![current.privateDictionary isEqual:candidate.privateDictionary])return Fail(operationError,2);
                LBXContainerIdentitySpecification *observed=[LBXContainerIdentitySpecification createWithConfiguration:candidate error:operationError];if(!observed)return NO;
                NSDictionary *inventory=[self inventoryFor:candidate.identifier error:operationError];if(!inventory)return NO;
                NSDictionary *prior=inventory[candidate.identifier];NSMutableDictionary *record=[prior mutableCopy];
                if(prior){
                    LBXContainerIdentitySpecification *saved=[LBXContainerIdentitySpecification fromDictionary:prior[@"identitySpecification"] error:nil];
                    if(![prior[@"configuration"] isEqual:candidate.privateDictionary]||![saved.privateDictionary isEqual:observed.privateDictionary])return Fail(operationError,2);
                    // A journal without a strict durable reservation is old or
                    // inconsistent state. Never silently adopt/refreeze it.
                    if(![self effectCurrent])return Fail(operationError,4);
                    if(![self->_store allocationReservationCurrentForConfiguration:candidate beforeDeadline:deadline error:operationError])return NO;
                }else {
                    NSSet *wanted=[NSSet setWithArray:observed.reservationKeys.allValues];
                    for(NSDictionary *other in inventory.allValues){LBXContainerIdentitySpecification *spec=[LBXContainerIdentitySpecification fromDictionary:other[@"identitySpecification"] error:nil];if([wanted intersectsSet:[NSSet setWithArray:spec.reservationKeys.allValues]])return Fail(operationError,2);}
                    record=[@{@"formatVersion":@1,@"configurationIdentifier":candidate.identifier,@"configuration":candidate.privateDictionary,
                        @"configurationSHA256":observed.configurationSHA256,@"phase":@"intent",@"identitySpecification":observed.privateDictionary,@"resources":@{},@"runtimeAccepted":@NO} mutableCopy];
                    // Same configuration.lock closes the read/reserve CAS race.
                    // Reservation may outlive a failed final fence or a process
                    // crash before intent; ordinary edit never thaws it.
                    if(![self effectCurrent])return Fail(operationError,4);
                    if(![self->_store reserveConfigurationForClosedAllocation:candidate beforeDeadline:deadline error:operationError])return NO;
                }
                if(![self effectCurrent])return Fail(operationError,4);
                if(![self boundary:@"configuration_reserved" error:operationError])return NO;
                if(!prior&&(![self writeJournal:record deadline:deadline error:operationError]||![self boundary:@"intent_committed" error:operationError]))return NO;
                if(![self finish:record deadline:deadline error:operationError])return NO;
                if(![self->_store allocationReservationCurrentForConfiguration:candidate beforeDeadline:deadline error:operationError])return NO;
                LBXContainerIdentitySpecification *finalContext=[LBXContainerIdentitySpecification createWithConfiguration:candidate error:operationError];
                if(!finalContext||![finalContext.privateDictionary isEqual:observed.privateDictionary]||![self effectCurrent])return Fail(operationError,4);
                result=Snapshot(record);return result!=nil;
            } @finally {self->_heldLock=-1;flock(lock,LOCK_UN);close(lock);}
        }
    } beforeDeadline:deadline error:error];
    return success?result:nil;
}
- (NSDictionary *)recoverClosedAllocationForConfiguration:(LBXContainerConfiguration *)configuration beforeDeadline:(double)deadline error:(NSError **)error {
    return [self ensureClosedAllocationForConfiguration:configuration beforeDeadline:deadline error:error];
}
#if LBX_CONTAINER_CLOSED_ALLOCATION_TESTING
- (void)testStopAfterBoundary:(NSString *)boundary {@synchronized(self){_stopBoundary=[boundary copy];}}
#endif
@end
