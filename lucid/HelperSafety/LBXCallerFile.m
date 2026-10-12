#import "LBXCallerFile.h"
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

static BOOL LBXCallerNode(struct stat node,off_t size) {
    return S_ISREG(node.st_mode) && node.st_uid==0 && !(node.st_mode&0022) &&
        node.st_nlink==1 && node.st_size==size;
}
static BOOL LBXCallerUnchanged(struct stat a,struct stat b) {
    return a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_uid==b.st_uid &&
        a.st_gid==b.st_gid && a.st_mode==b.st_mode && a.st_nlink==b.st_nlink && a.st_size==b.st_size &&
        a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec;
}
BOOL LBXVerifyCallerFile(NSString *path,off_t expectedSize,NSString *expectedSHA256) {
    if(![path isKindOfClass:NSString.class] || !path.isAbsolutePath ||
       [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound ||
       ![expectedSHA256 isKindOfClass:NSString.class] || expectedSHA256.length!=64 ||
       expectedSize<=0 || expectedSize>32*1024*1024) return NO;
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(fd<0)return NO;
    BOOL valid=NO;
    @try {
        struct stat before,after,named;
        if(!fstat(fd,&before) && LBXCallerNode(before,expectedSize)) {
            CC_SHA256_CTX context;CC_SHA256_Init(&context);
            unsigned char buffer[16384],digest[CC_SHA256_DIGEST_LENGTH];
            off_t total=0;unsigned interruptions=0;
            while(total<expectedSize) {
                ssize_t count=read(fd,buffer,(size_t)MIN((off_t)sizeof(buffer),expectedSize-total));
                if(count<0 && errno==EINTR && ++interruptions<=4)continue;
                if(count<=0)break;
                CC_SHA256_Update(&context,buffer,(CC_LONG)count);total+=count;
            }
            CC_SHA256_Final(digest,&context);
            char hex[65];for(unsigned i=0;i<sizeof(digest);i++)snprintf(hex+i*2,3,"%02x",digest[i]);
            // Check both the open vnode and the current name. A replacement,
            // permission change or mutation during hashing must revoke it.
            valid=total==expectedSize && [expectedSHA256 isEqual:@(hex)] &&
                !fstat(fd,&after) && LBXCallerUnchanged(before,after) &&
                !lstat(path.fileSystemRepresentation,&named) && LBXCallerUnchanged(after,named);
        }
    } @catch(__unused NSException *exception) { valid=NO; }
    close(fd);return valid;
}
