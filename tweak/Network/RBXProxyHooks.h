#import <Foundation/Foundation.h>
#import "RBXProfile.h"

BOOL RBXInstallProxyHooks(RBXDeviceProfile *profile);
void RBXApplyProxyToConfiguration(NSURLSessionConfiguration *cfg);

BOOL RBXVerifyProxyHooks(void);
