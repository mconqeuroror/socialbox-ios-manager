#import "LBXInstalledApplicationBinding.h"
#import "LBXDarwinDrainBackend.h"
#import "../../shared/RBXStorageGate.h"
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <dirent.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <string.h>

static NSString *const Instagram=@"com.burbn.instagram";
static NSString *const Facebook=@"com.facebook.Facebook";
static BOOL Official(id value){return [value isEqual:Instagram]||[value isEqual:Facebook];}
static NSString *const InstalledRoot=@"/private/var/containers/Bundle/Application";
static BOOL Fail(NSError **error,NSInteger code) {
    if(error){*error=[NSError errorWithDomain:@"com.socialbox.installed-application-binding" code:code userInfo:@{
        NSLocalizedDescriptionKey:code==2?@"Root observation is required":code==3?@"Official application registration is invalid":
        code==4?@"Official application installation changed":code==5?@"Application observation exceeded its bounds":
        @"Official application installation cannot be safely observed"}];}
    return NO;
}
static double Clock(void){mach_timebase_info_data_t scale;mach_timebase_info(&scale);return scale.denom?(double)mach_continuous_time()*scale.numer/scale.denom/1e9:NAN;}
static NSDictionary *Snapshot(id value){
    if(![NSJSONSerialization isValidJSONObject:value])return nil;NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:nil];
    return data.length&&data.length<=262144?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
}
static NSString *Hex(const unsigned char *bytes,size_t length){NSMutableString *value=[NSMutableString string];for(size_t i=0;i<length;i++)[value appendFormat:@"%02x",bytes[i]];return [value copy];}
#if LBX_INSTALLED_APPLICATION_BINDING_TESTING
static NSString *DataDigest(NSData *data){unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);return Hex(digest,sizeof(digest));}
#endif
static BOOL Name(id value){return [value isKindOfClass:NSString.class]&&[value length]&&[value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<256&&
    [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound&&![value containsString:@"/"]&&![value containsString:@"\\"]&&![@[@".",@".."] containsObject:value];}
static BOOL Path(id value){
    if(![value isKindOfClass:NSString.class]||![value hasPrefix:@"/"]||[value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>=4096||[value containsString:@"\\"]||[value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)return NO;
    NSArray *parts=[value componentsSeparatedByString:@"/"];if(parts.count<2||![parts.firstObject isEqual:@""])return NO;
    for(NSUInteger i=1;i<parts.count;i++)if(!Name(parts[i]))return NO;return YES;
}
static NSString *Normalize(id value){
    if(![value isKindOfClass:NSString.class])return nil;
    // Only the platform's documented system alias is accepted. Never resolve
    // interior symlinks, dot components or a supplied path through Foundation.
    NSString *path=[value hasPrefix:@"/var/"]?[@"/private" stringByAppendingString:value]:value;
    return Path(path)?[path copy]:nil;
}
#if LBX_INSTALLED_APPLICATION_BINDING_TESTING
static BOOL Exact(id value,NSArray *keys){if(![value isKindOfClass:NSDictionary.class]||[value count]!=keys.count)return NO;for(id key in value)if(![key isKindOfClass:NSString.class])return NO;return [[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]];}
#endif
#if !LBX_INSTALLED_APPLICATION_BINDING_TESTING
static BOOL Fingerprint(id value){return [value isKindOfClass:NSString.class]&&[value length]==64&&[value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;}
#endif
static BOOL ExtensionID(id value,NSString *main){
    return Official(main)&&[value isKindOfClass:NSString.class]&&[value length]<256&&[value hasPrefix:[main stringByAppendingString:@"."]]&&[value length]>main.length+1&&
        [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"] invertedSet]].location==NSNotFound;
}
#if LBX_INSTALLED_APPLICATION_BINDING_TESTING
static NSDictionary *TestRegistration;
static NSString *TestInstallationRoot;
static void (^TestFileCallback)(NSString *);
static void (^TestFinalRegistrationCallback)(void);
#endif
static BOOL RootCaller(BOOL testing){
#if LBX_INSTALLED_APPLICATION_BINDING_TESTING
    if(testing)return YES;
#else
    (void)testing;
#endif
    return getuid()==0&&geteuid()==0;
}
static NSDictionary *RawRegistration(BOOL testing,NSString *expected,NSError **error){
#if LBX_INSTALLED_APPLICATION_BINDING_TESTING
    if(testing){NSDictionary *registered;@synchronized(LBXInstalledApplicationBinding.class){registered=TestRegistration;}
        if(!Exact(registered,@[@"bundlePath",@"canonicalExecutablePath"])){Fail(error,3);return nil;}
        NSString *bundle=Normalize(registered[@"bundlePath"]),*executable=Normalize(registered[@"canonicalExecutablePath"]);
        if(!bundle||!executable){Fail(error,3);return nil;}return @{@"bundlePath":bundle,@"canonicalExecutablePath":executable};}
#endif
    (void)testing;if(!Official(expected)){Fail(error,1);return nil;}static dispatch_once_t once;dispatch_once(&once,^{if(!dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices",RTLD_NOW))dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",RTLD_NOW);});
    Class cls=NSClassFromString(@"LSApplicationProxy");SEL lookup=NSSelectorFromString(@"applicationProxyForIdentifier:"),bundleURL=NSSelectorFromString(@"bundleURL"),canonical=NSSelectorFromString(@"canonicalExecutablePath");
    if(![cls respondsToSelector:lookup]){Fail(error,1);return nil;}id proxy=((id(*)(id,SEL,id))objc_msgSend)(cls,lookup,expected);
    id url=[proxy respondsToSelector:bundleURL]?((id(*)(id,SEL))objc_msgSend)(proxy,bundleURL):nil;
    id raw=[proxy respondsToSelector:canonical]?((id(*)(id,SEL))objc_msgSend)(proxy,canonical):nil;
    NSString *bundle=[url isKindOfClass:NSURL.class]&&[url isFileURL]?Normalize([url path]):nil,*executable=Normalize(raw);
    if(!bundle||!executable){Fail(error,3);return nil;}return @{@"bundlePath":bundle,@"canonicalExecutablePath":executable};
}
static NSDictionary *LegacyRegistration(NSDictionary *raw,BOOL testing,NSString *expected,NSError **error){
#if LBX_INSTALLED_APPLICATION_BINDING_TESTING
    if(testing){if(!Official(expected)){Fail(error,1);return nil;}NSData *data=[NSJSONSerialization dataWithJSONObject:raw options:NSJSONWritingSortedKeys error:nil];return @{@"bundlePath":raw[@"bundlePath"],@"bundleIdentifier":expected,@"registrationFingerprint":DataDigest(data),@"executables":NSNull.null};}
    Fail(error,1);return nil;
#else
    (void)testing;if(!Official(expected)){Fail(error,1);return nil;}LBXDrainTarget *target=[[[LBXDarwinDrainBackend alloc] init] resolve:expected error:nil];
    if(![target isKindOfClass:LBXDrainTarget.class]||![target.bundleID isEqual:expected]||![target.bundlePath isEqual:raw[@"bundlePath"]]||
        !Fingerprint(target.fingerprint)||![target.executables isKindOfClass:NSArray.class]||!target.executables.count||target.executables.count>129){Fail(error,3);return nil;}
    for(id path in target.executables)if(!Path(path)){Fail(error,3);return nil;}
    return Snapshot(@{@"bundlePath":target.bundlePath,@"bundleIdentifier":target.bundleID,@"registrationFingerprint":target.fingerprint,@"executables":target.executables});
#endif
}
static BOOL TrustedFD(int fd,BOOL directory,BOOL testing){
    struct stat s;if(fd<0||fstat(fd,&s)||(directory?!S_ISDIR(s.st_mode):!S_ISREG(s.st_mode))||(!directory&&s.st_nlink!=1)||!RBXStorageGateNoACL(fd))return NO;
#if LBX_INSTALLED_APPLICATION_BINDING_TESTING
    if(testing)return (s.st_uid==0||s.st_uid==geteuid())&&(!(s.st_mode&0022)||(directory&&s.st_uid==0&&(s.st_mode&S_ISVTX)));
#endif
    (void)testing;return (s.st_uid==0||s.st_uid==33)&&!(s.st_mode&0022);
}
static NSDictionary *Metadata(int fd,NSString *path,BOOL directory){
    struct stat s;if(fstat(fd,&s))return nil;
    NSMutableDictionary *record=[@{@"path":path,@"device":@(s.st_dev),@"inode":@(s.st_ino),@"owner":@(s.st_uid),@"group":@(s.st_gid),@"mode":@(s.st_mode&07777)} mutableCopy];
    if(!directory)[record addEntriesFromDictionary:@{@"size":@(s.st_size),@"linkCount":@(s.st_nlink),@"mtimeSeconds":@(s.st_mtimespec.tv_sec),@"mtimeNanoseconds":@(s.st_mtimespec.tv_nsec),@"ctimeSeconds":@(s.st_ctimespec.tv_sec),@"ctimeNanoseconds":@(s.st_ctimespec.tv_nsec)}];
    return [record copy];
}
static BOOL Same(int parent,NSString *name,int held){struct stat a,b;return held>=0&&!fstat(held,&a)&&!(parent<0?lstat("/",&b):fstatat(parent,name.fileSystemRepresentation,&b,AT_SYMLINK_NOFOLLOW))&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino;}

@interface LBXBindingObservation:NSObject
@property(nonatomic)BOOL testing;
@property(nonatomic)double deadline;
@property(nonatomic)uint64_t bytes;
@property(nonatomic,strong)NSMutableArray<NSMutableDictionary *> *pins;
- (BOOL)within:(NSError **)error;
- (int)directoryAt:(int)parent name:(NSString *)name path:(NSString *)path error:(NSError **)error;
- (nullable NSDictionary *)fileAt:(int)parent name:(NSString *)name path:(NSString *)path executable:(BOOL)main info:(NSDictionary * _Nullable * _Nullable)info error:(NSError **)error;
- (BOOL)verify:(NSError **)error;
- (BOOL)verifyMetadata:(NSError **)error;
- (nullable NSArray<NSString *> *)children:(int)directory error:(NSError **)error;
@end
@implementation LBXBindingObservation
- (instancetype)init{if((self=[super init])){_pins=[NSMutableArray array];_deadline=Clock()+30;}return self;}
- (void)dealloc{for(NSDictionary *pin in _pins)close([pin[@"fd"] intValue]);}
- (BOOL)within:(NSError **)error{double now=Clock();return isfinite(now)&&now>=0&&now<_deadline?YES:Fail(error,5);}
- (BOOL)current:(NSDictionary *)pin {
    int fd=[pin[@"fd"] intValue];BOOL directory=[pin[@"directory"] boolValue];return TrustedFD(fd,directory,_testing)&&
        Same([pin[@"parent"] intValue],pin[@"name"],fd)&&[Metadata(fd,pin[@"metadata"][@"path"],directory) isEqual:pin[@"metadata"]];
}
- (int)directoryAt:(int)parent name:(NSString *)name path:(NSString *)path error:(NSError **)error {
    if(![self within:error])return -1;int fd=parent<0?open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):openat(parent,name.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(!TrustedFD(fd,YES,_testing)||!Same(parent,name,fd)){if(fd>=0)close(fd);Fail(error,1);return -1;}
    [_pins addObject:[@{@"fd":@(fd),@"parent":@(parent),@"name":name,@"directory":@YES,@"metadata":Metadata(fd,path,YES)} mutableCopy]];return fd;
}
- (NSString *)hash:(NSMutableDictionary *)pin limit:(uint64_t)limit data:(NSData * _Nullable * _Nullable)output error:(NSError **)error {
    int fd=[pin[@"fd"] intValue];uint64_t size=[pin[@"metadata"][@"size"] unsignedLongLongValue];
    if(!size||size>limit||![self current:pin]||lseek(fd,0,SEEK_SET)<0){Fail(error,1);return nil;}
    CC_SHA256_CTX context;CC_SHA256_Init(&context);NSMutableData *data=output?[NSMutableData data]:nil;char buffer[65536];uint64_t total=0;unsigned interruptions=0;
    while(total<size){if(![self within:error])return nil;size_t capacity=(size_t)MIN((uint64_t)sizeof(buffer),size-total);ssize_t count=read(fd,buffer,capacity);
        if(count<0&&errno==EINTR&&++interruptions<=4)continue;if(count<=0){Fail(error,1);return nil;}
        if(_bytes+(uint64_t)count>2ULL*1024*1024*1024){Fail(error,5);return nil;}_bytes+=(uint64_t)count;total+=(uint64_t)count;
        CC_SHA256_Update(&context,buffer,(CC_LONG)count);if(data)[data appendBytes:buffer length:(NSUInteger)count];}
    ssize_t extra;do{extra=read(fd,buffer,1);}while(extra<0&&errno==EINTR&&++interruptions<=4);
    if(extra!=0||![self current:pin]||![self within:error]){Fail(error,4);return nil;}
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(digest,&context);if(output)*output=[data copy];return Hex(digest,sizeof(digest));
}
- (NSDictionary *)fileAt:(int)parent name:(NSString *)name path:(NSString *)path executable:(BOOL)main info:(NSDictionary **)info error:(NSError **)error {
    if(info)*info=nil;if(![self within:error])return nil;int fd=openat(parent,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(!TrustedFD(fd,NO,_testing)||!Same(parent,name,fd)){if(fd>=0)close(fd);Fail(error,1);return nil;}
    NSDictionary *metadata=Metadata(fd,path,NO);
    if(main&&(!([metadata[@"mode"] unsignedIntValue]&0111)||faccessat(parent,name.fileSystemRepresentation,X_OK,0))){close(fd);Fail(error,1);return nil;}
    NSMutableDictionary *pin=[@{@"fd":@(fd),@"parent":@(parent),@"name":name,@"directory":@NO,@"metadata":metadata} mutableCopy];[_pins addObject:pin];
#if LBX_INSTALLED_APPLICATION_BINDING_TESTING
    void(^callback)(NSString *);@synchronized(LBXInstalledApplicationBinding.class){callback=[TestFileCallback copy];}if(callback)callback(path);
#endif
    NSData *bytes=nil;NSString *digest=[self hash:pin limit:info?1024ULL*1024:512ULL*1024*1024 data:info?&bytes:NULL error:error];if(!digest)return nil;
    pin[@"digest"]=digest;pin[@"limit"]=@(info?1024ULL*1024:512ULL*1024*1024);
    if(info){id value=[NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:nil error:nil];if(![value isKindOfClass:NSDictionary.class]){Fail(error,3);return nil;}*info=value;}
    NSMutableDictionary *record=[metadata mutableCopy];record[@"sha256"]=digest;return [record copy];
}
- (NSArray<NSString *> *)children:(int)directory error:(NSError **)error {
    if(![self within:error])return nil;int fd=openat(directory,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *stream=fd>=0?fdopendir(fd):NULL;if(!stream){if(fd>=0)close(fd);Fail(error,1);return nil;}
    NSMutableArray *names=[NSMutableArray array];BOOL valid=YES;for(;;){if(![self within:error]){valid=NO;break;}errno=0;struct dirent *entry=readdir(stream);if(!entry){if(errno)valid=NO;break;}if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
        NSString *name=[[NSString alloc] initWithBytes:entry->d_name length:strlen(entry->d_name) encoding:NSUTF8StringEncoding];if(!Name(name)||names.count>=128){valid=NO;break;}[names addObject:name];}
    closedir(stream);if(!valid){Fail(error,5);return nil;}return [names sortedArrayUsingSelector:@selector(compare:)];
}
- (BOOL)verify:(NSError **)error {
    for(NSMutableDictionary *pin in _pins){if(![self within:error]||![self current:pin])return Fail(error,4);
        if(![pin[@"directory"] boolValue]){NSString *digest=[self hash:pin limit:[pin[@"limit"] unsignedLongLongValue] data:NULL error:error];if(![digest isEqual:pin[@"digest"]])return Fail(error,4);}}
    return [self verifyMetadata:error];
}
- (BOOL)verifyMetadata:(NSError **)error {
    for(NSDictionary *pin in _pins)if(![self current:pin])return Fail(error,4);return [self within:error];
}
@end

@interface LBXInstalledApplicationBinding ()
- (instancetype)initPrivate:(NSDictionary *)snapshot;
+ (instancetype)observeOfficialApplication:(NSString *)expected error:(NSError **)error;
@end
@implementation LBXInstalledApplicationBinding {NSDictionary *_snapshot;}
- (instancetype)initPrivate:(NSDictionary *)snapshot{if((self=[super init]))_snapshot=snapshot;return self;}
+ (instancetype)observeOfficialApplication:(NSString *)expected error:(NSError **)error {
    if(error)*error=nil;BOOL testing=NO;NSString *root=InstalledRoot;
#if LBX_INSTALLED_APPLICATION_BINDING_TESTING
    @synchronized(self){testing=TestRegistration&&TestInstallationRoot;if(testing)root=[TestInstallationRoot copy];}
#endif
    if(!Official(expected)){Fail(error,1);return nil;}
    if(!RootCaller(testing)){Fail(error,2);return nil;}
    @try {
        // This cooperative deadline includes both registration observations;
        // a fixed system call cannot be interrupted, so check on its return.
        LBXBindingObservation *observation=[LBXBindingObservation new];observation.testing=testing;
        NSDictionary *raw=RawRegistration(testing,expected,error);if(!raw)return nil;
        if(![observation within:error])return nil;
        NSString *bundle=raw[@"bundlePath"],*installation=bundle.stringByDeletingLastPathComponent,*identifier=installation.lastPathComponent;
        NSUUID *uuid=[[NSUUID alloc] initWithUUIDString:identifier];
        if(!Path(root)||![installation.stringByDeletingLastPathComponent isEqual:root]||!uuid||[uuid.UUIDString isEqual:@"00000000-0000-0000-0000-000000000000"]||
            !Name(bundle.lastPathComponent)||![bundle.pathExtension isEqual:@"app"]){Fail(error,3);return nil;}
        NSDictionary *legacy=LegacyRegistration(raw,testing,expected,error);if(!legacy)return nil;
        if(![observation within:error])return nil;
        int parent=[observation directoryAt:-1 name:@"/" path:@"/" error:error];if(parent<0)return nil;
        NSMutableArray *ancestors=[NSMutableArray arrayWithObject:observation.pins.lastObject[@"metadata"]];NSString *physical=@"/";
        for(NSString *part in [[bundle componentsSeparatedByString:@"/"] subarrayWithRange:NSMakeRange(1,[bundle componentsSeparatedByString:@"/"].count-1)]){
            physical=[physical isEqual:@"/"]?[@"/" stringByAppendingString:part]:[physical stringByAppendingPathComponent:part];
            parent=[observation directoryAt:parent name:part path:physical error:error];if(parent<0)return nil;[ancestors addObject:observation.pins.lastObject[@"metadata"]];}
        int bundleFD=parent;NSDictionary *info=nil;
        NSDictionary *bundleInfo=[observation fileAt:bundleFD name:@"Info.plist" path:[bundle stringByAppendingPathComponent:@"Info.plist"] executable:NO info:&info error:error];
        NSString *executableName=info[@"CFBundleExecutable"],*executable=Name(executableName)?[bundle stringByAppendingPathComponent:executableName]:nil;
        if(!bundleInfo||![info[@"CFBundleIdentifier"] isEqual:expected]||!executable||![raw[@"canonicalExecutablePath"] isEqual:executable]){Fail(error,3);return nil;}
        NSDictionary *main=[observation fileAt:bundleFD name:executableName path:executable executable:YES info:NULL error:error];if(!main)return nil;
        NSMutableArray *extensions=[NSMutableArray array],*executables=[NSMutableArray arrayWithObject:executable];NSMutableSet *identifiers=[NSMutableSet setWithObject:expected];
        id pluginDirectory=NSNull.null;int plugins=-1;NSArray *children=@[];struct stat pluginStat;
        if(!fstatat(bundleFD,"PlugIns",&pluginStat,AT_SYMLINK_NOFOLLOW)){
            plugins=[observation directoryAt:bundleFD name:@"PlugIns" path:[bundle stringByAppendingPathComponent:@"PlugIns"] error:error];if(plugins<0)return nil;
            pluginDirectory=observation.pins.lastObject[@"metadata"];children=[observation children:plugins error:error];if(!children)return nil;
            for(NSString *child in children){if(![child.pathExtension isEqual:@"appex"]){Fail(error,3);return nil;}
                NSString *extension=[bundle stringByAppendingPathComponent:[@"PlugIns" stringByAppendingPathComponent:child]];
                int extensionFD=[observation directoryAt:plugins name:child path:extension error:error];if(extensionFD<0)return nil;NSDictionary *node=observation.pins.lastObject[@"metadata"],*extensionInfo=nil;
                NSDictionary *plist=[observation fileAt:extensionFD name:@"Info.plist" path:[extension stringByAppendingPathComponent:@"Info.plist"] executable:NO info:&extensionInfo error:error];
                NSString *extensionID=extensionInfo[@"CFBundleIdentifier"],*extensionExecutable=extensionInfo[@"CFBundleExecutable"];
                if(!plist||!ExtensionID(extensionID,expected)||[identifiers containsObject:extensionID]||![extensionInfo[@"NSExtension"] isKindOfClass:NSDictionary.class]||!Name(extensionExecutable)){Fail(error,3);return nil;}
                NSString *path=[extension stringByAppendingPathComponent:extensionExecutable];NSDictionary *binary=[observation fileAt:extensionFD name:extensionExecutable path:path executable:NO info:NULL error:error];if(!binary)return nil;
                [identifiers addObject:extensionID];[executables addObject:path];[extensions addObject:@{@"bundleIdentifier":extensionID,@"bundlePath":extension,@"bundleNode":node,@"infoPlist":plist,@"executableName":extensionExecutable,@"executable":binary}];
            }
        }else if(errno!=ENOENT){Fail(error,1);return nil;}
        if(![observation verify:error])return nil;
        if(plugins>=0){if(![[observation children:plugins error:error] isEqual:children]){Fail(error,4);return nil;}}
        else if(!fstatat(bundleFD,"PlugIns",&pluginStat,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT){Fail(error,4);return nil;}
        NSDictionary *finalRaw=RawRegistration(testing,expected,error);
        if(!finalRaw||![observation within:error])return nil;
        NSDictionary *finalLegacy=LegacyRegistration(finalRaw,testing,expected,error);
        if(!finalLegacy||![observation within:error])return nil;
#if LBX_INSTALLED_APPLICATION_BINDING_TESTING
        void(^finalCallback)(void);@synchronized(self){finalCallback=[TestFinalRegistrationCallback copy];}if(finalCallback)finalCallback();
#endif
        // Relevant inventory must be rechecked after the final external
        // observations. Directory timestamps deliberately do not bind it.
        if(plugins>=0){if(![[observation children:plugins error:error] isEqual:children]){Fail(error,4);return nil;}}
        else if(!fstatat(bundleFD,"PlugIns",&pluginStat,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT){Fail(error,4);return nil;}
        if(![raw isEqual:finalRaw]||![legacy isEqual:finalLegacy]||![observation verifyMetadata:error]){Fail(error,4);return nil;}
        if(!testing&&![legacy[@"executables"] isEqual:executables]){Fail(error,3);return nil;}
        NSDictionary *snapshot=Snapshot(@{@"formatVersion":@1,@"bundleIdentifier":expected,@"installationUUID":uuid.UUIDString.lowercaseString,
            @"bundlePath":bundle,@"registrationFingerprint":legacy[@"registrationFingerprint"],@"ancestors":ancestors,@"bundleInfo":bundleInfo,
            @"mainExecutable":main,@"pluginDirectory":pluginDirectory,@"extensions":extensions,@"runtimeAccepted":@NO});
        if(!snapshot){Fail(error,5);return nil;}
        if(!RootCaller(testing)){Fail(error,2);return nil;}
        if(![observation within:error])return nil;
        return [[self alloc] initPrivate:snapshot];
    }@catch(__unused NSException *exception){Fail(error,1);return nil;}
}
+ (instancetype)observeOfficialInstagram:(NSError **)error {return [self observeOfficialApplication:Instagram error:error];}
+ (instancetype)observeOfficialFacebook:(NSError **)error {return [self observeOfficialApplication:Facebook error:error];}
- (BOOL)matchesCurrentInstallation:(NSError **)error {
    if(error)*error=nil;NSString *expected=_snapshot[@"bundleIdentifier"];
    if(!Official(expected))return Fail(error,3);
    LBXInstalledApplicationBinding *current=[LBXInstalledApplicationBinding observeOfficialApplication:expected error:error];
    if(!current)return NO;if(![current.privateDictionary isEqual:_snapshot])return Fail(error,4);return YES;
}
- (NSDictionary *)privateDictionary{return _snapshot;}
- (NSDictionary *)safeStatus{return @{@"formatVersion":@1,@"extensionCount":@([_snapshot[@"extensions"] count]),@"executableDigestsBound":@YES,@"signatureVerified":@NO,@"wholeBundleIntegrityVerified":@NO,@"runtimeAccepted":@NO};}
- (NSString *)description{return [NSString stringWithFormat:@"<LBXInstalledApplicationBinding %@>",self.safeStatus];}
- (NSString *)debugDescription{return self.description;}
#if LBX_INSTALLED_APPLICATION_BINDING_TESTING
+ (void)testUseRegistration:(NSDictionary *)registration installationRoot:(NSString *)root {@synchronized(self){TestRegistration=registration?Snapshot(registration):nil;TestInstallationRoot=[root isKindOfClass:NSString.class]?[root copy]:nil;}}
+ (void)testAfterOpeningFile:(void (^)(NSString *))callback {@synchronized(self){TestFileCallback=[callback copy];}}
+ (void)testAfterFinalRegistration:(void (^)(void))callback {@synchronized(self){TestFinalRegistrationCallback=[callback copy];}}
#endif
@end
