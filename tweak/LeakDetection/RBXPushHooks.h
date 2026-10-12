#import <Foundation/Foundation.h>

// Feature 2.1 — push token monitor + block.
// - registerForRemoteNotifications no-ops when the container's push toggle is OFF
//   (default OFF): the shared APNs token is a top correlation signal.
// - The app-delegate token callback never receives the hardware APNs token. A
//   per-container dummy is substituted (or the callback is skipped when push is
//   OFF) so two containers cannot share a real or fake token.
// - Token capture still records the hardware hex into the store for the daemon
//   PUSH LEAK monitor, but that value is not returned to Reddit.

BOOL RBXInstallPushHooks(void);

// 32-byte APNs-shaped dummy, unique and stable per container. Never the
// hardware token. Used by API/protobuf rewrite when a token field appears.
NSString *RBXContainerDummyPushTokenHex(void);
NSData *RBXContainerDummyPushTokenData(void);
NSString *RBXCapturedRealPushTokenHex(void);
NSData *RBXCapturedRealPushTokenData(void);
