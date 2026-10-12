#import "LBXDrainProtocol.h"
NS_ASSUME_NONNULL_BEGIN
// One completion, bounded request, no spawn/waitpid, no original/name-kill fallback.
FOUNDATION_EXPORT void LBXRequestApplicationDrain(NSString *bundleID, void (^completion)(BOOL));
FOUNDATION_EXPORT void LBXCheckDrainService(void (^completion)(BOOL));
NS_ASSUME_NONNULL_END
