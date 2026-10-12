// Native macOS Foundation tests for the same transport compiled into both apps.
#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import "../shared/RBXRequestQueue.h"

@interface RBXRequestQueue (FailureTesting)
- (BOOL)_syncDescriptor:(int)fd operation:(NSString *)operation error:(NSError **)error;
@end
@interface FaultQueue : RBXRequestQueue
@property(nonatomic, copy) NSString *failedOperation;
@property(nonatomic) NSUInteger failuresRemaining;
@end
@implementation FaultQueue
- (BOOL)_syncDescriptor:(int)fd operation:(NSString *)operation error:(NSError **)error {
    if (self.failuresRemaining && [operation isEqualToString:self.failedOperation]) {
        self.failuresRemaining--;
        if (error) *error = [NSError errorWithDomain:@"test" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Injected fsync failure"}];
        return NO;
    }
    return [super _syncDescriptor:fd operation:operation error:error];
}
@end

static void Check(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"TestFailure" reason:message userInfo:nil];
}

static FaultQueue *Queue(NSString *root) {
    return [[FaultQueue alloc] initWithRootDirectory:root daemonUID:geteuid() clientUID:geteuid()];
}

static NSString *Record(NSString *root, NSString *directory, NSString *requestID) {
    return [[root stringByAppendingPathComponent:directory]
        stringByAppendingPathComponent:[requestID stringByAppendingPathExtension:@"plist"]];
}

static void PublishRaw(NSString *root, NSString *identifier, NSDictionary *values) {
    Check([values writeToFile:Record(root, @"Inbox", identifier) atomically:YES], @"raw fixture write");
}

static void TestConcurrent(NSString *root) {
    FaultQueue *daemon = Queue(root);
    NSError *error = nil;
    Check([daemon prepareDaemon:&error], error.description);
    FaultQueue *contender = Queue(root);
    Check(![contender prepareDaemon:&error], @"second daemon must not acquire queue ownership");
    NSMutableArray *ids = [NSMutableArray array];
    dispatch_group_t group = dispatch_group_create();
    for (NSUInteger i = 0; i < 64; i++) {
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                NSString *identifier = [Queue(root) enqueueAction:@"previewIdentity"
                    values:@{@"container": @"a", @"sequence": @(i)} error:nil];
                @synchronized (ids) { if (identifier) [ids addObject:identifier]; }
            }
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    Check(ids.count == 64 && [NSSet setWithArray:ids].count == 64, @"all concurrent submissions must survive");
    NSMutableSet *claimed = [NSMutableSet set];
    while (YES) {
        error = nil;
        NSDictionary *request = [daemon claimNextRequest:&error];
        Check(error == nil, error.description);
        if (!request) break;
        NSString *identifier = request[@"requestId"];
        Check(![claimed containsObject:identifier], @"request claimed twice");
        [claimed addObject:identifier];
        Check([daemon finishRequest:request ok:YES message:@"done"
            values:@{@"sequence": request[@"sequence"]} error:&error], error.description);
        Check([daemon finishRequest:request ok:NO message:@"late callback" values:@{} error:&error], @"duplicate completion must be harmless");
        NSDictionary *result = [Queue(root) resultForRequestID:identifier error:&error];
        Check([result[@"state"] isEqual:@"succeeded"] && [result[@"message"] isEqual:@"done"], @"first terminal result must win");
        Check([result[@"containerId"] isEqual:@"a"] && result[@"details"][@"sequence"], @"receipt preserves action details");
    }
    Check(claimed.count == 64, @"no submitted request may be lost");
    NSString *finishedID = ids.firstObject;
    PublishRaw(root, finishedID, @{@"formatVersion": @1, @"requestId": finishedID,
        @"action": @"deleteContainer", @"requestedAt": @0});
    Check([daemon claimNextRequest:&error] == nil && !error, @"duplicate UUID replay rejected");
}

