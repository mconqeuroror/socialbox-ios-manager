#import "RBXHookInstallation.h"
#import "RBXSysctlHooks.h"
#import "RBXProfile.h"
#import "RBXContainerManager.h"
#import "RBXLog.h"
#import <Foundation/Foundation.h>
#import <sys/sysctl.h>
#import <sys/types.h>
#import <sys/utsname.h>
#import <string.h>
#import <stdlib.h>
#import <time.h>
#import <substrate.h>
#import <errno.h>

// sysctl / uname / boot-time spoofing. Apps read hw.machine, hw.model, hw.memsize,
// kern.boottime, kern.osrelease directly; without hooks these leak the real device
// even when MobileGestalt is fully spoofed.

static RBXDeviceProfile *rbxProfile(void) {
    return [RBXContainerManager sharedManager].currentProfile;
}

static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int (*orig_uname)(struct utsname *);

static int replaced_sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                                void *newp, size_t newlen) {
    RBXDeviceProfile *p = rbxProfile();
    if (!p || !name || !oldlenp) {
        errno = EPERM;
        return -1;
    }
    if (strncmp(name, "kern.proc", 9) == 0) {
        errno = EPERM;
        return -1;
    }

    if (strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.model") == 0) {
        NSString *value = strcmp(name, "hw.model") == 0
            ? [p valueForPath:@"device.hwModelStr"] : p.productType;
        size_t required = strlen(value.UTF8String) + 1;
        if (!oldp) { *oldlenp = required; return 0; }
        if (*oldlenp < required) { *oldlenp = required; errno = ENOMEM; return -1; }
        memcpy(oldp, value.UTF8String, required);
        *oldlenp = required;
        return 0;
    } else if (strcmp(name, "hw.memsize") == 0) {
        NSString *ram = [p valueForPath:@"device.ramBytes"];
        if (!oldp) { *oldlenp = sizeof(uint64_t); return 0; }
        if (*oldlenp < sizeof(uint64_t)) { *oldlenp = sizeof(uint64_t); errno = ENOMEM; return -1; }
        uint64_t bytes = strtoull(ram.UTF8String, NULL, 10);
        memcpy(oldp, &bytes, sizeof(bytes));
        *oldlenp = sizeof(bytes);
        return 0;
    } else if (strcmp(name, "kern.boottime") == 0) {
        static struct timeval syntheticBoot;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSTimeInterval epoch = [[p valueForPath:@"timing.syntheticBootEpoch"] doubleValue];
            NSTimeInterval uptime = MAX(3600.0,
                [[p valueForPath:@"timing.bootTimeOffsetSeconds"] doubleValue]);
            syntheticBoot.tv_sec = epoch > 0 ? (time_t)epoch : time(NULL) - (time_t)uptime;
            syntheticBoot.tv_usec = (suseconds_t)((p.containerId.hash % 1000) * 1000);
        });
        if (!oldp) { *oldlenp = sizeof(syntheticBoot); return 0; }
        if (*oldlenp < sizeof(syntheticBoot)) {
            *oldlenp = sizeof(syntheticBoot); errno = ENOMEM; return -1;
        }
        memcpy(oldp, &syntheticBoot, sizeof(syntheticBoot));
        *oldlenp = sizeof(syntheticBoot);
        return 0;
    } else if (strcmp(name, "kern.osrelease") == 0 ||
               strcmp(name, "kern.version") == 0 ||
               strcmp(name, "kern.osversion") == 0 ||
               strcmp(name, "kern.bootsessionuuid") == 0 ||
               strcmp(name, "kern.bootargs") == 0) {
        NSString *rel = nil;
        if (strcmp(name, "kern.osrelease") == 0) {
            rel = [p valueForPath:@"device.darwinRelease"];
        } else if (strcmp(name, "kern.version") == 0) {
            rel = [NSString stringWithFormat:@"Darwin Kernel Version %@",
                   [p valueForPath:@"device.darwinRelease"] ?: @"23.5.0"];
        } else if (strcmp(name, "kern.osversion") == 0) {
            rel = [p valueForPath:@"device.buildVersion"];
        } else if (strcmp(name, "kern.bootsessionuuid") == 0) {
            rel = [p valueForPath:@"serials.platformUUID"];
        } else {
            rel = @"";
        }
        size_t required = strlen(rel.UTF8String) + 1;
        if (!oldp) { *oldlenp = required; return 0; }
        if (*oldlenp < required) { *oldlenp = required; errno = ENOMEM; return -1; }
        memcpy(oldp, rel.UTF8String, required);
        *oldlenp = required;
        return 0;
    } else if (strcmp(name, "hw.uuid") == 0 || strcmp(name, "kern.uuid") == 0) {
        NSString *uuid = [p valueForPath:@"serials.platformUUID"];
        size_t required = strlen(uuid.UTF8String) + 1;
        if (!oldp) { *oldlenp = required; return 0; }
        if (*oldlenp < required) { *oldlenp = required; errno = ENOMEM; return -1; }
        memcpy(oldp, uuid.UTF8String, required);
        *oldlenp = required;
        return 0;
    } else if (strcmp(name, "kern.hostname") == 0) {
        NSString *hostname = p.deviceName ?: @"iPhone";
        size_t required = strlen(hostname.UTF8String) + 1;
        if (!oldp) { *oldlenp = required; return 0; }
        if (*oldlenp < required) { *oldlenp = required; errno = ENOMEM; return -1; }
        memcpy(oldp, hostname.UTF8String, required);
        *oldlenp = required;
        return 0;
    }
    return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

