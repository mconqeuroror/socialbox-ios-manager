#import "LBXNativeApplicationGate.h"
#import "LBXInstalledApplicationBinding.h"
#import "LBXNativeIsolationJournal.h"
#import "LBXDarwinDrainBackend.h"
#import "../../shared/RBXStorageGate.h"
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <dirent.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <sys/file.h>
#include <string.h>

static NSString *const Instagram=@"com.burbn.instagram";
static NSString *const Facebook=@"com.facebook.Facebook";
static BOOL Official(id value){return [value isEqual:Instagram]||[value isEqual:Facebook];}
double LBXNativeApplicationGateClock(void){mach_timebase_info_data_t scale;mach_timebase_info(&scale);return scale.denom?(double)mach_continuous_time()*scale.numer/scale.denom/1e9:NAN;}
static BOOL Fail(NSError **error,NSInteger code){if(error){*error=[NSError errorWithDomain:@"com.socialbox.native-application-gate" code:code userInfo:@{NSLocalizedDescriptionKey:
    code==2?@"Root service execution is required":code==3?@"Captured application binding changed":code==4?@"Application execution cannot be admitted":code==5?@"Application gate deadline exceeded":@"Application gate operation failed"}];}return NO;}
static BOOL Budget(double deadline){double now=LBXNativeApplicationGateClock();return isfinite(deadline)&&isfinite(now)&&deadline>now&&deadline-now<=120;}
static NSDictionary *Immutable(NSDictionary *value){NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];return data&&data.length<=524288?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;}
static NSString *Normalize(id value){if(![value isKindOfClass:NSString.class])return nil;return [value hasPrefix:@"/var/"]?[@"/private" stringByAppendingString:value]:value;}
#if LBX_NATIVE_APPLICATION_GATE_TESTING
static id<LBXDrainBackend> TestBackend;
static NSDictionary *TestRegistration;
static BOOL (^TestBeforeMode)(NSString *,mode_t);
#endif
static BOOL Root(BOOL testing){
#if LBX_NATIVE_APPLICATION_GATE_TESTING
    if(testing)return YES;
#else
    (void)testing;
#endif
    return getuid()==0&&geteuid()==0;
}
static NSDictionary *Registration(BOOL testing,NSString *expected){
#if LBX_NATIVE_APPLICATION_GATE_TESTING
    if(testing){@synchronized(LBXNativeApplicationGate.class){return TestRegistration;}}
#else
    (void)testing;
#endif
    if(!Official(expected))return nil;
    // Recovery starts in a fresh process and does not call the ordinary
    // installed-binding observer, so it must load LaunchServices itself.
    static dispatch_once_t once;dispatch_once(&once,^{if(!dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices",RTLD_NOW))dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",RTLD_NOW);});
    Class cls=NSClassFromString(@"LSApplicationProxy");SEL lookup=NSSelectorFromString(@"applicationProxyForIdentifier:"),bundle=NSSelectorFromString(@"bundleURL"),executable=NSSelectorFromString(@"canonicalExecutablePath");
    if(![cls respondsToSelector:lookup])return nil;id proxy=((id(*)(id,SEL,id))objc_msgSend)(cls,lookup,expected);
    id url=[proxy respondsToSelector:bundle]?((id(*)(id,SEL))objc_msgSend)(proxy,bundle):nil;
    id path=[proxy respondsToSelector:executable]?((id(*)(id,SEL))objc_msgSend)(proxy,executable):nil;
    NSString *a=[url isKindOfClass:NSURL.class]&&[url isFileURL]?Normalize([url path]):nil,*b=Normalize(path);
    return a&&b?@{@"bundlePath":a,@"canonicalExecutablePath":b}:nil;
}
static NSDictionary *Metadata(int fd,BOOL directory){struct stat s;if(fstat(fd,&s))return nil;
    NSMutableDictionary *m=[@{@"device":@(s.st_dev),@"inode":@(s.st_ino),@"owner":@(s.st_uid),@"group":@(s.st_gid),@"mode":@(s.st_mode&07777),@"flags":@(s.st_flags)} mutableCopy];
    if(!directory)[m addEntriesFromDictionary:@{@"size":@(s.st_size),@"linkCount":@(s.st_nlink),@"mtimeSeconds":@(s.st_mtimespec.tv_sec),@"mtimeNanoseconds":@(s.st_mtimespec.tv_nsec),@"ctimeSeconds":@(s.st_ctimespec.tv_sec),@"ctimeNanoseconds":@(s.st_ctimespec.tv_nsec)}];return [m copy];}
