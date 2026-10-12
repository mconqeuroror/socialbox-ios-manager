#import "LBXNativeStorageInventory.h"
#import "LBXInstalledApplicationBinding.h"
#import "LBXNativeIsolationJournal.h"
#import "LBXSocialBoxProduct.h"
#import "../../shared/RBXStorageGate.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <string.h>

static NSString *const IG=@"com.burbn.instagram";
static NSString *const FB=@"com.facebook.Facebook";
static BOOL Official(id x){return [x isEqual:IG]||[x isEqual:FB];}
static NSString *MainApp(NSDictionary *installation){
    id value=installation[@"bundleIdentifier"];
    if(Official(value))return value;
    return value==nil?IG:nil;
}
static NSString *const Store=@LBX_SOCIALBOX_PROFILE_STORE;
static NSString *const DataBase=@"/private/var/mobile/Containers/Data/Application";
static NSString *const GroupBase=@"/private/var/mobile/Containers/Shared/AppGroup";
static BOOL Fail(NSError **error,NSInteger code) {
    if(error)*error=[NSError errorWithDomain:@"com.socialbox.native-storage-inventory" code:code userInfo:@{NSLocalizedDescriptionKey:
        code==2?@"Root observation required":code==3?@"Registration or storage layout is incomplete":code==4?@"Storage changed during observation":code==5?@"Observation limit exceeded":@"Storage observation refused"}];
    return NO;
}
static BOOL Stage(NSError **error,NSInteger code,NSString *stage) {
    Fail(error,code);if(error&&*error){NSMutableDictionary *info=[(*error).userInfo mutableCopy];info[@"stage"]=stage;*error=[NSError errorWithDomain:(*error).domain code:code userInfo:info];}return NO;
}
static double Clock(void){mach_timebase_info_data_t t;mach_timebase_info(&t);return t.denom?(double)mach_continuous_time()*t.numer/t.denom/1e9:NAN;}
static BOOL Name(id x){return [x isKindOfClass:NSString.class]&&[x length]&&[x lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<256&&![x containsString:@"/"]&&![x containsString:@"\\"]&&![x isEqual:@"."]&&![x isEqual:@".."]&&[x rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound;}
static NSString *Path(id x){
    if(![x isKindOfClass:NSString.class])return nil;
    NSString *s=[x hasPrefix:@"/var/"]?[@"/private" stringByAppendingString:x]:x;
    if(![s hasPrefix:@"/"]||[s lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>=4096)return nil;
    NSArray *parts=[s componentsSeparatedByString:@"/"];for(NSUInteger i=1;i<parts.count;i++)if(!Name(parts[i]))return nil;
    return [s copy];
}
static BOOL Identifier(id x){return Name(x)&&[x rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"] invertedSet]].location==NSNotFound;}
static BOOL CID(NSString *x){if(!Name(x)||x.length>19)return NO;long long n=x.longLongValue;return n>=0&&[x isEqual:[NSString stringWithFormat:@"%lld",n]];}
static NSDictionary *Freeze(id x){if(![NSJSONSerialization isValidJSONObject:x])return nil;NSData *d=[NSJSONSerialization dataWithJSONObject:x options:NSJSONWritingSortedKeys error:nil];return d.length&&d.length<=8*1024*1024?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:nil;}
static NSString *Kind(mode_t m){return S_ISDIR(m)?@"directory":S_ISREG(m)?@"regular":S_ISLNK(m)?@"symlink":@"other";}
static NSDictionary *Node(struct stat s,NSString *path){
    NSMutableDictionary *node=[@{@"path":path,@"type":Kind(s.st_mode),@"device":@(s.st_dev),@"inode":@(s.st_ino),@"uid":@(s.st_uid),@"gid":@(s.st_gid),@"mode":@(s.st_mode&07777),@"flags":@(s.st_flags)} mutableCopy];
    // Unrelated installations can alter an ancestor directory's link count.
    // Relevant membership is separately captured and compared with readdir.
    if(!S_ISDIR(s.st_mode))node[@"linkCount"]=@(s.st_nlink);return [node copy];
}

// Every directory is opened from a held parent with O_NOFOLLOW. Leaf files are
// lstat-only: neither plist nor any other account-owned file is read or hashed.
@interface LBXStorageScan:NSObject
@property(nonatomic)BOOL testing;
@property(nonatomic)double deadline;
@property(nonatomic,strong)NSMutableArray *pins;
@property(nonatomic,strong)NSMutableDictionary *pinsByPath;
@property(nonatomic,strong)NSMutableArray *lists;
@property(nonatomic)NSUInteger entries;
- (int)openPath:(NSString *)path error:(NSError **)error;
- (int)openChild:(NSString *)name parent:(int)parent path:(NSString *)path error:(NSError **)error;
- (nullable NSArray *)list:(int)fd path:(NSString *)path error:(NSError **)error;
- (BOOL)verify:(NSError **)error;
- (BOOL)verifyPin:(NSDictionary *)pin error:(NSError **)error;
@end
@implementation LBXStorageScan
- (instancetype)init {if((self=[super init])){_pins=[NSMutableArray array];_pinsByPath=[NSMutableDictionary dictionary];_lists=[NSMutableArray array];_deadline=Clock()+30;}return self;}
- (void)dealloc {for(NSDictionary *pin in _pins)close([pin[@"fd"] intValue]);}
- (BOOL)within:(NSError **)error {double t=Clock();return isfinite(t)&&t<_deadline?YES:Fail(error,5);}
- (BOOL)trusted:(int)fd {
    struct stat s;if(fstat(fd,&s)||!S_ISDIR(s.st_mode)||!RBXStorageGateNoACL(fd))return NO;
    BOOL owner=s.st_uid==0||s.st_uid==501||s.st_uid==33;
    if(_testing)owner=owner||s.st_uid==geteuid();
    // System ancestors can be traversable by mobile; never accept writable
    // unrelated users. A host fixture may cross the normal root sticky /tmp.
    return owner&&(!(s.st_mode&0022)||(_testing&&s.st_uid==0&&(s.st_mode&S_ISVTX)));
}
- (int)openChild:(NSString *)name parent:(int)parent path:(NSString *)path error:(NSError **)error {
    // Reuse only the same canonical path through the same held parent. An FD
    // is not authority merely because it is cached: revalidate the complete
    // original pin and current parent entry every time it is reused.
    NSDictionary *existing=_pinsByPath[path];if(existing){
        if([existing[@"parent"] intValue]!=parent||![existing[@"name"] isEqual:name]||![self verifyPin:existing error:error]){Fail(error,4);return -1;}
        return [existing[@"fd"] intValue];
    }
    if(![self within:error]||_pins.count>=8192){Fail(error,5);return -1;}
    int fd=parent<0?open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):openat(parent,name.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    struct stat s,p;if(fd<0||![self trusted:fd]||fstat(fd,&s)||(parent<0?lstat("/",&p):fstatat(parent,name.fileSystemRepresentation,&p,AT_SYMLINK_NOFOLLOW))||s.st_dev!=p.st_dev||s.st_ino!=p.st_ino){if(fd>=0)close(fd);Fail(error,1);return -1;}
    NSDictionary *pin=@{@"fd":@(fd),@"parent":@(parent),@"name":name,@"node":Node(s,path)};[_pins addObject:pin];_pinsByPath[path]=pin;return fd;
}
- (int)openPath:(NSString *)path error:(NSError **)error {
    int fd=[self openChild:@"/" parent:-1 path:@"/" error:error];NSString *current=@"/";
    for(NSString *name in [path.pathComponents subarrayWithRange:NSMakeRange(1,path.pathComponents.count-1)]){if(fd<0)return -1;current=[current stringByAppendingPathComponent:name];fd=[self openChild:name parent:fd path:current error:error];}return fd;
}
- (NSArray *)rawList:(int)fd path:(NSString *)path error:(NSError **)error {
    int copy=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *stream=copy<0?NULL:fdopendir(copy);if(!stream){if(copy>=0)close(copy);Fail(error,1);return nil;}
    NSMutableArray *rows=[NSMutableArray array];BOOL good=YES;
    for(;;){if(![self within:error]){good=NO;break;}errno=0;struct dirent *entry=readdir(stream);if(!entry){if(errno)good=NO;break;}
        if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
        NSString *name=[[NSString alloc] initWithBytes:entry->d_name length:strlen(entry->d_name) encoding:NSUTF8StringEncoding];struct stat s;
        if(!Name(name)||rows.count>=4096||fstatat(fd,name.fileSystemRepresentation,&s,AT_SYMLINK_NOFOLLOW)){good=NO;break;}
        NSMutableDictionary *row=[Node(s,[path stringByAppendingPathComponent:name]) mutableCopy];row[@"name"]=name;[rows addObject:row];
    }
    closedir(stream);if(!good){Fail(error,1);return nil;}
    return [rows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"name"] compare:b[@"name"]];}];
}
- (NSArray *)list:(int)fd path:(NSString *)path error:(NSError **)error {
    NSArray *rows=[self rawList:fd path:path error:error];if(!rows)return nil;_entries+=rows.count;if(_entries>16384){Fail(error,5);return nil;}
    [_lists addObject:@{@"fd":@(fd),@"path":path,@"rows":rows}];return rows;
}
- (BOOL)verifyPin:(NSDictionary *)pin error:(NSError **)error {
    int fd=[pin[@"fd"] intValue],parent=[pin[@"parent"] intValue];struct stat s,p;NSString *path=pin[@"node"][@"path"];
    if(![self within:error]||![self trusted:fd]||fstat(fd,&s)||(parent<0?lstat("/",&p):fstatat(parent,[pin[@"name"] fileSystemRepresentation],&p,AT_SYMLINK_NOFOLLOW))||
       ![Node(s,path) isEqual:pin[@"node"]]||![Node(p,path) isEqual:pin[@"node"]])return Fail(error,4);
    return YES;
}
- (BOOL)verify:(NSError **)error {
    for(NSDictionary *pin in _pins)if(![self verifyPin:pin error:error])return NO;
    for(NSDictionary *list in _lists)if(![[self rawList:[list[@"fd"] intValue] path:list[@"path"] error:error] isEqual:list[@"rows"]])return Fail(error,4);
    return [self within:error];
}
@end

static NSDictionary *Find(NSArray *rows,NSString *name){for(NSDictionary *row in rows)if([row[@"name"] isEqual:name])return row;return nil;}
static NSDictionary *Inspect(LBXStorageScan *scan,NSString *path,NSError **error) {
    int root=[scan openPath:path error:error];if(root<0)return nil;struct stat s;if(fstat(root,&s))return nil;
    NSArray *top=[scan list:root path:path error:error];if(!top)return nil;
    NSMutableDictionary *result=[@{@"root":Node(s,path),@"rootEntries":top,@"libraryEntries":@[],@"profileStores":@[],@"layoutIssues":@[],@"defaultStatePlacement":@"UNRESOLVED",@"accountFileContentsRead":@NO} mutableCopy];
    NSMutableArray *stores=[NSMutableArray array],*issues=[NSMutableArray array];
    int library=-1;NSString *libraryPath=[path stringByAppendingPathComponent:@"Library"];NSArray *libraryRows=@[];
    NSDictionary *libraryNode=Find(top,@"Library");
    if(libraryNode){if(![libraryNode[@"type"] isEqual:@"directory"]){Fail(error,3);return nil;}library=[scan openChild:@"Library" parent:root path:libraryPath error:error];if(library<0)return nil;libraryRows=[scan list:library path:libraryPath error:error];if(!libraryRows)return nil;result[@"libraryEntries"]=libraryRows;}
    for(NSDictionary *placement in @[@{@"rows":top,@"fd":@(root),@"path":path},@{@"rows":libraryRows,@"fd":@(library),@"path":libraryPath}]){
        NSDictionary *entry=Find(placement[@"rows"],Store);if(!entry)continue;
        if(![entry[@"type"] isEqual:@"directory"]){Fail(error,3);return nil;}
        NSString *storePath=[placement[@"path"] stringByAppendingPathComponent:Store];int fd=[scan openChild:Store parent:[placement[@"fd"] intValue] path:storePath error:error];if(fd<0)return nil;
        NSArray *rows=[scan list:fd path:storePath error:error];if(!rows)return nil;NSMutableArray *profiles=[NSMutableArray array],*metadata=[NSMutableArray array];
        for(NSDictionary *row in rows){NSString *name=row[@"name"];
            if(CID(name)){if(![row[@"type"] isEqual:@"directory"]){Fail(error,3);return nil;}int child=[scan openChild:name parent:fd path:row[@"path"] error:error];if(child<0)return nil;[profiles addObject:row];}
            else {[metadata addObject:row];[issues addObject:@{@"code":@"UNKNOWN_NATIVE_STORE_ENTRY",@"node":row}];}
        }
        [stores addObject:@{@"root":entry,@"profiles":profiles,@"otherEntries":metadata}];
    }
    if(stores.count>1)[issues addObject:@{@"code":@"AMBIGUOUS_NATIVE_STORE_PLACEMENT"}];
    // Never infer a default directory from the ID used in management metadata.
    // Root and Library inventories expose default data outside the CID store.
    BOOL zero=NO;for(NSDictionary *store in stores)for(NSDictionary *row in store[@"profiles"])if([row[@"name"] isEqual:@"0"])zero=YES;
    result[@"defaultStatePlacement"]=zero?@"ZERO_DIRECTORY_OBSERVED_OUTSIDE_DATA_UNVERIFIED":@"NO_ZERO_DIRECTORY_OUTSIDE_DATA_UNRESOLVED";
    result[@"profileStores"]=stores;result[@"layoutIssues"]=issues;return result;
}

#if !LBX_NATIVE_STORAGE_INVENTORY_TESTING
static id Get(id obj,NSString *name){SEL s=NSSelectorFromString(name);return [obj respondsToSelector:s]?((id(*)(id,SEL))objc_msgSend)(obj,s):nil;}
static NSString *URLPath(id value){return [value isKindOfClass:NSURL.class]&&[value isFileURL]?Path([value path]):nil;}
static NSDictionary *Owner(id proxy,NSString *identifier,NSString *bundle,NSError **error){
    NSString *registeredBundle=URLPath(Get(proxy,@"bundleURL")),*data=URLPath(Get(proxy,@"dataContainerURL"));id groups=Get(proxy,@"groupContainerURLs"),entitlements=Get(proxy,@"entitlements");
    NSString *role=Official(identifier)?@"main":@"extension";
    if(![registeredBundle isEqual:bundle]){Stage(error,3,[role stringByAppendingString:@".bundle-registration"]);return nil;}
    if(!data){Stage(error,3,[role stringByAppendingString:@".data-container-url"]);return nil;}
    if(![groups isKindOfClass:NSDictionary.class]||[groups count]>64){Stage(error,3,[role stringByAppendingString:groups?@".group-map-type-or-limit":@".group-map-missing"]);return nil;}
    if(![entitlements isKindOfClass:NSDictionary.class]){Stage(error,3,[role stringByAppendingString:entitlements?@".entitlements-type":@".entitlements-missing"]);return nil;}
    id declared=entitlements[@"com.apple.security.application-groups"]?:@[];
    if(![declared isKindOfClass:NSArray.class]||[declared count]>64){Stage(error,3,[role stringByAppendingString:@".declared-groups-type-or-limit"]);return nil;}
    NSMutableDictionary *paths=[NSMutableDictionary dictionary];for(id group in groups){NSString *path=URLPath(groups[group]);if(!Identifier(group)||!path){Stage(error,3,[role stringByAppendingString:@".group-identifier-or-url"]);return nil;}paths[group]=path;}
    for(id group in declared)if(!Identifier(group)){Stage(error,3,[role stringByAppendingString:@".declared-group-identifier"]);return nil;}
    if([NSSet setWithArray:declared].count!=[declared count]||![[NSSet setWithArray:declared] isEqual:[NSSet setWithArray:paths.allKeys]]){Stage(error,3,[role stringByAppendingString:@".declared-registered-groups-mismatch"]);return nil;}
    return @{@"bundleIdentifier":identifier,@"bundlePath":bundle,@"dataPath":data,@"groups":paths,@"declaredGroups":[declared sortedArrayUsingSelector:@selector(compare:)]};
}
static NSDictionary *ComponentMetadata(NSDictionary *extension){
    NSDictionary *bound=extension[@"infoPlist"];NSString *path=Path(bound[@"path"]);if(!path||![path.lastPathComponent isEqual:@"Info.plist"])return @{@"status":@"UNAVAILABLE"};
    LBXStorageScan *scan=[LBXStorageScan new];int parent=[scan openPath:path.stringByDeletingLastPathComponent error:nil];if(parent<0)return @{@"status":@"UNAVAILABLE"};
    int fd=openat(parent,"Info.plist",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);struct stat before,after;
    BOOL good=fd>=0&&!fstat(fd,&before)&&S_ISREG(before.st_mode)&&before.st_nlink==1&&(before.st_uid==0||before.st_uid==33)&&!(before.st_mode&0022)&&before.st_size>0&&before.st_size<=1024*1024&&RBXStorageGateNoACL(fd)&&before.st_dev==[bound[@"device"] longLongValue]&&before.st_ino==[bound[@"inode"] unsignedLongLongValue];
    NSMutableData *bytes=good?[NSMutableData dataWithLength:(NSUInteger)before.st_size]:nil;NSUInteger offset=0;while(good&&offset<bytes.length){ssize_t n=read(fd,(char *)bytes.mutableBytes+offset,bytes.length-offset);if(n<=0){good=NO;break;}offset+=(NSUInteger)n;}
    if(good)good=!fstat(fd,&after)&&before.st_dev==after.st_dev&&before.st_ino==after.st_ino&&before.st_size==after.st_size&&[scan verify:nil];if(fd>=0)close(fd);
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];if(good)CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest);NSMutableString *hex=[NSMutableString string];if(good)for(NSUInteger i=0;i<sizeof(digest);i++)[hex appendFormat:@"%02x",digest[i]];
    if(!good||![hex isEqual:bound[@"sha256"]])return @{@"status":@"UNAVAILABLE"};
    id plist=[NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:nil error:nil];if(![plist isKindOfClass:NSDictionary.class])return @{@"status":@"UNAVAILABLE"};
    id minimum=plist[@"MinimumOSVersion"],point=[plist[@"NSExtension"] isKindOfClass:NSDictionary.class]?plist[@"NSExtension"][@"NSExtensionPointIdentifier"]:nil;
    NSMutableDictionary *result=[@{@"status":@"OBSERVED_BOUND_INFO_PLIST",@"publisherVerified":@NO} mutableCopy];if(Name(minimum)&&[minimum length]<40)result[@"minimumOSVersion"]=minimum;if(Identifier(point))result[@"extensionPointIdentifier"]=point;
    NSOperatingSystemVersion os=NSProcessInfo.processInfo.operatingSystemVersion;result[@"deviceOSVersion"]=@[@(os.majorVersion),@(os.minorVersion),@(os.patchVersion)];return result;
}
static id DirectPlugin(NSString *identifier,NSMutableDictionary *observation){
    Class cls=NSClassFromString(@"LSPlugInKitProxy");SEL selector=NSSelectorFromString(@"pluginKitProxyForIdentifier:");Method method=cls?class_getClassMethod(cls,selector):NULL;
    observation[@"selectorPresent"]=@([cls respondsToSelector:selector]);const char *type=method?method_getTypeEncoding(method):NULL;
    if(!type||strcmp(type,"@24@0:8@16")){observation[@"status"]=@"SELECTOR_ABI_UNAVAILABLE";return nil;}
    id value=((id(*)(id,SEL,id))objc_msgSend)(cls,selector,identifier);observation[@"status"]=value?@"PROXY_RETURNED":@"NO_PROXY_RETURNED";return value;
}
static NSDictionary *Registration(NSDictionary *installation,NSError **error){
    static dispatch_once_t once;dispatch_once(&once,^{if(!dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices",RTLD_NOW))dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",RTLD_NOW);});
    NSString *mainApp=MainApp(installation);if(!mainApp){Stage(error,3,@"main.bundle-identifier");return nil;}
    Class cls=NSClassFromString(@"LSApplicationProxy");SEL lookup=NSSelectorFromString(@"applicationProxyForIdentifier:");if(![cls respondsToSelector:lookup]){Stage(error,3,@"main.lookup-unavailable");return nil;}
    id app=((id(*)(id,SEL,id))objc_msgSend)(cls,lookup,mainApp);NSDictionary *main=Owner(app,mainApp,installation[@"bundlePath"],error);if(!main)return nil;
    id raw=Get(app,@"plugInKitPlugins");NSArray *plugins=[raw isKindOfClass:NSSet.class]?[raw allObjects]:([raw isKindOfClass:NSArray.class]?raw:nil);
    NSArray *expected=installation[@"extensions"];if(!plugins){Stage(error,3,@"extensions.list-type-or-missing");return nil;}
    if(plugins.count>128){Stage(error,3,@"extensions.registration-limit");return nil;}
    NSMutableDictionary *byPath=[NSMutableDictionary dictionary];for(id plugin in plugins){NSString *path=URLPath(Get(plugin,@"bundleURL"));if(!path||byPath[path]){Stage(error,3,@"extension.bundle-url-or-duplicate");return nil;}byPath[path]=plugin;}
    NSMutableArray *owners=[NSMutableArray arrayWithObject:main],*unresolved=[NSMutableArray array],*issues=[NSMutableArray array];NSMutableSet *installedPaths=[NSMutableSet set];
    for(NSDictionary *extension in expected){[installedPaths addObject:extension[@"bundlePath"]];id plugin=byPath[extension[@"bundlePath"]];NSMutableDictionary *direct=[NSMutableDictionary dictionary];BOOL missingFromApp=plugin==nil;
        if(!plugin)plugin=DirectPlugin(extension[@"bundleIdentifier"],direct);
        NSError *ownerError=nil;id a=Get(plugin,@"pluginIdentifier"),b=Get(plugin,@"bundleIdentifier");NSDictionary *owner=nil;
        if(plugin&&(!a||[a isEqual:extension[@"bundleIdentifier"]])&&(!b||[b isEqual:extension[@"bundleIdentifier"]])&&(a||b))owner=Owner(plugin,extension[@"bundleIdentifier"],extension[@"bundlePath"],&ownerError);
        if(owner&&!missingFromApp){[owners addObject:owner];continue;}
        // Direct lookup is diagnostic only: omission from the installed app's
        // registration remains unresolved even when a proxy is returned.
        NSMutableDictionary *missing=[@{@"bundleIdentifier":extension[@"bundleIdentifier"],@"bundlePath":extension[@"bundlePath"],@"reason":missingFromApp?@"NOT_IN_APP_PLUGIN_REGISTRATION":@"OWNER_STORAGE_REGISTRATION_UNAVAILABLE"} mutableCopy];
        if(direct.count)missing[@"directLookup"]=direct;if(owner)missing[@"directRegisteredOwner"]=owner;if(ownerError.userInfo[@"stage"])missing[@"storageFailureStage"]=ownerError.userInfo[@"stage"];
        [unresolved addObject:missing];
    }
    for(NSString *path in byPath)if(![installedPaths containsObject:path])[issues addObject:@{@"reason":@"REGISTERED_EXTENSION_OUTSIDE_INSTALLED_INVENTORY",@"bundlePath":path}];
    return Freeze(@{@"owners":owners,@"unresolvedOwners":unresolved,@"registrationIssues":issues,@"registeredExtensionCount":@(plugins.count),@"installedExtensionCount":@(expected.count)});
}
#endif

