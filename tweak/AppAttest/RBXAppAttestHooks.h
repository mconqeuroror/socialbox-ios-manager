#import <Foundation/Foundation.h>

// App Attest / DeviceCheck control module (Feature 1 + 2.2).
// - Per-container + global attest toggle: OFF makes the app see DeviceCheck-style
//   errors so it gracefully skips attestation (like an old iPhone); ON passes
//   through and the key is recorded in the central store.
// - Key budget tracking (device.attestKeysUsed) with threshold alerts.
// - KeyId dedup guard: a container reusing another container's key (cloned
//   keychain) gets attest blocked so a dead account's key is never re-sent.
// - DCDevice.generateToken fail-closed: default OFF, and always blocked when
//   the container's attest mode is OFF (no shared hardware token).

// DeviceCheck error domain/code used for synthetic failures. The public headers
// declare DCErrorDomain/DCErrorUnknown; we reference them when the framework
// headers provide them, falling back to the literal domain string.
FOUNDATION_EXPORT NSString *const RBXDeviceCheckErrorDomain;

// Called from the tweak ctor (or lazily): installs hooks, seeds the container
// entry in the central store, and registers for storeChanged refreshes.
BOOL RBXInstallAppAttestHooks(void);

@interface RBXAppAttestHooks : NSObject

// Effective attest mode for the current process's container ("on"|"off").
+ (NSString *)effectiveMode;

// Number of keys recorded device-wide (from the central store).
+ (NSInteger)attestKeyCount;

@end
