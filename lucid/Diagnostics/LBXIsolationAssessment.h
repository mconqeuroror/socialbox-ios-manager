#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Launcher metadata is deliberately a different evidence class from an
// in-application isolation probe. Refreshing this model never runs a probe.
FOUNDATION_EXPORT NSDictionary *LBXIsolationAssessment(id _Nullable snapshot, NSDate *refreshedAt);
// A fixed whitelist: excludes context names/IDs, app membership, identity,
// credentials, paths and arbitrary text from the recovered implementation.
FOUNDATION_EXPORT NSDictionary *LBXIsolationPublicReport(NSDictionary *assessment);
NS_ASSUME_NONNULL_END
