#import "LBXNativeStorageFence.h"
#import "LBXNativeStorageInventory.h"
#import "LBXNativeStorageLayout.h"
#import "LBXNativeApplicationGate.h"
#import "LBXNativeIsolationJournal.h"
#import "../../shared/RBXStorageGate.h"
#include <dirent.h>
#include <fcntl.h>
#include <math.h>
#include <string.h>
#ifndef LBX_NATIVE_STORAGE_FENCE_TESTING
#define LBX_NATIVE_STORAGE_FENCE_TESTING 0
#endif
static NSString *const Instagram=@"com.burbn.instagram";
static NSString *const Facebook=@"com.facebook.Facebook";
static BOOL Official(id value){return [value isEqual:Instagram]||[value isEqual:Facebook];}

static BOOL Fail(NSError **error,NSInteger code){if(error)*error=[NSError errorWithDomain:@"com.socialbox.native-storage-fence" code:code userInfo:@{NSLocalizedDescriptionKey:@"Native storage transaction could not be verified; recovery is required"}];return NO;}
static BOOL Budget(double deadline){double now=LBXNativeApplicationGateClock();return isfinite(now)&&isfinite(deadline)&&deadline>now&&deadline-now<=120;}
#if LBX_NATIVE_STORAGE_FENCE_TESTING
static NSString *TestRoot;
static int (^ReopenDescriptor)(NSString *);
static void (^Checkpoint)(NSString *);
static uid_t RootOwner(void){return getuid();}
static gid_t RootGroup(void){return getgid();}
static uid_t AppOwner(void){return getuid();}
static gid_t AppGroup(void){return getgid();}
static BOOL Root(void){return TestRoot!=nil;}
#else
static uid_t RootOwner(void){return 0;}
static gid_t RootGroup(void){return 0;}
static uid_t AppOwner(void){return 501;}
static gid_t AppGroup(void){return 501;}
static BOOL Root(void){return getuid()==0&&geteuid()==0;}
#endif
static BOOL Scope(NSString *path){
#if LBX_NATIVE_STORAGE_FENCE_TESTING
    if(TestRoot)return [path hasPrefix:[TestRoot stringByAppendingString:@"/"]];
#endif
    return [path hasPrefix:@"/private/var/mobile/Containers/"];
}
static NSDictionary *Attributes(struct stat s){NSMutableDictionary *attributes=[@{@"device":@(s.st_dev),@"inode":@(s.st_ino),@"uid":@(s.st_uid),@"gid":@(s.st_gid),@"mode":@(s.st_mode&07777),@"flags":@(s.st_flags)} mutableCopy];if(!S_ISDIR(s.st_mode))attributes[@"linkCount"]=@(s.st_nlink);return [attributes copy];}
static NSDictionary *Immutable(NSDictionary *value){if(![NSJSONSerialization isValidJSONObject:value])return nil;NSData *bytes=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];return bytes.length&&bytes.length<=8*1024*1024?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;}
static void At(NSString *stage){
#if LBX_NATIVE_STORAGE_FENCE_TESTING
    if(Checkpoint)Checkpoint(stage);
#else
    (void)stage;
#endif
}
static int OpenNode(int parent,NSString *leaf,NSString *path,BOOL directory){
    int fd=parent<0?open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):openat(parent,leaf.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|(directory?O_DIRECTORY:O_NONBLOCK));
#if LBX_NATIVE_STORAGE_FENCE_TESTING
    if(fd<0&&errno==EACCES&&ReopenDescriptor){int retained=ReopenDescriptor(path);if(retained>=0)fd=fcntl(retained,F_DUPFD_CLOEXEC,0);}
#else
    (void)path;
