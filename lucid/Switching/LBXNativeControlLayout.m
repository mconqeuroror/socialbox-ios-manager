#import "LBXNativeControlLayout.h"
#import "LBXSocialBoxProduct.h"
#import "../../shared/RBXStorageGate.h"
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#ifndef LBX_NATIVE_CONTROL_LAYOUT_TESTING
#define LBX_NATIVE_CONTROL_LAYOUT_TESTING 0
#endif

static NSString *const Instagram=@"com.burbn.instagram";
static NSString *const Facebook=@"com.facebook.Facebook";
static NSString *const ContainersPath=@LBX_SOCIALBOX_CONTROL_CONTAINERS;
static NSString *const RuntimePath=@LBX_SOCIALBOX_CONTROL_RUNTIME;

@interface LBXNativeControlLayout ()
@property(nonatomic,copy)NSDictionary *status;
- (instancetype)initPrivate;
@end

static BOOL Fail(NSError **error,NSInteger code){
    if(error)*error=[NSError errorWithDomain:@"com.socialbox.native-control-layout" code:code userInfo:@{NSLocalizedDescriptionKey:
        code==2?@"Root context is required to observe native control files":@"Native family control layout refused"}];
    return NO;
}
static NSDictionary *Immutable(id value){
    if(![NSJSONSerialization isValidJSONObject:value])return nil;
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    return bytes.length&&bytes.length<=8*1024*1024?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;
}
static NSDictionary *Identity(int fd,NSString *name,NSString *path,NSString *type){
    struct stat s;if(fd<0||fstat(fd,&s)||!RBXStorageGateNoACL(fd)||(s.st_mode&0022))return nil;
    if([type isEqual:@"directory"]&&(!S_ISDIR(s.st_mode)||s.st_nlink<2))return nil;
    if([type isEqual:@"file"]&&(!S_ISREG(s.st_mode)||s.st_nlink!=1))return nil;
    return Immutable(@{@"name":name,@"path":path,@"type":type,@"device":@(s.st_dev),@"inode":@(s.st_ino),@"uid":@(s.st_uid),@"gid":@(s.st_gid),@"mode":@(s.st_mode&07777),@"flags":@(s.st_flags),@"linkCount":@(s.st_nlink),@"size":@(s.st_size)});
}
static int OpenChild(int parent,NSString *name,BOOL directory){
    if(!name.length||[name isEqual:@"."]||[name isEqual:@".."]||[name containsString:@"/"]||[name containsString:@"\\"])return -1;
    return openat(parent,name.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|(directory?O_DIRECTORY:O_NONBLOCK));
}
static NSDictionary *File(int parent,NSString *name,NSString *parentPath){
    int fd=OpenChild(parent,name,NO);NSDictionary *node=Identity(fd,name,[parentPath stringByAppendingPathComponent:name],@"file");if(fd>=0)close(fd);return node;
}
static NSArray *Names(int fd){
    int duped=dup(fd);if(duped<0)return nil;DIR *dir=fdopendir(duped);if(!dir){close(duped);return nil;}
    NSMutableArray *names=[NSMutableArray array];
    for(;;){errno=0;struct dirent *entry=readdir(dir);if(!entry){if(errno){closedir(dir);return nil;}break;}
        if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
        NSString *name=@(entry->d_name);if(!name.length||name.length>255){closedir(dir);return nil;}[names addObject:name];}
    closedir(dir);[names sortUsingSelector:@selector(compare:)];return names;
}
static int OpenAbsolute(NSString *path){
    if(![path isKindOfClass:NSString.class]||!path.isAbsolutePath||path.length>=4096||[path containsString:@"\\"])return -1;
    char resolved[PATH_MAX];if(!realpath(path.fileSystemRepresentation,resolved))return -1;
    NSString *physical=@(resolved);NSArray *parts=[physical componentsSeparatedByString:@"/"];int fd=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    for(NSUInteger i=1;i<parts.count;i++){int child=fd>=0?OpenChild(fd,parts[i],YES):-1;if(fd>=0)close(fd);fd=child;if(fd<0)return -1;}
    return fd;
}
static NSDictionary *Application(int containers,NSString *bundle,NSString *containersPath){
    int fd=OpenChild(containers,bundle,YES);if(fd<0)return nil;
    NSDictionary *root=Identity(fd,bundle,[containersPath stringByAppendingPathComponent:bundle],@"directory");
    NSArray *names=Names(fd);NSDictionary *metadata=File(fd,@"metadata.plist",[containersPath stringByAppendingPathComponent:bundle]);
    close(fd);
    if(!root||!metadata||![names containsObject:@"metadata.plist"])return nil;
    return Immutable(@{@"bundleIdentifier":bundle,@"root":root,@"metadata":metadata,@"contentsRead":@NO});
}
static LBXNativeControlLayout *Layout(int containers,NSString *containersPath,int runtime,NSString *runtimePath,NSError **error){
    if(error)*error=nil;
    NSArray *containerNames=Names(containers),*runtimeNames=Names(runtime);
    NSDictionary *global=File(containers,@"global_metadata.plist",containersPath);
    NSDictionary *instagram=Application(containers,Instagram,containersPath);
    NSDictionary *facebook=Application(containers,Facebook,containersPath);
    NSDictionary *instagramRuntime=File(runtime,[Instagram stringByAppendingString:@".plist"],runtimePath);
    NSDictionary *facebookRuntime=File(runtime,[Facebook stringByAppendingString:@".plist"],runtimePath);
    BOOL familyRoots=[containerNames containsObject:Instagram]&&[containerNames containsObject:Facebook]&&[containerNames containsObject:@"global_metadata.plist"];
    BOOL familyRuntime=[runtimeNames containsObject:[Instagram stringByAppendingString:@".plist"]]&&[runtimeNames containsObject:[Facebook stringByAppendingString:@".plist"]];
    if(!global||!instagram||!facebook||!instagramRuntime||!facebookRuntime||!familyRoots||!familyRuntime){Fail(error,1);return nil;}
    NSDictionary *status=Immutable(@{@"kind":@"native-family-control-layout",@"formatVersion":@1,@"layoutStatus":@"OBSERVED",
        @"applications":@[Instagram,Facebook],@"globalMetadata":global,@"instagram":instagram,@"facebook":facebook,
        @"instagramRuntimePlist":instagramRuntime,@"facebookRuntimePlist":facebookRuntime,
        @"accountFileContentsRead":@NO,@"selectionChanged":@NO,@"hookInstalled":@NO,@"installedSwitchConnected":@NO,
        @"runtimeAccepted":@NO,@"isolationVerified":@NO});
    if(!status){Fail(error,1);return nil;}
    LBXNativeControlLayout *layout=[[LBXNativeControlLayout alloc] initPrivate];
    layout.status=status;return layout;
}
@implementation LBXNativeControlLayout
- (instancetype)initPrivate{return [super init];}
- (NSDictionary *)safeStatus{return _status?:Immutable(@{@"kind":@"native-family-control-layout",@"layoutStatus":@"REFUSED",@"isolationVerified":@NO,@"runtimeAccepted":@NO,@"accountFileContentsRead":@NO})?:@{};}
- (NSString *)description{return @"<LBXNativeControlLayout>";}
+ (instancetype)observeOfficialFamily:(NSError **)error {
    if(getuid()!=0||geteuid()!=0){Fail(error,2);return nil;}
    NSString *containersPath=[ContainersPath stringByResolvingSymlinksInPath],*runtimePath=[RuntimePath stringByResolvingSymlinksInPath];
    int containers=OpenAbsolute(containersPath),runtime=OpenAbsolute(runtimePath);
    LBXNativeControlLayout *layout=(containers>=0&&runtime>=0)?Layout(containers,containersPath,runtime,runtimePath,error):nil;
    if(containers>=0)close(containers);if(runtime>=0)close(runtime);
    if(!layout){Fail(error,1);return nil;}
    return layout;
}
#if LBX_NATIVE_CONTROL_LAYOUT_TESTING
+ (instancetype)testObserveContainers:(NSString *)containersPath runtimePlists:(NSString *)runtimePath error:(NSError **)error {
    int containers=OpenAbsolute(containersPath),runtime=OpenAbsolute(runtimePath);
    LBXNativeControlLayout *layout=(containers>=0&&runtime>=0)?Layout(containers,containersPath,runtime,runtimePath,error):nil;
    if(containers>=0)close(containers);if(runtime>=0)close(runtime);
    if(!layout){Fail(error,1);return nil;}
    return layout;
}
#endif
@end