@interface LBXGatePin:NSObject
@property(nonatomic)int fd,parent;
@property(nonatomic)BOOL directory,executable;
@property(nonatomic,copy)NSString *path,*name,*digest;
@property(nonatomic,copy)NSDictionary *original,*expected;
@end
@implementation LBXGatePin
- (instancetype)init{if((self=[super init])){_fd=-1;_parent=-1;}return self;}
- (void)dealloc{if(_fd>=0)close(_fd);}
@end
@class LBXCapturedDrainBackend;
@interface LBXNativeApplicationGate ()
@property(nonatomic)BOOL testing,busy,reentered,closureAttempted,restored,invalidated;
@property(nonatomic)double deadline;
@property(nonatomic,strong)NSArray<LBXGatePin *> *pins,*executables;
@property(nonatomic,strong)LBXGatePin *bundlePin,*pluginsPin;
@property(nonatomic,copy)NSArray *pluginNames;
@property(nonatomic,copy)NSDictionary *journal,*registration;
@property(nonatomic,copy)NSString *applicationID;
@property(nonatomic,strong)id<LBXDrainBackend> processBackend;
@property(nonatomic,strong)LBXDrainTarget *target;
@property(nonatomic,strong)LBXNativeIsolationJournal *recoveryJournal;
- (BOOL)verifyContents:(BOOL)contents error:(NSError **)error;
- (BOOL)seal:(NSError **)error;
+ (instancetype)captureOfficialApplication:(NSString *)expected beforeDeadline:(double)deadline error:(NSError **)error;
- (instancetype)initPrivate;
@end
@interface LBXCapturedDrainBackend:NSObject<LBXDrainBackend>
@property(nonatomic,weak)LBXNativeApplicationGate *gate;
@end
@implementation LBXCapturedDrainBackend
- (LBXDrainTarget *)resolve:(NSString *)bundle error:(NSError **)error{LBXNativeApplicationGate *g=self.gate;if(![bundle isEqual:g.applicationID]||![g verifyContents:NO error:error])return nil;
    LBXDrainTarget *r=[LBXDrainTarget new];r.bundleID=g.target.bundleID;r.bundlePath=g.target.bundlePath;r.executables=g.target.executables;r.fingerprint=g.target.fingerprint;return r;}
- (NSArray *)snapshot:(NSError **)error{return [self.gate.processBackend snapshot:error];}
- (RBXProcessIdentityResult)terminate:(RBXObservedProcess)identity{return [self.gate.processBackend terminate:identity];}
- (double)monotonicTime{return [self.gate.processBackend monotonicTime];}
- (BOOL)pause{return [self.gate.processBackend pause];}
@end
static BOOL SameNode(LBXGatePin *pin){struct stat a,b;if(fstat(pin.fd,&a)||
    (pin.parent<0?lstat("/",&b):fstatat(pin.parent,pin.name.fileSystemRepresentation,&b,AT_SYMLINK_NOFOLLOW)))return NO;
    return (pin.directory?S_ISDIR(a.st_mode):S_ISREG(a.st_mode))&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino&&
        a.st_dev==[pin.original[@"device"] longLongValue]&&a.st_ino==[pin.original[@"inode"] unsignedLongLongValue]&&RBXStorageGateNoACL(pin.fd);}
