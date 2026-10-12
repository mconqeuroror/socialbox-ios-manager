#import <Foundation/Foundation.h>
#import "RBXProfile.h"

// Resolves this clone from its own provisioned profile or signed bootstrap.
// Malformed/missing identity gets a synthetic fallback with readiness denied.
// Shared active bindings and default profiles never authorize clone traffic.

@interface RBXContainerManager : NSObject

@property (nonatomic, readonly) NSString *containerId;
@property (nonatomic, readonly) BOOL isContainerized;
@property (nonatomic, readonly) RBXDeviceProfile *currentProfile;
@property (nonatomic, readonly) BOOL validatedProfileLoaded;

+ (instancetype)sharedManager;

// Root of this process's per-container app data, inside the real app sandbox.
// Other clones receive separate OS-assigned sandboxes.
- (NSString *)containerDataDirectory;
- (NSString *)containerKeychainAccessGroupSuffix;   // e.g. ".rbx.model-alice"
- (NSString *)currentProxyURL;
- (void)runAcceptanceProbeIfRequested;

@end
