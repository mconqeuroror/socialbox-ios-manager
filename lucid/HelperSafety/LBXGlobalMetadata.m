#import "LBXGlobalMetadata.h"
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <os/log.h>

static const size_t LBXMetadataLimit=16*1024*1024;
static double LBXMetadataClock(void){struct timespec t;return clock_gettime(CLOCK_MONOTONIC,&t)?0:(double)t.tv_sec+(double)t.tv_nsec/1e9;}
static BOOL LBXStableNode(struct stat a,struct stat b) {
    return a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_size==b.st_size &&
        a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec;
}
static BOOL LBXMetadataNode(struct stat node) {
    return S_ISREG(node.st_mode) && node.st_nlink==1 && !(node.st_mode&0022) &&
        (node.st_uid==getuid() || node.st_uid==geteuid() || (geteuid()==0 && node.st_uid==501));
}
static int LBXMetadataDirectory(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath ||
        [path.pathComponents containsObject:@".."] || [path.pathComponents containsObject:@"."] ||
        [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound ||
        ![path.lastPathComponent isEqual:@"global_metadata.plist"]) return -1;
    int fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);if(fd<0)return -1;
    for(NSString *part in path.stringByDeletingLastPathComponent.pathComponents) {
        if([part isEqual:@"/"])continue;
        int next=openat(fd,part.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(next<0 && errno==ENOENT) {
            if(mkdirat(fd,part.fileSystemRepresentation,0755) && errno!=EEXIST){close(fd);return -1;}
            next=openat(fd,part.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        }
        close(fd);fd=next;if(fd<0)return -1;
    }
    struct stat node;
    if(fstat(fd,&node) || !S_ISDIR(node.st_mode) || (node.st_mode&0022) ||
        !(node.st_uid==getuid() || node.st_uid==geteuid() || (geteuid()==0 && node.st_uid==501))) {close(fd);return -1;}
    return fd;
}
static BOOL LBXLockMetadata(int fd) {
    double now=LBXMetadataClock(),deadline=now+.5;if(now<=0)return NO;
    do {
        if(!flock(fd,LOCK_EX|LOCK_NB))return YES;
        if(errno!=EWOULDBLOCK && errno!=EAGAIN && errno!=EINTR)return NO;
        usleep(5000);now=LBXMetadataClock();
    }while(now>0 && now<deadline);
    return NO;
}
static BOOL LBXMetadataTransaction(NSString *path,NSDictionary *replacement,void (^mutation)(NSMutableDictionary *)) {
    if((replacement!=nil)==(mutation!=nil))return NO;
    int directory=LBXMetadataDirectory(path);if(directory<0)return NO;
    const char *name="global_metadata.plist",*lockName="global_metadata.plist.lock";
    int lock=-1,input=-1,output=-1;NSString *temporary=nil;BOOL locked=NO,published=NO,result=NO;
    @try {
        do {
            lock=openat(directory,lockName,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0644);
            struct stat lockNode,lockPath;
            if(lock<0 || fstat(lock,&lockNode) || !LBXMetadataNode(lockNode) || !LBXLockMetadata(lock))break;
            locked=YES;
            if(fstatat(directory,lockName,&lockPath,AT_SYMLINK_NOFOLLOW) || lockNode.st_dev!=lockPath.st_dev || lockNode.st_ino!=lockPath.st_ino)break;
            input=openat(directory,name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
            BOOL missing=input<0 && errno==ENOENT;
            if(input<0 && !missing)break;
            struct stat before={0},after={0};NSMutableDictionary *metadata=nil;
            if(!missing) {
                if(fstat(input,&before) || !LBXMetadataNode(before) || before.st_size<=0 || (uint64_t)before.st_size>LBXMetadataLimit)break;
                NSMutableData *bytes=[NSMutableData dataWithLength:(NSUInteger)before.st_size];size_t done=0;
                while(done<bytes.length) {
                    ssize_t count=read(input,(char *)bytes.mutableBytes+done,bytes.length-done);
                    if(count<0 && errno==EINTR)continue;if(count<=0)break;done+=(size_t)count;
                }
                if(done!=bytes.length || fstat(input,&after) || !LBXStableNode(before,after))break;
                id parsed=[NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListMutableContainersAndLeaves format:NULL error:nil];
                if(![parsed isKindOfClass:NSMutableDictionary.class])break; // never reset corruption to an empty account list
                metadata=parsed;
            } else metadata=[@{@"version":@2,@"activeContainer":@0,@"nextContainerID":@1,@"containers":[NSMutableArray array]} mutableCopy];
            if(mutation)mutation(metadata);
            else {
                if(![replacement isKindOfClass:NSDictionary.class])break;
                metadata=[replacement mutableCopy];
            }
            NSData *encoded=[NSPropertyListSerialization dataWithPropertyList:metadata format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
            if(!encoded || !encoded.length || encoded.length>LBXMetadataLimit)break;
            temporary=[@".global_metadata.plist.socialbox." stringByAppendingString:NSUUID.UUID.UUIDString];
            output=openat(directory,temporary.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
            if(output<0)break;
            size_t done=0;
            while(done<encoded.length) {
                ssize_t count=write(output,(const char *)encoded.bytes+done,encoded.length-done);
                if(count<0 && errno==EINTR)continue;if(count<=0)break;done+=(size_t)count;
            }
            if(done!=encoded.length)break;
            struct stat created;if(fstat(output,&created) || !LBXMetadataNode(created))break;
            uid_t uid=missing?created.st_uid:before.st_uid;gid_t gid=missing?created.st_gid:before.st_gid;
            if((created.st_uid!=uid || created.st_gid!=gid) && fchown(output,uid,gid))break;
            if(fchmod(output,missing?0644:(before.st_mode&0777)) || fsync(output))break;
            // Detect non-cooperating writers, changed lock files and a moved
            // parent before commit. This is not a fence against malicious root.
            struct stat current,parent,location;
            if(fstatat(directory,lockName,&lockPath,AT_SYMLINK_NOFOLLOW) || lockPath.st_dev!=lockNode.st_dev || lockPath.st_ino!=lockNode.st_ino)break;
            if(fstat(directory,&parent) || lstat(path.stringByDeletingLastPathComponent.fileSystemRepresentation,&location) ||
                parent.st_dev!=location.st_dev || parent.st_ino!=location.st_ino)break;
            int observed=fstatat(directory,name,&current,AT_SYMLINK_NOFOLLOW);
            if(missing ? !(observed<0 && errno==ENOENT) : (observed || !LBXStableNode(before,current)))break;
            if(renameat(directory,temporary.fileSystemRepresentation,directory,name))break;
            published=YES;
            if(fsync(directory))break;
            result=YES;
        }while(0);
    } @catch(__unused NSException *exception) {
        // Internal mutation failures must release the file lock. Exception text
        // can contain identity/session values and is intentionally not logged.
    } @finally {
        if(output>=0)close(output);
        if(temporary && !published)unlinkat(directory,temporary.fileSystemRepresentation,0);
        if(input>=0)close(input);
        if(locked)flock(lock,LOCK_UN);
        if(lock>=0)close(lock);
        close(directory);
    }
    if(!result)os_log_error(OS_LOG_DEFAULT,"LBX_METADATA write failed; published=%{public}s",published?"yes_durability_unknown":"no");
    return result;
}
BOOL LBXWriteGlobalMetadata(NSString *path,NSDictionary *metadata){return LBXMetadataTransaction(path,metadata,nil);}
BOOL LBXMutateGlobalMetadata(NSString *path,void (^mutation)(NSMutableDictionary *)){return LBXMetadataTransaction(path,nil,mutation);}