@interface LBXNativeStorageInventory ()
- (instancetype)initPrivate:(NSDictionary *)snapshot;
@end
static NSDictionary *Capture(NSDictionary *registration,NSDictionary *installation,NSString *dataRoot,NSString *groupRoot,BOOL testing,BOOL(^finalCheck)(void),NSError **error) {
#if !LBX_NATIVE_STORAGE_INVENTORY_TESTING
    // Enforce both credentials at the internal boundary too. The fixture
    // provider and caller-controlled test role never exist in production.
    if(getuid()!=0||geteuid()!=0){Fail(error,2);return nil;}testing=NO;
#endif
    NSString *main=MainApp(installation);if(!main){Fail(error,3);return nil;}
    NSArray *owners=registration[@"owners"],*extensions=installation[@"extensions"],*unresolved=registration[@"unresolvedOwners"]?:@[],*registrationIssues=registration[@"registrationIssues"]?:@[];
    if(![owners isKindOfClass:NSArray.class]||![extensions isKindOfClass:NSArray.class]||![unresolved isKindOfClass:NSArray.class]||![registrationIssues isKindOfClass:NSArray.class]||owners.count+unresolved.count!=extensions.count+1||owners.count>129||unresolved.count>128||registrationIssues.count>128){Fail(error,3);return nil;}
    NSMutableDictionary *expected=[NSMutableDictionary dictionaryWithObject:installation[@"bundlePath"]?:@"" forKey:main];
    for(NSDictionary *extension in extensions){NSString *identifier=extension[@"bundleIdentifier"],*path=Path(extension[@"bundlePath"]);if(!Identifier(identifier)||![identifier hasPrefix:[main stringByAppendingString:@"."]]||expected[identifier]||!path){Fail(error,3);return nil;}expected[identifier]=path;}
    LBXStorageScan *scan=[LBXStorageScan new];scan.testing=testing;NSMutableSet *seen=[NSMutableSet set],*dataPaths=[NSMutableSet set];NSMutableDictionary *groupPaths=[NSMutableDictionary dictionary],*pathGroups=[NSMutableDictionary dictionary],*storage=[NSMutableDictionary dictionary];
    NSMutableArray *mapped=[NSMutableArray array];NSUInteger issues=unresolved.count+registrationIssues.count,profiles=0;
    for(NSDictionary *owner in owners){NSString *identifier=owner[@"bundleIdentifier"],*data=Path(owner[@"dataPath"]);NSDictionary *groups=owner[@"groups"];NSArray *declared=owner[@"declaredGroups"];
        NSString *ownerDataRoot=[identifier isEqual:main]?dataRoot:[dataRoot.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"PluginKitPlugin"];
        if(!Identifier(identifier)||[seen containsObject:identifier]||![expected[identifier] isEqual:owner[@"bundlePath"]]){Stage(error,3,@"capture.owner-identity");return nil;}
        if(!data||![data.stringByDeletingLastPathComponent isEqual:ownerDataRoot]||![[NSUUID alloc] initWithUUIDString:data.lastPathComponent]){Stage(error,3,[identifier isEqual:main]?@"capture.main-data-path-bound":@"capture.extension-data-path-bound");return nil;}
        if([dataPaths containsObject:data]){Stage(error,3,@"capture.duplicate-owner-data-root");return nil;}
        if(![groups isKindOfClass:NSDictionary.class]||groups.count>64||![declared isKindOfClass:NSArray.class]||declared.count>64){Stage(error,3,@"capture.group-map-or-declaration");return nil;}
        for(id group in declared)if(!Identifier(group)){Fail(error,3);return nil;}
        if([NSSet setWithArray:declared].count!=declared.count||![[NSSet setWithArray:declared] isEqual:[NSSet setWithArray:groups.allKeys]]){Fail(error,3);return nil;}
        [seen addObject:identifier];[dataPaths addObject:data];NSDictionary *observed=Inspect(scan,data,error);if(!observed)return nil;storage[data]=observed;
        for(id group in groups){NSString *path=Path(groups[group]);if(!Identifier(group)||!path||![path.stringByDeletingLastPathComponent isEqual:groupRoot]||![[NSUUID alloc] initWithUUIDString:path.lastPathComponent]){Stage(error,3,@"capture.shared-group-path-bound");return nil;}
            if((groupPaths[group]&&![groupPaths[group] isEqual:path])||(pathGroups[path]&&![pathGroups[path] isEqual:group])){Stage(error,3,@"capture.shared-group-ambiguous-owner");return nil;}
            groupPaths[group]=path;pathGroups[path]=group;if(!storage[path]){observed=Inspect(scan,path,error);if(!observed)return nil;storage[path]=observed;}}
        [mapped addObject:owner];
    }
    if(![seen containsObject:main]){Stage(error,3,@"capture.main-owner-required");return nil;}
    for(NSDictionary *entry in unresolved){NSString *identifier=entry[@"bundleIdentifier"];if(!Identifier(identifier)||[identifier isEqual:main]||[seen containsObject:identifier]||![expected[identifier] isEqual:entry[@"bundlePath"]]||!Name(entry[@"reason"])){Stage(error,3,@"capture.unresolved-owner-mismatch");return nil;}[seen addObject:identifier];}
    if(![[NSSet setWithArray:expected.allKeys] isEqual:seen]){Fail(error,3);return nil;}
    if(finalCheck&&!finalCheck()){Fail(error,4);return nil;}if(![scan verify:error])return nil;
    NSMutableDictionary *identities=[NSMutableDictionary dictionary];
    for(NSString *path in storage){NSDictionary *root=storage[path][@"root"];NSString *identity=[NSString stringWithFormat:@"%@:%@",root[@"device"],root[@"inode"]];if(identities[identity]){Fail(error,3);return nil;}identities[identity]=path;
        issues+=[storage[path][@"layoutIssues"] count];for(NSDictionary *store in storage[path][@"profileStores"])profiles+=[store[@"profiles"] count];}
    NSDictionary *snapshot=Freeze(@{@"formatVersion":@1,@"bundleIdentifier":main,@"installation":installation,@"owners":mapped,@"storage":storage,
        @"groupRegistrations":groupPaths,@"registration":registration,@"unresolvedOwners":unresolved,@"layoutStatus":issues?@"REJECTED":@"OBSERVED",@"unknownLayoutCount":@(issues),@"profileDirectoryCount":@(profiles),
        @"defaultStateVerified":@NO,@"completeSharedWriters":@NO,@"entitlementsSource":@"LaunchServices registration, not publisher signature verification",
        @"accountFileContentsRead":@NO,@"runtimeAccepted":@NO,@"safeToGate":@NO});
    if(!snapshot){Fail(error,5);return nil;}return snapshot;
}
static BOOL NewerOS(id minimum,id current){
    if(![minimum isKindOfClass:NSString.class]||[minimum length]>40||![current isKindOfClass:NSArray.class]||[current count]!=3)return NO;
    NSArray *parts=[minimum componentsSeparatedByString:@"."];if(!parts.count||parts.count>3)return NO;NSMutableArray *version=[NSMutableArray array];
    for(NSString *part in parts){if(!part.length||part.length>3||[part rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location!=NSNotFound)return NO;[version addObject:@(part.integerValue)];}
    while(version.count<3)[version addObject:@0];for(id value in current)if(![value isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()||CFNumberIsFloatType((__bridge CFNumberRef)value)||[value longLongValue]<0||[value unsignedLongLongValue]>999)return NO;
    for(NSUInteger i=0;i<3;i++){if([version[i] integerValue]>[current[i] integerValue])return YES;if([version[i] integerValue]<[current[i] integerValue])return NO;}return NO;
}
static NSDictionary *Classify(NSDictionary *snapshot,NSDictionary *metadata){
    NSMutableDictionary *result=[snapshot mutableCopy];NSMutableArray *unavailable=[NSMutableArray array];NSArray *unresolved=snapshot[@"unresolvedOwners"];
    for(NSDictionary *missing in unresolved){NSString *identifier=missing[@"bundleIdentifier"];NSDictionary *info=metadata[identifier],*extension=nil;
        for(NSDictionary *candidate in snapshot[@"installation"][@"extensions"])if([candidate[@"bundleIdentifier"] isEqual:identifier]&&[candidate[@"bundlePath"] isEqual:missing[@"bundlePath"]])extension=candidate;
        NSDictionary *executable=extension[@"executable"];id mode=executable[@"mode"];
        if(![missing[@"reason"] isEqual:@"NOT_IN_APP_PLUGIN_REGISTRATION"]||![missing[@"directLookup"][@"selectorPresent"] isEqual:@YES]||![missing[@"directLookup"][@"status"] isEqual:@"NO_PROXY_RETURNED"]||missing[@"directRegisteredOwner"]||![info[@"status"] isEqual:@"OBSERVED_BOUND_INFO_PLIST"]||!NewerOS(info[@"minimumOSVersion"],info[@"deviceOSVersion"])||![mode isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)mode)==CFBooleanGetTypeID()||CFNumberIsFloatType((__bridge CFNumberRef)mode)||[mode unsignedLongLongValue]>07777||([mode unsignedIntValue]&0111)||!Path(executable[@"path"]))continue;
        [unavailable addObject:@{@"bundleIdentifier":identifier,@"bundlePath":missing[@"bundlePath"],@"executable":executable,@"componentMetadata":info,@"reason":@"NEWER_OS_AND_ORIGINALLY_NONEXECUTABLE_WITH_NO_LS_PROXY",@"mustRemainNonExecutable":@YES,@"storageAbsenceProven":@NO}];
    }
    result[@"unresolvedComponentMetadata"]=metadata;result[@"unavailableExecutables"]=unavailable;
    if(unresolved.count&&unavailable.count==unresolved.count&&[snapshot[@"unknownLayoutCount"] unsignedIntegerValue]==unresolved.count){result[@"layoutStatus"]=@"OBSERVED_WITH_UNAVAILABLE_COMPONENT";result[@"unknownLayoutCount"]=@0;}
    return Freeze(result);
}
@implementation LBXNativeStorageInventory {NSDictionary *_snapshot;}
- (instancetype)initPrivate:(NSDictionary *)snapshot {if((self=[super init]))_snapshot=snapshot;return self;}
+ (instancetype)observeOfficialApplication:(NSString *)bundle error:(NSError **)error {
    if(error)*error=nil;if(getuid()!=0||geteuid()!=0){Fail(error,2);return nil;}
#if LBX_NATIVE_STORAGE_INVENTORY_TESTING
    (void)bundle;Fail(error,2);return nil;
#else
    if(!Official(bundle)){Fail(error,1);return nil;}
    @try {LBXInstalledApplicationBinding *binding=[bundle isEqual:IG]?[LBXInstalledApplicationBinding observeOfficialInstagram:error]:[LBXInstalledApplicationBinding observeOfficialFacebook:error];if(!binding){Stage(error,3,@"installation.binding-unavailable");return nil;}
        NSDictionary *installation=binding.privateDictionary,*registration=Registration(installation,error);if(!registration)return nil;
        NSDictionary *snapshot=Capture(registration,installation,DataBase,GroupBase,NO,^BOOL{
            return [binding matchesCurrentInstallation:nil]&&[registration isEqual:Registration(installation,nil)]&&getuid()==0&&geteuid()==0;
        },error);if(!snapshot)return nil;
        NSMutableDictionary *metadata=[NSMutableDictionary dictionary];for(NSDictionary *missing in snapshot[@"unresolvedOwners"])for(NSDictionary *extension in installation[@"extensions"])if([missing[@"bundleIdentifier"] isEqual:extension[@"bundleIdentifier"]])metadata[missing[@"bundleIdentifier"]]=ComponentMetadata(extension);
        NSDictionary *classified=Classify(snapshot,metadata);return classified?[[self alloc] initPrivate:classified]:nil;
    }@catch(__unused NSException *exception){Fail(error,1);return nil;}
#endif
}
+ (instancetype)observeOfficialInstagram:(NSError **)error {return [self observeOfficialApplication:IG error:error];}
+ (instancetype)observeOfficialFacebook:(NSError **)error {return [self observeOfficialApplication:FB error:error];}
- (NSDictionary *)privateDictionary{return _snapshot;}
- (BOOL)matchesCurrentRegistration:(NSError **)error {
    if(error)*error=nil;if(getuid()!=0||geteuid()!=0)return Stage(error,2,@"registration.root-required");
#if LBX_NATIVE_STORAGE_INVENTORY_TESTING
    return Stage(error,3,@"registration.production-provider-unavailable");
#else
    @try {NSDictionary *current=Registration(_snapshot[@"installation"],error);if(!current)return NO;
        return [current isEqual:_snapshot[@"registration"]]?YES:Stage(error,4,@"registration.changed");
    }@catch(__unused NSException *exception){return Stage(error,1,@"registration.observation-failed");}
#endif
}
+ (instancetype)recoverFromJournal:(LBXNativeIsolationJournal *)journal error:(NSError **)error {
    if(error)*error=nil;if(getuid()!=0||geteuid()!=0){Stage(error,2,@"recovery.root-required");return nil;}
#if LBX_NATIVE_STORAGE_INVENTORY_TESTING
    (void)journal;Stage(error,3,@"recovery.production-provider-unavailable");return nil;
#else
    @try {
        if(object_getClass(journal)!=LBXNativeIsolationJournal.class){Stage(error,3,@"recovery.exact-journal-required");return nil;}
        NSDictionary *before=[journal validatedCurrentRecord:error];if(!before)return nil;
        id raw=before[@"payload"][@"storageFence"][@"inventorySnapshot"];NSDictionary *snapshot=[raw isKindOfClass:NSDictionary.class]?Freeze(raw):nil;
        if(!snapshot||![snapshot[@"formatVersion"] isEqual:@1]||!Official(snapshot[@"bundleIdentifier"])||![snapshot[@"installation"] isKindOfClass:NSDictionary.class]||![snapshot[@"registration"] isKindOfClass:NSDictionary.class]||![snapshot[@"owners"] isKindOfClass:NSArray.class]||![snapshot[@"storage"] isKindOfClass:NSDictionary.class]||![snapshot[@"groupRegistrations"] isKindOfClass:NSDictionary.class]||![snapshot[@"unresolvedOwners"] isKindOfClass:NSArray.class]||![snapshot[@"unavailableExecutables"] isKindOfClass:NSArray.class]||![snapshot[@"runtimeAccepted"] isEqual:@NO]||![snapshot[@"safeToGate"] isEqual:@NO]||![@[@"OBSERVED",@"OBSERVED_WITH_UNAVAILABLE_COMPONENT",@"REJECTED"] containsObject:snapshot[@"layoutStatus"]]){Stage(error,3,@"recovery.inventory-snapshot-unavailable");return nil;}
        // Registration() performs only LS queries. It does not recapture the
        // installation, demand X_OK or inspect permissions changed by the gate.
        NSDictionary *registered=Registration(snapshot[@"installation"],error);if(!registered||![registered isEqual:snapshot[@"registration"]]){Stage(error,4,@"recovery.registration-changed");return nil;}
        NSDictionary *after=[journal validatedCurrentRecord:error];if(!after||![before isEqual:after]){Stage(error,4,@"recovery.journal-changed");return nil;}
        return [[self alloc] initPrivate:snapshot];
    }@catch(__unused NSException *exception){Stage(error,1,@"recovery.observation-failed");return nil;}
#endif
}
- (NSDictionary *)safeStatus{return @{@"formatVersion":@1,@"layoutStatus":_snapshot[@"layoutStatus"],@"ownerCount":@([_snapshot[@"owners"] count]),@"unresolvedOwnerCount":@([_snapshot[@"unresolvedOwners"] count]),@"unavailableExecutableCount":@([_snapshot[@"unavailableExecutables"] count]),@"storageRootCount":@([_snapshot[@"storage"] count]),@"sharedGroupCount":@([_snapshot[@"groupRegistrations"] count]),@"profileDirectoryCount":_snapshot[@"profileDirectoryCount"],@"unknownLayoutCount":_snapshot[@"unknownLayoutCount"],@"defaultStateVerified":@NO,@"completeSharedWriters":@NO,@"accountFileContentsRead":@NO,@"runtimeAccepted":@NO,@"safeToGate":@NO};}
- (NSString *)description{return [NSString stringWithFormat:@"<LBXNativeStorageInventory %@>",self.safeStatus];}
- (NSString *)debugDescription{return self.description;}
#if LBX_NATIVE_STORAGE_INVENTORY_TESTING
+ (NSDictionary *)testClassifySnapshot:(NSDictionary *)snapshot metadata:(NSDictionary *)metadata {return Classify(snapshot,metadata);}
- (BOOL)testMatchesRegistration:(NSDictionary *)registration error:(NSError **)error {
    if(error)*error=nil;return [registration isEqual:_snapshot[@"registration"]]?YES:Stage(error,4,@"registration.changed");
}
+ (instancetype)testObserveRegistration:(NSDictionary *)registration installation:(NSDictionary *)installation dataRoot:(NSString *)dataRoot groupRoot:(NSString *)groupRoot afterScan:(void (^)(void))afterScan error:(NSError **)error {
    if(error)*error=nil;@try{NSDictionary *snapshot=Capture(registration,installation,dataRoot,groupRoot,YES,^BOOL{if(afterScan)afterScan();return YES;},error);return snapshot?[[self alloc] initPrivate:snapshot]:nil;}@catch(__unused NSException *exception){Fail(error,1);return nil;}
}
#endif
@end
