#import <Foundation/Foundation.h>
#import "RBXProfile.h"

BOOL RBXInstallDeviceHooks(RBXDeviceProfile *profile);

// Hardware IDFV captured via %orig before the spoof is returned. Nil until the
// first identifierForVendor read (eagerly primed in %ctor).
NSString *RBXRealIDFVString(void);
