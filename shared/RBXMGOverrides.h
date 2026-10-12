#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Builds the canonical MobileGestalt override map from a profile's nested fields.
// Unknown explicit keys are retained for forward compatibility, but canonical
// mapped identity fields always win so overrides cannot contradict the profile.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *RBXBuildMGOverrides(NSDictionary *profile);

NS_ASSUME_NONNULL_END
