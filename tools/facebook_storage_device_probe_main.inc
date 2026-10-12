#define CF(x) ((__bridge CFStringRef)(x))
static id Copied(CFTypeRef value){return CFBridgingRelease(value);}
int main(int argc,char **argv){@autoreleasepool{
 Check(argc==3,@"phase and nonce required");NSString *phase=@(argv[1]),*nonce=@(argv[2]);
 Check(nonce.length==32&&[nonce rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location==NSNotFound,@"unique test namespace");
 NSString *cid=[@"native-storage-" stringByAppendingString:nonce];NSDictionary *descriptor=RBXAppDescriptorForType(@"facebook");
 ActualBundle=RBXAppBundleIdentifier(descriptor,cid);NSString *foreign=RBXAppBundleIdentifier(descriptor,[cid stringByAppendingString:@"-B"]);
 FixtureHome=[@"/var/mobile/Library/Caches/socialbox-fbstore-probe-" stringByAppendingString:nonce];
 NSMutableArray *domains=[NSMutableArray arrayWithObjects:ActualBundle,foreign,nil];
 for(NSString *source in RBXFacebookSharedStorageDomains())for(NSString *bundle in @[ActualBundle,foreign])[domains addObject:RBXFacebookPrivateStorageDomain(bundle,RBXFacebookStorageRole(source))];
 if([phase isEqual:@"clean"]){
  for(NSString *domain in domains){CFPreferencesSetMultiple(NULL,(__bridge CFArrayRef)@[@"canary",@"native",@"role"],CF(domain),kCFPreferencesCurrentUser,kCFPreferencesAnyHost);Check(CFPreferencesAppSynchronize(CF(domain)),@"synthetic domain cleanup synchronized");}
  NSError *error=nil;BOOL removed=[NSFileManager.defaultManager removeItemAtPath:FixtureHome error:&error];Check(removed||error.code==NSFileNoSuchFileError,@"synthetic directory cleaned");
  printf("PASS device storage cleanup: %u checks\n",Checks);return 0;
 }
 if([phase isEqual:@"seed"]){
  for(NSString *domain in domains){CFPreferencesSetAppValue(CFSTR("canary"),CFSTR("native-synthetic-marker"),CF(domain));Check(CFPreferencesAppSynchronize(CF(domain)),@"synthetic canary seeded");Check([Copied(CFPreferencesCopyAppValue(CFSTR("canary"),CF(domain))) isEqual:@"native-synthetic-marker"],@"native provider confirms real data exists");}
  printf("PASS device storage seed: %u checks\n",Checks);return 0;
 }
 Check([phase isEqual:@"verify"],@"known probe phase");
 Check([NSFileManager.defaultManager createDirectoryAtPath:FixtureHome withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:nil],@"synthetic group home created");
 Substrate=dlopen("/var/jb/usr/lib/libsubstrate.dylib",RTLD_NOW);Check(Substrate!=NULL,@"real Substrate loaded");
 NSMutableDictionary *app=[@{@"bundleIdentifier":ActualBundle,@"keychainAccessGroup":RBXAppKeychainGroup(descriptor,ActualBundle),@"sourceVersion":Version,@"sourceBuild":Build} mutableCopy];[app addEntriesFromDictionary:RBXAppKeychainMetadata(descriptor,ActualBundle)];
 RBXContainerManager *m=[RBXContainerManager new];m.currentProfile=[FixtureProfile new];m.containerId=cid;m.validatedProfileLoaded=YES;m.currentProfile.rawProfile=@{@"containerId":cid,@"appType":@"facebook",@"app":app};
 Check(RBXInstallFacebookStorageHooks(m),@"actual installer checks real trampolines");
 for(NSString *source in RBXFacebookSharedStorageDomains()){
  CFStringRef src=CF(source);NSString *foreignDomain=RBXFacebookPrivateStorageDomain(foreign,RBXFacebookStorageRole(source));
  Check([Copied(CFPreferencesCopyAppValue(CFSTR("canary"),src)) isEqual:@"native-synthetic-marker"],@"public C API reaches own private canary");
  Check(!CFPreferencesCopyAppValue(CFSTR("canary"),CF(foreignDomain)),@"public C API denies real foreign canary");
  CFPreferencesSetAppValue(CFSTR("role"),(__bridge CFStringRef)source,src);Check(CFPreferencesAppSynchronize(src),@"public C write and sync");
  NSUserDefaults *suite=[[NSUserDefaults alloc] initWithSuiteName:source];Check(suite!=nil,@"real hooked suite initializer");
  Check([[suite stringForKey:@"role"] isEqual:source],@"Foundation and CF agree on domain");
  NSData *bytes=[NSData dataWithBytes:"\0\xff\x01\x7f" length:4];[suite setObject:bytes forKey:@"native"];
  Check([Copied(CFPreferencesCopyAppValue(CFSTR("native"),src)) isEqual:bytes],@"opaque bytes unchanged across actual hooked API families");
  Check(![[NSUserDefaults alloc] initWithSuiteName:foreignDomain],@"real Foundation rejects foreign suite");
  NSURL *group=[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:source];
  Check(group!=nil&&[group.path hasPrefix:[FixtureHome stringByAppendingString:@"/"]],@"actual App Group hook uses private synthetic home");
  Check([source writeToURL:[group URLByAppendingPathComponent:@"canary"] atomically:YES encoding:NSUTF8StringEncoding error:nil],@"private group path is writable");
 }
 for(NSString *source in RBXFacebookSharedStorageDomains())Check([Copied(CFPreferencesCopyAppValue(CFSTR("role"),CF(source))) isEqual:source],@"same key in all four domains never collapses");
 Check(![[NSUserDefaults alloc] initWithSuiteName:@"com.apple.UIKit"],@"platform suite objects cannot enable shared writes");
 Check(!CFPreferencesCopyAppValue(CFSTR("canary"),CF(foreign)),@"foreign application domain denied");
 Check(![NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.com.facebook.unknown"],@"unknown group has no original fallback");
 printf("PASS real Substrate storage interception on iOS: %u checks\n",Checks);return 0;
}}
