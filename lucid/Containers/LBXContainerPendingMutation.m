#import "LBXContainerPendingMutation.h"
#import "LBXContainerConfiguration.h"
#import "../Authorization/LBXLicenseEndpoints.h"
#import "../../shared/RBXStorageGate.h"
#import "../../shared/RBXProc.h"
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/file.h>
#include <dirent.h>
#include <limits.h>
#include <string.h>

static NSString *const Leaf=@"SocialBoxPendingMutations",*const PendingMarker=@".socialbox-pending-v1.json";
static BOOL Fail(NSError **error,NSInteger code) {
    if(error)*error=[NSError errorWithDomain:@"com.socialbox.pending-mutation" code:code userInfo:@{NSLocalizedDescriptionKey:
        code==2?@"Pending mutation changed; reconcile the exact saved candidate":code==3?@"Pending mutation is invalid":
        code==4?@"A mobile user frontend role is required":code==5?@"The fixed mobile frontend context is unavailable":@"Private pending state is unavailable; recovery is required"}];
    return NO;
}
static uid_t Owner(void) {
#if LBX_CONTAINER_MUTATION_TESTING
    return geteuid();
#else
    return 501;
#endif
}
static gid_t Group(void) {
#if LBX_CONTAINER_MUTATION_TESTING
    return getegid();
#else
    return 501;
#endif
}
static BOOL Caller(void) {
#if LBX_CONTAINER_MUTATION_TESTING
    return YES;
#else
    return getuid()==501&&geteuid()==501;
#endif
}
static BOOL Exact(id value,NSArray *keys) {
    if(![value isKindOfClass:NSDictionary.class]||[value count]!=keys.count)return NO;
    for(id key in value)if(![key isKindOfClass:NSString.class])return NO;
    return [[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]];
}
static BOOL Integer(id value,BOOL positive) {
    return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()&&
        !CFNumberIsFloatType((__bridge CFNumberRef)value)&&[value longLongValue]>=(positive?1:0)&&[value unsignedLongLongValue]<=LLONG_MAX;
}
static BOOL UUID(id value) {return [value isKindOfClass:NSString.class]&&[value length]==36&&
    [[[NSUUID alloc] initWithUUIDString:value].UUIDString.lowercaseString isEqual:value]&&![value isEqual:@"00000000-0000-0000-0000-000000000000"];}
static NSData *JSON(id value) {return [NSJSONSerialization isValidJSONObject:value]?[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:nil]:nil;}
static NSDictionary *Snapshot(id value) {NSData *data=JSON(value);return data.length&&data.length<=32768?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;}
static LBXContainerConfiguration *Document(id value) {LBXContainerConfiguration *c=[LBXContainerConfiguration fromDictionary:value error:nil];return c&&[c.privateDictionary isEqual:value]?c:nil;}
static BOOL Slot(id value) {
    if(!Exact(value,@[@"identifier",@"epoch",@"attempt",@"operation",@"configuration",@"expected"])||!UUID(value[@"identifier"])||
        !Integer(value[@"epoch"],YES)||!Integer(value[@"attempt"],NO))return NO;
    LBXContainerConfiguration *candidate=Document(value[@"configuration"]);if(!candidate)return NO;
    if([value[@"operation"] isEqual:@"create"])return candidate.revision==1&&value[@"expected"]==NSNull.null;
    LBXContainerConfiguration *expected=Document(value[@"expected"]);
    return [value[@"operation"] isEqual:@"update"]&&expected&&[candidate.identifier isEqual:expected.identifier]&&
        expected.revision<LLONG_MAX&&candidate.revision==expected.revision+1;
}
static BOOL Safe(int fd,BOOL directory) {struct stat s;return fd>=0&&!fstat(fd,&s)&&(directory?S_ISDIR(s.st_mode):S_ISREG(s.st_mode))&&
    s.st_uid==Owner()&&s.st_gid==Group()&&(s.st_mode&07777)==(directory?0700:0600)&&(directory||s.st_nlink==1)&&RBXStorageGateNoACL(fd);}
