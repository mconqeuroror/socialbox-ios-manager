#import <Foundation/Foundation.h>
#import "RBXContainerManager.h"

void RBXInstallKeychainHooks(RBXContainerManager *mgr);
// Independent of the legacy item-namespace hooks above. Absent policy is an
// explicit pass-through; local-only constrains only synchronizable selectors.
BOOL RBXInstallKeychainSyncPolicy(RBXContainerManager *mgr);
