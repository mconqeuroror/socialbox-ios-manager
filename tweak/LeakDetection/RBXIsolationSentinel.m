#import "RBXSentinelIO.h"
#import "RBXContainerManager.h"
#import "RBXProfile.h"
#import "RBXLog.h"
#import <UIKit/UIKit.h>

static dispatch_source_t sSentinelTimer;
static dispatch_queue_t sSentinelQueue;
static id sSentinelForeground;
static BOOL sSentinelRunning;
static BOOL sSentinelAlert;
static NSDictionary *sSentinelChallenge;

static void RBXScheduleSentinel(void) {
    // All scheduling state and UIKit access are confined to the main queue.
    if (sSentinelRunning) return;
    RBXContainerManager *manager = RBXContainerManager.sharedManager;
    NSString *home = NSHomeDirectory(), *bundle = NSBundle.mainBundle.bundleIdentifier;
    int dir = RBXSentinelPrefs(home);
    if (dir < 0) return;
    NSDictionary *control = RBXSentinelRead(dir,RBXSentinelControlName,0);
    NSDictionary *ready = RBXSentinelRead(dir,@"com.redditbox.hook-ready.plist",getuid());
    close(dir);
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (!RBXSentinelControlValid(control,bundle,home.lastPathComponent,now) ||
        !RBXSentinelReady(ready,bundle,getpid())) {
        RBXLogErr("RBX_SENTINEL container=%{public}@ probe=control result=NOT_RUN reason=missing-stale-or-invalid",manager.containerId);
        return;
    }
    NSDictionary *settings = control[@"settings"];
    if (![settings[@"enabled"] isEqual:@YES]) {
        if (sSentinelTimer) dispatch_source_cancel(sSentinelTimer);
        sSentinelTimer = nil;
        [NSNotificationCenter.defaultCenter removeObserver:sSentinelForeground];
        sSentinelForeground = nil;
        return;
    }
    dispatch_source_set_timer(sSentinelTimer,dispatch_time(DISPATCH_TIME_NOW,[settings[@"intervalMinutes"] longLongValue]*60*NSEC_PER_SEC),
        [settings[@"intervalMinutes"] longLongValue]*60*NSEC_PER_SEC,5*NSEC_PER_SEC);
    BOOL shared = [[manager.currentProfile valueForPath:@"security.systemClipboard"] isEqual:@"enabled"];
    __block BOOL clipboardVisible = NO, clipboardError = NO;
    @try {
        if (!shared) {
            UIPasteboard *board = UIPasteboard.generalPasteboard;
            if (!board) @throw [NSException exceptionWithName:@"RBXSentinelClipboardUnavailable" reason:nil userInfo:nil];
            clipboardVisible = board.numberOfItems > 0 || board.hasStrings || board.hasImages || board.hasURLs ||
                board.items.count > 0 || board.string != nil;
        }
    } @catch (__unused NSException *e) { clipboardError = YES; }
    // Explicitly optional write challenge. Never write when compatibility mode
    // intentionally exposes the user's shared clipboard. The normal observer
    // never writes clipboard data and never seeds sibling storage.
    if ([settings[@"clipboardChallenge"] isEqual:@YES] && !sSentinelChallenge) {
        BOOL available = NO, visible = NO;
        if (!shared) @try {
            UIPasteboard *board = UIPasteboard.generalPasteboard;
            if (!board) @throw [NSException exceptionWithName:@"RBXSentinelClipboardUnavailable" reason:nil userInfo:nil];
            [board setItems:@[@{@"public.utf8-plain-text":[@"RBX_SENTINEL:" stringByAppendingString:NSUUID.UUID.UUIDString]}]
                options:@{UIPasteboardOptionLocalOnly:@YES, UIPasteboardOptionExpirationDate:[NSDate dateWithTimeIntervalSinceNow:60]}];
            visible = board.numberOfItems > 0 || board.string != nil;
            available = YES;
        } @catch (__unused NSException *e) { available = NO; }
        sSentinelChallenge = RBXSentinelClipboardChallenge(shared,available,visible);
    }
    NSDictionary *challenge = [settings[@"clipboardChallenge"] isEqual:@YES] ? sSentinelChallenge : nil;
    sSentinelRunning = YES;
    dispatch_async(sSentinelQueue, ^{
        @autoreleasepool {
            RBXSentinelAPIs api = {
                .keychain = ^OSStatus(NSDictionary *query) {
                    CFTypeRef result = NULL;
                    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query,&result);
                    if (result) CFRelease(result);
                    return status;
                },
                .attributes = ^NSDictionary *(NSString *path, NSError **error) {
                    return [NSFileManager.defaultManager attributesOfItemAtPath:path error:error];
                },
                .openReadOnly = ^BOOL(NSString *path, NSError **error) {
                    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:path] error:error];
                    return RBXSentinelCloseReadHandle(handle);
                },
                .defaults = ^id(NSString *suite, NSString *key) {
                    return RBXSentinelReadDefaults([NSUserDefaults new],suite,key);
                },
                .clipboardHasContent = ^BOOL {
                    if (clipboardError) @throw [NSException exceptionWithName:@"ClipboardUnavailable" reason:nil userInfo:nil];
                    return clipboardVisible;
                }
            };
            NSMutableArray *rows = [RBXSentinelProbe(control[@"targets"],shared,now,api) mutableCopy];
            if (challenge) [rows addObject:challenge];
            sSentinelAlert |= RBXSentinelHasLeak(rows);
            for (NSDictionary *row in rows) {
                if ([row[@"status"] isEqual:@"LEAK"])
                    RBXLogErr("RBX_SENTINEL container=%{public}@ probe=%{public}@ target=%{public}@ result=LEAK code=%{public}@ review-before-network-open",manager.containerId,row[@"probe"],row[@"target"],row[@"code"]);
                else RBXLog("RBX_SENTINEL container=%{public}@ probe=%{public}@ target=%{public}@ result=%{public}@ code=%{public}@",manager.containerId,row[@"probe"],row[@"target"],row[@"status"],row[@"code"]);
            }
            NSMutableDictionary *report = [NSMutableDictionary dictionary];
            for (NSString *key in @[@"containerId",@"bundleIdentifier",@"generation",@"bootEpoch",@"pid"])
                report[key] = ready[key];
            [report addEntriesFromDictionary:@{@"schemaVersion":@1,@"revision":control[@"revision"],
                @"timestamp":@(now),@"rows":rows,@"alert":@(sSentinelAlert)}];
            int output = RBXSentinelPrefs(home);
            NSDictionary *current = RBXSentinelRead(output,RBXSentinelControlName,0);
            NSDictionary *currentReady = RBXSentinelRead(output,@"com.redditbox.hook-ready.plist",getuid());
            if ([current[@"revision"] isEqual:control[@"revision"]] && [currentReady isEqual:ready] &&
                RBXSentinelFresh(@(now),NSDate.date.timeIntervalSince1970,60)) {
                if (!RBXSentinelWrite(output,RBXSentinelReportName,report,getuid()))
                    RBXLogErr("RBX_SENTINEL container=%{public}@ probe=report result=NOT_RUN reason=receipt-write-failed",manager.containerId);
            }
            if (output >= 0) close(output);
            dispatch_async(dispatch_get_main_queue(), ^{ sSentinelRunning = NO; });
        }
    });
}

