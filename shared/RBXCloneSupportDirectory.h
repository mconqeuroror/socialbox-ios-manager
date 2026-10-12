#pragma once
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

// The daemon must provision every parent for the sandbox owner. Opening each
// component without following links also prevents repairing a foreign target.
static inline NSString *RBXCloneSupportDirectoryWithRootOwner(NSString *home, uid_t owner, gid_t group, uid_t rootOwner, NSError **error) {
    int fd=-1;
    if (!home.isAbsolutePath) { errno=EINVAL; goto failed; }
    fd=open(home.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0)goto failed;
    struct stat root;
    if(fstat(fd,&root)<0)goto failed;
    if(root.st_uid!=rootOwner){errno=EPERM;goto failed;}
    for(NSString *part in @[@"Library",@"Application Support",@"RedditBox"]) {
        BOOL created=mkdirat(fd,part.fileSystemRepresentation,0700)==0;
        if(!created && errno!=EEXIST)goto failed;
        int next=openat(fd,part.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(next<0)goto failed;
        struct stat st;
        BOOL ok=fstat(next,&st)==0;
        if(ok && st.st_uid!=owner && st.st_uid!=0){errno=EPERM;ok=NO;}
        if(ok && (st.st_uid!=owner || st.st_gid!=group))ok=fchown(next,owner,group)==0;
        if(ok && (created || st.st_uid!=owner || [part isEqual:@"RedditBox"]))ok=fchmod(next,0700)==0;
        int saved=errno;close(fd);fd=next;errno=saved;
        if(!ok)goto failed;
    }
    close(fd);
    return [home stringByAppendingPathComponent:@"Library/Application Support/RedditBox"];
failed:;
    int saved=errno;if(fd>=0)close(fd);
    if(error)*error=[NSError errorWithDomain:NSPOSIXErrorDomain code:saved?:EIO userInfo:@{NSLocalizedDescriptionKey:@"Clone support directory ownership or no-follow traversal failed"}];
    return nil;
}

// Ordinary mobile homes retain the original strict ownership contract.
static inline NSString *RBXCloneSupportDirectory(NSString *home, uid_t owner, gid_t group, NSError **error) {
    return RBXCloneSupportDirectoryWithRootOwner(home,owner,group,owner,error);
}
