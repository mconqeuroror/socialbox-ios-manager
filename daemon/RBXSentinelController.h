#import <Foundation/Foundation.h>
@interface RBXSentinelController : NSObject
// Read-only daemon authority, installed before the publisher starts. No provider
// (or no active launch) means no current runtime evidence. Never trust a PID
// chosen only by the clone's diagnostic plist.
+ (void)setProcessIdentityProvider:(NSDictionary *(^)(void))provider;
+ (NSDictionary *)summaryForProfile:(NSDictionary *)profile siblings:(NSArray *)identifiers
                             store:(NSDictionary *)store lease:(NSDictionary *)lease;
@end
