#import <Preferences/Preferences.h>

// Container management pane: list / add / delete, per-container proxy URL,
// per-container IDFA posture. Actions go to the daemon via the pending plist
// + com.redditbox.containerAction doorbell (prefs never generates profiles).

@interface RBXContainersListController : PSListController
@end
