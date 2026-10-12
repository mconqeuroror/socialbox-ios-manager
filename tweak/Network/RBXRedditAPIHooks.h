#import <Foundation/Foundation.h>
#import "RBXProfile.h"

// Reddit API header/body rewrite (install UUID, X-Dev-Ad-Id, Device-Name, UA,
// install timestamp, analytics device fields). Forces per-container wire
// identity on reddit.com / redditmedia / snooguts / redditstatic hosts and
// rewrites matching JSON / form / protobuf keys on any host. Passes through
// with no profile. Isolates loid / session / installation_id UserDefaults
// keys and remaps non-Apple suites (incl. app groups) onto the container.

BOOL RBXInstallRedditAPIHooks(RBXDeviceProfile *profile);
