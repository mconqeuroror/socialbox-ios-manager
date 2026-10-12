// Live acceptance of the actual source daemon verifier and HTTPS transport.
// A disposable fixture supplies its own identity/key and pairing persistence;
// this program never reads or writes the installed app's data or Keychain.
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import "RBXSecureConfig.h"
#import "RBXCloudSync.h"
#import "RBXOperationContext.h"
static NSString *ProbeCloudPath, *ProbeStatePath, *ProbeKey, *ProbeIdentity;
#define RBX_LICENSE_CLOUD_PLIST ProbeCloudPath
#define RBX_LICENSE_STATE_PLIST ProbeStatePath
#define RBX_LICENSE_TESTING 1
#import "../daemon/RBXLicenseGuard.m"

@implementation RBXSecureConfig
+ (NSString *)accessKey:(NSError **)error { return ProbeKey; }
@end
@implementation RBXCloudSync
+ (instancetype)sharedSync { static id value; return value ?: (value = [self new]); }
- (BOOL)acceptLicensePairing:(NSDictionary *)pairing context:(RBXOperationContext *)context error:(NSError **)error {
    if (![context check:error]) return NO;
    NSMutableDictionary *cloud = [[NSDictionary dictionaryWithContentsOfFile:ProbeCloudPath] mutableCopy];
    if (!cloud || ![pairing[@"deviceId"] isKindOfClass:NSString.class] || ![pairing[@"token"] isKindOfClass:NSString.class]) return NO;
    if (cloud[@"deviceId"] && ![cloud[@"deviceId"] isEqual:pairing[@"deviceId"]]) return NO;
    cloud[@"deviceId"] = pairing[@"deviceId"]; cloud[@"deviceToken"] = pairing[@"token"];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:cloud format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    return data && [data writeToFile:ProbeCloudPath options:NSDataWritingAtomic error:error] &&
        chmod(ProbeCloudPath.fileSystemRepresentation, 0600) == 0 &&
        [[NSDictionary dictionaryWithContentsOfFile:ProbeCloudPath] isEqual:cloud];
}
@end
@interface ProbeGuard : RBXLicenseGuard @end
@implementation ProbeGuard
#ifdef RBX_PROBE_DEVICE_KEYCHAIN
- (NSDictionary *)_identityQuery {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.socialbox.acceptance.license-device",
        (__bridge id)kSecAttrAccount: ProbeIdentity,
        (__bridge id)kSecAttrAccessGroup: @"SBXACCEPT.com.socialbox.license-acceptance"};
}
#else
- (NSString *)_readDeviceIdentity:(NSError **)error { return ProbeIdentity; }
#endif
@end

int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 4) { fprintf(stderr, "Usage: probe PRIVATE_DIRECTORY activate|validate|status active|locked\n"); return 2; }
    umask(0077);
    NSString *directory = @(argv[1]), *mode = @(argv[2]), *expected = @(argv[3]);
    struct stat info;
    if (lstat(directory.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode) ||
        info.st_uid != geteuid() || (info.st_mode & 0077) ||
        ![@[@"activate", @"validate", @"status"] containsObject:mode] || ![@[@"active", @"locked"] containsObject:expected]) return 2;
    NSString *input = [directory stringByAppendingPathComponent:@"input.json"];
    if (lstat(input.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) || info.st_nlink != 1 ||
        info.st_uid != geteuid() || (info.st_mode & 0077) || info.st_size > 16384) return 2;
    NSDictionary *fixture = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:input] options:0 error:nil];
    if (![fixture isKindOfClass:NSDictionary.class] || ![fixture[@"key"] isKindOfClass:NSString.class] ||
        ![fixture[@"identity"] isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:fixture[@"identity"]]) return 2;
    ProbeKey = fixture[@"key"]; ProbeIdentity = [fixture[@"identity"] lowercaseString];
    ProbeCloudPath = [directory stringByAppendingPathComponent:@"cloud.plist"];
    ProbeStatePath = [directory stringByAppendingPathComponent:@"license-state.plist"];
    // Test fixtures deliberately use the real product's existing origin/pin.
    if (![NSFileManager.defaultManager fileExistsAtPath:ProbeCloudPath])
        if (![@{@"serverURL": RBXCloudProductionOrigin} writeToFile:ProbeCloudPath atomically:YES]) return 2;
    [RBXOperationContext setSafetyFenceDirectoryForTesting:[directory stringByAppendingPathComponent:@"fences"]];
    ProbeGuard *guard = [ProbeGuard new];
    if (![mode isEqual:@"status"]) {
        RBXOperationContext *context = [RBXOperationContext contextWithRequestID:NSUUID.UUID.UUIDString
            bootEpoch:RBXOperationContext.daemonBootEpoch timeout:25];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        void (^completion)(BOOL, NSString *) = ^(BOOL unlocked, NSString *message) { dispatch_semaphore_signal(done); };
        if ([mode isEqual:@"activate"]) [guard activateWithContext:context completion:completion];
        else [guard validateWithContext:context completion:completion];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC))) return 3;
        if (![context waitForQuiescence:5]) return 3;
        [context finish];
    }
    NSDictionary *status = guard.safeStatus;
    BOOL active = guard.isUnlocked, traffic = guard.trafficEntitlementValid;
    BOOL passed = active == [expected isEqual:@"active"] && traffic == active;
    NSDictionary *output = @{@"pass": @(passed), @"unlocked": @(active), @"trafficEntitlementValid": @(traffic),
        @"status": status[@"status"], @"mode": mode, @"scope": @"actual daemon verifier; isolated acceptance identity/pairing"};
    NSData *json = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout);
    return passed ? 0 : 1;
} }
