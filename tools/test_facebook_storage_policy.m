#import <Foundation/Foundation.h>
#import "RBXFacebookStoragePolicy.h"
static unsigned checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL line %d\n",__LINE__); return 1; } } while(0)
int main(void) { @autoreleasepool {
 NSDictionary *fb=RBXAppDescriptorForType(@"facebook");
 NSString *a=RBXAppBundleIdentifier(fb,@"storage-A"), *b=RBXAppBundleIdentifier(fb,@"storage-B");
 NSArray *sources=RBXFacebookSharedStorageDomains(); NSMutableSet *mapped=[NSMutableSet set];
 CHECK(sources.count==4);
 for(NSString *source in sources) {
  NSString *aa=nil,*bb=nil;CHECK(RBXFacebookMapStorageDomain(a,source,&aa));CHECK(RBXFacebookMapStorageDomain(b,source,&bb));
  CHECK(![aa isEqual:source] && ![aa isEqual:bb]);[mapped addObject:aa];
  NSString *twice=nil;CHECK(RBXFacebookMapStorageDomain(a,aa,&twice)&&[twice isEqual:aa]);
  CHECK(!RBXFacebookMapStorageDomain(a,bb,&twice));
  CHECK(!RBXFacebookMapStorageDomain(b,aa,&twice));
 }
 CHECK(mapped.count==4);
 NSString *out=nil;
 CHECK(RBXFacebookMapStorageDomain(a,@"com.facebook.Facebook",&out)&&[out isEqual:a]);
 CHECK(RBXFacebookMapStorageDomain(a,a,&out)&&[out isEqual:a]);
 CHECK(RBXFacebookMapStorageDomain(a,nil,&out)&&out==nil);
 for(id domain in @[b,[b stringByAppendingString:@".private"],@"group.com.facebook.unknown",@"group.com.facebook.family.evil",@"group.com.metaplatforms.family.evil",@"com.reddit.Reddit",RBXAppBundleIdentifier(RBXRedditAppDescriptor(),@"other"),@"",@4,NSNull.null]) CHECK(!RBXFacebookMapStorageDomain(a,domain,&out));
 for(NSString *domain in @[NSGlobalDomain,NSArgumentDomain,NSRegistrationDomain,@"com.apple.UIKit"]) CHECK(RBXFacebookMapStorageDomain(a,domain,&out)&&[out isEqual:domain]);
 CHECK(!RBXFacebookMapStorageDomain(@"com.facebook.Facebook",sources[0],&out));
 CHECK(!RBXFacebookMapStorageDomain(RBXAppBundleIdentifier(RBXRedditAppDescriptor(),@"A"),sources[0],&out));
 for(NSString *source in sources) {NSString *role=RBXFacebookStorageRole(source);CHECK(role.length && [role rangeOfString:@"/"].location==NSNotFound);}
 CHECK(!RBXFacebookStorageRole(@"group.com.facebook.family/../other"));
 printf("PASS Facebook storage domain policy: %u assertions\n",checks);
} return 0; }
