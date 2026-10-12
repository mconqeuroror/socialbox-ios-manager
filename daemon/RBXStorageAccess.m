#import "RBXStorageAccess.h"
#import "RBXAppRegistry.h"
#import "RBXStorageGate.h"
#include <sys/file.h>
#include <fcntl.h>
#include <dirent.h>
#include <string.h>
#ifndef RBX_STORAGE_ACCESS_TESTING
#import "RBXCloneManager.h"
static uid_t RBXStorageRootOwner(void) { return 0; }
static gid_t RBXStorageRootGroup(void) { return 0; }
static uid_t RBXStorageAppOwner(void) { return 501; }
static gid_t RBXStorageAppGroup(void) { return 501; }
static uid_t RBXStorageInstallerOwner(void) { return 33; }
static gid_t RBXStorageInstallerGroup(void) { return 33; }
static NSString *RBXStorageLedgerPath(void) { return @"/var/mobile/Library/RedditBox/storage-access"; }
static NSArray *RBXStorageRegisteredTargets(NSError **error) { return [RBXCloneManager storageTargetsWithError:error]; }
#endif

static BOOL StorageError(NSError **error,NSString *message) {
    if(error)*error=[NSError errorWithDomain:@"com.redditbox.storage-access" code:errno?:EPERM userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static BOOL PathPresent(NSString *path) { struct stat s;return lstat(path.fileSystemRepresentation,&s)==0||errno!=ENOENT; }
static BOOL TargetShape(NSDictionary *target) {
    if(![target isKindOfClass:NSDictionary.class])return NO;
    for(NSString *key in @[@"appType",@"containerId",@"bundleIdentifier",@"bundlePath",@"home",@"executable"])
        if(![target[key] isKindOfClass:NSString.class]||![target[key] length])return NO;
    NSDictionary *descriptor=RBXAppDescriptorForType(target[@"appType"]);
    if(![RBXAppBundleIdentifier(descriptor,target[@"containerId"]) isEqual:target[@"bundleIdentifier"]])return NO;
    for(NSString *key in @[@"bundlePath",@"home",@"executable"])
        if(![target[key] isAbsolutePath]||![target[key] isEqual:[target[key] stringByStandardizingPath]])return NO;
    return [[target[@"executable"] stringByDeletingLastPathComponent] isEqual:target[@"bundlePath"]] && ![target[@"home"] isEqual:target[@"bundlePath"]];
}
static BOOL RecordShape(NSDictionary *record) {
    if(!TargetShape(record)||![record[@"version"] isEqual:@1]||![record[@"inodes"] isKindOfClass:NSDictionary.class])return NO;
    for(NSString *key in @[@"executable",@"bundlePath",@"home"]){
        NSDictionary *identity=record[@"inodes"][key];
        if(![identity isKindOfClass:NSDictionary.class]||![identity[@"device"] isKindOfClass:NSNumber.class]||![identity[@"inode"] isKindOfClass:NSNumber.class]||[identity[@"inode"] unsignedLongLongValue]==0)return NO;
    }
    return YES;
}
static int Ledger(NSError **error) {
    NSString *path=RBXStorageLedgerPath();
    int parent=open(path.stringByDeletingLastPathComponent.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    struct stat s;BOOL safe=parent>=0&&fstat(parent,&s)==0&&s.st_uid==RBXStorageRootOwner()&&!(s.st_mode&0022)&&RBXStorageGateNoACL(parent);
    if(safe&&mkdirat(parent,path.lastPathComponent.fileSystemRepresentation,0700)!=0&&errno!=EEXIST)safe=NO;
    if(safe)safe=fsync(parent)==0;
    int fd=safe?openat(parent,path.lastPathComponent.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):-1;
    if(parent>=0)close(parent);
    if(fd<0||fstat(fd,&s)!=0||s.st_uid!=RBXStorageRootOwner()||(s.st_mode&0077)||!RBXStorageGateNoACL(fd)){
        if(fd>=0)close(fd);StorageError(error,@"Storage ownership ledger is unavailable or unsafe");return -1;
    }
    return fd;
}
static int Lock(int directory,NSError **error) {
    int fd=openat(directory,"lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0600);struct stat s;
    if(fd<0||fstat(fd,&s)||!S_ISREG(s.st_mode)||s.st_nlink!=1||s.st_uid!=RBXStorageRootOwner()||(s.st_mode&0077)||!RBXStorageGateNoACL(fd)||flock(fd,LOCK_EX|LOCK_NB)){
        if(fd>=0)close(fd);StorageError(error,@"Another storage transition is running or its lock is unsafe");return -1;
    }
    return fd;
}
static NSDictionary *ReadRecord(int directory,NSString *bundle,NSError **error) {
    NSString *name=[bundle stringByAppendingString:@".plist"];
    int fd=openat(directory,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(fd<0){if(errno!=ENOENT)StorageError(error,@"Cannot read storage ownership receipt");return nil;}
    struct stat s;BOOL ok=fstat(fd,&s)==0&&S_ISREG(s.st_mode)&&s.st_nlink==1&&s.st_uid==RBXStorageRootOwner()&&!(s.st_mode&0077)&&s.st_size>0&&s.st_size<=16384&&RBXStorageGateNoACL(fd);
    NSMutableData *data=[NSMutableData data];char bytes[4096];
    while(ok){ssize_t n=read(fd,bytes,sizeof(bytes));if(n<0&&errno==EINTR)continue;if(n<0){ok=NO;break;}if(!n)break;[data appendBytes:bytes length:n];if(data.length>16384)ok=NO;}
    close(fd);
    NSDictionary *record=ok?[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil]:nil;
    if(!RecordShape(record)||![record[@"bundleIdentifier"] isEqual:bundle]){StorageError(error,@"Storage ownership receipt is corrupt or belongs to another clone");return nil;}
    return record;
}
static BOOL WriteRecord(int directory,NSDictionary *record,NSError **error) {
    if(!RecordShape(record))return StorageError(error,@"Invalid storage binding");
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    NSString *temp=[@".pending-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd=data.length&&data.length<=16384?openat(directory,temp.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600):-1;
    BOOL ok=fd>=0;NSUInteger position=0;
    while(ok&&position<data.length){ssize_t n=write(fd,(const char *)data.bytes+position,data.length-position);if(n<0&&errno==EINTR)continue;if(n<=0){ok=NO;break;}position+=n;}
    if(ok)ok=fsync(fd)==0;if(fd>=0&&close(fd)!=0)ok=NO;
    NSString *name=[record[@"bundleIdentifier"] stringByAppendingString:@".plist"];
    if(ok)ok=renameat(directory,temp.fileSystemRepresentation,directory,name.fileSystemRepresentation)==0&&fsync(directory)==0;
    if(!ok){unlinkat(directory,temp.fileSystemRepresentation,0);return StorageError(error,@"Cannot durably bind clone storage before changing permissions");}
    return [ReadRecord(directory,record[@"bundleIdentifier"],error) isEqual:record];
}
static int OpenTarget(NSDictionary *target,NSString *key,NSDictionary *receipt,NSError **error) {
    BOOL directory=![key isEqual:@"executable"];
    int fd=open([target[key] fileSystemRepresentation],O_RDONLY|O_NOFOLLOW|O_CLOEXEC|(directory?O_DIRECTORY:O_NONBLOCK));
    struct stat s;BOOL ok=fd>=0&&fstat(fd,&s)==0&&(directory?S_ISDIR(s.st_mode):S_ISREG(s.st_mode))&&(directory||s.st_nlink==1)&&
        (s.st_uid==RBXStorageRootOwner()||s.st_uid==RBXStorageAppOwner()||s.st_uid==RBXStorageInstallerOwner())&&RBXStorageGateNoACL(fd);
    if(ok&&receipt){NSDictionary *identity=receipt[@"inodes"][key];ok=s.st_dev==[identity[@"device"] longLongValue]&&s.st_ino==[identity[@"inode"] unsignedLongLongValue]&&[target[key] isEqual:receipt[key]];}
    if(!ok){if(fd>=0)close(fd);StorageError(error,@"Clone storage path, inode, ownership or ACL changed");return -1;}
    return fd;
}
static BOOL ReceiptGone(NSDictionary *record) {
    return !PathPresent(record[@"bundlePath"])&&!PathPresent(record[@"home"]);
}
static NSArray *Records(int directory,NSError **error) {
    DIR *listing=fdopendir(dup(directory));if(!listing){StorageError(error,@"Cannot enumerate storage ownership receipts");return nil;}
    NSMutableArray *records=[NSMutableArray array];BOOL ok=YES;unsigned count=0;
    for(;;){errno=0;struct dirent *e=readdir(listing);if(!e){if(errno)ok=NO;break;}if(++count>8192){ok=NO;break;}
        NSString *name=@(e->d_name);if(![name hasSuffix:@".plist"])continue;
        NSDictionary *record=ReadRecord(directory,name.stringByDeletingPathExtension,error);if(!record){ok=NO;break;}[records addObject:record];
    }closedir(listing);if(!ok){StorageError(error,@"Storage ownership inventory cannot be proven");return nil;}return records;
}
// Close each still-present recorded object even when another one was lost. A
// partial registration/receipt cannot authorize a new launch, but must not stop
// revocation of the remaining intact siblings.
static BOOL SealRecords(NSArray *records,NSError **error) {
    BOOL ok=YES;
    for(NSString *key in @[@"executable",@"home",@"bundlePath"])for(NSDictionary *record in records){
        if(ReceiptGone(record))continue;
        int fd=OpenTarget(record,key,record,error);
        if(fd<0){ok=NO;continue;}
        if(!RBXStorageGateSet(fd,RBXStorageRootOwner(),RBXStorageRootGroup(),[key isEqual:@"executable"]?0600:0700)){ok=NO;StorageError(error,@"Could not seal every recorded clone object");}close(fd);
    }
    return ok;
}
static NSDictionary *Adopt(int directory,NSDictionary *target,NSError **error) {
    if(!TargetShape(target)){StorageError(error,@"Registered storage target has no exact app identity");return nil;}
    NSError *readError=nil;NSDictionary *record=ReadRecord(directory,target[@"bundleIdentifier"],&readError);
    if(readError){if(error)*error=readError;return nil;}
    if(record&&ReceiptGone(record))record=nil; // old objects proven absent; new installation gets a new binding.
    NSMutableDictionary *next=[target mutableCopy];next[@"version"]=@1;NSMutableDictionary *inodes=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"executable",@"bundlePath",@"home"]){int fd=OpenTarget(target,key,record,error);if(fd<0)return nil;struct stat s;BOOL ok=fstat(fd,&s)==0;close(fd);if(!ok){StorageError(error,@"Cannot bind storage inode");return nil;}inodes[key]=@{@"device":@(s.st_dev),@"inode":@(s.st_ino)};}
    next[@"inodes"]=inodes;
    if(record&&![record isEqual:next]){StorageError(error,@"Storage registration changed while previous objects still exist");return nil;}
    return record?: (WriteRecord(directory,next,error)?next:nil);
}
static BOOL PathsStillPinned(NSArray *records) {
    for(NSDictionary *record in records)for(NSString *key in @[@"executable",@"bundlePath",@"home"]){int fd=OpenTarget(record,key,record,nil);if(fd<0)return NO;close(fd);}return YES;
}
typedef struct { __unsafe_unretained NSArray *records; __unsafe_unretained BOOL (^authorized)(void); } StorageAuthorization;
static bool MayOpen(void *opaque) { StorageAuthorization *a=opaque;return a->authorized&&a->authorized()&&PathsStillPinned(a->records); }

@implementation RBXStorageAccess
+ (BOOL)closeAll:(NSError **)error { return [self transition:nil authorized:nil error:error]; }
+ (BOOL)openProfile:(NSDictionary *)profile authorized:(BOOL (^)(void))authorized error:(NSError **)error {
    if(![profile isKindOfClass:NSDictionary.class]||![profile[@"app"] isKindOfClass:NSDictionary.class]||![profile[@"app"][@"bundlePath"] isKindOfClass:NSString.class]||!authorized)return StorageError(error,@"Storage admission requires an exact profile and live process authority");
    return [self transition:profile authorized:authorized error:error];
}
+ (BOOL)transition:(NSDictionary *)profile authorized:(BOOL (^)(void))authorized error:(NSError **)error {
    @synchronized(self){
        int directory=Ledger(error);if(directory<0)return NO;int lock=Lock(directory,error);if(lock<0){close(directory);return NO;}
        BOOL success=NO;RBXStorageGateEntry *entries=NULL;NSUInteger opened=0;
        @try {
            NSArray *previous=Records(directory,error);if(!previous)return NO;
            BOOL sealed=SealRecords(previous,error);
            NSArray *targets=RBXStorageRegisteredTargets(error);if(!targets||targets.count>4096)return NO;
            NSMutableArray *current=[NSMutableArray array];NSMutableSet *bundles=[NSMutableSet set];
            for(NSDictionary *target in targets){
                NSDictionary *record=Adopt(directory,target,error);if(!record||[bundles containsObject:record[@"bundleIdentifier"]]){SealRecords(current,nil);return StorageError(error,@"Cannot adopt a unique complete registered storage inventory");}
                [bundles addObject:record[@"bundleIdentifier"]];[current addObject:record];
            }
            BOOL complete=sealed;
            for(NSDictionary *record in previous)if(![bundles containsObject:record[@"bundleIdentifier"]]&&!ReceiptGone(record))complete=NO;
            if(!complete){SealRecords(current,nil);return StorageError(error,@"Unresolved or orphaned clone storage prevents admission");}
            if(!current.count)return profile?StorageError(error,@"Selected clone has no registered storage"):YES;
            entries=calloc(current.count,sizeof(*entries));if(!entries){SealRecords(current,nil);return StorageError(error,@"Cannot allocate storage transition");}
            NSUInteger selected=current.count;
            for(NSDictionary *record in current){
                RBXStorageGateEntry *e=&entries[opened++];e->executable=e->bundle=e->home=-1;
                e->executable=OpenTarget(record,@"executable",record,error);e->bundle=OpenTarget(record,@"bundlePath",record,error);e->home=OpenTarget(record,@"home",record,error);
                if(e->executable<0||e->bundle<0||e->home<0){SealRecords(current,nil);return NO;}
                e->executableDevice=[record[@"inodes"][@"executable"][@"device"] longLongValue];e->executableInode=[record[@"inodes"][@"executable"][@"inode"] unsignedLongLongValue];
                e->bundleDevice=[record[@"inodes"][@"bundlePath"][@"device"] longLongValue];e->bundleInode=[record[@"inodes"][@"bundlePath"][@"inode"] unsignedLongLongValue];
                e->homeDevice=[record[@"inodes"][@"home"][@"device"] longLongValue];e->homeInode=[record[@"inodes"][@"home"][@"inode"] unsignedLongLongValue];
                if(profile&&[record[@"containerId"] isEqual:profile[@"containerId"]]&&[record[@"appType"] isEqual:RBXAppDescriptorForProfile(profile)[@"appType"]]&&[record[@"bundleIdentifier"] isEqual:profile[@"app"][@"bundleIdentifier"]]&&[record[@"bundlePath"] isEqual:[profile[@"app"][@"bundlePath"] stringByResolvingSymlinksInPath]])selected=opened-1;
            }
            StorageAuthorization a={current,authorized};
            success=RBXStorageGateTransition(entries,current.count,selected,RBXStorageRootOwner(),RBXStorageRootGroup(),RBXStorageAppOwner(),RBXStorageAppGroup(),RBXStorageInstallerOwner(),profile?MayOpen:NULL,&a);
            if(profile&&selected==current.count)success=StorageError(error,@"Selected profile does not match registered clone storage");
            if(!success){SealRecords(current,nil);StorageError(error,@"Storage transition was refused or its authority was revoked");}
            return success;
        } @finally {for(NSUInteger i=0;i<opened;i++){if(entries[i].executable>=0)close(entries[i].executable);if(entries[i].bundle>=0)close(entries[i].bundle);if(entries[i].home>=0)close(entries[i].home);}free(entries);flock(lock,LOCK_UN);close(lock);close(directory);}
    }
}
+ (BOOL)performInstallerMaintenanceForBundle:(NSString *)bundle expectedBundlePath:(NSString *)path
                                  operation:(BOOL (^)(NSError **))operation error:(NSError **)error {
    if(!operation)return StorageError(error,@"Installer maintenance needs an operation");
    NSDictionary *descriptor=RBXAppDescriptorForBundleIdentifier(bundle);
    if(!RBXAppOwnsCloneBundleIdentifier(descriptor,bundle))return operation(error);
    @synchronized(self){
        int directory=Ledger(error);if(directory<0)return NO;
        int lock=Lock(directory,error);if(lock<0){close(directory);return NO;}
        int code=-1,main=-1;NSArray *records=nil;BOOL result=NO;
        @try {
            NSError *failure=nil;NSDictionary *record=ReadRecord(directory,bundle,&failure);
            if(failure){if(error)*error=failure;return NO;}
            // No receipt means this installation was never adopted/permission
            // changed by us. Its normal removal guards still apply unchanged.
            if(!record)return operation(error);
            if(![record[@"bundlePath"] isEqual:path.stringByResolvingSymlinksInPath])return StorageError(error,@"Installer target differs from the storage receipt");
            records=Records(directory,error);if(!records||!SealRecords(records,error))return NO;
            if(ReceiptGone(record))return operation(error);
            code=OpenTarget(record,@"bundlePath",record,error);main=OpenTarget(record,@"executable",record,error);
            if(code<0||main<0)return NO;
            // Only the service group can inspect the code; mobile gets no new
            // permission and no home permission changes occur here.
            if(!RBXStorageGateSet(main,RBXStorageRootOwner(),RBXStorageInstallerGroup(),0640)||
               !RBXStorageGateSet(code,RBXStorageRootOwner(),RBXStorageInstallerGroup(),0750)||
               !PathsStillPinned(@[record]))return StorageError(error,@"Could not authorize installer code inspection");
            result=operation(error);
        } @finally {
            if(records&&!SealRecords(records,error))result=NO;
            if(code>=0)close(code);if(main>=0)close(main);
            flock(lock,LOCK_UN);close(lock);close(directory);
        }
        return result;
    }
}
+ (BOOL)ownsClosedHome:(NSString *)home bundleIdentifier:(NSString *)bundle error:(NSError **)error {
    if(![home isKindOfClass:NSString.class]||![bundle isKindOfClass:NSString.class]||!RBXAppDescriptorForBundleIdentifier(bundle))return NO;
    int directory=Ledger(error);if(directory<0)return NO;
    NSDictionary *record=ReadRecord(directory,bundle,error);close(directory);
    struct stat supplied;
    if(lstat(home.fileSystemRepresentation,&supplied)||!S_ISDIR(supplied.st_mode)||![record[@"home"] isEqual:home.stringByResolvingSymlinksInPath])return NO;
    int fd=OpenTarget(record,@"home",record,error);if(fd<0)return NO;
    struct stat s;BOOL valid=fstat(fd,&s)==0&&s.st_dev==supplied.st_dev&&s.st_ino==supplied.st_ino&&s.st_uid==RBXStorageRootOwner()&&s.st_gid==RBXStorageRootGroup()&&(s.st_mode&07777)==0700;close(fd);
    return valid;
}
@end
