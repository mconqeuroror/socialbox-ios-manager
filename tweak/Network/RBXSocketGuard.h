#import <Foundation/Foundation.h>

BOOL RBXInstallSocketGuard(void);
BOOL RBXVerifySocketGuard(NSError **error);
BOOL RBXNetworkLeaseAllowsCurrentContainer(void);
NSString *RBXNetworkLeaseProxyURL(void);
void RBXMarkAllHooksReady(NSDictionary *installed, NSDictionary *(^behaviorChecks)(void));
NSString *RBXNetworkLeaseGeneration(void);
NSString *RBXNetworkLeaseExitIP(void);
BOOL RBXSystemFirewallMatchesCurrentLease(void);
BOOL RBXSystemFirewallCoversOutOfProcessAuth(void);

NSString *RBXNetworkLeaseProxyAddress(void);
