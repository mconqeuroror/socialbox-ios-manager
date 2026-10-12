#import <Foundation/Foundation.h>
#import "RBXAppProcessCoordinator.h"
#import "RBXOperationContext.h"
#import "RBXBoundedProcess.h"
#import "RBXAppRegistry.h"
#import "RBXStorageAccess.h"
static BOOL StorageCloseOK=YES,StorageOpenOK=YES;
@implementation RBXStorageAccess
+ (BOOL)ownsClosedHome:(NSString *)home bundleIdentifier:(NSString *)bundle error:(NSError **)error { return NO; }
+ (BOOL)closeAll:(NSError **)error { return StorageCloseOK; }
+ (BOOL)openProfile:(NSDictionary *)profile authorized:(BOOL (^)(void))authorized error:(NSError **)error { return StorageOpenOK&&authorized&&authorized(); }
@end

// Compile the real coordinator and controller, but override all mutating,
// observation and launch seams below. No real process is signalled or launched.
#import "../daemon/RBXProcessController.m"
#import "../daemon/RBXAppProcessCoordinator.m"

static RBXOperationContext *sContext;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RBXOperationContext
+ (RBXOperationContext *)currentContext { return sContext; }
@end
@implementation RBXBoundedProcess @end
#pragma clang diagnostic pop

@interface RBXCoordinatorTestContext : RBXOperationContext
@property(nonatomic) NSTimeInterval testDeadline;
@property(nonatomic) BOOL testCancelled;
@end
@implementation RBXCoordinatorTestContext
- (NSTimeInterval)deadlineMonotonic { return self.testDeadline; }
- (BOOL)isCancelled { return self.testCancelled; }
- (BOOL)check:(NSError **)error {
    if (self.testCancelled && error) *error = [NSError errorWithDomain:@"test" code:1 userInfo:nil];
    return !self.testCancelled;
}
@end

@interface RBXCoordinatorTestClock : NSObject
@property(atomic) NSTimeInterval now;
@end
@implementation RBXCoordinatorTestClock @end

@interface RBXFakeAppController : RBXProcessController <RBXAppProcessControlling>
@property(nonatomic, strong) RBXCoordinatorTestClock *clock;
@property(nonatomic, strong) NSMutableArray<NSString *> *events;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *waitBudgets;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *verifyDeadlines;
@property(nonatomic, strong) NSMutableArray *callbacks;
@property(nonatomic, strong) NSDictionary *fakeIdentity;
@property(nonatomic, strong) NSDictionary *lastProfile;
@property(nonatomic, strong) NSDictionary *birthOverrides;
@property(nonatomic) BOOL stopOK, verifyOK, launchOK, inspectOK, corruptIdentity;
@property(nonatomic) NSTimeInterval stopDuration, verifyDuration;
@property(nonatomic) NSUInteger launches;
@property(nonatomic) pid_t pid;
@property(nonatomic) NSUInteger fakeObservationCount;
@property(nonatomic, strong) dispatch_semaphore_t launchEntered, releaseLaunch;
@property(nonatomic, strong) dispatch_semaphore_t stopEntered, releaseStop;
@property(nonatomic, strong) dispatch_semaphore_t inspectionEntered, releaseInspection;
@property(nonatomic, copy) void (^liveCallback)(NSDictionary *, NSString *);
@end