#endif
    return fd;
}
static BOOL Name(NSString *name){return [name isKindOfClass:NSString.class]&&name.length&&[name lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<256;}
@interface LBXStoragePin:NSObject
@property(nonatomic)int fd,parent;
@property(nonatomic)BOOL directory,controlled,namespace,ownsImmutable;
@property(nonatomic,copy)NSString *path,*leaf,*cid;
@property(nonatomic,copy)NSDictionary *original,*expected;
@end
@implementation LBXStoragePin
- (instancetype)init{if((self=[super init])){_fd=-1;_parent=-1;}return self;}
- (void)dealloc{if(_fd>=0)close(_fd);}
@end
static BOOL Same(LBXStoragePin *pin){struct stat a,b;if(fstat(pin.fd,&a)||(pin.parent<0?lstat("/",&b):fstatat(pin.parent,pin.leaf.fileSystemRepresentation,&b,AT_SYMLINK_NOFOLLOW)))return NO;
    return (pin.directory?S_ISDIR(a.st_mode):S_ISREG(a.st_mode))&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino&&a.st_dev==[pin.original[@"device"] longLongValue]&&a.st_ino==[pin.original[@"inode"] unsignedLongLongValue]&&RBXStorageGateNoACL(pin.fd);}
static NSArray *Names(int fd){int copy=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *stream=copy>=0?fdopendir(copy):NULL;if(!stream){if(copy>=0)close(copy);return nil;}NSMutableArray *names=[NSMutableArray array];BOOL good=YES;
    for(;;){errno=0;struct dirent *e=readdir(stream);if(!e){if(errno)good=NO;break;}if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;NSString *name=[[NSString alloc] initWithBytes:e->d_name length:strlen(e->d_name) encoding:NSUTF8StringEncoding];if(!name||names.count>=4096){good=NO;break;}[names addObject:name];}closedir(stream);return good?[names sortedArrayUsingSelector:@selector(compare:)]:nil;}
@interface LBXNativeStorageFence ()
@property(nonatomic,strong)LBXNativeApplicationGate *gate;
@property(nonatomic,strong)LBXNativeStorageInventory *inventory;
@property(nonatomic,strong)LBXNativeIsolationJournal *journal;
@property(nonatomic,strong)NSArray<LBXStoragePin *> *pins,*dataPins,*namespacePins;
@property(nonatomic,copy)NSDictionary *record,*envelope,*memberships;
@property(nonatomic,copy)NSString *phase,*selected;
@property(nonatomic)BOOL busy,reentered,effects,lastDrainVerified;
@property(nonatomic)double deadline;
- (instancetype)initPrivate;
- (BOOL)current;
@end
static bool Authorized(void *context){BOOL(^block)(void)=(__bridge id)context;return block();}
@implementation LBXNativeStorageFence
- (instancetype)initPrivate{return [super init];}
#if LBX_NATIVE_STORAGE_FENCE_TESTING
+ (void)testUseRoot:(NSString *)root {TestRoot=[root copy];}
+ (void)testSetReopenDescriptor:(int (^)(NSString *))provider{ReopenDescriptor=[provider copy];}
+ (void)testSetCheckpoint:(void (^)(NSString *))checkpoint{Checkpoint=[checkpoint copy];}
#endif
static NSDictionary *NodeAttributes(NSDictionary *node){NSMutableDictionary *attrs=[NSMutableDictionary dictionary];for(NSString *key in @[@"device",@"inode",@"uid",@"gid",@"mode",@"flags"]){if(!node[key])return nil;attrs[key]=node[key];}if(![node[@"type"] isEqual:@"directory"]){if(!node[@"linkCount"])return nil;attrs[@"linkCount"]=node[@"linkCount"];}return [attrs copy];}
static BOOL RecoverAttributes(NSDictionary *actual,NSDictionary *original,BOOL space,NSString *cid){
    for(NSString *key in @[@"device",@"inode"])if(![actual[key] isEqual:original[key]])return NO;
    if(original[@"linkCount"]&&![actual[@"linkCount"] isEqual:original[@"linkCount"]])return NO;
    unsigned flags=[original[@"flags"] unsignedIntValue],nowFlags=[actual[@"flags"] unsignedIntValue];mode_t sealed=space?0711:0000;
    if(flags&~(UF_NODUMP|UF_HIDDEN))return NO;
    uid_t activeOwner=space||[cid isEqual:@"0"]?[original[@"uid"] unsignedIntValue]:AppOwner();
    gid_t activeGroup=space||[cid isEqual:@"0"]?[original[@"gid"] unsignedIntValue]:AppGroup();
    mode_t activeMode=space||[cid isEqual:@"0"]?[original[@"mode"] unsignedIntValue]:0700;
    if(nowFlags==(flags|UF_IMMUTABLE))return [actual[@"uid"] unsignedIntValue]==RootOwner()&&[actual[@"gid"] unsignedIntValue]==RootGroup()&&[actual[@"mode"] unsignedIntValue]==sealed;
    if(nowFlags!=flags)return NO;
    // Only states reachable while setting original, sealed, or selected
    // attributes are admitted for restrictive recovery, never for opening.
    unsigned owner=[actual[@"uid"] unsignedIntValue],group=[actual[@"gid"] unsignedIntValue],mode=[actual[@"mode"] unsignedIntValue];
    return (owner==[original[@"uid"] unsignedIntValue]||owner==RootOwner()||owner==activeOwner)&&
        (group==[original[@"gid"] unsignedIntValue]||group==RootGroup()||group==activeGroup)&&
        (mode==[original[@"mode"] unsignedIntValue]||mode==sealed||mode==activeMode||mode==0000);
}
+ (instancetype)captureInventory:(LBXNativeStorageInventory *)inventory applicationGate:(LBXNativeApplicationGate *)gate journal:(LBXNativeIsolationJournal *)journal error:(NSError **)error {
    return [self openInventory:inventory applicationGate:gate journal:journal saved:nil envelope:nil beforeDeadline:LBXNativeApplicationGateClock()+30 error:error];
}
+ (instancetype)openInventory:(LBXNativeStorageInventory *)inventory applicationGate:(LBXNativeApplicationGate *)gate journal:(LBXNativeIsolationJournal *)journal saved:(NSDictionary *)saved envelope:(NSDictionary *)envelope beforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;if(!Root()||!Budget(deadline)||![inventory isMemberOfClass:LBXNativeStorageInventory.class]||![gate isMemberOfClass:LBXNativeApplicationGate.class]||![journal isMemberOfClass:LBXNativeIsolationJournal.class]){Fail(error,1);return nil;}
    NSError *journalError=nil;NSDictionary *prior=[journal validatedCurrentRecord:&journalError];if(journalError||(saved?![prior isEqual:envelope]:prior!=nil)){Fail(error,2);return nil;}
    if(![inventory.privateDictionary[@"installation"] isEqual:gate.privateJournalRecord[@"binding"]]||![inventory matchesCurrentRegistration:error]){Fail(error,3);return nil;}
    id inventoryID=inventory.privateDictionary[@"bundleIdentifier"],gateID=gate.privateJournalRecord[@"binding"][@"bundleIdentifier"];
    if(Official(inventoryID)&&Official(gateID)&&![inventoryID isEqual:gateID]){Fail(error,3);return nil;}
    LBXNativeStorageLayout *layout=[LBXNativeStorageLayout layoutForInventory:inventory error:error];if(!layout)return nil;
    if(saved&&(![saved isKindOfClass:NSDictionary.class]||saved.count!=6||![saved[@"formatVersion"] isEqual:@1]||![saved[@"inventorySnapshot"] isEqual:inventory.privateDictionary]||![saved[@"layout"] isEqual:layout.privateDictionary]||![saved[@"originals"] isKindOfClass:NSArray.class]||![saved[@"ancestry"] isKindOfClass:NSArray.class])){Fail(error,3);return nil;}
    LBXNativeStorageFence *fence=[[self alloc] initPrivate];fence.gate=gate;fence.journal=journal;fence.inventory=inventory;fence.deadline=deadline;fence.envelope=envelope;
    NSMutableDictionary *byPath=[NSMutableDictionary dictionary],*memberships=[NSMutableDictionary dictionary],*controls=[NSMutableDictionary dictionary],*ancestors=[NSMutableDictionary dictionary];NSMutableArray *pins=[NSMutableArray array],*data=[NSMutableArray array],*namespaces=[NSMutableArray array];
    NSArray *groups=@[layout.privateDictionary[@"protectedNodes"],layout.privateDictionary[@"namespaces"]];
    for(NSUInteger group=0;group<groups.count;group++)for(NSDictionary *item in groups[group]){NSString *path=item[@"node"][@"path"];if(controls[path]){Fail(error,3);return nil;}controls[path]=@{@"node":item[@"node"],@"namespace":@(group==1),@"cid":group==0?item[@"containerID"]:NSNull.null};}
    if(saved)for(NSDictionary *ancestor in saved[@"ancestry"]){NSString *path=ancestor[@"path"];if(![ancestor isKindOfClass:NSDictionary.class]||ancestor.count!=2||![path isKindOfClass:NSString.class]||ancestors[path]||![ancestor[@"original"] isKindOfClass:NSDictionary.class]){Fail(error,3);return nil;}ancestors[path]=ancestor[@"original"];}
    NSMutableDictionary *plannedMembers=[NSMutableDictionary dictionary];
    for(NSDictionary *space in groups[1]){NSString *path=space[@"node"][@"path"];NSMutableArray *names=[NSMutableArray array];
        for(NSArray *group in groups)for(NSDictionary *item in group){NSString *child=item[@"node"][@"path"];if([child.stringByDeletingLastPathComponent isEqual:path])[names addObject:child.lastPathComponent];}
        if([NSSet setWithArray:names].count!=names.count){Fail(error,3);return nil;}plannedMembers[path]=[names sortedArrayUsingSelector:@selector(compare:)];
    }
    for(NSUInteger group=0;group<groups.count;group++)for(NSDictionary *item in groups[group]){
        NSDictionary *node=item[@"node"];NSString *path=node[@"path"];if(!Scope(path)||path.length>=4096){Fail(error,3);return nil;}
        NSArray *parts=path.pathComponents;NSString *current=@"/";LBXStoragePin *parent=nil;
        for(NSUInteger i=0;i<parts.count;i++){
            NSString *leaf=parts[i];if(i){if(!Name(leaf)||[leaf isEqual:@"."]||[leaf isEqual:@".."]||[leaf containsString:@"/"]||[leaf containsString:@"\\"]){Fail(error,3);return nil;}current=[current stringByAppendingPathComponent:leaf];}
            LBXStoragePin *pin=byPath[current];BOOL directory=i+1<parts.count||[node[@"type"] isEqual:@"directory"];
            if(!pin){pin=[LBXStoragePin new];pin.path=current;pin.leaf=i?leaf:@"/";pin.parent=parent?parent.fd:-1;pin.directory=directory;
                pin.fd=OpenNode(pin.parent,pin.leaf,current,directory);struct stat stat;
                if(pin.fd<0||fstat(pin.fd,&stat)||(stat.st_uid!=0&&stat.st_uid!=501&&stat.st_uid!=33)||((stat.st_mode&0022)&&!(LBX_NATIVE_STORAGE_FENCE_TESTING&&directory&&stat.st_uid==0&&(stat.st_mode&S_ISVTX)))||(!directory&&stat.st_nlink!=1)){Fail(error,3);return nil;}
                NSDictionary *actual=Attributes(stat),*control=controls[current];pin.original=saved?(control?NodeAttributes(control[@"node"]):ancestors[current]):actual;pin.expected=actual;
                if(!pin.original||!Same(pin)){Fail(error,3);return nil;}
                if(saved){if(control?!RecoverAttributes(actual,pin.original,[control[@"namespace"] boolValue],control[@"cid"]):![actual isEqual:pin.original]){Fail(error,3);return nil;}}
                [pins addObject:pin];byPath[current]=pin;
            }else if(pin.directory!=directory){Fail(error,3);return nil;}parent=pin;
        }
        if(parent.controlled){Fail(error,3);return nil;}parent.controlled=YES;parent.namespace=group==1;parent.cid=group==0?item[@"containerID"]:nil;parent.ownsImmutable=saved!=nil;
        if(![parent.original isEqual:NodeAttributes(node)]||([parent.original[@"flags"] unsignedIntValue]&~(UF_NODUMP|UF_HIDDEN))||([parent.original[@"mode"] unsignedIntValue]&07000)){Fail(error,3);return nil;}
        if(group==0)[data addObject:parent];else{if(!saved&&![Names(parent.fd) isEqual:plannedMembers[path]]){Fail(error,3);return nil;}memberships[path]=plannedMembers[path];[namespaces addObject:parent];}
    }
    fence.pins=pins;fence.dataPins=data;fence.namespacePins=[namespaces sortedArrayUsingComparator:^NSComparisonResult(LBXStoragePin *a,LBXStoragePin *b){return [a.path compare:b.path];}];fence.memberships=memberships;fence.phase=saved?@"recovery-closing":@"captured";
    NSMutableArray *originals=[NSMutableArray array],*ancestry=[NSMutableArray array];for(LBXStoragePin *pin in pins){if(pin.controlled)[originals addObject:@{@"path":pin.path,@"directory":@(pin.directory),@"namespace":@(pin.namespace),@"containerID":pin.cid?:NSNull.null,@"original":pin.original}];else[ancestry addObject:@{@"path":pin.path,@"original":pin.original}];}
    fence.record=Immutable(@{@"formatVersion":@1,@"inventorySnapshot":inventory.privateDictionary,@"layout":layout.privateDictionary,@"originals":originals,@"memberships":memberships,@"ancestry":ancestry});
    if(!fence.record||(saved?![saved isEqual:fence.record]:![fence current])){Fail(error,3);return nil;}return fence;
}
+ (instancetype)recoverFromJournal:(LBXNativeIsolationJournal *)journal beforeDeadline:(double)deadline error:(NSError **)error {
    if(error)*error=nil;if(!Root()||!Budget(deadline)||![journal isMemberOfClass:LBXNativeIsolationJournal.class]){Fail(error,1);return nil;}
    LBXNativeApplicationGate *gate=nil;LBXNativeStorageFence *fence=nil;
    @try {NSDictionary *envelope=[journal validatedCurrentRecord:error],*payload=envelope[@"payload"],*record=payload[@"storageFence"];
        if(![payload[@"component"] isEqual:@"native-storage-fence"]||![record isKindOfClass:NSDictionary.class]){Fail(error,3);return nil;}
        gate=[LBXNativeApplicationGate recoverFromJournal:journal beforeDeadline:deadline error:error];if(!gate)return nil;
        NSMutableDictionary *intent=[payload mutableCopy];intent[@"phase"]=@"recovery-closing";intent[@"selectedContainerID"]=NSNull.null;intent[@"runtimeAccepted"]=@NO;intent[@"lastDrainVerified"]=@NO;
        if(![journal compareRecord:envelope replaceWith:intent error:error]){[gate closeAndDrainBeforeDeadline:deadline error:nil];return nil;}
        envelope=[journal validatedCurrentRecord:error];if(!envelope||![gate closeAndDrainBeforeDeadline:deadline error:error])return nil;At(@"recovery-gate-closed");
        LBXNativeStorageInventory *inventory=[LBXNativeStorageInventory recoverFromJournal:journal error:error];if(!inventory)return nil;
        fence=[self openInventory:inventory applicationGate:gate journal:journal saved:record envelope:envelope beforeDeadline:deadline error:error];if(!fence)return nil;
        fence.effects=YES;fence.lastDrainVerified=YES;
        if([fence freeze]&&[fence current]&&[fence publish:@"closed" selected:nil error:error])return fence;
    }@catch(__unused NSException *exception){Fail(error,3);}
    if(fence)[fence emergencyClose];else if(gate)[gate closeAndDrainBeforeDeadline:LBXNativeApplicationGateClock()+10 error:nil];Fail(error,4);return nil;
}

