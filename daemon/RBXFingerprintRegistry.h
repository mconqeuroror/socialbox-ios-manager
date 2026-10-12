#import <Foundation/Foundation.h>

// Feature 2.4 — fingerprint registry (daemon side).
// Computes a per-container bundleHash (FNV-1a 64-bit over sorted
// "userAgent|model|screen|locale|timezone" fields from the profile + observed
// User-Agent) and flags FINGERPRINT DUP when two LIVE containers collide.

NS_ASSUME_NONNULL_BEGIN

@interface RBXFingerprintRegistry : NSObject

// FNV-1a 64-bit over the string, returned as 16 uppercase hex chars.
+ (NSString *)hashString:(NSString *)input;

// bundleHash inputs from a container profile dict + observed user agent.
// Order-independent: parts are sorted before hashing so semantically identical
// sets produce the same hash.
// Returns nil when the required profile fields or observed UA are malformed.
+ (nullable NSString *)bundleHashForProfile:(nullable NSDictionary *)profile
                       observedUA:(nullable NSString *)userAgent;

// Recompute + persist bundle hashes for all containers, then check for
// duplicates among LIVE containers (not dead, not paused). Adds
// "FINGERPRINT DUP" alerts (one per colliding pair, deduped).
- (void)refreshAndCheck;
@end

NS_ASSUME_NONNULL_END
