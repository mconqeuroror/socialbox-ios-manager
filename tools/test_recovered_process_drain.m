#import "../lucid/Switching/LBXProcessDrain.h"
#import <objc/runtime.h>
#include <stdio.h>
#include <math.h>

static unsigned Checks, Failures;
static BOOL FoundationVarAlias;
static IMP OriginalStandardize;
static NSString *FakeStandardize(id self, SEL selector) {
    NSString *standard=((NSString *(*)(id,SEL))OriginalStandardize)(self,selector);
    return FoundationVarAlias && [standard hasPrefix:@"/private/var/"] ? [standard substringFromIndex:8] : standard;
}
static NSString *const Bundle = @"/private/var/containers/Bundle/Application/11111111-1111-4111-8111-111111111111/Facebook.app";
static NSString *const Request = @"11111111-1111-4111-8111-111111111112";
static void Check(BOOL value, const char *message) { Checks++; if (!value) { Failures++; fprintf(stderr,"FAIL %s\n",message); } }
static LBXDrainProcess *Process(pid_t pid, long birth, NSString *path) {
    LBXDrainProcess *row = [LBXDrainProcess new]; RBXObservedProcess p = {0};
    p.pid = pid; p.startSeconds = birth; p.startMicroseconds = 123;
    strlcpy(p.executable, path.UTF8String, sizeof(p.executable)); row.identity = p; return row;
}
@interface Fixture : NSObject <LBXDrainBackend>
@property LBXDrainTarget *target;
@property NSArray *frames;
@property NSMutableArray *stops;
@property unsigned snapshots, resolutions, pauses, changeAt, stopChangedAt, pauseFailsAt;
@property double now, step, resolveDelay, snapshotDelay;
@property BOOL freeze, badClock, deny, disappear, throws, badTarget;
@end
@implementation Fixture
- (instancetype)init { if ((self=[super init])) {
    _target=[LBXDrainTarget new]; _target.bundleID=@"com.facebook.Facebook"; _target.bundlePath=Bundle;
    _target.executables=@[[Bundle stringByAppendingPathComponent:@"Facebook"],
        [Bundle stringByAppendingPathComponent:@"PlugIns/Share.appex/Share"]]; _target.fingerprint=@"registration-v1";
    _frames=@[@[]]; _stops=[NSMutableArray array]; _step=0.03; _now=100;
} return self; }
- (LBXDrainTarget *)resolve:(NSString *)bundleID error:(NSError **)error {
    (void)bundleID;(void)error; _resolutions++; _now += _resolveDelay;
    if (_throws) [NSException raise:@"test" format:@"backend failure"];
    if (_badTarget) return nil;
    if (_changeAt && _resolutions>=_changeAt) _target.fingerprint=@"registration-v2";
    return _target;
}
- (NSArray *)snapshot:(NSError **)error { (void)error;
    id frame = _frames[MIN(_snapshots, _frames.count-1)]; _snapshots++; _now+=_snapshotDelay;
    return frame==NSNull.null ? nil : frame;
}
- (RBXProcessIdentityResult)terminate:(RBXObservedProcess)p {
    [_stops addObject:@(p.pid)];
    if (_stopChangedAt && _stops.count==_stopChangedAt) return RBXProcessChanged;
    return _deny ? RBXProcessDenied : _disappear ? RBXProcessGone : RBXProcessTerminationRequested;
}
- (double)monotonicTime { return _badClock ? NAN : _now; }
- (BOOL)pause { _pauses++; if (!_freeze) _now+=_step; return !_pauseFailsAt || _pauses<_pauseFailsAt; }
@end

