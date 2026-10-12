#import <Foundation/Foundation.h>

@class RBXContainerRegistry;

NS_ASSUME_NONNULL_BEGIN

@interface RBXDiagnostics : NSObject
+ (NSDictionary *)runWithRegistry:(RBXContainerRegistry *)registry;
+ (NSDictionary *)exportSupportLog;
@end

NS_ASSUME_NONNULL_END
