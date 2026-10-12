#pragma once
#import <Foundation/Foundation.h>
#import "RBXStorageGate.h"
#include <fcntl.h>
#include <unistd.h>

// SGATE-002: restore executable modes only in a root-private transaction copy.
// The installed source and data snapshots never pass through this function.
static inline BOOL RBXPrepareStagedExecutable(NSString *bundle,NSString *transactions,uid_t owner,gid_t group,NSError **error) {
    int fd=-1,main=-1;BOOL ok=NO;
    NSString *canonical=transactions.stringByResolvingSymlinksInPath;
    NSString *prefix=[transactions stringByAppendingString:@"/"];
    NSString *target=nil;
    NSArray *parts=nil;NSDictionary *info=nil;NSString *name=nil;
    if(![bundle hasPrefix:prefix]||![bundle isEqual:bundle.stringByStandardizingPath]||![bundle.pathExtension isEqual:@"app"])goto done;
    target=[canonical stringByAppendingPathComponent:[bundle substringFromIndex:prefix.length]];
    fd=open(canonical.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    struct stat st;
    if(fd<0||fstat(fd,&st)||st.st_uid!=owner||(st.st_mode&0077)||!RBXStorageGateNoACL(fd))goto done;
    parts=[[bundle substringFromIndex:prefix.length] pathComponents];
    if(parts.count<3)goto done; // transaction / Payload / App.app
    for(NSUInteger index=0;index<parts.count;index++){
        NSString *part=parts[index];
        if([@[@".",@"..",@"/"] containsObject:part])goto done;
        int next=openat(fd,part.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        close(fd);fd=next;
        if(fd<0||fstat(fd,&st)||!RBXStorageGateNoACL(fd))goto done;
        // Every parent must retain root authority; the copied bundle may have
        // installer ownership inherited by copyfile and is normalized below.
        if(index+1<parts.count&&(st.st_uid!=owner||(st.st_mode&0022)))goto done;
    }
    info=[NSDictionary dictionaryWithContentsOfFile:[target stringByAppendingPathComponent:@"Info.plist"]];
    name=info[@"CFBundleExecutable"];
    if(![name isKindOfClass:NSString.class]||!name.length||![name isEqual:name.lastPathComponent]||[@[@".",@".."] containsObject:name])goto done;
    main=openat(fd,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(main<0||fstat(main,&st)||!S_ISREG(st.st_mode)||st.st_nlink!=1||!RBXStorageGateNoACL(main))goto done;
    ok=RBXStorageGateSet(fd,owner,group,0755)&&RBXStorageGateSet(main,owner,group,0755);
    if(ok){struct stat current;ok=lstat(target.fileSystemRepresentation,&current)==0;struct stat pinned;ok=ok&&fstat(fd,&pinned)==0&&current.st_dev==pinned.st_dev&&current.st_ino==pinned.st_ino;}
 done:
    if(main>=0)close(main);if(fd>=0)close(fd);
    if(!ok&&error)*error=[NSError errorWithDomain:@"com.redditbox.storage-access" code:errno?:EPERM userInfo:@{NSLocalizedDescriptionKey:@"Only a verified private staged app may regain executable permissions"}];
    return ok;
}