static BOOL ParentSafe(int fd) {
    struct stat s;if(fd<0||fstat(fd,&s)||!S_ISDIR(s.st_mode)||!RBXStorageGateNoACL(fd))return NO;
#if LBX_CONTAINER_MUTATION_TESTING
    return (s.st_uid==0||s.st_uid==Owner())&&(!(s.st_mode&0022)||(s.st_uid==0&&(s.st_mode&S_ISVTX)));
#else
    return (s.st_uid==0||s.st_uid==501)&&!(s.st_mode&0022);
#endif
}
static BOOL Same(int parent,NSString *name,int fd) {struct stat a,b;return fd>=0&&!fstat(fd,&a)&&
    !(parent<0?lstat("/",&b):fstatat(parent,name.fileSystemRepresentation,&b,AT_SYMLINK_NOFOLLOW))&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino;}
static NSDictionary *Node(int fd) {struct stat s;if(fstat(fd,&s))return nil;return @{@"device":@(s.st_dev),@"inode":@(s.st_ino),@"owner":@(s.st_uid),@"group":@(s.st_gid),@"mode":@(s.st_mode&07777)};}
static NSDictionary *FileNode(int fd) {struct stat s;if(fstat(fd,&s))return nil;NSMutableDictionary *node=[Node(fd) mutableCopy];
    [node addEntriesFromDictionary:@{@"size":@(s.st_size),@"links":@(s.st_nlink),@"mtime":@(s.st_mtimespec.tv_sec),@"mtimeNS":@(s.st_mtimespec.tv_nsec),@"ctime":@(s.st_ctimespec.tv_sec),@"ctimeNS":@(s.st_ctimespec.tv_nsec)}];return [node copy];}
static NSString *Physical(NSString *path) {char output[PATH_MAX];return [path isKindOfClass:NSString.class]&&path.isAbsolutePath&&realpath(path.fileSystemRepresentation,output)?[NSString stringWithUTF8String:output]:nil;}
#if LBX_CONTAINER_MUTATION_TESTING
static NSString *TestHome,*TestExecutable;
#endif

