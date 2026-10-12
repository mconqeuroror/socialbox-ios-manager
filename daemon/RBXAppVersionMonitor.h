#import <Foundation/Foundation.h>

// D2 — app-version drift monitor. Detects an outdated Reddit app (the installed
// bundle's CFBundleShortVersionString vs a manually maintained latest-known
// version) and records an alert in a standalone plist. Runs at daemon start and
// then every 24h. Deliberately offline: the latest-known version is configured
// by the operator (PLAN.md §11 advises pinning the Reddit version), so there are
// no network calls.

@interface RBXAppVersionMonitor : NSObject

// Runs one check immediately (call at daemon start) and schedules the recurring
// 24h timer on a background queue.
- (void)startMonitoring;

// Performs one version comparison + alert write. Exposed for tests/manual runs.
- (void)checkNow;

// Installed app version (e.g. "2025.30.0"); nil if the bundle can't be located.
+ (NSString *)installedRedditVersion;

// Latest known version from the standalone plist (default "2025.30.0").
+ (NSString *)latestKnownVersion;

@end
