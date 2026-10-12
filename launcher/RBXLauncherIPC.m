#import "RBXLauncherIPC.h"
#import "RBXRequestQueue.h"
#import "RBXAppScope.h"

@implementation RBXLauncherIPC

+ (BOOL)sendAction:(NSString *)action
            values:(NSDictionary *)values
      notification:(CFStringRef)notification {
    return [self sendActionReturningRequestId:action values:values
        notification:notification] != nil;
}

+ (NSString *)sendActionReturningRequestId:(NSString *)action
                                     values:(NSDictionary *)values
                               notification:(CFStringRef)notification {
    [self migrateLegacyRequestStateIfNeeded];
    NSString *requestId = [[RBXRequestQueue defaultQueue] enqueueAction:action
        values:values ?: @{} error:nil];
    if (!requestId.length) return nil;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        notification, NULL, NULL, TRUE);
    return requestId;
}

+ (void)migrateLegacyRequestStateIfNeeded {
    @synchronized(self) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if ([defaults integerForKey:@"RBXIPCReceiptMigrationVersion"] >= 1) return;
        NSString *legacyId = [defaults stringForKey:@"RBXSourceImportRequestId"];
        if (legacyId.length) {
            NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:
                @"/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist"];
            NSDictionary *legacy = [state[@"sourceImport"] isKindOfClass:NSDictionary.class]
                ? state[@"sourceImport"] : @{};
            BOOL hasReceipt = [legacy[@"requestId"] isEqualToString:legacyId] &&
                [legacy[@"ok"] isKindOfClass:NSNumber.class] &&
                [legacy[@"completedAt"] doubleValue] > 0;
            NSString *message = hasReceipt
                ? [NSString stringWithFormat:@"Previous source import: %@",
                    [legacy[@"message"] isKindOfClass:NSString.class]
                        ? legacy[@"message"] : @"The previous version completed this import."]
                : @"Previous version source import has no receipt; check source status before retrying.";
            [defaults setObject:@{@"ok": @(hasReceipt && [legacy[@"ok"] boolValue]),
                @"message": message} forKey:@"RBXLegacySourceImportNotice"];
            // A legacy singleton request cannot be recovered or replayed safely.
            [defaults removeObjectForKey:@"RBXSourceImportRequestId"];
        }
        [defaults setInteger:1 forKey:@"RBXIPCReceiptMigrationVersion"];
    }
}

+ (NSDictionary *)legacySourceImportNotice {
    [self migrateLegacyRequestStateIfNeeded];
    return [NSUserDefaults.standardUserDefaults dictionaryForKey:@"RBXLegacySourceImportNotice"];
}

+ (NSDictionary *)requestResultForId:(NSString *)requestId {
    if (!requestId.length) return nil;
    NSDictionary *result = [[RBXRequestQueue defaultQueue]
        resultForRequestID:requestId error:nil];
    if (![result isKindOfClass:NSDictionary.class] ||
        ![result[@"requestId"] isEqualToString:requestId] ||
        ![result[@"ok"] isKindOfClass:NSNumber.class]) return nil;
    return result;
}

+ (NSString *)pendingKeyForOwner:(NSString *)owner {
    return [@"RBXPendingRequests." stringByAppendingString:owner ?: @""];
}

+ (NSArray<NSDictionary *> *)pendingRequestsForOwner:(NSString *)owner {
    NSArray *stored = [NSUserDefaults.standardUserDefaults
        arrayForKey:[self pendingKeyForOwner:owner]];
    NSMutableArray *requests = [NSMutableArray array];
    for (id request in stored) {
        if ([request isKindOfClass:NSDictionary.class] &&
            [request[@"requestId"] isKindOfClass:NSString.class] &&
            [request[@"action"] isKindOfClass:NSString.class]) [requests addObject:request];
    }
    return requests;
}

+ (NSString *)sendActionReturningRequestId:(NSString *)action
                                    values:(NSDictionary *)values
                              notification:(CFStringRef)notification
                                     owner:(NSString *)owner {
    NSString *requestId = [self sendActionReturningRequestId:action values:values
        notification:notification];
    if (!requestId.length) return nil;
    @synchronized(self) {
        NSMutableArray *requests = [[self pendingRequestsForOwner:owner] mutableCopy];
        [requests addObject:@{@"requestId": requestId, @"action": action}];
        [NSUserDefaults.standardUserDefaults setObject:requests
            forKey:[self pendingKeyForOwner:owner]];
    }
    return requestId;
}

+ (void)finishObservingRequestId:(NSString *)requestId owner:(NSString *)owner {
    @synchronized(self) {
        NSMutableArray *remaining = [NSMutableArray array];
        for (NSDictionary *request in [self pendingRequestsForOwner:owner]) {
            if (![request[@"requestId"] isEqualToString:requestId]) [remaining addObject:request];
        }
        [NSUserDefaults.standardUserDefaults setObject:remaining
            forKey:[self pendingKeyForOwner:owner]];
    }
}

+ (NSString *)sendActionReturningRequestId:(NSString *)action
                                    values:(NSDictionary *)values
                              notification:(CFStringRef)notification
                                     owner:(NSString *)owner
                                   appType:(NSString *)appType {
    NSDictionary *descriptor = [appType isKindOfClass:NSString.class] ? RBXAppDescriptorForType(appType) : nil;
    NSDictionary *scoped = RBXAppScopedRequestValues(values, descriptor);
    if (!scoped) return nil;
    return [self sendActionReturningRequestId:action values:scoped notification:notification owner:owner];
}

@end