@interface LBXContainerPendingMutation ()
- (instancetype)initPrivate;
@end
@implementation LBXContainerPendingMutation {
    NSArray<NSNumber *> *_parents;NSArray<NSString *> *_names;NSArray<NSDictionary *> *_parentNodes;
    int _root,_client;NSDictionary *_rootNode,*_lockNode,*_clientNode,*_context;NSString *_clientPath;
#if LBX_CONTAINER_MUTATION_TESTING
    NSString *_stop;
#endif
}
- (instancetype)initPrivate {if((self=[super init]))_root=_client=-1;return self;}
- (void)dealloc {for(NSNumber *fd in _parents)close(fd.intValue);if(_root>=0)close(_root);if(_client>=0)close(_client);}
- (NSString *)description {return @"<LBXContainerPendingMutation: private mobile metadata; runtimeAccepted=false>";}
- (NSString *)debugDescription {return self.description;}
- (BOOL)boundary:(NSString *)name error:(NSError **)error {
#if LBX_CONTAINER_MUTATION_TESTING
    if([_stop isEqual:name])return Fail(error,1);
#else
    (void)name;(void)error;
#endif
    return YES;
}
- (BOOL)current {
    if(!Caller())return NO;
    NSString *home=NSHomeDirectory(),*executable=@LBX_LICENSE_CLIENT_PATH;
#if LBX_CONTAINER_MUTATION_TESTING
    @synchronized(self.class){if(TestHome)home=[TestHome copy];if(TestExecutable)executable=[TestExecutable copy];}
#else
    char running[PROC_PIDPATHINFO_MAXSIZE];
    if(proc_pidpath(getpid(),running,sizeof(running))<=0||![Physical([NSString stringWithUTF8String:running]) isEqual:_clientPath])return NO;
#endif
    if(![Physical(home) isEqual:_context[@"homePath"]]||![Physical(executable) isEqual:_clientPath]||
        !Safe(_root,YES)||![Node(_root) isEqual:_rootNode]||!Same(_parents.lastObject.intValue,Leaf,_root))return NO;
    for(NSUInteger i=0;i<_parents.count;i++)if(!ParentSafe(_parents[i].intValue)||![Node(_parents[i].intValue) isEqual:_parentNodes[i]]||
        !Same(i?_parents[i-1].intValue:-1,i?_names[i-1]:@"/",_parents[i].intValue))return NO;
    struct stat named;return _client>=0&&RBXStorageGateNoACL(_client)&&[FileNode(_client) isEqual:_clientNode]&&
        !lstat(_clientPath.fileSystemRepresentation,&named)&&S_ISREG(named.st_mode)&&named.st_dev==[_clientNode[@"device"] longLongValue]&&named.st_ino==[_clientNode[@"inode"] unsignedLongLongValue];
}
- (BOOL)lockCurrent:(int)fd {return [self current]&&Safe(fd,NO)&&Same(_root,@"pending.lock",fd)&&[Node(fd) isEqual:_lockNode];}
- (int)lock:(NSError **)error {
    if(![self current]){Fail(error,1);return -1;}int fd=openat(_root,"pending.lock",O_RDWR|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(![self lockCurrent:fd]||flock(fd,LOCK_EX|LOCK_NB)||![self lockCurrent:fd]){if(fd>=0)close(fd);Fail(error,1);return -1;}return fd;
}
- (NSDictionary *)readFile:(NSString *)name directory:(int)directory {
    int fd=openat(directory,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);NSDictionary *before=fd>=0?FileNode(fd):nil;
    if(!Safe(fd,NO)||!Same(directory,name,fd)||[before[@"size"] longLongValue]<=0||[before[@"size"] unsignedLongLongValue]>32768){if(fd>=0)close(fd);return nil;}
    NSMutableData *data=[NSMutableData data];char buffer[4096];ssize_t n;unsigned interruptions=0;
    for(;;){n=read(fd,buffer,sizeof(buffer));if(n<0&&errno==EINTR&&++interruptions<=4)continue;if(n<=0)break;
        if(data.length+(NSUInteger)n>32768){n=-1;break;}[data appendBytes:buffer length:(NSUInteger)n];}
    BOOL valid=n==0&&data.length==[before[@"size"] unsignedLongLongValue]&&Safe(fd,NO)&&Same(directory,name,fd)&&[FileNode(fd) isEqual:before];close(fd);
    id record=valid?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    return [record isKindOfClass:NSDictionary.class]&&[JSON(record) isEqual:data]?record:nil;
}
- (BOOL)inventory {
    int fd=openat(_root,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *stream=fd>=0?fdopendir(fd):NULL;if(!stream){if(fd>=0)close(fd);return NO;}
    BOOL valid=YES;NSUInteger count=0;BOOL state=NO,lock=NO;
    for(;;){errno=0;struct dirent *e=readdir(stream);if(!e){if(errno)valid=NO;break;}if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;
        NSString *name=[NSString stringWithUTF8String:e->d_name];if(++count>64||!name){valid=NO;break;}
        if([name isEqual:@"state.json"]){state=YES;continue;}if([name isEqual:@"pending.lock"]){lock=YES;continue;}
        if(![name hasPrefix:@"stage-"]||!UUID([name substringFromIndex:6])){valid=NO;break;}
        int stage=openat(_root,e->d_name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);valid=Safe(stage,NO)&&Same(_root,name,stage);if(stage>=0)close(stage);if(!valid)break;
    }closedir(stream);return valid&&state&&lock;
}
- (NSDictionary *)state:(NSError **)error {
    if(![self current]||![self inventory]){Fail(error,1);return nil;}
    NSDictionary *marker=[self readFile:PendingMarker directory:_parents.lastObject.intValue];
    if(!Exact(marker,@[@"formatVersion",@"context",@"root"])||!Integer(marker[@"formatVersion"],YES)||![marker[@"formatVersion"] isEqual:@1]||
        ![marker[@"context"] isEqual:_context]||![marker[@"root"] isEqual:_rootNode]){Fail(error,1);return nil;}
    NSDictionary *state=[self readFile:@"state.json" directory:_root];
    if(!Exact(state,@[@"formatVersion",@"context",@"epoch",@"pending"])||!Integer(state[@"formatVersion"],YES)||![state[@"formatVersion"] isEqual:@1]||
       !Integer(state[@"epoch"],YES)||![state[@"context"] isEqual:_context]||
       (state[@"pending"]!=NSNull.null&&(!Slot(state[@"pending"])||![state[@"pending"][@"epoch"] isEqual:state[@"epoch"]]))){Fail(error,1);return nil;}
    return state;
}
- (BOOL)writeState:(NSDictionary *)state replacing:(NSDictionary *)expected lock:(int)lock error:(NSError **)error {
    NSData *data=JSON(state);if(!data.length||data.length>32768)return Fail(error,3);if(![self lockCurrent:lock])return Fail(error,1);
    NSString *name=[@"stage-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];int fd=openat(_root,name.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    BOOL valid=Safe(fd,NO)&&Same(_root,name,fd)&&[self lockCurrent:lock],published=NO;NSUInteger offset=0;unsigned interrupted=0;
    @try {
        while(valid&&offset<data.length){if(![self lockCurrent:lock]){valid=NO;break;}ssize_t n=write(fd,(const char *)data.bytes+offset,data.length-offset);
            if(n<0&&errno==EINTR&&++interrupted<=4)continue;if(n<=0){valid=NO;break;}offset+=(NSUInteger)n;}
        valid=valid&&!fsync(fd)&&Safe(fd,NO)&&Same(_root,name,fd)&&[self lockCurrent:lock];
        if(!valid||![self boundary:@"state_staged" error:error])return Fail(error,1);
        NSDictionary *current=[self state:error];if(![current isEqual:expected])return Fail(error,current?2:1);
        if(![self lockCurrent:lock]||renameat(_root,name.fileSystemRepresentation,_root,"state.json"))return Fail(error,1);published=YES;
        if(![self lockCurrent:lock]||!Safe(fd,NO)||!Same(_root,@"state.json",fd)||![self boundary:@"state_renamed" error:error])return Fail(error,1);
        if(fsync(_root)||![[self readFile:@"state.json" directory:_root] isEqual:state]||![self lockCurrent:lock]||![self boundary:@"state_synced" error:error])return Fail(error,1);
        return YES;
    } @finally {if(!published&&fd>=0&&Same(_root,name,fd))unlinkat(_root,name.fileSystemRepresentation,0);if(fd>=0)close(fd);}
}
// Initial setup is not a proof of pristine history. Its trusted caller must
// establish that fact; complete same-UID/root tree deletion cannot be detected.
+ (instancetype)openWithCreate:(BOOL)create error:(NSError **)error {
    if(error)*error=nil;if(!Caller()){Fail(error,4);return nil;}
    NSString *home=NSHomeDirectory(),*executable=@LBX_LICENSE_CLIENT_PATH;
#if LBX_CONTAINER_MUTATION_TESTING
    @synchronized(self){if(TestHome)home=[TestHome copy];if(TestExecutable)executable=[TestExecutable copy];}
#endif
    home=Physical(home);executable=Physical(executable);if(!home||!executable){Fail(error,5);return nil;}
#if !LBX_CONTAINER_MUTATION_TESTING
    char running[PROC_PIDPATHINFO_MAXSIZE];if(proc_pidpath(getpid(),running,sizeof(running))<=0||![Physical([NSString stringWithUTF8String:running]) isEqual:executable]){Fail(error,5);return nil;}
#endif
    LBXContainerPendingMutation *journal=[[self alloc] initPrivate];journal->_clientPath=executable;
    journal->_client=open(executable.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);struct stat cs;
    BOOL valid=journal->_client>=0&&!fstat(journal->_client,&cs)&&S_ISREG(cs.st_mode)&&!(cs.st_mode&0022)&&cs.st_nlink==1&&cs.st_size>0&&cs.st_size<=32*1024*1024&&RBXStorageGateNoACL(journal->_client);
#if LBX_CONTAINER_MUTATION_TESTING
    valid=valid&&(cs.st_uid==0||cs.st_uid==Owner());
#else
    valid=valid&&cs.st_uid==0&&cs.st_size==LBX_LICENSE_CLIENT_SIZE;
#endif
    journal->_clientNode=valid?FileNode(journal->_client):nil;CC_SHA256_CTX digest;CC_SHA256_Init(&digest);char bytes[16384];off_t total=0;unsigned interrupted=0;
    while(valid&&total<cs.st_size){ssize_t n=read(journal->_client,bytes,(size_t)MIN((off_t)sizeof(bytes),cs.st_size-total));if(n<0&&errno==EINTR&&++interrupted<=4)continue;if(n<=0){valid=NO;break;}CC_SHA256_Update(&digest,bytes,(CC_LONG)n);total+=n;}
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(hash,&digest);NSMutableString *sha=[NSMutableString string];for(NSUInteger i=0;i<sizeof(hash);i++)[sha appendFormat:@"%02x",hash[i]];
    valid=valid&&total==cs.st_size&&[FileNode(journal->_client) isEqual:journal->_clientNode];
#if !LBX_CONTAINER_MUTATION_TESTING
    valid=valid&&[sha isEqual:@LBX_LICENSE_CLIENT_SHA256];
#endif
    if(!valid){Fail(error,5);return nil;}
    NSMutableArray *fds=[NSMutableArray array],*names=[NSMutableArray array],*nodes=[NSMutableArray array];int first=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(first>=0){[fds addObject:@(first)];[nodes addObject:Node(first)];}valid=ParentSafe(first);
    NSArray *parts=[home componentsSeparatedByString:@"/"];for(NSUInteger i=1;valid&&i<parts.count;i++){if(![parts[i] length]||[@[@".",@".."] containsObject:parts[i]]){valid=NO;break;}
        int parent=[fds.lastObject intValue],fd=openat(parent,[parts[i] fileSystemRepresentation],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd>=0){[fds addObject:@(fd)];[nodes addObject:Node(fd)];[names addObject:parts[i]];}valid=ParentSafe(fd)&&Same(parent,parts[i],fd);}
    NSDictionary *homeNode=valid?Node([fds.lastObject intValue]):nil;
    for(NSString *part in @[@"Library",@"Application Support"]){if(!valid)break;int parent=[fds.lastObject intValue];
        // Only fixed local infrastructure is created during explicit setup.
        if(create&&mkdirat(parent,part.fileSystemRepresentation,0700)&&errno!=EEXIST){valid=NO;break;}
        int fd=openat(parent,part.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd>=0){[fds addObject:@(fd)];[names addObject:part];[nodes addObject:Node(fd)];}valid=ParentSafe(fd)&&Same(parent,part,fd);}
    journal->_parents=[fds copy];journal->_names=[names copy];journal->_parentNodes=[nodes copy];if(!valid){Fail(error,1);return nil;}
    journal->_context=Snapshot(@{@"homePath":home,@"home":homeNode,@"clientPath":executable,@"client":journal->_clientNode,@"clientSHA256":sha,
        @"serviceName":@LBX_LICENSE_SERVICE_NAME,@"servicePath":@LBX_LICENSE_SERVICE_PATH,@"protocolVersion":@1});
    int parent=[fds.lastObject intValue];struct stat leafNode,markerNode;BOOL hasLeaf=!fstatat(parent,Leaf.fileSystemRepresentation,&leafNode,AT_SYMLINK_NOFOLLOW);int leafError=errno;
    BOOL hasMarker=!fstatat(parent,PendingMarker.fileSystemRepresentation,&markerNode,AT_SYMLINK_NOFOLLOW);int markerError=errno;
    BOOL fresh=!hasLeaf&&!hasMarker&&leafError==ENOENT&&markerError==ENOENT;
    if(!hasLeaf&&!(fresh&&create)){Fail(error,1);return nil;}if(hasLeaf&&!hasMarker){Fail(error,1);return nil;}
    if(fresh&&mkdirat(parent,Leaf.fileSystemRepresentation,0700)){Fail(error,1);return nil;}
    journal->_root=openat(parent,Leaf.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(!Safe(journal->_root,YES)||!Same(parent,Leaf,journal->_root)){Fail(error,1);return nil;}
    journal->_rootNode=Node(journal->_root);int lock=openat(journal->_root,"pending.lock",O_RDWR|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC|(fresh?(O_CREAT|O_EXCL):0),0600);
    valid=Safe(lock,NO)&&Same(journal->_root,@"pending.lock",lock);journal->_lockNode=valid?Node(lock):nil;
    if(valid&&fresh){NSDictionary *state=@{@"formatVersion":@1,@"context":journal->_context,@"epoch":@1,@"pending":NSNull.null};
        NSDictionary *marker=@{@"formatVersion":@1,@"context":journal->_context,@"root":journal->_rootNode};
        for(NSArray *entry in @[@[@"state.json",state,@(journal->_root)],@[PendingMarker,marker,@(parent)]]){
            NSData *data=JSON(entry[1]);int fd=openat([entry[2] intValue],[entry[0] fileSystemRepresentation],O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);NSUInteger offset=0;unsigned interruptions=0;
            valid=valid&&data.length&&data.length<=32768&&Safe(fd,NO)&&Same([entry[2] intValue],entry[0],fd);
            while(valid&&offset<data.length){ssize_t n=write(fd,(const char *)data.bytes+offset,data.length-offset);if(n<0&&errno==EINTR&&++interruptions<=4)continue;if(n<=0){valid=NO;break;}offset+=(NSUInteger)n;}
            valid=valid&&!fsync(fd)&&Safe(fd,NO)&&Same([entry[2] intValue],entry[0],fd)&&!fsync([entry[2] intValue]);if(fd>=0)close(fd);if(!valid)break;
        }
        valid=valid&&!fsync(lock)&&!fsync(journal->_root)&&!fsync(parent);
    }
    if(lock>=0)close(lock);if(!valid||![journal current]){Fail(error,1);return nil;}
    NSError *readError=nil;[journal pendingMutation:&readError];if(readError){if(error)*error=readError;return nil;}return journal;
}
- (NSDictionary *)pendingMutation:(NSError **)error {
    if(error)*error=nil;@synchronized(self){int lock=[self lock:error];if(lock<0)return nil;@try {
        NSDictionary *state=[self state:error];if(!state||![self lockCurrent:lock]){Fail(error,1);return nil;}return state[@"pending"]==NSNull.null?nil:state[@"pending"];
    } @finally {flock(lock,LOCK_UN);close(lock);}}
}
- (NSDictionary *)stageConfiguration:(LBXContainerConfiguration *)configuration replacing:(LBXContainerConfiguration *)expected error:(NSError **)error {
    if(error)*error=nil;LBXContainerConfiguration *candidate=[configuration isKindOfClass:LBXContainerConfiguration.class]?Document(configuration.privateDictionary):nil;
    LBXContainerConfiguration *prior=[expected isKindOfClass:LBXContainerConfiguration.class]?Document(expected.privateDictionary):nil;
    if(!candidate||(expected&&!prior)){Fail(error,3);return nil;}
    @synchronized(self){int lock=[self lock:error];if(lock<0)return nil;@try {
        NSDictionary *current=[self state:error];if(!current)return nil;if(current[@"pending"]!=NSNull.null){Fail(error,2);return nil;}
        uint64_t epoch=[current[@"epoch"] unsignedLongLongValue];if(epoch>=LLONG_MAX){Fail(error,3);return nil;}
        NSDictionary *slot=@{@"identifier":NSUUID.UUID.UUIDString.lowercaseString,@"epoch":@(epoch+1),@"attempt":@0,@"operation":prior?@"update":@"create",@"configuration":candidate.privateDictionary,@"expected":prior.privateDictionary?:NSNull.null};
        if(!Slot(slot)){Fail(error,3);return nil;}NSDictionary *next=@{@"formatVersion":@1,@"context":_context,@"epoch":@(epoch+1),@"pending":slot};
        return [self writeState:next replacing:current lock:lock error:error]?Snapshot(slot):nil;
    } @finally {flock(lock,LOCK_UN);close(lock);}}
}
- (NSDictionary *)beginAttemptForMutation:(NSDictionary *)mutation error:(NSError **)error {
    if(error)*error=nil;NSDictionary *wanted=Snapshot(mutation);if(!Slot(wanted)){Fail(error,3);return nil;}
    @synchronized(self){int lock=[self lock:error];if(lock<0)return nil;@try {
        NSDictionary *current=[self state:error];if(!current)return nil;if(![current[@"pending"] isEqual:wanted]){Fail(error,2);return nil;}
        uint64_t epoch=[current[@"epoch"] unsignedLongLongValue],attempt=[wanted[@"attempt"] unsignedLongLongValue];if(epoch>=LLONG_MAX||attempt>=LLONG_MAX){Fail(error,3);return nil;}
        NSMutableDictionary *slot=[wanted mutableCopy];slot[@"epoch"]=@(epoch+1);slot[@"attempt"]=@(attempt+1);
        NSDictionary *next=@{@"formatVersion":@1,@"context":_context,@"epoch":@(epoch+1),@"pending":slot};
        return [self writeState:next replacing:current lock:lock error:error]?Snapshot(slot):nil;
    } @finally {flock(lock,LOCK_UN);close(lock);}}
}
- (BOOL)clearConfirmedMutation:(NSDictionary *)mutation error:(NSError **)error {
    if(error)*error=nil;NSDictionary *wanted=Snapshot(mutation);if(!Slot(wanted))return Fail(error,3);
    @synchronized(self){int lock=[self lock:error];if(lock<0)return NO;@try {
        NSDictionary *current=[self state:error];if(!current)return NO;if(![current[@"pending"] isEqual:wanted])return Fail(error,2);
        uint64_t epoch=[current[@"epoch"] unsignedLongLongValue];if(epoch>=LLONG_MAX)return Fail(error,3);
        if(![self boundary:@"clear_before_publish" error:error])return NO;
        return [self writeState:@{@"formatVersion":@1,@"context":_context,@"epoch":@(epoch+1),@"pending":NSNull.null} replacing:current lock:lock error:error];
    } @finally {flock(lock,LOCK_UN);close(lock);}}
}
- (NSDictionary *)safeStatus {NSError *error=nil;NSDictionary *pending=[self pendingMutation:&error];return @{@"available":@((BOOL)!error),@"hasPending":@((BOOL)(pending!=nil)),@"runtimeAccepted":@NO};}
#if LBX_CONTAINER_MUTATION_TESTING
+ (void)testUseHomeDirectory:(NSString *)home clientExecutable:(NSString *)executable {@synchronized(self){TestHome=[home copy];TestExecutable=[executable copy];}}
- (void)testStopAfterBoundary:(NSString *)boundary {@synchronized(self){_stop=[boundary copy];}}
#endif
@end
