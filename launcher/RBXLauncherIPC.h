#import <Foundation/Foundation.h>

@interface RBXLauncherIPC : NSObject
+ (BOOL)sendAction:(NSString *)action
            values:(NSDictionary *)values
      notification:(CFStringRef)notification;
+ (nullable NSString *)sendActionReturningRequestId:(NSString *)action
                                             values:(NSDictionary *)values
                                       notification:(CFStringRef)notification;
+ (nullable NSDictionary *)requestResultForId:(NSString *)requestId;
// Persist only IDs/actions so results survive launcher suspension or restart.
+ (nullable NSString *)sendActionReturningRequestId:(NSString *)action
                                             values:(NSDictionary *)values
                                       notification:(CFStringRef)notification
                                              owner:(NSString *)owner;
+ (NSArray<NSDictionary *> *)pendingRequestsForOwner:(NSString *)owner;
+ (void)finishObservingRequestId:(NSString *)requestId owner:(NSString *)owner;
+ (void)migrateLegacyRequestStateIfNeeded;
+ (nullable NSDictionary *)legacySourceImportNotice;
+ (nullable NSString *)sendActionReturningRequestId:(NSString *)action
                                             values:(NSDictionary *)values
                                       notification:(CFStringRef)notification
                                              owner:(NSString *)owner
                                            appType:(NSString *)appType;
@end
