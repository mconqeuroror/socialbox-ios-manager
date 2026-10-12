#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class LBXHelperClient;

FOUNDATION_EXPORT NSString *const LBXContainerStoreInstagram;
FOUNDATION_EXPORT NSString *const LBXContainerStoreFacebook;

@interface LBXContainerRecord : NSObject
@property(nonatomic) long long containerID;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSArray<NSString *> *apps;
@end

@interface LBXContainerStore : NSObject
@property(nonatomic, readonly) NSString *controlRoot;
@property(nonatomic, readonly) NSString *profileStoreRoot;
@property(nonatomic, readonly) NSString *runtimeRoot;

- (NSArray<LBXContainerRecord *> *)listContainers:(NSError *_Nullable *_Nullable)error;
- (nullable LBXContainerRecord *)containerWithID:(long long)containerID
                                          error:(NSError *_Nullable *_Nullable)error;
- (long long)activeContainerIDForBundleID:(NSString *)bundleID
                                   error:(NSError *_Nullable *_Nullable)error;
- (BOOL)setActiveContainerID:(long long)containerID
                 forBundleID:(NSString *)bundleID
                       error:(NSError *_Nullable *_Nullable)error;
- (BOOL)setGlobalActiveContainerID:(long long)containerID
                             error:(NSError *_Nullable *_Nullable)error;
- (long long)nextContainerID:(NSError *_Nullable *_Nullable)error;
- (BOOL)upsertContainer:(LBXContainerRecord *)record error:(NSError *_Nullable *_Nullable)error;
- (BOOL)renameContainerID:(long long)containerID
                   toName:(NSString *)name
                    error:(NSError *_Nullable *_Nullable)error;
// Switches the whole phone: Instagram, Facebook and shared Meta folders move
// together. bundleIDs is accepted for callers that still pass a list; the
// payload swap is always the unit switch.
- (BOOL)activateContainerID:(long long)containerID
               forBundleIDs:(NSArray<NSString *> *)bundleIDs
                     helper:(LBXHelperClient *)helper
                      error:(NSError *_Nullable *_Nullable)error;
- (BOOL)deleteContainerID:(long long)containerID
                   helper:(LBXHelperClient *)helper
                    error:(NSError *_Nullable *_Nullable)error;
- (NSString *)controlPathForBundleID:(NSString *)bundleID containerID:(long long)containerID;
- (NSString *)profilePathForContainerID:(long long)containerID;
- (BOOL)writeRuntimeSelection:(long long)containerID
                  forBundleID:(NSString *)bundleID
                        error:(NSError *_Nullable *_Nullable)error;
- (NSDictionary *)verifyIsolationForBundleID:(NSString *)bundleID
                                 containerID:(long long)containerID;
- (NSDictionary *)verifyDataSeparationForContainerID:(long long)containerID
                                              helper:(nullable LBXHelperClient *)helper;
@end

NS_ASSUME_NONNULL_END
