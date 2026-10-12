#import "../Switching/LBXInstalledApplicationBinding.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <sys/acl.h>
#include <membership.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>

static NSUInteger checks,failures;
static void Check(BOOL good,NSString *why){checks++;if(!good){failures++;fprintf(stderr,"FAIL: %s\n",why.UTF8String);}}

#if LBX_INSTALLED_APPLICATION_BINDING_TESTING
@interface InstallationFixture:NSObject
@property(nonatomic,copy) NSString *base,*root,*installation,*bundle,*plist,*executable,*plugins,*extension,*extensionPlist,*extensionExecutable;
@property(nonatomic,copy) NSDictionary *registration;
@end
@implementation InstallationFixture @end
static NSString *Hash(NSData *data){unsigned char bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);NSMutableString *result=[NSMutableString string];for(NSUInteger i=0;i<sizeof(bytes);i++)[result appendFormat:@"%02x",bytes[i]];return result;}
static BOOL WriteBytes(NSString *path,NSData *data,mode_t mode){return [data writeToFile:path atomically:NO]&&chmod(path.fileSystemRepresentation,mode)==0;}
static BOOL WriteInfo(NSString *path,NSDictionary *info){NSData *bytes=[NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];return bytes&&WriteBytes(path,bytes,0644);}
static BOOL WriteSameInode(NSString *path,NSData *bytes,mode_t mode){struct stat before,after;BOOL valid=!lstat(path.fileSystemRepresentation,&before)&&WriteBytes(path,bytes,mode)&&!lstat(path.fileSystemRepresentation,&after);Check(valid&&before.st_dev==after.st_dev&&before.st_ino==after.st_ino,@"same-inode mutation is verified against real pre/post descriptor identity");return valid&&before.st_dev==after.st_dev&&before.st_ino==after.st_ino;}
static NSDictionary *MainInfo(void){return @{@"CFBundleIdentifier":@"com.burbn.instagram",@"CFBundleExecutable":@"Instagram",@"CFBundleShortVersionString":@"448.0.0",@"CFBundleVersion":@"1072661960"};}
static NSDictionary *ExtensionInfo(void){return @{@"CFBundleIdentifier":@"com.burbn.instagram.shareextension",@"CFBundleExecutable":@"Share",@"NSExtension":@{@"NSExtensionPointIdentifier":@"com.apple.share-services"}};}
static NSMutableDictionary *Replace(NSDictionary *value,NSString *key,id replacement){NSMutableDictionary *copy=[value mutableCopy];if(replacement)copy[key]=replacement;else[copy removeObjectForKey:key];return copy;}
static BOOL MakeDirectory(NSString *path){return [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:nil]&&chmod(path.fileSystemRepresentation,0755)==0;}
static BOOL Remove(NSString *path){return [NSFileManager.defaultManager removeItemAtPath:path error:nil];}
static BOOL ReplaceInode(NSString *path,NSString *base,mode_t mode){struct stat before,after;NSData *bytes=[NSData dataWithContentsOfFile:path];NSString *held=[base stringByAppendingPathComponent:@"retained-old-inode"];BOOL valid=bytes&&!lstat(path.fileSystemRepresentation,&before)&&!rename(path.fileSystemRepresentation,held.fileSystemRepresentation)&&WriteBytes(path,bytes,mode)&&!lstat(path.fileSystemRepresentation,&after);Check(valid&&before.st_dev==after.st_dev&&before.st_ino!=after.st_ino&&[[NSData dataWithContentsOfFile:path] isEqual:bytes],@"replacement retains old inode outside app and independently verifies different new inode with exact same bytes");return valid&&before.st_dev==after.st_dev&&before.st_ino!=after.st_ino;}
static NSDictionary *FacebookMainInfo(void){return @{@"CFBundleIdentifier":@"com.facebook.Facebook",@"CFBundleExecutable":@"Facebook",@"CFBundleShortVersionString":@"1.0",@"CFBundleVersion":@"1"};}
static NSDictionary *FacebookExtensionInfo(void){return @{@"CFBundleIdentifier":@"com.facebook.Facebook.shareextension",@"CFBundleExecutable":@"Share",@"NSExtension":@{@"NSExtensionPointIdentifier":@"com.apple.share-services"}};}
static InstallationFixture *FacebookFixture(void){
    char temporary[]="/tmp/socialbox-installed-facebook.XXXXXX";if(!mkdtemp(temporary))return nil;
    char physical[PATH_MAX];if(!realpath(temporary,physical))return nil;
    InstallationFixture *f=[InstallationFixture new];f.base=[NSString stringWithUTF8String:physical];f.root=[f.base stringByAppendingPathComponent:@"Application"];
    f.installation=[f.root stringByAppendingPathComponent:@"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"];
    f.bundle=[f.installation stringByAppendingPathComponent:@"Facebook.app"];f.plist=[f.bundle stringByAppendingPathComponent:@"Info.plist"];
    f.executable=[f.bundle stringByAppendingPathComponent:@"Facebook"];f.plugins=[f.bundle stringByAppendingPathComponent:@"PlugIns"];
    f.extension=[f.plugins stringByAppendingPathComponent:@"Share.appex"];f.extensionPlist=[f.extension stringByAppendingPathComponent:@"Info.plist"];f.extensionExecutable=[f.extension stringByAppendingPathComponent:@"Share"];
    BOOL valid=MakeDirectory(f.root)&&MakeDirectory(f.installation)&&MakeDirectory(f.bundle)&&WriteInfo(f.plist,FacebookMainInfo())&&WriteBytes(f.executable,[@"private fixture executable: facebook v1\n" dataUsingEncoding:NSUTF8StringEncoding],0755);
    valid=valid&&MakeDirectory(f.plugins)&&MakeDirectory(f.extension)&&WriteInfo(f.extensionPlist,FacebookExtensionInfo())&&WriteBytes(f.extensionExecutable,[@"private fixture executable: facebook extension v1\n" dataUsingEncoding:NSUTF8StringEncoding],0644);
    f.registration=@{@"bundlePath":f.bundle,@"canonicalExecutablePath":f.executable};
    if(!valid){Remove(f.base);return nil;}return f;
}
static InstallationFixture *Fixture(BOOL extension){
    char temporary[]="/tmp/socialbox-installed-binding.XXXXXX";if(!mkdtemp(temporary))return nil;
    char physical[PATH_MAX];if(!realpath(temporary,physical))return nil;
    InstallationFixture *f=[InstallationFixture new];f.base=[NSString stringWithUTF8String:physical];f.root=[f.base stringByAppendingPathComponent:@"Application"];
    f.installation=[f.root stringByAppendingPathComponent:@"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"];
    f.bundle=[f.installation stringByAppendingPathComponent:@"Instagram.app"];f.plist=[f.bundle stringByAppendingPathComponent:@"Info.plist"];
    f.executable=[f.bundle stringByAppendingPathComponent:@"Instagram"];f.plugins=[f.bundle stringByAppendingPathComponent:@"PlugIns"];
    f.extension=[f.plugins stringByAppendingPathComponent:@"Share.appex"];f.extensionPlist=[f.extension stringByAppendingPathComponent:@"Info.plist"];f.extensionExecutable=[f.extension stringByAppendingPathComponent:@"Share"];
    BOOL valid=MakeDirectory(f.root)&&MakeDirectory(f.installation)&&MakeDirectory(f.bundle)&&WriteInfo(f.plist,MainInfo())&&WriteBytes(f.executable,[@"private fixture executable: main v1\n" dataUsingEncoding:NSUTF8StringEncoding],0755);
    if(extension)valid=valid&&MakeDirectory(f.plugins)&&MakeDirectory(f.extension)&&WriteInfo(f.extensionPlist,ExtensionInfo())&&WriteBytes(f.extensionExecutable,[@"private fixture executable: extension v1\n" dataUsingEncoding:NSUTF8StringEncoding],0644);
    f.registration=@{@"bundlePath":f.bundle,@"canonicalExecutablePath":f.executable};
    if(!valid){Remove(f.base);return nil;}return f;
}
static void Use(InstallationFixture *fixture){[LBXInstalledApplicationBinding testUseRegistration:fixture.registration installationRoot:fixture.root];}
static LBXInstalledApplicationBinding *Observe(InstallationFixture *f){Use(f);NSError *error=nil;LBXInstalledApplicationBinding *binding=[LBXInstalledApplicationBinding observeOfficialInstagram:&error];Check(binding&&!error,@"valid real filesystem fixture observed before adverse mutation");return binding;}
static BOOL Reject(InstallationFixture *f){Use(f);NSError *error=nil;id result=[LBXInstalledApplicationBinding observeOfficialInstagram:&error];return !result&&error&&![error.description containsString:f.base]&&![error.description containsString:@"private fixture executable"]&&![error.description containsString:@"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"];}
static BOOL Contains(id value,id needle){if([value isKindOfClass:NSDictionary.class]){for(id key in value)if(Contains(value[key],needle))return YES;return NO;}if([value isKindOfClass:NSArray.class]){for(id item in value)if(Contains(item,needle))return YES;return NO;}return [value isEqual:needle];}
static BOOL ImmutableTree(id value){
    if([value isKindOfClass:NSDictionary.class]){BOOL immutable=NO;@try{[(NSMutableDictionary *)value setObject:@1 forKey:@"test-mutation"];}@catch(__unused NSException *e){immutable=YES;}if(!immutable)return NO;for(id key in value)if(!ImmutableTree(value[key]))return NO;}
    else if([value isKindOfClass:NSArray.class]){BOOL immutable=NO;@try{[(NSMutableArray *)value addObject:@1];}@catch(__unused NSException *e){immutable=YES;}if(!immutable)return NO;for(id item in value)if(!ImmutableTree(item))return NO;}
    else if([value isKindOfClass:NSString.class]){NSString *before=[value copy];BOOL immutable=NO;@try{[(NSMutableString *)value appendString:@"test-mutation"];}@catch(__unused NSException *e){immutable=YES;}return immutable&&[value isEqual:before];}
    return YES;
}
static BOOL SetACL(NSString *path,BOOL populated){
    acl_t acl=acl_init(populated?1:0);BOOL valid=acl!=NULL;
    if(populated){uuid_t subject;acl_entry_t entry;acl_permset_t permissions;valid=valid&&!mbr_uid_to_uuid(geteuid(),subject)&&!acl_create_entry(&acl,&entry)&&!acl_set_tag_type(entry,ACL_EXTENDED_ALLOW)&&!acl_set_qualifier(entry,subject)&&!acl_get_permset(entry,&permissions)&&!acl_add_perm(permissions,ACL_READ_DATA);}
    if(valid)valid=acl_set_file(path.fileSystemRepresentation,ACL_TYPE_EXTENDED,acl)==0;if(acl)acl_free(acl);return valid;
}
static void Adverse(NSString *label,BOOL extension,BOOL (^mutation)(InstallationFixture *)){
    InstallationFixture *f=Fixture(extension);Check(f!=nil,@"adverse test has genuine separate private fixture");if(!f)return;
    LBXInstalledApplicationBinding *prior=Observe(f);Check(mutation(f),@"adverse filesystem or registration mutation actually occurred");Check(Reject(f),label);
    NSError *error=nil;Check(![prior matchesCurrentInstallation:&error]&&error!=nil,@"adverse current installation cannot match an earlier binding");[LBXInstalledApplicationBinding testUseRegistration:nil installationRoot:nil];Remove(f.base);
}
static void Changed(NSString *label,BOOL extension,BOOL (^mutation)(InstallationFixture *)){
    InstallationFixture *f=Fixture(extension);Check(f!=nil,@"changed test has genuine separate private fixture");if(!f)return;
    LBXInstalledApplicationBinding *prior=Observe(f);NSDictionary *saved=prior.privateDictionary;
    Check(mutation(f),@"valid changed installation mutation actually occurred");Use(f);NSError *error=nil;
    Check(![prior matchesCurrentInstallation:&error]&&error!=nil,label);
    LBXInstalledApplicationBinding *current=[LBXInstalledApplicationBinding observeOfficialInstagram:&error];Check(current&&!error&&![current.privateDictionary isEqual:saved],@"changed valid installation produces distinct immutable evidence");Check([prior.privateDictionary isEqual:saved],@"new observation never mutates an existing binding");[LBXInstalledApplicationBinding testUseRegistration:nil installationRoot:nil];Remove(f.base);
}
static void DuringCapture(NSString *label,void (^mutation)(InstallationFixture *)){
    InstallationFixture *f=Fixture(YES);Check(f!=nil,@"mid-capture test has genuine separate private fixture");if(!f)return;Use(f);__block BOOL changed=NO;
    [LBXInstalledApplicationBinding testAfterOpeningFile:^(NSString *path){if(changed||![path isEqual:f.executable])return;changed=YES;mutation(f);}];
    NSError *error=nil;id result=[LBXInstalledApplicationBinding observeOfficialInstagram:&error];
    Check(changed,@"fixture hook actually ran after descriptor observation began");Check(!result&&error!=nil,label);
    [LBXInstalledApplicationBinding testAfterOpeningFile:nil];[LBXInstalledApplicationBinding testUseRegistration:nil installationRoot:nil];Remove(f.base);
}
static void AfterRegistrationCapture(NSString *label,BOOL extension,BOOL (^mutation)(InstallationFixture *)){
    InstallationFixture *f=Fixture(extension);Check(f!=nil,@"final registration mutation has genuine separate private fixture");if(!f)return;Use(f);__block BOOL changed=NO;
    [LBXInstalledApplicationBinding testAfterFinalRegistration:^{changed=mutation(f);}];NSError *error=nil;id result=[LBXInstalledApplicationBinding observeOfficialInstagram:&error];
    Check(changed,@"real inventory mutation actually occurred after last registration observations");Check(!result&&error!=nil,label);
    [LBXInstalledApplicationBinding testAfterFinalRegistration:nil];[LBXInstalledApplicationBinding testUseRegistration:nil installationRoot:nil];Remove(f.base);
}
#endif

