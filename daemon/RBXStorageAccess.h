#import <Foundation/Foundation.h>

// SGATE-002: the daemon owns inactive clone storage. Admission is separate from
// networking and always requires a fresh, globally drained process reservation.
@interface RBXStorageAccess : NSObject
+ (BOOL)closeAll:(NSError **)error;
+ (BOOL)openProfile:(NSDictionary *)profile authorized:(BOOL (^)(void))authorized error:(NSError **)error;
+ (BOOL)ownsClosedHome:(NSString *)home bundleIdentifier:(NSString *)bundle error:(NSError **)error;
// Permit installd's group to inspect code during a captured uninstall. The
// home stays closed and the main executable never gains execute permission.
+ (BOOL)performInstallerMaintenanceForBundle:(NSString *)bundle expectedBundlePath:(NSString *)path
                                  operation:(BOOL (^)(NSError **))operation error:(NSError **)error;
@end
