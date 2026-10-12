// ACCEPT-002/003: temporary on-device observer. No gate/IPC/keychain mutation.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <limits.h>
#include <errno.h>
#include <stdlib.h>
#include "RBXMemoryBudget.h"

static void emit(NSDictionary *value) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    [NSFileHandle.fileHandleWithStandardOutput writeData:data];
}
// Boxed C comparisons are NSNumber integers, not JSON booleans. The host
// deliberately requires real booleans before accepting mechanical evidence.
static NSNumber *RBXProbeBoolean(BOOL value) { return value ? @YES : @NO; }
static BOOL safeTemporaryDirectory(NSString *value) {
    char resolved[PATH_MAX];
    if (!realpath(value.fileSystemRepresentation,resolved)) return NO;
    NSString *canonical=[NSString stringWithUTF8String:resolved];
    // iOS realpath uses /private/var. No caller-selected shared/root location.
    NSString *prefix=@"/private/var/mobile/Containers/Data/Application/";
    if (![canonical hasPrefix:prefix]) return NO;
    NSArray *pieces=[[canonical substringFromIndex:prefix.length] componentsSeparatedByString:@"/"];
    return pieces.count==2 && [pieces[0] length]==36 && [pieces[1] isEqual:@"tmp"];
}
static int directoryAt(int parent, const char *name, uid_t owner, mode_t mode, BOOL create) {
    BOOL made=NO;
    if (create && mkdirat(parent,name,mode)==0) made=YES;
    int fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
    if (fd<0) return -1;
    if (made && (fchown(fd,owner,owner) || fchmod(fd,mode))) { close(fd); return -1; }
    struct stat st={0};
    if (fstat(fd,&st) || st.st_uid!=owner || (st.st_mode&0777)!=mode) { close(fd); return -1; }
    return fd;
}
static int acceptanceDirectory(NSString *root, BOOL create) {
    char canonical[PATH_MAX];
    if (!realpath(root.fileSystemRepresentation,canonical)) return -1;
    NSString *path=[NSString stringWithUTF8String:canonical];
    NSString *prefix=@"/private/var/mobile/Containers/Data/Application/";
    NSString *tail=[path hasPrefix:prefix] ? [path substringFromIndex:prefix.length] : @"";
    if (tail.length!=36 || [tail containsString:@"/"]) return -1;
    int fd=open(canonical,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
    if (fd<0) return -1;
    // Existing user-owned parents keep their modes; never chmod an app directory.
    const char *parents[]={"Library","Application Support","RedditBox"};
    for (int i=0;i<3;i++) {
        BOOL made=create && mkdirat(fd,parents[i],0700)==0;
        int child=openat(fd,parents[i],O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
        if (child<0) { close(fd); return -1; }
        if (made && (fchown(child,501,501)||fchmod(child,0700))) { close(child); close(fd); return -1; }
        struct stat st={0};
        if (fstat(child,&st)||st.st_uid!=501||(st.st_mode&0022)) { close(child); close(fd); return -1; }
        close(fd); fd=child;
    }
    int result=directoryAt(fd,"acceptance",0,0755,create);
    close(fd); return result;
}
static NSDictionary *requestAt(int dir) {
    int fd=openat(dir,"request.json",O_RDONLY|O_NOFOLLOW);
    if (fd<0) return errno==ENOENT ? @{} : nil;
    struct stat st={0};
    if (fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=0||st.st_nlink!=1||
        (st.st_mode&0777)!=0444||st.st_size<2||st.st_size>4096) { close(fd); return nil; }
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)st.st_size];
    ssize_t count=read(fd,data.mutableBytes,data.length); close(fd);
    id request=count==(ssize_t)data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [request isKindOfClass:NSDictionary.class] ? request : nil;
}
static int acceptanceLock(int dir) {
    int fd=openat(dir,".preparation-lock",O_RDWR|O_CREAT|O_NOFOLLOW,0600);
    struct stat st={0};
    if (fd<0) return -1;
    if (fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=0||st.st_nlink!=1||
        (st.st_mode&0777)!=0600||flock(fd,LOCK_EX)) { close(fd); return -1; }
    return fd;
}
static BOOL validNonce(NSString *nonce) {
    return [nonce isKindOfClass:NSString.class] && nonce.length==36 && [[NSUUID alloc] initWithUUIDString:nonce]!=nil;
}
static BOOL prepareCanary(NSString *root, NSData *bytes) {
    if (getuid()!=0||bytes.length>4096) return NO;
    id parsed=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    if (![parsed isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *request=parsed;
    NSString *nonce=request[@"nonce"], *target=request[@"targetBundleId"];
    if (!validNonce(nonce)||![target isKindOfClass:NSString.class]||!target.length||
        ![@[@"seed",@"verify",@"cleanup"] containsObject:request[@"operation"]]) return NO;
    int dir=acceptanceDirectory(root,YES);
    if (dir<0) return NO;
    int lock=acceptanceLock(dir);
    if (lock<0) { close(dir); return NO; }
    int results=directoryAt(dir,"results",501,0700,YES);
    NSDictionary *existing=requestAt(dir);
    BOOL allowed=results>=0 && existing && (!existing.count ||
        ([existing[@"nonce"] isEqual:nonce] && [existing[@"targetBundleId"] isEqual:target]));
    if (results>=0) close(results);
    NSString *temporary=[@".request-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int out=allowed ? openat(dir,temporary.UTF8String,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600) : -1;
    BOOL ok=out>=0 && write(out,bytes.bytes,bytes.length)==(ssize_t)bytes.length &&
        !fsync(out) && !fchmod(out,0444);
    if (out>=0) close(out);
    if (ok) ok=renameat(dir,temporary.UTF8String,dir,"request.json")==0;
    if (out>=0 && !ok) unlinkat(dir,temporary.UTF8String,0);
    close(lock); close(dir); return ok;
}
static NSData *canaryDataAt(int dir, NSString *name, NSUInteger maximum) {
    int fd=openat(dir,name.UTF8String,O_RDONLY|O_NOFOLLOW);
    if (fd<0) return nil;
    struct stat st={0};
    if (fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=501||st.st_nlink!=1||
        (st.st_mode&0777)!=0600||st.st_size<0||st.st_size>(off_t)maximum) { close(fd); return nil; }
    NSMutableData *bytes=[NSMutableData dataWithLength:(NSUInteger)st.st_size];
    ssize_t count=read(fd,bytes.mutableBytes,bytes.length); close(fd);
    return count==(ssize_t)bytes.length ? bytes : nil;
}
static NSDictionary *observeCanary(NSString *root, NSString *nonce, NSString *operation) {
    if (!validNonce(nonce)||![@[@"seed",@"verify",@"cleanup",@"sentinel"] containsObject:operation]) return @{};
    int dir=acceptanceDirectory(root,NO);
    if (dir<0) return @{};
    int results=directoryAt(dir,"results",501,0700,NO); close(dir);
    if (results<0) return @{};
    NSString *name=[operation isEqual:@"sentinel"] ? [nonce stringByAppendingString:@".sentinel"] :
        [NSString stringWithFormat:@"%@-%@.json",nonce,operation];
    NSData *bytes=canaryDataAt(results,name,16384); close(results);
    if ([operation isEqual:@"sentinel"]) return @{@"matches":RBXProbeBoolean([bytes isEqual:[nonce dataUsingEncoding:NSUTF8StringEncoding]]),
        @"observedAt":@(NSDate.date.timeIntervalSince1970)};
    id result=bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
    return [result isKindOfClass:NSDictionary.class] ? result : @{};
}
static NSDictionary *deletionSummary(NSString *identifier) {
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    if (!identifier.length || identifier.length>180 || [identifier rangeOfCharacterFromSet:allowed.invertedSet].location!=NSNotFound) return @{};
    int dir=open("/var/mobile/Library/RedditBox/deletions",O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
    struct stat st={0};
    if (dir<0) return @{};
    if (fstat(dir,&st)||st.st_uid!=0||(st.st_mode&0077)) { close(dir); return @{}; }
    NSString *name=[identifier stringByAppendingString:@".plist"];
    int fd=openat(dir,name.UTF8String,O_RDONLY|O_NOFOLLOW|O_NONBLOCK); close(dir);
    if (fd<0) return @{};
    if (fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=0||st.st_nlink!=1||(st.st_mode&0077)||
        st.st_size<1||st.st_size>2*1024*1024) { close(fd); return @{}; }
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)st.st_size];
    ssize_t count=read(fd,data.mutableBytes,data.length); close(fd);
    id raw=count==(ssize_t)data.length ? [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil] : nil;
    if (![raw isKindOfClass:NSDictionary.class]) return @{};
    NSDictionary *record=raw, *target=[record[@"target"] isKindOfClass:NSDictionary.class] ? record[@"target"] : @{};
    BOOL valid=[record[@"containerId"] isEqual:identifier] && [record[@"formatVersion"] isEqual:@1];
    return @{@"valid":RBXProbeBoolean(valid),@"phase":[record[@"phase"] isKindOfClass:NSString.class] ? record[@"phase"] : @"",
        @"bundleIdentifier":[target[@"bundleIdentifier"] isKindOfClass:NSString.class] ? target[@"bundleIdentifier"] : @"",
        @"accessGroup":[target[@"keychainAccessGroup"] isKindOfClass:NSString.class] ? target[@"keychainAccessGroup"] : @"",
        @"updatedAt":[record[@"updatedAt"] isKindOfClass:NSNumber.class] ? record[@"updatedAt"] : @0,
        @"recoveryEvidence":RBXProbeBoolean(record[@"profileEvidence"]!=nil||record[@"finalProfileEvidence"]!=nil||record[@"profileReadError"]!=nil)};
}
static BOOL removeCanaryControls(NSString *root, NSString *nonce) {
    if (getuid()!=0||!validNonce(nonce)) return NO;
    int dir=acceptanceDirectory(root,NO);
    if (dir<0) return NO;
    int lock=acceptanceLock(dir);
    if (lock<0) { close(dir); return NO; }
    NSDictionary *existing=requestAt(dir);
    BOOL ok=existing && (!existing.count || ([existing[@"nonce"] isEqual:nonce] && !unlinkat(dir,"request.json",0)));
    int results=directoryAt(dir,"results",501,0700,NO);
    if (results<0) ok=NO;
    if (results>=0 && ok) for (NSString *operation in @[@"seed",@"verify",@"cleanup"]) {
        NSString *name=[NSString stringWithFormat:@"%@-%@.json",nonce,operation];
        struct stat st={0}; errno=0;
        if (fstatat(results,name.UTF8String,&st,AT_SYMLINK_NOFOLLOW)<0) { if (errno!=ENOENT) ok=NO; continue; }
        if (!S_ISREG(st.st_mode)||st.st_uid!=501||st.st_nlink!=1||unlinkat(results,name.UTF8String,0)) ok=NO;
    }
    if (results>=0) close(results);
    close(lock); close(dir); return ok;
}
int main(int argc, const char *argv[]) { @autoreleasepool {
    alarm(8); // Bound observer lifetime even if the SSH client disconnects.
    if (argc==3 && strcmp(argv[1],"--prepare-canary")==0) {
        NSData *bytes=[NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
        emit(@{@"prepared":RBXProbeBoolean(prepareCanary([NSString stringWithUTF8String:argv[2]],bytes))}); return 0;
    }
    if (argc==4 && strcmp(argv[1],"--remove-canary-controls")==0) {
        emit(@{@"cleaned":RBXProbeBoolean(removeCanaryControls([NSString stringWithUTF8String:argv[2]],
            [NSString stringWithUTF8String:argv[3]]))}); return 0;
    }
    if (argc==5 && strcmp(argv[1],"--observe-canary")==0) {
        emit(observeCanary([NSString stringWithUTF8String:argv[2]],[NSString stringWithUTF8String:argv[3]],
            [NSString stringWithUTF8String:argv[4]])); return 0;
    }
    if (argc==3 && strcmp(argv[1],"--deletion-summary")==0) {
        emit(deletionSummary([NSString stringWithUTF8String:argv[2]])); return 0;
    }
    if (argc==3 && strcmp(argv[1],"--pid")==0) {
        char *end=NULL; long number=strtol(argv[2],&end,10);
        if (!end || *end || number<=1 || number>INT_MAX) return 2;
        int (*pidpath)(int,void *,uint32_t)=dlsym(RTLD_DEFAULT,"proc_pidpath");
        char executable[4096]={0}; int pathResult=pidpath ? pidpath((int)number,executable,sizeof(executable)) : -1;
        RBXMemoryControl control=dlsym(RTLD_DEFAULT,"memorystatus_control");
        RBXMemoryLimits limits={0}; errno=0;
        // GET_MEMLIMIT_PROPERTIES only. Never call SET_MEMLIMIT_PROPERTIES (7).
        int result=control ? control(8,(int)number,0,&limits,sizeof(limits)) : -1;
        emit(@{@"path":pathResult>0 ? [NSString stringWithUTF8String:executable] : @"",
            @"memoryRead":RBXProbeBoolean(result==0),@"activeMiB":@(limits.active),@"inactiveMiB":@(limits.inactive),
            @"errorNumber":@(result ? errno : 0)}); return 0;
    }
    if (argc==3 && strcmp(argv[1],"--exists")==0) {
        struct stat item={0}; errno=0; int result=lstat(argv[2],&item); int failure=errno;
        emit(@{@"exists":RBXProbeBoolean(result==0),@"absent":RBXProbeBoolean(result<0 && failure==ENOENT),@"errorNumber":@(result ? failure : 0)}); return 0;
    }
    if (argc==3 && strcmp(argv[1],"--realpath")==0) {
        char resolved[PATH_MAX];
        BOOL ok=realpath(argv[2],resolved)!=NULL;
        emit(@{@"path":ok ? [NSString stringWithUTF8String:resolved] : @""}); return 0;
    }
    if (argc==4 && strcmp(argv[1],"--storage-sentinel")==0) {
        NSString *a=[NSString stringWithUTF8String:argv[2]], *b=[NSString stringWithUTF8String:argv[3]];
        if (!safeTemporaryDirectory(a) || !safeTemporaryDirectory(b)) {
            emit(@{@"created":@NO,@"absentInB":@NO,@"cleaned":@YES,@"safePaths":@NO}); return 0;
        }
        int left=open(a.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
        int right=open(b.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
        struct stat ls={0},rs={0};
        BOOL distinct=left>=0 && right>=0 && !fstat(left,&ls) && !fstat(right,&rs) &&
            (ls.st_dev!=rs.st_dev || ls.st_ino!=rs.st_ino);
        NSString *name=[@"redditbox-acceptance-" stringByAppendingString:NSUUID.UUID.UUIDString];
        int marker=distinct ? openat(left,name.UTF8String,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600) : -1;
        BOOL created=marker>=0;
        if (marker>=0) { const char bytes[]="disposable acceptance marker\n"; if (write(marker,bytes,sizeof(bytes)-1)!=(ssize_t)sizeof(bytes)-1) created=NO; close(marker); }
        struct stat found; errno=0;
        BOOL absent=distinct && fstatat(right,name.UTF8String,&found,AT_SYMLINK_NOFOLLOW)<0 && errno==ENOENT;
        BOOL cleaned=marker<0 || unlinkat(left,name.UTF8String,0)==0;
        if (left>=0) close(left); if (right>=0) close(right);
        emit(@{@"created":RBXProbeBoolean(created),@"absentInB":RBXProbeBoolean(absent),@"cleaned":RBXProbeBoolean(cleaned),@"safePaths":@YES}); return 0;
    }
    return 2;
} }