@implementation RBXFakeAppController
- (instancetype)initWithAppDescriptor:(NSDictionary *)descriptor {
    if ((self = [super initWithAppDescriptor:descriptor])) {
        _stopOK = _verifyOK = _launchOK = _inspectOK = YES;
        _waitBudgets = [NSMutableArray array]; _verifyDeadlines = [NSMutableArray array];
        _callbacks = [NSMutableArray array]; _pid = [descriptor[@"appType"] isEqual:@"reddit"] ? 101 : 202;
    }
    return self;
}
- (void)event:(NSString *)name { @synchronized (self.events) { [self.events addObject:[name stringByAppendingFormat:@":%@", self.appDescriptor[@"appType"]]]; } }
- (void)killAppProcesses { [self event:@"kill"]; }
- (BOOL)killAllAndWait:(NSTimeInterval)timeout {
    [self event:@"wait"]; [self.waitBudgets addObject:@(timeout)];
    dispatch_semaphore_t entered;
    @synchronized (self) { entered = self.stopEntered; self.stopEntered = nil; }
    if (entered) { dispatch_semaphore_signal(entered); dispatch_semaphore_wait(self.releaseStop, DISPATCH_TIME_FOREVER); }
    self.clock.now += self.stopDuration; return self.stopOK;
}
- (BOOL)verifyNoAppSocketsForInterval:(NSTimeInterval)interval deadline:(NSTimeInterval)deadline error:(NSError **)error {
    [self event:@"verify"]; [self.verifyDeadlines addObject:@(deadline)];
    self.clock.now += self.verifyDuration;
    if (!self.verifyOK && error) *error = [NSError errorWithDomain:@"test.verify" code:1 userInfo:nil];
    return self.verifyOK;
}
- (BOOL)launchCloneForProfile:(NSDictionary *)profile error:(NSError **)error {
    [self event:@"launch"]; self.lastProfile = profile; self.launches++;
    if (self.launchEntered) { dispatch_semaphore_signal(self.launchEntered); dispatch_semaphore_wait(self.releaseLaunch, DISPATCH_TIME_FOREVER); }
    if (!self.launchOK) return NO;
    self.fakeIdentity = @{@"containerId":profile[@"containerId"], @"bundleIdentifier":profile[@"app"][@"bundleIdentifier"],
        @"executable":[NSString stringWithFormat:@"/Applications/%@.app/Main", self.appDescriptor[@"appType"]],
        @"pid":@(self.pid), @"generation":[NSString stringWithFormat:@"generation-%lu", (unsigned long)self.launches], @"bootEpoch":@"boot-a",
        @"processStartSeconds":@1000, @"processStartMicroseconds":@123};
    if (self.birthOverrides) {
        NSMutableDictionary *changed=[self.fakeIdentity mutableCopy];
        for (NSString *key in self.birthOverrides) {
            if (self.birthOverrides[key]==NSNull.null) [changed removeObjectForKey:key];
            else changed[key]=self.birthOverrides[key];
        }
        self.fakeIdentity=changed;
    }
    if (self.corruptIdentity) self.fakeIdentity = @{@"pid":@(self.pid)};
    return YES;
}
- (NSDictionary *)activeCloneIdentity { return self.fakeIdentity; }
- (pid_t)activeClonePID { return self.pid; }
- (NSUInteger)terminationObservationInFlight { return self.fakeObservationCount; }
- (BOOL)isProfileStopped:(NSDictionary *)profile error:(NSError **)error {
    [self event:@"inspect"];
    BOOL stoppedSnapshot = self.inspectOK;
    if (self.inspectionEntered) {
        dispatch_semaphore_signal(self.inspectionEntered);
        dispatch_semaphore_wait(self.releaseInspection, DISPATCH_TIME_FOREVER);
    }
    return stoppedSnapshot;
}
- (void)stopWatchingAppTermination { [self event:@"cancel"]; self.liveCallback = nil; }
- (void)watchAppTerminationOnQueue:(dispatch_queue_t)queue onExit:(void (^)(NSDictionary *, NSString *))onExit {
    [self event:@"watch"]; self.liveCallback = onExit; [self.callbacks addObject:[onExit copy]];
}
@end

// Exercise the ACTUAL production dispatch-source handler, token checks, identity
// locks and in-flight counter. Override only its I/O and launch/stop effects.
@interface RBXActualObserverController : RBXProcessController <RBXAppProcessControlling>
@property(nonatomic, strong) dispatch_semaphore_t entered, releaseEffect;
@property(nonatomic, copy) NSString *blockedPhase;
@property(atomic) NSUInteger bindingWrites, kills;
@end
@implementation RBXActualObserverController
- (void)killAppProcesses { self.kills++; }
- (BOOL)killAllAndWait:(NSTimeInterval)timeout { [self killAppProcesses]; return YES; }
- (BOOL)verifyNoAppSocketsForInterval:(NSTimeInterval)interval deadline:(NSTimeInterval)deadline error:(NSError **)error { return YES; }
- (BOOL)launchCloneForProfile:(NSDictionary *)profile error:(NSError **)error {
    [self _setActiveCloneIdentity:@{@"containerId":profile[@"containerId"], @"bundleIdentifier":profile[@"app"][@"bundleIdentifier"],
        @"executable":@"/Applications/Fixture.app/Main", @"pid":@313, @"generation":@"actual-observer-generation", @"bootEpoch":@"actual-observer-boot",
        @"processStartSeconds":@1000, @"processStartMicroseconds":@123}];
    return YES;
}
- (void)blockIfPhase:(NSString *)phase {
    if ([self.blockedPhase isEqual:phase]) {
        dispatch_semaphore_signal(self.entered); dispatch_semaphore_wait(self.releaseEffect, DISPATCH_TIME_FOREVER);
    }
}
- (NSDictionary *)_terminationProcessPaths:(NSError **)error {
    NSDictionary *identity = self.activeCloneIdentity;
    [self blockIfPhase:@"read"];
    return identity ? @{identity[@"pid"]:identity[@"executable"]} : @{};
}
- (NSDictionary *)_terminationNetworkLease { return @{@"state":@"closed"}; }
- (NSDictionary *)_terminationProcessBirthForIdentity:(NSDictionary *)identity error:(NSError **)error {
    return @{@"processStartSeconds":@1000, @"processStartMicroseconds":@123};
}
- (BOOL)_terminationMatchesProcessPath:(NSString *)path error:(NSError **)error { return [path isEqual:@"/Applications/Fixture.app/Main"]; }
- (BOOL)_revokeTerminationBinding:(NSError **)error {
    [self blockIfPhase:@"binding"];
    self.bindingWrites++; return YES;
}
@end

