#import "../Switching/LBXNativeApplicationGate.h"
#import "../Switching/LBXInstalledApplicationBinding.h"
#import "../Switching/LBXNativeIsolationJournal.h"
#include <sys/wait.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>
static NSUInteger checks,failures;
static void Check(BOOL valid,NSString *why){checks++;if(!valid){failures++;fprintf(stderr,"FAIL: %s\n",why.UTF8String);}}
#if LBX_NATIVE_APPLICATION_GATE_TESTING
@interface GateBackend:NSObject<LBXDrainBackend>
@property(nonatomic,strong)NSMutableArray *rows;
@property(nonatomic)NSUInteger snapshots,kills;
@property(nonatomic)BOOL enumerationFails,terminationFails,relaunch;
@property(nonatomic,copy)void(^atSnapshot)(void);
@end
@implementation GateBackend
- (instancetype)init{if((self=[super init]))_rows=[NSMutableArray array];return self;}
- (LBXDrainTarget *)resolve:(NSString *)bundle error:(NSError **)error{(void)bundle;(void)error;Check(NO,@"captured verifier must replace ordinary X_OK resolver");return nil;}
- (NSArray *)snapshot:(NSError **)error{(void)error;_snapshots++;if(_atSnapshot)_atSnapshot();if(_enumerationFails)return nil;return [_rows copy];}
- (RBXProcessIdentityResult)terminate:(RBXObservedProcess)identity{_kills++;if(_terminationFails)return RBXProcessDenied;for(LBXDrainProcess *p in [_rows copy])if(p.identity.pid==identity.pid){[_rows removeObject:p];if(_relaunch){RBXObservedProcess next=identity;next.startSeconds++;p.identity=next;[_rows addObject:p];}}return RBXProcessTerminationRequested;}
- (double)monotonicTime{return LBXNativeApplicationGateClock();}
- (BOOL)pause{usleep(1000);return YES;}
@end
@interface GateFixture:NSObject
@property(nonatomic,copy)NSString *base,*root,*bundle,*main,*extension,*readOnly,*plugins,*plist;
@property(nonatomic,copy)NSDictionary *registration;
@property(nonatomic,strong)GateBackend *backend;
@end
@implementation GateFixture @end
static BOOL Directory(NSString *p){return [NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil]&&chmod(p.fileSystemRepresentation,0755)==0;}
static BOOL Bytes(NSString *p,NSData *bytes,mode_t mode){return [bytes writeToFile:p atomically:NO]&&chmod(p.fileSystemRepresentation,mode)==0;}
static BOOL Info(NSString *dir,NSString *identifier,NSString *name){return [@{@"CFBundleIdentifier":identifier,@"CFBundleExecutable":name,@"CFBundleVersion":@"1",@"CFBundleShortVersionString":@"1",@"NSExtension":@{@"NSExtensionPointIdentifier":@"com.apple.share-services"}} writeToFile:[dir stringByAppendingPathComponent:@"Info.plist"] atomically:NO];}
static mode_t Mode(NSString *p){struct stat s;return !lstat(p.fileSystemRepresentation,&s)?s.st_mode&07777:0xffff;}
static BOOL Closed(GateFixture *f){return Mode(f.main)==0644&&Mode(f.extension)==0644&&Mode(f.readOnly)==0644;}
static double Deadline(void){return LBXNativeApplicationGateClock()+30;}
static GateFixture *Fixture(void){char temporary[]="/private/var/tmp/socialbox-launch-gate.XXXXXX",physical[PATH_MAX];if(!mkdtemp(temporary)||!realpath(temporary,physical))return nil;
    if(chown(physical,geteuid(),getegid()))return nil;GateFixture *f=[GateFixture new];f.base=@(physical);f.root=[f.base stringByAppendingPathComponent:@"Application"];f.bundle=[f.root stringByAppendingPathComponent:@"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA/Instagram.app"];
    f.main=[f.bundle stringByAppendingPathComponent:@"Instagram"];f.plist=[f.bundle stringByAppendingPathComponent:@"Info.plist"];f.plugins=[f.bundle stringByAppendingPathComponent:@"PlugIns"];
    NSString *ext=[f.plugins stringByAppendingPathComponent:@"Share.appex"],*ro=[f.plugins stringByAppendingPathComponent:@"Readonly.appex"];
    f.extension=[ext stringByAppendingPathComponent:@"Share"];f.readOnly=[ro stringByAppendingPathComponent:@"Readonly"];
    NSData *bytes=[@"genuine owned fixture binary bytes\n" dataUsingEncoding:NSUTF8StringEncoding];
    BOOL ok=Directory(f.bundle)&&Info(f.bundle,@"com.burbn.instagram",@"Instagram")&&Bytes(f.main,bytes,0755)&&Directory(ext)&&Info(ext,@"com.burbn.instagram.share",@"Share")&&Bytes(f.extension,bytes,0755)&&Directory(ro)&&Info(ro,@"com.burbn.instagram.readonly",@"Readonly")&&Bytes(f.readOnly,bytes,0644);
    if(!ok)return nil;f.registration=@{@"bundlePath":f.bundle,@"canonicalExecutablePath":f.main};f.backend=[GateBackend new];
    [LBXInstalledApplicationBinding testUseRegistration:f.registration installationRoot:f.root];[LBXNativeApplicationGate testUseBackend:f.backend registration:f.registration];return f;
}
static GateFixture *FacebookFixture(void){char temporary[]="/private/var/tmp/socialbox-launch-gate-facebook.XXXXXX",physical[PATH_MAX];if(!mkdtemp(temporary)||!realpath(temporary,physical))return nil;
    if(chown(physical,geteuid(),getegid()))return nil;GateFixture *f=[GateFixture new];f.base=@(physical);f.root=[f.base stringByAppendingPathComponent:@"Application"];f.bundle=[f.root stringByAppendingPathComponent:@"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA/Facebook.app"];
    f.main=[f.bundle stringByAppendingPathComponent:@"Facebook"];f.plist=[f.bundle stringByAppendingPathComponent:@"Info.plist"];f.plugins=[f.bundle stringByAppendingPathComponent:@"PlugIns"];
    NSString *ext=[f.plugins stringByAppendingPathComponent:@"Share.appex"];
    f.extension=[ext stringByAppendingPathComponent:@"Share"];f.readOnly=f.extension;
    NSData *bytes=[@"genuine owned facebook fixture binary bytes\n" dataUsingEncoding:NSUTF8StringEncoding];
    BOOL ok=Directory(f.bundle)&&Info(f.bundle,@"com.facebook.Facebook",@"Facebook")&&Bytes(f.main,bytes,0755)&&Directory(ext)&&Info(ext,@"com.facebook.Facebook.share",@"Share")&&Bytes(f.extension,bytes,0755);
    if(!ok)return nil;f.registration=@{@"bundlePath":f.bundle,@"canonicalExecutablePath":f.main};f.backend=[GateBackend new];
    [LBXInstalledApplicationBinding testUseRegistration:f.registration installationRoot:f.root];[LBXNativeApplicationGate testUseBackend:f.backend registration:f.registration];return f;
}
static LBXNativeApplicationGate *Capture(GateFixture *f){NSError *error=nil;LBXNativeApplicationGate *g=[LBXNativeApplicationGate captureOfficialInstagramBeforeDeadline:Deadline() error:&error];Check(g&&!error,@"capture genuine pinned filesystem installation without mode changes");Check(Mode(f.main)==0755&&Mode(f.extension)==0755&&Mode(f.readOnly)==0644,@"capture preserves all original executable modes");return g;}
static void Row(GateBackend *b,NSString *path,pid_t pid){LBXDrainProcess *p=[LBXDrainProcess new];RBXObservedProcess identity={0};identity.pid=pid;identity.startSeconds=123;identity.startMicroseconds=4;strlcpy(identity.executable,path.fileSystemRepresentation,sizeof(identity.executable));p.identity=identity;[b.rows addObject:p];}
static void Case(NSString *name,void(^body)(GateFixture *,LBXNativeApplicationGate *)){@autoreleasepool{GateFixture *f=Fixture();Check(f!=nil,@"test owns separate real filesystem tree");if(!f)return;LBXNativeApplicationGate *g=Capture(f);if(g)body(f,g);[LBXNativeApplicationGate testBeforeModeChange:nil];[LBXNativeApplicationGate testUseBackend:nil registration:nil];[LBXInstalledApplicationBinding testUseRegistration:nil installationRoot:nil];Check([NSFileManager.defaultManager removeItemAtPath:f.base error:nil],[name stringByAppendingString:@": private fixture cleanup"]);}}
static BOOL Immutable(id value){if([value isKindOfClass:NSDictionary.class]){BOOL immutable=NO;@try{[(NSMutableDictionary *)value setObject:@1 forKey:@"mutate"];}@catch(__unused NSException *e){immutable=YES;}if(!immutable)return NO;for(id key in value)if(!Immutable(value[key]))return NO;}else if([value isKindOfClass:NSArray.class]){BOOL immutable=NO;@try{[(NSMutableArray *)value addObject:@1];}@catch(__unused NSException *e){immutable=YES;}if(!immutable)return NO;for(id child in value)if(!Immutable(child))return NO;}return YES;}
#endif
int main(void){@autoreleasepool{
#if LBX_NATIVE_APPLICATION_GATE_TESTING
    @autoreleasepool{GateFixture *facebook=FacebookFixture();Check(facebook!=nil,@"Facebook gate owns a separate real filesystem tree");if(facebook){
        NSError *error=nil;LBXNativeApplicationGate *g=[LBXNativeApplicationGate captureOfficialFacebookBeforeDeadline:Deadline() error:&error];
        Check(g&&!error&&[g.privateJournalRecord[@"binding"][@"bundleIdentifier"] isEqual:@"com.facebook.Facebook"]&&[g.safeStatus[@"runtimeAccepted"] isEqual:@NO],@"Facebook gate captures official Facebook without runtime admission");
        Check(![LBXNativeApplicationGate captureOfficialInstagramBeforeDeadline:Deadline() error:&error],@"Instagram gate cannot adopt a Facebook installation");
        Check([g closeAndDrainBeforeDeadline:Deadline() error:&error]&&Mode(facebook.main)==0644&&Mode(facebook.extension)==0644,@"Facebook drain closes Facebook executables only");
        [LBXNativeApplicationGate testUseBackend:nil registration:nil];[LBXInstalledApplicationBinding testUseRegistration:nil installationRoot:nil];
        Check([NSFileManager.defaultManager removeItemAtPath:facebook.base error:nil],@"Facebook gate fixture cleanup");
    }}
    @autoreleasepool{GateFixture *instagram=Fixture();Check(instagram!=nil,@"Instagram fixture for Facebook gate mismatch");if(instagram){
        NSError *error=nil;Check(![LBXNativeApplicationGate captureOfficialFacebookBeforeDeadline:Deadline() error:&error],@"Facebook gate cannot adopt an Instagram installation");
        [LBXNativeApplicationGate testUseBackend:nil registration:nil];[LBXInstalledApplicationBinding testUseRegistration:nil installationRoot:nil];
        Check([NSFileManager.defaultManager removeItemAtPath:instagram.base error:nil],@"Instagram mismatch fixture cleanup");
    }}
    Case(@"successful drain and restoration",^(GateFixture *f,LBXNativeApplicationGate *g){NSError *error=nil;NSData *before=[NSData dataWithContentsOfFile:f.main];NSDictionary *journal=g.privateJournalRecord;
        Check(Immutable(journal)&&[journal[@"executables"] count]==3,@"journal recursively immutable with every original executable record");
        Check(![g.description containsString:f.base]&&[g.safeStatus[@"runtimeAccepted"] isEqual:@NO],@"safe status omits paths and does not claim isolation");
        Check(![LBXNativeApplicationGate captureOfficialInstagramBeforeDeadline:Deadline() error:&error],@"competing held execution gate excluded by inode lock");
        Row(f.backend,f.main,42420);Row(f.backend,f.extension,42421);Row(f.backend,@"/outside/Instagram",42422);
        __block BOOL snapshotsClosed=YES;f.backend.atSnapshot=^{snapshotsClosed=snapshotsClosed&&Closed(f);};
        Check([g closeAndDrainBeforeDeadline:Deadline() error:&error]&&!error&&Closed(f),@"checked closure and process drain succeeds across main and extensions");
        Check(snapshotsClosed&&f.backend.kills==2&&f.backend.rows.count==1&&f.backend.snapshots>=3,@"exact targets drained only after all execution bits closed; outside same-name retained");
        Check(![LBXInstalledApplicationBinding observeOfficialInstagram:&error],@"ordinary X_OK binding cannot manufacture observation while gated");
        f.backend.atSnapshot=nil;__block NSUInteger authorized=0;
        Check([g restoreExecutionBeforeDeadline:Deadline() authorization:^BOOL{authorized++;return YES;} error:&error]&&!error,@"fresh absence plus synchronous authorization restores captured modes");
        Check(authorized>=7&&Mode(f.main)==0755&&Mode(f.extension)==0755&&Mode(f.readOnly)==0644,@"restoration preserves readonly extension and checks every step");
        Check([[NSData dataWithContentsOfFile:f.main] isEqual:before]&&[g.privateJournalRecord isEqual:journal],@"code bytes and original journal never rewritten");
    });
    for(NSString *kind in @[@"denied",@"exception",@"revoked",@"reentrant",@"running",@"expired"])
        Case(kind,^(GateFixture *f,LBXNativeApplicationGate *g){NSError *error=nil;Check([g closeAndDrainBeforeDeadline:Deadline() error:&error],@"precondition closed and absent");if([kind isEqual:@"running"])Row(f.backend,f.main,42420);__block NSUInteger calls=0;
            BOOL ok=[g restoreExecutionBeforeDeadline:[kind isEqual:@"expired"]?LBXNativeApplicationGateClock()-1:Deadline() authorization:^BOOL{calls++;if([kind isEqual:@"exception"])[NSException raise:@"fixture" format:@"private"];if([kind isEqual:@"reentrant"])[g closeExecutionBeforeDeadline:Deadline() error:nil];return ![kind isEqual:@"denied"]&&(![kind isEqual:@"revoked"]||calls<3);} error:&error];
            Check(!ok&&error&&Closed(f),@"denial exception revocation running process expiry or reentrancy never leaves executable open");Check(f.backend.kills==0,@"restore inspection never kills newly running process");
        });
    Case(@"process starts during failed admission",^(GateFixture *f,LBXNativeApplicationGate *g){NSError *error=nil;Check([g closeAndDrainBeforeDeadline:Deadline() error:&error],@"admission failure fixture starts closed and absent");
        __block BOOL started=NO;BOOL restored=[g restoreExecutionBeforeDeadline:Deadline() authorization:^BOOL{if(Mode(f.main)&0111){started=YES;Row(f.backend,f.main,42420);return NO;}return YES;} error:&error];
        Check(started&&!restored&&Closed(f)&&f.backend.rows.count==1,@"resealing after partial admission does not impersonate process absence");
        Check([g closeAndDrainBeforeDeadline:Deadline() error:&error]&&f.backend.kills==1&&f.backend.rows.count==0,@"owner can drain again before touching storage after admission failure");
    });
    for(NSString *kind in @[@"enumeration",@"termination",@"relaunch"])
        Case(kind,^(GateFixture *f,LBXNativeApplicationGate *g){NSError *error=nil;Row(f.backend,f.main,42420);f.backend.enumerationFails=[kind isEqual:@"enumeration"];f.backend.terminationFails=[kind isEqual:@"termination"];f.backend.relaunch=[kind isEqual:@"relaunch"];Check(![g closeAndDrainBeforeDeadline:Deadline() error:&error]&&error&&Closed(f),@"failed drain always keeps retained execution modes closed");Check([error.userInfo[@"stage"] hasPrefix:@"process-drain:"]&&![error.description containsString:f.base],@"drain refusal retains its safe fixed reason without process paths");});
    for(NSString *kind in @[@"replacement",@"symlink",@"ancestor",@"hardlink",@"plist",@"plugin",@"registration",@"permissions"])
        Case(kind,^(GateFixture *f,LBXNativeApplicationGate *g){NSError *error=nil;Check([g closeExecutionBeforeDeadline:Deadline() error:&error],@"drift begins from verified closed gate");NSString *retained=[f.base stringByAppendingPathComponent:@"retained"];BOOL changed=NO;
            if([kind isEqual:@"replacement"]||[kind isEqual:@"symlink"]){NSData *data=[NSData dataWithContentsOfFile:f.main];changed=!rename(f.main.fileSystemRepresentation,retained.fileSystemRepresentation);changed=changed&&([kind isEqual:@"symlink"]?!symlink(retained.fileSystemRepresentation,f.main.fileSystemRepresentation):Bytes(f.main,data,0755));}
            if([kind isEqual:@"ancestor"]){changed=!rename(f.bundle.fileSystemRepresentation,retained.fileSystemRepresentation)&&!symlink(retained.fileSystemRepresentation,f.bundle.fileSystemRepresentation);}
            if([kind isEqual:@"hardlink"])changed=!link(f.main.fileSystemRepresentation,retained.fileSystemRepresentation);
            if([kind isEqual:@"plist"])changed=Bytes(f.plist,[@"changed property-list" dataUsingEncoding:NSUTF8StringEncoding],0644);
            if([kind isEqual:@"plugin"])changed=Directory([f.plugins stringByAppendingPathComponent:@"Late.appex"]);
            if([kind isEqual:@"registration"]){[LBXNativeApplicationGate testUseBackend:f.backend registration:@{@"bundlePath":f.bundle,@"canonicalExecutablePath":f.extension}];changed=YES;}
            if([kind isEqual:@"permissions"])changed=!chmod(f.main.fileSystemRepresentation,0400);
            Check(changed,@"adverse real filesystem or registration mutation occurred");Check(![g restoreExecutionBeforeDeadline:Deadline() authorization:^BOOL{return YES;} error:&error]&&error,@"binding drift refuses execution restoration");
            if([kind isEqual:@"replacement"])Check(Mode(f.main)==0755&&Mode(retained)==0644,@"emergency closure touches held old inode only, never replacement");
            if([kind isEqual:@"permissions"])Check(Mode(f.main)==0400,@"emergency closure cannot broaden read/write permissions");
            if([kind isEqual:@"symlink"])Check(Mode(retained)==0644,@"symlink path cannot redirect restoration");
        });
    Case(@"foreign execute mode cannot be laundered by resealing",^(GateFixture *f,LBXNativeApplicationGate *g){NSError *error=nil;Check([g closeExecutionBeforeDeadline:Deadline() error:&error],@"foreign mode fixture starts closed");Check(!chmod(f.main.fileSystemRepresentation,0755),@"external actor actually restored execution bits");
        Check(![g closeExecutionBeforeDeadline:Deadline() error:&error]&&Closed(f),@"known inode emergency resealed while foreign change is refused");
        Check(![g restoreExecutionBeforeDeadline:Deadline() authorization:^BOOL{return YES;} error:&error]&&Closed(f)&&[g.safeStatus[@"bindingInvalidated"] isEqual:@YES],@"same object cannot erase foreign mode evidence through a later restore");
    });
    for(NSString *kind in @[@"close-failure",@"close-exception",@"restore-failure",@"restore-exception"])
        Case(kind,^(GateFixture *f,LBXNativeApplicationGate *g){NSError *error=nil;BOOL restore=[kind hasPrefix:@"restore"];if(restore)Check([g closeExecutionBeforeDeadline:Deadline() error:&error],@"failure restore starts from closed execution");__block BOOL injected=NO;
            [LBXNativeApplicationGate testBeforeModeChange:^BOOL(NSString *path,mode_t mode){if(!injected&&[path isEqual:f.main]&&(!restore||(mode&0111))){injected=YES;if([kind hasSuffix:@"exception"])[NSException raise:@"fixture" format:@"injected"];return NO;}return YES;}];
            BOOL result=restore?[g restoreExecutionBeforeDeadline:Deadline() authorization:^BOOL{return YES;} error:&error]:[g closeExecutionBeforeDeadline:Deadline() error:&error];
            Check(injected&&!result&&error,@"actual mode boundary failure cannot report successful gate operation");Check(Mode(f.extension)==0644&&Mode(f.readOnly)==0644,@"later captured executables still receive emergency closure attempts");if(restore)Check(Closed(f),@"partial restore failure reseals every executable");
            [LBXNativeApplicationGate testBeforeModeChange:nil];Check([g closeExecutionBeforeDeadline:Deadline() error:&error]&&Closed(f),@"explicit retry can finish closure after transient syscall seam failure");
        });
    @autoreleasepool{GateFixture *f=Fixture();Check(f!=nil,@"deallocation fixture exists");@autoreleasepool{LBXNativeApplicationGate *g=Capture(f);Check([g closeExecutionBeforeDeadline:Deadline() error:nil],@"deallocation starts closed");}Check(Closed(f),@"deallocation does not automatically restore execution");[NSFileManager.defaultManager removeItemAtPath:f.base error:nil];}
    for(NSString *kind in @[@"closed",@"mixed",@"original",@"replacement",@"permissions",@"flags",@"plist",@"ancestor",@"plugin",@"journal-closed",@"journal-changed"]){@autoreleasepool{
        GateFixture *f=Fixture();Check(f!=nil,@"restart owns real installation and private journal tree");if(!f)continue;
        NSString *journalPath=[f.base stringByAppendingPathComponent:@"journal"];
        pid_t child=fork();if(child==0){@autoreleasepool{NSError *error=nil;LBXNativeApplicationGate *g=[LBXNativeApplicationGate captureOfficialInstagramBeforeDeadline:Deadline() error:&error];LBXNativeIsolationJournal *j=[LBXNativeIsolationJournal testOpenDirectory:journalPath create:YES error:&error];
            if(!g||!j||![j compareRecord:nil replaceWith:@{@"applicationGate":g.privateJournalRecord} error:&error]){fprintf(stderr,"child recovery setup failed gate=%d journal=%d error=%s\n",g!=nil,j!=nil,error.description.UTF8String);_exit(31);}
            if(![kind isEqual:@"original"]&&![g closeExecutionBeforeDeadline:Deadline() error:&error])_exit(32);
            if([kind isEqual:@"mixed"]&&chmod(f.extension.fileSystemRepresentation,0755))_exit(33);
            _exit(0);}}
        int status=0;Check(child>0&&waitpid(child,&status,0)==child&&WIFEXITED(status)&&WEXITSTATUS(status)==0,@"actual child exits with durable original binding and un-restored mode state");
        NSError *error=nil;LBXNativeIsolationJournal *journal=[LBXNativeIsolationJournal testOpenDirectory:journalPath create:NO error:&error];Check(journal&&!error,@"fresh process handle validates persisted root-private journal");
        BOOL adverse=![@[@"closed",@"mixed",@"original"] containsObject:kind],changed=!adverse;
        NSString *retained=[f.base stringByAppendingPathComponent:@"retained"];
        if([kind isEqual:@"replacement"]){NSData *data=[NSData dataWithContentsOfFile:f.main];changed=!rename(f.main.fileSystemRepresentation,retained.fileSystemRepresentation)&&Bytes(f.main,data,0644);}
        if([kind isEqual:@"permissions"])changed=!chmod(f.main.fileSystemRepresentation,0600);
        if([kind isEqual:@"flags"])changed=!chflags(f.main.fileSystemRepresentation,UF_HIDDEN);
        if([kind isEqual:@"plist"])changed=Bytes(f.plist,[@"different plist bytes" dataUsingEncoding:NSUTF8StringEncoding],0644);
        if([kind isEqual:@"ancestor"])changed=!chmod(f.bundle.fileSystemRepresentation,0700);
        if([kind isEqual:@"plugin"])changed=Directory([f.plugins stringByAppendingPathComponent:@"Late.appex"]);
        if([kind isEqual:@"journal-closed"]){[journal close];changed=YES;}
        if([kind isEqual:@"journal-changed"]){NSString *record=[journalPath stringByAppendingPathComponent:@"record.json"];changed=Bytes(record,[@"{}" dataUsingEncoding:NSUTF8StringEncoding],0600);}
        Check(changed,@"restart adverse state was actually applied");mode_t before=Mode(f.main);
        LBXNativeApplicationGate *recovered=[LBXNativeApplicationGate recoverFromJournal:journal beforeDeadline:Deadline() error:&error];
        Check(Mode(f.main)==before,@"recovery observation never temporarily enables execution");
        if(adverse)Check(!recovered&&error,@"foreign inode mode flags metadata inventory or stale journal cannot recover authority");
        else{Check(recovered&&!error,@"durable original or gated or partially gated state reconstructs retained descriptors");if(recovered){Check([recovered closeAndDrainBeforeDeadline:Deadline() error:&error]&&Closed(f),@"recovered exact inodes close and drain through expected gate modes");Check([recovered restoreExecutionBeforeDeadline:Deadline() authorization:^BOOL{return YES;} error:&error]&&Mode(f.main)==0755&&Mode(f.extension)==0755&&Mode(f.readOnly)==0644,@"explicit authorized recovery restores exact original modes only");}}
        [journal close];if([kind isEqual:@"flags"])chflags(f.main.fileSystemRepresentation,0);
        Check([NSFileManager.defaultManager removeItemAtPath:f.base error:nil],@"restart fixture and journal cleanup");
    }}
#if LBX_PRIVATE_GATE_ABORT_RECOVERY
    for(NSString *kind in @[@"success",@"wrong-component",@"spawn-started",@"spawn-error",@"storage-changed",@"selection-changed",@"denied",@"revoked",@"exception"]){@autoreleasepool{
        GateFixture *f=Fixture();Check(f!=nil,@"abort fixture owns exact code tree");if(!f)continue;NSError *error=nil;NSString *directory=[f.base stringByAppendingPathComponent:@"probe-journal"];
        LBXNativeIsolationJournal *journal=[LBXNativeIsolationJournal testOpenDirectory:directory create:YES error:&error];Check(journal&&!error,@"abort has real locked durable journal");
        @autoreleasepool{LBXNativeApplicationGate *gate=Capture(f);NSMutableDictionary *payload=[@{@"component":@"native-application-gate-probe",@"formatVersion":@1,@"applicationGate":gate.privateJournalRecord,@"phase":@"prepared",@"acceptance":@"FAIL",@"spawnErrno":@(-1),@"probeAccountFileContentsRead":@NO,@"storagePermissionsChanged":@NO,@"selectionChanged":@NO} mutableCopy];
            if([kind isEqual:@"wrong-component"])payload[@"component"]=@"native-storage-fence";
            if([kind isEqual:@"spawn-started"])payload[@"phase"]=@"spawn-check-pending";
            if([kind isEqual:@"spawn-error"])payload[@"spawnErrno"]=@(EACCES);
            if([kind isEqual:@"storage-changed"])payload[@"storagePermissionsChanged"]=@YES;
            if([kind isEqual:@"selection-changed"])payload[@"selectionChanged"]=@YES;
            Check([journal compareRecord:nil replaceWith:payload error:&error]&&[gate closeExecutionBeforeDeadline:Deadline() error:&error]&&Closed(f),@"prepared abort stores originals before closing actual code modes");
        }
        LBXNativeApplicationGate *gate=[LBXNativeApplicationGate recoverFromJournal:journal beforeDeadline:Deadline() error:&error];Check(gate&&!error,@"abort reconstructs exact private journal binding");f.backend.enumerationFails=YES;
        Check(![gate restoreExecutionBeforeDeadline:Deadline() authorization:^BOOL{return YES;} error:&error]&&Closed(f),@"normal restore still refuses missing complete process enumeration");
        __block NSUInteger calls=0;BOOL restored=[gate restoreOriginalExecutionForUnstartedProbe:journal beforeDeadline:Deadline() authorization:^BOOL{calls++;if([kind isEqual:@"exception"])[NSException raise:@"fixture" format:@"abort"];return ![kind isEqual:@"denied"]&&(![kind isEqual:@"revoked"]||calls<4);} error:&error];
        if([kind isEqual:@"success"]){Check(restored&&!error&&Mode(f.main)==0755&&Mode(f.extension)==0755&&Mode(f.readOnly)==0644,@"unstarted private probe restores only exact original code modes despite unavailable enumeration");
            Check([journal.currentRecord[@"payload"][@"phase"] isEqual:@"aborted-original-code-restored"]&&[journal.currentRecord[@"payload"][@"acceptance"] isEqual:@"FAIL"]&&[gate.safeStatus[@"runtimeAccepted"] isEqual:@NO],@"abort completion cannot masquerade as successful probe or runtime isolation");
            NSDictionary *completed=journal.currentRecord;Check([gate restoreOriginalExecutionForUnstartedProbe:journal beforeDeadline:Deadline() authorization:^BOOL{return YES;} error:&error]&&Mode(f.main)==0755&&[journal.currentRecord isEqual:completed],@"retry after completed abort validates original modes without resealing or journal mutation");}
        else Check(!restored&&error&&Closed(f),@"wrong component trial effects or failed authorization cannot use abort-only restoration");
        [journal close];Check([NSFileManager.defaultManager removeItemAtPath:f.base error:nil],@"abort fixture exact tree cleanup");
    }}
#endif
    [LBXNativeApplicationGate testUseBackend:nil registration:nil];[LBXInstalledApplicationBinding testUseRegistration:nil installationRoot:nil];
#else
    Check(![LBXNativeApplicationGate respondsToSelector:NSSelectorFromString(@"testUseBackend:registration:")],@"production excludes fixture backend and registration");
    Check(![LBXNativeApplicationGate respondsToSelector:NSSelectorFromString(@"testBeforeModeChange:")],@"production excludes mutation seam");
    Check(![LBXNativeApplicationGate instancesRespondToSelector:NSSelectorFromString(@"restoreOriginalExecutionForUnstartedProbe:beforeDeadline:authorization:error:")],@"normal production excludes private aborted-probe restoration");
    if(getuid()!=0||geteuid()!=0){NSError *error=nil;Check(![LBXNativeApplicationGate captureOfficialInstagramBeforeDeadline:LBXNativeApplicationGateClock()+10 error:&error]&&error,@"production requires real and effective root");
        Check(![LBXNativeApplicationGate captureOfficialFacebookBeforeDeadline:LBXNativeApplicationGateClock()+10 error:&error]&&error,@"Facebook production gate requires real and effective root");}
#endif
    NSLog(@"%@: %lu application gate assertions, %lu failures",failures?@"FAIL":@"PASS",(unsigned long)checks,(unsigned long)failures);return failures?1:0;
}}