static NSString *Hash(LBXGatePin *pin,double deadline,uint64_t *budget){
    uint64_t length=[pin.expected[@"size"] unsignedLongLongValue],limit=pin.executable?512ULL*1024*1024:1024ULL*1024;
    if(!length||length>limit||*budget<length)return nil;CC_SHA256_CTX hash;CC_SHA256_Init(&hash);char bytes[65536];uint64_t offset=0;unsigned interrupts=0;
    while(offset<length){if(!Budget(deadline))return nil;ssize_t n=pread(pin.fd,bytes,(size_t)MIN(sizeof(bytes),length-offset),(off_t)offset);
        if(n<0&&errno==EINTR&&++interrupts<=4)continue;if(n<=0)return nil;offset+=(uint64_t)n;CC_SHA256_Update(&hash,bytes,(CC_LONG)n);}
    *budget-=length;unsigned char result[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(result,&hash);NSMutableString *hex=[NSMutableString string];for(NSUInteger i=0;i<sizeof(result);i++)[hex appendFormat:@"%02x",result[i]];return hex;
}
static NSArray *Children(int fd){int copy=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *dir=copy>=0?fdopendir(copy):NULL;if(!dir){if(copy>=0)close(copy);return nil;}
    NSMutableArray *names=[NSMutableArray array];BOOL ok=YES;for(;;){errno=0;struct dirent *e=readdir(dir);if(!e){if(errno)ok=NO;break;}if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;
        NSString *name=[[NSString alloc] initWithBytes:e->d_name length:strlen(e->d_name) encoding:NSUTF8StringEncoding];if(!name||names.count>=128){ok=NO;break;}[names addObject:name];}closedir(dir);return ok?[names sortedArrayUsingSelector:@selector(compare:)]:nil;}
@implementation LBXNativeApplicationGate
- (instancetype)initPrivate{return [super init];}
+ (instancetype)captureOfficialApplication:(NSString *)expected beforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;BOOL testing=NO;id<LBXDrainBackend> backend=nil;
#if LBX_NATIVE_APPLICATION_GATE_TESTING
    @synchronized(self){testing=TestBackend&&TestRegistration;backend=TestBackend;}
#endif
    if(!Official(expected)){Fail(error,1);return nil;}
    if(!Root(testing)){Fail(error,2);return nil;}if(!Budget(deadline)){Fail(error,5);return nil;}
    @try {
        LBXInstalledApplicationBinding *binding=[expected isEqual:Instagram]?[LBXInstalledApplicationBinding observeOfficialInstagram:error]:[LBXInstalledApplicationBinding observeOfficialFacebook:error];if(!binding||!Budget(deadline))return nil;
        NSDictionary *snapshot=binding.privateDictionary;if(![snapshot[@"bundleIdentifier"] isEqual:expected]){Fail(error,3);return nil;}NSString *bundle=snapshot[@"bundlePath"],*main=snapshot[@"mainExecutable"][@"path"];
        LBXNativeApplicationGate *gate=[[self alloc] initPrivate];gate.testing=testing;gate.deadline=deadline;gate.applicationID=expected;gate.processBackend=backend?:[LBXDarwinDrainBackend new];
        gate.registration=@{@"bundlePath":bundle,@"canonicalExecutablePath":main};if(![Registration(testing,expected) isEqual:gate.registration]){Fail(error,3);return nil;}
        NSMutableArray *records=[NSMutableArray arrayWithArray:snapshot[@"ancestors"]];
        if(snapshot[@"pluginDirectory"]!=NSNull.null)[records addObject:snapshot[@"pluginDirectory"]];
        for(NSDictionary *extension in snapshot[@"extensions"])[records addObject:extension[@"bundleNode"]];
        NSUInteger directories=records.count;[records addObject:snapshot[@"bundleInfo"]];[records addObject:snapshot[@"mainExecutable"]];
        NSMutableSet *executablePaths=[NSMutableSet setWithObject:main];NSMutableArray *names=[NSMutableArray array];
        for(NSDictionary *extension in snapshot[@"extensions"]){[records addObject:extension[@"infoPlist"]];[records addObject:extension[@"executable"]];[executablePaths addObject:extension[@"executable"][@"path"]];[names addObject:[extension[@"bundlePath"] lastPathComponent]];}
        NSMutableArray *pins=[NSMutableArray array],*executables=[NSMutableArray array];NSMutableDictionary *byPath=[NSMutableDictionary dictionary];
        for(NSUInteger i=0;i<records.count;i++){
            NSDictionary *record=records[i];NSString *path=record[@"path"];BOOL directory=i<directories;LBXGatePin *pin=[LBXGatePin new];pin.path=path;pin.name=path.lastPathComponent;pin.directory=directory;pin.executable=[executablePaths containsObject:path];
            LBXGatePin *parent=byPath[path.stringByDeletingLastPathComponent];if([path isEqual:@"/"])pin.fd=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            else{if(!parent||!parent.directory){Fail(error,3);return nil;}pin.parent=parent.fd;pin.fd=openat(parent.fd,pin.name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|(directory?O_DIRECTORY:O_NONBLOCK));}
            pin.original=Metadata(pin.fd,directory);pin.expected=pin.original;pin.digest=record[@"sha256"];
            if(!pin.original||byPath[path]||!SameNode(pin)){Fail(error,3);return nil;}
            for(NSString *key in pin.original)if(![key isEqual:@"flags"]&&![pin.original[key] isEqual:record[key]]){Fail(error,3);return nil;}
            if(pin.executable){[executables addObject:pin];if([path isEqual:main]&&flock(pin.fd,LOCK_EX|LOCK_NB)){Fail(error,4);return nil;}}
            if([path isEqual:bundle])gate.bundlePin=pin;if([path isEqual:[bundle stringByAppendingPathComponent:@"PlugIns"]])gate.pluginsPin=pin;
            [pins addObject:pin];byPath[path]=pin;
        }
        gate.pins=pins;gate.executables=executables;gate.pluginNames=[names sortedArrayUsingSelector:@selector(compare:)];
        gate.target=[LBXDrainTarget new];gate.target.bundleID=expected;gate.target.bundlePath=bundle;
        gate.target.executables=[executables valueForKey:@"path"];gate.target.fingerprint=snapshot[@"registrationFingerprint"];
        NSMutableArray *originals=[NSMutableArray array];for(LBXGatePin *pin in executables)[originals addObject:@{@"path":pin.path,@"metadata":pin.original}];
        NSMutableArray *nodes=[NSMutableArray array];for(LBXGatePin *pin in pins)[nodes addObject:@{@"path":pin.path,@"metadata":pin.original,@"directory":@(pin.directory),@"executable":@(pin.executable),@"sha256":pin.digest?:NSNull.null}];
        gate.journal=Immutable(@{@"formatVersion":@1,@"binding":snapshot,@"executables":originals,@"nodes":nodes,@"admission":@NO});
        if(!gate.journal||![gate verifyContents:YES error:error])return nil;return gate;
    }@catch(__unused NSException *exception){Fail(error,1);return nil;}
}
+ (instancetype)captureOfficialInstagramBeforeDeadline:(double)deadline error:(NSError **)error {return [self captureOfficialApplication:Instagram beforeDeadline:deadline error:error];}
+ (instancetype)captureOfficialFacebookBeforeDeadline:(double)deadline error:(NSError **)error {return [self captureOfficialApplication:Facebook beforeDeadline:deadline error:error];}
// Reconstruct only from a currently locked root journal, with independently
// checked registration and every captured filesystem identity. No saved object
// can grant execution without later fresh absence and owner authorization.
+ (instancetype)recoverFromJournal:(LBXNativeIsolationJournal *)journal beforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;BOOL testing=NO;id<LBXDrainBackend> backend=nil;
#if LBX_NATIVE_APPLICATION_GATE_TESTING
    @synchronized(self){testing=TestBackend&&TestRegistration;backend=TestBackend;}
