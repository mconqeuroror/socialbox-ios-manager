#import "RBXContainerRegistry.h"
#import "RBXProfileIO.h"
#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import "RBXCloneManager.h"
#import "RBXStorageAccess.h"
#import "RBXAppProcessCoordinator.h"
#import "RBXProfileGenerator.h"
#import "RBXOperationContext.h"
#import "RBXAppRuntime.h"
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
static BOOL Offline(void){for(NSNumber *family in @[@(AF_INET),@(AF_INET6)]){struct sockaddr_storage sa={0};
 if(family.intValue==AF_INET){struct sockaddr_in *a=(void *)&sa;a->sin_len=sizeof(*a);a->sin_family=AF_INET;inet_pton(AF_INET,"1.1.1.1",&a->sin_addr);}else{struct sockaddr_in6 *a=(void *)&sa;a->sin6_len=sizeof(*a);a->sin6_family=AF_INET6;inet_pton(AF_INET6,"2606:4700:4700::1111",&a->sin6_addr);}
 SCNetworkReachabilityFlags flags=0;SCNetworkReachabilityRef r=SCNetworkReachabilityCreateWithAddress(NULL,(struct sockaddr *)&sa);BOOL ok=r&&SCNetworkReachabilityGetFlags(r,&flags);if(r)CFRelease(r);if(!ok||(flags&kSCNetworkReachabilityFlagsReachable))return NO;}return YES;}
int RBXOfflineAcceptanceCommand(int argc,char **argv){
 if(argc!=5||geteuid()!=0||!Offline())return 65;
 NSString *phase=@(argv[2]),*nonce=@(argv[3]),*role=@(argv[4]);
 if(nonce.length!=32||[nonce rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location!=NSNotFound||![@[@"A",@"B"] containsObject:role])return 65;
 NSString *cid=[NSString stringWithFormat:@"accept-fb-%@-%@",nonce,role];NSString *root=[@"/var/jb/tmp/socialbox-fb-acceptance-" stringByAppendingString:nonce];
 NSFileManager *fm=NSFileManager.defaultManager;NSError *error=nil;
 if(![fm createDirectoryAtPath:root withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:&error]&&error.code!=NSFileWriteFileExistsError)return 1;
 NSString *saved=[root stringByAppendingPathComponent:[role stringByAppendingString:@".plist"]];
 RBXCloneManager *clones=[[RBXCloneManager alloc] initWithAppType:@"facebook" operationContext:RBXOperationContext.currentContext];
 NSMutableDictionary *profile=[[NSDictionary dictionaryWithContentsOfFile:saved] mutableCopy];
 if([phase isEqual:@"create"]){
  if(!profile){profile=[[RBXProfileGenerator generateProfileForContainerId:cid appType:@"facebook" proxyCountry:@"US" existingProfiles:@[] error:&error] mutableCopy];if(!profile){fprintf(stderr,"profile: %s\n",error.localizedDescription.UTF8String);return 1;}if(![profile writeToFile:saved atomically:YES])return 1;}
  if(![profile[@"containerId"] isEqual:cid]||![profile[@"appType"] isEqual:@"facebook"])return 65;
  NSDictionary *app=[clones ensureCloneForContainer:cid profile:profile nickname:[@"Offline FB " stringByAppendingString:role] error:&error];
  if(!app){fprintf(stderr,"clone: %s\n",error.localizedDescription.UTF8String);return 1;}
  profile[@"app"]=app;if(![profile writeToFile:saved atomically:YES])return 1;
  if(![clones syncProfile:profile error:&error]){fprintf(stderr,"sync: %s\n",error.localizedDescription.UTF8String);return 1;}
 }else if([phase isEqual:@"sync"]){
  if(![profile[@"containerId"] isEqual:cid]||!RBXAppRuntimeProfileMatchesBundle(profile,profile[@"app"][@"bundleIdentifier"]))return 65;
  if(![clones syncProfile:profile error:&error]){fprintf(stderr,"sync: %s\n",error.localizedDescription.UTF8String);return 1;}
 }else if([@[@"open",@"close",@"export"] containsObject:phase]){
  if(![profile[@"containerId"] isEqual:cid]||!RBXAppRuntimeProfileMatchesBundle(profile,profile[@"app"][@"bundleIdentifier"]))return 65;
  RBXAppProcessCoordinator *processes=[RBXAppProcessCoordinator new];
  if(![processes killAllAndWait:8]){fprintf(stderr,"stop/storage close failed\n");return 1;}
  if([phase isEqual:@"open"] && ![RBXStorageAccess openProfile:profile authorized:^BOOL{return Offline() && [RBXOperationContext.currentContext check:nil] && [processes verifyNoAppSocketsForInterval:0 timeout:3 error:nil];} error:&error]){fprintf(stderr,"storage open: %s\n",error.localizedDescription.UTF8String);return 1;}
  if([phase isEqual:@"export"]){NSString *path=[clones exportIPAForProfile:profile error:&error];if(!path){fprintf(stderr,"export: %s\n",error.localizedDescription.UTF8String);return 1;}printf("exported private clone IPA\n");}
 }else if([phase isEqual:@"delete"]){
  if(![profile[@"containerId"] isEqual:cid]||!RBXAppRuntimeProfileMatchesBundle(profile,profile[@"app"][@"bundleIdentifier"]))return 65;
  NSString *published=[@"/var/mobile/Library/Preferences/com.redditbox.profiles" stringByAppendingPathComponent:[cid stringByAppendingString:@".json"]];
  NSDictionary *old=[RBXProfileIO loadProfileForContainer:cid error:nil];
  if(old && ![old isEqual:profile])return 65;
  if(!old && ![RBXProfileIO writeProfile:profile containerId:cid toPath:published error:&error])return 1;
  if(![[RBXContainerRegistry new] deleteContainer:cid error:&error]){fprintf(stderr,"delete: %s\n",error.localizedDescription.UTF8String);return 1;}
  printf("deleted own test clone %s\n",role.UTF8String);return 0;
 }else if(![phase isEqual:@"inspect"])return 65;
 NSString *bundle=profile[@"app"][@"bundleIdentifier"],*home=[clones dataContainerForBundleIdentifier:bundle];
 if(!home.length)return 1;
 NSDictionary *report=@{@"role":role,@"containerId":cid,@"bundle":bundle,@"home":home,@"app":profile[@"app"],@"offline":@(Offline())};
 NSString *path=[root stringByAppendingPathComponent:[role stringByAppendingString:@"-info.plist"]];if(![report writeToFile:path atomically:YES])return 1;
 chmod(path.fileSystemRepresentation,0600);chown(path.fileSystemRepresentation,501,501);
 printf("PASS offline clone %s provisioned and profile synchronized\n",role.UTF8String);return 0;
}
