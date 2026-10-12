#import <Foundation/Foundation.h>

// C2 — timezone identity hooks. +[NSTimeZone systemTimeZone/localTimeZone/
// defaultTimeZone] answer from the container profile (device.timezone);
// +[NSTimeZone timeZoneWithName:] only spoofed for the profile's own zone.
// Installs itself via %ctor; every hook passes through unchanged when no
// profile is loaded.

BOOL RBXInstallTimezoneHooks(void);
