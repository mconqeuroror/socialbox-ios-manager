#import <Foundation/Foundation.h>
#import "../lucid/Switching/LBXNativeStorageInventory.h"
#include <sys/stat.h>
#include <sys/resource.h>
#include <fcntl.h>
#include <unistd.h>

static NSUInteger Checks;
static void Check(BOOL ok,NSString *message){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}}
static NSString *Join(NSString *a,NSString *b){return [a stringByAppendingPathComponent:b];}
static void Dir(NSString *p){Check([NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil],@"fixture directory");}
static void Write(NSString *p){Check([[@"PRIVATE CANARY CONTENT" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:p atomically:NO],@"fixture file");}
// Exercise the real private scanner; this adds no production fixture seam.
@interface LBXStorageScan:NSObject
@property(nonatomic)BOOL testing;
- (int)openPath:(NSString *)path error:(NSError **)error;
- (BOOL)verify:(NSError **)error;
@end
@interface Fixture:NSObject
@property NSString *base,*dataBase,*groupsBase,*main,*extension,*group,*store;
@property NSMutableDictionary *registration;
@property NSDictionary *installation;
- (LBXNativeStorageInventory *)observe:(void (^)(void))after;
@end
@implementation Fixture
- (instancetype)init {if((self=[super init])) {
    NSString *raw=Join(NSTemporaryDirectory(),[@"socialbox-native-storage-" stringByAppendingString:NSUUID.UUID.UUIDString]);Dir(raw);char *physical=realpath(raw.fileSystemRepresentation,NULL);Check(physical!=NULL,@"fixture canonical root");_base=@(physical);free(physical);
    _dataBase=Join(_base,@"Data/Application");_groupsBase=Join(_base,@"Shared/AppGroup");
    _main=Join(_dataBase,NSUUID.UUID.UUIDString);_extension=Join(Join(_dataBase.stringByDeletingLastPathComponent,@"PluginKitPlugin"),NSUUID.UUID.UUIDString);_group=Join(_groupsBase,NSUUID.UUID.UUIDString);
    for(NSString *path in @[_main,_extension,_group]){Dir(Join(path,@"Library"));Dir(Join(path,@"Documents"));Write(Join(path,@".com.apple.mobile_container_manager.metadata.plist"));}
    _store=Join(_main,@"Library/___SocialBox_Containers");for(NSString *cid in @[@"108",@"109"]){Dir(Join(_store,cid));Write(Join(Join(_store,cid),@"do-not-read"));}
    NSString *app=@"/fixed/installation/Instagram.app",*plugin=Join(app,@"PlugIns/Share.appex");
    _installation=@{@"bundlePath":app,@"extensions":@[@{@"bundleIdentifier":@"com.burbn.instagram.share",@"bundlePath":plugin}]};
    NSDictionary *(^owner)(NSString *,NSString *,NSString *)=^NSDictionary *(NSString *identifier,NSString *bundle,NSString *data){return @{@"bundleIdentifier":identifier,@"bundlePath":bundle,@"dataPath":data,@"groups":@{@"group.com.example.fixture":self.group},@"declaredGroups":@[@"group.com.example.fixture"]};};
    _registration=[@{@"owners":@[owner(@"com.burbn.instagram",app,_main),owner(@"com.burbn.instagram.share",plugin,_extension)]} mutableCopy];
}return self;}
- (void)dealloc {[NSFileManager.defaultManager removeItemAtPath:_base error:nil];}
- (LBXNativeStorageInventory *)observe:(void (^)(void))after {NSError *error=nil;return [LBXNativeStorageInventory testObserveRegistration:self.registration installation:self.installation dataRoot:self.dataBase groupRoot:self.groupsBase afterScan:after error:&error];}
@end
static void ReplaceOwner(Fixture *f,NSUInteger index,NSString *key,id value){NSMutableArray *owners=[f.registration[@"owners"] mutableCopy];NSMutableDictionary *owner=[owners[index] mutableCopy];if(value)owner[key]=value;else[owner removeObjectForKey:key];owners[index]=owner;f.registration[@"owners"]=owners;}
static void Bad(NSString *label,void(^change)(Fixture *)){@autoreleasepool{Fixture *f=[Fixture new];change(f);Check([f observe:nil]==nil,label);}}
static void ReusedPins(void){
    @autoreleasepool{Fixture *f=[Fixture new];LBXStorageScan *scan=[LBXStorageScan new];scan.testing=YES;
        int first=[scan openPath:f.main error:nil];Check(first>=0,@"first path retains actual directory FD");
        Check([scan openPath:f.main error:nil]==first,@"same canonical path reuses same live FD");
        Check([scan openPath:f.extension error:nil]>=0&&[scan verify:nil],@"distinct root shares only matching ancestors and all pins verify");
        Check(!chmod(f.dataBase.fileSystemRepresentation,0755),@"change owned shared ancestor mode");
        Check([scan openPath:f.main error:nil]<0,@"cached shared ancestor mode drift refused before reuse");
    }
    @autoreleasepool{Fixture *f=[Fixture new];LBXStorageScan *scan=[LBXStorageScan new];scan.testing=YES;
        Check([scan openPath:f.main error:nil]>=0,@"capture ancestor before replacement");
        NSString *old=[f.dataBase stringByAppendingString:@"-old"];Check(!rename(f.dataBase.fileSystemRepresentation,old.fileSystemRepresentation),@"move owned cached ancestor");Dir(f.dataBase);
        Check([scan openPath:f.main error:nil]<0,@"same path replacement inode refused before cached descendant reuse");
        Check(![scan verify:nil],@"final held-parent check also rejects replaced ancestor");
    }
    @autoreleasepool{Fixture *f=[Fixture new];LBXStorageScan *scan=[LBXStorageScan new];scan.testing=YES;
        Check([scan openPath:f.main error:nil]>=0,@"capture root before symlink substitution");
        NSString *old=[f.main stringByAppendingString:@"-old"];Check(!rename(f.main.fileSystemRepresentation,old.fileSystemRepresentation),@"move owned cached root");
        Check(!symlink(old.fileSystemRepresentation,f.main.fileSystemRepresentation),@"substitute same destination through symlink");
        Check([scan openPath:f.main error:nil]<0,@"same destination symlink cannot reuse cached FD");
    }
}
static void LimitedDescriptors(void){@autoreleasepool{
    Fixture *f=[Fixture new];NSMutableDictionary *groups=[NSMutableDictionary dictionaryWithDictionary:@{@"group.com.example.fixture":f.group}];
    for(NSUInteger i=0;i<2;i++){NSString *path=Join(f.groupsBase,NSUUID.UUID.UUIDString);Dir(path);groups[[NSString stringWithFormat:@"group.com.example.extra%lu",(unsigned long)i]]=path;}
    NSMutableArray *owners=[NSMutableArray array],*extensions=[NSMutableArray array],*roots=[NSMutableArray arrayWithArray:groups.allValues];
    for(NSUInteger i=0;i<7;i++){
        NSString *identifier=i?[NSString stringWithFormat:@"com.burbn.instagram.extension%lu",(unsigned long)i]:@"com.burbn.instagram";
        NSString *bundle=i?Join(f.installation[@"bundlePath"],[NSString stringWithFormat:@"PlugIns/Extension%lu.appex",(unsigned long)i]):f.installation[@"bundlePath"];
        NSString *data=i?Join(Join(f.dataBase.stringByDeletingLastPathComponent,@"PluginKitPlugin"),NSUUID.UUID.UUIDString):f.main;
        Dir(data);[roots addObject:data];if(i)[extensions addObject:@{@"bundleIdentifier":identifier,@"bundlePath":bundle}];
        [owners addObject:@{@"bundleIdentifier":identifier,@"bundlePath":bundle,@"dataPath":data,@"groups":groups,@"declaredGroups":groups.allKeys}];
    }
    for(NSString *root in roots){Dir(Join(root,@"Library/___SocialBox_Containers/108"));Dir(Join(root,@"Library/___SocialBox_Containers/109"));}
    f.installation=@{@"bundlePath":f.installation[@"bundlePath"],@"extensions":extensions};f.registration=[@{@"owners":owners} mutableCopy];
    LBXNativeStorageInventory *before=[f observe:nil];Check(before&&[before.safeStatus[@"storageRootCount"] isEqual:@10],@"ten owned roots observed without pressure");
    struct rlimit saved,limited;Check(getrlimit(RLIMIT_NOFILE,&saved)==0&&saved.rlim_cur>=256,@"host supports phone descriptor limit");limited=saved;limited.rlim_cur=256;
    Check(setrlimit(RLIMIT_NOFILE,&limited)==0,@"use phone descriptor limit without changing hard limit");
    int held[256],count=0,descriptor;while(count<256&&(descriptor=open("/dev/null",O_RDONLY|O_CLOEXEC))>=0)held[count++]=descriptor;
    int exhaustion=errno;BOOL filled=count<256&&exhaustion==EMFILE&&count>=96;
    for(int i=0;i<96&&count;i++)close(held[--count]);
    // Model retained fence/code FDs. The scan has exactly 96 descriptor slots
    // available, enough for unique roots but not ten copies of all ancestors.
    BOOL observed=filled;NSInteger refusal=0;for(NSUInteger i=0;i<8&&observed;i++){@autoreleasepool{
        NSError *error=nil;LBXNativeStorageInventory *value=[LBXNativeStorageInventory testObserveRegistration:f.registration installation:f.installation dataRoot:f.dataBase groupRoot:f.groupsBase afterScan:nil error:&error];
        observed=value&&[value.privateDictionary isEqual:before.privateDictionary];refusal=error.code;
    }}
    while(count)close(held[--count]);Check(setrlimit(RLIMIT_NOFILE,&saved)==0,@"restore host descriptor limit");
    Check(filled,@"fixture reached real EMFILE before reserving exact headroom");
    if(!observed)fprintf(stderr,"limited inventory refused code %ld\n",(long)refusal);
    Check(observed,@"repeated complete ten-root observation fits 96 free FDs under limit256 and retains exact snapshot");
}}
int main(void){@autoreleasepool {
    ReusedPins();
    LimitedDescriptors();
    Check([LBXNativeStorageInventory observeOfficialInstagram:nil]==nil,@"fixture build cannot invoke production provider");
    Check([LBXNativeStorageInventory observeOfficialFacebook:nil]==nil,@"fixture build cannot invoke Facebook production provider");
    Fixture *f=[Fixture new];NSData *before=[NSData dataWithContentsOfFile:Join(Join(f.store,@"108"),@"do-not-read")];LBXNativeStorageInventory *inventory=[f observe:nil];Check(inventory!=nil,@"complete main and extension registrations observed");
    Check([inventory.safeStatus[@"ownerCount"] isEqual:@2]&&[inventory.safeStatus[@"storageRootCount"] isEqual:@3]&&[inventory.safeStatus[@"sharedGroupCount"] isEqual:@1],@"shared groups deduplicate while owner relationships remain");
    Check([inventory.safeStatus[@"profileDirectoryCount"] isEqual:@2]&&[inventory.safeStatus[@"layoutStatus"] isEqual:@"OBSERVED"],@"exact numeric CID directories discovered");
    Check([inventory testMatchesRegistration:f.registration error:nil],@"same exact saved registration matches without executable or permission observation");
    Check(![inventory testMatchesRegistration:@{@"owners":@[]} error:nil],@"changed owner registration invalidates match");
    Check(![inventory matchesCurrentRegistration:nil],@"fixture object cannot use production registration authority");
    struct stat original;Check(!lstat(f.main.fileSystemRepresentation,&original)&&[inventory.privateDictionary[@"storage"][f.main][@"root"][@"flags"] unsignedIntValue]==original.st_flags,@"root flags record exact observed original flags");
    Check([inventory.privateDictionary[@"storage"][f.main][@"defaultStatePlacement"] isEqual:@"NO_ZERO_DIRECTORY_OUTSIDE_DATA_UNRESOLVED"],@"default is not invented from selection ID zero");
    Check(![inventory.safeStatus[@"safeToGate"] boolValue]&&![inventory.safeStatus[@"runtimeAccepted"] boolValue]&&![inventory.safeStatus[@"defaultStateVerified"] boolValue]&&![inventory.safeStatus[@"completeSharedWriters"] boolValue],@"inventory never grants gate admission or shared-writer completeness");
    Check(![[inventory description] containsString:f.main]&&![[inventory description] containsString:@"group.com.example"]&&![[inventory description] containsString:@"108"],@"safe status omits private paths group IDs and CIDs");
    Check([[NSData dataWithContentsOfFile:Join(Join(f.store,@"108"),@"do-not-read")] isEqual:before],@"account file bytes unchanged");
    NSData *snapshot=[NSJSONSerialization dataWithJSONObject:inventory.privateDictionary options:NSJSONWritingSortedKeys error:nil];Check(snapshot.length&&![inventory.privateDictionary isKindOfClass:NSMutableDictionary.class],@"private snapshot immutable and serializable");
    Write(Join(f.store,@"metadata.plist"));LBXNativeStorageInventory *unknown=[f observe:nil];Check(unknown&&[unknown.safeStatus[@"layoutStatus"] isEqual:@"REJECTED"]&&[unknown.safeStatus[@"unknownLayoutCount"] isEqual:@1],@"unknown native metadata retained privately and rejected");
    Check([[NSJSONSerialization dataWithJSONObject:inventory.privateDictionary options:NSJSONWritingSortedKeys error:nil] isEqual:snapshot],@"later files cannot mutate prior snapshot");
    @autoreleasepool {Fixture *facebook=[Fixture new];
        NSString *app=@"/fixed/installation/Facebook.app",*plugin=[app stringByAppendingPathComponent:@"PlugIns/Share.appex"];
        facebook.installation=@{@"bundlePath":app,@"bundleIdentifier":@"com.facebook.Facebook",@"extensions":@[@{@"bundleIdentifier":@"com.facebook.Facebook.share",@"bundlePath":plugin}]};
        NSDictionary *(^owner)(NSString *,NSString *,NSString *)=^NSDictionary *(NSString *identifier,NSString *bundle,NSString *data){return @{@"bundleIdentifier":identifier,@"bundlePath":bundle,@"dataPath":data,@"groups":@{@"group.com.example.fixture":facebook.group},@"declaredGroups":@[@"group.com.example.fixture"]};};
        facebook.registration=[@{@"owners":@[owner(@"com.facebook.Facebook",app,facebook.main),owner(@"com.facebook.Facebook.share",plugin,facebook.extension)]} mutableCopy];
        LBXNativeStorageInventory *observed=[facebook observe:nil];
        Check(observed&&[observed.privateDictionary[@"bundleIdentifier"] isEqual:@"com.facebook.Facebook"]&&[observed.safeStatus[@"layoutStatus"] isEqual:@"OBSERVED"]&&[observed.safeStatus[@"ownerCount"] isEqual:@2]&&![observed.safeStatus[@"runtimeAccepted"] boolValue],@"Facebook main and extension capture uses the same host contract without claiming isolation");
    }
    Bad(@"unofficial main bundle cannot use native capture",^(Fixture *x){x.installation=@{@"bundlePath":x.installation[@"bundlePath"],@"bundleIdentifier":@"com.twitter.twitter",@"extensions":x.installation[@"extensions"]};});
    Bad(@"missing extension refuses partial inventory",^(Fixture *x){x.registration[@"owners"]=@[x.registration[@"owners"][0]];});
    @autoreleasepool {Fixture *x=[Fixture new];NSDictionary *extension=x.installation[@"extensions"][0];x.registration[@"owners"]=@[x.registration[@"owners"][0]];x.registration[@"unresolvedOwners"]=@[@{@"bundleIdentifier":extension[@"bundleIdentifier"],@"bundlePath":extension[@"bundlePath"],@"reason":@"NOT_IN_APP_PLUGIN_REGISTRATION"}];LBXNativeStorageInventory *partial=[x observe:nil];Check(partial&&[partial.safeStatus[@"layoutStatus"] isEqual:@"REJECTED"]&&[partial.safeStatus[@"unresolvedOwnerCount"] isEqual:@1]&&[partial.safeStatus[@"storageRootCount"] isEqual:@2]&&!partial.privateDictionary[@"storage"][x.extension],@"explicit unresolved installed extension preserves rejected main and group observations without inventing data root");}
    Bad(@"duplicate main cannot replace extension",^(Fixture *x){x.registration[@"owners"]=@[x.registration[@"owners"][0],x.registration[@"owners"][0]];});
    Bad(@"wrong installed extension bundle refused",^(Fixture *x){ReplaceOwner(x,1,@"bundlePath",@"/other.appex");});
    Bad(@"missing data registration refused",^(Fixture *x){ReplaceOwner(x,1,@"dataPath",nil);});
    Bad(@"shared main and extension data roots ambiguous",^(Fixture *x){ReplaceOwner(x,1,@"dataPath",x.main);});
    Bad(@"relative registered data root refused",^(Fixture *x){ReplaceOwner(x,0,@"dataPath",@"../outside");});
    Bad(@"dot components refused",^(Fixture *x){ReplaceOwner(x,0,@"dataPath",Join(x.dataBase,@"../Application/00000000-0000-0000-0000-000000000001"));});
    Bad(@"outside registered data root refused",^(Fixture *x){ReplaceOwner(x,0,@"dataPath",Join(x.base,NSUUID.UUID.UUIDString));});
    Bad(@"declared but unregistered group refused",^(Fixture *x){ReplaceOwner(x,0,@"declaredGroups",@[@"group.missing"]);});
    Bad(@"duplicate group declarations refused",^(Fixture *x){ReplaceOwner(x,0,@"declaredGroups",@[@"group.com.example.fixture",@"group.com.example.fixture"]);});
    Bad(@"one group cannot refer to two roots",^(Fixture *x){NSString *p=Join(x.groupsBase,NSUUID.UUID.UUIDString);Dir(p);ReplaceOwner(x,1,@"groups",@{@"group.com.example.fixture":p});});
    Bad(@"one group root cannot have ambiguous names",^(Fixture *x){ReplaceOwner(x,1,@"groups",@{@"group.other":x.group});ReplaceOwner(x,1,@"declaredGroups",@[@"group.other"]);});
    for(NSString *component in @[@"data",@"Library",@"store",@"profile"])Bad(@"symlink at gate boundaries refused",^(Fixture *x){NSString *p=[component isEqual:@"data"]?x.main:[component isEqual:@"Library"]?Join(x.main,@"Library"):[component isEqual:@"store"]?x.store:Join(x.store,@"108");NSString *moved=[p stringByAppendingString:@"-moved"];Check(!rename(p.fileSystemRepresentation,moved.fileSystemRepresentation),@"move fixture before alias");Check(!symlink(moved.fileSystemRepresentation,p.fileSystemRepresentation),@"create alias fixture");});
    for(NSString *name in @[@"01",@"-1",@"18446744073709551616",@"unknown.plist"]) {@autoreleasepool {Fixture *x=[Fixture new];Dir(Join(x.store,name));LBXNativeStorageInventory *value=[x observe:nil];Check(value&&[value.safeStatus[@"layoutStatus"] isEqual:@"REJECTED"],@"noncanonical CID or unknown native node rejected");}}
    @autoreleasepool {Fixture *x=[Fixture new];Dir(Join(x.main,@"___SocialBox_Containers/108"));LBXNativeStorageInventory *value=[x observe:nil];Check(value&&[value.safeStatus[@"layoutStatus"] isEqual:@"REJECTED"],@"two store placements rejected");}
    @autoreleasepool {Fixture *x=[Fixture new];Dir(Join(x.store,@"0"));LBXNativeStorageInventory *value=[x observe:nil];Check([value.privateDictionary[@"storage"][x.main][@"defaultStatePlacement"] isEqual:@"ZERO_DIRECTORY_OBSERVED_OUTSIDE_DATA_UNVERIFIED"],@"observed zero directory does not prove default routing");}
    @autoreleasepool {Fixture *x=[Fixture new];Check([x observe:^{Dir(Join(x.store,@"110"));}]==nil,@"late CID creation invalidates observed membership");}
    @autoreleasepool {Fixture *x=[Fixture new];Check([x observe:^{Check(!chmod(x.store.fileSystemRepresentation,0755),@"change observed mode");}]==nil,@"late directory mode change invalidates snapshot");}
    @autoreleasepool {Fixture *x=[Fixture new];Check([x observe:^{NSString *p=Join(x.store,@"108");Check(!rename(p.fileSystemRepresentation,[p stringByAppendingString:@"-old"].fileSystemRepresentation),@"replace observed inode");Dir(p);}]==nil,@"same path different inode invalidates snapshot");}
    NSString *unavailableID=@"com.burbn.instagram.fixturecontrol",*bundle=@"/fixed/Control.appex";
    NSDictionary *missing=@{@"bundleIdentifier":unavailableID,@"bundlePath":bundle,@"reason":@"NOT_IN_APP_PLUGIN_REGISTRATION",@"directLookup":@{@"selectorPresent":@YES,@"status":@"NO_PROXY_RETURNED"}};
    NSDictionary *extension=@{@"bundleIdentifier":unavailableID,@"bundlePath":bundle,@"executable":@{@"path":Join(bundle,@"Control"),@"mode":@0444}};
    NSDictionary *info=@{@"status":@"OBSERVED_BOUND_INFO_PLIST",@"minimumOSVersion":@"18.0",@"deviceOSVersion":@[@16,@7,@16]};
    NSDictionary *classification=@{@"installation":@{@"extensions":@[extension]},@"unresolvedOwners":@[missing],@"unknownLayoutCount":@1,@"layoutStatus":@"REJECTED",@"runtimeAccepted":@NO,@"safeToGate":@NO};
    NSDictionary *known=[LBXNativeStorageInventory testClassifySnapshot:classification metadata:@{unavailableID:info}];Check([known[@"layoutStatus"] isEqual:@"OBSERVED_WITH_UNAVAILABLE_COMPONENT"]&&[known[@"unavailableExecutables"] count]==1&&[known[@"unavailableExecutables"][0][@"mustRemainNonExecutable"] isEqual:@YES]&&[known[@"unavailableExecutables"][0][@"storageAbsenceProven"] isEqual:@NO]&&[known[@"safeToGate"] isEqual:@NO],@"strict newer OS plus nonexec and no LS proxy classification grants no launch or storage absence authority");
    for(NSString *minimum in @[@"16.7.16",@"16.7.15",@"16",@"18beta",@"18..0"]){NSMutableDictionary *changed=[info mutableCopy];changed[@"minimumOSVersion"]=minimum;Check([[LBXNativeStorageInventory testClassifySnapshot:classification metadata:@{unavailableID:changed}][@"layoutStatus"] isEqual:@"REJECTED"],@"minimum OS must be strictly newer with a valid version");}
    for(NSNumber *mode in @[@0755,@0100,@YES,@(-1)]){NSMutableDictionary *changed=[extension mutableCopy];changed[@"executable"]=@{@"path":Join(bundle,@"Control"),@"mode":mode};NSMutableDictionary *value=[classification mutableCopy];value[@"installation"]=@{@"extensions":@[changed]};Check([[LBXNativeStorageInventory testClassifySnapshot:value metadata:@{unavailableID:info}][@"layoutStatus"] isEqual:@"REJECTED"],@"executable or malformed original mode cannot be excluded");}
    for(NSDictionary *direct in @[@{@"selectorPresent":@NO,@"status":@"NO_PROXY_RETURNED"},@{@"selectorPresent":@YES,@"status":@"PROXY_RETURNED"},@{@"selectorPresent":@YES,@"status":@"SELECTOR_ABI_UNAVAILABLE"}]){NSMutableDictionary *changed=[missing mutableCopy];changed[@"directLookup"]=direct;NSMutableDictionary *value=[classification mutableCopy];value[@"unresolvedOwners"]=@[changed];Check([[LBXNativeStorageInventory testClassifySnapshot:value metadata:@{unavailableID:info}][@"layoutStatus"] isEqual:@"REJECTED"],@"missing selector ABI or a returned proxy is unresolved");}
    NSMutableDictionary *otherIssue=[classification mutableCopy];otherIssue[@"unknownLayoutCount"]=@2;Check([[LBXNativeStorageInventory testClassifySnapshot:otherIssue metadata:@{unavailableID:info}][@"layoutStatus"] isEqual:@"REJECTED"],@"known unavailable component cannot hide a separate layout problem");
    printf("PASS: %lu native storage inventory assertions; no device operations\n",(unsigned long)Checks);return 0;
}}
