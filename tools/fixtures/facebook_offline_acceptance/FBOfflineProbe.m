#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import "RBXContainerManager.h"
#import "RBXFacebookStoragePolicy.h"
#import "RBXAppKeychainPolicy.h"
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/syscall.h>
#import <objc/runtime.h>

// Device-only acceptance: enter the kernel without any libc/path hook. Keep an
// own-file positive control, so an unavailable ABI is never counted as denial.
static int RawOpen(const char *path) {
#if defined(__arm64__)
 register long a0 __asm("x0")=AT_FDCWD;
 register const char *a1 __asm("x1")=path;
 register long a2 __asm("x2")=O_RDONLY;
 register long a3 __asm("x3")=0;
 register long number __asm("x16")=SYS_openat;
 unsigned failed;
 __asm volatile("svc #0x80\n\tcset %w1, cs" : "+r"(a0), "=r"(failed)
     : "r"(a1), "r"(a2), "r"(a3), "r"(number) : "memory", "cc");
 if(failed){errno=(int)a0;return -1;}return (int)a0;
#else
 errno=ENOTSUP;return -1;
#endif
}

static NSDictionary *ReadFD(int fd, int saved, NSData *expected) {
 char bytes[16]={0};ssize_t count=fd>=0?read(fd,bytes,sizeof(bytes)):-1;
 if(fd>=0)close(fd);
 NSData *value=count>=0?[NSData dataWithBytes:bytes length:(NSUInteger)count]:nil;
 return @{@"opened":@(fd>=0),@"errno":@(saved),@"matchedCanary":@([value isEqual:expected])};
}
void RBXOfflineProbe(RBXContainerManager *manager, NSDictionary *installed){@autoreleasepool{
 NSString *home=NSHomeDirectory();NSDictionary *request=[NSDictionary dictionaryWithContentsOfFile:[home stringByAppendingPathComponent:@"Documents/SocialBoxOfflineProbe.plist"]];
 NSString *nonce=request[@"nonce"],*role=request[@"role"],*phase=request[@"phase"];
 if(![nonce isKindOfClass:NSString.class]||nonce.length!=32||![role isKindOfClass:NSString.class]||![@[@"A",@"B"] containsObject:role]||![@[@"seed",@"verify"] containsObject:phase])return;
 NSString *expectedCid=[NSString stringWithFormat:@"accept-fb-%@-%@",nonce,role];if(![manager.containerId isEqual:expectedCid])return;
 unsigned int methodCount=0;Method *methods=class_copyMethodList(NSClassFromString(@"WKPreferences"),&methodCount);for(unsigned int mi=0;mi<methodCount;mi++){NSString *name=NSStringFromSelector(method_getName(methods[mi]));if([name.lowercaseString containsString:@"peerconnection"]||[name.lowercaseString containsString:@"mediadevices"])NSLog(@"RBX_WEB_SELECTOR %@",name);}free(methods);
 BOOL seed=[phase isEqual:@"seed"];NSMutableArray *checks=[NSMutableArray array];
 void (^record)(NSString *,BOOL,id)=^(NSString *name,BOOL pass,id detail){[checks addObject:@{@"probe":name,@"pass":@(pass),@"detail":detail?:@""}];};
 record(@"validated-profile",manager.validatedProfileLoaded,@(geteuid()));
 record(@"storage-installer",[installed[@"facebook-storage"] boolValue],@"checked installer");
 record(@"keychain-installer",[installed[@"keychain-sync-policy"] boolValue],@"checked installer");
 NSDictionary *descriptor=RBXAppDescriptorForType(@"facebook");NSString *key=[@"sbx.acceptance." stringByAppendingString:nonce];NSData *value=[role dataUsingEncoding:NSUTF8StringEncoding];
 for(NSString *group in descriptor[@"keychainSourceGroups"]){
  NSMutableDictionary *query=[@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:key,(__bridge id)kSecAttrAccount:@"canary",(__bridge id)kSecAttrAccessGroup:group} mutableCopy];
  if(seed){NSMutableDictionary *add=query.mutableCopy;add[(__bridge id)kSecValueData]=value;add[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;OSStatus status=SecItemAdd((__bridge CFDictionaryRef)add,NULL);record([@"keychain-seed:" stringByAppendingString:group],status==errSecSuccess||status==errSecDuplicateItem,@(status));}
  query[(__bridge id)kSecReturnData]=@YES;CFTypeRef result=NULL;OSStatus status=SecItemCopyMatching((__bridge CFDictionaryRef)query,&result);id got=CFBridgingRelease(result);record([@"keychain-own:" stringByAppendingString:group],status==errSecSuccess&&[got isEqual:value],@(status));
 }
 NSUserDefaults *standard=NSUserDefaults.standardUserDefaults;if(seed)[standard setObject:role forKey:key];record(@"defaults-own",[[standard objectForKey:key] isEqual:role],@"value comparison only");
 for(NSString *source in RBXFacebookSharedStorageDomains()){
  NSUserDefaults *suite=[[NSUserDefaults alloc] initWithSuiteName:source];if(seed)[suite setObject:role forKey:key];[suite synchronize];record([@"suite-own:" stringByAppendingString:source],[[suite objectForKey:key] isEqual:role],@"value comparison only");
  CFPropertyListRef copied=CFPreferencesCopyAppValue((__bridge CFStringRef)key,(__bridge CFStringRef)source);record([@"cf-own:" stringByAppendingString:source],[CFBridgingRelease(copied) isEqual:role],@"cross-API comparison");
  NSURL *url=[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:source];NSURL *marker=[url URLByAppendingPathComponent:key];if(seed && marker)[value writeToURL:marker options:NSDataWritingAtomic error:nil];record([@"group-own:" stringByAppendingString:source],url&&[url.path hasPrefix:[home stringByAppendingString:@"/"]]&&[[NSData dataWithContentsOfURL:marker] isEqual:value],@"private-home marker");
 }
 NSString *ownFile=[home stringByAppendingPathComponent:[@"Documents/" stringByAppendingString:key]];if(seed)[value writeToFile:ownFile options:NSDataWritingAtomic error:nil];record(@"filesystem-own",[[NSData dataWithContentsOfFile:ownFile] isEqual:value],@"own marker readable");
 errno=0;int ownFD=RawOpen(ownFile.fileSystemRepresentation);NSDictionary *ownRaw=ReadFD(ownFD,errno,value);
 record(@"filesystem-own-direct-syscall",[ownRaw[@"matchedCanary"] boolValue],ownRaw);
 NSString *foreignHome=request[@"siblingHome"],*foreignBundle=request[@"siblingBundle"];
 if([foreignHome isKindOfClass:NSString.class] && [foreignBundle isKindOfClass:NSString.class]){
  for(NSString *group in RBXAppKeychainGroups(descriptor,foreignBundle)){
   NSDictionary *q=@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:key,(__bridge id)kSecAttrAccount:@"canary",(__bridge id)kSecAttrAccessGroup:group,(__bridge id)kSecReturnData:@YES};CFTypeRef r=NULL;OSStatus status=SecItemCopyMatching((__bridge CFDictionaryRef)q,&r);if(r)CFRelease(r);record([@"keychain-foreign:" stringByAppendingString:group],status==errSecMissingEntitlement||status==errSecItemNotFound,@(status));
  }
  NSUserDefaults *foreign=[[NSUserDefaults alloc] initWithSuiteName:foreignBundle];record(@"defaults-foreign",![foreign objectForKey:key],@"foreign suite absent");
  for(NSString *source in RBXFacebookSharedStorageDomains()){
   NSString *domain=RBXFacebookPrivateStorageDomain(foreignBundle,RBXFacebookStorageRole(source));CFPropertyListRef r=CFPreferencesCopyAppValue((__bridge CFStringRef)key,(__bridge CFStringRef)domain);record([@"cf-foreign:" stringByAppendingString:source],r==NULL,@"foreign domain absent");if(r)CFRelease(r);
  }
  int (*sandboxCheck)(pid_t,const char *,int,...)=dlsym(RTLD_DEFAULT,"sandbox_check");
  int sandboxResult=sandboxCheck?sandboxCheck(getpid(),"file-read-data",1,[foreignHome UTF8String]):-999;
  int (*codesignOps)(pid_t,unsigned int,void *,size_t)=dlsym(RTLD_DEFAULT,"csops");uint32_t flags=0;int codesignResult=codesignOps?codesignOps(getpid(),0,&flags,sizeof(flags)):-999;
  record(@"sandbox-observer",sandboxResult!=0,@{@"check":@(sandboxResult),@"csops":@(codesignResult),@"flags":@(flags)});
  NSString *foreignFile=[foreignHome stringByAppendingPathComponent:[@"Documents/" stringByAppendingString:key]];NSError *error=nil;NSData *foreignData=[NSData dataWithContentsOfFile:foreignFile options:0 error:&error];
  NSData *foreignExpected=[([role isEqual:@"A"]?@"B":@"A") dataUsingEncoding:NSUTF8StringEncoding];
  record(@"filesystem-foreign-data",foreignData==nil,@{@"error":@(error.code),@"matchedForeignCanary":@([foreignData isEqual:foreignExpected])});
  errno=0;int foreignFD=open(foreignFile.fileSystemRepresentation,O_RDONLY);NSDictionary *ordinary=ReadFD(foreignFD,errno,foreignExpected);
  record(@"filesystem-foreign-posix",![ordinary[@"opened"] boolValue]&&[ordinary[@"errno"] intValue]==EACCES,ordinary);
  errno=0;foreignFD=RawOpen(foreignFile.fileSystemRepresentation);NSDictionary *raw=ReadFD(foreignFD,errno,foreignExpected);
  record(@"filesystem-foreign-direct-syscall",![raw[@"opened"] boolValue]&&[raw[@"errno"] intValue]==EACCES,raw);
  NSError *fileError=nil;NSDictionary *fileAttributes=[NSFileManager.defaultManager attributesOfItemAtPath:foreignFile error:&fileError];
  record(@"filesystem-foreign-file-stat",fileAttributes==nil,@(fileError.code));
  NSError *attributesError=nil;NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:foreignHome error:&attributesError];record(@"filesystem-foreign-stat",attributes==nil,@(attributesError.code));
 }
 int fd=socket(AF_INET,SOCK_STREAM,0);struct sockaddr_in destination={0};destination.sin_len=sizeof(destination);destination.sin_family=AF_INET;destination.sin_port=htons(9);inet_pton(AF_INET,"198.51.100.1",&destination.sin_addr);errno=0;int result=fd>=0?connect(fd,(struct sockaddr *)&destination,sizeof(destination)):-1;int saved=errno;if(fd>=0)close(fd);record(@"closed-socket-gate",result<0&&(saved==EHOSTUNREACH),@(saved));
 for(NSNumber *family in @[@(AF_INET),@(AF_INET6)]){errno=0;int udp=socket(family.intValue,SOCK_DGRAM,0);int saved=errno;if(udp>=0)close(udp);record([NSString stringWithFormat:@"closed-udp-%@",family],udp<0&&saved==EACCES,@(saved));}
 int pair[2];BOOL ipc=socketpair(AF_UNIX,SOCK_STREAM,0,pair)==0;if(ipc){char got=0;ipc=send(pair[0],"x",1,0)==1&&recv(pair[1],&got,1,0)==1&&got=='x';close(pair[0]);close(pair[1]);}record(@"unix-ipc-still-works",ipc,@"local IPC control");
 BOOL all=YES;for(NSDictionary *c in checks)if(![c[@"pass"] boolValue])all=NO;
 NSDictionary *report=@{@"phase":phase,@"role":role,@"timestamp":@([NSDate.date timeIntervalSince1970]),@"uid":@(getuid()),@"checks":checks,@"passed":@(all),@"installed":installed};
 NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];[json writeToFile:[home stringByAppendingPathComponent:@"Documents/SocialBoxOfflineResult.json"] options:NSDataWritingAtomic error:nil];
}}