static void TestFIFO(NSString *root) {
    FaultQueue *daemon = Queue(root);
    Check([daemon prepareDaemon:nil], @"prepare FIFO test");
    NSString *a = [Queue(root) enqueueAction:@"launchContainer" values:@{@"container": @"a"} error:nil];
    NSString *b = [Queue(root) enqueueAction:@"launchContainer" values:@{@"container": @"b"} error:nil];
    NSDictionary *first = [daemon claimNextRequest:nil];
    NSDictionary *second = [daemon claimNextRequest:nil];
    Check([first[@"requestId"] isEqual:a] && [second[@"requestId"] isEqual:b], @"A then B must not be reordered by random UUIDs");
    Check([daemon finishRequest:first ok:YES message:@"done" values:@{} error:nil], @"finish A");
    Check([daemon finishRequest:second ok:YES message:@"done" values:@{} error:nil], @"finish B");
    NSString *createID = [Queue(root) enqueueAction:@"createContainer" values:@{} error:nil];
    NSDictionary *create = [daemon claimNextRequest:nil];
    Check([daemon finishRequest:create ok:YES message:@"created" values:@{@"containerId": @"generated-id"} error:nil], @"finish generated container");
    Check([[[daemon resultForRequestID:createID error:nil] objectForKey:@"containerId"] isEqual:@"generated-id"], @"receipt uses created container ID");
}

static void TestOwnedSnapshotAndInvalidEntries(NSString *root) {
    FaultQueue *daemon = Queue(root);
    Check([daemon prepareDaemon:nil], @"prepare snapshot test");
    NSString *identifier = [Queue(root) enqueueAction:@"createContainer" values:@{@"container": @"original"} error:nil];
    int retainedWriter = open(Record(root, @"Inbox", identifier).fileSystemRepresentation, O_WRONLY);
    Check(retainedWriter >= 0, @"open client writer before claim");
    NSDictionary *request = [daemon claimNextRequest:nil];
    Check([request[@"container"] isEqual:@"original"], @"claimed original request");
    Check(ftruncate(retainedWriter, 0) == 0 && write(retainedWriter, "changed", 7) == 7, @"mutate retained client inode");
    close(retainedWriter);
    NSDictionary *snapshot = [NSDictionary dictionaryWithContentsOfFile:Record(root, @"Processing", identifier)];
    Check([snapshot[@"container"] isEqual:@"original"], @"owned snapshot must use a different inode");
    Check([daemon finishRequest:request ok:YES message:@"done" values:@{} error:nil], @"complete snapshot request");

    NSString *target = [root.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"untouched"];
    Check([@"marker" writeToFile:target atomically:YES encoding:NSUTF8StringEncoding error:nil], @"create link target");
    for (NSNumber *hardLink in @[@NO, @YES]) {
        NSString *badID = NSUUID.UUID.UUIDString;
        NSString *path = Record(root, @"Inbox", badID);
        int result = hardLink.boolValue ? link(target.fileSystemRepresentation, path.fileSystemRepresentation)
            : symlink(target.fileSystemRepresentation, path.fileSystemRepresentation);
        Check(result == 0, @"create unsafe link fixture");
        Check([daemon claimNextRequest:nil] == nil, @"unsafe request must not execute");
        Check([[[daemon resultForRequestID:badID error:nil] objectForKey:@"state"] isEqual:@"failed"], @"unsafe request receives rejection receipt");
        Check([[NSString stringWithContentsOfFile:target encoding:NSUTF8StringEncoding error:nil] isEqual:@"marker"], @"link target preserved");
    }
    NSString *badID = NSUUID.UUID.UUIDString;
    PublishRaw(root, badID, @{@"formatVersion": @1, @"requestId": NSUUID.UUID.UUIDString,
        @"action": @"deleteContainer", @"requestedAt": @0});
    Check([daemon claimNextRequest:nil] == nil, @"mismatched payload ID must not execute");
    Check([[[daemon resultForRequestID:badID error:nil] objectForKey:@"state"] isEqual:@"failed"], @"malformed payload gets terminal result");
    Check([daemon resultForRequestID:@"../../escape" error:nil] == nil, @"result lookup rejects path traversal");
}

