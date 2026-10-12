#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL LBXHelperAtomicBatchSwap(NSArray *operations, BOOL contents,
                                                NSError * _Nullable * _Nullable error);
NS_ASSUME_NONNULL_END
