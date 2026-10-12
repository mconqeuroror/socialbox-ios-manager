#import <Foundation/Foundation.h>

// Feature 3.1 — shadowban / account health checker (daemon side).
//
// For each container with a username and not dead/paused, performs an
// unauthenticated GET https://www.reddit.com/user/{username}/about.json
// THROUGH that container's proxy. If no proxy is configured/valid the check is
// skipped and logged — the phone's direct IP is never used (acceptance #7).
//
// Status mapping (calibration):
//   default {200: healthy, 403: suspended, 404: shadowbanned} — editable in
//   the central store under health.calibration. Calibration mode
//   (health.calibrationMode) logs full status + body snippet (first 500 bytes)
//   and does NOT change container status, so the operator can verify the
//   mapping against a real banned test account.
//
// Gold-standard backup (documented, intentionally NOT implemented here): post a
// test comment to a decoy subreddit from the container and verify visibility
// from an incognito session. Anonymous about.json is the cheap approximation.

NS_ASSUME_NONNULL_BEGIN

@interface RBXHealthChecker : NSObject

// Singleton (used by the darwin-notification callback path in main.m).
+ (instancetype)sharedChecker;

// Start the scheduled timer (interval from store.health.intervalSeconds,
// default 6h) and listen for the on-demand darwin notification
// "com.redditbox.healthCheck".
- (void)start;

// Run checks for all eligible containers now.
- (void)runChecks;

// Check a single container (used by the on-demand path and fresh accounts).
- (void)checkContainer:(NSString *)containerId;

// Fresh-account check: invoked after container creation / first login. If the
// account is shadowbanned from day one, sets status red, deathReason=shadowban
// and adds a FRESH ACCOUNT BANNED alert.
- (void)checkFreshAccount:(NSString *)containerId;

@end

NS_ASSUME_NONNULL_END