#endif
    if(!Root(testing)){Fail(error,2);return nil;}if(!Budget(deadline)){Fail(error,5);return nil;}
    @try {
        if(object_getClass(journal)!=LBXNativeIsolationJournal.class){Fail(error,3);return nil;}
        NSDictionary *envelope=[journal validatedCurrentRecord:error],*saved=envelope[@"payload"][@"applicationGate"];
        if(![saved isKindOfClass:NSDictionary.class]||saved.count!=5||![saved[@"formatVersion"] isEqual:@1]||![saved[@"admission"] isEqual:@NO]){Fail(error,3);return nil;}
        NSDictionary *snapshot=saved[@"binding"];NSArray *nodes=saved[@"nodes"],*originals=saved[@"executables"];
        if(![snapshot isKindOfClass:NSDictionary.class]||!Official(snapshot[@"bundleIdentifier"])||![nodes isKindOfClass:NSArray.class]||nodes.count>520||![originals isKindOfClass:NSArray.class]){Fail(error,3);return nil;}
        NSString *expected=snapshot[@"bundleIdentifier"],*bundle=snapshot[@"bundlePath"],*main=snapshot[@"mainExecutable"][@"path"];
        NSDictionary *registration=@{@"bundlePath":bundle,@"canonicalExecutablePath":main};
        if(![Registration(testing,expected) isEqual:registration]||![bundle.pathExtension isEqual:@"app"]||![[main stringByDeletingLastPathComponent] isEqual:bundle]){Fail(error,3);return nil;}
        NSArray *ancestors=snapshot[@"ancestors"],*extensions=snapshot[@"extensions"];
        if(![ancestors isKindOfClass:NSArray.class]||![extensions isKindOfClass:NSArray.class]||extensions.count>128){Fail(error,3);return nil;}
        NSArray *parts=[bundle componentsSeparatedByString:@"/"];if(parts.count!=ancestors.count){Fail(error,3);return nil;}
        NSString *path=@"/";for(NSUInteger i=0;i<parts.count;i++){if(i)path=[path stringByAppendingPathComponent:parts[i]];if(![ancestors[i][@"path"] isEqual:path]){Fail(error,3);return nil;}}
        NSMutableArray *records=[ancestors mutableCopy],*names=[NSMutableArray array];NSString *plugins=[bundle stringByAppendingPathComponent:@"PlugIns"];
        NSDictionary *plugin=snapshot[@"pluginDirectory"];
        if((id)plugin!=NSNull.null){if(![plugin[@"path"] isEqual:plugins]){Fail(error,3);return nil;}[records addObject:plugin];}
        else if(extensions.count){Fail(error,3);return nil;}
        NSMutableSet *executablePaths=[NSMutableSet setWithObject:main];
        for(NSDictionary *extension in extensions){NSString *p=extension[@"bundlePath"],*binary=extension[@"executable"][@"path"];
            if(![p.stringByDeletingLastPathComponent isEqual:plugins]||![p.pathExtension isEqual:@"appex"]||![extension[@"bundleNode"][@"path"] isEqual:p]||
               ![extension[@"infoPlist"][@"path"] isEqual:[p stringByAppendingPathComponent:@"Info.plist"]]||![binary.stringByDeletingLastPathComponent isEqual:p]||[executablePaths containsObject:binary]||[names containsObject:p.lastPathComponent]){Fail(error,3);return nil;}
            [records addObject:extension[@"bundleNode"]];[executablePaths addObject:binary];[names addObject:p.lastPathComponent];}
        NSUInteger directories=records.count;if(![snapshot[@"bundleInfo"][@"path"] isEqual:[bundle stringByAppendingPathComponent:@"Info.plist"]]){Fail(error,3);return nil;}
        [records addObject:snapshot[@"bundleInfo"]];[records addObject:snapshot[@"mainExecutable"]];
        for(NSDictionary *extension in extensions){[records addObject:extension[@"infoPlist"]];[records addObject:extension[@"executable"]];}
        if(nodes.count!=records.count||originals.count!=executablePaths.count){Fail(error,3);return nil;}
        LBXNativeApplicationGate *gate=[[self alloc] initPrivate];gate.testing=testing;gate.deadline=deadline;gate.applicationID=expected;gate.registration=registration;gate.processBackend=backend?:[LBXDarwinDrainBackend new];
        NSMutableArray *pins=[NSMutableArray array],*executables=[NSMutableArray array],*capturedOriginals=[NSMutableArray array];NSMutableDictionary *byPath=[NSMutableDictionary dictionary];
        for(NSUInteger i=0;i<records.count;i++){
            NSDictionary *record=records[i],*node=nodes[i],*metadata=node[@"metadata"];NSString *p=record[@"path"];BOOL directory=i<directories,executable=[executablePaths containsObject:p];
            if(![node isKindOfClass:NSDictionary.class]||node.count!=5||![node[@"path"] isEqual:p]||![node[@"directory"] isEqual:@(directory)]||![node[@"executable"] isEqual:@(executable)]||![node[@"sha256"] isEqual:record[@"sha256"]?:NSNull.null]||![metadata isKindOfClass:NSDictionary.class]){Fail(error,3);return nil;}
            LBXGatePin *pin=[LBXGatePin new];pin.path=p;pin.name=p.lastPathComponent;pin.directory=directory;pin.executable=executable;pin.original=metadata;pin.digest=record[@"sha256"];
            LBXGatePin *parent=byPath[p.stringByDeletingLastPathComponent];if([p isEqual:@"/"])pin.fd=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            else{if(!parent||!parent.directory){Fail(error,3);return nil;}pin.parent=parent.fd;pin.fd=openat(parent.fd,pin.name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|(directory?O_DIRECTORY:O_NONBLOCK));}
            NSDictionary *actual=Metadata(pin.fd,directory);pin.expected=actual;
            if(!actual||metadata.count!=actual.count||byPath[p]||!SameNode(pin)){Fail(error,3);return nil;}
            for(NSString *key in actual){
                if(!metadata[key]||(![key isEqual:@"flags"]&&![metadata[key] isEqual:record[key]])){Fail(error,3);return nil;}
                if(executable&&[@[@"ctimeSeconds",@"ctimeNanoseconds"] containsObject:key])continue;
                if(executable&&[key isEqual:@"mode"]){unsigned original=[metadata[key] unsignedIntValue],now=[actual[key] unsignedIntValue];if(now!=original&&now!=(original&~0111)){Fail(error,3);return nil;}}
                else if(![actual[key] isEqual:metadata[key]]){Fail(error,3);return nil;}
            }
            if(executable){[executables addObject:pin];[capturedOriginals addObject:@{@"path":p,@"metadata":metadata}];if([p isEqual:main]&&(!([metadata[@"mode"] unsignedIntValue]&0111)||flock(pin.fd,LOCK_EX|LOCK_NB))){Fail(error,4);return nil;}}
            if([p isEqual:bundle])gate.bundlePin=pin;if([p isEqual:plugins])gate.pluginsPin=pin;[pins addObject:pin];byPath[p]=pin;
        }
        if(![capturedOriginals isEqual:originals]){Fail(error,3);return nil;}
        gate.pins=pins;gate.executables=executables;gate.pluginNames=[names sortedArrayUsingSelector:@selector(compare:)];gate.target=[LBXDrainTarget new];gate.target.bundleID=expected;gate.target.bundlePath=bundle;gate.target.executables=[executables valueForKey:@"path"];gate.target.fingerprint=snapshot[@"registrationFingerprint"];
        gate.journal=Immutable(saved);gate.recoveryJournal=journal;gate.closureAttempted=YES;
        if(!gate.journal||![gate verifyContents:YES error:error]||![[journal validatedCurrentRecord:error] isEqual:envelope])return nil;return gate;
    }@catch(__unused NSException *exception){Fail(error,3);return nil;}
}
- (BOOL)invalidate:(NSError **)error{_invalidated=YES;return Fail(error,3);}
- (BOOL)verifyContents:(BOOL)contents error:(NSError **)error {
    if(!Root(_testing))return Fail(error,2);if(!Budget(_deadline))return Fail(error,5);
    if(_invalidated||_reentered||!Official(_applicationID)||![Registration(_testing,_applicationID) isEqual:_registration])return [self invalidate:error];
    if(_recoveryJournal&&![[[_recoveryJournal validatedCurrentRecord:error] objectForKey:@"payload"][@"applicationGate"] isEqual:_journal])return [self invalidate:error];
    uint64_t budget=2ULL*1024*1024*1024;
    for(LBXGatePin *pin in _pins){if(!Budget(_deadline)||!SameNode(pin)||![Metadata(pin.fd,pin.directory) isEqual:pin.expected])return [self invalidate:error];
        if(contents&&!pin.directory){if(![Hash(pin,_deadline,&budget) isEqual:pin.digest]||!SameNode(pin)||![Metadata(pin.fd,NO) isEqual:pin.expected])return [self invalidate:error];}}
    if(_pluginsPin){if(![Children(_pluginsPin.fd) isEqual:_pluginNames])return [self invalidate:error];}
    else{struct stat s;if(!fstatat(_bundlePin.fd,"PlugIns",&s,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT)return [self invalidate:error];}
    return Official(_applicationID)&&[Registration(_testing,_applicationID) isEqual:_registration]&&Budget(_deadline)?YES:[self invalidate:error];
}
- (BOOL)setMode:(mode_t)mode pin:(LBXGatePin *)pin {
#if LBX_NATIVE_APPLICATION_GATE_TESTING
    BOOL(^callback)(NSString *,mode_t);@synchronized(LBXNativeApplicationGate.class){callback=[TestBeforeMode copy];}if(callback&&!callback(pin.path,mode))return NO;
#endif
    NSDictionary *before=Metadata(pin.fd,NO);if(!SameNode(pin)||![before isEqual:pin.expected]){_invalidated=YES;return NO;}
    if(fchmod(pin.fd,mode))return NO;
    NSDictionary *after=Metadata(pin.fd,NO);if(!after)return NO;
    for(NSString *key in before)if(![@[@"mode",@"ctimeSeconds",@"ctimeNanoseconds"] containsObject:key]&&![before[key] isEqual:after[key]])return NO;
    if([after[@"mode"] unsignedIntValue]!=mode)return NO;pin.expected=after;
    return fsync(pin.fd)==0&&SameNode(pin)&&[Metadata(pin.fd,NO) isEqual:after];
}
- (BOOL)seal:(NSError **)error {
    _closureAttempted=YES;_restored=NO;BOOL ok=YES;
    // Every captured inode gets a closure attempt. Failure never transfers
    // authority to a replacement path and never prevents later attempts.
    for(LBXGatePin *pin in _executables){@try {
        struct stat s;if(fstat(pin.fd,&s)||!S_ISREG(s.st_mode)||s.st_dev!=[pin.original[@"device"] longLongValue]||s.st_ino!=[pin.original[@"inode"] unsignedLongLongValue]){ok=NO;continue;}
        // On drift, only remove currently present execute bits. Never restore
        // read/write permissions while attempting emergency closure.
        mode_t mode=(s.st_mode&07777)&~0111;
        if(!SameNode(pin)||![Metadata(pin.fd,NO) isEqual:pin.expected])_invalidated=YES;
#if LBX_NATIVE_APPLICATION_GATE_TESTING
        BOOL(^callback)(NSString *,mode_t);@synchronized(LBXNativeApplicationGate.class){callback=[TestBeforeMode copy];}if(callback&&!callback(pin.path,mode)){ok=NO;continue;}
#endif
        if(fchmod(pin.fd,mode)||fsync(pin.fd)){ok=NO;continue;}NSDictionary *after=Metadata(pin.fd,NO);
        if(!after||[after[@"mode"] unsignedIntValue]!=mode){ok=NO;continue;}
        NSDictionary *before=pin.expected;BOOL unchanged=YES;
        for(NSString *key in before)if(![@[@"mode",@"ctimeSeconds",@"ctimeNanoseconds"] containsObject:key]&&![before[key] isEqual:after[key]])unchanged=NO;
        if(mode!=([pin.original[@"mode"] unsignedIntValue]&~0111))unchanged=NO;
        if(unchanged&&SameNode(pin))pin.expected=after;else{_invalidated=YES;ok=NO;}
    }@catch(__unused NSException *exception){ok=NO;}}
    return ok?YES:Fail(error,4);
}
- (BOOL)begin:(double)deadline error:(NSError **)error{if(_busy){_reentered=YES;return Fail(error,4);}if(!Root(_testing))return Fail(error,2);if(!Budget(deadline))return Fail(error,5);_busy=YES;_reentered=NO;_deadline=deadline;return YES;}
- (BOOL)closeExecutionBeforeDeadline:(double)deadline error:(NSError **)error {@synchronized(self){if(error)*error=nil;if(![self begin:deadline error:error])return NO;BOOL result=NO;
    @try{BOOL current=[self verifyContents:YES error:error];BOOL closed=[self seal:error];result=current&&closed&&[self verifyContents:NO error:error];}
    @catch(__unused NSException *exception){[self seal:nil];Fail(error,4);}
    @finally{_busy=NO;}return result;}}
- (BOOL)observeAbsence:(BOOL)terminate error:(NSError **)error {
    double remaining=_deadline-LBXNativeApplicationGateClock();if(remaining<.1)return Fail(error,5);
    LBXCapturedDrainBackend *backend=[LBXCapturedDrainBackend new];backend.gate=self;
    NSDictionary *receipt=LBXDrainApplication(backend,_applicationID,NSUUID.UUID.UUIDString,MIN(5.0,remaining),terminate);
    if(![receipt[@"status"] isEqual:@"observed_absent"]){
        // Only the drain's fixed reason labels may leave this layer. The
        // private receipt also contains process identities and is not exported.
        NSArray *reasons=@[@"invalid_request",@"clock_failed",@"registration_failed",@"deadline_exceeded",@"registration_changed",@"enumeration_failed",@"invalid_process_snapshot",@"unregistered_app_process",@"processes_present",@"relaunch_detected",@"process_identity_changed",@"termination_denied",@"pause_failed",@"observation_limit",@"backend_exception"];
        NSString *reason=[reasons containsObject:receipt[@"reason"]]?receipt[@"reason"]:@"unknown";
        if(error)*error=[NSError errorWithDomain:@"com.socialbox.native-application-gate" code:4 userInfo:@{NSLocalizedDescriptionKey:@"Application process drain could not be verified",@"stage":[@"process-drain:" stringByAppendingString:reason]}];return NO;
    }
    return [self verifyContents:NO error:error];
}
- (BOOL)closeAndDrainBeforeDeadline:(double)deadline error:(NSError **)error {@synchronized(self){if(error)*error=nil;if(![self begin:deadline error:error])return NO;BOOL result=NO;
    @try{BOOL current=[self verifyContents:YES error:error];BOOL closed=[self seal:error];result=current&&closed&&[self verifyContents:NO error:error]&&[self observeAbsence:YES error:error];}
    @catch(__unused NSException *exception){[self seal:nil];Fail(error,4);}
    @finally{_busy=NO;}return result;}}
- (BOOL)restoreExecutionBeforeDeadline:(double)deadline authorization:(BOOL (^)(void))authorization error:(NSError **)error {@synchronized(self){if(error)*error=nil;if(![self begin:deadline error:error])return NO;BOOL result=NO;
    @try{
        if(_closureAttempted&&!_restored&&authorization&&[self verifyContents:YES error:error]&&[self observeAbsence:NO error:error]&&authorization()&&[self verifyContents:NO error:error]){
            // Restore the main application last. A process may still start during
            // admission; any later failure requires a fresh drain before storage work.
            NSMutableArray *order=[_executables mutableCopy];if(order.count>1){id main=order.firstObject;[order removeObjectAtIndex:0];[order addObject:main];}
            result=YES;for(LBXGatePin *pin in order){if(!authorization()||![self verifyContents:NO error:error]||![self setMode:[pin.original[@"mode"] unsignedIntValue] pin:pin]||!authorization()||![self verifyContents:NO error:error]){result=NO;break;}}
            if(result)_restored=YES;
        }
    }@catch(__unused NSException *exception){result=NO;}
    @finally{if(!result){[self seal:nil];Fail(error,4);}_busy=NO;}return result;}}
#if LBX_PRIVATE_GATE_ABORT_RECOVERY
static BOOL ProbeAbortRecord(NSDictionary *envelope,NSDictionary *binding){
    NSDictionary *p=envelope[@"payload"];
    return [p isKindOfClass:NSDictionary.class]&&p.count==9&&[p[@"formatVersion"] isEqual:@1]&&
        [p[@"component"] isEqual:@"native-application-gate-probe"]&&[p[@"applicationGate"] isEqual:binding]&&
        [p[@"acceptance"] isEqual:@"FAIL"]&&[p[@"spawnErrno"] isEqual:@(-1)]&&
        [p[@"probeAccountFileContentsRead"] isEqual:@NO]&&[p[@"storagePermissionsChanged"] isEqual:@NO]&&[p[@"selectionChanged"] isEqual:@NO]&&
        [@[@"prepared",@"abort-restoring-original-code",@"aborted-original-code-restored"] containsObject:p[@"phase"]];
}
static BOOL UnstartedProbe(NSDictionary *envelope,NSDictionary *binding){return ProbeAbortRecord(envelope,binding)&&![envelope[@"payload"][@"phase"] isEqual:@"aborted-original-code-restored"];}
- (BOOL)restoreOriginalExecutionForUnstartedProbe:(LBXNativeIsolationJournal *)journal beforeDeadline:(double)deadline authorization:(BOOL (^)(void))authorization error:(NSError **)error {@synchronized(self){
    if(error)*error=nil;if(![self begin:deadline error:error])return NO;BOOL result=NO;
    @try {
        NSDictionary *previous=[journal validatedCurrentRecord:error];
        BOOL owner=journal==_recoveryJournal&&object_getClass(journal)==LBXNativeIsolationJournal.class&&authorization;
        if(owner&&ProbeAbortRecord(previous,_journal)&&[previous[@"payload"][@"phase"] isEqual:@"aborted-original-code-restored"]&&
           [self verifyContents:YES error:error]&&authorization()&&[[journal validatedCurrentRecord:error] isEqual:previous]&&[self verifyContents:NO error:error]){
            result=YES;for(LBXGatePin *pin in _executables)if(![pin.expected[@"mode"] isEqual:pin.original[@"mode"]])result=NO;
            if(result)_restored=YES;
        }else if(owner&&_closureAttempted&&!_restored&&UnstartedProbe(previous,_journal)&&[self verifyContents:YES error:error]&&authorization()&&[self verifyContents:NO error:error]){
            NSMutableDictionary *intent=[previous[@"payload"] mutableCopy];intent[@"phase"]=@"abort-restoring-original-code";
            if([journal compareRecord:previous replaceWith:intent error:error]){
                NSDictionary *permit=[journal validatedCurrentRecord:error];
                BOOL(^allowed)(void)=^BOOL{return UnstartedProbe(permit,self.journal)&&[[journal validatedCurrentRecord:nil] isEqual:permit]&&authorization()&&[self verifyContents:NO error:nil];};
                NSMutableArray *order=[_executables mutableCopy];if(order.count>1){id main=order.firstObject;[order removeObjectAtIndex:0];[order addObject:main];}
                result=allowed();for(LBXGatePin *pin in order){if(!result||!allowed()||![self setMode:[pin.original[@"mode"] unsignedIntValue] pin:pin]||!allowed()){result=NO;break;}}
                if(result)result=[self verifyContents:YES error:error]&&allowed();
                if(result){NSMutableDictionary *finished=[permit[@"payload"] mutableCopy];finished[@"phase"]=@"aborted-original-code-restored";
                    result=[journal compareRecord:permit replaceWith:finished error:error]&&[[journal validatedCurrentRecord:error][@"payload"] isEqual:finished]&&[self verifyContents:NO error:error];}
                if(result)_restored=YES;
            }
        }
    }@catch(__unused NSException *exception){result=NO;}
    @finally{if(!result){[self seal:nil];if(!error||!*error)Fail(error,4);}_busy=NO;}return result;
}}
#endif
- (NSDictionary *)privateJournalRecord{return _journal;}
- (NSDictionary *)safeStatus{@synchronized(self){return @{@"formatVersion":@1,@"executableCount":@(_executables.count),@"closureAttempted":@(_closureAttempted),@"executionRestored":@(_restored),@"bindingInvalidated":@(_invalidated),@"runtimeAccepted":@NO,@"journalRecoverySupported":@YES,@"durableOwnerIntegrated":@NO};}}
- (NSString *)description{return [NSString stringWithFormat:@"<LBXNativeApplicationGate %@>",self.safeStatus];}
- (NSString *)debugDescription{return self.description;}
// Releasing a gate never opens code. Recovery requires its durable root journal.
#if LBX_NATIVE_APPLICATION_GATE_TESTING
+ (void)testUseBackend:(id<LBXDrainBackend>)backend registration:(NSDictionary *)registration{@synchronized(self){TestBackend=backend;TestRegistration=registration?Immutable(registration):nil;}}
+ (void)testBeforeModeChange:(BOOL (^)(NSString *,mode_t))callback{@synchronized(self){TestBeforeMode=[callback copy];}}
#endif
@end