static int replaced_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                           void *newp, size_t newlen) {
    if (name && namelen >= 2) {
        const char *mapped = NULL;
        if (name[0] == CTL_HW) {
            if (name[1] == HW_MACHINE) mapped = "hw.machine";
            else if (name[1] == HW_MODEL) mapped = "hw.model";
            else if (name[1] == HW_MEMSIZE) mapped = "hw.memsize";
        } else if (name[0] == CTL_KERN) {
            if (name[1] == KERN_PROC) {
                errno = EPERM;
                return -1;
            }
            if (name[1] == KERN_BOOTTIME) mapped = "kern.boottime";
            else if (name[1] == KERN_OSRELEASE) mapped = "kern.osrelease";
            else if (name[1] == KERN_OSVERSION) mapped = "kern.osversion";
            else if (name[1] == KERN_VERSION) mapped = "kern.version";
            else if (name[1] == KERN_HOSTNAME) mapped = "kern.hostname";
        }
        if (mapped) return replaced_sysctlbyname(mapped, oldp, oldlenp, newp, newlen);
    }
    return orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
}

static int replaced_uname(struct utsname *buf) {
    int ret = orig_uname(buf);
    if (ret != 0) return ret;

    RBXDeviceProfile *p = rbxProfile();
    if (p) {
        NSString *pt = p.productType;
        if (pt) {
            strncpy(buf->machine, pt.UTF8String, sizeof(buf->machine) - 1);
            buf->machine[sizeof(buf->machine) - 1] = '\0';
        }
        NSString *rel = [p valueForPath:@"device.darwinRelease"];
        if (rel) {
            strncpy(buf->release, rel.UTF8String, sizeof(buf->release) - 1);
            buf->release[sizeof(buf->release) - 1] = '\0';
        }
        strncpy(buf->nodename, p.deviceName.UTF8String ?: "iPhone",
                sizeof(buf->nodename) - 1);
        buf->nodename[sizeof(buf->nodename) - 1] = '\0';
        NSString *kernelVersion = [NSString stringWithFormat:@"Darwin Kernel Version %@",
                                   rel ?: @"23.5.0"];
        strncpy(buf->version, kernelVersion.UTF8String, sizeof(buf->version) - 1);
        buf->version[sizeof(buf->version) - 1] = '\0';
    }
    return ret;
}

BOOL RBXInstallSysctlHooks(RBXDeviceProfile *profile) {
    if (!profile) return NO;
    MSHookFunction((void *)sysctlbyname, (void *)replaced_sysctlbyname, (void **)&orig_sysctlbyname);
    MSHookFunction((void *)sysctl, (void *)replaced_sysctl, (void **)&orig_sysctl);
    MSHookFunction((void *)uname, (void *)replaced_uname, (void **)&orig_uname);
    RBXLog("sysctl/uname hooks installed for container %@", profile.containerId);
    return RBXHookInstallationPassed();
}

BOOL RBXVerifySysctlHooks(void) {
    RBXDeviceProfile *p = rbxProfile();
    if (!p || !RBXHookInstallationPassed()) return NO;
    NSDictionary *strings = @{@"hw.machine": p.productType ?: @"",
        @"hw.model": [p valueForPath:@"device.hwModelStr"] ?: @"",
        @"kern.osrelease": [p valueForPath:@"device.darwinRelease"] ?: @"",
        @"kern.osversion": [p valueForPath:@"device.buildVersion"] ?: @""};
    for (NSString *key in strings) {
        NSString *expected = strings[key]; size_t required = 0;
        if (!expected.length || sysctlbyname(key.UTF8String, NULL, &required, NULL, 0) ||
            required != strlen(expected.UTF8String) + 1 || required > 512) return NO;
        char value[512] = {}; size_t size = sizeof(value);
        if (sysctlbyname(key.UTF8String, value, &size, NULL, 0) || size != required ||
            memcmp(value, expected.UTF8String, required)) return NO;
        char sentinel = 'X'; size = 1; errno = 0;
        if (sysctlbyname(key.UTF8String, &sentinel, &size, NULL, 0) != -1 ||
            errno != ENOMEM || size != required || sentinel != 'X') return NO;
    }
    int mib[] = {CTL_HW, HW_MACHINE}; char machine[512] = {}; size_t size = sizeof(machine);
    if (sysctl(mib, 2, machine, &size, NULL, 0) ||
        size != strlen(p.productType.UTF8String) + 1 || strcmp(machine, p.productType.UTF8String)) return NO;
    uint64_t memory = 0; size = sizeof(memory);
    if (sysctlbyname("hw.memsize", &memory, &size, NULL, 0) || size != sizeof(memory) ||
        memory != strtoull([p valueForPath:@"device.ramBytes"].UTF8String, NULL, 10)) return NO;
    struct utsname system = {};
    return uname(&system) == 0 && !strcmp(system.machine, p.productType.UTF8String) &&
        !strcmp(system.release, [p valueForPath:@"device.darwinRelease"].UTF8String);
}