@interface RBXCoordinatorFixture : NSObject
@property(nonatomic, strong) RBXCoordinatorTestClock *clock;
@property(nonatomic, strong) NSMutableArray<NSString *> *events;
@property(nonatomic, strong) RBXFakeAppController *reddit, *facebook;
@property(nonatomic, strong) RBXAppProcessCoordinator *coordinator;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *exits;
@end
@implementation RBXCoordinatorFixture
- (instancetype)init {
    if ((self = [super init])) {
        _clock = [RBXCoordinatorTestClock new]; _clock.now = 100;
        _events = [NSMutableArray array]; _exits = [NSMutableArray array];
        _reddit = [[RBXFakeAppController alloc] initWithAppDescriptor:RBXRedditAppDescriptor()];
        _facebook = [[RBXFakeAppController alloc] initWithAppDescriptor:RBXAppDescriptorForType(@"facebook")];
        for (RBXFakeAppController *controller in @[_reddit, _facebook]) { controller.clock = _clock; controller.events = _events; }
        RBXCoordinatorTestClock *clock = _clock;
        _coordinator = [[RBXAppProcessCoordinator alloc] initWithControllers:@[_facebook, _reddit]
            runnableAppTypes:[NSSet setWithArray:@[@"reddit", @"facebook"]] monotonicClock:^NSTimeInterval { return clock.now; }];
        NSCAssert(_coordinator, @"valid test-only canonical app activation");
        NSMutableArray *exits = _exits;
        [_coordinator watchAppTerminationOnQueue:dispatch_get_main_queue() onExit:^(NSDictionary *identity, NSString *reason) {
            [exits addObject:identity];
        }];
        [_events removeAllObjects];
    }
    return self;
}
@end

static NSDictionary *Profile(NSString *type, NSString *container) {
    NSDictionary *descriptor = RBXAppDescriptorForType(type);
    NSMutableDictionary *profile = [@{@"containerId":container,
        @"app":@{@"bundleIdentifier":RBXAppBundleIdentifier(descriptor, container),
            @"bundlePath":@"/Applications/Clone.app", @"architecture":@"clonedApp-v2", @"cloneState":@"ready"}} mutableCopy];
    if (type) profile[@"appType"] = type;
    return profile;
}

static BOOL HasLaunch(RBXCoordinatorFixture *fixture) {
    return fixture.reddit.launches != 0 || fixture.facebook.launches != 0;
}

static int ConcurrentLaunchStopRegression(void) {
    RBXCoordinatorFixture *f = [RBXCoordinatorFixture new];
    NSCAssert([f.coordinator killAllAndWait:8], @"concurrent fixture starts drained");
    f.reddit.launchEntered = dispatch_semaphore_create(0); f.reddit.releaseLaunch = dispatch_semaphore_create(0);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL launched = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        launched = [f.coordinator launchCloneForProfile:Profile(@"reddit",@"overlap") error:nil];
        dispatch_semaphore_signal(done);
    });
    NSCAssert(dispatch_semaphore_wait(f.reddit.launchEntered, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC)) == 0, @"launch delegate reached deterministic barrier");
    dispatch_semaphore_t stopDone = dispatch_semaphore_create(0);
    __block BOOL stopped = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ stopped = [f.coordinator killAllAndWait:8]; dispatch_semaphore_signal(stopDone); });
    long stopWait = dispatch_semaphore_wait(stopDone, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC));
    dispatch_semaphore_signal(f.reddit.releaseLaunch);
    if (stopWait) dispatch_semaphore_wait(stopDone, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC));
    NSCAssert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC)) == 0, @"late launch completion is bounded");
    int failed = stopWait || stopped || launched || f.coordinator.activeCloneIdentity != nil;
    if (failed) fprintf(stderr, "FAIL overlap: stop reported %s while launch was blocked; late launch reported %s and active identity %s\n",
        stopped ? "success" : "failure", launched ? "success" : "failure", f.coordinator.activeCloneIdentity ? "present" : "absent");
    RBXCoordinatorFixture *observer = [RBXCoordinatorFixture new]; observer.reddit.fakeObservationCount = 1;
    BOOL observerStopped = [observer.coordinator killAllAndWait:8];
    if (observerStopped) { failed++; fprintf(stderr, "FAIL observer: stop reported success while a cancelled producer still had an executing handler\n"); }
    return failed;
}