int main(void){@autoreleasepool{
#if LBX_INSTALLED_APPLICATION_BINDING_TESTING
    [LBXInstalledApplicationBinding testUseRegistration:nil installationRoot:nil];NSError *error=nil;
    if(getuid()!=0||geteuid()!=0)Check(![LBXInstalledApplicationBinding observeOfficialInstagram:&error]&&error!=nil,@"unprivileged real observer cannot invent official registration");
    if(getuid()!=0||geteuid()!=0)Check(![LBXInstalledApplicationBinding observeOfficialFacebook:&error]&&error!=nil,@"unprivileged real observer cannot invent official Facebook registration");
    InstallationFixture *f=Fixture(YES);Check(f!=nil,@"complete genuine private fixture setup");if(!f)return 1;
    LBXInstalledApplicationBinding *binding=Observe(f);Check(binding!=nil,@"main plus read-only embedded extension accepted as observed ownership only");
    if(!binding){[LBXInstalledApplicationBinding testUseRegistration:nil installationRoot:nil];Remove(f.base);NSLog(@"FAIL: %lu installed application binding assertions, %lu failures",(unsigned long)checks,(unsigned long)failures);return 1;}
    NSData *mainBefore=[NSData dataWithContentsOfFile:f.executable],*extensionBefore=[NSData dataWithContentsOfFile:f.extensionExecutable],*plistBefore=[NSData dataWithContentsOfFile:f.plist];struct stat mainStat,plistStat,extensionStat;
    Check(!lstat(f.executable.fileSystemRepresentation,&mainStat)&&!lstat(f.plist.fileSystemRepresentation,&plistStat)&&!lstat(f.extensionExecutable.fileSystemRepresentation,&extensionStat),@"stat evidence came from actual fixture nodes");
    Check(Contains(binding.privateDictionary,f.bundle)&&Contains(binding.privateDictionary,f.executable)&&Contains(binding.privateDictionary,f.extensionExecutable),@"private snapshot binds exact registered bundle and all executable paths");
    Check(Contains(binding.privateDictionary,Hash(mainBefore))&&Contains(binding.privateDictionary,Hash(extensionBefore))&&Contains(binding.privateDictionary,Hash(plistBefore)),@"independent SHA256 pins exact executable and property-list bytes");
    Check(Contains(binding.privateDictionary,@(mainStat.st_ino))&&Contains(binding.privateDictionary,@(plistStat.st_ino))&&Contains(binding.privateDictionary,@(extensionStat.st_ino)),@"exact device node inode identities are recorded");
    Check(Contains(binding.privateDictionary,@(mainStat.st_dev)),@"filesystem device identity is recorded with inode identity");
    NSDictionary *mainNode=binding.privateDictionary[@"mainExecutable"];
    Check([mainNode[@"path"] isEqual:f.executable]&&[mainNode[@"sha256"] isEqual:Hash(mainBefore)]&&[mainNode[@"device"] longLongValue]==mainStat.st_dev&&[mainNode[@"inode"] unsignedLongLongValue]==mainStat.st_ino,@"main file binds independent bytes digest and exact descriptor identity together");
    Check([mainNode[@"size"] longLongValue]==mainStat.st_size&&[mainNode[@"linkCount"] unsignedLongLongValue]==mainStat.st_nlink&&[mainNode[@"owner"] unsignedLongLongValue]==mainStat.st_uid&&[mainNode[@"group"] unsignedLongLongValue]==mainStat.st_gid,@"main descriptor ownership size and link count are exact");
    Check(([mainNode[@"mode"] unsignedLongLongValue]&07777)==(mainStat.st_mode&07777)&&[mainNode[@"mtimeSeconds"] longLongValue]==mainStat.st_mtimespec.tv_sec&&[mainNode[@"mtimeNanoseconds"] longLongValue]==mainStat.st_mtimespec.tv_nsec&&[mainNode[@"ctimeSeconds"] longLongValue]==mainStat.st_ctimespec.tv_sec&&[mainNode[@"ctimeNanoseconds"] longLongValue]==mainStat.st_ctimespec.tv_nsec,@"mode and complete modification/change timestamps are exact observed metadata");
    Check([binding matchesCurrentInstallation:&error]&&!error,@"unchanged current registration and all nodes revalidate");
    LBXInstalledApplicationBinding *again=[LBXInstalledApplicationBinding observeOfficialInstagram:&error];Check([again.privateDictionary isEqual:binding.privateDictionary],@"stable observation has identical bytes metadata digests and inode binding");
    Check([[NSData dataWithContentsOfFile:f.executable] isEqual:mainBefore]&&[[NSData dataWithContentsOfFile:f.extensionExecutable] isEqual:extensionBefore]&&[[NSData dataWithContentsOfFile:f.plist] isEqual:plistBefore],@"observer never rewrites any installed executable or metadata bytes");
    Check(ImmutableTree(binding.privateDictionary)&&ImmutableTree(binding.safeStatus),@"all nested private and public values have immutable ownership");
    Check([binding.privateDictionary[@"runtimeAccepted"] isEqual:@NO]&&[binding.safeStatus[@"runtimeAccepted"] isEqual:@NO],@"binding and status always deny runtime acceptance");
    Check([binding.safeStatus[@"signatureVerified"] isEqual:@NO]&&[binding.safeStatus[@"wholeBundleIntegrityVerified"] isEqual:@NO],@"owned file bytes do not impersonate publisher signature or whole-bundle verification");
    Check(!binding.privateDictionary[@"license"]&&!binding.privateDictionary[@"sourceAuthorization"]&&!binding.privateDictionary[@"launchPermit"],@"observation contains no source license or transferable admission permit");
    NSString *display=[@[binding.description,binding.debugDescription,binding.safeStatus.description] componentsJoinedByString:@"\n"];
    for(NSString *sensitive in @[f.base,f.bundle,f.executable,f.extensionExecutable,@"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",Hash(mainBefore),Hash(extensionBefore),@"private fixture executable"])
        Check(![display containsString:sensitive],@"safe projections omit private paths inode-bound UUIDs hashes and executable data");
    NSMutableDictionary *registration=[f.registration mutableCopy];NSMutableString *path=[f.bundle mutableCopy];registration[@"bundlePath"]=path;[LBXInstalledApplicationBinding testUseRegistration:registration installationRoot:f.root];
    registration[@"canonicalExecutablePath"]=@"/untrusted";[path appendString:@"/mutated"];
    Check([binding matchesCurrentInstallation:&error]&&!error,@"test registration provider copies mutable caller data rather than retaining authority aliases");
    [LBXInstalledApplicationBinding testUseRegistration:nil installationRoot:nil];Remove(f.base);
    f=Fixture(YES);Check(f!=nil,@"two-extension genuine fixture setup");if(!f)return 1;NSString *second=[f.plugins stringByAppendingPathComponent:@"Aardvark.appex"];
    Check(MakeDirectory(second)&&WriteInfo([second stringByAppendingPathComponent:@"Info.plist"],Replace(ExtensionInfo(),@"CFBundleIdentifier",@"com.burbn.instagram.aardvark"))&&WriteBytes([second stringByAppendingPathComponent:@"Share"],[@"second extension" dataUsingEncoding:NSUTF8StringEncoding],0644),@"distinct second embedded executable actually exists");
    binding=Observe(f);NSArray *inventory=binding.privateDictionary[@"extensions"];
    Check(inventory.count==2&&[inventory[0][@"bundlePath"] isEqual:second]&&[inventory[1][@"bundlePath"] isEqual:f.extension],@"extension inventory is deterministic by actual bundle-folder name with no duplicate identity");
    Check([binding matchesCurrentInstallation:&error]&&!error,@"multiple distinct extension executable bindings remain stable");[LBXInstalledApplicationBinding testUseRegistration:nil installationRoot:nil];Remove(f.base);
    InstallationFixture *facebook=FacebookFixture();Check(facebook!=nil,@"complete genuine Facebook fixture setup");if(!facebook)return 1;
    Use(facebook);NSError *facebookError=nil;LBXInstalledApplicationBinding *facebookBinding=[LBXInstalledApplicationBinding observeOfficialFacebook:&facebookError];
    Check(facebookBinding&&!facebookError&&[facebookBinding.privateDictionary[@"bundleIdentifier"] isEqual:@"com.facebook.Facebook"]&&[facebookBinding.privateDictionary[@"runtimeAccepted"] isEqual:@NO],@"official Facebook installation is observed without runtime admission");
    Check([facebookBinding.safeStatus[@"runtimeAccepted"] isEqual:@NO]&&[facebookBinding matchesCurrentInstallation:&facebookError]&&!facebookError,@"unchanged Facebook installation revalidates only as Facebook");
    Check(![LBXInstalledApplicationBinding observeOfficialInstagram:&facebookError],@"Instagram observer cannot adopt a Facebook installation");
    Check([facebookBinding.privateDictionary[@"extensions"] count]==1,@"Facebook share extension stays a distinct member of the Facebook bundle");
    [LBXInstalledApplicationBinding testUseRegistration:nil installationRoot:nil];Remove(facebook.base);
    f=Fixture(YES);Check(f!=nil,@"Instagram fixture for Facebook observer mismatch");if(!f)return 1;Use(f);
    Check(![LBXInstalledApplicationBinding observeOfficialFacebook:&error],@"Facebook observer cannot adopt an Instagram installation");
    Check(WriteInfo(f.plist,Replace(MainInfo(),@"CFBundleIdentifier",@"com.twitter.twitter"))&&![LBXInstalledApplicationBinding observeOfficialInstagram:&error],@"Twitter cannot use the official Instagram observer");
    [LBXInstalledApplicationBinding testUseRegistration:nil installationRoot:nil];Remove(f.base);

    for(NSString *key in @[@"plist",@"executable",@"extensionPlist",@"extensionExecutable"])
        Adverse(@"missing installed metadata or executable fails closed",YES,^BOOL(InstallationFixture *x){return Remove([x valueForKey:key]);});
    for(NSString *key in @[@"root",@"installation",@"bundle",@"plist",@"executable",@"plugins",@"extension",@"extensionPlist",@"extensionExecutable"]){
        Adverse(@"writable trusted installation node is rejected",YES,^BOOL(InstallationFixture *x){NSString *p=[x valueForKey:key];struct stat s;return !lstat(p.fileSystemRepresentation,&s)&&!chmod(p.fileSystemRepresentation,(s.st_mode&07777)|0020);});
        Adverse(@"nonempty ACL on an installation node is rejected",YES,^BOOL(InstallationFixture *x){return SetACL([x valueForKey:key],YES);});
    }
    for(NSString *key in @[@"plist",@"executable",@"extensionPlist",@"extensionExecutable"]){
        Adverse(@"hard-linked metadata or executable is not uniquely owned",YES,^BOOL(InstallationFixture *x){NSString *p=[x valueForKey:key];return !link(p.fileSystemRepresentation,[x.base stringByAppendingPathComponent:@"hard-link"].fileSystemRepresentation);});
        Adverse(@"symlink metadata or executable is never traversed",YES,^BOOL(InstallationFixture *x){NSString *p=[x valueForKey:key],*outside=[x.base stringByAppendingPathComponent:@"outside"];return !rename(p.fileSystemRepresentation,outside.fileSystemRepresentation)&&!symlink(outside.fileSystemRepresentation,p.fileSystemRepresentation);});
    }
    Adverse(@"interior bundle symlink is rejected before observation",YES,^BOOL(InstallationFixture *x){NSString *outside=[x.base stringByAppendingPathComponent:@"outside.app"];return !rename(x.bundle.fileSystemRepresentation,outside.fileSystemRepresentation)&&!symlink(outside.fileSystemRepresentation,x.bundle.fileSystemRepresentation);});
    Adverse(@"interior installation symlink is rejected before observation",YES,^BOOL(InstallationFixture *x){NSString *outside=[x.base stringByAppendingPathComponent:@"outside-installation"];return !rename(x.installation.fileSystemRepresentation,outside.fileSystemRepresentation)&&!symlink(outside.fileSystemRepresentation,x.installation.fileSystemRepresentation);});
    Adverse(@"installation root symlink is rejected before observation",YES,^BOOL(InstallationFixture *x){NSString *outside=[x.base stringByAppendingPathComponent:@"outside-root"];return !rename(x.root.fileSystemRepresentation,outside.fileSystemRepresentation)&&!symlink(outside.fileSystemRepresentation,x.root.fileSystemRepresentation);});
    Adverse(@"PlugIns directory symlink is rejected before observation",YES,^BOOL(InstallationFixture *x){NSString *outside=[x.base stringByAppendingPathComponent:@"outside-plugins"];return !rename(x.plugins.fileSystemRepresentation,outside.fileSystemRepresentation)&&!symlink(outside.fileSystemRepresentation,x.plugins.fileSystemRepresentation);});
    Adverse(@"embedded extension directory symlink is rejected before observation",YES,^BOOL(InstallationFixture *x){NSString *outside=[x.base stringByAppendingPathComponent:@"outside-extension"];return !rename(x.extension.fileSystemRepresentation,outside.fileSystemRepresentation)&&!symlink(outside.fileSystemRepresentation,x.extension.fileSystemRepresentation);});
    Adverse(@"main must retain executable permissions",YES,^BOOL(InstallationFixture *x){return !chmod(x.executable.fileSystemRepresentation,0644);});
    Adverse(@"empty Info.plist fails closed",YES,^BOOL(InstallationFixture *x){return WriteBytes(x.plist,NSData.data,0644);});
    Adverse(@"empty executable fails closed",YES,^BOOL(InstallationFixture *x){return WriteBytes(x.executable,NSData.data,0755);});
    Adverse(@"Info.plist beyond bounded read size is rejected before capture",YES,^BOOL(InstallationFixture *x){int fd=open(x.plist.fileSystemRepresentation,O_WRONLY|O_NOFOLLOW);if(fd<0)return NO;BOOL valid=!ftruncate(fd,1024*1024+1);close(fd);return valid;});
    Adverse(@"oversized executable cannot create an unbounded digest operation",YES,^BOOL(InstallationFixture *x){int fd=open(x.executable.fileSystemRepresentation,O_WRONLY|O_NOFOLLOW);if(fd<0)return NO;BOOL valid=!ftruncate(fd,512LL*1024*1024+1);close(fd);return valid;});
    Adverse(@"FIFO masquerading as executable rejects without blocking",YES,^BOOL(InstallationFixture *x){return Remove(x.executable)&&!mkfifo(x.executable.fileSystemRepresentation,0755);});
    Adverse(@"directory masquerading as executable rejects",YES,^BOOL(InstallationFixture *x){return Remove(x.executable)&&MakeDirectory(x.executable);});
    Adverse(@"malformed Info.plist fails closed",YES,^BOOL(InstallationFixture *x){return WriteBytes(x.plist,[@"invalid" dataUsingEncoding:NSUTF8StringEncoding],0644);});
    Adverse(@"non-dictionary property list fails closed",YES,^BOOL(InstallationFixture *x){NSData *bytes=[NSPropertyListSerialization dataWithPropertyList:@[@"invalid"] format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];return WriteBytes(x.plist,bytes,0644);});
    for(id bad in @[@"com.facebook.Facebook",@"com.burbn.instagram.clone",@"",@42,@YES,@[]])
        Adverse(@"main metadata must identify fixed official Instagram exactly",YES,^BOOL(InstallationFixture *x){return WriteInfo(x.plist,Replace(MainInfo(),@"CFBundleIdentifier",bad));});
    for(id bad in @[@"../Instagram",@"PlugIns/Share.appex/Share",@".",@"..",@"",@42,@YES,@[]])
        Adverse(@"main executable metadata cannot escape or coerce a name",YES,^BOOL(InstallationFixture *x){return WriteInfo(x.plist,Replace(MainInfo(),@"CFBundleExecutable",bad));});
    Adverse(@"registered canonical main path must equal actual bundle executable",YES,^BOOL(InstallationFixture *x){x.registration=Replace(x.registration,@"canonicalExecutablePath",x.extensionExecutable);return YES;});
    Adverse(@"registration must include canonical main executable identity",YES,^BOOL(InstallationFixture *x){x.registration=Replace(x.registration,@"canonicalExecutablePath",nil);return YES;});
    Adverse(@"registration must include exactly observed bundle path",YES,^BOOL(InstallationFixture *x){x.registration=Replace(x.registration,@"bundlePath",nil);return YES;});
    Adverse(@"extra registration fields cannot supply caller authority",YES,^BOOL(InstallationFixture *x){x.registration=Replace(x.registration,@"authorized",@YES);return YES;});
    Adverse(@"unregistered alternate bundle is not allowed by filesystem discovery",YES,^BOOL(InstallationFixture *x){x.registration=Replace(x.registration,@"bundlePath",[x.installation stringByAppendingPathComponent:@"Missing.app"]);return YES;});
    for(NSString *spelling in @[@"/./",@"//",@"/../Instagram.app/"])
        Adverse(@"noncanonical registered path spelling cannot supply ownership",YES,^BOOL(InstallationFixture *x){x.registration=Replace(x.registration,@"canonicalExecutablePath",[x.bundle stringByAppendingFormat:@"%@Instagram",spelling]);return YES;});
    Adverse(@"registration must use the exact fixed installation root layout",YES,^BOOL(InstallationFixture *x){x.root=[x.base stringByAppendingPathComponent:@"OtherApplication"];return YES;});
    Adverse(@"non-UUID installation directory is rejected",YES,^BOOL(InstallationFixture *x){NSString *old=x.installation,*replacement=[x.root stringByAppendingPathComponent:@"not-a-uuid"];if(rename(old.fileSystemRepresentation,replacement.fileSystemRepresentation))return NO;x.installation=replacement;x.bundle=[replacement stringByAppendingPathComponent:@"Instagram.app"];x.executable=[x.bundle stringByAppendingPathComponent:@"Instagram"];x.registration=@{@"bundlePath":x.bundle,@"canonicalExecutablePath":x.executable};return YES;});
    Adverse(@"unknown PlugIns child cannot disappear from executable inventory",YES,^BOOL(InstallationFixture *x){return WriteBytes([x.plugins stringByAppendingPathComponent:@"Unknown"],[@"unknown" dataUsingEncoding:NSUTF8StringEncoding],0644);});
    Adverse(@"embedded extension metadata must contain an extension dictionary",YES,^BOOL(InstallationFixture *x){return WriteInfo(x.extensionPlist,Replace(ExtensionInfo(),@"NSExtension",@"not-a-dictionary"));});
    Adverse(@"embedded extension requires explicit extension metadata",YES,^BOOL(InstallationFixture *x){return WriteInfo(x.extensionPlist,Replace(ExtensionInfo(),@"NSExtension",nil));});
    for(id bad in @[@"com.facebook.Facebook.share",@"com.burbn.instagram",@"",@42,@YES,@[]])
        Adverse(@"embedded extension ID must be a distinct fixed-app member",YES,^BOOL(InstallationFixture *x){return WriteInfo(x.extensionPlist,Replace(ExtensionInfo(),@"CFBundleIdentifier",bad));});
    Adverse(@"duplicate embedded extension identifiers are rejected",YES,^BOOL(InstallationFixture *x){NSString *duplicate=[x.plugins stringByAppendingPathComponent:@"Duplicate.appex"];return MakeDirectory(duplicate)&&WriteInfo([duplicate stringByAppendingPathComponent:@"Info.plist"],ExtensionInfo())&&WriteBytes([duplicate stringByAppendingPathComponent:@"Share"],[@"other" dataUsingEncoding:NSUTF8StringEncoding],0644);});
    Adverse(@"embedded executable names cannot point into a different extension",YES,^BOOL(InstallationFixture *x){return WriteInfo(x.extensionPlist,Replace(ExtensionInfo(),@"CFBundleExecutable",@"../Instagram"));});

    Changed(@"same-inode executable content drift is detected",YES,^BOOL(InstallationFixture *x){return WriteSameInode(x.executable,[@"private fixture executable: main v2\n" dataUsingEncoding:NSUTF8StringEncoding],0755);});
    Changed(@"same-inode Info.plist byte drift is detected",YES,^BOOL(InstallationFixture *x){NSData *bytes=[NSPropertyListSerialization dataWithPropertyList:Replace(MainInfo(),@"CFBundleVersion",@"1072661961") format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];return WriteSameInode(x.plist,bytes,0644);});
    Changed(@"valid executable mode drift is detected",YES,^BOOL(InstallationFixture *x){return !chmod(x.executable.fileSystemRepresentation,0555);});
    Changed(@"same bytes in a replaced executable inode are detected",YES,^BOOL(InstallationFixture *x){return ReplaceInode(x.executable,x.base,0755);});
    Changed(@"same bytes in a replaced plist inode are detected",YES,^BOOL(InstallationFixture *x){return ReplaceInode(x.plist,x.base,0644);});
    Changed(@"valid extension ID changes are detected",YES,^BOOL(InstallationFixture *x){return WriteInfo(x.extensionPlist,Replace(ExtensionInfo(),@"CFBundleIdentifier",@"com.burbn.instagram.otherextension"));});
    Changed(@"embedded extension removal changes the installation binding",YES,^BOOL(InstallationFixture *x){return Remove(x.extension);});
    Changed(@"embedded extension addition changes the installation binding",NO,^BOOL(InstallationFixture *x){return MakeDirectory(x.plugins)&&MakeDirectory(x.extension)&&WriteInfo(x.extensionPlist,ExtensionInfo())&&WriteBytes(x.extensionExecutable,[@"new extension" dataUsingEncoding:NSUTF8StringEncoding],0644);});
    Changed(@"reinstalled official app at a new registered UUID cannot reuse binding",YES,^BOOL(InstallationFixture *x){NSString *replacement=[x.root stringByAppendingPathComponent:@"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"];if(rename(x.installation.fileSystemRepresentation,replacement.fileSystemRepresentation))return NO;x.installation=replacement;x.bundle=[replacement stringByAppendingPathComponent:@"Instagram.app"];x.executable=[x.bundle stringByAppendingPathComponent:@"Instagram"];x.registration=@{@"bundlePath":x.bundle,@"canonicalExecutablePath":x.executable};return YES;});
    DuringCapture(@"path replacement after opening descriptor cannot bind an unrelated new inode",^(InstallationFixture *x){NSString *old=[x.base stringByAppendingPathComponent:@"old-main"];Check(!rename(x.executable.fileSystemRepresentation,old.fileSystemRepresentation)&&WriteBytes(x.executable,[@"replacement" dataUsingEncoding:NSUTF8StringEncoding],0755),@"mid-capture inode replacement actually occurred");});
    DuringCapture(@"same-inode writes during capture cannot produce a mixed digest/metadata snapshot",^(InstallationFixture *x){Check(WriteSameInode(x.executable,[@"changed while observed" dataUsingEncoding:NSUTF8StringEncoding],0755),@"mid-capture same-inode bytes really changed");});
    DuringCapture(@"mode drift during capture invalidates initial descriptor metadata",^(InstallationFixture *x){Check(!chmod(x.executable.fileSystemRepresentation,0555),@"mid-capture mode actually changed");});
    DuringCapture(@"hard-link drift during capture invalidates unique node ownership",^(InstallationFixture *x){Check(!link(x.executable.fileSystemRepresentation,[x.base stringByAppendingPathComponent:@"mid-capture-link"].fileSystemRepresentation),@"mid-capture link count really changed");});
    DuringCapture(@"ACL drift during capture invalidates trusted descriptor ownership",^(InstallationFixture *x){Check(SetACL(x.executable,YES),@"mid-capture ACL really changed");});
    DuringCapture(@"previously observed plist cannot change while executable is captured",^(InstallationFixture *x){Check(WriteInfo(x.plist,Replace(MainInfo(),@"CFBundleVersion",@"1072661961")),@"already captured plist bytes really changed during observation");});
    DuringCapture(@"changed registered executable cannot slip past final registration comparison",^(InstallationFixture *x){[LBXInstalledApplicationBinding testUseRegistration:Replace(x.registration,@"canonicalExecutablePath",x.extensionExecutable) installationRoot:x.root];});
    AfterRegistrationCapture(@"extension child added after final registration still invalidates captured inventory",YES,^BOOL(InstallationFixture *x){NSString *added=[x.plugins stringByAppendingPathComponent:@"Late.appex"];return MakeDirectory(added)&&WriteInfo([added stringByAppendingPathComponent:@"Info.plist"],Replace(ExtensionInfo(),@"CFBundleIdentifier",@"com.burbn.instagram.late"))&&WriteBytes([added stringByAppendingPathComponent:@"Share"],[@"late extension" dataUsingEncoding:NSUTF8StringEncoding],0644);});
    AfterRegistrationCapture(@"PlugIns absent at initial inventory cannot appear after final registration",NO,^BOOL(InstallationFixture *x){return MakeDirectory(x.plugins)&&MakeDirectory(x.extension)&&WriteInfo(x.extensionPlist,ExtensionInfo())&&WriteBytes(x.extensionExecutable,[@"late first extension" dataUsingEncoding:NSUTF8StringEncoding],0644);});
    [LBXInstalledApplicationBinding testUseRegistration:nil installationRoot:nil];
    NSLog(@"%@: %lu installed application binding assertions, %lu failures",failures?@"FAIL":@"PASS",(unsigned long)checks,(unsigned long)failures);
#else
    Check(![LBXInstalledApplicationBinding respondsToSelector:NSSelectorFromString(@"testUseRegistration:installationRoot:")],@"production host class contains no fixture registration provider");
    Check(![LBXInstalledApplicationBinding respondsToSelector:NSSelectorFromString(@"testAfterOpeningFile:")],@"production host class contains no fixture mutation callback");
    Check(![LBXInstalledApplicationBinding respondsToSelector:NSSelectorFromString(@"testAfterFinalRegistration:")],@"production host class contains no fixture registration-window callback");
    if(getuid()!=0||geteuid()!=0){NSError *error=nil;Check(![LBXInstalledApplicationBinding observeOfficialInstagram:&error]&&error!=nil,@"production observer enforces real root context");
        Check(![LBXInstalledApplicationBinding observeOfficialFacebook:&error]&&error!=nil,@"Facebook production observer enforces real root context");}
    NSLog(@"%@: %lu production host boundary assertions, %lu failures",failures?@"FAIL":@"PASS",(unsigned long)checks,(unsigned long)failures);
#endif
    return failures?1:0;
}}
