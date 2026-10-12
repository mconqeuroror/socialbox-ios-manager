#import <UIKit/UIKit.h>

// Decoration of the pinned Containers loading overlay only. No switch action,
// timer, message, admission or completion is started or replaced here.
BOOL SBSwitchProgressInstall(void);
#if LBX_PRESENTATION_FIXTURE
void SBSwitchProgressFixtureReduceMotion(UIView *glyph, BOOL reduced);
#endif
