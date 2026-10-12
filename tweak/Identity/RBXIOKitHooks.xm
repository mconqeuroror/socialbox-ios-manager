#import "RBXHookInstallation.h"
#import "RBXIOKitHooks.h"
#import "RBXProfile.h"
#import "RBXContainerManager.h"
#import "RBXLog.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <substrate.h>

// IOKit user client reads (IOPlatformExpertDevice). Apps and some SDKs query
// IOPlatformSerialNumber / IOPlatformUUID directly via IOKit, bypassing MobileGestalt.

static RBXDeviceProfile *rbxProfile(void) {
    return [RBXContainerManager sharedManager].currentProfile;
}

// Only the current startup-probe thread substitutes a synthetic input value.
// Calls still enter the exported IOKit APIs and the installed sanitizer.
static thread_local BOOL sIOKitProbe;
static CFTypeRef (*orig_IORegistryEntryCreateCFProperty)(io_registry_entry_t, CFStringRef, CFAllocatorRef, IOOptionBits);
static CFTypeRef (*orig_IORegistryEntrySearchCFProperty)(io_registry_entry_t, const io_name_t,
                                                         CFStringRef, CFAllocatorRef,
                                                         IOOptionBits);
static kern_return_t (*orig_IORegistryEntryCreateCFProperties)(
    io_registry_entry_t, CFMutableDictionaryRef *, CFAllocatorRef, IOOptionBits);

static BOOL RBXIOKitKeyIsSensitive(NSString *key) {
    NSString *lower = key.lowercaseString;
    for (NSString *fragment in @[@"serial", @"uuid", @"unique", @"imei", @"meid",
                                  @"mac-address", @"bluetooth", @"wifi", @"chip-id",
                                  @"baseband", @"locationid", @"registry-id", @"die-id",
                                  @"ecid", @"currentcapacity", @"designcapacity",
                                  @"cyclecount", @"voltage", @"amperage",
                                  @"temperature"]) {
        if ([lower containsString:fragment]) return YES;
    }
    return NO;
}

static id RBXSanitizeIOKitTree(id value, NSString *key, NSUInteger depth) {
    if (!value || depth > 16) return nil;
    RBXDeviceProfile *profile = rbxProfile();
    if (!profile) return nil;
    if ([key isEqual:@"IOPlatformSerialNumber"]) return profile.serialNumber;
    if ([key isEqual:@"IOPlatformUUID"]) return [profile valueForPath:@"serials.platformUUID"];
    if (key && RBXIOKitKeyIsSensitive(key)) return nil;
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *safe = [NSMutableDictionary dictionary];
        for (id childKey in value) {
            if (![childKey isKindOfClass:NSString.class]) continue;
            id child = RBXSanitizeIOKitTree(value[childKey], childKey, depth + 1);
            if (child) safe[childKey] = child;
        }
        return safe;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *safe = [NSMutableArray array];
        for (id child in value) {
            id filtered = RBXSanitizeIOKitTree(child, nil, depth + 1);
            if (filtered) [safe addObject:filtered];
        }
        return safe;
    }
    return value;
}

static CFTypeRef RBXSanitizeIOKitValue(CFTypeRef value, CFStringRef key) {
    if (!value) return NULL;
    id safe = RBXSanitizeIOKitTree((__bridge id)value, (__bridge NSString *)key, 0);
    CFTypeRef result = safe ? (__bridge_retained CFTypeRef)safe : NULL;
    CFRelease(value);
    return result;
}

static CFTypeRef replaced_IORegistryEntryCreateCFProperty(io_registry_entry_t entry,
                                                         CFStringRef key,
                                                         CFAllocatorRef allocator,
                                                         IOOptionBits options) {
    CFTypeRef value = sIOKitProbe ? CFRetain(CFSTR("RBX-probe-original")) :
        orig_IORegistryEntryCreateCFProperty(entry, key, allocator, options);
    return RBXSanitizeIOKitValue(value, key);
}

static CFTypeRef replaced_IORegistryEntrySearchCFProperty(io_registry_entry_t entry,
                                                          const io_name_t plane,
                                                          CFStringRef key,
                                                          CFAllocatorRef allocator,
                                                          IOOptionBits options) {
    CFTypeRef value = sIOKitProbe ? CFRetain(CFSTR("RBX-probe-original")) :
        orig_IORegistryEntrySearchCFProperty(entry, plane, key,
                                                           allocator, options);
    return RBXSanitizeIOKitValue(value, key);
}

