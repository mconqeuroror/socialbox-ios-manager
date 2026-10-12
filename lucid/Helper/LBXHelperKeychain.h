#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Agrp token is LBX_SOCIALBOX_KEYCHAIN_TOKEN → pattern %.s_o_c_i_a_l_b_o_x.<CID>
FOUNDATION_EXPORT NSString *LBXHelperAccessGroupForContainer(long long containerID);
FOUNDATION_EXPORT NSDictionary * _Nullable LBXHelperDumpKeychain(NSString *bundleID,
                                                                 long long containerID,
                                                                 NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL LBXHelperRestoreKeychain(NSDictionary *items, NSString *bundleID,
                                                long long containerID,
                                                NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL LBXHelperClearKeychain(NSString *bundleID, BOOL nuclear,
                                              NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
