#import <Foundation/Foundation.h>

// Daemon-side leak monitors (Features 2.1 + 2.3).
//  - PUSH LEAK: two LIVE containers share a non-null push token
//  - IP LINK: two LIVE containers made requests within an overlapping window
//    (last 10 minutes) using the same proxyId
// Runs periodically alongside the health checker and on demand.

NS_ASSUME_NONNULL_BEGIN

@interface RBXLeakMonitor : NSObject

+ (instancetype)sharedMonitor;

// Start the periodic monitor loop (default every 5 minutes).
- (void)start;

// Run one pass now (also invoked by the periodic loop).
- (void)runLeakChecks;

@end

NS_ASSUME_NONNULL_END
