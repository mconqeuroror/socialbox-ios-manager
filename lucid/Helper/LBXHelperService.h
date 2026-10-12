#pragma once
#import <Foundation/Foundation.h>
#import "LBXHelperProtocol.h"

NS_ASSUME_NONNULL_BEGIN
@interface LBXHelperService : NSObject <LBXHelperProtocol, NSXPCListenerDelegate>
@end
NS_ASSUME_NONNULL_END
