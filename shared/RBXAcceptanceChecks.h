#pragma once
#import <Foundation/Foundation.h>

// ACCEPT-001: read-only presentation of the existing launcher/diagnostic schema.
// PASS is scoped to the named observation, never to overall device isolation.
// No filesystem, IPC, network, keychain, or gate mutation occurs here.
FOUNDATION_EXPORT NSArray<NSDictionary *> *RBXAcceptanceChecks(NSDictionary *launcherState,
                                                              NSTimeInterval now);