- (BOOL)current {
    if(!Root()||!Budget(_deadline)||_reentered||![_inventory matchesCurrentRegistration:nil])return NO;
    for(LBXStoragePin *pin in _pins){struct stat s;if(!Same(pin)||fstat(pin.fd,&s)||![Attributes(s) isEqual:pin.expected])return NO;}
    for(LBXStoragePin *pin in _namespacePins)if(![Names(pin.fd) isEqual:_memberships[pin.path]])return NO;
    NSError *error=nil;NSDictionary *disk=[_journal validatedCurrentRecord:&error];return !error&&(_envelope?[disk isEqual:_envelope]:disk==nil);
}
- (BOOL)publish:(NSString *)phase selected:(NSString *)selected error:(NSError **)error {
    NSDictionary *payload=@{@"component":@"native-storage-fence",@"phase":phase,@"selectedContainerID":selected?:NSNull.null,
        @"applicationGate":_gate.privateJournalRecord,@"storageFence":_record,@"runtimeAccepted":@NO,@"lastDrainVerified":@(_lastDrainVerified)};
    if(![_journal compareRecord:_envelope replaceWith:payload error:error])return NO;
    _envelope=_journal.currentRecord;_phase=phase;_selected=[selected copy];At([@"published-" stringByAppendingString:phase]);return YES;
}
- (RBXStorageGateImmutableNode)entry:(LBXStoragePin *)pin {
    struct stat parent={0};fstat(pin.parent,&parent);
    RBXStorageGateImmutableNode entry={0};entry.descriptor=pin.fd;entry.device=[pin.original[@"device"] longLongValue];entry.inode=[pin.original[@"inode"] unsignedLongLongValue];entry.directory=pin.directory;
    entry.parent=(RBXStorageGateDirectory){pin.parent,parent.st_dev,parent.st_ino};entry.leaf=pin.leaf.UTF8String;
    entry.activeOwner=pin.namespace?[pin.original[@"uid"] unsignedIntValue]:([pin.cid isEqual:@"0"]?[pin.original[@"uid"] unsignedIntValue]:AppOwner());
    entry.activeGroup=pin.namespace?[pin.original[@"gid"] unsignedIntValue]:([pin.cid isEqual:@"0"]?[pin.original[@"gid"] unsignedIntValue]:AppGroup());
    entry.activeMode=(pin.namespace||[pin.cid isEqual:@"0"])?[pin.original[@"mode"] unsignedIntValue]:0700;
    entry.sealedMode=pin.namespace?0711:0000;entry.originalFlags=[pin.original[@"flags"] unsignedIntValue];entry.ownsImmutable=pin.ownsImmutable;return entry;
}
- (void)expectSelection:(NSString *)selected {
    for(LBXStoragePin *pin in _pins)if(pin.controlled){
        NSMutableDictionary *expected=[pin.original mutableCopy];BOOL open=!pin.namespace&&selected&&[pin.cid isEqual:selected];
        RBXStorageGateImmutableNode entry=[self entry:pin];
        expected[@"uid"]=@(open?entry.activeOwner:RootOwner());expected[@"gid"]=@(open?entry.activeGroup:RootGroup());
        expected[@"mode"]=@(open?entry.activeMode:entry.sealedMode);
        expected[@"flags"]=@(entry.originalFlags|(open?0:UF_IMMUTABLE));pin.expected=expected;
    }
}
- (BOOL)freeze {
    BOOL good=YES;
    // Namespace ancestors intentionally overlap data roots. Seal each ancestor
    // separately; the complete member lists are validated again before opening.
    for(LBXStoragePin *pin in _namespacePins){RBXStorageGateImmutableNode entry=[self entry:pin];pin.ownsImmutable=YES;
        if(!RBXStorageGateImmutableNodeSetTransition(&entry,1,NULL,0,RootOwner(),RootGroup(),AppOwner(),NULL,NULL))good=NO;At(@"namespace-frozen");}
    NSUInteger count=_dataPins.count;RBXStorageGateImmutableNode *entries=calloc(count,sizeof(*entries));
    if(!entries)good=NO;else{for(NSUInteger i=0;i<count;i++){entries[i]=[self entry:_dataPins[i]];_dataPins[i].ownsImmutable=YES;}
        if(!RBXStorageGateImmutableNodeSetTransition(entries,count,NULL,0,RootOwner(),RootGroup(),AppOwner(),NULL,NULL))good=NO;free(entries);}
    [self expectSelection:nil];At(@"data-frozen");return good;
}
- (BOOL)drain:(double)deadline error:(NSError **)error{_lastDrainVerified=NO;_lastDrainVerified=[_gate closeAndDrainBeforeDeadline:deadline error:error];if(_lastDrainVerified)At(@"gate-closed");return _lastDrainVerified;}
- (void)emergencyClose {
    [self drain:LBXNativeApplicationGateClock()+10 error:nil];
    if(_effects)[self freeze];_phase=@"recovery-required";
}
- (BOOL)closeAllBeforeDeadline:(double)deadline error:(NSError **)error {@synchronized(self){
    if(_busy){_reentered=YES;return Fail(error,4);}_busy=YES;_reentered=NO;_deadline=deadline;BOOL good=NO;
    @try{_lastDrainVerified=NO;if([self current]&&[self publish:@"closing" selected:nil error:error]){_effects=YES;
        good=[self drain:deadline error:error]&&[self freeze]&&[self current]&&[self publish:@"closed" selected:nil error:error];}}
    @catch(__unused NSException *exception){good=NO;}
    if(!good&&_effects)[self emergencyClose];_busy=NO;return good?YES:Fail(error,4);
}}
- (BOOL)openContainerID:(NSString *)cid beforeDeadline:(double)deadline authorization:(BOOL (^)(void))authorization error:(NSError **)error {@synchronized(self){
    if(_busy){_reentered=YES;return Fail(error,4);}_busy=YES;_reentered=NO;_deadline=deadline;BOOL good=NO;
    @try{if([_phase isEqual:@"closed"]&&authorization&&[self current]&&[_record[@"layout"][@"observedContainerIDs"] containsObject:cid]&&authorization()&&[self current]){
        NSUInteger count=_dataPins.count;RBXStorageGateImmutableNode *entries=calloc(count,sizeof(*entries));size_t *selection=calloc(count,sizeof(*selection));size_t selectedCount=0;
        if(entries&&selection){for(NSUInteger i=0;i<count;i++){entries[i]=[self entry:_dataPins[i]];if([_dataPins[i].cid isEqual:cid])selection[selectedCount++]=i;}
            _lastDrainVerified=NO;if(selectedCount&&[self publish:@"opening" selected:cid error:error]&&[self drain:deadline error:error]){
                BOOL (^allowed)(void)=^BOOL{@try{return Root()&&Budget(self.deadline)&&!self.reentered&&authorization();}@catch(__unused NSException *e){return NO;}};
                good=RBXStorageGateImmutableNodeSetTransition(entries,count,selection,selectedCount,RootOwner(),RootGroup(),AppOwner(),Authorized,(__bridge void *)allowed);[self expectSelection:cid];
                good=good&&[self current]&&authorization()&&[self current]&&[self publish:@"data-open-execution-closed" selected:cid error:error];}}
        free(entries);free(selection);}}
    @catch(__unused NSException *exception){good=NO;}
    if(!good&&_effects)[self emergencyClose];_busy=NO;return good?YES:Fail(error,4);
}}
- (BOOL)restoreExecutionBeforeDeadline:(double)deadline authorization:(BOOL (^)(void))authorization error:(NSError **)error {@synchronized(self){
    if(_busy){_reentered=YES;return Fail(error,4);}_busy=YES;_reentered=NO;_deadline=deadline;BOOL good=NO;
    @try{_lastDrainVerified=NO;if([_phase isEqual:@"data-open-execution-closed"]&&authorization&&[self current]&&authorization()&&[self current]&&[self publish:@"restoring-execution" selected:_selected error:error]){
        _lastDrainVerified=NO;good=[_gate restoreExecutionBeforeDeadline:deadline authorization:^BOOL{@try{return [self current]&&authorization()&&[self current];}@catch(__unused NSException *e){return NO;}} error:error];
        good=good&&[self current]&&authorization()&&[self publish:@"active" selected:_selected error:error];}}
    @catch(__unused NSException *exception){good=NO;}
    if(!good&&_effects)[self emergencyClose];_busy=NO;return good?YES:Fail(error,4);
}}
- (NSDictionary *)safeStatus {return @{@"phase":_phase?:@"unavailable",@"protectedNodeCount":@(_dataPins.count),@"namespaceCount":@(_namespacePins.count),@"runtimeAccepted":@NO,@"lastDrainVerified":@(_lastDrainVerified),@"brokerIsolationVerified":@NO};}
@end
