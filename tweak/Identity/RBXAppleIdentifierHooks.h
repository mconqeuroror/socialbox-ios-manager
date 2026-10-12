#import <Foundation/Foundation.h>
#import "RBXProfile.h"

BOOL RBXInstallAppleIdentifierHooks(RBXDeviceProfile *profile);

// Hardware IDFA captured via %orig before the spoof is returned. Nil until the
// first advertisingIdentifier read (eagerly primed in %ctor). Used so protobuf
// scans can replace the real token with the container profile value.
NSString *RBXRealIDFAString(void);
