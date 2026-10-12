#import "LBXLicenseInstallationEstablishment.h"
#import "LBXLicenseOwner.h"
#import "LBXLicenseVault.h"
#import "LBXLicenseEndpoints.h"
#import "LBXLicenseIPC.h"
#import "../Containers/LBXContainerConfigurationStore.h"
#import "../Containers/LBXContainerEndpoints.h"
#import "../../shared/RBXStorageGate.h"
#import <CommonCrypto/CommonDigest.h>
#include <mach-o/dyld.h>
#include <fcntl.h>
#include <dirent.h>
#include <unistd.h>
#include <limits.h>
#include <string.h>
#include <math.h>

static BOOL Fail(NSError **error){if(error){*error=[NSError errorWithDomain:@"com.socialbox.installation-establishment" code:1
    userInfo:@{NSLocalizedDescriptionKey:@"Trusted installation preparation is unavailable; existing or partial state was not reset"}];}return NO;}
static uid_t Owner(void){
#if LBX_LICENSE_INSTALLATION_TESTING
    return geteuid();
#else
    return 0;
#endif
}
static BOOL Caller(void){
#if LBX_LICENSE_INSTALLATION_TESTING
    return getuid()==geteuid();
#else
    return getuid()==0&&geteuid()==0&&getegid()==0;
#endif
}
static BOOL Exact(id value,NSArray *keys){return [value isKindOfClass:NSDictionary.class]&&[value count]==keys.count&&
    [[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]];}
static BOOL Version(id value){return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()&&
    !CFNumberIsFloatType((__bridge CFNumberRef)value)&&[value longLongValue]==1;}
static NSData *JSON(id value){return [NSJSONSerialization isValidJSONObject:value]?[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:nil]:nil;}
static NSString *Digest(NSData *data){if(!data)return nil;unsigned char bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);
    NSMutableString *value=[NSMutableString string];for(NSUInteger i=0;i<sizeof(bytes);i++)[value appendFormat:@"%02x",bytes[i]];return value;}
static NSDictionary *Node(int fd){struct stat n;if(fd<0||fstat(fd,&n))return nil;return @{@"device":@(n.st_dev),@"inode":@(n.st_ino),@"owner":@(n.st_uid),@"group":@(n.st_gid),@"mode":@(n.st_mode&07777)};}
static NSDictionary *File(int fd){struct stat n;if(fd<0||fstat(fd,&n))return nil;NSMutableDictionary *v=[Node(fd) mutableCopy];
    [v addEntriesFromDictionary:@{@"size":@(n.st_size),@"links":@(n.st_nlink),@"mtime":@(n.st_mtimespec.tv_sec),@"mtimeNS":@(n.st_mtimespec.tv_nsec),@"ctime":@(n.st_ctimespec.tv_sec),@"ctimeNS":@(n.st_ctimespec.tv_nsec)}];return [v copy];}
static BOOL InitialFile(id value){NSArray *keys=@[@"device",@"inode",@"owner",@"group",@"mode",@"size",@"links",@"mtime",@"mtimeNS",@"ctime",@"ctimeNS"];
    if(!Exact(value,keys))return NO;for(NSString *key in keys){id n=value[key];if(![n isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)n)==CFBooleanGetTypeID()||
        CFNumberIsFloatType((__bridge CFNumberRef)n)||[n longLongValue]<0)return NO;}
    return [value[@"inode"] unsignedLongLongValue]>0&&[value[@"owner"] unsignedLongLongValue]==Owner()&&[value[@"group"] unsignedLongLongValue]==getegid()&&
        [value[@"mode"] unsignedLongLongValue]==0600&&[value[@"size"] unsignedLongLongValue]>0&&[value[@"size"] unsignedLongLongValue]<=32768&&
        [value[@"links"] unsignedLongLongValue]==1&&[value[@"mtimeNS"] unsignedLongLongValue]<1000000000&&[value[@"ctimeNS"] unsignedLongLongValue]<1000000000;
}
static BOOL Safe(int fd,BOOL directory){struct stat n;return fd>=0&&!fstat(fd,&n)&&(directory?S_ISDIR(n.st_mode):S_ISREG(n.st_mode))&&n.st_uid==Owner()&&n.st_gid==getegid()&&
    (n.st_mode&07777)==(directory?0700:0600)&&(directory||n.st_nlink==1)&&RBXStorageGateNoACL(fd);}
