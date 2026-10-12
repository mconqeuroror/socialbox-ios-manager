// Exercise the actual launcher IPC overload with inert queue/preferences/notify.
// No daemon request, Darwin notification, or user preference is published.
#import <Foundation/Foundation.h>
#import "../shared/RBXRequestQueue.h"
#import "../launcher/RBXAppScope.h"
static NSMutableDictionary *FixturePreferences;
static NSMutableArray *FixtureQueue;
static NSUInteger FixtureNotifications;
@interface RBXAppIPCDefaults : NSObject
+ (instancetype)standardUserDefaults;
- (NSInteger)integerForKey:(NSString *)key;
- (NSString *)stringForKey:(NSString *)key;
- (NSArray *)arrayForKey:(NSString *)key;
- (NSDictionary *)dictionaryForKey:(NSString *)key;
- (void)setInteger:(NSInteger)value forKey:(NSString *)key;
- (void)setObject:(id)value forKey:(NSString *)key;
- (void)removeObjectForKey:(NSString *)key;
@end
@implementation RBXAppIPCDefaults
+ (instancetype)standardUserDefaults { return [self new]; }
- (NSInteger)integerForKey:(NSString *)key { return [FixturePreferences[key] integerValue]; }
- (NSString *)stringForKey:(NSString *)key { return FixturePreferences[key]; }
- (NSArray *)arrayForKey:(NSString *)key { return FixturePreferences[key]; }
- (NSDictionary *)dictionaryForKey:(NSString *)key { return FixturePreferences[key]; }
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { FixturePreferences[key] = @(value); }
- (void)setObject:(id)value forKey:(NSString *)key { FixturePreferences[key] = value; }
- (void)removeObjectForKey:(NSString *)key { [FixturePreferences removeObjectForKey:key]; }
@end
@interface RBXAppIPCQueue : NSObject
+ (instancetype)defaultQueue;
- (NSString *)enqueueAction:(NSString *)action values:(NSDictionary *)values error:(NSError **)error;
- (NSDictionary *)resultForRequestID:(NSString *)request error:(NSError **)error;
@end
@implementation RBXAppIPCQueue
+ (instancetype)defaultQueue { return [self new]; }
- (NSString *)enqueueAction:(NSString *)action values:(NSDictionary *)values error:(NSError **)error {
    NSString *request = [NSString stringWithFormat:@"request-%lu", (unsigned long)FixtureQueue.count];
    [FixtureQueue addObject:@{@"requestId":request,@"action":action,@"values":values}]; return request;
}
- (NSDictionary *)resultForRequestID:(NSString *)request error:(NSError **)error { return nil; }
@end
static void RBXFixtureNotify(CFNotificationCenterRef center, CFNotificationName name,
                            const void *object, CFDictionaryRef userInfo, Boolean immediately) {
    FixtureNotifications++;
}
#define NSUserDefaults RBXAppIPCDefaults
#define RBXRequestQueue RBXAppIPCQueue
#define CFNotificationCenterPostNotification RBXFixtureNotify
#import "../launcher/RBXLauncherIPC.m"
#undef CFNotificationCenterPostNotification
#undef RBXRequestQueue
#undef NSUserDefaults
static void Check(BOOL ok, NSString *message) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
int main(void) { @autoreleasepool {
    FixturePreferences = [@{@"RBXIPCReceiptMigrationVersion":@1} mutableCopy];
    FixtureQueue = [NSMutableArray array];
    NSString *rd = [RBXLauncherIPC sendActionReturningRequestId:@"createContainer" values:@{@"container":@"legacy"}
        notification:CFSTR("fixture") owner:@"simple-wizard" appType:@"reddit"];
    NSString *fb = [RBXLauncherIPC sendActionReturningRequestId:@"createContainer" values:@{@"container":@"fb"}
        notification:CFSTR("fixture") owner:@"simple-wizard.facebook" appType:@"facebook"];
    Check(rd.length && fb.length && FixtureQueue.count == 2 && FixtureNotifications == 2, @"both typed requests queued once");
    Check([FixtureQueue[0][@"values"] isEqual:@{@"container":@"legacy",@"appType":@"reddit"}], @"Reddit payload preserved with additive type");
    Check([FixtureQueue[1][@"values"] isEqual:@{@"container":@"fb",@"appType":@"facebook"}], @"Facebook create carries explicit type");
    Check([[RBXLauncherIPC pendingRequestsForOwner:@"simple-wizard"].firstObject[@"requestId"] isEqual:rd], @"legacy owner receives only its own durable receipt");
    Check([[RBXLauncherIPC pendingRequestsForOwner:@"simple-wizard.facebook"].firstObject[@"requestId"] isEqual:fb], @"Facebook owner cannot recover Reddit receipt");
    [RBXLauncherIPC finishObservingRequestId:fb owner:@"simple-wizard.facebook"];
    Check([RBXLauncherIPC pendingRequestsForOwner:@"simple-wizard.facebook"].count == 0 && [RBXLauncherIPC pendingRequestsForOwner:@"simple-wizard"].count == 1, @"finishing FB receipt cannot clear Reddit pending work");
    for (NSString *action in @[@"import-source",@"runDiagnostics"]) {
        NSString *request = [RBXLauncherIPC sendActionReturningRequestId:action values:@{} notification:CFSTR("fixture") owner:@"settings.facebook" appType:@"facebook"];
        Check(request.length && [FixtureQueue.lastObject[@"values"][@"appType"] isEqual:@"facebook"], @"inactive registered app permits source import and diagnostics inspection");
    }
    NSUInteger queued = FixtureQueue.count, notified = FixtureNotifications;
    NSDictionary *preferencesBefore = [FixturePreferences copy];
    Check(![RBXLauncherIPC sendActionReturningRequestId:@"launchContainer" values:@{@"container":@"legacy",@"appType":@"reddit"} notification:CFSTR("fixture") owner:@"launcher.facebook" appType:@"facebook"], @"cross-app payload rejected");
    for (id type in @[@"unknown",NSNull.null]) Check(![RBXLauncherIPC sendActionReturningRequestId:@"createContainer" values:@{} notification:CFSTR("fixture") owner:@"launcher" appType:type], @"invalid app rejected");
    Check(![RBXLauncherIPC sendActionReturningRequestId:@"createContainer" values:@{} notification:CFSTR("fixture") owner:@"launcher" appType:nil], @"typed entry point never silently chooses Reddit");
    Check(FixtureQueue.count == queued && FixtureNotifications == notified && [FixturePreferences isEqual:preferencesBefore], @"rejected requests have no queue, notification or durable-observation side effects");
    puts("PASS: actual app-typed IPC, durable owner separation and mismatch rejection");
} return 0; }
