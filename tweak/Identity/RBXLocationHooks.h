#import <Foundation/Foundation.h>

// C3 — GPS location hooks (CLLocationManager). Delivers a spoofed fix from the
// container profile (device.location.{lat,lon}) to the app's delegate with a
// small per-fix jitter, plus a stable last-known location. Limitations (accepted,
// best-effort per spec): significant-location-change monitoring, visit
// monitoring, region monitoring, heading/fused (CLGeocoder reverse-geocode of
// the spoofed point) are not covered. Installs itself via %ctor; passes through
// unchanged when no profile is loaded.

BOOL RBXInstallLocationHooks(void);
