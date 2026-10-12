#import "RBXHookInstallation.h"
#import "RBXNotificationHooks.h"
#import "RBXContainerManager.h"
#import "RBXLog.h"
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <BackgroundTasks/BackgroundTasks.h>

static NSError *RBXNotificationBlockedError(void) {
    return [NSError errorWithDomain:@"com.redditbox.notifications" code:1
        userInfo:@{NSLocalizedDescriptionKey:
            @"Notifications are disabled for container isolation"}];
}

%hook UNUserNotificationCenter

- (void)addNotificationRequest:(UNNotificationRequest *)request
         withCompletionHandler:(void (^)(NSError *error))completionHandler {
    if (completionHandler) completionHandler(RBXNotificationBlockedError());
}

- (void)getPendingNotificationRequestsWithCompletionHandler:
    (void (^)(NSArray<UNNotificationRequest *> *requests))completionHandler {
    if (completionHandler) completionHandler(@[]);
}

- (void)getDeliveredNotificationsWithCompletionHandler:
    (void (^)(NSArray<UNNotification *> *notifications))completionHandler {
    if (completionHandler) completionHandler(@[]);
}

- (void)removePendingNotificationRequestsWithIdentifiers:(NSArray<NSString *> *)identifiers {}
- (void)removeAllPendingNotificationRequests {}
- (void)removeDeliveredNotificationsWithIdentifiers:(NSArray<NSString *> *)identifiers {}
- (void)removeAllDeliveredNotifications {}

%end

%hook BGTaskScheduler

- (BOOL)registerForTaskWithIdentifier:(NSString *)identifier
                           usingQueue:(dispatch_queue_t)queue
                        launchHandler:(void (^)(BGTask *task))launchHandler {
    return NO;
}
- (BOOL)submitTaskRequest:(BGTaskRequest *)taskRequest error:(NSError **)error {
    if (error) *error = RBXNotificationBlockedError();
    return NO;
}
- (void)cancelTaskRequestWithIdentifier:(NSString *)identifier {}
- (void)cancelAllTaskRequests {}

%end

%hook UIApplication

- (void)scheduleLocalNotification:(UILocalNotification *)notification {}
- (void)presentLocalNotificationNow:(UILocalNotification *)notification {}
- (NSArray<UILocalNotification *> *)scheduledLocalNotifications { return @[]; }
- (void)setScheduledLocalNotifications:(NSArray<UILocalNotification *> *)notifications {}
- (void)cancelLocalNotification:(UILocalNotification *)notification {}
- (void)cancelAllLocalNotifications {}
- (void)setMinimumBackgroundFetchInterval:(NSTimeInterval)minimumBackgroundFetchInterval {}
- (UIBackgroundRefreshStatus)backgroundRefreshStatus {
    return UIBackgroundRefreshStatusDenied;
}

%end

BOOL RBXInstallNotificationHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        %init;
        RBXLog("local/pending notification installation checked=%d container=%@", RBXHookInstallationPassed(),
               [RBXContainerManager sharedManager].containerId);
    });
    return RBXHookInstallationPassed();
}
