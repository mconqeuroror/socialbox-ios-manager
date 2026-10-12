#import "LBXContainerConfigurationStore.h"
#import "LBXContainerConfiguration.h"
#import "../Authorization/LBXLicenseOwner.h"
#import "../Authorization/LBXLicenseIPC.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/acl.h>
#include <dirent.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>

#if LBX_CONTAINER_STORE_TESTING
static void (^PristineBoundaryHandler)(NSString *);
static NSString *PristineStopBoundary;
#endif
static BOOL PristineBoundary(NSString *boundary) {
#if LBX_CONTAINER_STORE_TESTING
    if(PristineBoundaryHandler)PristineBoundaryHandler(boundary);
    return ![PristineStopBoundary isEqual:boundary];
#else
    (void)boundary;return YES;
#endif
}

static BOOL Fail(NSError **error, NSInteger code) {
    if(error)*error=[NSError errorWithDomain:@"com.socialbox.container-configuration-store" code:code
        userInfo:@{NSLocalizedDescriptionKey:code==2?@"Container configuration changed; reload before saving":
        code==3?@"Container configuration is invalid":code==4?@"A current license and unexpired operation are required":
        @"Private container configuration storage is unavailable; recovery is required"}];
    return NO;
}
static uid_t Owner(void) {
#if LBX_CONTAINER_STORE_TESTING
    return geteuid();
#else
    return 0;
#endif
}
static BOOL RootCaller(void) {
#if LBX_CONTAINER_STORE_TESTING
    return YES;
#else
    return getuid()==0&&geteuid()==0;
#endif
}
static BOOL NoACL(int fd) {
    errno=0;acl_t acl=acl_get_fd_np(fd,ACL_TYPE_EXTENDED);
    if(!acl)return errno==ENOENT;
    BOOL valid=acl_valid(acl)==0;acl_entry_t entry;errno=0;
    int result=acl_get_entry(acl,ACL_FIRST_ENTRY,&entry),saved=errno;acl_free(acl);
    return valid && result==-1 && saved==EINVAL;
}
static BOOL SafeFD(int fd,BOOL directory) {
    struct stat s;
    return fd>=0&&!fstat(fd,&s)&&(directory?S_ISDIR(s.st_mode):S_ISREG(s.st_mode))&&
        s.st_uid==Owner()&&!(s.st_mode&0077)&&(directory||s.st_nlink==1)&&NoACL(fd);
}
static BOOL AncestorSafe(int fd) {
    struct stat s;if(fd<0||fstat(fd,&s)||!S_ISDIR(s.st_mode)||!NoACL(fd))return NO;
#if LBX_CONTAINER_STORE_TESTING
    return (s.st_uid==0||s.st_uid==Owner())&&(!(s.st_mode&0022)||(s.st_uid==0&&(s.st_mode&S_ISVTX)));
#else
    return s.st_uid==0&&!(s.st_mode&0022);
#endif
}
static NSDictionary *Node(int fd) {
    struct stat s;if(fd<0||fstat(fd,&s))return nil;
    return @{@"device":@((unsigned long long)s.st_dev),@"inode":@((unsigned long long)s.st_ino),@"owner":@(s.st_uid),@"group":@(s.st_gid),@"mode":@(s.st_mode)};
}
static NSDictionary *Immutable(id value) {
    NSData *data=[NSJSONSerialization isValidJSONObject:value]?[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil]:nil;
    return data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
}
static BOOL Identifier(id value) {
    return [value isKindOfClass:NSString.class]&&[value length]==36&&
        [[[NSUUID alloc] initWithUUIDString:value].UUIDString.lowercaseString isEqual:value];
}
static NSString *Filename(NSString *identifier) {return [identifier stringByAppendingString:@".json"];}
static BOOL SameNode(int directory,const char *name,int held) {
    struct stat path,node;
    return !fstat(held,&node)&&!fstatat(directory,name,&path,AT_SYMLINK_NOFOLLOW)&&
        path.st_dev==node.st_dev&&path.st_ino==node.st_ino;
}
static BOOL Exact(id value,NSArray *keys) {
    if(![value isKindOfClass:NSDictionary.class]||[value count]!=keys.count)return NO;
    for(id key in value)if(![key isKindOfClass:NSString.class])return NO;
    return [[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]];
}
static BOOL Envelope(id value) {
    if(!Exact(value,@[@"storageVersion",@"configuration",@"allocationReserved"]))return NO;
    id version=value[@"storageVersion"],reserved=value[@"allocationReserved"];
    return [version isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)version)!=CFBooleanGetTypeID()&&
        !CFNumberIsFloatType((__bridge CFNumberRef)version)&&[version isEqual:@1]&&
        [reserved isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)reserved)==CFBooleanGetTypeID();
}
static BOOL RetiredEnvelope(id value) {
    if(!Exact(value,@[@"storageVersion",@"configuration",@"allocationReserved",@"retired"]))return NO;
    id version=value[@"storageVersion"],reserved=value[@"allocationReserved"],retired=value[@"retired"];
    return [version isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)version)!=CFBooleanGetTypeID()&&
        !CFNumberIsFloatType((__bridge CFNumberRef)version)&&[version isEqual:@2]&&
        [reserved isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)reserved)==CFBooleanGetTypeID()&&![reserved boolValue]&&
        [retired isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)retired)==CFBooleanGetTypeID()&&[retired boolValue];
}
static LBXContainerConfiguration *StoredConfiguration(id record) {
    // Legacy exact bare configurations are readable; their reservation state
    // is UNKNOWN and edits are blocked. Malformed envelopes cannot fall back.
    id document=(Envelope(record)||RetiredEnvelope(record))?record[@"configuration"]:record;
    LBXContainerConfiguration *configuration=[LBXContainerConfiguration fromDictionary:document error:nil];
    return configuration&&[configuration.privateDictionary isEqual:document]?configuration:nil;
}
static NSDictionary *StorageRecord(LBXContainerConfiguration *configuration,BOOL reserved) {
    return @{@"storageVersion":@1,@"configuration":configuration.privateDictionary,@"allocationReserved":@(reserved)};
}
static NSDictionary *RetirementRecord(LBXContainerConfiguration *configuration) {
    return @{@"storageVersion":@2,@"configuration":configuration.privateDictionary,@"allocationReserved":@NO,@"retired":@YES};
}
static BOOL StableFile(struct stat a,struct stat b) {
    return a.st_dev==b.st_dev&&a.st_ino==b.st_ino&&a.st_uid==b.st_uid&&a.st_gid==b.st_gid&&a.st_mode==b.st_mode&&
        a.st_nlink==b.st_nlink&&a.st_size==b.st_size&&a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec&&
        a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec&&a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec&&a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec;
}
@interface LBXContainerConfigurationStore ()
- (instancetype)initPrivate;
+ (instancetype)openDirectory:(NSString *)directory licenseOwner:(LBXLicenseOwner *)owner create:(BOOL)create pristine:(BOOL)pristine error:(NSError **)error;
- (NSArray<LBXContainerConfiguration *> *)configurationsLocked:(int)lock emptyOnly:(BOOL)empty error:(NSError **)error;
@end
@implementation LBXContainerConfigurationStore {
    int _directory;
    int _parent;
    NSArray<NSNumber *> *_ancestors;NSArray<NSString *> *_ancestorNames;NSArray<NSDictionary *> *_ancestorNodes;
    NSDictionary *_directoryNode;
    NSString *_leaf;
    BOOL _unsafe;
    dev_t _lockDevice;ino_t _lockInode;
    LBXLicenseOwner *_owner;
    int _proofLock;double _proofDeadline;LBXContainerConfiguration *_proofConfiguration;
    BOOL _emptyNamespaceCallback;
    int _emptyNamespaceLock;double _emptyNamespaceDeadline;NSDictionary *_emptyNamespaceContext;
}
- (instancetype)initPrivate {if((self=[super init])){_directory=-1;_parent=-1;_proofLock=-1;_emptyNamespaceLock=-1;}return self;}
- (void)dealloc {if(_directory>=0)close(_directory);for(NSNumber *fd in _ancestors)close(fd.intValue);}
- (NSString *)description {return @"<LBXContainerConfigurationStore: private source configuration>";}
- (NSString *)debugDescription {return self.description;}
- (BOOL)usesLicenseOwner:(LBXLicenseOwner *)owner {return owner&&_owner==owner;}
+ (instancetype)openDirectory:(NSString *)directory licenseOwner:(LBXLicenseOwner *)owner create:(BOOL)create error:(NSError **)error {
    return [self openDirectory:directory licenseOwner:owner create:create pristine:NO error:error];
}
+ (instancetype)createPristineDirectory:(NSString *)directory licenseOwner:(LBXLicenseOwner *)owner error:(NSError **)error {
    return [self openDirectory:directory licenseOwner:owner create:YES pristine:YES error:error];
}
+ (instancetype)openDirectory:(NSString *)directory licenseOwner:(LBXLicenseOwner *)owner create:(BOOL)create pristine:(BOOL)pristine error:(NSError **)error {
    if(error)*error=nil;
    if(!RootCaller()||![directory isKindOfClass:NSString.class]||!directory.isAbsolutePath||![owner isKindOfClass:LBXLicenseOwner.class]||geteuid()!=Owner()) {Fail(error,1);return nil;}
    NSString *leaf=directory.lastPathComponent;char physical[PATH_MAX];
    if(!leaf.length||[leaf isEqual:@"."]||[leaf isEqual:@".."]||!realpath(directory.stringByDeletingLastPathComponent.fileSystemRepresentation,physical)) {Fail(error,1);return nil;}
    NSString *parent=[[NSString alloc] initWithUTF8String:physical];
    if(pristine&&![directory isEqual:[parent stringByAppendingPathComponent:leaf]]){Fail(error,1);return nil;}
    NSMutableArray<NSNumber *> *fds=[NSMutableArray array];NSMutableArray *names=[NSMutableArray array],*nodes=[NSMutableArray array];
    int root=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(root>=0){[fds addObject:@(root)];[names addObject:@""];[nodes addObject:Node(root)?:@{}];}
    BOOL ancestorsValid=AncestorSafe(root);
    for(NSString *part in parent.pathComponents) {
        if([part isEqual:@"/"])continue;
        int next=ancestorsValid?openat(root,part.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):-1;
        if(!AncestorSafe(next)||!SameNode(root,part.fileSystemRepresentation,next)){if(next>=0)close(next);ancestorsValid=NO;break;}
        root=next;[fds addObject:@(root)];[names addObject:part];[nodes addObject:Node(root)];
    }
    struct stat node;
    BOOL valid=ancestorsValid&&root>=0&&!fstat(root,&node)&&S_ISDIR(node.st_mode)&&node.st_uid==Owner()&&!(node.st_mode&0022)&&NoACL(root);
    if(!valid){for(NSNumber *fd in fds)close(fd.intValue);Fail(error,1);return nil;}
    BOOL fresh=NO;
    if(create) {if(!mkdirat(root,leaf.fileSystemRepresentation,0700))fresh=YES;else if(pristine||errno!=EEXIST){for(NSNumber *fd in fds)close(fd.intValue);Fail(error,1);return nil;}}
    int fd=openat(root,leaf.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(!SafeFD(fd,YES)||!SameNode(root,leaf.fileSystemRepresentation,fd)){if(fd>=0)close(fd);for(NSNumber *ancestor in fds)close(ancestor.intValue);Fail(error,1);return nil;}
    LBXContainerConfigurationStore *store=[[self alloc] initPrivate];store->_directory=fd;store->_parent=root;store->_leaf=[leaf copy];store->_owner=owner;
    store->_ancestors=[fds copy];store->_ancestorNames=[names copy];store->_ancestorNodes=[nodes copy];store->_directoryNode=Node(fd);
    if(pristine&&(!fresh||!PristineBoundary(@"directory_created")||![store directoryCurrent]||![store pristineInventoryHasLock:NO])){Fail(error,1);return nil;}
    int lock=openat(fd,"configuration.lock",O_RDWR|O_NOFOLLOW|O_CLOEXEC|(fresh?(O_CREAT|O_EXCL):0),0600);
    struct stat lockNode;
    valid=SafeFD(lock,NO)&&SameNode(fd,"configuration.lock",lock)&&!fstat(lock,&lockNode);
    if(valid){store->_lockDevice=lockNode.st_dev;store->_lockInode=lockNode.st_ino;}
    if(valid&&pristine)valid=PristineBoundary(@"lock_created")&&[store lockCurrent:lock]&&[store pristineInventoryHasLock:YES];
    if(valid&&fresh)valid=[store lockCurrent:lock]&&!fsync(lock)&&[store lockCurrent:lock]&&!fsync(fd)&&[store lockCurrent:lock]&&!fsync(root)&&[store lockCurrent:lock];
    if(valid&&pristine)valid=PristineBoundary(@"namespace_published")&&[store lockCurrent:lock]&&[store pristineInventoryHasLock:YES];
    if(lock>=0)close(lock);
    if(!valid){Fail(error,1);return nil;}return store;
}
- (BOOL)directoryCurrent {
    struct stat parent;
    if(!RootCaller()||_unsafe||!SafeFD(_directory,YES)||![_directoryNode isEqual:Node(_directory)]||!_ancestors.count)return NO;
    for(NSUInteger i=0;i<_ancestors.count;i++) {
        int fd=_ancestors[i].intValue;
        if(!AncestorSafe(fd)||![_ancestorNodes[i] isEqual:Node(fd)]||(i&&!SameNode(_ancestors[i-1].intValue,_ancestorNames[i].fileSystemRepresentation,fd)))return NO;
    }
    return !fstat(_parent,&parent)&&S_ISDIR(parent.st_mode)&&
        parent.st_uid==Owner()&&!(parent.st_mode&0022)&&NoACL(_parent)&&SameNode(_parent,_leaf.fileSystemRepresentation,_directory);
}
- (BOOL)pristineInventoryHasLock:(BOOL)hasLock {
    int fd=openat(_directory,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *stream=fd>=0?fdopendir(fd):NULL;
    BOOL valid=stream!=NULL,seen=NO;struct dirent *entry;
    if(stream)for(;;) {
        errno=0;entry=readdir(stream);if(!entry){if(errno)valid=NO;break;}
        if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
        if(!hasLock||seen||strcmp(entry->d_name,"configuration.lock")){valid=NO;break;}seen=YES;
    }
    if(stream)closedir(stream);else if(fd>=0)close(fd);
    return valid&&seen==hasLock&&[self directoryCurrent];
}
- (BOOL)lockCurrent:(int)lock {
    struct stat node;
    return [self directoryCurrent]&&SafeFD(lock,NO)&&SameNode(_directory,"configuration.lock",lock)&&
        !fstat(lock,&node)&&node.st_dev==_lockDevice&&node.st_ino==_lockInode;
}
- (int)lockBeforeDeadline:(double)deadline {
    // Only two explicitly implemented read-only APIs can reuse a held proof.
    // All ordinary recursive lock acquisition is refused immediately.
    if(_proofLock>=0||_emptyNamespaceCallback||![self directoryCurrent])return -1;
    int fd=openat(_directory,"configuration.lock",O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(![self lockCurrent:fd]){if(fd>=0)close(fd);return -1;}
    BOOL locked=NO;
    for(unsigned attempt=0;attempt<100&&LBXLicenseIPCClock()<deadline;attempt++) {
        if(!flock(fd,LOCK_EX|LOCK_NB)){locked=YES;break;}
        if(errno!=EWOULDBLOCK&&errno!=EINTR)break;usleep(10000);
    }
    if(!locked||![self lockCurrent:fd]){close(fd);return -1;}
    return fd;
}
- (NSDictionary *)configurationNamespaceContextForTrustedInstaller:(NSError **)error {
    if(error)*error=nil;
    if(_proofLock>=0||_emptyNamespaceCallback||!RootCaller()){Fail(error,1);return nil;}
    @synchronized(self) {
        double deadline=LBXLicenseIPCClock()+1;int lock=[self lockBeforeDeadline:deadline];if(lock<0){Fail(error,1);return nil;}
        @try {
            NSDictionary *context=[self lockCurrent:lock]?Immutable(@{@"directory":Node(_directory),@"lock":Node(lock)}):nil;
            if(!context||!PristineBoundary(@"namespace_observed")||![self lockCurrent:lock]||LBXLicenseIPCClock()>=deadline||
                ![context isEqual:Immutable(@{@"directory":Node(_directory)?:@{},@"lock":Node(lock)?:@{}})]){Fail(error,1);return nil;}
            return context;
        } @finally {flock(lock,LOCK_UN);close(lock);}
    }
}
- (NSDictionary *)readRecordIdentifier:(NSString *)identifier absent:(BOOL *)absent {
    if(absent)*absent=NO;
    NSString *file=Filename(identifier);int fd=openat(_directory,file.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(fd<0){if(absent&&errno==ENOENT)*absent=YES;return nil;}
    struct stat before,after;
    if(!SafeFD(fd,NO)||!SameNode(_directory,file.fileSystemRepresentation,fd)||fstat(fd,&before)||before.st_size<=0||before.st_size>16384){close(fd);return nil;}
    NSMutableData *data=[NSMutableData data];char buffer[4096];ssize_t n;unsigned interruptions=0;
    for(;;){n=read(fd,buffer,sizeof(buffer));if(n<0&&errno==EINTR&&++interruptions<=4)continue;if(n<=0)break;
        if(data.length+(NSUInteger)n>16384){close(fd);return nil;}[data appendBytes:buffer length:(NSUInteger)n];}
    BOOL valid=n==0&&data.length==(NSUInteger)before.st_size&&SafeFD(fd,NO)&&SameNode(_directory,file.fileSystemRepresentation,fd)&&!fstat(fd,&after)&&StableFile(before,after);close(fd);
    id record=valid?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    LBXContainerConfiguration *configuration=StoredConfiguration(record);
    // New retirement records have one exact canonical representation. Duplicate
    // keys, alternate escaping/whitespace or numeric Boolean substitutes cannot
    // be adopted as durable retirement proof. Existing v1/legacy reads retain
    // their established parsing contract.
    if(RetiredEnvelope(record)&&![[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil] isEqual:data])return nil;
    return [configuration.identifier isEqual:identifier]?record:nil;
}
- (LBXContainerConfiguration *)readIdentifier:(NSString *)identifier absent:(BOOL *)absent {
    NSDictionary *record=[self readRecordIdentifier:identifier absent:absent];
    return RetiredEnvelope(record)?nil:StoredConfiguration(record);
}
- (LBXContainerConfiguration *)configurationWithIdentifier:(NSString *)identifier error:(NSError **)error {
    BOOL absent=NO;LBXContainerConfiguration *result=[self configurationWithIdentifier:identifier absent:&absent error:error];
    if(absent)Fail(error,1);return result;
}
- (LBXContainerConfiguration *)configurationWithIdentifier:(NSString *)identifier absent:(BOOL *)absent error:(NSError **)error {
    if(absent)*absent=NO;if(error)*error=nil;
    if(!Identifier(identifier)){Fail(error,3);return nil;}
    @synchronized(self) {
        int lock=[self lockBeforeDeadline:LBXLicenseIPCClock()+1];if(lock<0){Fail(error,1);return nil;}
        BOOL missing=NO;NSDictionary *record=[self readRecordIdentifier:identifier absent:&missing];
        LBXContainerConfiguration *result=RetiredEnvelope(record)?nil:StoredConfiguration(record);
        BOOL current=[self lockCurrent:lock];flock(lock,LOCK_UN);close(lock);
        if(!current||(!result&&!missing)){Fail(error,current&&RetiredEnvelope(record)?2:1);return nil;}
        if(missing&&absent)*absent=YES;return result;
    }
}
- (NSArray<LBXContainerConfiguration *> *)configurationsLocked:(int)lock emptyOnly:(BOOL)empty error:(NSError **)error {
    int fd=openat(_directory,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *stream=fd>=0?fdopendir(fd):NULL;
    BOOL valid=stream!=NULL;NSMutableDictionary *records=[NSMutableDictionary dictionary];struct dirent *entry;NSUInteger seen=0;
    if(stream)for(;;) {
        errno=0;entry=readdir(stream);if(!entry){if(errno)valid=NO;break;}
        NSString *file=[[NSString alloc] initWithBytes:entry->d_name length:strlen(entry->d_name) encoding:NSUTF8StringEncoding];
        if([@[@".",@"..",@"configuration.lock"] containsObject:file])continue;
        if(++seen>4096||empty){valid=NO;break;}
        // Ordinary inventory preserves the existing interrupted-stage policy;
        // pristine namespace bootstrap rejects ALL non-lock nodes above.
        if([file hasPrefix:@"pending-"])continue;
        NSString *identifier=[file stringByDeletingPathExtension];
        if(![file isEqual:Filename(identifier)]||!Identifier(identifier)){valid=NO;break;}
        NSDictionary *stored=[self readRecordIdentifier:identifier absent:NULL];
        LBXContainerConfiguration *record=StoredConfiguration(stored);if(!record){valid=NO;break;}
        // Tombstones remain occupied, counted private nodes; hiding an active
        // row never establishes absence or pristine initial-setup authority.
        if(!RetiredEnvelope(stored))records[identifier]=record;
    }
    if(stream)closedir(stream);else if(fd>=0)close(fd);
    if(!valid||![self lockCurrent:lock]){Fail(error,1);return nil;}
    NSMutableArray *result=[NSMutableArray array];for(NSString *identifier in [records.allKeys sortedArrayUsingSelector:@selector(compare:)])[result addObject:records[identifier]];return [result copy];
}
- (NSArray<LBXContainerConfiguration *> *)configurations:(NSError **)error {
    @synchronized(self) {
        int lock=[self lockBeforeDeadline:LBXLicenseIPCClock()+1];if(lock<0){Fail(error,1);return nil;}
        @try {return [self configurationsLocked:lock emptyOnly:NO error:error];} @finally {flock(lock,LOCK_UN);close(lock);}
    }
}
- (BOOL)writeStorageRecord:(NSDictionary *)record replacingRecord:(NSDictionary *)expected deadline:(double)deadline lock:(int)lock error:(NSError **)error {
    LBXContainerConfiguration *configuration=(Envelope(record)||RetiredEnvelope(record))?StoredConfiguration(record):nil;
    if(!configuration)return Fail(error,3);
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    if(!data.length||data.length>16384)return Fail(error,3);
    if(![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
    if(![self lockCurrent:lock])return Fail(error,1);
    NSString *stage=[@"pending-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString],*destination=Filename(configuration.identifier);
    int fd=openat(_directory,stage.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    BOOL valid=SafeFD(fd,NO)&&SameNode(_directory,stage.fileSystemRepresentation,fd)&&[self lockCurrent:lock];NSUInteger offset=0;
    while(valid&&offset<data.length) {
        if(![_owner sourceOperationCurrentBeforeDeadline:deadline]||![self lockCurrent:lock]){valid=NO;break;}
        ssize_t n=write(fd,(const char *)data.bytes+offset,data.length-offset);if(n<0&&errno==EINTR)continue;if(n<=0){valid=NO;break;}offset+=(NSUInteger)n;
    }
    if(valid)valid=!fsync(fd)&&SafeFD(fd,NO)&&SameNode(_directory,stage.fileSystemRepresentation,fd)&&[self lockCurrent:lock];
    // Recheck the complete record, including its freeze, before publication.
    // Cooperating store writers serialize on the same pinned lock. Arbitrary
    // external root mutations and concurrently running old code are unsupported.
    BOOL absent=NO;NSDictionary *current=valid?[self readRecordIdentifier:configuration.identifier absent:&absent]:nil;
    BOOL matches=expected?[current isEqual:expected]:absent;
    NSInteger failure=current||absent?2:1;
    BOOL authorized=[_owner sourceOperationCurrentBeforeDeadline:deadline];
    BOOL published=valid&&matches&&authorized&&[self lockCurrent:lock]&&
        !renameat(_directory,stage.fileSystemRepresentation,_directory,destination.fileSystemRepresentation);
    if(published) {
        valid=[self lockCurrent:lock]&&SafeFD(fd,NO)&&SameNode(_directory,destination.fileSystemRepresentation,fd)&&
            !fsync(_directory)&&[[self readRecordIdentifier:configuration.identifier absent:NULL] isEqual:record]&&[self lockCurrent:lock];
        if(!valid)_unsafe=YES;
        failure=1;
    }else {
        if(fd>=0&&SameNode(_directory,stage.fileSystemRepresentation,fd))unlinkat(_directory,stage.fileSystemRepresentation,0);
        if(valid&&matches)failure=1;valid=NO;
    }
    if(fd>=0&&close(fd))valid=NO;
    // Final fence failure can follow durable publication. The consumer retains
    // the exact candidate and reconciles it; no rollback or thaw is implied.
    authorized=authorized&&[_owner sourceOperationCurrentBeforeDeadline:deadline];
    return valid&&authorized?YES:Fail(error,authorized?failure:4);
}
- (BOOL)commitConfiguration:(LBXContainerConfiguration *)configuration replacing:(LBXContainerConfiguration *)expected beforeDeadline:(double)deadline error:(NSError **)error {
    return [_owner performSourceOperation:^BOOL(NSError **operationError){
        return [self commitConfiguration:configuration replacing:expected inCurrentSourceOperationBeforeDeadline:deadline error:operationError];
    } beforeDeadline:deadline error:error];
}
- (BOOL)commitConfiguration:(LBXContainerConfiguration *)configuration replacing:(LBXContainerConfiguration *)expected inCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;
    if(![configuration isKindOfClass:LBXContainerConfiguration.class]||(expected&&![expected isKindOfClass:LBXContainerConfiguration.class]))return Fail(error,3);
    LBXContainerConfiguration *candidate=[LBXContainerConfiguration fromDictionary:configuration.privateDictionary error:nil];
    LBXContainerConfiguration *prior=expected?[LBXContainerConfiguration fromDictionary:expected.privateDictionary error:nil]:nil;
    NSDictionary *record=candidate.privateDictionary,*old=prior.privateDictionary;
    if(!candidate||(expected&&!prior)||!Identifier(record[@"identifier"])||
       (prior?(![record[@"identifier"] isEqual:old[@"identifier"]]||[record[@"revision"] unsignedLongLongValue]!=[old[@"revision"] unsignedLongLongValue]+1):![record[@"revision"] isEqual:@1]))return Fail(error,3);
    if(_proofLock>=0||!RootCaller()||![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
    @synchronized(self) {
        int lock=[self lockBeforeDeadline:deadline];if(lock<0)return Fail(error,1);
        @try {
            BOOL absent=NO;NSDictionary *stored=[self readRecordIdentifier:record[@"identifier"] absent:&absent];
            LBXContainerConfiguration *current=StoredConfiguration(stored);
            BOOL matches=prior?[current.privateDictionary isEqual:old]:absent;
            BOOL frozen=current&&(RetiredEnvelope(stored)||!Envelope(stored)||[stored[@"allocationReserved"] boolValue]);
            return matches&&!frozen?[self writeStorageRecord:StorageRecord(candidate,NO) replacingRecord:stored deadline:deadline lock:lock error:error]:Fail(error,current||absent?2:1);
        } @finally {flock(lock,LOCK_UN);close(lock);}
    }
}
- (BOOL)retireConfiguration:(LBXContainerConfiguration *)configuration inCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;
    LBXContainerConfiguration *candidate=[configuration isKindOfClass:LBXContainerConfiguration.class]?[LBXContainerConfiguration fromDictionary:configuration.privateDictionary error:nil]:nil;
    if(!candidate)return Fail(error,3);
    if(_proofLock>=0||_emptyNamespaceCallback||!RootCaller()||![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
    @synchronized(self) {
        int lock=[self lockBeforeDeadline:deadline];if(lock<0)return Fail(error,1);
        @try {
            BOOL absent=NO;NSDictionary *stored=[self readRecordIdentifier:candidate.identifier absent:&absent];
            LBXContainerConfiguration *current=StoredConfiguration(stored);
            if(!current||![current.privateDictionary isEqual:candidate.privateDictionary])return Fail(error,current||absent?2:1);
            if(![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
            if(![self lockCurrent:lock])return Fail(error,1);
            if(RetiredEnvelope(stored))return YES;
            // Retirement never upgrades legacy UNKNOWN or releases an existing
            // allocation reservation. The exact expected envelope is rechecked
            // by publication CAS under this same held configuration lock.
            if(!Envelope(stored)||[stored[@"allocationReserved"] boolValue])return Fail(error,2);
            return [self writeStorageRecord:RetirementRecord(candidate) replacingRecord:stored deadline:deadline lock:lock error:error];
        } @finally {flock(lock,LOCK_UN);close(lock);}
    }
}
- (BOOL)retirementCurrentForConfiguration:(LBXContainerConfiguration *)configuration inCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;
    LBXContainerConfiguration *candidate=[configuration isKindOfClass:LBXContainerConfiguration.class]?[LBXContainerConfiguration fromDictionary:configuration.privateDictionary error:nil]:nil;
    if(!candidate)return Fail(error,3);
    if(_proofLock>=0||_emptyNamespaceCallback||!RootCaller()||![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
    @synchronized(self) {
        int lock=[self lockBeforeDeadline:deadline];if(lock<0)return Fail(error,1);
        @try {
            BOOL absent=NO;NSDictionary *stored=[self readRecordIdentifier:candidate.identifier absent:&absent];
            if(!StoredConfiguration(stored))return Fail(error,absent?2:1);
            if(![stored isEqual:RetirementRecord(candidate)])return Fail(error,2);
            if(![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
            return [self lockCurrent:lock]?YES:Fail(error,1);
        } @finally {flock(lock,LOCK_UN);close(lock);}
    }
}
- (LBXContainerConfiguration *)configurationWithIdentifier:(NSString *)identifier absent:(BOOL *)absent inCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error {
    if(absent)*absent=NO;if(error)*error=nil;
    if(!Identifier(identifier)){Fail(error,3);return nil;}
    if(_proofLock>=0||!RootCaller()||![_owner sourceOperationCurrentBeforeDeadline:deadline]){Fail(error,4);return nil;}
    @synchronized(self) {
        int lock=[self lockBeforeDeadline:deadline];if(lock<0){Fail(error,1);return nil;}
        @try {
            BOOL missing=NO;NSDictionary *record=[self readRecordIdentifier:identifier absent:&missing];
            BOOL retired=RetiredEnvelope(record);LBXContainerConfiguration *result=retired?nil:StoredConfiguration(record);
            if(![self lockCurrent:lock]||(!result&&!missing&&!retired)){Fail(error,1);return nil;}
            if(![_owner sourceOperationCurrentBeforeDeadline:deadline]){Fail(error,4);return nil;}
            if(![self lockCurrent:lock]){Fail(error,1);return nil;}
            if(retired){Fail(error,2);return nil;}
            if(missing&&absent)*absent=YES;return result;
        } @finally {flock(lock,LOCK_UN);close(lock);}
    }
}
- (NSArray<LBXContainerConfiguration *> *)configurationsInCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;
    if(_proofLock>=0||!RootCaller()||![_owner sourceOperationCurrentBeforeDeadline:deadline]){Fail(error,4);return nil;}
    @synchronized(self) {
        int lock=[self lockBeforeDeadline:deadline];if(lock<0){Fail(error,1);return nil;}
        @try {
            NSArray *result=[self configurationsLocked:lock emptyOnly:NO error:error];
            if(!result)return nil;
            if(![_owner sourceOperationCurrentBeforeDeadline:deadline]){Fail(error,4);return nil;}
            if(![self lockCurrent:lock]){Fail(error,1);return nil;}return result;
        } @finally {flock(lock,LOCK_UN);close(lock);}
    }
}
- (NSDictionary *)configurationNamespaceContextInCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;
    if(!RootCaller()||![_owner sourceOperationCurrentBeforeDeadline:deadline]){Fail(error,4);return nil;}
    @synchronized(self) {
        if(_proofLock>=0) {
            if(deadline!=_proofDeadline||![self lockCurrent:_proofLock]){Fail(error,4);return nil;}
            NSDictionary *context=Immutable(@{@"directory":Node(_directory),@"lock":Node(_proofLock)});
            if(!context||![_owner sourceOperationCurrentBeforeDeadline:deadline]||![self lockCurrent:_proofLock]){Fail(error,4);return nil;}return context;
        }
        int lock=[self lockBeforeDeadline:deadline];if(lock<0){Fail(error,1);return nil;}
        @try {
            NSDictionary *context=[self lockCurrent:lock]?Immutable(@{@"directory":Node(_directory),@"lock":Node(lock)}):nil;
            if(!context){Fail(error,1);return nil;}
            if(![_owner sourceOperationCurrentBeforeDeadline:deadline]){Fail(error,4);return nil;}
            if(![self lockCurrent:lock]){Fail(error,1);return nil;}return context;
        } @finally {flock(lock,LOCK_UN);close(lock);}
    }
}
- (BOOL)isConfigurationEditable:(LBXContainerConfiguration *)configuration inCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;
    LBXContainerConfiguration *candidate=[configuration isKindOfClass:LBXContainerConfiguration.class]?[LBXContainerConfiguration fromDictionary:configuration.privateDictionary error:nil]:nil;
    if(!candidate)return Fail(error,3);
    if(!RootCaller()||![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
    @synchronized(self) {
        BOOL scoped=_proofLock>=0;
        if(scoped&&(deadline!=_proofDeadline||![_proofConfiguration.privateDictionary isEqual:candidate.privateDictionary]))return Fail(error,4);
        int lock=scoped?_proofLock:[self lockBeforeDeadline:deadline];if(lock<0)return Fail(error,1);
        @try {
            BOOL absent=NO;NSDictionary *stored=[self readRecordIdentifier:candidate.identifier absent:&absent];
            LBXContainerConfiguration *current=StoredConfiguration(stored);
            if(!current||![current.privateDictionary isEqual:candidate.privateDictionary])return Fail(error,current||absent?2:1);
            if(RetiredEnvelope(stored)||!Envelope(stored)||[stored[@"allocationReserved"] boolValue])return Fail(error,2);
            if(![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
            return [self lockCurrent:lock]?YES:Fail(error,1);
        } @finally {if(!scoped){flock(lock,LOCK_UN);close(lock);}}
    }
}
- (BOOL)performWithExactConfiguration:(LBXContainerConfiguration *)configuration inCurrentSourceOperationBeforeDeadline:(double)deadline operation:(BOOL (^)(NSDictionary *,NSError **))operation error:(NSError **)error {
    if(error)*error=nil;
    LBXContainerConfiguration *candidate=[configuration isKindOfClass:LBXContainerConfiguration.class]?[LBXContainerConfiguration fromDictionary:configuration.privateDictionary error:nil]:nil;
    if(!candidate)return Fail(error,3);
    if(!operation||_proofLock>=0||!RootCaller()||![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
    @synchronized(self) {
        int lock=[self lockBeforeDeadline:deadline];if(lock<0)return Fail(error,1);
        @try {
            BOOL absent=NO;NSDictionary *stored=[self readRecordIdentifier:candidate.identifier absent:&absent];LBXContainerConfiguration *current=StoredConfiguration(stored);
            if(!current||![current.privateDictionary isEqual:candidate.privateDictionary])return Fail(error,current||absent?2:1);
            if(RetiredEnvelope(stored))return Fail(error,2);
            NSDictionary *context=Immutable(@{@"directory":Node(_directory),@"lock":Node(lock)});
            if(![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
            if(!context||![self lockCurrent:lock])return Fail(error,1);
            _proofLock=lock;_proofDeadline=deadline;_proofConfiguration=candidate;
            BOOL performed=NO;
            @try {performed=operation(context,error);} @finally {_proofLock=-1;_proofDeadline=0;_proofConfiguration=nil;}
            if(![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
            if(![self lockCurrent:lock]||![Immutable(@{@"directory":Node(_directory),@"lock":Node(lock)}) isEqual:context])return Fail(error,1);
            NSDictionary *after=[self readRecordIdentifier:candidate.identifier absent:&absent];
            if(![after isEqual:stored])return Fail(error,StoredConfiguration(after)||absent?2:1);
            if(![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
            return [self lockCurrent:lock]?performed:Fail(error,1);
        } @finally {_proofLock=-1;_proofDeadline=0;_proofConfiguration=nil;flock(lock,LOCK_UN);close(lock);}
    }
}
- (BOOL)performWithExactRetirement:(LBXContainerConfiguration *)configuration inCurrentSourceOperationBeforeDeadline:(double)deadline operation:(BOOL (^)(NSDictionary *,NSError **))operation error:(NSError **)error {
    if(error)*error=nil;
    LBXContainerConfiguration *candidate=[configuration isKindOfClass:LBXContainerConfiguration.class]?[LBXContainerConfiguration fromDictionary:configuration.privateDictionary error:nil]:nil;
    if(!candidate)return Fail(error,3);
    if(!operation||_proofLock>=0||_emptyNamespaceCallback||!RootCaller()||![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
    @synchronized(self) {
        int lock=[self lockBeforeDeadline:deadline];if(lock<0)return Fail(error,1);
        @try {
            BOOL absent=NO;NSDictionary *stored=[self readRecordIdentifier:candidate.identifier absent:&absent];
            if(!StoredConfiguration(stored))return Fail(error,absent?2:1);
            if(![stored isEqual:RetirementRecord(candidate)])return Fail(error,2);
            NSDictionary *context=Immutable(@{@"directory":Node(_directory),@"lock":Node(lock)});
            if(![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
            if(!context||![self lockCurrent:lock])return Fail(error,1);
            _proofLock=lock;_proofDeadline=deadline;_proofConfiguration=candidate;
            BOOL performed=NO;
            @try {performed=operation(context,error);} @finally {_proofLock=-1;_proofDeadline=0;_proofConfiguration=nil;}
            if(![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
            if(![self lockCurrent:lock]||![Immutable(@{@"directory":Node(_directory),@"lock":Node(lock)}) isEqual:context])return Fail(error,1);
            NSDictionary *after=[self readRecordIdentifier:candidate.identifier absent:&absent];
            if(![after isEqual:stored])return Fail(error,StoredConfiguration(after)||absent?2:1);
            if(![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
            return [self lockCurrent:lock]?performed:Fail(error,1);
        } @finally {_proofLock=-1;_proofDeadline=0;_proofConfiguration=nil;flock(lock,LOCK_UN);close(lock);}
    }
}
- (BOOL)performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:(double)deadline operation:(BOOL (^)(NSDictionary *,NSError **))operation error:(NSError **)error {
    if(error)*error=nil;
    if(!operation||_proofLock>=0||_emptyNamespaceCallback||!RootCaller()||![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
    @synchronized(self) {
        int lock=[self lockBeforeDeadline:deadline];if(lock<0)return Fail(error,1);
        @try {
            if(![self configurationsLocked:lock emptyOnly:YES error:error])return NO;
            NSDictionary *context=Immutable(@{@"directory":Node(_directory),@"lock":Node(lock)});
            if(![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
            if(!context||![self lockCurrent:lock])return Fail(error,1);
            // INITIAL-ONLY lock-order exception: configuration -> fresh pending
            // publication. Callback is synchronous, can enter only the narrow
            // original-context verifier below, cannot enter any owner, hold an
            // established pending lock, or escape authority.
            BOOL performed=NO;_emptyNamespaceCallback=YES;_emptyNamespaceLock=lock;_emptyNamespaceDeadline=deadline;_emptyNamespaceContext=context;
            @try {performed=operation(context,error);} @finally {_emptyNamespaceCallback=NO;_emptyNamespaceLock=-1;_emptyNamespaceDeadline=0;_emptyNamespaceContext=nil;}
            if(![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
            if(![self lockCurrent:lock]||![Immutable(@{@"directory":Node(_directory),@"lock":Node(lock)}) isEqual:context]||
                ![self configurationsLocked:lock emptyOnly:YES error:error])return Fail(error,1);
            return performed;
        } @finally {flock(lock,LOCK_UN);close(lock);}
    }
}
- (BOOL)verifyHeldEmptyNamespaceContext:(NSDictionary *)namespaceContext inCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;
    if(!RootCaller()||![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
    @synchronized(self) {
        if(!_emptyNamespaceCallback||_emptyNamespaceLock<0||namespaceContext!=_emptyNamespaceContext||deadline!=_emptyNamespaceDeadline)return Fail(error,4);
        if(![self lockCurrent:_emptyNamespaceLock]||![namespaceContext isEqual:Immutable(@{@"directory":Node(_directory)?:@{},@"lock":Node(_emptyNamespaceLock)?:@{}})]||
           ![self configurationsLocked:_emptyNamespaceLock emptyOnly:YES error:error])return Fail(error,1);
        if(![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
        return [self lockCurrent:_emptyNamespaceLock]&&[namespaceContext isEqual:Immutable(@{@"directory":Node(_directory)?:@{},@"lock":Node(_emptyNamespaceLock)?:@{}})]?YES:Fail(error,1);
    }
}
- (BOOL)reserveConfigurationForClosedAllocation:(LBXContainerConfiguration *)configuration beforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;
    LBXContainerConfiguration *candidate=[configuration isKindOfClass:LBXContainerConfiguration.class]?
        [LBXContainerConfiguration fromDictionary:configuration.privateDictionary error:nil]:nil;
    if(!candidate)return Fail(error,3);
    if(_proofLock>=0||!RootCaller()||![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
    @synchronized(self) {
        int lock=[self lockBeforeDeadline:deadline];if(lock<0)return Fail(error,1);
        @try {
            BOOL absent=NO;NSDictionary *record=[self readRecordIdentifier:candidate.identifier absent:&absent];
            LBXContainerConfiguration *current=StoredConfiguration(record);
            if(!current||![current.privateDictionary isEqual:candidate.privateDictionary])return Fail(error,current||absent?2:1);
            if(![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
            if(![self lockCurrent:lock])return Fail(error,1);
            if(RetiredEnvelope(record))return Fail(error,2);
            if(Envelope(record)&&[record[@"allocationReserved"] boolValue])return YES;
            return [self writeStorageRecord:StorageRecord(candidate,YES) replacingRecord:record deadline:deadline lock:lock error:error];
        } @finally {flock(lock,LOCK_UN);close(lock);}
    }
}
- (BOOL)allocationReservationCurrentForConfiguration:(LBXContainerConfiguration *)configuration beforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;
    LBXContainerConfiguration *candidate=[configuration isKindOfClass:LBXContainerConfiguration.class]?
        [LBXContainerConfiguration fromDictionary:configuration.privateDictionary error:nil]:nil;
    if(!candidate)return Fail(error,3);
    if(_proofLock>=0||!RootCaller()||![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
    @synchronized(self) {
        int lock=[self lockBeforeDeadline:deadline];if(lock<0)return Fail(error,1);
        @try {
            BOOL absent=NO;NSDictionary *record=[self readRecordIdentifier:candidate.identifier absent:&absent];
            LBXContainerConfiguration *current=StoredConfiguration(record);
            if(!current||![current.privateDictionary isEqual:candidate.privateDictionary])return Fail(error,current||absent?2:1);
            if(!Envelope(record)||![record[@"allocationReserved"] boolValue])return Fail(error,2);
            if(![_owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error,4);
            return [self lockCurrent:lock]?YES:Fail(error,1);
        } @finally {flock(lock,LOCK_UN);close(lock);}
    }
}
#if LBX_CONTAINER_STORE_TESTING
+ (void)testPristineBoundaryHandler:(void (^)(NSString *))handler {PristineBoundaryHandler=[handler copy];}
+ (void)testStopPristineAfterBoundary:(NSString *)boundary {PristineStopBoundary=[boundary copy];}
#endif
@end
