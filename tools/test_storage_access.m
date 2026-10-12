#import <Foundation/Foundation.h>
#import "RBXStorageAccess.h"
#import "RBXAppRegistry.h"
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
static NSString *FixtureRoot;
static NSArray *Targets;
static BOOL ProviderFails;
static NSUInteger Checks;
static uid_t RBXStorageRootOwner(void) { return getuid(); }
static gid_t RBXStorageRootGroup(void) { return getgid(); }
static uid_t RBXStorageAppOwner(void) { return getuid(); }
static gid_t RBXStorageAppGroup(void) { return getgid(); }
static uid_t RBXStorageInstallerOwner(void) { return getuid(); }
static gid_t RBXStorageInstallerGroup(void) { return getgid(); }
static NSString *RBXStorageLedgerPath(void) { return [FixtureRoot stringByAppendingPathComponent:@"ledger"]; }
static NSArray *RBXStorageRegisteredTargets(NSError **error) {
    if (ProviderFails) { if(error)*error=[NSError errorWithDomain:@"fixture" code:1 userInfo:nil]; return nil; }
    return Targets;
}
#define RBX_STORAGE_ACCESS_TESTING 1
#import "../daemon/RBXStorageAccess.m"
static void Check(BOOL ok,NSString *message) { Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);} }
static void Mode(NSString *path,mode_t mode) { struct stat s;Check(lstat(path.fileSystemRepresentation,&s)==0&&(s.st_mode&07777)==mode,@"actual file mode"); }
static NSDictionary *Target(unsigned i) {
    NSString *cid=[NSString stringWithFormat:@"storage-%u",i];
    NSString *bundle=RBXAppBundleIdentifier(RBXAppDescriptorForType(i%2?@"facebook":@"reddit"),cid);
    NSString *base=[FixtureRoot stringByAppendingPathComponent:cid];
    NSString *app=[base stringByAppendingPathComponent:@"App.app"],*home=[base stringByAppendingPathComponent:@"Home"];
    NSFileManager *fm=NSFileManager.defaultManager;
    Check([fm createDirectoryAtPath:app withIntermediateDirectories:YES attributes:nil error:nil],@"create app");
    Check([fm createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:nil],@"create home");
    NSString *binary=[app stringByAppendingPathComponent:@"Main"];
    Check([@"synthetic executable bytes" writeToFile:binary atomically:YES encoding:NSUTF8StringEncoding error:nil],@"create executable");
    chmod(binary.fileSystemRepresentation,0755);
    Check([cid writeToFile:[home stringByAppendingPathComponent:@"canary"] atomically:YES encoding:NSUTF8StringEncoding error:nil],@"seed own data");
    return @{@"bundleIdentifier":bundle,@"containerId":cid,@"appType":i%2?@"facebook":@"reddit",@"bundlePath":app,@"home":home,@"executable":binary};
}
int main(int argc,char **argv) {@autoreleasepool {
    Check(argc==2,@"fixture root required"); FixtureRoot=[@(argv[1]) stringByResolvingSymlinksInPath];
    NSMutableArray *all=[NSMutableArray array];for(unsigned i=0;i<40;i++)[all addObject:Target(i)];Targets=all;
    Check([RBXStorageAccess closeAll:nil],@"adopt and close 40 real entries");
    for(NSDictionary *t in Targets){Mode(t[@"executable"],0600);Mode(t[@"bundlePath"],0700);Mode(t[@"home"],0700);Check([RBXStorageAccess ownsClosedHome:t[@"home"] bundleIdentifier:t[@"bundleIdentifier"] error:nil],@"exact closed home authority");}
    for(unsigned round=0;round<3;round++)for(NSDictionary *t in Targets){
        NSDictionary *p=@{@"containerId":t[@"containerId"],@"appType":t[@"appType"],@"app":@{@"bundleIdentifier":t[@"bundleIdentifier"],@"bundlePath":t[@"bundlePath"]}};
        Check([RBXStorageAccess openProfile:p authorized:^BOOL{return YES;} error:nil],@"select exact clone");
        for(NSDictionary *other in Targets){BOOL chosen=other==t;Mode(other[@"executable"],chosen?0755:0600);Mode(other[@"bundlePath"],chosen?0755:0700);}
        Check([[NSString stringWithContentsOfFile:[t[@"home"] stringByAppendingPathComponent:@"canary"] encoding:NSUTF8StringEncoding error:nil] isEqual:t[@"containerId"]],@"identity survives every selection");
    }
    NSDictionary *t=Targets[0];NSDictionary *p=@{@"containerId":t[@"containerId"],@"appType":t[@"appType"],@"app":@{@"bundleIdentifier":t[@"bundleIdentifier"],@"bundlePath":t[@"bundlePath"]}};
    for(unsigned revoke=1;revoke<=4;revoke++) { __block unsigned calls=0;Check(![RBXStorageAccess openProfile:p authorized:^BOOL{return ++calls<revoke;} error:nil],@"revocation rejects admission");for(NSDictionary *q in Targets)Mode(q[@"executable"],0600); }
    Check(![RBXStorageAccess openProfile:p authorized:nil error:nil],@"no authority means no admission");
    Check(![RBXStorageAccess ownsClosedHome:Targets[1][@"home"] bundleIdentifier:t[@"bundleIdentifier"] error:nil],@"foreign home denied");
    Check([RBXStorageAccess openProfile:p authorized:^BOOL{return YES;} error:nil],@"open before provider loss");ProviderFails=YES;
    Check(![RBXStorageAccess closeAll:nil],@"provider loss cannot prove complete closure");Mode(t[@"executable"],0600);Mode(t[@"home"],0700);ProviderFails=NO;
    __block BOOL maintained=NO;
    Check([RBXStorageAccess performInstallerMaintenanceForBundle:t[@"bundleIdentifier"] expectedBundlePath:t[@"bundlePath"] operation:^BOOL(NSError **e){
        maintained=YES;Mode(t[@"executable"],0640);Mode(t[@"bundlePath"],0750);Mode(t[@"home"],0700);
        Mode(Targets[1][@"executable"],0600);return YES;
    } error:nil]&&maintained,@"installer inspects exact code without opening home or execution");
    Mode(t[@"executable"],0600);Mode(t[@"bundlePath"],0700);
    Check(![RBXStorageAccess performInstallerMaintenanceForBundle:t[@"bundleIdentifier"] expectedBundlePath:Targets[1][@"bundlePath"] operation:^BOOL(NSError **e){Check(NO,@"foreign target never calls operation");return YES;} error:nil],@"foreign maintenance path denied");
    Check(![RBXStorageAccess performInstallerMaintenanceForBundle:t[@"bundleIdentifier"] expectedBundlePath:t[@"bundlePath"] operation:^BOOL(NSError **e){return NO;} error:nil],@"installer failure propagates");
    Mode(t[@"executable"],0600);Mode(t[@"bundlePath"],0700);
    @try {[RBXStorageAccess performInstallerMaintenanceForBundle:t[@"bundleIdentifier"] expectedBundlePath:t[@"bundlePath"] operation:^BOOL(NSError **e){@throw [NSException exceptionWithName:@"test" reason:nil userInfo:nil];} error:nil];} @catch(NSException *e) {}
    Mode(t[@"executable"],0600);Mode(t[@"bundlePath"],0700);
    // A moved/replaced home must not inherit root receipt authority.
    NSString *moved=[t[@"home"] stringByAppendingString:@"-moved"];
    Check([NSFileManager.defaultManager moveItemAtPath:t[@"home"] toPath:moved error:nil],@"move home");
    Check([NSFileManager.defaultManager createDirectoryAtPath:t[@"home"] withIntermediateDirectories:NO attributes:nil error:nil],@"substitute home");
    Check(![RBXStorageAccess closeAll:nil],@"stale inode prevents adoption");Check(![RBXStorageAccess ownsClosedHome:t[@"home"] bundleIdentifier:t[@"bundleIdentifier"] error:nil],@"substituted home never authorized");
    Check([NSFileManager.defaultManager removeItemAtPath:t[@"home"] error:nil]&&[NSFileManager.defaultManager moveItemAtPath:moved toPath:t[@"home"] error:nil],@"restore exact fixture inode");
    Check([RBXStorageAccess closeAll:nil],@"recovery seals same owned objects");
    // Removed registrations may not leave a still-present recorded home open.
    Targets=[all subarrayWithRange:NSMakeRange(1,39)];Check(![RBXStorageAccess closeAll:nil],@"orphan receipt blocks new admission");
    Check([NSFileManager.defaultManager removeItemAtPath:t[@"bundlePath"] error:nil]&&[NSFileManager.defaultManager removeItemAtPath:t[@"home"] error:nil],@"actual deletion");
    Check([RBXStorageAccess closeAll:nil],@"fully deleted receipt is safe history");
    printf("PASS %lu durable storage assertions; 40 targets, 120 switches, revoked authority, provider loss, substituted inode and deletion\n",(unsigned long)Checks);
}return 0;}
