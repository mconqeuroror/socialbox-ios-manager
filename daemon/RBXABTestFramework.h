#import <Foundation/Foundation.h>

// Feature 5 — A/B test framework for App Attest ON vs OFF.
// On container creation: assign group A/B 50/50 (arc4random_uniform(2)),
// store in attest.group. Effective attest for "auto" mode = group default
// (A=ON, B=OFF). Lifecycle fields (createdAt, diedAt, deathReason,
// missionCompleted) already live in the central store; this class seeds the
// group + createdAt and provides the report data for the prefs dashboard.

NS_ASSUME_NONNULL_BEGIN

@interface RBXABTestFramework : NSObject

// Assign a group to the container and record createdAt. Called by the daemon
// right after a new container (profile) is created.
+ (void)assignGroupForContainer:(NSString *)containerId;

// Mark mission completed (operator taps "done" in prefs or the daemon
// detects the mission goal).
+ (void)markMissionCompleted:(NSString *)containerId;

// Group for an existing container (nil if unassigned).
+ (nullable NSString *)groupForContainer:(NSString *)containerId;

@end

NS_ASSUME_NONNULL_END
