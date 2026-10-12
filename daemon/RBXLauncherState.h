#import <Foundation/Foundation.h>

@class RBXContainerRegistry;

NS_ASSUME_NONNULL_BEGIN

@interface RBXLauncherState : NSObject
+ (void)publishStartupRecoveryResult:(NSDictionary *)result registry:(RBXContainerRegistry *)registry;

+ (NSString *)statePath;
+ (void)publishWithRegistry:(RBXContainerRegistry *)registry;
+ (BOOL)refreshBeforeLaunchWithRegistry:(RBXContainerRegistry *)registry;
+ (void)startPeriodicPublisherWithRegistry:(RBXContainerRegistry *)registry;

@end

NS_ASSUME_NONNULL_END
