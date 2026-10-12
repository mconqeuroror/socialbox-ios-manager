#import <Foundation/Foundation.h>

// C1 — locale identity hooks. +[NSLocale currentLocale/systemLocale] and
// +[NSLocale preferredLanguages] answer from the container profile (device.locale /
// device.language); -[NSLocale localeIdentifier] is spoofed only for the instances
// we handed out. Installs itself via %ctor; every hook passes through unchanged
// when no profile is loaded.

BOOL RBXInstallLocaleHooks(void);