static kern_return_t replaced_IORegistryEntryCreateCFProperties(
    io_registry_entry_t entry, CFMutableDictionaryRef *properties,
    CFAllocatorRef allocator, IOOptionBits options) {
    kern_return_t status;
    if (sIOKitProbe && properties) {
        *properties = (__bridge_retained CFMutableDictionaryRef)[@{
            @"IOPlatformSerialNumber": @"RBX-probe-original",
            @"IOPlatformUUID": @"RBX-probe-original", @"unique-unmapped": @"must-remove",
            @"probe-control": @"keep", @"children": @[@{@"IOPlatformSerialNumber": @"nested-physical",
                @"registry": @{@"die-id": @42, @"probe-control": @"nested-keep"}}] } mutableCopy];
        status = KERN_SUCCESS;
    } else status = orig_IORegistryEntryCreateCFProperties(entry, properties, allocator, options);
    if (status != KERN_SUCCESS || !properties || !*properties || !rbxProfile()) return status;
    NSDictionary *safe = RBXSanitizeIOKitTree((__bridge id)*properties, nil, 0);
    CFMutableDictionaryRef replacement = (__bridge_retained CFMutableDictionaryRef)[safe mutableCopy];
    CFRelease(*properties);
    *properties = replacement;
    return status;
}

BOOL RBXInstallIOKitHooks(RBXDeviceProfile *profile) {
    if (!profile) return NO;
    MSHookFunction((void *)IORegistryEntryCreateCFProperty,
                   (void *)replaced_IORegistryEntryCreateCFProperty,
                   (void **)&orig_IORegistryEntryCreateCFProperty);
    MSHookFunction((void *)IORegistryEntrySearchCFProperty,
                   (void *)replaced_IORegistryEntrySearchCFProperty,
                   (void **)&orig_IORegistryEntrySearchCFProperty);
    MSHookFunction((void *)IORegistryEntryCreateCFProperties,
                   (void *)replaced_IORegistryEntryCreateCFProperties,
                   (void **)&orig_IORegistryEntryCreateCFProperties);
    RBXLog("IOKit hooks installed for container %@", profile.containerId);
    return RBXHookInstallationPassed();
}

BOOL RBXVerifyIOKitHooks(void) {
    if (!RBXHookInstallationPassed() || !rbxProfile().serialNumber.length ||
        ![rbxProfile() valueForPath:@"serials.platformUUID"].length) return NO;
    BOOL ok = YES;
    sIOKitProbe = YES;
    @try {
        for (NSString *key in @[@"IOPlatformSerialNumber", @"IOPlatformUUID", @"unique-unmapped"]) {
            id expected = [key isEqual:@"IOPlatformSerialNumber"] ? rbxProfile().serialNumber :
                ([key isEqual:@"IOPlatformUUID"] ? [rbxProfile() valueForPath:@"serials.platformUUID"] : nil);
            CFTypeRef scalar = IORegistryEntryCreateCFProperty(MACH_PORT_NULL,
                (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
            CFTypeRef search = IORegistryEntrySearchCFProperty(MACH_PORT_NULL, kIOServicePlane,
                (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
            ok = ok && (expected ? [(__bridge id)scalar isEqual:expected] &&
                [(__bridge id)search isEqual:expected] : !scalar && !search);
            if (scalar) CFRelease(scalar); if (search) CFRelease(search);
        }
        CFMutableDictionaryRef bulk = NULL;
        kern_return_t status = IORegistryEntryCreateCFProperties(MACH_PORT_NULL, &bulk, kCFAllocatorDefault, 0);
        NSDictionary *values = (__bridge NSDictionary *)bulk;
        ok = ok && status == KERN_SUCCESS &&
            [values[@"IOPlatformSerialNumber"] isEqual:rbxProfile().serialNumber] &&
            [values[@"IOPlatformUUID"] isEqual:[rbxProfile() valueForPath:@"serials.platformUUID"]] &&
            !values[@"unique-unmapped"] && [values[@"probe-control"] isEqual:@"keep"];
        NSDictionary *child = [values[@"children"] firstObject];
        ok = ok && [child[@"IOPlatformSerialNumber"] isEqual:rbxProfile().serialNumber] &&
            !child[@"registry"][@"die-id"] && [child[@"registry"][@"probe-control"] isEqual:@"nested-keep"];
        if (bulk) CFRelease(bulk);
    } @finally { sIOKitProbe = NO; }
    return ok;
}
