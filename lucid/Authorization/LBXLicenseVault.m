#import "LBXLicenseVault.h"
#import "LBXLicenseOwner.h"
#import "LBXLicenseIPC.h"
#import "../../shared/RBXStorageGate.h"
#import "../../daemon/RBXLicenseToken.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>

#if LBX_LICENSE_VAULT_TESTING
static void (^PristineBoundaryHandler)(NSString *);
static NSString *PristineStopBoundary;
#endif
static BOOL PristineBoundary(NSString *boundary) {
#if LBX_LICENSE_VAULT_TESTING
    if(PristineBoundaryHandler)PristineBoundaryHandler(boundary);
    return ![PristineStopBoundary isEqual:boundary];
#else
    (void)boundary;return YES;
#endif
}

static NSString *const Origin=@"https://redditspoof.vercel.app";
static NSError *Failure(NSInteger code) {
    return [NSError errorWithDomain:@"com.socialbox.license-vault" code:code
        userInfo:@{NSLocalizedDescriptionKey:code==2?@"License state changed; retry the current operation":
        code==3?@"Signed license receipt is invalid":@"Private license storage is unavailable; recovery is required"}];
}
static BOOL Fail(NSError **error,NSInteger code) { if(error)*error=Failure(code);return NO; }
static BOOL Matches(id text,NSString *pattern) {
    if(![text isKindOfClass:NSString.class]||[text length]>4096)return NO;
    return NSEqualRanges([text rangeOfString:pattern options:NSRegularExpressionSearch],NSMakeRange(0,[text length]));
}
static uid_t Owner(void) {
#if LBX_LICENSE_VAULT_TESTING
    return geteuid();
#else
    return 0;
#endif
}
static BOOL RootCaller(void) {
#if LBX_LICENSE_VAULT_TESTING
    return YES;
#else
    return getuid()==0&&geteuid()==0;
#endif
}
static NSDictionary *Node(int fd) {
    struct stat s;if(fd<0||fstat(fd,&s))return nil;
    return @{@"device":@((unsigned long long)s.st_dev),@"inode":@((unsigned long long)s.st_ino),
        @"owner":@(s.st_uid),@"group":@(s.st_gid),@"mode":@(s.st_mode)};
}
static BOOL Same(int parent,const char *name,int fd) {
    struct stat a,b;return fd>=0&&!fstat(fd,&a)&&!fstatat(parent,name,&b,AT_SYMLINK_NOFOLLOW)&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino;
}
static BOOL StableFile(struct stat a,struct stat b) {
    return a.st_dev==b.st_dev&&a.st_ino==b.st_ino&&a.st_uid==b.st_uid&&a.st_gid==b.st_gid&&a.st_mode==b.st_mode&&a.st_nlink==b.st_nlink&&a.st_size==b.st_size&&
        a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec&&a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec&&a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec&&a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec;
}
static BOOL AncestorSafe(int fd) {
    struct stat s;if(fd<0||fstat(fd,&s)||!S_ISDIR(s.st_mode)||!RBXStorageGateNoACL(fd))return NO;
#if LBX_LICENSE_VAULT_TESTING
    BOOL owner=s.st_uid==0||s.st_uid==Owner();
    BOOL writable=(s.st_mode&0022)!=0;
    return owner&&(!writable||(s.st_uid==0&&(s.st_mode&S_ISVTX)));
#else
    return s.st_uid==0&&!(s.st_mode&0022);
#endif
}
static BOOL SafeFD(int fd,BOOL directory) {
    struct stat s;
    return fd>=0 && !fstat(fd,&s) && (directory?S_ISDIR(s.st_mode):S_ISREG(s.st_mode)) &&
        s.st_uid==Owner() && !(s.st_mode&0077) && (directory||s.st_nlink==1) && RBXStorageGateNoACL(fd);
}
static BOOL Revision(id n) {
    return [n isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)n)!=CFBooleanGetTypeID() &&
        isfinite([n doubleValue]) && [n doubleValue]>=1 && [n doubleValue]<9007199254740991.0 &&
        floor([n doubleValue])==[n doubleValue];
}
static BOOL Valid(id r) {
    if(![r isKindOfClass:NSDictionary.class] || !Revision(r[@"formatVersion"]) || ![r[@"formatVersion"] isEqual:@1] || !Revision(r[@"revision"]) ||
       ![r[@"server"] isEqual:Origin] || !Matches(r[@"deviceIdentity"],@"[0-9a-f-]{36}") ||
       ![[[NSUUID alloc] initWithUUIDString:r[@"deviceIdentity"]].UUIDString.lowercaseString isEqual:r[@"deviceIdentity"]] ||
       !Matches(r[@"key"],@"(?:[A-HJ-NP-Z2-9]{4}(?:-[A-HJ-NP-Z2-9]{4}){3})?"))return NO;
    BOOL empty=[r[@"deviceId"] isEqual:@""] && [r[@"deviceToken"] isEqual:@""];
    return empty || (Matches(r[@"deviceId"],@"[A-Za-z0-9_-]{1,128}") && Matches(r[@"deviceToken"],@"[0-9a-f]{64}"));
}
static NSDictionary *Config(NSDictionary *r) {
    return [r dictionaryWithValuesForKeys:@[@"server",@"deviceIdentity",@"key",@"deviceId",@"deviceToken",@"revision"]];
}
@interface LBXLicenseVerifiedCommit ()
- (instancetype)initWithClaims:(NSDictionary *)claims configuration:(NSDictionary *)configuration;
@end
@implementation LBXLicenseVerifiedCommit {
    NSDictionary *_configuration;
}
- (instancetype)initWithClaims:(NSDictionary *)claims configuration:(NSDictionary *)configuration {
    if((self=[super init])) {
        _status=[claims[@"status"] copy];_expiresAt=[claims[@"exp"] doubleValue];
        _configuration=[configuration copy];
    }return self;
}
- (BOOL)matchesConfiguration:(NSDictionary *)configuration { return [_configuration isEqual:configuration]; }
- (NSString *)description { return @"<LBXLicenseVerifiedCommit: private signed commit>"; }
@end
@interface LBXLicenseVault ()
- (instancetype)initPrivate;
+ (instancetype)openDirectory:(NSString *)directory create:(BOOL)create error:(NSError **)error;
+ (instancetype)openDirectory:(NSString *)directory create:(BOOL)create pristine:(BOOL)pristine error:(NSError **)error;
@end
@implementation LBXLicenseVault {
    int _directory;
    NSArray<NSNumber *> *_ancestors;NSArray<NSString *> *_ancestorNames;NSArray<NSDictionary *> *_ancestorNodes;
    NSString *_leaf;NSDictionary *_directoryNode,*_lockNode;
    BOOL _unsafe;
    BOOL _pristineCreation;
#if LBX_LICENSE_VAULT_TESTING
    NSData *_testKey;NSString *_testKeyID;
#endif
}
- (instancetype)initPrivate {if((self=[super init]))_directory=-1;return self;}
- (void)dealloc {if(_directory>=0)close(_directory);for(NSNumber *fd in _ancestors)close(fd.intValue);}
- (NSString *)description {return @"<LBXLicenseVault: private installation pairing>";}
- (BOOL)directoryCurrent {
    if(_unsafe||!RootCaller()||!SafeFD(_directory,YES)||![Node(_directory) isEqual:_directoryNode]||!_ancestors.count)return NO;
    for(NSUInteger i=0;i<_ancestors.count;i++) {
        int fd=_ancestors[i].intValue;
        if(!AncestorSafe(fd)||![Node(fd) isEqual:_ancestorNodes[i]]||(i&&!Same(_ancestors[i-1].intValue,_ancestorNames[i].fileSystemRepresentation,fd)))return NO;
    }
    return Same(_ancestors.lastObject.intValue,_leaf.fileSystemRepresentation,_directory);
}
- (BOOL)lockCurrent:(int)lock {return [self directoryCurrent]&&SafeFD(lock,NO)&&Same(_directory,"owner.lock",lock)&&[_lockNode isEqual:Node(lock)];}
- (BOOL)inventoryExactly:(NSArray<NSString *> *)expected {
    int fd=openat(_directory,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    DIR *stream=fd>=0?fdopendir(fd):NULL;BOOL valid=stream!=NULL;struct dirent *entry;
    NSMutableSet *names=[NSMutableSet set];
    if(stream)for(;;) {
        errno=0;entry=readdir(stream);if(!entry){if(errno)valid=NO;break;}
        NSString *name=[[NSString alloc] initWithBytes:entry->d_name length:strlen(entry->d_name) encoding:NSUTF8StringEncoding];
        if([name isEqual:@"."]||[name isEqual:@".."])continue;
        if(!name||![expected containsObject:name]||[names containsObject:name]){valid=NO;break;}[names addObject:name];
    }
    if(stream)closedir(stream);else if(fd>=0)close(fd);
    return valid&&[names isEqual:[NSSet setWithArray:expected]]&&[self directoryCurrent];
}
- (int)lockCreating:(BOOL *)created {
    if(![self directoryCurrent])return -1;
    // Only the factory's successful fresh mkdir permits creation. Established
    // missing or replaced infrastructure is never adopted or repaired.
    int fd=created?openat(_directory,"owner.lock",O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600):openat(_directory,"owner.lock",O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(!SafeFD(fd,NO)||!Same(_directory,"owner.lock",fd)){if(fd>=0)close(fd);return -1;}
    if(created){_lockNode=Node(fd);*created=YES;}
    if(![self lockCurrent:fd]){close(fd);return -1;}
    BOOL locked=NO;
    for(unsigned i=0;i<100;i++) {
        if(!flock(fd,LOCK_EX|LOCK_NB)){locked=YES;break;}
        if(errno!=EWOULDBLOCK&&errno!=EINTR)break;usleep(10000);
    }
    if(!locked||![self lockCurrent:fd]){close(fd);return -1;}return fd;
}
- (NSDictionary *)readLocked {
    int fd=openat(_directory,"pairing.json",O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);struct stat before,after;
    if(!SafeFD(fd,NO)||!Same(_directory,"pairing.json",fd)||fstat(fd,&before)||before.st_size<=0||before.st_size>32768){if(fd>=0)close(fd);return nil;}
    NSMutableData *data=[NSMutableData data];unsigned char buffer[4096];ssize_t n;unsigned interruptions=0;
    for(;;){n=read(fd,buffer,sizeof(buffer));if(n<0&&errno==EINTR&&++interruptions<=4)continue;if(n<=0)break;
        if(data.length+(NSUInteger)n>32768){close(fd);return nil;}[data appendBytes:buffer length:(NSUInteger)n];}
    BOOL safe=n==0&&data.length==(NSUInteger)before.st_size&&SafeFD(fd,NO)&&Same(_directory,"pairing.json",fd)&&!fstat(fd,&after)&&StableFile(before,after);close(fd);
    id record=safe?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;return Valid(record)?record:nil;
}
- (BOOL)writeLocked:(NSDictionary *)record lock:(int)lock {
    if(![self lockCurrent:lock])return NO;
    NSData *data=Valid(record)?[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil]:nil;
    if(!data.length||data.length>32768)return NO;
    NSString *name=[@"pending-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd=openat(_directory,name.UTF8String,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    BOOL ok=SafeFD(fd,NO)&&Same(_directory,name.UTF8String,fd)&&[self lockCurrent:lock];NSUInteger offset=0;unsigned interruptions=0;
    while(ok&&offset<data.length) {
        if(![self lockCurrent:lock]){ok=NO;break;}
        ssize_t n=write(fd,(const char *)data.bytes+offset,data.length-offset);
        if(n<0&&errno==EINTR&&++interruptions<=4)continue;
        if(n<=0){ok=NO;break;}offset+=(NSUInteger)n;
    }
    if(ok)ok=fsync(fd)==0&&SafeFD(fd,NO)&&Same(_directory,name.UTF8String,fd)&&[self lockCurrent:lock];
    if(ok&&_pristineCreation)ok=PristineBoundary(@"before_seed_publication")&&[self lockCurrent:lock]&&[self inventoryExactly:@[@"owner.lock",name]];
    // The pristine producer cannot replace a destination that appears after
    // the initial absent observation. Normal verified CAS writes keep their
    // established atomic-replacement protocol.
    if(ok)ok=_pristineCreation?renameatx_np(_directory,name.UTF8String,_directory,"pairing.json",RENAME_EXCL)==0:
        renameat(_directory,name.UTF8String,_directory,"pairing.json")==0;
    if(ok)ok=[self lockCurrent:lock]&&SafeFD(fd,NO)&&Same(_directory,"pairing.json",fd)&&fsync(_directory)==0&&[[self readLocked] isEqual:record]&&[self lockCurrent:lock];
    if(!ok){if(!_pristineCreation&&fd>=0&&Same(_directory,name.UTF8String,fd))unlinkat(_directory,name.UTF8String,0);_unsafe=YES;}
    if(fd>=0&&close(fd))ok=NO;return ok;
}
+ (instancetype)openDirectory:(NSString *)directory error:(NSError **)error {return [self openDirectory:directory create:YES error:error];}
+ (instancetype)openExistingDirectory:(NSString *)directory error:(NSError **)error {return [self openDirectory:directory create:NO error:error];}
+ (instancetype)openDirectory:(NSString *)directory create:(BOOL)create error:(NSError **)error {
    return [self openDirectory:directory create:create pristine:NO error:error];
}
+ (instancetype)createPristineDirectory:(NSString *)directory error:(NSError **)error {
    return [self openDirectory:directory create:YES pristine:YES error:error];
}
+ (instancetype)openDirectory:(NSString *)directory create:(BOOL)create pristine:(BOOL)pristine error:(NSError **)error {
    if(error)*error=nil;
    if(!RootCaller()||![directory isKindOfClass:NSString.class]||!directory.isAbsolutePath||geteuid()!=Owner()){Fail(error,1);return nil;}
    NSString *leaf=directory.lastPathComponent;char physical[PATH_MAX];
    if(!leaf.length||[leaf isEqual:@"."]||[leaf isEqual:@".."]||!realpath(directory.stringByDeletingLastPathComponent.fileSystemRepresentation,physical)){Fail(error,1);return nil;}
    NSString *parent=[[NSString alloc] initWithUTF8String:physical];NSMutableArray<NSNumber *> *fds=[NSMutableArray array];
    if(pristine&&![directory isEqual:[parent stringByAppendingPathComponent:leaf]]){Fail(error,1);return nil;}
    NSMutableArray *names=[NSMutableArray array],*nodes=[NSMutableArray array];int root=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(root>=0){[fds addObject:@(root)];[names addObject:@""];[nodes addObject:Node(root)?:@{}];}
    BOOL valid=AncestorSafe(root);
    for(NSString *part in parent.pathComponents) {
        if([part isEqual:@"/"])continue;
        int next=valid?openat(root,part.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):-1;
        if(!AncestorSafe(next)||!Same(root,part.fileSystemRepresentation,next)){if(next>=0)close(next);valid=NO;break;}
        root=next;[fds addObject:@(root)];[names addObject:part];[nodes addObject:Node(root)];
    }
    // The immediate dedicated parent must be owned by this role and private
    // against other writers, even when a host fixture traverses sticky /tmp.
    struct stat parentNode;if(valid)valid=!fstat(root,&parentNode)&&parentNode.st_uid==Owner()&&!(parentNode.st_mode&0022);
    BOOL fresh=NO;
    if(valid&&create){if(!mkdirat(root,leaf.fileSystemRepresentation,0700))fresh=YES;else if(pristine||errno!=EEXIST)valid=NO;}
    int dir=valid?openat(root,leaf.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):-1;
    valid=valid&&SafeFD(dir,YES)&&Same(root,leaf.fileSystemRepresentation,dir)&&(!fresh||!fsync(root));
    if(!valid){if(dir>=0)close(dir);for(NSNumber *fd in fds)close(fd.intValue);Fail(error,1);return nil;}
    LBXLicenseVault *vault=[[self alloc] initPrivate];vault->_directory=dir;vault->_leaf=[leaf copy];vault->_directoryNode=Node(dir);
    vault->_ancestors=[fds copy];vault->_ancestorNames=[names copy];vault->_ancestorNodes=[nodes copy];
    vault->_pristineCreation=pristine;
    if(pristine&&(!fresh||!PristineBoundary(@"directory_created")||![vault inventoryExactly:@[]])){Fail(error,1);return nil;}
    if(!fresh){int fd=openat(dir,"owner.lock",O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);if(SafeFD(fd,NO)&&Same(dir,"owner.lock",fd))vault->_lockNode=Node(fd);if(fd>=0)close(fd);}
    BOOL created=NO;int lock=[vault lockCreating:fresh?&created:NULL];if(lock<0){Fail(error,1);return nil;}
    NSDictionary *record=nil;
    @try {
        if(pristine&&(!created||!PristineBoundary(@"lock_created")||![vault lockCurrent:lock]||![vault inventoryExactly:@[@"owner.lock"]])){Fail(error,1);return nil;}
        record=[vault readLocked];struct stat existing;
        BOOL absent=fstatat(dir,"pairing.json",&existing,AT_SYMLINK_NOFOLLOW)!=0&&errno==ENOENT;
        if(pristine&&(record||!absent)){Fail(error,1);return nil;}
        if(!record&&fresh&&created&&absent) {
            record=@{@"formatVersion":@1,@"server":Origin,@"deviceIdentity":NSUUID.UUID.UUIDString.lowercaseString,@"key":@"",@"deviceId":@"",@"deviceToken":@"",@"revision":@1};
            if(![vault writeLocked:record lock:lock])record=nil;
        }
        if(![vault lockCurrent:lock])record=nil;
        if(pristine&&record&&(!PristineBoundary(@"seed_published")||![vault lockCurrent:lock]||![vault inventoryExactly:@[@"owner.lock",@"pairing.json"]]||![[vault readLocked] isEqual:record]))record=nil;
    } @finally {flock(lock,LOCK_UN);close(lock);}
    if(!record){Fail(error,1);return nil;}vault->_pristineCreation=NO;return vault;
}
- (NSDictionary *)installationContextForTrustedInstaller:(NSError **)error {
    if(error)*error=nil;
    if(!RootCaller()){Fail(error,1);return nil;}
    @synchronized(self) {
        double deadline=LBXLicenseIPCClock()+1;int lock=[self lockCreating:NULL];if(lock<0){Fail(error,1);return nil;}
        @try {
            NSDictionary *record=[self readLocked];
            if(!record||![self lockCurrent:lock]){Fail(error,1);return nil;}
            NSDictionary *observed=@{@"server":record[@"server"],@"deviceIdentity":record[@"deviceIdentity"],
                @"vault":@{@"directory":Node(_directory),@"lock":Node(lock)}};
            NSData *data=[NSJSONSerialization dataWithJSONObject:observed options:NSJSONWritingSortedKeys error:nil];
            NSDictionary *context=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
            if(!context||!PristineBoundary(@"installation_observed")||![[self readLocked] isEqual:record]||![self lockCurrent:lock]||LBXLicenseIPCClock()>=deadline||
                ![observed isEqual:@{@"server":record[@"server"],@"deviceIdentity":record[@"deviceIdentity"],@"vault":@{@"directory":Node(_directory)?:@{},@"lock":Node(lock)?:@{}}}]){Fail(error,1);return nil;}
            return context;
        } @finally {flock(lock,LOCK_UN);close(lock);}
    }
}
- (NSDictionary *)configuration:(NSError **)error {
    @synchronized(self) {
        int lock=[self lockCreating:NULL];if(lock<0){Fail(error,1);return nil;}
        @try {
            NSDictionary *r=[self readLocked];
            if(!r||![self lockCurrent:lock]){Fail(error,1);return nil;}return Config(r);
        } @finally {flock(lock,LOCK_UN);close(lock);}
    }
}
- (NSDictionary *)beginWithKey:(NSString *)key error:(NSError **)error {
    if(key && ![key isKindOfClass:NSString.class]){Fail(error,1);return nil;}
    NSString *normalized=key?[[key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString]:nil;
    if(normalized&&!Matches(normalized,@"[A-HJ-NP-Z2-9]{4}(?:-[A-HJ-NP-Z2-9]{4}){3}")){Fail(error,1);return nil;}
    @synchronized(self) {
        int lock=[self lockCreating:NULL];if(lock<0){Fail(error,1);return nil;}
        @try {
            NSMutableDictionary *r=[[self readLocked] mutableCopy];
            if(normalized)r[@"key"]=normalized;
            BOOL ok=r && [r[@"key"] length] && [r[@"revision"] doubleValue]<9007199254740990.0;
            if(ok){r[@"revision"]=@([r[@"revision"] unsignedLongLongValue]+1);ok=[self writeLocked:r lock:lock];}
            if(!ok){Fail(error,1);return nil;}return Config(r);
        } @finally {flock(lock,LOCK_UN);close(lock);}
    }
}
- (BOOL)commitReceipt:(NSDictionary *)receipt expectedConfiguration:(NSDictionary *)expected error:(NSError **)error {
    return [self commitVerifiedReceipt:receipt expectedConfiguration:expected error:error]!=nil;
}
- (LBXLicenseVerifiedCommit *)commitVerifiedReceipt:(NSDictionary *)receipt expectedConfiguration:(NSDictionary *)expected error:(NSError **)error {
    @synchronized(self) {
        int lock=[self lockCreating:NULL];if(lock<0){Fail(error,1);return nil;}
        @try {
        NSMutableDictionary *r=[[self readLocked] mutableCopy];BOOL ok=NO;NSInteger code=3;
        LBXLicenseVerifiedCommit *verified=nil;
        if(!r||![Config(r) isEqual:expected])code=2;
        else if([receipt isKindOfClass:NSDictionary.class]) {
            NSString *device=receipt[@"deviceId"],*nonce=receipt[@"requestNonce"],*token=receipt[@"licenseToken"];
            BOOL paired=[r[@"deviceId"] length]>0;
            if(Matches(device,@"[A-Za-z0-9_-]{1,128}") && Matches(nonce,@"[0-9a-f-]{36}") &&
               (!paired||[device isEqual:r[@"deviceId"]]) && [token isKindOfClass:NSString.class]) {
                NSDictionary *binding=@{@"server":Origin,@"deviceId":device,
                    @"deviceBinding":[RBXLicenseToken fingerprint:r[@"deviceIdentity"]],
                    @"keyFingerprint":[RBXLicenseToken fingerprint:r[@"key"]]};
                NSTimeInterval now=NSDate.date.timeIntervalSince1970;NSDictionary *claims=nil;
#if LBX_LICENSE_VAULT_TESTING
                if(_testKey)claims=[RBXLicenseToken verifyToken:token publicKeyDER:_testKey keyID:_testKeyID expected:binding nonce:nonce now:now error:nil];
                else
#endif
                claims=[RBXLicenseToken verifyToken:token expected:binding nonce:nonce now:now error:nil];
                BOOL active=[claims[@"status"] isEqual:@"active"]&&[claims[@"exp"] doubleValue]>now;
                NSString *credential=receipt[@"deviceToken"];
                if(claims && ((!active&&paired) || (active && (paired ? (!credential||[credential isEqual:r[@"deviceToken"]]) : Matches(credential,@"[0-9a-f]{64}"))))) {
                    if(active&&!paired){r[@"deviceId"]=device;r[@"deviceToken"]=credential;}
                    r[@"revision"]=@([r[@"revision"] unsignedLongLongValue]+1);
                    // Status is descriptive only. No stored token/Boolean can
                    // authorize an engine through this credential-vault API.
                    r[@"lastStatus"]=active?@"active":([claims[@"status"] isEqual:@"active"]?@"expired":claims[@"status"]);
                    r[@"lastVerifiedAt"]=@(now);ok=[self writeLocked:r lock:lock];if(!ok)code=1;
                    if(ok)verified=[[LBXLicenseVerifiedCommit alloc] initWithClaims:claims configuration:Config(r)];
                }
            }
        }
        if(!ok)Fail(error,code);return verified;
        } @finally {flock(lock,LOCK_UN);close(lock);}
    }
}
- (NSDictionary *)pairingContextForSourceOwner:(LBXLicenseOwner *)owner beforeDeadline:(NSTimeInterval)deadline error:(NSError **)error {
    if(error)*error=nil;
    if(!RootCaller()||![owner usesVault:self]||![owner sourceOperationCurrentBeforeDeadline:deadline]){Fail(error,2);return nil;}
    __block NSDictionary *context=nil;
    @synchronized(self) {
        int lock=[self lockCreating:NULL];if(lock<0){Fail(error,1);return nil;}
        @try {
            NSDictionary *record=[self readLocked],*configuration=record?Config(record):nil;
            if(![configuration[@"key"] length]||![configuration[@"deviceId"] length]||![configuration[@"deviceToken"] length]){Fail(error,2);return nil;}
            NSDictionary *observed=@{@"server":configuration[@"server"],@"deviceIdentity":configuration[@"deviceIdentity"],@"deviceId":configuration[@"deviceId"],
                @"keyFingerprint":[RBXLicenseToken fingerprint:configuration[@"key"]],@"bearerFingerprint":[RBXLicenseToken fingerprint:configuration[@"deviceToken"]],
                @"vault":@{@"directory":Node(_directory),@"lock":Node(lock)}};
            NSData *data=[NSJSONSerialization dataWithJSONObject:observed options:NSJSONWritingSortedKeys error:nil];
            context=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
            if(!context||![[self readLocked] isEqual:record]||![self lockCurrent:lock]||LBXLicenseIPCClock()>=deadline){Fail(error,1);context=nil;}
        } @finally {flock(lock,LOCK_UN);close(lock);}
    }
    // sourceOperationCurrent reads the vault itself. It must never run while
    // this method holds its separate flock description.
    if(context&&![owner sourceOperationCurrentBeforeDeadline:deadline]){Fail(error,2);return nil;}return context;
}
- (NSDictionary *)safeStatus {
    NSDictionary *c=[self configuration:nil];return @{@"storage":c?@"ready":@"unavailable",
        @"paired":@((BOOL)([c[@"deviceId"] length]>0)),@"engineAuthorized":@NO};
}
#if LBX_LICENSE_VAULT_TESTING
- (void)testUsePublicKey:(NSData *)key keyID:(NSString *)keyID { _testKey=[key copy];_testKeyID=[keyID copy]; }
+ (void)testPristineBoundaryHandler:(void (^)(NSString *))handler {PristineBoundaryHandler=[handler copy];}
+ (void)testStopPristineAfterBoundary:(NSString *)boundary {PristineStopBoundary=[boundary copy];}
#endif
@end