static void ConcurrentInspectionLaunchRegression(void) {
    RBXCoordinatorFixture *f = [RBXCoordinatorFixture new];
    NSCAssert([f.coordinator killAllAndWait:8], @"inspection fixture starts drained");
    f.reddit.inspectionEntered = dispatch_semaphore_create(0);
    f.reddit.releaseInspection = dispatch_semaphore_create(0);
    NSDictionary *profile = Profile(@"reddit", @"inspection-overlap");
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL stopped = NO;
    __block NSError *inspectionError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        stopped = [f.coordinator isProfileStopped:profile error:&inspectionError];
        dispatch_semaphore_signal(done);
    });
    NSCAssert(dispatch_semaphore_wait(f.reddit.inspectionEntered, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC)) == 0,
        @"inspection captures a stopped snapshot before launch admission");
    BOOL launched = [f.coordinator launchCloneForProfile:profile error:nil];
    dispatch_semaphore_signal(f.reddit.releaseInspection);
    NSCAssert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC)) == 0,
        @"inspection returns after the entire launch has completed");
    NSCAssert(launched && f.coordinator.activeClonePID == 101, @"the target is now the active launched clone");
    NSCAssert(!stopped && inspectionError, @"a completed launch invalidates the earlier stopped snapshot even after its in-flight count reaches zero");
}

static void ConcurrentStopRegression(void) {
    RBXCoordinatorFixture *f = [RBXCoordinatorFixture new];
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), done = dispatch_semaphore_create(0);
    f.reddit.stopEntered = entered; f.reddit.releaseStop = dispatch_semaphore_create(0);
    __block BOOL first = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ first = [f.coordinator killAllAndWait:8]; dispatch_semaphore_signal(done); });
    NSCAssert(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC)) == 0, @"first stop reached backend wait");
    NSCAssert(![f.coordinator launchCloneForProfile:Profile(@"facebook",@"overlap") error:nil] && !HasLaunch(f), @"launch cannot enter while stop is blocked");
    NSCAssert(![f.coordinator isProfileStopped:Profile(@"facebook",@"overlap") error:nil], @"read-only inspection cannot prove stopped during an in-flight transition");
    dispatch_semaphore_t secondDone = dispatch_semaphore_create(0); __block BOOL second = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ second = [f.coordinator killAllAndWait:8]; dispatch_semaphore_signal(secondDone); });
    long waited = dispatch_semaphore_wait(secondDone, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC));
    dispatch_semaphore_signal(f.reddit.releaseStop);
    if (waited) dispatch_semaphore_wait(secondDone, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC));
    NSCAssert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC)) == 0, @"old stop returns after backend releases");
    NSCAssert(!waited && !first && !second, @"emergency stop never waits behind another backend and neither overlapping stop claims early quiescence");
    NSCAssert([f.coordinator killAllAndWait:8], @"new stop proves quiescence after both old operations finish");
}

static void ActualObserverQuiescenceRegression(NSString *phase) {
    RBXActualObserverController *controller = [[RBXActualObserverController alloc] initWithAppDescriptor:RBXRedditAppDescriptor()];
    controller.blockedPhase = phase; controller.entered = dispatch_semaphore_create(0); controller.releaseEffect = dispatch_semaphore_create(0);
    RBXAppProcessCoordinator *coordinator = [[RBXAppProcessCoordinator alloc] initWithControllers:@[controller]
        runnableAppTypes:[NSSet setWithObject:@"reddit"] monotonicClock:^NSTimeInterval { return 100; }];
    dispatch_queue_t queue = dispatch_queue_create("rbx.actual-observer-test", DISPATCH_QUEUE_SERIAL);
    [coordinator watchAppTerminationOnQueue:queue onExit:^(NSDictionary *identity, NSString *reason) { [controller blockIfPhase:@"callback"]; }];
    NSCAssert([coordinator killAllAndWait:8] && [coordinator launchCloneForProfile:Profile(@"reddit",@"observer") error:nil], @"actual timer producer fixture launched");
    NSCAssert(dispatch_semaphore_wait(controller.entered, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC)) == 0 && controller.terminationObservationInFlight == 1,
        @"actual timer handler remains counted across blocked read/callback/binding effects");
    dispatch_semaphore_t stopped = dispatch_semaphore_create(0); __block BOOL stopResult = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ stopResult = [coordinator killAllAndWait:8]; dispatch_semaphore_signal(stopped); });
    long waited = dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC));
    BOOL admission = NO;
    if (!waited) admission = [coordinator launchCloneForProfile:Profile(@"reddit",@"later") error:nil];
    dispatch_semaphore_signal(controller.releaseEffect);
    if (waited) dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC));
    dispatch_semaphore_t quiet = dispatch_semaphore_create(0); dispatch_async(queue, ^{ dispatch_semaphore_signal(quiet); });
    NSCAssert(dispatch_semaphore_wait(quiet, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC)) == 0, @"cancelled actual producer drains after its effect returns");
    NSCAssert(!waited && !stopResult && !admission && controller.terminationObservationInFlight == 0, @"cancel is immediate, in-flight producer blocks drain/admission, completion removes count");
    NSUInteger expectedWrites = [phase isEqual:@"binding"] ? 1 : 0;
    NSCAssert(controller.bindingWrites == expectedWrites, @"cancel invalidates before binding; already-entered write remains counted through its actual effect");
    NSCAssert([coordinator killAllAndWait:8], @"only a later drain after old handler completion may succeed");
}