static NSDictionary *Run(Fixture *f, BOOL drain) { return LBXDrainApplication(f,@"com.facebook.Facebook",Request,0.3,drain); }
static BOOL Reason(NSDictionary *r, NSString *value) { return [r[@"reason"] isEqual:value]; }
static void NoAuthority(NSDictionary *r) {
    Check([r[@"networkFenced"] isEqual:@NO] && [r[@"launchesFenced"] isEqual:@NO] &&
        [r[@"reusableAdmission"] isEqual:@NO], "receipt never claims a network/launch fence or reusable authority");
}
int main(void) { @autoreleasepool {
    Method standardizer=class_getInstanceMethod(NSString.class,@selector(stringByStandardizingPath));
    OriginalStandardize=method_setImplementation(standardizer,(IMP)FakeStandardize);
    Fixture *f=[Fixture new]; NSDictionary *r=Run(f,YES);
    Check([r[@"status"] isEqual:@"observed_absent"] && f.snapshots==2 && f.pauses==1 && f.stops.count==0,
          "already absent needs two complete separated snapshots and no termination"); NoAuthority(r);
    Check([r[@"requestID"] isEqual:Request] && [r[@"registrationFingerprint"] isEqual:@"registration-v1"],"receipt binds request and registration");
    LBXDrainProcess *main=Process(30001,42,f.target.executables[0]), *extension=Process(30002,43,f.target.executables[1]);
    LBXDrainProcess *unrelated=Process(30003,44,@"/private/var/containers/Bundle/Application/other/Other.app/Facebook");
    f=[Fixture new]; f.frames=@[@[main,extension,unrelated],@[unrelated],@[unrelated]]; r=Run(f,YES);
    Check([r[@"status"] isEqual:@"observed_absent"] && [f.stops isEqual:@[@30001,@30002]] &&
        [r[@"terminationRequests"] isEqual:@2],"exact main and extension stopped; same-name unrelated app untouched"); NoAuthority(r);
    Check([r[@"observedProcesses"] count]==2,"receipt records both original birth identities");
    f=[Fixture new]; f.frames=@[@[main]]; r=Run(f,NO);
    Check([r[@"status"] isEqual:@"observed_running"] && !f.stops.count,"inspect never terminates a running app");
    f=[Fixture new]; f.frames=@[@[main]]; r=Run(f,YES);
    Check(Reason(r,@"deadline_exceeded") && f.stops.count==1 && f.snapshots>1,"termination request is not proof of exit; timeout without repeated kills");
    f=[Fixture new]; f.frames=@[@[main],NSNull.null]; r=Run(f,YES);
    Check(Reason(r,@"enumeration_failed") && [r[@"status"] isEqual:@"failed"],"lost enumeration after termination cannot report absence");
    f=[Fixture new]; f.frames=@[NSNull.null]; r=Run(f,YES);
    Check(Reason(r,@"enumeration_failed") && !f.stops.count,"enumeration denied before drain has no side effect");
    f=[Fixture new]; f.frames=@[@[main],@[Process(30001,99,f.target.executables[0])]]; r=Run(f,YES);
    Check(Reason(r,@"relaunch_detected") && f.stops.count==1,"same PID new birth detected; never killed under old authority");
    f=[Fixture new]; f.frames=@[@[main],@[Process(30005,99,f.target.executables[0])]]; r=Run(f,YES);
    Check(Reason(r,@"relaunch_detected"),"new PID relaunch prevents absent receipt");
    f=[Fixture new]; f.frames=@[@[main],@[],@[Process(30005,99,f.target.executables[1])]]; r=Run(f,YES);
    Check(Reason(r,@"relaunch_detected"),"extension launch between two empty checks rejected");
    f=[Fixture new]; f.frames=@[@[main,extension]]; f.stopChangedAt=1; r=Run(f,YES);
    Check(Reason(r,@"process_identity_changed") && f.stops.count==1,"stop identity change aborts whole batch before other stops");
    f=[Fixture new]; f.frames=@[@[main,extension]]; f.deny=YES; r=Run(f,YES);
    Check(Reason(r,@"termination_denied") && f.stops.count==1,"task right denial aborts with no PID/name fallback");
    f=[Fixture new]; f.frames=@[@[main],@[],@[]]; f.disappear=YES; r=Run(f,YES);
    Check([r[@"status"] isEqual:@"observed_absent"] && [r[@"terminationRequests"] isEqual:@0],"natural exit still requires fresh absent observations");
    f=[Fixture new]; f.frames=@[@[main]]; f.changeAt=3; r=Run(f,YES);
    Check(Reason(r,@"registration_changed") && !f.stops.count,"bundle changed before signal blocks termination");
    f=[Fixture new]; f.changeAt=4; r=Run(f,YES);
    Check(Reason(r,@"registration_changed"),"registration changed after final snapshot blocks receipt");
    f=[Fixture new]; f.frames=@[@[main]]; f.resolveDelay=0.11; r=Run(f,YES);
    Check(Reason(r,@"deadline_exceeded") && !f.stops.count,"slow registration recheck must not allow a late termination");
    for(NSNumber *drain in @[@NO,@YES]){
        f=[Fixture new];f.frames=@[@[main]];f.snapshotDelay=.31;r=Run(f,drain.boolValue);
        Check(Reason(r,@"deadline_exceeded")&&f.snapshots==1&&!f.stops.count&&!f.pauses,
            "slow complete snapshot consumes request deadline before inspect result or termination");
    }
    f=[Fixture new];f.snapshotDelay=.31;r=Run(f,YES);
    Check(Reason(r,@"deadline_exceeded")&&f.snapshots==1&&!f.pauses,"slow empty snapshot cannot begin absent-observation sequence after deadline");
    f=[Fixture new];f.frames=@[NSNull.null];f.snapshotDelay=.31;r=Run(f,YES);
    Check(Reason(r,@"deadline_exceeded")&&!f.stops.count,"failed enumeration retries still consume the original deadline");
    f=[Fixture new];f.snapshotDelay=-.1;r=Run(f,YES);
    Check(Reason(r,@"clock_failed")&&f.snapshots==1&&!f.pauses,"backward clock during snapshot refuses result immediately");
    f=[Fixture new];f.snapshotDelay=.02;r=Run(f,YES);
    Check([r[@"status"] isEqual:@"observed_absent"]&&fabs([r[@"elapsedSeconds"] doubleValue]-.07)<.00001,
        "successful absent receipt accounts for both complete snapshot durations");
    f=[Fixture new]; f.freeze=YES; f.frames=@[@[main]]; r=Run(f,YES);
    Check(Reason(r,@"observation_limit") && f.snapshots==256 && f.stops.count==1,"frozen monotonic source has independent iteration cap");
    f=[Fixture new]; f.badClock=YES; r=Run(f,YES);
    Check(Reason(r,@"clock_failed") && !f.resolutions,"unavailable monotonic clock blocks operation");
    f=[Fixture new]; f.step=-1; r=Run(f,YES); Check(Reason(r,@"clock_failed"),"backward clock rejected");
    f=[Fixture new]; f.pauseFailsAt=1; r=Run(f,YES); Check(Reason(r,@"pause_failed"),"interrupted pause exhaustion blocks success");
    f=[Fixture new]; f.throws=YES; r=Run(f,YES); Check(Reason(r,@"backend_exception"),"backend exception becomes failed receipt");
    f=[Fixture new]; f.badTarget=YES; r=Run(f,YES); Check(Reason(r,@"registration_failed"),"missing registration never falls back to names");
    for (NSString *identifier in @[@"com.apple.springboard",@"com.socialbox.app",@"com.redditbox.launcher",@"socialbox.profile.fb.p1",@"Facebook",@"com.facebook.Facebook.evil"]) {
        f=[Fixture new]; r=LBXDrainApplication(f,identifier,Request,0.3,YES);
        Check(Reason(r,@"invalid_request") && !f.resolutions && !f.stops.count,"unregistered/protected family rejected before backend");
    }
    for (NSNumber *timeout in @[@0,@(-1),@(INFINITY),@(NAN),@6]) {
        f=[Fixture new]; r=LBXDrainApplication(f,@"com.facebook.Facebook",Request,timeout.doubleValue,YES);
        Check(Reason(r,@"invalid_request") && !f.resolutions,"invalid timeout rejected");
    }
    for (NSString *request in @[@"",@"bad",@"../../file"]) {
        f=[Fixture new]; r=LBXDrainApplication(f,@"com.facebook.Facebook",request,0.3,YES);
        Check(Reason(r,@"invalid_request") && !f.resolutions,"invalid request identifier rejected");
    }
    for (NSArray *frame in @[@[main,main], @[@"bad"], @[Process(1,42,f.target.executables[0])],
        @[Process(30001,0,f.target.executables[0])], @[Process(30001,42,@"relative")],
        @[Process(30001,42,[Bundle stringByAppendingPathComponent:@"unregistered-helper"])]]) {
        f=[Fixture new]; f.frames=@[frame]; r=Run(f,YES);
        Check([r[@"status"] isEqual:@"failed"] && !f.stops.count,"malformed or unknown in-bundle process fails before any batch side effect");
    }
    // Kernel paths commonly use /var while LaunchServices resolves /private/var.
    // Normalize this known alias for matching, retain raw identity for task checks.
    f=[Fixture new]; NSString *alias=[f.target.executables[0] substringFromIndex:8];
    f.frames=@[@[Process(30001,42,alias)],@[],@[]]; r=Run(f,YES);
    Check(f.stops.count==1 && [r[@"status"] isEqual:@"observed_absent"],"known /var alias matches exact registered executable");
    FoundationVarAlias=YES;
    Check([Bundle.stringByStandardizingPath hasPrefix:@"/var/"],"fixture reproduces iOS Foundation standardization shortening private var");
    f=[Fixture new];f.frames=@[@[main,extension],@[],@[]];r=Run(f,YES);
    Check([r[@"status"] isEqual:@"observed_absent"]&&[f.stops isEqual:@[@30001,@30002]],"Foundation canonical alias retains exact main and extension process authority");NoAuthority(r);
    f=[Fixture new];f.frames=@[@[main]];r=Run(f,NO);
    Check([r[@"status"] isEqual:@"observed_running"]&&!f.stops.count,"inspection stays read-only under Foundation alias standardization");
    for(NSString *path in @[[Bundle stringByAppendingString:@"//Facebook"],[Bundle stringByAppendingString:@"/../Facebook"],[Bundle stringByAppendingString:@"/./Facebook"]]){
        f=[Fixture new];f.target.executables=@[path];r=Run(f,YES);
        Check(Reason(r,@"registration_failed")&&!f.stops.count&&!f.snapshots,"normalization still rejects noncanonical target paths before process effects");
    }
    f=[Fixture new];f.frames=@[@[Process(30001,42,[Bundle stringByAppendingString:@"/../Facebook"])]];r=Run(f,YES);
    Check(Reason(r,@"invalid_process_snapshot")&&!f.stops.count,"process traversal remains rejected under Foundation alias normalization");
    printf("%s recovered drain: %u assertions, %u failures; mocked processes, no real termination\n",Failures?"FAIL":"PASS",Checks,Failures);
    return Failures?1:0;
}}
