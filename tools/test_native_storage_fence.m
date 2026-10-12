#import <Foundation/Foundation.h>
#import "../lucid/Switching/LBXNativeStorageFence.h"
#import "../lucid/Switching/LBXNativeStorageInventory.h"
#import "../lucid/Switching/LBXNativeApplicationGate.h"
#import "../lucid/Switching/LBXNativeIsolationJournal.h"
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
static NSUInteger checks;static BOOL ExecutionClosed,FailDrain,FailRestoreAfterOpening,RegistrationValid=YES;
#define CHECK(...) do {checks++;if(!(__VA_ARGS__)){fprintf(stderr,"FAIL line %d errno %d\n",__LINE__,errno);exit(1);}}while(0)
@interface LBXNativeStorageInventory (Fixture)
+ (instancetype)fixture:(NSDictionary *)snapshot;
- (instancetype)initFixture:(NSDictionary *)snapshot;
@end
@implementation LBXNativeStorageInventory {NSDictionary *_fixture;}
+ (instancetype)fixture:(NSDictionary *)snapshot{return [[self alloc] initFixture:snapshot];}
- (instancetype)initFixture:(NSDictionary *)snapshot{if((self=[super init]))_fixture=snapshot;return self;}
+ (instancetype)observeOfficialInstagram:(NSError **)error{(void)error;return nil;}
+ (instancetype)observeOfficialFacebook:(NSError **)error{(void)error;return nil;}
+ (instancetype)recoverFromJournal:(LBXNativeIsolationJournal *)journal error:(NSError **)error{NSDictionary *record=[journal validatedCurrentRecord:error];if(!RegistrationValid)return nil;NSDictionary *snapshot=record[@"payload"][@"storageFence"][@"inventorySnapshot"];return snapshot?[self fixture:snapshot]:nil;}
- (BOOL)matchesCurrentRegistration:(NSError **)error{(void)error;return RegistrationValid;}
- (NSDictionary *)privateDictionary{return _fixture;}
- (NSDictionary *)safeStatus{return @{};}
@end
@interface LBXNativeApplicationGate (Fixture)
+ (instancetype)fixture;
- (instancetype)initFixture;
@end
@implementation LBXNativeApplicationGate
+ (instancetype)fixture{return [[self alloc] initFixture];}
- (instancetype)initFixture{return [super init];}
+ (instancetype)captureOfficialInstagramBeforeDeadline:(double)deadline error:(NSError **)error{(void)deadline;(void)error;return nil;}
+ (instancetype)captureOfficialFacebookBeforeDeadline:(double)deadline error:(NSError **)error{(void)deadline;(void)error;return nil;}
+ (instancetype)recoverFromJournal:(LBXNativeIsolationJournal *)journal beforeDeadline:(double)deadline error:(NSError **)error{(void)deadline;NSDictionary *record=[journal validatedCurrentRecord:error];return [record[@"payload"][@"applicationGate"] isEqual:[self fixture].privateJournalRecord]?[self fixture]:nil;}
- (BOOL)closeExecutionBeforeDeadline:(double)deadline error:(NSError **)error{(void)deadline;(void)error;ExecutionClosed=YES;return YES;}
- (BOOL)closeAndDrainBeforeDeadline:(double)deadline error:(NSError **)error{(void)deadline;(void)error;ExecutionClosed=YES;return !FailDrain;}
- (BOOL)restoreExecutionBeforeDeadline:(double)deadline authorization:(BOOL(^)(void))authorization error:(NSError **)error{(void)deadline;(void)error;if(!authorization())return NO;ExecutionClosed=NO;if(FailRestoreAfterOpening){FailDrain=YES;return NO;}return authorization();}
- (NSDictionary *)privateJournalRecord{return @{@"fixture":@YES,@"binding":@{@"fixture":@YES}};}
- (NSDictionary *)safeStatus{return @{@"executionClosed":@(ExecutionClosed)};}
@end
double LBXNativeApplicationGateClock(void){return NSProcessInfo.processInfo.systemUptime;}
static NSDictionary *Node(NSString *path){struct stat s;CHECK(!lstat(path.fileSystemRepresentation,&s));NSMutableDictionary *node=[@{@"name":path.lastPathComponent,@"path":path,@"type":S_ISDIR(s.st_mode)?@"directory":@"regular",@"device":@(s.st_dev),@"inode":@(s.st_ino),@"uid":@(s.st_uid),@"gid":@(s.st_gid),@"mode":@(s.st_mode&07777),@"flags":@(s.st_flags)} mutableCopy];if(!S_ISDIR(s.st_mode))node[@"linkCount"]=@(s.st_nlink);return node;}
static void Directory(NSString *path){CHECK(!mkdir(path.fileSystemRepresentation,0700));}
static NSDictionary *FixtureFor(NSString *base,NSString *bundle){NSString *root=[base stringByAppendingPathComponent:@"Data"],*library=[root stringByAppendingPathComponent:@"Library"],*store=[library stringByAppendingPathComponent:@"___SocialBox_Containers"];
    Directory(root);Directory(library);Directory(store);Directory([store stringByAppendingPathComponent:@"1"]);Directory([store stringByAppendingPathComponent:@"2"]);Directory([root stringByAppendingPathComponent:@"Documents"]);Directory([library stringByAppendingPathComponent:@"Preferences"]);
    NSString *file=[root stringByAppendingPathComponent:@"default-state"];int fd=open(file.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600);CHECK(fd>=0);CHECK(write(fd,"owned fixture",13)==13);CHECK(!close(fd));
    return @{@"installation":@{@"fixture":@YES},@"bundleIdentifier":bundle,@"layoutStatus":@"OBSERVED",@"owners":@[@{@"dataPath":root,@"groups":@{}}],
        @"storage":@{root:@{@"root":Node(root),@"rootEntries":@[Node(library),Node([root stringByAppendingPathComponent:@"Documents"]),Node(file)],
            @"libraryEntries":@[Node(store),Node([library stringByAppendingPathComponent:@"Preferences"])],
            @"profileStores":@[@{@"root":Node(store),@"profiles":@[Node([store stringByAppendingPathComponent:@"1"]),Node([store stringByAppendingPathComponent:@"2"])],@"otherEntries":@[]}],@"layoutIssues":@[]}}};
}
static NSDictionary *Fixture(NSString *base){return FixtureFor(base,@"com.burbn.instagram");}
static NSArray *Nodes(NSDictionary *snapshot){NSMutableArray *nodes=[NSMutableArray array];for(NSDictionary *scope in [snapshot[@"storage"] allValues]){[nodes addObject:scope[@"root"]];[nodes addObjectsFromArray:scope[@"rootEntries"]];[nodes addObjectsFromArray:scope[@"libraryEntries"]];for(NSDictionary *store in scope[@"profileStores"])[nodes addObjectsFromArray:store[@"profiles"]];}return nodes;}
static void Cleanup(NSDictionary *snapshot,NSString *base){for(NSDictionary *node in Nodes(snapshot)){NSString *path=node[@"path"];struct stat s;CHECK(!lstat(path.fileSystemRepresentation,&s));CHECK(s.st_dev==[node[@"device"] longLongValue]&&s.st_ino==[node[@"inode"] unsignedLongLongValue]);CHECK(!chflags(path.fileSystemRepresentation,[node[@"flags"] unsignedIntValue]));CHECK(!chmod(path.fileSystemRepresentation,[node[@"mode"] unsignedIntValue]));}CHECK([NSFileManager.defaultManager removeItemAtPath:base error:nil]);}
static void CheckSelected(NSDictionary *snapshot,NSString *cid){for(NSDictionary *scope in [snapshot[@"storage"] allValues])for(NSDictionary *store in scope[@"profileStores"])for(NSDictionary *node in store[@"profiles"]){struct stat s;CHECK(!lstat([node[@"path"] fileSystemRepresentation],&s));BOOL active=[node[@"name"] isEqual:cid];CHECK((s.st_mode&07777)==(active?0700:0000));CHECK(s.st_flags==(active?0:UF_IMMUTABLE));}}
static double Deadline(void){return LBXNativeApplicationGateClock()+30;}
static NSString *Base(void){char template[]="/tmp/socialbox-fence-XXXXXX";CHECK(mkdtemp(template));char physical[PATH_MAX];CHECK(realpath(template,physical));CHECK(!chown(physical,getuid(),getgid()));NSString *base=@(physical);[LBXNativeStorageFence testUseRoot:base];RegistrationValid=YES;FailDrain=NO;ExecutionClosed=NO;return base;}
static NSDictionary *RetainNodes(NSDictionary *snapshot){NSMutableDictionary *fds=[NSMutableDictionary dictionary];for(NSDictionary *node in Nodes(snapshot)){NSString *path=node[@"path"];if(fds[path])continue;int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|([node[@"type"] isEqual:@"directory"]?O_DIRECTORY:O_NONBLOCK));CHECK(fd>=0);fds[path]=@(fd);}return fds;}
static void ReleaseNodes(NSDictionary *fds){[LBXNativeStorageFence testSetReopenDescriptor:nil];for(NSNumber *fd in fds.allValues)CHECK(!close(fd.intValue));}
static void RecoveryCases(void){
    NSArray *stages=@[@"published-closing",@"gate-closed",@"namespace-frozen",@"data-frozen",@"published-closed",@"published-opening",@"published-data-open-execution-closed",@"published-restoring-execution",@"published-active"];
    for(NSString *stage in stages){@autoreleasepool{NSString *base=Base();NSDictionary *snapshot=Fixture(base),*fds=RetainNodes(snapshot);NSString *journalPath=[base stringByAppendingPathComponent:@"Journal"];
        LBXNativeIsolationJournal *first=[LBXNativeIsolationJournal testOpenDirectory:journalPath create:YES error:nil];CHECK(first);[first close];
        pid_t child=fork();CHECK(child>=0);if(!child){@autoreleasepool{
            LBXNativeIsolationJournal *journal=[LBXNativeIsolationJournal testOpenDirectory:journalPath create:NO error:nil];
            LBXNativeStorageFence *fence=[LBXNativeStorageFence captureInventory:[LBXNativeStorageInventory fixture:snapshot] applicationGate:[LBXNativeApplicationGate fixture] journal:journal error:nil];if(!fence)_exit(71);
            [LBXNativeStorageFence testSetCheckpoint:^(NSString *point){if([point isEqual:stage])_exit(79);}];
            if(![fence closeAllBeforeDeadline:Deadline() error:nil])_exit(72);
            if(![fence openContainerID:@"1" beforeDeadline:Deadline() authorization:^BOOL{return YES;} error:nil])_exit(73);
            if(![fence restoreExecutionBeforeDeadline:Deadline() authorization:^BOOL{return YES;} error:nil])_exit(74);_exit(75);
        }}
        int status=0;CHECK(waitpid(child,&status,0)==child&&WIFEXITED(status)&&WEXITSTATUS(status)==79);
        [LBXNativeStorageFence testSetReopenDescriptor:^int(NSString *path){NSNumber *fd=fds[path];return fd?fd.intValue:-1;}];
        LBXNativeIsolationJournal *journal=[LBXNativeIsolationJournal testOpenDirectory:journalPath create:NO error:nil];CHECK(journal);NSError *error=nil;
        LBXNativeStorageFence *recovered=[LBXNativeStorageFence recoverFromJournal:journal beforeDeadline:Deadline() error:&error];CHECK(recovered&&!error);CHECK(ExecutionClosed);CHECK([recovered.safeStatus[@"phase"] isEqual:@"closed"]);CHECK([recovered.safeStatus[@"lastDrainVerified"] isEqual:@YES]);CheckSelected(snapshot,nil);
        CHECK([journal.currentRecord[@"payload"][@"phase"] isEqual:@"closed"]);CHECK(journal.currentRecord[@"payload"][@"selectedContainerID"]==NSNull.null);
        CHECK([recovered openContainerID:@"2" beforeDeadline:Deadline() authorization:^BOOL{return YES;} error:&error]);CheckSelected(snapshot,@"2");CHECK(ExecutionClosed);
        [journal close];ReleaseNodes(fds);Cleanup(snapshot,base);
    }}
    for(NSString *kind in @[@"registration",@"binding",@"layout",@"original",@"ancestry",@"membership",@"unknown-entry",@"foreign-mode",@"foreign-flag",@"replacement",@"symlink",@"ancestor-replacement",@"failed-drain",@"closed-journal"]){@autoreleasepool{
        NSString *base=Base();NSDictionary *snapshot=Fixture(base),*fds=RetainNodes(snapshot);NSString *journalPath=[base stringByAppendingPathComponent:@"Journal"];
        LBXNativeIsolationJournal *journal=[LBXNativeIsolationJournal testOpenDirectory:journalPath create:YES error:nil];CHECK(journal);
        LBXNativeStorageFence *fence=[LBXNativeStorageFence captureInventory:[LBXNativeStorageInventory fixture:snapshot] applicationGate:[LBXNativeApplicationGate fixture] journal:journal error:nil];CHECK(fence);CHECK([fence closeAllBeforeDeadline:Deadline() error:nil]);
        [LBXNativeStorageFence testSetReopenDescriptor:^int(NSString *path){NSNumber *fd=fds[path];return fd?fd.intValue:-1;}];
        if([@[@"binding",@"layout",@"original",@"ancestry",@"membership"] containsObject:kind]){
            NSMutableDictionary *payload=[NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:journal.currentRecord[@"payload"] options:0 error:nil] options:NSJSONReadingMutableContainers error:nil];NSMutableDictionary *record=payload[@"storageFence"];
            if([kind isEqual:@"binding"])record[@"inventorySnapshot"][@"installation"]=@{@"foreign":@YES};
            if([kind isEqual:@"layout"])record[@"layout"][@"observedContainerIDs"]=@[@"0",@"99"];
            if([kind isEqual:@"original"])record[@"originals"][0][@"original"][@"inode"]=@1;
            if([kind isEqual:@"ancestry"])record[@"ancestry"][0][@"original"][@"inode"]=@1;
            if([kind isEqual:@"membership"])record[@"memberships"]=[NSMutableDictionary dictionary];
            CHECK([journal compareRecord:journal.currentRecord replaceWith:payload error:nil]);
        }
        NSString *root=[snapshot[@"storage"] allKeys][0],*profile=[root stringByAppendingPathComponent:@"Library/___SocialBox_Containers/1"];
        if([kind isEqual:@"unknown-entry"]){CHECK(!chflags(root.fileSystemRepresentation,0));int fd=open([[root stringByAppendingPathComponent:@"unknown-state"] fileSystemRepresentation],O_WRONLY|O_CREAT|O_EXCL,0600);CHECK(fd>=0);CHECK(!close(fd));}
        if([kind isEqual:@"foreign-mode"]){CHECK(!chflags(profile.fileSystemRepresentation,0));CHECK(!chmod(profile.fileSystemRepresentation,0500));}
        if([kind isEqual:@"foreign-flag"]){CHECK(!chflags(profile.fileSystemRepresentation,UF_HIDDEN));}
        NSString *retained=[base stringByAppendingPathComponent:@"retained-original"],*replaced=[root stringByAppendingPathComponent:@"default-state"];
        if([kind isEqual:@"replacement"]||[kind isEqual:@"symlink"]){CHECK(!chflags(root.fileSystemRepresentation,0));CHECK(!chflags(replaced.fileSystemRepresentation,0));CHECK(!rename(replaced.fileSystemRepresentation,retained.fileSystemRepresentation));if([kind isEqual:@"symlink"])CHECK(!symlink(retained.fileSystemRepresentation,replaced.fileSystemRepresentation));else{int fd=open(replaced.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600);CHECK(fd>=0);CHECK(!close(fd));}}
        if([kind isEqual:@"ancestor-replacement"]){replaced=[root stringByAppendingPathComponent:@"Library"];CHECK(!chflags(root.fileSystemRepresentation,0));CHECK(!chflags(replaced.fileSystemRepresentation,0));CHECK(!rename(replaced.fileSystemRepresentation,retained.fileSystemRepresentation));Directory(replaced);}
        if([kind isEqual:@"registration"])RegistrationValid=NO;if([kind isEqual:@"failed-drain"])FailDrain=YES;if([kind isEqual:@"closed-journal"])[journal close];
        NSError *error=nil;LBXNativeStorageFence *recovered=[LBXNativeStorageFence recoverFromJournal:journal beforeDeadline:Deadline() error:&error];CHECK(!recovered);CHECK(ExecutionClosed);
        if(![kind isEqual:@"closed-journal"])CHECK(![journal.currentRecord[@"payload"][@"phase"] isEqual:@"active"]);
        if([@[@"replacement",@"symlink",@"ancestor-replacement"] containsObject:kind]){CHECK([NSFileManager.defaultManager removeItemAtPath:replaced error:nil]);CHECK(!rename(retained.fileSystemRepresentation,replaced.fileSystemRepresentation));}
        [journal close];RegistrationValid=YES;FailDrain=NO;ReleaseNodes(fds);Cleanup(snapshot,base);
    }}
    for(NSString *kind in @[@"namespace-insertion",@"registration-drift"]){NSString *base=Base();NSDictionary *snapshot=Fixture(base);NSString *root=[snapshot[@"storage"] allKeys][0];
        if([kind isEqual:@"namespace-insertion"]){int fd=open([[root stringByAppendingPathComponent:@"late"] fileSystemRepresentation],O_WRONLY|O_CREAT|O_EXCL,0600);CHECK(fd>=0);CHECK(!close(fd));}else RegistrationValid=NO;
        LBXNativeIsolationJournal *journal=[LBXNativeIsolationJournal testOpenDirectory:[base stringByAppendingPathComponent:@"Journal"] create:YES error:nil];CHECK(journal);
        CHECK(![LBXNativeStorageFence captureInventory:[LBXNativeStorageInventory fixture:snapshot] applicationGate:[LBXNativeApplicationGate fixture] journal:journal error:nil]);CHECK(journal.currentRecord==nil);CHECK(!ExecutionClosed);[journal close];RegistrationValid=YES;Cleanup(snapshot,base);
    }
}
int main(void){@autoreleasepool{
    for(int scenario=0;scenario<6;scenario++){
        char template[]="/tmp/socialbox-fence-XXXXXX";CHECK(mkdtemp(template));char physical[PATH_MAX];CHECK(realpath(template,physical));NSString *base=@(physical);CHECK(!chown(physical,getuid(),getgid()));[LBXNativeStorageFence testUseRoot:base];NSDictionary *snapshot=Fixture(base);
        LBXNativeIsolationJournal *journal=[LBXNativeIsolationJournal testOpenDirectory:[base stringByAppendingPathComponent:@"Journal"] create:YES error:nil];CHECK(journal);ExecutionClosed=NO;FailDrain=NO;FailRestoreAfterOpening=NO;
        LBXNativeApplicationGate *gate=[LBXNativeApplicationGate fixture];LBXNativeStorageFence *fence=[LBXNativeStorageFence captureInventory:[LBXNativeStorageInventory fixture:snapshot] applicationGate:gate journal:journal error:nil];CHECK(fence);CHECK(journal.currentRecord==nil);
        if(scenario==4)FailDrain=YES;
        BOOL closed=[fence closeAllBeforeDeadline:Deadline() error:nil];CHECK(closed==(scenario!=4));CHECK(ExecutionClosed);CheckSelected(snapshot,nil);
        if(scenario==0){
            CHECK([fence openContainerID:@"1" beforeDeadline:Deadline() authorization:^BOOL{return YES;} error:nil]);CHECK(ExecutionClosed);CheckSelected(snapshot,@"1");
            NSString *root=[snapshot[@"storage"] allKeys][0];errno=0;CHECK(mkdir([[root stringByAppendingPathComponent:@"unexpected"] fileSystemRepresentation],0700)==-1);CHECK(errno==EPERM);
            Directory([root stringByAppendingPathComponent:@"Library/___SocialBox_Containers/1/legitimate-child"]);
            CHECK([fence restoreExecutionBeforeDeadline:Deadline() authorization:^BOOL{return YES;} error:nil]);CHECK(!ExecutionClosed);
            CHECK([fence closeAllBeforeDeadline:Deadline() error:nil]);CHECK(ExecutionClosed);CheckSelected(snapshot,nil);
            CHECK([fence openContainerID:@"2" beforeDeadline:Deadline() authorization:^BOOL{return YES;} error:nil]);CheckSelected(snapshot,@"2");
            CHECK([fence restoreExecutionBeforeDeadline:Deadline() authorization:^BOOL{return YES;} error:nil]);CHECK(!ExecutionClosed);
        }else if(scenario==1){CHECK(![fence openContainerID:@"99" beforeDeadline:Deadline() authorization:^BOOL{return YES;} error:nil]);CHECK(ExecutionClosed);CheckSelected(snapshot,nil);}
        else if(scenario==2){__block NSUInteger calls=0;CHECK(![fence openContainerID:@"1" beforeDeadline:Deadline() authorization:^BOOL{return ++calls<3;} error:nil]);CHECK(ExecutionClosed);CheckSelected(snapshot,nil);}
        else if(scenario==3){CHECK(![fence openContainerID:@"1" beforeDeadline:Deadline() authorization:^BOOL{[fence closeAllBeforeDeadline:Deadline() error:nil];return YES;} error:nil]);CHECK(ExecutionClosed);CheckSelected(snapshot,nil);}
        else if(scenario==5){
            CHECK([fence openContainerID:@"1" beforeDeadline:Deadline() authorization:^BOOL{return YES;} error:nil]);CheckSelected(snapshot,@"1");
            // Simulate code admitted before a later failure, followed by an
            // unavailable process observation. Restrict future access, but
            // never claim the newly started process or its held FDs are gone.
            FailRestoreAfterOpening=YES;
            CHECK(![fence restoreExecutionBeforeDeadline:Deadline() authorization:^BOOL{return YES;} error:nil]);
            CHECK(ExecutionClosed);CheckSelected(snapshot,nil);
            CHECK([fence.safeStatus[@"phase"] isEqual:@"recovery-required"]);
            CHECK([fence.safeStatus[@"lastDrainVerified"] isEqual:@NO]);
            CHECK([fence.safeStatus[@"runtimeAccepted"] isEqual:@NO]);
            CHECK(![journal.currentRecord[@"payload"][@"phase"] isEqual:@"active"]);
            CHECK(![fence openContainerID:@"2" beforeDeadline:Deadline() authorization:^BOOL{return YES;} error:nil]);
        }
        [journal close];Cleanup(snapshot,base);
    }
    FailRestoreAfterOpening=NO;
    @autoreleasepool{NSString *base=Base();NSDictionary *snapshot=FixtureFor(base,@"com.facebook.Facebook");
        LBXNativeIsolationJournal *journal=[LBXNativeIsolationJournal testOpenDirectory:[base stringByAppendingPathComponent:@"Journal"] create:YES error:nil];CHECK(journal);
        LBXNativeStorageFence *fence=[LBXNativeStorageFence captureInventory:[LBXNativeStorageInventory fixture:snapshot] applicationGate:[LBXNativeApplicationGate fixture] journal:journal error:nil];
        CHECK(fence&&[fence.safeStatus[@"phase"] isEqual:@"captured"]&&[fence.safeStatus[@"runtimeAccepted"] isEqual:@NO]&&journal.currentRecord==nil);
        [journal close];Cleanup(snapshot,base);
    }
    RecoveryCases();
    printf("PASS %lu native storage fence checks (fixture process authority; real files/flags/journal)\n",(unsigned long)checks);return 0;
}}