static void TestSwitch(NSString *first, NSString *second) {
    RBXCoordinatorFixture *f = [RBXCoordinatorFixture new]; NSError *error = nil;
    RBXFakeAppController *firstController = [first isEqual:@"reddit"] ? f.reddit : f.facebook;
    RBXFakeAppController *secondController = [second isEqual:@"reddit"] ? f.reddit : f.facebook;
    NSCAssert([f.coordinator killAllAndWait:8], @"initial global drain");
    NSCAssert(([f.events isEqual:@[@"cancel:reddit", @"cancel:facebook", @"kill:reddit", @"kill:facebook", @"wait:reddit", @"wait:facebook"]]),
        @"cancel every producer and issue every kill before waiting for either app");
    NSCAssert([f.coordinator launchCloneForProfile:Profile(first, @"first") error:&error], @"first app launch %@", error);
    NSCAssert(f.coordinator.activeClonePID == firstController.pid && firstController.liveCallback && !secondController.liveCallback, @"observe only exact active controller");
    NSDictionary *oldIdentity = f.coordinator.activeCloneIdentity;
    void (^oldCallback)(NSDictionary *, NSString *) = firstController.callbacks.lastObject;
    NSCAssert(![f.coordinator launchCloneForProfile:Profile(second, @"second") error:nil], @"no second launch without global stop");
    [f.events removeAllObjects];
    NSCAssert([f.coordinator killAllAndWait:8] && !f.coordinator.activeCloneIdentity && f.coordinator.activeClonePID == 0, @"global stop discards active authority");
    NSCAssert(!firstController.liveCallback && !secondController.liveCallback, @"old producer cancelled before switch");
    NSCAssert([f.coordinator launchCloneForProfile:Profile(second, @"second") error:&error], @"second app launch %@", error);
    oldCallback(oldIdentity, @"queued old timer event");
    NSCAssert(f.exits.count == 0 && f.coordinator.activeClonePID == secondController.pid, @"stale other-app callback cannot revoke active identity");
    NSCAssert([f.coordinator.activeCloneIdentity[@"bundleIdentifier"] isEqual:Profile(second,@"second")[@"app"][@"bundleIdentifier"]], @"launch dispatch retains selected registered app");
    NSCAssert([secondController.lastProfile[@"appType"] isEqual:second], @"immutable descriptor routing");
}