static BOOL Parent(int fd){struct stat n;if(fd<0||fstat(fd,&n)||!S_ISDIR(n.st_mode)||!RBXStorageGateNoACL(fd))return NO;
#if LBX_LICENSE_INSTALLATION_TESTING
    return (n.st_uid==0||n.st_uid==Owner())&&(!(n.st_mode&0022)||(n.st_uid==0&&(n.st_mode&S_ISVTX)));
#else
    return n.st_uid==0&&!(n.st_mode&0022);
#endif
}
static BOOL Same(int parent,NSString *name,int fd){struct stat a,b;return fd>=0&&!fstat(fd,&a)&&!(parent<0?lstat("/",&b):fstatat(parent,name.fileSystemRepresentation,&b,AT_SYMLINK_NOFOLLOW))&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino;}
static NSString *Physical(NSString *path){char bytes[PATH_MAX];return [path isKindOfClass:NSString.class]&&path.isAbsolutePath&&realpath(path.fileSystemRepresentation,bytes)?[NSString stringWithUTF8String:bytes]:nil;}
static BOOL Time(double deadline){double now=LBXLicenseIPCClock();return isfinite(now)&&isfinite(deadline)&&now<deadline;}
static NSDictionary *Paths(void){return @{@"anchor":@LBX_LICENSE_INSTALLATION_PATH,@"vault":@LBX_LICENSE_VAULT_PATH,@"configuration":@LBX_CONTAINER_STORE_PATH,
    @"pending":@LBX_CONTAINER_PENDING_PATH,@"installer":@LBX_LICENSE_INSTALLER_PATH,@"service":@LBX_LICENSE_SERVICE_PATH,@"client":@LBX_LICENSE_CLIENT_PATH};}
static BOOL ValidPaths(NSDictionary *paths){if(!Exact(paths,@[@"anchor",@"vault",@"configuration",@"pending",@"installer",@"service",@"client"]))return NO;
    NSMutableSet *unique=[NSMutableSet set];for(NSString *key in paths){NSString *value=paths[key];if(![value isKindOfClass:NSString.class]||!value.isAbsolutePath||value.length>4096||
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound){return NO;}[unique addObject:value];}
    for(NSString *value in paths.allValues){NSArray *parts=[value componentsSeparatedByString:@"/"];for(NSUInteger i=1;i<parts.count;i++)
        if(![parts[i] length]||[parts[i] isEqual:@"."]||[parts[i] isEqual:@".."])return NO;}
    if(unique.count!=paths.count)return NO;
    NSString *parent=paths[@"anchor"];parent=parent.stringByDeletingLastPathComponent;
    for(NSString *key in @[@"anchor",@"vault",@"configuration",@"pending"]){NSString *value=paths[key],*leaf=value.lastPathComponent;
        if(![value.stringByDeletingLastPathComponent isEqual:parent]||!NSEqualRanges([leaf rangeOfString:@"[A-Za-z0-9][A-Za-z0-9_-]{0,79}" options:NSRegularExpressionSearch],NSMakeRange(0,leaf.length)))return NO;}
    return YES;}
