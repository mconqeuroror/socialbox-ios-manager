#import "RBXFacebookPrivateGroupStore.h"
static unsigned checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL line %d\n",__LINE__); exit(1); } } while(0)
int main(void) { @autoreleasepool {
 NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 NSFileManager *fm=NSFileManager.defaultManager;
 CHECK([fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
 NSString *aHome=[root stringByAppendingPathComponent:@"A"],*bHome=[root stringByAppendingPathComponent:@"B"];
 CHECK([fm createDirectoryAtPath:aHome withIntermediateDirectories:NO attributes:nil error:nil]);
 CHECK([fm createDirectoryAtPath:bHome withIntermediateDirectories:NO attributes:nil error:nil]);
 NSString *a=RBXAppBundleIdentifier(RBXAppDescriptorForType(@"facebook"),@"group-test-A");
 NSString *b=RBXAppBundleIdentifier(RBXAppDescriptorForType(@"facebook"),@"group-test-B");
 NSMutableSet *urls=[NSMutableSet set];
 for(NSString *source in RBXFacebookSharedStorageDomains()) {
  NSURL *au=RBXFacebookPrivateGroupURL(a,source,aHome),*bu=RBXFacebookPrivateGroupURL(b,source,bHome);
  CHECK(au && bu && ![au isEqual:bu]);[urls addObject:au];
  CHECK([au.path hasPrefix:[aHome stringByAppendingString:@"/"]]);
  CHECK([RBXFacebookPrivateGroupURL(a,source,aHome) isEqual:au]);
  NSURL *marker=[au URLByAppendingPathComponent:@"synthetic-canary"];
  CHECK([@"own-state" writeToURL:marker atomically:YES encoding:NSUTF8StringEncoding error:nil]);
  CHECK(![fm fileExistsAtPath:[[bu URLByAppendingPathComponent:@"synthetic-canary"] path]]);
  struct stat st;CHECK(!stat(au.fileSystemRepresentation,&st) && (st.st_mode&0777)==0700);
 }
 CHECK(urls.count==4);
 for(id invalid in @[@"group.com.facebook.Facebook/../family",@"group.com.facebook.unknown",@4,NSNull.null])CHECK(!RBXFacebookPrivateGroupURL(a,invalid,aHome));
 CHECK(!RBXFacebookPrivateGroupURL(@"com.facebook.Facebook",@"group.com.facebook.family",aHome));
 CHECK(!RBXFacebookPrivateGroupURL(a,@"group.com.facebook.family",@"relative"));
 NSString *role=[aHome stringByAppendingPathComponent:@"Library/Application Support/SocialBox/PrivateGroups-v1/msys"];
 CHECK([fm removeItemAtPath:role error:nil]);
 CHECK([fm createSymbolicLinkAtPath:role withDestinationPath:bHome error:nil]);
 CHECK(!RBXFacebookPrivateGroupURL(a,@"group.com.facebook.msysstorage",aHome));
 CHECK(![fm fileExistsAtPath:[bHome stringByAppendingPathComponent:@"synthetic-canary"]]);
 CHECK([fm removeItemAtPath:role error:nil]);
 CHECK([@"not-directory" writeToFile:role atomically:YES encoding:NSUTF8StringEncoding error:nil]);
 CHECK(!RBXFacebookPrivateGroupURL(a,@"group.com.facebook.msysstorage",aHome));
 CHECK([fm removeItemAtPath:root error:nil]);
 printf("PASS Facebook private group filesystem: %u assertions\n",checks);
} return 0; }