int main(void) { @autoreleasepool {
    if (ConcurrentLaunchStopRegression()) return 1;
    ConcurrentInspectionLaunchRegression();
    ConcurrentStopRegression();
    for (NSString *phase in @[@"read", @"callback", @"binding"]) ActualObserverQuiescenceRegression(phase);
    RBXAppProcessCoordinator *production = [RBXAppProcessCoordinator new];
    NSMutableArray *runnable = [NSMutableArray array];
    for (NSDictionary *descriptor in RBXRegisteredAppDescriptors()) if ([descriptor[@"runnable"] boolValue]) [runnable addObject:descriptor];
    NSCAssert([production.appDescriptors isEqual:RBXRegisteredAppDescriptors()], @"default coordinator closes all canonical owners, including inactive clones");
    {
        RBXCoordinatorFixture *f=[RBXCoordinatorFixture new];
        StorageCloseOK=NO;NSCAssert(![f.coordinator killAllAndWait:8],@"failed storage seal cannot establish global drain");
        NSCAssert(![f.coordinator launchCloneForProfile:Profile(@"reddit",@"sealed") error:nil]&&!f.reddit.launches,@"no launch after incomplete storage closure");
        StorageCloseOK=YES;NSCAssert([f.coordinator killAllAndWait:8],@"storage closure recovers");
        StorageOpenOK=NO;NSCAssert(![f.coordinator launchCloneForProfile:Profile(@"reddit",@"sealed") error:nil]&&!f.reddit.launches,@"failed storage admission never spawns");StorageOpenOK=YES;
    }
    NSError *error = nil;
    if (![RBXAppDescriptorForType(@"facebook")[@"runnable"] boolValue])
        NSCAssert(![production launchCloneForProfile:Profile(@"facebook",@"fb") error:&error] && [error.localizedDescription containsString:@"inactive"], @"inactive profile rejected before delegate/spawn");
    NSCAssert(![production launchCloneForProfile:@{@"appType":@"unknown"} error:nil], @"unknown type rejected");
    NSCAssert(![production launchCloneForProfile:(id)NSNull.null error:nil], @"non-dictionary profile rejected");
    {
        RBXFakeAppController *reddit = [[RBXFakeAppController alloc] initWithAppDescriptor:RBXRedditAppDescriptor()];
        RBXAppProcessCoordinator *restricted = [[RBXAppProcessCoordinator alloc] initWithControllers:@[reddit]
            runnableAppTypes:[NSSet setWithObject:@"reddit"] monotonicClock:^NSTimeInterval { return 100; }];
        NSCAssert(![restricted launchCloneForProfile:Profile(@"facebook",@"fb") error:nil] && reddit.launches == 0,
            @"inactive registry selection is rejected independently of future production activation");
        NSCAssert((![[RBXAppProcessCoordinator alloc] initWithControllers:@[reddit, reddit]
            runnableAppTypes:[NSSet setWithObject:@"reddit"] monotonicClock:^NSTimeInterval { return 100; }]), @"duplicate fake bindings rejected");
    }
    TestSwitch(@"reddit", @"facebook"); TestSwitch(@"facebook", @"reddit");
    {
        RBXCoordinatorFixture *f = [RBXCoordinatorFixture new];
        f.reddit.stopDuration = 1.6; f.facebook.stopDuration = 1.6;
        NSCAssert([f.coordinator stopAllAppsAndWait:RBX_STARTUP_STOP_BUDGET error:nil],
            @"actual startup budget accommodates both stable-clean intervals and inventory work");
        NSCAssert(f.facebook.waitBudgets.count == 1, @"inactive registered family still drained");
    }

    for (NSString *failedType in @[@"reddit", @"facebook"]) {
        RBXCoordinatorFixture *f = [RBXCoordinatorFixture new];
        ([failedType isEqual:@"reddit"] ? f.reddit : f.facebook).stopOK = NO;
        NSCAssert(![f.coordinator stopAllAppsAndWait:8 error:&error] && error, @"failure in either drain rejects global success");
        NSCAssert([f.events containsObject:@"kill:reddit"] && [f.events containsObject:@"kill:facebook"] &&
            [f.events containsObject:@"wait:reddit"] && [f.events containsObject:@"wait:facebook"], @"one failure never skips later app stop/drain");
        NSCAssert(![f.coordinator launchCloneForProfile:Profile(@"reddit",@"a") error:nil] && !HasLaunch(f), @"no admission after unproved global drain");
    }
    {
        RBXCoordinatorFixture *f = [RBXCoordinatorFixture new]; f.reddit.stopDuration = 2; f.facebook.stopDuration = 3;
        NSCAssert([f.coordinator stopAllAppsAndWait:8 error:nil], @"both fit aggregate budget");
        NSCAssert(f.reddit.waitBudgets[0].doubleValue == 8 && f.facebook.waitBudgets[0].doubleValue == 6, @"second app gets only remaining budget");
    }
    for (NSNumber *duration in @[@8.0, @9.0, @(-1.0), @(NAN)]) {
        RBXCoordinatorFixture *f = [RBXCoordinatorFixture new]; f.reddit.stopDuration = duration.doubleValue;
        NSCAssert(![f.coordinator stopAllAppsAndWait:8 error:&error], @"deadline equality/overrun/regression/clock loss rejects success");
        NSCAssert([f.events containsObject:@"kill:facebook"] && ![f.events containsObject:@"wait:facebook"], @"later app already stopped; expired/invalid clock never starts another wait");
        NSCAssert(![f.coordinator launchCloneForProfile:Profile(@"facebook",@"a") error:nil] && !HasLaunch(f), @"deadline failure prevents spawn");
    }
    for (NSNumber *timeout in @[@0, @(-1), @(NAN), @(INFINITY)]) {
        RBXCoordinatorFixture *f = [RBXCoordinatorFixture new];
        NSCAssert(![f.coordinator stopAllAppsAndWait:timeout.doubleValue error:nil] && f.reddit.waitBudgets.count == 0, @"invalid budgets never prove stop");
    }
    {
        RBXCoordinatorFixture *f = [RBXCoordinatorFixture new];
        NSCAssert([f.coordinator killAllAndWait:8], @"setup stop");
        f.reddit.verifyDuration = 1; f.facebook.verifyDuration = 1;
        NSCAssert([f.coordinator verifyNoAppSocketsForInterval:1 timeout:4 error:nil], @"global socket verification");
        NSCAssert(f.reddit.verifyDeadlines[0].doubleValue == 104 && f.facebook.verifyDeadlines[0].doubleValue == 104, @"same absolute deadline reaches both controllers");
        f.reddit.verifyDuration = 2; f.facebook.verifyDuration = 2;
        NSCAssert(![f.coordinator verifyNoAppSocketsForInterval:1 timeout:3 error:nil], @"delegate late success cannot extend deadline");
    }
    for (NSString *failedType in @[@"reddit", @"facebook"]) {
        RBXCoordinatorFixture *f = [RBXCoordinatorFixture new]; NSCAssert([f.coordinator killAllAndWait:8], @"setup stop");
        ([failedType isEqual:@"reddit"] ? f.reddit : f.facebook).verifyOK = NO;
        NSCAssert(![f.coordinator launchCloneForProfile:Profile(@"reddit",@"a") error:nil] && !HasLaunch(f), @"any app reappearing during final preflight blocks launch");
        NSCAssert([f.events containsObject:@"verify:reddit"] && [f.events containsObject:@"verify:facebook"], @"socket failure does not report partial success");
    }
    {
        RBXCoordinatorFixture *f = [RBXCoordinatorFixture new];
        NSCAssert(![f.coordinator launchCloneForProfile:Profile(nil,@"legacy") error:nil] && !HasLaunch(f), @"no launch before global stop");
        NSCAssert([f.coordinator killAllAndWait:8] && [f.coordinator launchCloneForProfile:Profile(nil,@"legacy") error:nil], @"legacy missing appType selects Reddit");
        NSCAssert(f.reddit.launches == 1 && f.facebook.launches == 0, @"legacy routing unchanged");
        NSDictionary *original = f.coordinator.activeCloneIdentity;
        void (^oldCallback)(NSDictionary *, NSString *) = f.reddit.callbacks.lastObject;
        NSCAssert([f.coordinator killAllAndWait:8] && [f.coordinator launchCloneForProfile:Profile(nil,@"legacy") error:nil], @"same container and PID reused with new generation");
        oldCallback(original,@"stale same-app generation");
        NSCAssert(f.exits.count == 0, @"old callback epoch cannot revoke replacement");
        NSDictionary *current = f.coordinator.activeCloneIdentity;
        void (^callback)(NSDictionary *, NSString *) = f.reddit.liveCallback;
        for (NSString *key in @[@"containerId",@"bundleIdentifier",@"executable",@"pid",@"generation",@"bootEpoch",@"processStartSeconds",@"processStartMicroseconds"]) {
            NSMutableDictionary *wrong = [current mutableCopy]; wrong[key] = [key isEqual:@"pid"] ? @999 : @"wrong";
            callback(wrong,@"wrong identity field");
            NSCAssert(f.exits.count == 0 && f.coordinator.activeClonePID == 101, @"all eight active identity fields must match");
        }
        callback(current,@"actual exit"); callback(current,@"duplicate queued event");
        NSCAssert(f.exits.count == 1 && !f.coordinator.activeCloneIdentity && f.coordinator.activeClonePID == 0, @"exact identity delivered once, authority removed before callback");
    }
    {
        RBXCoordinatorFixture *f = [RBXCoordinatorFixture new]; NSCAssert([f.coordinator killAllAndWait:8], @"setup stop");
        f.facebook.corruptIdentity = YES;
        NSCAssert(![f.coordinator launchCloneForProfile:Profile(@"facebook",@"a") error:nil] && !f.coordinator.activeCloneIdentity, @"delegate success without exact identity is not launch success");
        NSCAssert([f.events.lastObject isEqual:@"kill:facebook"], @"identity mismatch requests cleanup of every app");
    }
    {
        RBXCoordinatorFixture *f = [RBXCoordinatorFixture new]; NSCAssert([f.coordinator killAllAndWait:8], @"setup stop");
        f.facebook.launchOK = NO;
        NSCAssert(![f.coordinator launchCloneForProfile:Profile(@"facebook",@"a") error:nil] && !f.coordinator.activeCloneIdentity, @"underlying launch failure leaves no active authority");
        f.facebook.launchOK = YES;
        NSCAssert(![f.coordinator launchCloneForProfile:Profile(@"facebook",@"a") error:nil] && f.facebook.launches == 1, @"failed launch consumes drain authorization");
    }
    {
        RBXCoordinatorFixture *f = [RBXCoordinatorFixture new]; NSCAssert([f.coordinator killAllAndWait:8], @"setup stop");
        NSMutableDictionary *bad = [Profile(@"facebook",@"a") mutableCopy]; bad[@"app"] = Profile(@"reddit",@"a")[@"app"];
        NSCAssert(![f.coordinator launchCloneForProfile:bad error:nil] && !HasLaunch(f), @"cross-app clone identity rejected before dispatch");
        NSCAssert([f.coordinator isProfileStopped:Profile(@"facebook",@"a") error:nil] && [f.events.lastObject isEqual:@"inspect:facebook"], @"read-only inspection routes exact profile controller");
        [f.coordinator stopWatchingAppTermination];
        NSCAssert(![f.coordinator launchCloneForProfile:Profile(@"facebook",@"a") error:nil] && !HasLaunch(f), @"launch requires producer observation registration");
    }
    {
        RBXCoordinatorFixture *f = [RBXCoordinatorFixture new]; RBXCoordinatorTestContext *context = [RBXCoordinatorTestContext new];
        context.testDeadline = 104; sContext = context; f.reddit.stopDuration = 1; f.facebook.stopDuration = 1;
        NSCAssert([f.coordinator killAllAndWait:20] && f.reddit.waitBudgets[0].doubleValue == 4 && f.facebook.waitBudgets[0].doubleValue == 3, @"aggregate operation deadline caps per-app cleanup");
        context.testCancelled = YES; context.testDeadline = 101;
        NSCAssert([f.coordinator killAllAndWait:8] && f.reddit.waitBudgets.lastObject.doubleValue == 8, @"cancelled owner retains explicit bounded cleanup allowance");
        NSCAssert(![f.coordinator verifyNoAppSocketsForInterval:0 timeout:3 error:nil], @"cancellation never authorizes admission verification"); sContext = nil;
    }
    {
        RBXCoordinatorFixture *f = [RBXCoordinatorFixture new]; RBXCoordinatorTestContext *context = [RBXCoordinatorTestContext new];
        context.testDeadline = 99; sContext = context;
        NSCAssert(![f.coordinator killAllAndWait:8] && [f.events containsObject:@"kill:reddit"] &&
            [f.events containsObject:@"kill:facebook"] && f.reddit.waitBudgets.count == 0 && f.facebook.waitBudgets.count == 0,
            @"expired owner still requests stop from every app without inventing drain time"); sContext = nil;
    }
    for (NSDictionary *invalid in @[
        @{@"processStartSeconds":NSNull.null}, @{@"processStartSeconds":@0},
        @{@"processStartSeconds":@(-1)}, @{@"processStartSeconds":@1.5}, @{@"processStartSeconds":@"1000"},
        @{@"processStartMicroseconds":NSNull.null}, @{@"processStartMicroseconds":@(-1)},
        @{@"processStartMicroseconds":@1000000}, @{@"processStartMicroseconds":@0.5},
        @{@"processStartMicroseconds":@(NAN)}]) {
        RBXCoordinatorFixture *f=[RBXCoordinatorFixture new];
        NSCAssert([f.coordinator killAllAndWait:8], @"birth admission fixture drained");
        f.reddit.birthOverrides=invalid;
        NSCAssert(![f.coordinator launchCloneForProfile:Profile(@"reddit",@"bad-birth") error:nil] &&
            !f.coordinator.activeCloneIdentity, @"missing or invalid process birth cannot establish authority");
    }
    // The additive real bounded wrapper refuses malformed/expired deadlines
    // before process/LS I/O; existing default controller still binds Reddit.
    RBXProcessController *real = [RBXProcessController new];
    NSCAssert([real.appDescriptor isEqual:RBXRedditAppDescriptor()] && !real.activeCloneIdentity, @"original default controller outcome preserved");
    NSCAssert(![real verifyNoAppSocketsForInterval:0 deadline:0 error:nil] &&
        ![real verifyNoAppSocketsForInterval:NAN deadline:INFINITY error:nil], @"real bounded verifier rejects invalid budget before any process inspection");
    [real stopWatchingAppTermination];
    puts("PASS: global Reddit/Facebook stop sequencing, aggregate deadlines, overlapping stop/launch epochs, actual timer producer quiescence, exact identity and stale observer rejection");
} return 0; }