// Walk physical fixed-policy ancestors and retain their exact identities.
static BOOL Parents(NSString *physical,NSMutableArray *fds,NSMutableArray *names,NSMutableArray *nodes){int fd=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    NSDictionary *node=Node(fd);if(fd>=0){[fds addObject:@(fd)];if(node)[nodes addObject:node];}BOOL good=Parent(fd)&&node;NSArray *parts=[physical componentsSeparatedByString:@"/"];
    for(NSUInteger i=1;good&&i<parts.count;i++){int parent=[fds.lastObject intValue];fd=openat(parent,[parts[i] fileSystemRepresentation],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        node=Node(fd);if(fd>=0){[fds addObject:@(fd)];[names addObject:parts[i]];if(node)[nodes addObject:node];}good=Parent(fd)&&node&&Same(parent,parts[i],fd);}return good;}
static void Close(NSArray *fds){for(NSNumber *fd in fds)close(fd.intValue);}
static NSDictionary *Image(NSString *path,double deadline){NSString *parent=Physical(path.stringByDeletingLastPathComponent);if(!parent||!Time(deadline))return nil;
    NSMutableArray *fds=[NSMutableArray array],*names=[NSMutableArray array],*nodes=[NSMutableArray array];BOOL good=Parents(parent,fds,names,nodes);int fd=good?openat([fds.lastObject intValue],path.lastPathComponent.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC):-1;
    struct stat n;NSDictionary *before=File(fd);good=good&&fd>=0&&!fstat(fd,&n)&&S_ISREG(n.st_mode)&&n.st_uid==Owner()&&!(n.st_mode&0022)&&(n.st_mode&0111)&&n.st_nlink==1&&n.st_size>0&&n.st_size<=32*1024*1024&&RBXStorageGateNoACL(fd)&&Same([fds.lastObject intValue],path.lastPathComponent,fd);
    CC_SHA256_CTX hash;CC_SHA256_Init(&hash);char bytes[16384];off_t total=0;unsigned interruptions=0;
    while(good&&total<n.st_size){if(!Time(deadline)){good=NO;break;}ssize_t got=read(fd,bytes,(size_t)MIN((off_t)sizeof(bytes),n.st_size-total));if(got<0&&errno==EINTR&&++interruptions<=4)continue;if(got<=0){good=NO;break;}total+=got;CC_SHA256_Update(&hash,bytes,(CC_LONG)got);}
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(digest,&hash);NSMutableString *sha=[NSMutableString string];for(NSUInteger i=0;i<sizeof(digest);i++)[sha appendFormat:@"%02x",digest[i]];
    good=good&&Time(deadline)&&[File(fd) isEqual:before]&&Same([fds.lastObject intValue],path.lastPathComponent,fd);
    for(NSUInteger i=0;good&&i<fds.count;i++)good=Parent([fds[i] intValue])&&[Node([fds[i] intValue]) isEqual:nodes[i]]&&Same(i?[fds[i-1] intValue]:-1,i?names[i-1]:@"/",[fds[i] intValue]);
    NSDictionary *result=good?@{@"declared":path,@"physical":[parent stringByAppendingPathComponent:path.lastPathComponent],@"file":before,@"sha256":sha,@"parents":nodes}:nil;
    if(fd>=0)close(fd);Close(fds);return result;}
static BOOL Process(NSDictionary *paths,BOOL creating){
#if LBX_LICENSE_INSTALLATION_TESTING
    (void)paths;(void)creating;return Caller();
#else
    char buffer[PATH_MAX];uint32_t size=sizeof(buffer);if(!Caller()||_NSGetExecutablePath(buffer,&size))return NO;
    NSString *observed=Physical([NSString stringWithUTF8String:buffer]);return observed&&([observed isEqual:Physical(paths[@"installer"])]||(!creating&&[observed isEqual:Physical(paths[@"service"])]));
#endif
}
#if LBX_LICENSE_INSTALLATION_TESTING
static NSString *Stop;
static void (^BoundaryHandler)(NSString *);
#endif
static BOOL Boundary(NSString *name){
#if LBX_LICENSE_INSTALLATION_TESTING
    if(BoundaryHandler)BoundaryHandler(name);
    return ![Stop isEqual:name];
#else
    (void)name;return YES;
#endif
}
@interface LBXLicenseInstallationEstablishment ()
- (instancetype)initPrivate;
+ (nullable instancetype)assemble:(NSDictionary *)paths sha:(NSString *)sha size:(NSUInteger)size create:(BOOL)create error:(NSError **)error;
- (BOOL)currentBeforeDeadline:(double)deadline error:(NSError **)error;
- (BOOL)currentBeforeDeadline:(double)deadline namespaceObserver:(NSDictionary *(^)(void))observer error:(NSError **)error;
@end
@implementation LBXLicenseInstallationEstablishment {
    LBXLicenseVault *_vault;LBXLicenseOwner *_licenseOwner;LBXContainerConfigurationStore *_configurationStore;
    NSDictionary *_paths,*_policy,*_intent,*_prepared,*_intentFile,*_preparedFile,*_anchorNode;
    NSDictionary *_pendingInitialFile,*_pendingNode,*_pendingConsumedFile;
    NSArray *_parents,*_names,*_nodes;NSString *_physical,*_leaf;int _anchor,_pendingFD;
}
- (instancetype)initPrivate{if((self=[super init])){_anchor=-1;_pendingFD=-1;}return self;}
- (void)dealloc{Close(_parents);if(_anchor>=0)close(_anchor);if(_pendingFD>=0)close(_pendingFD);}
- (LBXLicenseVault *)vault{return _vault;}
- (LBXLicenseOwner *)licenseOwner{return _licenseOwner;}
- (LBXContainerConfigurationStore *)configurationStore{return _configurationStore;}
- (NSString *)description{return @"<LBXLicenseInstallationEstablishment: private prepared provenance; runtimeAccepted=false>";}
- (NSString *)debugDescription{return self.description;}
- (BOOL)ancestry{if(!Caller()||!Safe(_anchor,YES)||![Node(_anchor) isEqual:_anchorNode]||!Same([_parents.lastObject intValue],_leaf,_anchor)||
    ![Physical(_paths[@"anchor"]) isEqual:_physical])return NO;
    for(NSUInteger i=0;i<_parents.count;i++){if(!Parent([_parents[i] intValue])||![Node([_parents[i] intValue]) isEqual:_nodes[i]]||
        !Same(i?[_parents[i-1] intValue]:-1,i?_names[i-1]:@"/",[_parents[i] intValue]))return NO;}return YES;}
- (BOOL)inventory:(BOOL)prepared{int fd=openat(_anchor,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *dir=fd>=0?fdopendir(fd):NULL;if(!dir){if(fd>=0)close(fd);return NO;}
    NSUInteger count=0;BOOL good=YES;for(;;){errno=0;struct dirent *e=readdir(dir);if(!e){if(errno)good=NO;break;}if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;
        if(++count>(prepared?3:1)||(!strcmp(e->d_name,"prepared.json")?!prepared:
            (!strcmp(e->d_name,"pending-establishment.json")?!prepared:strcmp(e->d_name,"intent.json")))){good=NO;break;}}
    closedir(dir);return good&&count==(prepared?3:1);}
- (NSDictionary *)read:(NSString *)name witness:(NSDictionary **)witness{int fd=openat(_anchor,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);NSDictionary *before=File(fd);BOOL good=Safe(fd,NO)&&Same(_anchor,name,fd)&&[before[@"size"] longLongValue]>0&&[before[@"size"] unsignedLongLongValue]<=32768;
    NSMutableData *data=[NSMutableData data];char buffer[4096];unsigned interruptions=0;ssize_t got=-1;
    while(good){got=read(fd,buffer,sizeof(buffer));if(got<0&&errno==EINTR&&++interruptions<=4)continue;if(got<=0)break;if(data.length+(NSUInteger)got>32768){good=NO;break;}[data appendBytes:buffer length:(NSUInteger)got];}
    good=good&&got==0&&data.length==[before[@"size"] unsignedLongLongValue]&&Safe(fd,NO)&&Same(_anchor,name,fd)&&[File(fd) isEqual:before];
    if(fd>=0)close(fd);id value=good?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    good=good&&[value isKindOfClass:NSDictionary.class]&&[JSON(value) isEqual:data];if(witness)*witness=good?before:nil;return good?value:nil;}
- (BOOL)write:(NSString *)name document:(NSDictionary *(^)(NSDictionary *node))document witness:(NSDictionary **)witness deadline:(double)deadline{
    if(![self ancestry]||!Time(deadline))return NO;int fd=openat(_anchor,name.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    BOOL good=Safe(fd,NO)&&Same(_anchor,name,fd);NSDictionary *node=good?Node(fd):nil;NSData *data=good?JSON(document(node)):nil;good=good&&data.length&&data.length<=32768;NSUInteger offset=0;unsigned interruptions=0;
    while(good&&offset<data.length){if(!Time(deadline)){good=NO;break;}ssize_t got=write(fd,(const char *)data.bytes+offset,data.length-offset);if(got<0&&errno==EINTR&&++interruptions<=4)continue;if(got<=0){good=NO;break;}offset+=(NSUInteger)got;}
    good=good&&!fsync(fd)&&!fsync(_anchor)&&Safe(fd,NO)&&Same(_anchor,name,fd)&&[Node(fd) isEqual:node]&&[self ancestry]&&Time(deadline);if(witness)*witness=good?File(fd):nil;if(fd>=0)close(fd);return good;}
- (NSDictionary *)observePolicy:(double)deadline{NSMutableDictionary *result=[NSMutableDictionary dictionary];for(NSString *key in @[@"installer",@"service",@"client"]){NSDictionary *value=Image(_paths[key],deadline);if(!value)return nil;result[key]=value;}return [result copy];}
- (NSDictionary *)pendingDocument:(NSString *)phase {
    return _pendingNode?@{@"formatVersion":@1,@"phase":phase,@"anchor":_anchorNode,@"node":_pendingNode,@"pendingDirectory":_paths[@"pending"]}:nil;
}
- (BOOL)pendingEstablishmentCurrent {
    @synchronized(self) {
    if(!Safe(_pendingFD,NO)||!Same(_anchor,@"pending-establishment.json",_pendingFD)||![Node(_pendingFD) isEqual:_pendingNode])return NO;
    NSDictionary *file=nil,*record=[self read:@"pending-establishment.json" witness:&file];
    if(!record||!Safe(_pendingFD,NO)||!Same(_anchor,@"pending-establishment.json",_pendingFD)||![File(_pendingFD) isEqual:file])return NO;
    if([JSON(record) isEqual:JSON([self pendingDocument:@"pristine"])])return !_pendingConsumedFile&&[file isEqual:_pendingInitialFile]&&
        [Digest(JSON(record)) isEqual:_prepared[@"pendingEstablishment"][@"pristineSHA256"]];
    if(![JSON(record) isEqual:JSON([self pendingDocument:@"consumed"])]||(_pendingConsumedFile&&![file isEqual:_pendingConsumedFile]))return NO;
    if(!_pendingConsumedFile)_pendingConsumedFile=[file copy];return YES;
    }
}
- (BOOL)currentBeforeDeadline:(double)deadline error:(NSError **)error {
    return [self currentBeforeDeadline:deadline namespaceObserver:^NSDictionary *{return [self->_configurationStore configurationNamespaceContextForTrustedInstaller:nil];} error:error];
}
- (BOOL)currentBeforeDeadline:(double)deadline namespaceObserver:(NSDictionary *(^)(void))observer error:(NSError **)error{if(!observer||!Process(_paths,NO)||![self ancestry]||![self inventory:YES]||!Time(deadline))return Fail(error);
    NSDictionary *intentFile=nil,*preparedFile=nil,*intent=[self read:@"intent.json" witness:&intentFile],*prepared=[self read:@"prepared.json" witness:&preparedFile];
    BOOL good=[intent isEqual:_intent]&&[prepared isEqual:_prepared]&&[intentFile isEqual:_intentFile]&&[preparedFile isEqual:_preparedFile]&&
        [[self observePolicy:deadline] isEqual:_policy]&&[[_vault installationContextForTrustedInstaller:nil] isEqual:_prepared[@"vault"]]&&
        [observer() isEqual:_prepared[@"namespace"]]&&[self pendingEstablishmentCurrent]&&Boundary(@"before_final_reobservation");
    // Long policy reads and namespace observations precede this final exact
    // read. Anchor inode alone cannot detect replacement of its children.
    NSDictionary *finalIntentFile=nil,*finalPreparedFile=nil;
    NSDictionary *finalIntent=good?[self read:@"intent.json" witness:&finalIntentFile]:nil;
    NSDictionary *finalPrepared=good?[self read:@"prepared.json" witness:&finalPreparedFile]:nil;
    good=good&&[self inventory:YES]&&[finalIntent isEqual:_intent]&&[finalPrepared isEqual:_prepared]&&
        [finalIntentFile isEqual:_intentFile]&&[finalPreparedFile isEqual:_preparedFile]&&[self pendingEstablishmentCurrent]&&[self ancestry]&&Time(deadline);
    return good?YES:Fail(error);}
- (BOOL)preparedInstallationCurrent:(NSError **)error{return [self currentBeforeDeadline:LBXLicenseIPCClock()+20 error:error];}
- (NSDictionary *)immutableWitness {
    NSData *data=JSON(@{@"anchor":_anchorNode,@"intent":_intentFile,@"prepared":_preparedFile,@"documentSHA256":Digest(JSON(_prepared))});
    return data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
}
- (NSDictionary *)privatePreparedWitness:(NSError **)error{if(![self preparedInstallationCurrent:error])return nil;return [self immutableWitness];}
- (BOOL)sourceContextForOwner:(LBXLicenseOwner *)owner store:(LBXContainerConfigurationStore *)store pendingDirectory:(NSString *)pendingDirectory deadline:(double)deadline error:(NSError **)error {
    if(!Caller()||owner!=_licenseOwner||store!=_configurationStore||![owner usesVault:_vault]||![store usesLicenseOwner:owner]||
       ![pendingDirectory isKindOfClass:NSString.class]||![pendingDirectory isEqual:_paths[@"pending"]]||![owner sourceOperationCurrentBeforeDeadline:deadline])return Fail(error);
    return YES;
}
- (NSDictionary *)consumeForInitialPendingWithLicenseOwner:(LBXLicenseOwner *)owner configurationStore:(LBXContainerConfigurationStore *)store namespaceContext:(NSDictionary *)namespaceContext pendingDirectory:(NSString *)pendingDirectory inCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;
    if(![self sourceContextForOwner:owner store:store pendingDirectory:pendingDirectory deadline:deadline error:error]||
       ![store verifyHeldEmptyNamespaceContext:namespaceContext inCurrentSourceOperationBeforeDeadline:deadline error:error])return nil;
    BOOL current=[self currentBeforeDeadline:deadline namespaceObserver:^NSDictionary *{
        return [store verifyHeldEmptyNamespaceContext:namespaceContext inCurrentSourceOperationBeforeDeadline:deadline error:nil]?namespaceContext:nil;
    } error:error];
    if(!current||![self sourceContextForOwner:owner store:store pendingDirectory:pendingDirectory deadline:deadline error:error]||
       ![store verifyHeldEmptyNamespaceContext:namespaceContext inCurrentSourceOperationBeforeDeadline:deadline error:error])return nil;
    return [self immutableWitness];
}
- (NSDictionary *)reserveInitialPendingWithLicenseOwner:(LBXLicenseOwner *)owner configurationStore:(LBXContainerConfigurationStore *)store namespaceContext:(NSDictionary *)namespaceContext pendingDirectory:(NSString *)pendingDirectory inCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;
    @synchronized(self) {
        NSDictionary *witness=[self consumeForInitialPendingWithLicenseOwner:owner configurationStore:store namespaceContext:namespaceContext
            pendingDirectory:pendingDirectory inCurrentSourceOperationBeforeDeadline:deadline error:error];
        if(!witness)return nil;
        NSDictionary *file=nil,*record=[self read:@"pending-establishment.json" witness:&file];
        NSData *terminal=JSON([self pendingDocument:@"consumed"]);
        if(_pendingConsumedFile||![JSON(record) isEqual:JSON([self pendingDocument:@"pristine"])]||![file isEqual:_pendingInitialFile]||
           !terminal.length||terminal.length>32768||!Boundary(@"before_pending_reserve")||
           ![self sourceContextForOwner:owner store:store pendingDirectory:pendingDirectory deadline:deadline error:error]||
           ![store verifyHeldEmptyNamespaceContext:namespaceContext inCurrentSourceOperationBeforeDeadline:deadline error:error]||
           ![self ancestry]||!Safe(_pendingFD,NO)||!Same(_anchor,@"pending-establishment.json",_pendingFD)||![File(_pendingFD) isEqual:file]){Fail(error);return nil;}
        // The original inode is deliberately retained. Any partial bytes are
        // terminally unavailable, never reconstructed from the pristine seed.
        NSUInteger offset=0;unsigned interruptions=0;BOOL good=YES;NSDictionary *expectedFile=file;
        while(good&&offset<terminal.length){
            if(![self sourceContextForOwner:owner store:store pendingDirectory:pendingDirectory deadline:deadline error:nil]||
               ![store verifyHeldEmptyNamespaceContext:namespaceContext inCurrentSourceOperationBeforeDeadline:deadline error:nil]||
               ![self ancestry]||!Safe(_pendingFD,NO)||!Same(_anchor,@"pending-establishment.json",_pendingFD)||![File(_pendingFD) isEqual:expectedFile]){good=NO;break;}
            ssize_t got=pwrite(_pendingFD,(const char *)terminal.bytes+offset,terminal.length-offset,(off_t)offset);
            if(got<0&&errno==EINTR&&++interruptions<=4)continue;if(got<=0){good=NO;break;}offset+=(NSUInteger)got;expectedFile=File(_pendingFD);
            if(!Boundary(@"pending_reserve_written")){good=NO;break;}
        }
        if(good)good=[self sourceContextForOwner:owner store:store pendingDirectory:pendingDirectory deadline:deadline error:nil]&&
            [store verifyHeldEmptyNamespaceContext:namespaceContext inCurrentSourceOperationBeforeDeadline:deadline error:nil]&&
            [self ancestry]&&Safe(_pendingFD,NO)&&Same(_anchor,@"pending-establishment.json",_pendingFD)&&[File(_pendingFD) isEqual:expectedFile]&&
            !ftruncate(_pendingFD,(off_t)terminal.length);
        if(good){expectedFile=File(_pendingFD);good=Boundary(@"pending_reserve_truncated");}
        if(good)good=[self sourceContextForOwner:owner store:store pendingDirectory:pendingDirectory deadline:deadline error:nil]&&
            [self ancestry]&&Safe(_pendingFD,NO)&&Same(_anchor,@"pending-establishment.json",_pendingFD)&&[File(_pendingFD) isEqual:expectedFile]&&
            !fsync(_pendingFD)&&Boundary(@"pending_reserve_synced");
        if(!good||![File(_pendingFD) isEqual:expectedFile]){Fail(error);return nil;}
        NSDictionary *confirmed=[self consumeForInitialPendingWithLicenseOwner:owner configurationStore:store namespaceContext:namespaceContext
            pendingDirectory:pendingDirectory inCurrentSourceOperationBeforeDeadline:deadline error:error];
        if(![confirmed isEqual:witness]){Fail(error);return nil;}return confirmed;
    }
}
- (NSDictionary *)privatePreparedWitnessForLicenseOwner:(LBXLicenseOwner *)owner configurationStore:(LBXContainerConfigurationStore *)store pendingDirectory:(NSString *)pendingDirectory inCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;
    if(![self sourceContextForOwner:owner store:store pendingDirectory:pendingDirectory deadline:deadline error:error])return nil;
    BOOL current=[self currentBeforeDeadline:deadline namespaceObserver:^NSDictionary *{
        return [store configurationNamespaceContextInCurrentSourceOperationBeforeDeadline:deadline error:nil];
    } error:error];
    if(!current||![self sourceContextForOwner:owner store:store pendingDirectory:pendingDirectory deadline:deadline error:error])return nil;
    return [self immutableWitness];
}
+ (instancetype)assemble:(NSDictionary *)paths sha:(NSString *)sha size:(NSUInteger)size create:(BOOL)create error:(NSError **)error{
    if(error)*error=nil;if(!ValidPaths(paths)||!Process(paths,create)||![sha isKindOfClass:NSString.class]||sha.length!=64||size==0||size>32*1024*1024){Fail(error);return nil;}
    double deadline=LBXLicenseIPCClock()+20;NSString *parent=Physical([paths[@"anchor"] stringByDeletingLastPathComponent]);if(!parent){Fail(error);return nil;}
    LBXLicenseInstallationEstablishment *value=[[self alloc] initPrivate];value->_paths=[paths copy];value->_leaf=[paths[@"anchor"] lastPathComponent];value->_physical=[parent stringByAppendingPathComponent:value->_leaf];
    NSMutableArray *fds=[NSMutableArray array],*names=[NSMutableArray array],*nodes=[NSMutableArray array];BOOL good=Parents(parent,fds,names,nodes);value->_parents=[fds copy];value->_names=[names copy];value->_nodes=[nodes copy];
    NSDictionary *policy=good?[value observePolicy:deadline]:nil;good=good&&policy&&[policy[@"client"][@"sha256"] isEqual:sha]&&[policy[@"client"][@"file"][@"size"] unsignedLongLongValue]==size;value->_policy=policy;
    int parentFD=[fds.lastObject intValue];if(!good){Fail(error);return nil;}
    if(create){
        // Before the intent, every replaceable leaf and old pending marker must
        // be absent under the verified fixed physical parent. Absence does NOT
        // authorize ordinary startup; only this explicit installer reaches here.
        for(NSString *key in @[@"vault",@"configuration",@"pending"]){struct stat n;NSString *leaf=[paths[key] lastPathComponent];if(!fstatat(parentFD,leaf.fileSystemRepresentation,&n,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT){Fail(error);return nil;}}
        NSString *pendingMarker=[NSString stringWithFormat:@".%@.socialbox-root-pending-v1.json",[paths[@"pending"] lastPathComponent]];struct stat n;
        if(!fstatat(parentFD,pendingMarker.fileSystemRepresentation,&n,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT||mkdirat(parentFD,value->_leaf.fileSystemRepresentation,0700)){Fail(error);return nil;}
    }
    value->_anchor=openat(parentFD,value->_leaf.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);value->_anchorNode=Node(value->_anchor);
    if(!Safe(value->_anchor,YES)||!Same(parentFD,value->_leaf,value->_anchor)||![value ancestry]){Fail(error);return nil;}
    if(create){
        __block NSDictionary *intent=nil;NSDictionary *intentFile=nil;good=[value write:@"intent.json" document:^NSDictionary *(NSDictionary *node){
            intent=@{@"formatVersion":@1,@"anchor":value->_anchorNode,@"parents":value->_nodes,@"paths":paths,@"policy":policy,@"node":node};return intent;
        } witness:&intentFile deadline:deadline]&&!fsync(parentFD)&&Boundary(@"intent_synced");value->_intent=intent;value->_intentFile=intentFile;
        if(!good){Fail(error);return nil;}
        value->_vault=[LBXLicenseVault createPristineDirectory:[parent stringByAppendingPathComponent:[paths[@"vault"] lastPathComponent]] error:error];if(!value->_vault||!Boundary(@"vault_created")){Fail(error);return nil;}
        value->_licenseOwner=[[LBXLicenseOwner alloc] initWithVault:value->_vault];value->_configurationStore=[LBXContainerConfigurationStore createPristineDirectory:[parent stringByAppendingPathComponent:[paths[@"configuration"] lastPathComponent]] licenseOwner:value->_licenseOwner error:error];
        if(!value->_configurationStore||!Boundary(@"configuration_created")){Fail(error);return nil;}
        NSDictionary *vault=[value->_vault installationContextForTrustedInstaller:error],*namespace=[value->_configurationStore configurationNamespaceContextForTrustedInstaller:error];
        if(!vault||!namespace||![[value observePolicy:deadline] isEqual:policy]){Fail(error);return nil;}
        __block NSDictionary *pendingSeed=nil;NSDictionary *pendingFile=nil;
        good=[value write:@"pending-establishment.json" document:^NSDictionary *(NSDictionary *node){
            value->_pendingNode=node;pendingSeed=[value pendingDocument:@"pristine"];return pendingSeed;
        } witness:&pendingFile deadline:deadline]&&Boundary(@"pending_seed_synced");
        value->_pendingInitialFile=pendingFile;
        if(!good){Fail(error);return nil;}
        value->_pendingFD=openat(value->_anchor,"pending-establishment.json",O_RDWR|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
        if(!Safe(value->_pendingFD,NO)||!Same(value->_anchor,@"pending-establishment.json",value->_pendingFD)||![File(value->_pendingFD) isEqual:pendingFile]){Fail(error);return nil;}
        __block NSDictionary *prepared=nil;NSDictionary *preparedFile=nil;good=[value write:@"prepared.json" document:^NSDictionary *(NSDictionary *node){
            prepared=@{@"formatVersion":@1,@"anchor":value->_anchorNode,@"intent":value->_intentFile,@"intentSHA256":Digest(JSON(intent)),@"vault":vault,@"namespace":namespace,@"node":node,
                @"pendingEstablishment":@{@"node":value->_pendingNode,@"pristineFile":pendingFile,@"pristineSHA256":Digest(JSON(pendingSeed))}};return prepared;
        } witness:&preparedFile deadline:deadline]&&!fsync(parentFD)&&Boundary(@"prepared_synced");value->_prepared=prepared;value->_preparedFile=preparedFile;if(!good){Fail(error);return nil;}
    }else{
        NSDictionary *intentFile=nil,*preparedFile=nil;value->_intent=[value read:@"intent.json" witness:&intentFile];value->_prepared=[value read:@"prepared.json" witness:&preparedFile];value->_intentFile=intentFile;value->_preparedFile=preparedFile;
        NSDictionary *intent=value->_intent,*prepared=value->_prepared;
        NSMutableDictionary *intentNode=[value->_intentFile mutableCopy],*preparedNode=[value->_preparedFile mutableCopy];NSArray *fileKeys=@[@"size",@"links",@"mtime",@"mtimeNS",@"ctime",@"ctimeNS"];[intentNode removeObjectsForKeys:fileKeys];[preparedNode removeObjectsForKeys:fileKeys];
        good=Exact(intent,@[@"formatVersion",@"anchor",@"parents",@"paths",@"policy",@"node"])&&Version(intent[@"formatVersion"])&&
            [intent[@"anchor"] isEqual:value->_anchorNode]&&[intent[@"parents"] isEqual:value->_nodes]&&[intent[@"paths"] isEqual:paths]&&[intent[@"policy"] isEqual:policy]&&[intent[@"node"] isEqual:intentNode]&&
            Exact(prepared,@[@"formatVersion",@"anchor",@"intent",@"intentSHA256",@"vault",@"namespace",@"node",@"pendingEstablishment"])&&Version(prepared[@"formatVersion"])&&
            [prepared[@"anchor"] isEqual:value->_anchorNode]&&[prepared[@"intent"] isEqual:value->_intentFile]&&[prepared[@"intentSHA256"] isEqual:Digest(JSON(intent))]&&[prepared[@"node"] isEqual:preparedNode];
        if(!good){Fail(error);return nil;}
        NSDictionary *seed=prepared[@"pendingEstablishment"];
        good=Exact(seed,@[@"node",@"pristineFile",@"pristineSHA256"])&&Exact(seed[@"node"],@[@"device",@"inode",@"owner",@"group",@"mode"])&&
            InitialFile(seed[@"pristineFile"]);
        if(!good){Fail(error);return nil;}value->_pendingNode=seed[@"node"];value->_pendingInitialFile=seed[@"pristineFile"];
        NSMutableDictionary *seedNode=[value->_pendingInitialFile mutableCopy];[seedNode removeObjectsForKeys:fileKeys];
        if(![seedNode isEqual:value->_pendingNode]||![seed[@"pristineSHA256"] isEqual:Digest(JSON([value pendingDocument:@"pristine"]))]){Fail(error);return nil;}
        value->_pendingFD=openat(value->_anchor,"pending-establishment.json",O_RDWR|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
        if(!Safe(value->_pendingFD,NO)||!Same(value->_anchor,@"pending-establishment.json",value->_pendingFD)||![Node(value->_pendingFD) isEqual:value->_pendingNode]){Fail(error);return nil;}
        value->_vault=[LBXLicenseVault openExistingDirectory:[parent stringByAppendingPathComponent:[paths[@"vault"] lastPathComponent]] error:error];value->_licenseOwner=value->_vault?[[LBXLicenseOwner alloc] initWithVault:value->_vault]:nil;
        value->_configurationStore=value->_licenseOwner?[LBXContainerConfigurationStore openDirectory:[parent stringByAppendingPathComponent:[paths[@"configuration"] lastPathComponent]] licenseOwner:value->_licenseOwner create:NO error:error]:nil;
        if(!value->_configurationStore)return nil;
    }
    return [value currentBeforeDeadline:deadline error:error]?value:nil;
}
+ (instancetype)prepareFixedInstallation:(NSError **)error{return [self assemble:Paths() sha:@LBX_LICENSE_CLIENT_SHA256 size:LBX_LICENSE_CLIENT_SIZE create:YES error:error];}
+ (instancetype)openFixedPreparedInstallation:(NSError **)error{return [self assemble:Paths() sha:@LBX_LICENSE_CLIENT_SHA256 size:LBX_LICENSE_CLIENT_SIZE create:NO error:error];}
#if LBX_LICENSE_INSTALLATION_TESTING
+ (instancetype)testPreparePaths:(NSDictionary *)paths clientSHA256:(NSString *)sha size:(NSUInteger)size error:(NSError **)error{return [self assemble:paths sha:sha size:size create:YES error:error];}
+ (instancetype)testOpenPaths:(NSDictionary *)paths clientSHA256:(NSString *)sha size:(NSUInteger)size error:(NSError **)error{return [self assemble:paths sha:sha size:size create:NO error:error];}
+ (void)testStopAfterBoundary:(NSString *)boundary{Stop=[boundary copy];}
+ (void)testBoundaryHandler:(void (^)(NSString *))handler{BoundaryHandler=[handler copy];}
#endif
@end
