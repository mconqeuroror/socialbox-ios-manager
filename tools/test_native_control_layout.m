#import <Foundation/Foundation.h>
#import "../lucid/Switching/LBXNativeControlLayout.h"
static NSUInteger Checks;
static void Check(BOOL ok,NSString *label){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",label.UTF8String);exit(1);}}
static void Dir(NSString *p){Check([[NSFileManager defaultManager] createDirectoryAtPath:p withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil],@"dir");}
static void Touch(NSString *p){Check([@"\n" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil],@"file");Check([[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0644} ofItemAtPath:p error:nil],@"mode");}
int main(void){@autoreleasepool{
    NSError *error=nil;
    if(getuid()!=0||geteuid()!=0)Check([LBXNativeControlLayout observeOfficialFamily:&error]==nil&&error.code==2,@"production control layout requires root");
    NSString *base=[[NSTemporaryDirectory() stringByAppendingPathComponent:[@"socialbox-control-layout-" stringByAppendingString:NSUUID.UUID.UUIDString]] copy];
    NSString *containers=[base stringByAppendingPathComponent:@"Containers"],*runtime=[base stringByAppendingPathComponent:@"runtime"];
    Dir(containers);Dir(runtime);
    Touch([containers stringByAppendingPathComponent:@"global_metadata.plist"]);
    Dir([containers stringByAppendingPathComponent:@"com.burbn.instagram"]);
    Dir([containers stringByAppendingPathComponent:@"com.facebook.Facebook"]);
    Touch([containers stringByAppendingPathComponent:@"com.burbn.instagram/metadata.plist"]);
    Touch([containers stringByAppendingPathComponent:@"com.facebook.Facebook/metadata.plist"]);
    Touch([runtime stringByAppendingPathComponent:@"com.burbn.instagram.plist"]);
    Touch([runtime stringByAppendingPathComponent:@"com.facebook.Facebook.plist"]);
    LBXNativeControlLayout *layout=[LBXNativeControlLayout testObserveContainers:containers runtimePlists:runtime error:&error];
    Check(layout&&!error,@"family control trees observe");
    Check([layout.safeStatus[@"layoutStatus"] isEqual:@"OBSERVED"],@"observed");
    Check([layout.safeStatus[@"accountFileContentsRead"] isEqual:@NO],@"plist bytes never read");
    Check([layout.safeStatus[@"isolationVerified"] isEqual:@NO]&&[layout.safeStatus[@"runtimeAccepted"] isEqual:@NO],@"layout is not isolation");
    Check([layout.safeStatus[@"installedSwitchConnected"] isEqual:@NO],@"control layout is not installed switch");
    Check([layout.safeStatus[@"instagram"][@"bundleIdentifier"] isEqual:@"com.burbn.instagram"],@"instagram tree pinned");
    Check([layout.safeStatus[@"facebook"][@"bundleIdentifier"] isEqual:@"com.facebook.Facebook"],@"facebook tree pinned");
    Check(layout.safeStatus[@"instagram"][@"metadata"][@"inode"]!=nil&&layout.safeStatus[@"facebook"][@"metadata"][@"inode"]!=nil,@"metadata inodes recorded");
    Check(![layout.safeStatus[@"instagram"][@"metadata"][@"path"] containsString:@"account"],@"no account path invented");
    NSString *missingFB=[containers stringByAppendingPathComponent:@"com.facebook.Facebook/metadata.plist"];
    Check([[NSFileManager defaultManager] removeItemAtPath:missingFB error:nil],@"remove facebook metadata");
    error=nil;Check([LBXNativeControlLayout testObserveContainers:containers runtimePlists:runtime error:&error]==nil,@"Facebook metadata absence refuses family layout");
    Touch(missingFB);
    Dir([containers stringByAppendingPathComponent:@"com.facebook.Messenger"]);
    Touch([containers stringByAppendingPathComponent:@"com.facebook.Messenger/metadata.plist"]);
    Dir([containers stringByAppendingPathComponent:@"com.burbn.instagram/containers"]);
    error=nil;Check([LBXNativeControlLayout testObserveContainers:containers runtimePlists:runtime error:&error]!=nil&&!error,@"unrelated extra trees do not refuse Instagram+Facebook observe");
    [[NSFileManager defaultManager] removeItemAtPath:[containers stringByAppendingPathComponent:@"com.facebook.Messenger"] error:nil];
    Dir([containers stringByAppendingPathComponent:@"com.twitter.twitter"]);
    Touch([containers stringByAppendingPathComponent:@"com.twitter.twitter/metadata.plist"]);
    error=nil;LBXNativeControlLayout *withTwitter=[LBXNativeControlLayout testObserveContainers:containers runtimePlists:runtime error:&error];
    Check(withTwitter&&!error&&[withTwitter.safeStatus[@"applications"] isEqual:@[@"com.burbn.instagram",@"com.facebook.Facebook"]],@"Twitter control tree is ignored and cannot join the family application list");
    [[NSFileManager defaultManager] removeItemAtPath:[containers stringByAppendingPathComponent:@"com.twitter.twitter"] error:nil];
    Check([[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0666} ofItemAtPath:[containers stringByAppendingPathComponent:@"global_metadata.plist"] error:nil],@"world write");
    error=nil;Check([LBXNativeControlLayout testObserveContainers:containers runtimePlists:runtime error:&error]==nil,@"world-writable global metadata refused");
    [[NSFileManager defaultManager] removeItemAtPath:base error:nil];
    printf("PASS: %lu native family control-layout assertions\n",(unsigned long)Checks);return 0;
}}
