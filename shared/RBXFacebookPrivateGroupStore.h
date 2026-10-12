#pragma once
#import "RBXFacebookStoragePolicy.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

// FBSTORE-002. Private replacement inside the OS-issued clone home, not an
// entitlement to an original App Group. No foreign path or identifier fallback.
static inline NSURL *RBXFacebookPrivateGroupURL(NSString *bundle, id identifier, NSString *home) {
    NSString *role=RBXFacebookStorageRole(identifier);
    if (!RBXFacebookOwnStorageBundle(bundle) || !role || !home.isAbsolutePath) return nil;
    int fd=open(home.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (fd<0) return nil;
    NSArray *parts=@[@"Library",@"Application Support",@"SocialBox",@"PrivateGroups-v1",role];
    NSString *path=home;
    for (NSString *part in parts) {
        struct stat st;
        // Existing parents are never chmod'ed. Final private components must
        // remain owned by this app's uid and cannot be symbolic links.
        if (mkdirat(fd,part.fileSystemRepresentation,0700)<0 && errno!=EEXIST) {close(fd);return nil;}
        int child=openat(fd,part.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if (child<0 || fstat(child,&st)<0 || st.st_uid!=geteuid()) {
            if(child>=0)close(child);close(fd);return nil;
        }
        close(fd);fd=child;path=[path stringByAppendingPathComponent:part];
    }
    close(fd);
    return [NSURL fileURLWithPath:path isDirectory:YES];
}
