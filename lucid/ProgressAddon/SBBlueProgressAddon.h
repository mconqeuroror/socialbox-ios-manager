#import <UIKit/UIKit.h>

// Visual show-method decoration only. Never invokes a switch, license request,
// admission callback, controller creation or metadata mutation.
BOOL SBBlueProgressAddonInstall(void);

#if SB_BLUE_PROGRESS_TESTING
// Synthetic host substitutes fixed disk/role/loaded-image observations only.
// Absent from production. Does not substitute the original loader/ABI/shape.
void SBBlueProgressFixturePins(BOOL current);
void SBBlueProgressFixtureMetadata(NSDictionary *metadata);
#endif
