#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Per-container storage switching for a whole SocialBox "phone":
// Instagram + Facebook + their shared Meta folders, moved together.
//
// Each installed app still runs against its single system data container
// plus group / PluginKit roots. Each SocialBox container keeps a copy of
// those payloads in a slot under the store root on the same volume:
//   Store/<bundleID>/<cid>/Data
//   Store/<bundleID>/<cid>/<app-private group>
//   Store/Shared/<cid>/<shared group>
//   Store/Shared/<cid>/PluginKit/<extension id>
// Switching uses rename(2). The container-manager identity metadata stays
// in place. The caller must drain Instagram and Facebook first.
FOUNDATION_EXPORT NSString *const LBXHelperStorageRoot;
FOUNDATION_EXPORT NSString *const LBXHelperSharedStoreKey;

FOUNDATION_EXPORT NSString *_Nullable LBXHelperLiveDataContainer(NSString *bundleID,
                                                                 NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT long long LBXHelperLoadedContainerID(NSString *bundleID);
FOUNDATION_EXPORT BOOL LBXHelperSwitchContainerStorage(NSString *bundleID, long long fromContainerID,
                                                       long long toContainerID,
                                                       NSError *_Nullable *_Nullable error);
// Drains are the caller's job. Moves Instagram, Facebook, shared Meta groups
// and PluginKit extension data as one unit. Restarts cfprefsd once.
FOUNDATION_EXPORT BOOL LBXHelperSwitchPhoneStorage(long long fromContainerID, long long toContainerID,
                                                   NSError *_Nullable *_Nullable error);
// Removes parked payload slots. Refuses the currently loaded phone.
FOUNDATION_EXPORT BOOL LBXHelperDeleteContainerStorage(long long containerID,
                                                       NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT NSDictionary *LBXHelperDataSeparationReport(long long containerID);

NS_ASSUME_NONNULL_END