static void TestPersistenceAndRestart(NSString *root) {
    FaultQueue *daemon = Queue(root);
    Check([daemon prepareDaemon:nil], @"prepare persistence test");
    NSString *identifier = [Queue(root) enqueueAction:@"testConfiguration" values:@{} error:nil];
    NSDictionary *request = [daemon claimNextRequest:nil];
    daemon.failedOperation = @"record data"; daemon.failuresRemaining = 1;
    Check(![daemon finishRequest:request ok:YES message:@"first result" values:@{@"kept": @YES} error:nil], @"injected result write must fail");
    Check([NSFileManager.defaultManager fileExistsAtPath:Record(root, @"Processing", identifier)], @"failed result write must retain claim");
    Check([daemon resultForRequestID:identifier error:nil] == nil, @"unsaved result is absent");
    Check([daemon retryPendingResultsAndRecoverAbandonedClaims:nil], @"pending receipt retries without running the operation");
    NSDictionary *result = [daemon resultForRequestID:identifier error:nil];
    Check([result[@"message"] isEqual:@"first result"] && [result[@"details"][@"kept"] boolValue], @"retry preserves original result");
    Check(![NSFileManager.defaultManager fileExistsAtPath:Record(root, @"Processing", identifier)], @"durable result permits claim cleanup");

    identifier = [Queue(root) enqueueAction:@"deleteContainer" values:@{@"container": @"a"} error:nil];
    request = [daemon claimNextRequest:nil];
    daemon.failedOperation = @"record publication"; daemon.failuresRemaining = 1;
    Check(![daemon finishRequest:request ok:YES message:@"published" values:@{} error:nil], @"result directory fsync failure surfaced");
    Check([NSFileManager.defaultManager fileExistsAtPath:Record(root, @"Processing", identifier)], @"claim retained until result publication is durable");
    Check([daemon retryPendingResultsAndRecoverAbandonedClaims:nil], @"publication durability retry succeeds");

    NSString *interruptedID = [Queue(root) enqueueAction:@"createContainer" values:@{} error:nil];
    Check([daemon claimNextRequest:nil] != nil, @"claim before restart");
    daemon = nil; // releases the retained daemon flock
    daemon = Queue(root);
    Check([daemon prepareDaemon:nil] && [daemon retryPendingResultsAndRecoverAbandonedClaims:nil], @"recover after daemon restart");
    Check([[[daemon resultForRequestID:interruptedID error:nil] objectForKey:@"state"] isEqual:@"interrupted"], @"abandoned side effect is not replayed");
    Check([daemon claimNextRequest:nil] == nil, @"no replay after recovery");

    FaultQueue *client = Queue(root);
    client.failedOperation = @"record publication"; client.failuresRemaining = 1;
    NSError *error = nil;
    NSString *publishedID = [client enqueueAction:@"refreshLauncher" values:@{} error:&error];
    Check(publishedID.length && error, @"published enqueue preserves observable ID even if fsync fails");
    request = [daemon claimNextRequest:nil];
    Check([request[@"requestId"] isEqual:publishedID], @"published request survives enqueue sync failure");
    Check([daemon finishRequest:request ok:YES message:@"done" values:@{} error:nil], @"finish published request");
}

int main(void) {
    @autoreleasepool {
        NSString *parent = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"redditbox-request-tests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:parent withIntermediateDirectories:NO
            attributes:@{NSFilePosixPermissions: @0700} error:&error]) {
            fprintf(stderr, "%s\n", error.description.UTF8String); return 1;
        }
        @try {
            TestConcurrent([parent stringByAppendingPathComponent:@"concurrent"]);
            TestFIFO([parent stringByAppendingPathComponent:@"fifo"]);
            TestOwnedSnapshotAndInvalidEntries([parent stringByAppendingPathComponent:@"snapshots"]);
            TestPersistenceAndRestart([parent stringByAppendingPathComponent:@"persistence"]);
            puts("request queue native tests: PASS");
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL: %s\n", exception.reason.UTF8String); return 1;
        } @finally {
            [NSFileManager.defaultManager removeItemAtPath:parent error:nil];
        }
    }
    return 0;
}
