#import <Foundation/Foundation.h>

// B5 — battery-level offset. 50 accounts with a perfectly synchronized battery
// level is a soft cross-link, so each container adds a stable per-container
// offset from its profile (timing.batteryOffsetPercent, -8...+8) to the REAL
// level. Charging state stays real. Installs itself via %ctor; passes through
// unchanged when no profile is loaded.

BOOL RBXInstallBatteryHooks(void);
