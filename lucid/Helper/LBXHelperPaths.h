#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL LBXHelperIsIGOrFB(NSString * _Nullable bundleID);
FOUNDATION_EXPORT BOOL LBXHelperIsNumericContainerID(long long containerID);
FOUNDATION_EXPORT NSString *LBXHelperProfileStoreRoot(void);
FOUNDATION_EXPORT NSString *LBXHelperContainerTreePath(NSString *bundleID, long long containerID);
FOUNDATION_EXPORT BOOL LBXHelperPathUnderControlTree(NSString *path);
FOUNDATION_EXPORT NSString * _Nullable LBXHelperStandardizeAllowedPath(NSString *path);
FOUNDATION_EXPORT BOOL LBXHelperBootstrapContainerTree(NSString *bundleID, long long containerID,
                                                       NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL LBXHelperTeardownContainerTree(NSString *bundleID, long long containerID,
                                                      NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL LBXHelperChownRecursiveToMobile(NSString *path,
                                                       NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