void RBXInstallIsolationSentinel(void) {
    RBXContainerManager *manager = RBXContainerManager.sharedManager;
    if (!manager.validatedProfileLoaded || !manager.isContainerized || geteuid() == 0) return;
    NSString *home = NSHomeDirectory(), *bundle = NSBundle.mainBundle.bundleIdentifier;
    int dir = RBXSentinelPrefs(home);
    if (dir < 0) return;
    NSDictionary *control = RBXSentinelRead(dir,RBXSentinelControlName,0);
    NSDictionary *ready = RBXSentinelRead(dir,@"com.redditbox.hook-ready.plist",getuid()); close(dir);
    BOOL valid = RBXSentinelControlValid(control,bundle,home.lastPathComponent,NSDate.date.timeIntervalSince1970) &&
        RBXSentinelReady(ready,bundle,getpid()) &&
        RBXSentinelFresh(ready[@"timestamp"],NSDate.date.timeIntervalSince1970,60);
    RBXSentinelRegister(control[@"settings"],valid, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (sSentinelTimer) return;
            sSentinelQueue = dispatch_queue_create("com.redditbox.isolation-sentinel",DISPATCH_QUEUE_SERIAL);
            sSentinelTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
            dispatch_source_set_event_handler(sSentinelTimer, ^{ RBXScheduleSentinel(); });
            dispatch_resume(sSentinelTimer);
            sSentinelForeground = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { RBXScheduleSentinel(); }];
            RBXScheduleSentinel();
        });
    });
}
