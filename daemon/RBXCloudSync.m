#import "RBXInstallPaths.h"
#import "RBXCloudSync.h"
#import "RBXLicenseGuard.h"
#import "RBXProfileMetadata.h"
#import "RBXCentralStore.h"
#import "RBXContainerRegistry.h"
#import "RBXCloneManager.h"
#import "RBXAppVersionMonitor.h"
#import "RBXDeviceCatalog.h"
#import "RBXProfileGenerator.h"
#import "RBXMGOverrides.h"
#import "RBXProcessController.h"
#import "RBXAppProcessCoordinator.h"
#import "RBXSecureConfig.h"
#import "RBXRotationSecrets.h"
#import "RBXBackupSnapshot.h"
#import "RBXBackupArchive.h"
#import "RBXNetworkGate.h"
#import "RBXProfileTransport.h"
#import "RBXProfileIO.h"
#import "RBXAppRegistry.h"
#import "RBXAppProfileIdentity.h"
#import "RBXProfileIdentifier.h"
#import "RBXProxyManager.h"
#import "RBXOperationContext.h"
#import "RBXBoundedProcess.h"
#import "RBXLicenseToken.h"

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <spawn.h>
#import <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static char RBXCloudQueueKey;

// AES-256-GCM: CryptoKit's AES.GCM is Swift-only (no Objective-C bindings),
// so a pure-ObjC daemon cannot call it. CommonCrypto's public headers don't
// export GCM either, but the system libcommonCrypto.dylib exports the SPI
// oneshot GCM functions (available since iOS ~11; the same local-prototype
// technique is used in production by the AWS SDK's Apple crypto). The wire
// format is identical to the cloud contract: AES-256-GCM, 12-byte nonce,
// 16-byte tag, AAD-authenticated.
extern CCCryptorStatus CCCryptorGCMOneshotEncrypt(
    CCAlgorithm alg, const void *key, size_t keyLength,
    const void *iv, size_t ivLen,
    const void *aData, size_t aDataLen,
    const void *dataIn, size_t dataInLength,
    void *dataOut,
    void *tagOut, size_t tagLength) __attribute__((__warn_unused_result__));

extern CCCryptorStatus CCCryptorGCMOneshotDecrypt(
    CCAlgorithm alg, const void *key, size_t keyLength,
    const void *iv, size_t ivLen,
    const void *aData, size_t aDataLen,
    const void *dataIn, size_t dataInLength,
    void *dataOut,
    const void *tagIn, size_t tagLength) __attribute__((__warn_unused_result__));

#import "RBXCloudOrigin.h"

// SocialBox encrypted cloud backup and device pairing.
//
// Concurrency model: main retains each action's serialized request ownership
// through its completion. Cloud work and result persistence use one serial
// queue ("com.redditbox.cloud"); its plist is configuration, never an inbox.
// HTTP uses bounded NSURLSession requests. Encrypted backups travel in 1 MiB
// parts; the server sees ciphertext and never receives the encryption key.
//
// Networking choice (deliberate, documented): cloud sync talks to the OPERATOR's
// deployment directly, NOT through the per-container proxy. The blob never
// touches Reddit; routing operator infrastructure through account proxies would
// tie the operator's infra IP to account exit IPs for zero benefit.

static NSString *const kCloudPlist = @"/var/mobile/Library/Preferences/com.redditbox.cloud.plist";
static NSString *const kBindingFile = @"/var/mobile/Library/Preferences/com.redditbox.activeContainer";
static NSString *const kProfilesDir = @"/var/mobile/Library/Preferences/com.redditbox.profiles";

static NSString *const kAAD = @"{\"v\":1,\"kdf\":\"PBKDF2-SHA256\",\"iter\":600000,\"cipher\":\"AES-256-GCM\"}";
static const NSUInteger kSaltLen = 16;
static const NSUInteger kNonceLen = 12;
static const NSUInteger kTagLen = 16;
static const uint32_t kPBKDF2Iterations = 600000;
enum { kAESKeyLen = 32 };

static NSString *const kTarFallback = @"/usr/bin/tar";

static const NSTimeInterval kCloudHTTPTimeout = 30.0;

static NSError *RBXCloudInputError(NSString *message) {
    return [NSError errorWithDomain:@"com.redditbox.cloud" code:14
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL RBXCloudCheck(RBXOperationContext *context, NSError **error) {
    if (context.inspectionOnly) {
        if (error) *error = RBXCloudInputError(@"An inspection operation cannot modify cloud or profile state");
        return NO;
    }
    if (context) return [context check:error];
    if (error) *error = RBXCloudInputError(@"Cloud work has no operation owner");
    return NO;
}

static BOOL RBXCloudMessageCheck(RBXOperationContext *context, NSString **message) {
    NSError *error = nil;
    BOOL ok = RBXCloudCheck(context, &error);
    if (!ok && message) *message = error.localizedDescription;
    return ok;
}

static BOOL RBXCloudQuiesce(RBXOperationContext *context, NSError **error) {
    if (!RBXCloudCheck(context, error)) return NO;
    NSString *generation = [RBXNetworkGate closeTrafficWithReason:@"cloud backup/restore snapshot" error:error];
    BOOL stopped = [[RBXAppProcessCoordinator new] killAllAndWait:8.0];
    if (!generation || !stopped || ![RBXNetworkGate waitForMaintenanceClosure:generation timeout:1.0]) {
        if (error && !*error) *error = RBXCloudInputError(@"Backup/restore requires verified CLOSED and no clone processes");
        return NO;
    }
    return RBXCloudCheck(context, error);
}

static BOOL RBXCloudPrepareStage(NSString *path, NSString *containerId, NSString *action,
    RBXOperationContext *context, NSError **error) {
    if (!RBXCloudCheck(context, error)) return NO;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:path
        withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions: @0700} error:error]) return NO;
    NSDictionary *record = @{@"requestId": context.requestID, @"operationToken": context.token,
        @"bootEpoch": context.bootEpoch, @"containerId": containerId, @"action": action,
        @"phase": @"prepared", @"createdAt": @(NSDate.date.timeIntervalSince1970)};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:record
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    NSString *recordPath = [path stringByAppendingPathComponent:@"operation-recovery.plist"];
    if (!RBXCloudCheck(context, error) || !data ||
        ![data writeToFile:recordPath options:NSDataWritingAtomic error:error]) return NO;
    // The target receipt must be durable before staging copy/extraction starts.
    for (NSString *item in @[recordPath, path, path.stringByDeletingLastPathComponent]) {
        int flags = [item isEqualToString:recordPath] ? O_RDWR : O_RDONLY | O_DIRECTORY;
        int descriptor = open(item.fileSystemRepresentation, flags | O_NOFOLLOW);
        BOOL durable = descriptor >= 0 && fsync(descriptor) == 0;
        int saved = errno;
        if (descriptor >= 0) close(descriptor);
        if (!durable) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:saved userInfo:
                @{NSLocalizedDescriptionKey: @"Cloud recovery staging could not be made durable"}];
            return NO;
        }
    }
    return RBXCloudCheck(context, error);
}

static RBXOperationContext *RBXCloudLegacyContext(BOOL *owned) {
    RBXOperationContext *context = [RBXOperationContext currentContext];
    *owned = context == nil;
    return context ?: [RBXOperationContext contextWithRequestID:
        [@"cloud-background-" stringByAppendingString:NSUUID.UUID.UUIDString]
        bootEpoch:[RBXOperationContext daemonBootEpoch] timeout:180];
}

static void (^RBXCloudCompletion(RBXOperationContext *context,
    void (^done)(BOOL, NSString *)))(BOOL, NSString *) {
    return ^(BOOL ok, NSString *message) {
        NSError *error = nil;
        if (!RBXCloudCheck(context, &error)) {
            ok = NO;
            message = message.length ? [NSString stringWithFormat:@"%@; %@", error.localizedDescription, message]
                : error.localizedDescription;
        }
        if (done) done(ok, message);
    };
}

static void RBXCloudDispatch(RBXOperationContext *context, dispatch_queue_t queue,
    void (^done)(BOOL, NSString *), dispatch_block_t block) {
    BOOL scheduled = [context dispatchAsyncOnQueue:queue block:^{
        NSError *error = nil;
        if (!RBXCloudCheck(context, &error)) {
            if (done) done(NO, error.localizedDescription);
            return;
        }
        block();
    }];
    if (!scheduled) {
        NSError *error = nil;
        RBXCloudCheck(context, &error);
        if (done) done(NO, error.localizedDescription ?: @"Cloud operation could not be scheduled");
    }
}

static BOOL RBXCloudProfileAvailable(id containerId, NSError **error) {
    if (![RBXProfileIO isSafeContainerIdentifier:containerId]) {
        if (error) *error = [NSError errorWithDomain:RBXProfileIOErrorDomain
            code:RBXProfileIOInvalidIdentifier userInfo:@{NSLocalizedDescriptionKey:
                @"Profile identifier is missing or unsafe"}];
        return NO;
    }
    NSDictionary *deletion = [[RBXContainerRegistry new] deletionStateForContainer:containerId];
    if (deletion) {
        if (error) *error = RBXCloudInputError(
            [deletion[@"message"] isKindOfClass:NSString.class] ? deletion[@"message"] :
                @"Profile is reserved for deletion or recovery");
        return NO;
    }
    return YES;
}

static NSMutableDictionary *RBXCloudLoadProfile(NSString *containerId, NSError **error) {
    if (!RBXCloudProfileAvailable(containerId, error)) return nil;
    return [[RBXProfileIO loadProfileForContainer:containerId error:error] mutableCopy];
}

static BOOL RBXCloudWriteProfile(NSDictionary *profile, NSString *containerId,
                                  BOOL requireExisting, NSError **error) {
    if (!RBXCloudCheck([RBXOperationContext currentContext], error)) return NO;
    if (![profile isKindOfClass:NSDictionary.class] || ![NSJSONSerialization isValidJSONObject:profile]) {
        if (error) *error = RBXCloudInputError(@"Profile root must be a JSON object");
        return NO;
    }
    if (!RBXCloudProfileAvailable(containerId, error)) return NO;
    if (requireExisting && !RBXCloudLoadProfile(containerId, error)) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:RBXProfileForTransport(profile)
        options:NSJSONWritingPrettyPrinted error:error];
    if (!data || ![RBXProfileIO profileDictionaryFromData:data containerId:containerId error:error])
        return NO;
    if (!RBXCloudProfileAvailable(containerId, error)) return NO;
    NSString *path = [[kProfilesDir stringByAppendingPathComponent:containerId]
        stringByAppendingPathExtension:@"json"];
    return RBXCloudCheck([RBXOperationContext currentContext], error) &&
        [RBXProfileIO writeProfile:RBXProfileForTransport(profile) containerId:containerId toPath:path error:error];
}

static NSDictionary *RBXCloudResponseDictionary(NSData *data, NSError **error) {
    if (!data.length) {
        if (error && !*error) *error = RBXCloudInputError(@"Cloud returned an empty response");
        return nil;
    }
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (!value) return nil;
    if (![value isKindOfClass:NSDictionary.class]) {
        if (error) *error = RBXCloudInputError(@"Cloud response must be a JSON object");
        return nil;
    }
    return value;
}

static BOOL RBXCloudOptionalStrings(NSDictionary *value, NSArray<NSString *> *keys,
                                     NSError **error) {
    for (NSString *key in keys) {
        if (value[key] && ![value[key] isKindOfClass:NSString.class]) {
            if (error) *error = RBXCloudInputError([NSString stringWithFormat:
                @"Cloud field '%@' must be a string", key]);
            return NO;
        }
    }
    return YES;
}

static NSArray *RBXCloudAssignmentArray(NSDictionary *response, NSError **error) {
    if (!response) return nil;
    NSArray *assignments = response[@"assignments"];
    if (![assignments isKindOfClass:NSArray.class]) {
        if (error) *error = RBXCloudInputError(@"Cloud assignments must be an array");
        return nil;
    }
    for (id entry in assignments) {
        if (![entry isKindOfClass:NSDictionary.class] ||
            ![RBXProfileIO isSafeContainerIdentifier:entry[@"profileId"]]) {
            if (error) *error = RBXCloudInputError(@"Cloud assignment has an invalid profile identifier or object type");
            return nil;
        }
        for (NSString *section in @[@"proxy", @"rotationAuth"]) {
            id value = entry[section];
            if (!value || value == NSNull.null) continue;
            if (![value isKindOfClass:NSDictionary.class]) {
                if (error) *error = RBXCloudInputError([NSString stringWithFormat:
                    @"Cloud assignment section '%@' must be an object", section]);
                return nil;
            }
            NSArray *keys = [section isEqualToString:@"proxy"]
                ? @[@"url", @"id", @"country", @"healthStatus"] : @[@"header", @"value"];
            if (!RBXCloudOptionalStrings(value, keys, error)) return nil;
        }
    }
    return assignments;
}

// FBLIFE-006: authenticated app ownership must agree before restoring bytes.
// Missing app tags retain the legacy Reddit envelope. Other apps require the
// complete versioned same-logical-identity contract and an active descriptor.
static NSDictionary *RBXCloudBackupDescriptor(NSDictionary *manifest) {
    if (![manifest isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *descriptor = RBXAppDescriptorForType(manifest[@"appType"]);
    if (!descriptor || ![descriptor[@"runnable"] boolValue]) return nil;
    BOOL legacy = [descriptor[@"appType"] isEqual:@"reddit"];
    for (NSString *field in @[@"profile", @"profileSeed"]) {
        id scope = manifest[field];
        if (scope && ![scope isKindOfClass:NSDictionary.class]) return nil;
        if ((!legacy || scope[@"appType"]) &&
            ![scope[@"appType"] isEqual:descriptor[@"appType"]]) return nil;
    }
    if (manifest[@"sourceBundleIdentifier"] &&
        ![manifest[@"sourceBundleIdentifier"] isEqual:descriptor[@"sourceBundleIdentifier"]]) return nil;
    if (legacy) return descriptor;
    if ([manifest[@"profileSeed"] count] != 1) return nil;
    id version = manifest[@"schemaVersion"];
    NSDictionary *transfer = manifest[@"credentialTransfer"];
    if (![version isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID() || ![version isEqual:@2] ||
        ![manifest[@"sourceBundleIdentifier"] isEqual:descriptor[@"sourceBundleIdentifier"]] ||
        ![manifest[@"restorePolicy"] isEqual:@"same-logical-identity-new-local-container-v1"] ||
        ![transfer isKindOfClass:NSDictionary.class] ||
        ![transfer[@"appData"] isEqual:@"included"] ||
        ![transfer[@"keychain"] isEqual:@"not-exported"] ||
        ![transfer[@"deviceBoundKeys"] isEqual:@"not-transferable"]) return nil;
    for (NSString *flag in @[@"loginPreserved", @"requiresLoginVerification"]) {
        id value = transfer[flag];
        if (![value isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() ||
            ![value isEqual:[flag isEqual:@"loginPreserved"] ? @NO : @YES]) return nil;
    }
    return descriptor;
}

static BOOL RBXCloudValidateManifest(NSDictionary *manifest, NSString *selectedContainerId,
                                     NSError **error) {
    if (![manifest isKindOfClass:NSDictionary.class]) {
        if (error) *error = RBXCloudInputError(@"Backup manifest must be an object");
        return NO;
    }
    NSString *containerId = manifest[@"containerId"];
    if (![RBXProfileIO isSafeContainerIdentifier:containerId]) {
        if (error) *error = RBXCloudInputError(@"Backup container identifier is missing or unsafe");
        return NO;
    }
    // LIFE-014: an authentic envelope still has to belong to the selected
    // backup. Reject substitution before proxy checks, extraction or writes.
    if (![RBXProfileIO isSafeContainerIdentifier:selectedContainerId] ||
        ![containerId isEqualToString:selectedContainerId]) {
        if (error) *error = RBXCloudInputError(@"Backup manifest does not match the selected container identity");
        return NO;
    }
    for (NSString *key in @[@"profile", @"profileSeed", @"proxyHint", @"proxy"]) {
        if (manifest[key] && ![manifest[key] isKindOfClass:NSDictionary.class]) {
            if (error) *error = RBXCloudInputError([NSString stringWithFormat:
                @"Backup field '%@' must be an object", key]);
            return NO;
        }
    }
    if (!RBXCloudBackupDescriptor(manifest)) {
        if (error) *error = RBXCloudInputError(@"Backup app ownership or restore policy is invalid, incomplete, or not yet enabled");
        return NO;
    }
    if (!RBXCloudOptionalStrings(manifest, @[@"archiveB64", @"nickname", @"username"], error)) return NO;
    if (manifest[@"profile"]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:manifest[@"profile"] options:0 error:error];
        if (!data || ![RBXProfileIO profileDictionaryFromData:data containerId:containerId error:error]) return NO;
    }
    NSDictionary *seed = manifest[@"profileSeed"];
    if (!RBXCloudOptionalStrings(seed, @[@"productType", @"iosVersion", @"locale", @"timezone",
        @"deviceName", @"idfa", @"idfv", @"installId", @"installTimestampMs", @"redditDeviceName",
        @"batteryOffset", @"bootTimeOffset", @"syntheticBootEpoch"], error)) return NO;
    for (NSString *key in @[@"location", @"carrier", @"security", @"identityCustomization"]) {
        if (seed[key] && ![seed[key] isKindOfClass:NSDictionary.class]) {
            if (error) *error = RBXCloudInputError([NSString stringWithFormat:
                @"Backup seed field '%@' must be an object", key]);
            return NO;
        }
    }
    // Reuse the profile schema for the nested sections copied from legacy seeds.
    NSDictionary *seedProfile = @{@"containerId": containerId,
        @"device": @{@"location": seed[@"location"] ?: @{}, @"carrier": seed[@"carrier"] ?: @{}},
        @"security": seed[@"security"] ?: @{}, @"identityCustomization": seed[@"identityCustomization"] ?: @{}};
    NSData *seedData = [NSJSONSerialization dataWithJSONObject:seedProfile options:0 error:error];
    if (!seedData || ![RBXProfileIO profileDictionaryFromData:seedData containerId:containerId error:error]) return NO;
    return RBXCloudOptionalStrings(manifest[@"proxyHint"], @[@"url", @"country"], error) &&
        RBXCloudOptionalStrings(manifest[@"proxy"], @[@"url", @"country"], error);
}

// ---------------------------------------------------------------------------
// Helpers: persistent cloud configuration. Action input comes only from an
// owned request record passed by the daemon's request controller.

static NSMutableDictionary *RBXCloudReadPlist(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kCloudPlist];
    return d ?: [NSMutableDictionary dictionary];
}

static BOOL RBXCloudWritePlist(NSMutableDictionary *d) {
    if (!RBXCloudCheck([RBXOperationContext currentContext], nil)) return NO;
    return [d writeToFile:kCloudPlist atomically:YES] &&
        chmod(kCloudPlist.fileSystemRepresentation, 0600) == 0 &&
        chown(kCloudPlist.fileSystemRepresentation, 0, 0) == 0 &&
        [[NSDictionary dictionaryWithContentsOfFile:kCloudPlist] isEqualToDictionary:d];
}

static NSString *RBXCloudString(NSDictionary *d, NSString *key) {
    id v = [d isKindOfClass:NSDictionary.class] ? d[key] : nil;
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static BOOL RBXCloudBool(NSDictionary *d, NSString *key, BOOL fallback) {
    id v = [d isKindOfClass:NSDictionary.class] ? d[key] : nil;
    if ([v isKindOfClass:[NSNumber class]]) return ((NSNumber *)v).boolValue;
    return fallback;
}

// Random bytes via SecRandomCopyBytes; nil on failure (caller aborts).
static NSData *RBXCloudRandom(NSUInteger length) {
    uint8_t *buf = malloc(length);
    if (!buf) return nil;
    if (SecRandomCopyBytes(kSecRandomDefault, length, buf) != errSecSuccess) {
        free(buf);
        return nil;
    }
    return [NSData dataWithBytes:buf length:length];
}

// 24 chars over a 71-symbol alphabet (upper/lower/digits/symbols; visually
// ambiguous glyphs excluded), entropy sourced from SecRandomCopyBytes.
static NSString *RBXCloudGeneratePassphrase(void) {
    static NSString *alphabet = @"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%&*";
    NSMutableData *raw = [RBXCloudRandom(24) mutableCopy];
    if (!raw) return nil;
    NSMutableString *s = [NSMutableString stringWithCapacity:raw.length];
    for (NSUInteger i = 0; i < raw.length; i++) {
        const uint8_t b = ((const uint8_t *)raw.bytes)[i];
        [s appendFormat:@"%C", (unsigned short)[alphabet characterAtIndex:(b % alphabet.length)]];
    }
    return s;
}

// 4-char lowercase hex suffix for new worker container ids.
static NSString *RBXCloudShortRandomHex(void) {
    NSData *d = RBXCloudRandom(2);
    if (!d) return @"0000";
    const uint8_t *b = (const uint8_t *)d.bytes;
    return [NSString stringWithFormat:@"%02x%02x", b[0], b[1]];
}

static BOOL RBXCloudIsDir(NSString *path) {
    BOOL isDir = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] && isDir;
}

static NSString *RBXCloudSHA256Hex(NSData *data) {
    if (!data) return @"";
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *s = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [s appendFormat:@"%02x", digest[i]];
    }
    return s;
}

static NSTimeInterval RBXCloudParseTime(id v) {
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v doubleValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSISO8601DateFormatter *fmt = [[NSISO8601DateFormatter alloc] init];
        fmt.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        NSDate *d = [fmt dateFromString:(NSString *)v];
        if (!d) {
            fmt.formatOptions = NSISO8601DateFormatWithInternetDateTime;
            d = [fmt dateFromString:(NSString *)v];
        }
        if (d) return [d timeIntervalSince1970];
        return [(NSString *)v doubleValue];
    }
    return 0;
}

// ---------------------------------------------------------------------------
// The owned process group shares the caller's absolute deadline.
static BOOL RBXCloudSpawnTar(NSArray<NSString *> *args, RBXOperationContext *context, NSError **error) {
    if (!RBXCloudCheck(context, error)) return NO;
    NSString *tarPath = nil;
    for (NSString *candidate in @[RBXInstalledPath(@"/usr/bin/tar"), kTarFallback]) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:candidate]) { tarPath = candidate; break; }
    }
    if (!tarPath) {
        if (error) *error = RBXCloudInputError(@"No tar executable is installed");
        return NO;
    }
    return [RBXBoundedProcess runExecutable:tarPath arguments:args context:context
        outputPath:nil maximumOutputBytes:0 error:error];
}

static BOOL RBXCloudTarContainer(NSString *containerId, NSString *parent, NSString *archivePath,
    RBXOperationContext *context, NSError **error) {
    return RBXCloudSpawnTar(@[@"--create", @"--gzip", @"--file", archivePath,
        @"--directory", parent, containerId], context, error);
}

static BOOL RBXCloudUntar(NSString *archivePath, NSString *tmpDir, NSString *legacyContainerId,
    RBXOperationContext *context, NSError **error) {
    return RBXExtractBackupArchive(archivePath, tmpDir, legacyContainerId,
        ^BOOL(NSError **failure) { return RBXCloudCheck(context, failure); }, error);
}

static BOOL RBXCloudRestoreDataContents(NSString *source, NSString *destination,
    RBXOperationContext *context, NSError **error) {
    if (!RBXCloudCheck(context, error)) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:source];
    for (NSString *relative in enumerator) {
        if (!RBXCloudCheck(context, error)) return NO;
        NSString *path = [source stringByAppendingPathComponent:relative];
        NSDictionary *attributes = [fm attributesOfItemAtPath:path error:error];
        if (!attributes) return NO;
        if ([attributes[NSFileType] isEqualToString:NSFileTypeSymbolicLink]) {
            if (error) *error = [NSError errorWithDomain:@"com.redditbox.cloud"
                code:41 userInfo:@{NSLocalizedDescriptionKey:
                    @"backup contains a symbolic link"}];
            return NO;
        }
    }
    NSArray *entries = [fm contentsOfDirectoryAtPath:source error:error];
    if (!entries) return NO;
    for (NSString *entry in entries) {
        if (!RBXCloudCheck(context, error)) return NO;
        if ([entry isEqualToString:
                @".com.apple.mobile_container_manager.metadata.plist"]) continue;
        NSString *from = [source stringByAppendingPathComponent:entry];
        NSString *to = [destination stringByAppendingPathComponent:entry];
        [fm removeItemAtPath:to error:nil];
        if (![fm copyItemAtPath:from toPath:to error:error]) return NO;
    }
    enumerator = [fm enumeratorAtPath:destination];
    for (NSString *relative in enumerator) {
        if (!RBXCloudCheck(context, error)) return NO;
        if ([relative isEqualToString:
                @".com.apple.mobile_container_manager.metadata.plist"]) continue;
        NSString *path = [destination stringByAppendingPathComponent:relative];
        lchown(path.fileSystemRepresentation, 501, 501);
    }
    // Archived controls belong to the old clone/epoch. Success requires actual
    // absence; a removal error must reach the caller's existing rollback path.
    for (NSString *relative in @[@"Library/Preferences/com.redditbox.network-lease.plist",
        @"Library/Preferences/com.redditbox.firewall-status.plist",
        @"Library/Preferences/com.redditbox.hook-ready.plist",
        @"Library/Application Support/RedditBox/profile.json"]) {
        if (!RBXCloudCheck(context, error)) return NO;
        NSString *path = [destination stringByAppendingPathComponent:relative];
        struct stat info;
        if (lstat(path.fileSystemRepresentation, &info) == 0) {
            NSError *removeError = nil;
            if (![fm removeItemAtPath:path error:&removeError]) {
                if (error) *error = removeError ?: RBXCloudInputError(@"Restored clone control could not be removed");
                return NO;
            }
        } else if (errno != ENOENT) {
            if (error) *error = RBXCloudInputError(@"Restored clone control could not be inspected");
            return NO;
        }
        // lstat also detects dangling links; fileExistsAtPath would mistake
        // those for absence. Only ENOENT proves that this path is absent.
        if (lstat(path.fileSystemRepresentation, &info) == 0 || errno != ENOENT) {
            if (error) *error = RBXCloudInputError(@"Restored clone control absence could not be verified");
            return NO;
        }
    }
    return RBXCloudCheck(context, error);
}

// ---------------------------------------------------------------------------
// crypto

static NSData *RBXCloudDeriveKey(NSString *passphrase, NSData *salt) {
    NSData *pw = [passphrase dataUsingEncoding:NSUTF8StringEncoding];
    if (!pw || salt.length != kSaltLen) return nil;

    uint8_t key[kAESKeyLen];
    int rc = CCKeyDerivationPBKDF(kCCPBKDF2,
                                 pw.bytes, pw.length,
                                 salt.bytes, salt.length,
                                 kCCPRFHmacAlgSHA256,
                                 kPBKDF2Iterations,
                                 key, sizeof(key));
    if (rc != kCCSuccess) {
        NSLog(@"redditboxd: cloud Ă˘â‚¬â€ť PBKDF2 failed (%d)", rc);
        return nil;
    }
    return [NSData dataWithBytes:key length:sizeof(key)];
}

// AES-256-GCM seal. Returns ciphertext || 16-byte tag, or nil.
static NSData *RBXCloudEncrypt(NSString *passphrase, NSData *plaintext, NSData *salt, NSData *nonce) {
    if (salt.length != kSaltLen || nonce.length != kNonceLen) return nil;
    NSData *aad = [kAAD dataUsingEncoding:NSUTF8StringEncoding];
    NSData *key = RBXCloudDeriveKey(passphrase, salt);
    if (!key) return nil;

    NSMutableData *ciphertext = [NSMutableData dataWithLength:plaintext.length];
    NSMutableData *tag = [NSMutableData dataWithLength:kTagLen];
    CCCryptorStatus rc = CCCryptorGCMOneshotEncrypt(
        kCCAlgorithmAES, key.bytes, key.length,
        nonce.bytes, nonce.length,
        aad.bytes, aad.length,
        plaintext.bytes, plaintext.length,
        ciphertext.mutableBytes,
        tag.mutableBytes, tag.length);
    if (rc != kCCSuccess) {
        NSLog(@"redditboxd: cloud Ă˘â‚¬â€ť GCM encrypt failed (%d)", rc);
        return nil;
    }
    NSMutableData *out = [NSMutableData dataWithCapacity:ciphertext.length + tag.length];
    [out appendData:ciphertext];
    [out appendData:tag];
    return out;
}

// Decrypt ciphertext||tag with explicit salt + nonce (shared API contract).
static NSData *RBXCloudDecryptParts(NSString *passphrase, NSData *sealed, NSData *salt, NSData *nonce) {
    if (sealed.length <= kTagLen || salt.length != kSaltLen || nonce.length != kNonceLen) return nil;
    NSUInteger ctLen = sealed.length - kTagLen;
    NSData *ciphertext = [sealed subdataWithRange:NSMakeRange(0, ctLen)];
    NSData *tag = [sealed subdataWithRange:NSMakeRange(ctLen, kTagLen)];
    NSData *aad = [kAAD dataUsingEncoding:NSUTF8StringEncoding];

    NSData *key = RBXCloudDeriveKey(passphrase, salt);
    if (!key) return nil;

    NSMutableData *plain = [NSMutableData dataWithLength:ctLen];
    CCCryptorStatus rc = CCCryptorGCMOneshotDecrypt(
        kCCAlgorithmAES, key.bytes, key.length,
        nonce.bytes, nonce.length,
        aad.bytes, aad.length,
        ciphertext.bytes, ciphertext.length,
        plain.mutableBytes,
        tag.bytes, tag.length);
    if (rc != kCCSuccess) {
        NSLog(@"redditboxd: cloud Ă˘â‚¬â€ť GCM open failed (wrong passphrase?) rc=%d", rc);
        return nil;
    }
    return plain;
}

// Legacy packed blob = salt(16) || nonce(12) || ciphertext || tag(16).
static NSData *RBXCloudDecrypt(NSString *passphrase, NSData *blob) {
    if (blob.length <= kSaltLen + kNonceLen + kTagLen) return nil;
    NSData *salt = [blob subdataWithRange:NSMakeRange(0, kSaltLen)];
    NSData *nonce = [blob subdataWithRange:NSMakeRange(kSaltLen, kNonceLen)];
    NSData *sealed = [blob subdataWithRange:NSMakeRange(kSaltLen + kNonceLen,
                                                        blob.length - kSaltLen - kNonceLen)];
    return RBXCloudDecryptParts(passphrase, sealed, salt, nonce);
}

// payload = 4-byte big-endian manifest length + manifest JSON + tar.gz bytes
static NSData *RBXCloudBuildPayload(NSDictionary *manifest, NSData *archive) {
    NSData *manifestJson = [NSJSONSerialization dataWithJSONObject:manifest
                                                         options:NSJSONWritingSortedKeys
                                                           error:nil];
    if (!manifestJson) return nil;

    NSMutableData *payload = [NSMutableData dataWithCapacity:4 + manifestJson.length + archive.length];
    uint32_t len = htonl((uint32_t)manifestJson.length);
    [payload appendBytes:&len length:4];
    [payload appendData:manifestJson];
    [payload appendData:archive];
    return payload;
}

// Inverse; sets manifest (out) and returns the archive bytes, or nil.
static NSData *RBXCloudParsePayload(NSData *payload, NSDictionary **manifestOut) {
    if (payload.length < 4) return nil;
    uint32_t len = 0;
    [payload getBytes:&len range:NSMakeRange(0, 4)];
    len = ntohl(len);
    if (len == 0 || payload.length < 4 + (NSUInteger)len) return nil;

    NSData *manifestJson = [payload subdataWithRange:NSMakeRange(4, len)];
    NSData *archive = [payload subdataWithRange:NSMakeRange(4 + len, payload.length - 4 - len)];

    id obj = [NSJSONSerialization JSONObjectWithData:manifestJson options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    if (manifestOut) *manifestOut = obj;
    return archive;
}

// ---------------------------------------------------------------------------
// HTTP (delegate-less NSURLSession; direct connection Ă˘â‚¬â€ť see header comment)

// One shared session for the daemon's lifetime (a session per request would
// leak delegate/queue machinery on every call).
static NSURLSession *RBXCloudHTTPSession(void) {
    static NSURLSession *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = kCloudHTTPTimeout;
        cfg.timeoutIntervalForResource = kCloudHTTPTimeout * 2;
        s = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s;
}

// POST a JSON body (pairing). Response surface matches all other cloud calls.
static void RBXCloudPostJSON(NSString *urlString, NSDictionary *body, NSString *bearer,
                             RBXOperationContext *context, void (^done)(NSData *data, NSURLResponse *resp, NSError *err)) {
    NSError *ownershipError = nil;
    if (!RBXCloudCheck(context, &ownershipError)) {
        if (done) done(nil, nil, ownershipError);
        return;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (done) done(nil, nil, [NSError errorWithDomain:@"com.redditbox.cloud" code:1
                                                userInfo:@{NSLocalizedDescriptionKey: @"invalid URL"}]);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = MAX(0.001, MIN(kCloudHTTPTimeout, context.remainingTime));
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (bearer.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", bearer] forHTTPHeaderField:@"Authorization"];
    }

    NSError *err = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:&err];
    if (!json) {
        if (done) done(nil, nil, err ?: [NSError errorWithDomain:@"com.redditbox.cloud" code:2
                                                       userInfo:@{NSLocalizedDescriptionKey: @"cannot encode JSON"}]);
        return;
    }
    req.HTTPBody = json;

    __block NSURLSessionDataTask *task = nil;
    task = [RBXCloudHTTPSession() dataTaskWithRequest:req completionHandler:
        ^(NSData *data, NSURLResponse *response, NSError *requestError) {
        @try {
            [context performBlock:^{
                NSError *error = nil;
                if (!RBXCloudCheck(context, &error)) { if (done) done(nil, nil, error); return; }
                if (done) done(data, response, requestError);
            }];
        } @finally { [context untrackTask:task]; task = nil; }
    }];
    [context trackTask:task];
    if (RBXCloudCheck(context, nil)) [task resume]; else [task cancel];
}

// ---------------------------------------------------------------------------

@interface RBXCloudSync ()
- (BOOL)_uploadSealed:(NSData *)sealed metadata:(NSDictionary *)metadata context:(RBXOperationContext *)context error:(NSError **)error;
- (NSData *)_downloadParts:(NSDictionary *)manifest path:(NSString *)path context:(RBXOperationContext *)context error:(NSError **)error;
- (BOOL)_importWithBackupId:(NSString *)backupId expectedAppType:(NSString *)appType context:(RBXOperationContext *)context message:(NSString **)message;
- (void)_regeneratePassphraseWithContext:(RBXOperationContext *)context completion:(void (^)(BOOL, NSString *))done;
@end

@implementation RBXCloudSync {
    dispatch_queue_t _queue;
    RBXCentralStore *_store;
}

+ (instancetype)sharedSync {
    static RBXCloudSync *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.redditbox.cloud", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, &RBXCloudQueueKey, (__bridge void *)self, NULL);
        _store = [RBXCentralStore sharedStore];
    }
    return self;
}

// Synchronous raw request on the caller's queue (actions run inside the serial
// queue, so sync is fine and keeps the flow linear). Non-2xx = error.
- (NSData *)_performDataRequest:(NSMutableURLRequest *)req context:(RBXOperationContext *)context error:(NSError **)error {
    if (!RBXCloudCheck(context, error)) return nil;
    if (!req || !req.URL) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.cloud" code:3
                                            userInfo:@{NSLocalizedDescriptionKey: @"invalid URL"}];
        return nil;
    }
    req.timeoutInterval = MAX(0.001, MIN(kCloudHTTPTimeout, context.remainingTime));
    NSObject *boxLock = [NSObject new];
    __block BOOL accepting = YES;
    __block NSData *out = nil;
    __block NSError *requestError = nil;
    __block NSInteger status = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSURLSessionDataTask *task = nil;
    task = [RBXCloudHTTPSession() dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *failure) {
        @try {
            @synchronized (boxLock) {
                if (accepting) {
                    out = data;
                    requestError = failure;
                    status = [response isKindOfClass:NSHTTPURLResponse.class]
                        ? ((NSHTTPURLResponse *)response).statusCode : 0;
                }
            }
            dispatch_semaphore_signal(sem);
        } @finally { [context untrackTask:task]; task = nil; }
    }];
    [context trackTask:task];
    NSString *cancelToken = [context registerCancellationHandler:^{ dispatch_semaphore_signal(sem); }];
    if (RBXCloudCheck(context, nil)) [task resume]; else [task cancel];
    long wait = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(MAX(0, context.remainingTime) * NSEC_PER_SEC)));
    [context unregisterCancellationHandler:cancelToken];
    NSData *result = nil;
    NSError *failure = nil;
    NSInteger responseStatus = 0;
    @synchronized (boxLock) {
        accepting = NO;
        result = out;
        failure = requestError;
        responseStatus = status;
    }
    if (wait != 0) [context cancelWithReason:@"Cloud operation deadline expired"];
    if (!RBXCloudCheck(context, error)) return nil;
    if (failure) { if (error) *error = failure; return nil; }
    if (responseStatus >= 200 && responseStatus < 300) return result;
    if (error) *error = RBXCloudInputError([NSString stringWithFormat:@"HTTP %ld", (long)responseStatus]);
    return nil;
}

- (void)start {
    // Passphrase is generated on first run (pairing happens later on operator
    // action, but the passphrase must exist before the first export and before
    // it is shown in prefs).
    RBXOperationContext *context = [RBXOperationContext currentContext];
    BOOL owned = context == nil;
    if (!context) context = [RBXOperationContext contextWithRequestID:@"cloud-startup"
        bootEpoch:[RBXOperationContext daemonBootEpoch] timeout:30];
    RBXCloudDispatch(context, _queue, nil, ^{
        NSMutableDictionary *d = RBXCloudReadPlist();
        if (![RBXCloudString(d, @"passphrase") length]) {
            NSString *pp = RBXCloudGeneratePassphrase();
            if (pp.length >= 16) {
                d[@"passphrase"] = pp;
                RBXCloudWritePlist(d);
                NSLog(@"redditboxd: cloud Ă˘â‚¬â€ť passphrase generated (%lu chars)", (unsigned long)pp.length);
            } else {
                NSLog(@"redditboxd: cloud Ă˘â‚¬â€ť SecRandomCopyBytes failed; will retry on next action");
            }
        }
    });
    if (owned) [context finishWhenQuiescent];
}

- (void)_enforceCurrentAssignment {
    BOOL owned = NO;
    RBXOperationContext *context = RBXCloudLegacyContext(&owned);
    RBXCloudDispatch(context, _queue, nil, ^{ [self _enforceCurrentAssignmentWithContext:context]; });
    if (owned) [context finishWhenQuiescent];
}

- (void)_enforceCurrentAssignmentWithContext:(RBXOperationContext *)context {
    if (!self.paired) return;
    NSString *containerId = [[NSString stringWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.redditbox.activeContainer"
        encoding:NSUTF8StringEncoding error:nil]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSError *profileError = nil;
    NSMutableDictionary *profile = RBXCloudLoadProfile(containerId, &profileError);
    if (!profile) {
        NSLog(@"redditboxd: assignment check failed: %@", profileError.localizedDescription);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[[self serverURL] stringByAppendingString:@"/api/profile-proxies"]]];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", self.deviceToken]
   forHTTPHeaderField:@"Authorization"];
    NSError *error = nil;
    NSData *data = [self _performDataRequest:request context:context error:&error];
    NSDictionary *decoded = RBXCloudResponseDictionary(data, &error);
    NSArray *assignments = RBXCloudAssignmentArray(decoded, &error);
    if (error || !assignments) {
        NSLog(@"redditboxd: assignment check failed: %@", error.localizedDescription);
        return; // transient cloud failure does not rotate or bypass
    }

    NSString *remoteURL = nil;
    for (id candidate in assignments) {
        if (![candidate isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *entry = candidate;
        if ([RBXCloudString(entry, @"profileId") isEqualToString:containerId] &&
            [entry[@"proxy"] isKindOfClass:[NSDictionary class]]) {
            remoteURL = [entry[@"proxy"][@"url"] isKindOfClass:[NSString class]]
                ? entry[@"proxy"][@"url"] : nil;
            break;
        }
    }
    NSString *localURL = [profile[@"proxy"][@"url"] isKindOfClass:[NSString class]]
        ? profile[@"proxy"][@"url"] : nil;
    if (![profile isKindOfClass:[NSMutableDictionary class]] ||
        (remoteURL.length && [remoteURL isEqualToString:localURL])) return;

    // Revocation is global lease work, even when the active profile belongs to
    // Facebook. Stop every registered app family before changing assignment
    // bytes. A failed write must never leave the old session authorized.
    NSString *generation = [RBXNetworkGate closeTrafficWithReason:@"cloud proxy assignment revoked" error:&profileError];
    RBXAppProcessCoordinator *processes = [RBXAppProcessCoordinator new];
    BOOL stopped = [processes killAllAndWait:8.0];
    if (!generation.length || !stopped ||
        ![RBXNetworkGate waitForMaintenanceClosure:generation timeout:8.0] ||
        ![processes verifyNoAppSocketsForInterval:1.0 error:&profileError]) {
        [context markUnsafeWithReason:@"Cloud assignment changed but global closure was not proven. Review recovery before opening." error:nil];
        NSLog(@"redditboxd: assignment revocation requires closure recovery");
        return;
    }
    NSMutableDictionary *proxy = [profile[@"proxy"] mutableCopy] ?: [NSMutableDictionary dictionary];
    proxy[@"url"] = @"";
    [proxy removeObjectForKey:@"proxyId"];
    profile[@"proxy"] = proxy;
    profile[@"mgOverrides"] = RBXBuildMGOverrides(profile);
    if (!RBXCloudWriteProfile(profile, containerId, YES, &profileError)) {
        [context markUnsafeWithReason:@"Cloud assignment revocation could not be persisted. Traffic remains closed; review recovery." error:nil];
        NSLog(@"redditboxd: assignment revocation could not be persisted: %@",
            profileError.localizedDescription);
        return;
    }
    NSLog(@"redditboxd: active profile stopped because cloud proxy assignment changed or reset");
}

- (BOOL)paired {
    return [RBXCloudString(RBXCloudReadPlist(), @"deviceToken") length] > 0;
}

- (NSString *)deviceToken {
    return RBXCloudString(RBXCloudReadPlist(), @"deviceToken");
}

- (NSString *)passphrase {
    return RBXCloudString(RBXCloudReadPlist(), @"passphrase");
}

- (void)regeneratePassphrase {
    BOOL owned = NO;
    RBXOperationContext *context = RBXCloudLegacyContext(&owned);
    [self _regeneratePassphraseWithContext:context completion:^(BOOL ok, NSString *message) {
        NSLog(@"redditboxd: cloud Ă˘â‚¬â€ť %@", message);
    }];
    if (owned) [context finishWhenQuiescent];
}

- (void)_regeneratePassphraseWithContext:(RBXOperationContext *)context completion:(void (^)(BOOL, NSString *))done {
    done = RBXCloudCompletion(context, done);
    RBXCloudDispatch(context, _queue, done, ^{
        NSMutableDictionary *d = RBXCloudReadPlist();
        NSString *pp = RBXCloudGeneratePassphrase();
        if (pp.length < 16) {
            if (done) done(NO, @"Passphrase generation failed; the previous passphrase was retained.");
            return;
        }
        d[@"passphrase"] = pp;
        // Pairing survives; old blobs still require the old passphrase.
        BOOL written = RBXCloudWritePlist(d);
        if (done) done(written, written ?
            @"Passphrase regenerated. Existing backups require the previous passphrase." :
            @"Could not persist and verify the new passphrase.");
    });
}

- (NSString *)serverURL {
    NSString *s = RBXCloudConfiguredOrigin(RBXCloudReadPlist()[@"serverURL"]);
    if (!s) return @"";
    while ([s hasSuffix:@"/"] && s.length > 1) s = [s substringToIndex:s.length - 1];
    NSURLComponents *components = [NSURLComponents componentsWithString:s];
    NSString *scheme = components.scheme.lowercaseString;
    NSString *host = components.host.lowercaseString;
    BOOL localDevelopment = [scheme isEqualToString:@"http"] &&
        ([host isEqualToString:@"localhost"] || [host isEqualToString:@"127.0.0.1"] ||
         [host isEqualToString:@"::1"]);
    if (![scheme isEqualToString:@"https"] && !localDevelopment) {
        NSLog(@"redditboxd: refusing non-TLS cloud server URL");
        return @"";
    }
    return s;
}

- (BOOL)setServerURL:(NSString *)serverURL error:(NSError **)error {
    if (!RBXCloudCheck([RBXOperationContext currentContext], error)) return NO;
    if (![serverURL isKindOfClass:NSString.class]) {
        if (error) *error = RBXCloudInputError(@"Cloud server must be a URL string");
        return NO;
    }
    NSString *value = [serverURL
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([value hasSuffix:@"/"] && value.length > 1) {
        value = [value substringToIndex:value.length - 1];
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:value];
    NSString *scheme = components.scheme.lowercaseString;
    NSString *host = components.host.lowercaseString;
    BOOL localDevelopment = [scheme isEqualToString:@"http"] &&
        ([host isEqualToString:@"localhost"] || [host isEqualToString:@"127.0.0.1"] ||
         [host isEqualToString:@"::1"]);
    if ((!value.length || !components.host.length) ||
        (![scheme isEqualToString:@"https"] && !localDevelopment)) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.cloud"
            code:12 userInfo:@{NSLocalizedDescriptionKey:
                @"Cloud server must use HTTPS."}];
        return NO;
    }
    NSMutableDictionary *settings = RBXCloudReadPlist();
    value = [RBXLicenseToken canonicalServer:value] ?: value;
    NSString *previousServer = [RBXLicenseToken canonicalServer:self.serverURL] ?: self.serverURL;
    if (![previousServer isEqual:value]) {
        // Credentials are issued by one cloud deployment. Changing its origin
        // cannot forward a previous deployment's token to the new server.
        [settings removeObjectsForKeys:@[@"deviceId", @"deviceToken", @"deviceName", @"deviceRole"]];
    }
    settings[@"serverURL"] = value;
    BOOL written = RBXCloudWritePlist(settings);
    if (!written && error) *error = [NSError errorWithDomain:@"com.redditbox.cloud"
        code:13 userInfo:@{NSLocalizedDescriptionKey: @"Cloud server settings could not be persisted."}];
    return written;
}

- (BOOL)acceptLicensePairing:(NSDictionary *)pairing context:(RBXOperationContext *)context error:(NSError **)error {
    if (!RBXCloudCheck(context, error) || ![context beginWork:error]) return NO;
    __block BOOL ok = NO;
    __block NSError *failure = nil;
    dispatch_block_t save = ^{
        [context performBlock:^{
            if (!RBXCloudCheck(context, &failure)) return;
            NSString *identifier = RBXCloudString(pairing, @"deviceId");
            NSString *token = RBXCloudString(pairing, @"token");
            NSString *server = RBXCloudString(pairing, @"serverURL");
            NSString *role = RBXCloudString(pairing, @"role");
            if (!identifier.length || !token.length || token.length > 4096 ||
                ![server isEqual:[RBXLicenseToken canonicalServer:self.serverURL]] ||
                ![@[@"factory", @"worker"] containsObject:role ?: @""]) {
                failure = RBXCloudInputError(@"Verified activation pairing is incomplete or the server changed"); return;
            }
            NSMutableDictionary *settings = RBXCloudReadPlist();
            NSString *previous = RBXCloudString(settings, @"deviceId");
            if (previous.length && ![previous isEqual:identifier]) {
                failure = RBXCloudInputError(@"Activation cannot replace an existing paired device identity; use a key for this device's owner"); return;
            }
            settings[@"deviceId"] = identifier;
            settings[@"serverURL"] = server;
            settings[@"deviceToken"] = token;
            settings[@"deviceName"] = RBXCloudString(pairing, @"name") ?: identifier;
            settings[@"deviceRole"] = role;
            ok = RBXCloudWritePlist(settings);
            if (!ok) failure = RBXCloudInputError(@"Activation pairing could not be persisted and verified; retry activation");
        }];
    };
    @try {
        if (dispatch_get_specific(&RBXCloudQueueKey) == (__bridge void *)self) save();
        else dispatch_sync(_queue, save);
    } @finally { [context endWork]; }
    if (!ok && error) *error = failure;
    return ok;
}

- (void)syncProfileInventoryWithCompletion:
    (void (^)(BOOL ok, NSString *message))done {
    BOOL owned = NO;
    RBXOperationContext *context = RBXCloudLegacyContext(&owned);
    [self syncProfileInventoryWithContext:context completion:done];
    if (owned) [context finishWhenQuiescent];
}

- (void)syncProfileInventoryWithContext:(RBXOperationContext *)context
    completion:(void (^)(BOOL ok, NSString *message))done {
    done = RBXCloudCompletion(context, done);
    RBXCloudDispatch(context, _queue, done, ^{
        NSString *server = self.serverURL, *token = self.deviceToken;
        NSString *device = RBXCloudString(RBXCloudReadPlist(), @"deviceId");
        if (!token.length || !device.length) { if (done) done(NO, @"Device is not paired"); return; }
        NSDictionary *binding = @{@"serverURL": server, @"deviceId": device};
        __block NSError *error = nil;
        BOOL (^current)(void) = ^BOOL {
            if (!RBXCloudCheck(context, &error)) return NO;
            if (![self.serverURL isEqual:server] || ![self.deviceToken isEqual:token] ||
                ![RBXCloudString(RBXCloudReadPlist(), @"deviceId") isEqual:device]) {
                error = RBXCloudInputError(@"Pairing changed during inventory reconciliation; retry refresh");
                return NO;
            }
            return YES;
        };
        NSDictionary *(^exchange)(NSString *, NSString *, NSDictionary *) =
        ^NSDictionary *(NSString *path, NSString *method, NSDictionary *body) {
            if (!current()) return nil;
            error = nil;
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
                [NSURL URLWithString:[server stringByAppendingString:path]]];
            request.HTTPMethod = method;
            request.timeoutInterval = kCloudHTTPTimeout;
            [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
            if (body) {
                [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
                request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&error];
                if (!request.HTTPBody) return nil;
            }
            NSData *data = [self _performDataRequest:request context:context error:&error];
            return current() ? RBXCloudResponseDictionary(data, &error) : nil;
        };
        RBXContainerRegistry *registry = [RBXContainerRegistry new];
        NSArray *records = [registry cloudDeletionRecordsWithError:&error];
        NSArray *localIds = [registry containerIdsWithError:&error];
        if (!records || !localIds) { if (done) done(NO, error.localizedDescription); return; }
        NSMutableArray *pending = [NSMutableArray array];
        for (NSDictionary *record in records)
            if ([record[@"binding"] isEqual:binding]) [pending addObject:record[@"containerId"]];
        // Journal intent precedes any import/publication. No acknowledgement
        // deletes the journal: retries are idempotent even after a lost response.
        for (NSUInteger offset = 0; offset < pending.count; offset += 256) {
            NSArray *batch = [pending subarrayWithRange:NSMakeRange(offset, MIN(256, pending.count - offset))];
            NSDictionary *reply = exchange(@"/api/profiles/reconcile", @"POST", @{@"profileIds": batch});
            NSArray *ack = [reply[@"tombstones"] isKindOfClass:NSArray.class] ? reply[@"tombstones"] : nil;
            NSMutableSet *confirmed = [NSMutableSet set];
            for (id item in ack) if ([item isKindOfClass:NSDictionary.class] &&
                RBXCanonicalProfileIdentifier(item[@"profileId"]) && [item[@"deviceId"] isEqual:device])
                [confirmed addObject:item[@"profileId"]];
            if (![reply[@"formatVersion"] isEqual:@1] || ![[NSSet setWithArray:batch] isSubsetOfSet:confirmed]) {
                if (done) done(NO, error.localizedDescription ?: @"Cloud deletion not confirmed; durable local intent retained");
                return;
            }
        }
        NSDictionary *inventory = exchange(@"/api/profiles", @"GET", nil);
        NSArray *profiles = [inventory[@"profiles"] isKindOfClass:NSArray.class] ? inventory[@"profiles"] : nil;
        NSArray *tombstones = [inventory[@"tombstones"] isKindOfClass:NSArray.class] ? inventory[@"tombstones"] : nil;
        if (![inventory[@"formatVersion"] isEqual:@1] || !profiles || !tombstones) {
            if (done) done(NO, error.localizedDescription ?: @"Cloud must support version 1 deletion reconciliation"); return;
        }
        // Validate the complete remote ID namespace before writing any profile.
        NSMutableSet *folded = [NSMutableSet set], *cloudIds = [NSMutableSet set];
        NSMutableDictionary *remoteMetadata = [NSMutableDictionary dictionary];
        for (id item in [profiles arrayByAddingObjectsFromArray:tombstones]) {
            NSString *identifier = [item isKindOfClass:NSDictionary.class] ? item[@"profileId"] : nil;
            if (!RBXCanonicalProfileIdentifier(identifier) || ![item[@"deviceId"] isEqual:device] ||
                [folded containsObject:identifier.lowercaseString]) {
                if (done) done(NO, @"Cloud inventory has invalid, ambiguous, or wrong-device profile IDs; no IDs were rewritten"); return;
            }
            [folded addObject:identifier.lowercaseString];
        }
        for (NSDictionary *entry in profiles) {
            if (!RBXCloudOptionalStrings(entry, @[@"country", @"nickname", @"role", @"notes"], &error)) {
                if (done) done(NO, error.localizedDescription); return;
            }
            if ((entry[@"role"] && ![RBXProfileRoles() containsObject:entry[@"role"]]) ||
                (entry[@"notes"] && !RBXProfileNotesValid(entry[@"notes"])) ||
                (entry[@"metadataRevision"] && (![entry[@"metadataRevision"] isKindOfClass:NSNumber.class] ||
                    [entry[@"metadataRevision"] longLongValue] < 0))) {
                if (done) done(NO, @"Cloud returned invalid organizational metadata; local edits retained"); return;
            }
            [cloudIds addObject:entry[@"profileId"]];
            remoteMetadata[entry[@"profileId"]] = entry;
        }
        NSMutableSet *existing = [NSMutableSet setWithArray:localIds];
        for (NSDictionary *entry in tombstones) {
            NSString *identifier = entry[@"profileId"];
            if (!current() || ![registry recordRemoteRetirementForContainer:identifier binding:binding error:&error]) {
                if (done) done(NO, error.localizedDescription); return;
            }
        }
        // Persist account/device provenance BEFORE an uncertain POST or local
        // import. A later offline Delete can then retire the same cloud record.
        BOOL (^bindProfile)(NSString *, BOOL) = ^BOOL(NSString *identifier, BOOL remoteExists) {
            if (!current()) return NO;
            __block BOOL conflict = NO;
            BOOL saved = [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
                id raw = doc[@"cloudProfileBindings"];
                if (raw && ![raw isKindOfClass:NSDictionary.class]) { conflict = YES; return; }
                NSMutableDictionary *bindings = raw ? [raw mutableCopy] : [NSMutableDictionary dictionary];
                id previous = bindings[identifier];
                if ((previous && ![previous isEqual:binding]) ||
                    (!previous && remoteExists && [existing containsObject:identifier])) { conflict = YES; return; }
                bindings[identifier] = binding;
                doc[@"cloudProfileBindings"] = bindings;
            } error:&error];
            if (conflict) error = RBXCloudInputError(@"Profile ID conflicts with an unbound or different-device record; local data preserved, explicit recovery required");
            return saved && !conflict;
        };
        NSMutableArray *failures = [NSMutableArray array];
        NSUInteger created = 0;
        for (NSString *identifier in localIds) {
            if (!current()) { if (done) done(NO, error.localizedDescription); return; }
            if ([registry deletionStateForContainer:identifier]) continue;
            if (!RBXCanonicalProfileIdentifier(identifier)) {
                [failures addObject:[NSString stringWithFormat:@"%@ has a legacy ID; explicit migration required", identifier]]; continue;
            }
            if (!bindProfile(identifier, [cloudIds containsObject:identifier])) {
                [failures addObject:error.localizedDescription]; continue;
            }
            NSDictionary *profile = RBXCloudLoadProfile(identifier, &error);
            if (!profile) { [failures addObject:error.localizedDescription]; continue; }
            // A successful POST whose response was lost is acknowledged by the
            // next exact-owner inventory snapshot. Divergent edits still conflict.
            if ([cloudIds containsObject:identifier] && (![profile[@"metadataDirty"] boolValue] ||
                RBXMetadataAcknowledgesLocalEdit(profile, remoteMetadata[identifier]))) {
                NSDictionary *remote = remoteMetadata[identifier];
                if (remote[@"metadataRevision"] && ![registry updateMetadata:RBXProfileMetadata(remote)
                    forContainer:identifier local:NO error:&error]) [failures addObject:error.localizedDescription];
                continue;
            }
            NSDictionary *stored = [[RBXCentralStore sharedStore] container:identifier];
            NSMutableDictionary *publication = [RBXProfileMetadata(profile) mutableCopy];
            [publication addEntriesFromDictionary:@{@"profileId": identifier,
                @"nickname": RBXProfileDisplayName(profile, stored[@"nickname"], identifier),
                @"country": profile[@"proxy"][@"country"] ?: @"US"}];
            NSDictionary *reply = exchange(@"/api/profiles", @"POST", publication);
            NSDictionary *published = [reply[@"profile"] isKindOfClass:NSDictionary.class] ? reply[@"profile"] : nil;
            if (published) published = RBXMetadataReplyWithLegacyName(published, publication[@"nickname"]);
            if (![published[@"profileId"] isEqual:identifier] || ![published[@"deviceId"] isEqual:device] ||
                !published[@"metadataRevision"] || ![registry updateMetadata:published forContainer:identifier local:NO error:&error]) {
                [failures addObject:[NSString stringWithFormat:@"%@: %@. Local role/notes retained, including any pending name. For a revision conflict, review both copies then use 'Use cloud name, role & notes' to accept cloud edits.",
                    identifier, error.localizedDescription ?: @"Cloud did not confirm metadata and exact ID/device"]];
            }
        }
        for (NSDictionary *entry in profiles) {
            if (!current()) { if (done) done(NO, error.localizedDescription); return; }
            NSString *identifier = entry[@"profileId"];
            // Old unbound deletion receipts still block resurrection. They
            // cannot authorize deletion in a newly paired cloud account.
            if ([registry deletionStateForContainer:identifier] || [existing containsObject:identifier]) continue;
            if (!bindProfile(identifier, YES)) { [failures addObject:error.localizedDescription]; continue; }
            NSString *actual = [registry createContainerWithId:identifier
                proxyCountry:RBXCloudString(entry, @"country") ?: @"US" proxyURL:@""
                nickname:RBXCloudString(entry, @"nickname") ?: identifier error:&error];
            if (!actual || ![actual isEqual:identifier]) {
                [failures addObject:error.localizedDescription ?: @"Imported profile ID did not match cloud ID"]; continue;
            }
            [existing addObject:actual];
            if (entry[@"metadataRevision"] && ![registry updateMetadata:RBXProfileMetadata(entry)
                forContainer:actual local:NO error:&error]) [failures addObject:error.localizedDescription];
            created++;
        }
        if (done) done(failures.count == 0, failures.count ? [failures componentsJoinedByString:@"; "] :
            [NSString stringWithFormat:@"%lu profile(s) imported; deletions reconciled; pending local cleanup is shown in the launcher", (unsigned long)created]);
    });
}

- (void)syncLauncherConfigurationWithCompletion:
    (void (^)(BOOL ok, NSString *message))done {
    BOOL owned = NO;
    RBXOperationContext *context = RBXCloudLegacyContext(&owned);
    [self syncLauncherConfigurationWithContext:context completion:done];
    if (owned) [context finishWhenQuiescent];
}

- (void)syncLauncherConfigurationWithContext:(RBXOperationContext *)context
    completion:(void (^)(BOOL ok, NSString *message))done {
    done = RBXCloudCompletion(context, done);
    RBXCloudDispatch(context, _queue, done, ^{
        if (!self.paired) {
            if (done) done(YES, @"No paired cloud device; local settings retained");
            return;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
            [NSURL URLWithString:[[self serverURL]
                stringByAppendingString:@"/api/rotation-settings"]]];
        request.HTTPMethod = @"GET";
        request.timeoutInterval = kCloudHTTPTimeout;
        [request setValue:[NSString stringWithFormat:@"Bearer %@", self.deviceToken]
       forHTTPHeaderField:@"Authorization"];
        NSError *error = nil;
        NSData *data = [self _performDataRequest:request context:context error:&error];
        NSDictionary *decoded = RBXCloudResponseDictionary(data, &error);
        if (!decoded) {
            if (done) done(NO, error.localizedDescription ?: @"Invalid cloud configuration");
            return;
        }
        id raw = decoded[@"settings"];
        if (!raw || raw == NSNull.null) {
            if (done) done(YES, @"Cloud has no global settings; local settings retained");
            return;
        }
        if (![raw isKindOfClass:[NSDictionary class]]) {
            if (done) done(NO, @"Cloud returned malformed rotation settings");
            return;
        }
        NSDictionary *settings = raw;
        if (!RBXCloudOptionalStrings(settings, @[@"proxyURL", @"rotationURL", @"authHeader",
            @"authorization", @"method", @"updatedAt"], &error)) {
            if (done) done(NO, error.localizedDescription);
            return;
        }
        NSMutableDictionary *secure = [@{
            @"proxyURL": [settings[@"proxyURL"] isKindOfClass:[NSString class]]
                ? settings[@"proxyURL"] : @"",
            @"rotationURL": [settings[@"rotationURL"] isKindOfClass:[NSString class]]
                ? settings[@"rotationURL"] : @"",
            @"authHeader": [settings[@"authHeader"] isKindOfClass:[NSString class]]
                ? settings[@"authHeader"] : @"Authorization",
            @"authorization": [settings[@"authorization"] isKindOfClass:[NSString class]]
                ? settings[@"authorization"] : @"",
            @"method": [settings[@"method"] isKindOfClass:[NSString class]]
                ? settings[@"method"] : @"POST",
            @"source": @"cloud",
        } mutableCopy];
        if ([settings[@"updatedAt"] isKindOfClass:[NSString class]]) {
            secure[@"cloudUpdatedAt"] = settings[@"updatedAt"];
        }
        NSError *saveError = nil;
        if (!RBXCloudCheck(context, &saveError) ||
            ![RBXSecureConfig saveRotationConfiguration:secure error:&saveError]) {
            if (done) done(NO, saveError.localizedDescription);
            return;
        }
        if (done) done(YES, @"Cloud rotation settings applied to Keychain");
    });
}

- (void)syncProxyAssignmentForContainer:(NSString *)containerId
                             completion:(void (^)(BOOL, NSString *))done {
    BOOL owned = NO;
    RBXOperationContext *context = RBXCloudLegacyContext(&owned);
    [self syncProxyAssignmentForContainer:containerId context:context completion:done];
    if (owned) [context finishWhenQuiescent];
}

- (void)syncProxyAssignmentForContainer:(NSString *)containerId context:(RBXOperationContext *)context
                             completion:(void (^)(BOOL, NSString *))done {
    done = RBXCloudCompletion(context, done);
    RBXCloudDispatch(context, _queue, done, ^{
        NSError *profileError = nil;
        if (!RBXCloudLoadProfile(containerId, &profileError)) {
            if (done) done(NO, profileError.localizedDescription);
            return;
        }
        if (!self.paired) {
            if (done) done(NO, @"Device is not paired");
            return;
        }
        // Publication is owned by inventory reconciliation, which first binds
        // durable deletion intent. Launch must never silently re-register an ID.
        NSDictionary *bindings = [[RBXCentralStore sharedStore] dictionary][@"cloudProfileBindings"];
        NSString *device = RBXCloudString(RBXCloudReadPlist(), @"deviceId");
        NSDictionary *expected = device.length ? @{@"serverURL": self.serverURL, @"deviceId": device} : nil;
        if (!RBXCanonicalProfileIdentifier(containerId) || ![bindings isKindOfClass:NSDictionary.class] ||
            ![bindings[containerId] isEqual:expected]) {
            if (done) done(NO, @"Refresh cloud inventory to register this profile on the paired device before opening it");
            return;
        }

        NSString *urlString = [[self serverURL] stringByAppendingString:@"/api/profile-proxies"];
        NSMutableURLRequest *request =
            [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
        [request setValue:[NSString stringWithFormat:@"Bearer %@", self.deviceToken]
       forHTTPHeaderField:@"Authorization"];
        request.timeoutInterval = kCloudHTTPTimeout;
        NSError *requestError = nil;
        NSData *data = [self _performDataRequest:request context:context error:&requestError];
        NSDictionary *response = RBXCloudResponseDictionary(data, &requestError);
        if (!response) {
            if (done) done(NO, requestError.localizedDescription);
            return;
        }
        NSArray *assignments = RBXCloudAssignmentArray(response, &requestError);
        if (!assignments) {
            if (done) done(NO, requestError.localizedDescription);
            return;
        }
        NSDictionary *match = nil;
        for (NSDictionary *entry in assignments) {
            if ([entry isKindOfClass:[NSDictionary class]] &&
                [RBXCloudString(entry, @"profileId") isEqualToString:containerId]) {
                match = entry;
                break;
            }
        }
        NSDictionary *proxy = [match[@"proxy"] isKindOfClass:[NSDictionary class]]
            ? match[@"proxy"] : nil;
        if (proxy && !RBXCloudOptionalStrings(proxy,
            @[@"url", @"id", @"country", @"healthStatus"], &requestError)) {
            if (done) done(NO, requestError.localizedDescription);
            return;
        }
        NSString *proxyURL = RBXCloudString(proxy, @"url");
        if (requestError || !proxyURL.length ||
            [RBXCloudString(proxy, @"healthStatus") isEqualToString:@"unhealthy"]) {
            if (done) done(NO, requestError.localizedDescription ?: @"No healthy proxy assignment");
            return;
        }

        NSMutableDictionary *profile = RBXCloudLoadProfile(containerId, &profileError);
        if (!profile) {
            if (done) done(NO, profileError.localizedDescription);
            return;
        }
        NSMutableDictionary *proxySection = [profile[@"proxy"] isKindOfClass:[NSDictionary class]]
            ? [profile[@"proxy"] mutableCopy] : [NSMutableDictionary dictionary];
        proxySection[@"url"] = proxyURL;
        proxySection[@"proxyId"] = proxy[@"id"] ?: @"";
        if ([proxy[@"country"] isKindOfClass:[NSString class]] &&
            [proxy[@"country"] length]) {
            proxySection[@"country"] = [proxy[@"country"] uppercaseString];
        }
        profile[@"proxy"] = proxySection;
        profile[@"mgOverrides"] = RBXBuildMGOverrides(profile);
        if (!RBXCloudWriteProfile(profile, containerId, YES, &profileError)) {
            if (done) done(NO, profileError.localizedDescription);
            return;
        }
        if (done) done(YES, nil);
    });
}

- (void)syncRotationAuthForContainer:(NSString *)containerId
                          completion:(void (^)(BOOL, NSString *))done {
    BOOL owned = NO;
    RBXOperationContext *context = RBXCloudLegacyContext(&owned);
    [self syncRotationAuthForContainer:containerId context:context completion:done];
    if (owned) [context finishWhenQuiescent];
}

- (void)syncRotationAuthForContainer:(NSString *)containerId context:(RBXOperationContext *)context
                          completion:(void (^)(BOOL, NSString *))done {
    done = RBXCloudCompletion(context, done);
    RBXCloudDispatch(context, _queue, done, ^{
        NSError *profileError = nil;
        if (!RBXCloudLoadProfile(containerId, &profileError)) {
            if (done) done(NO, profileError.localizedDescription);
            return;
        }
        if (!self.paired) {
            if (done) done(YES, nil); // local/global configuration is authoritative fallback
            return;
        }
        // Publication is owned by inventory reconciliation, which first binds
        // durable deletion intent. Launch must never silently re-register an ID.
        NSDictionary *bindings = [[RBXCentralStore sharedStore] dictionary][@"cloudProfileBindings"];
        NSString *device = RBXCloudString(RBXCloudReadPlist(), @"deviceId");
        NSDictionary *expected = device.length ? @{@"serverURL": self.serverURL, @"deviceId": device} : nil;
        if (!RBXCanonicalProfileIdentifier(containerId) || ![bindings isKindOfClass:NSDictionary.class] ||
            ![bindings[containerId] isEqual:expected]) {
            if (done) done(NO, @"Refresh cloud inventory to register this profile on the paired device before opening it");
            return;
        }
        NSError *requestError = nil;

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
            [NSURL URLWithString:[[self serverURL]
                stringByAppendingString:@"/api/profile-proxies"]]];
        request.timeoutInterval = kCloudHTTPTimeout;
        [request setValue:[NSString stringWithFormat:@"Bearer %@", self.deviceToken]
       forHTTPHeaderField:@"Authorization"];
        NSData *data = [self _performDataRequest:request context:context error:&requestError];
        NSDictionary *response = RBXCloudResponseDictionary(data, &requestError);
        if (![response isKindOfClass:[NSDictionary class]]) {
            if (done) done(NO, requestError.localizedDescription ?: @"Malformed rotation auth response");
            return;
        }
        NSArray *assignments = RBXCloudAssignmentArray(response, &requestError);
        if (!assignments) {
            if (done) done(NO, requestError.localizedDescription);
            return;
        }
        NSDictionary *match = nil;
        for (id candidate in assignments) {
            if ([candidate isKindOfClass:[NSDictionary class]] &&
                [RBXCloudString(candidate, @"profileId") isEqualToString:containerId]) {
                match = candidate;
                break;
            }
        }
        id rawAuth = match[@"rotationAuth"];
        if (rawAuth && rawAuth != NSNull.null && ![rawAuth isKindOfClass:NSDictionary.class]) {
            if (done) done(NO, @"Cloud rotation authentication must be an object");
            return;
        }
        NSDictionary *auth = [rawAuth isKindOfClass:NSDictionary.class] ? rawAuth : nil;
        if (!RBXCloudOptionalStrings(auth, @[@"header", @"value"], &requestError)) {
            if (done) done(NO, requestError.localizedDescription);
            return;
        }
        NSString *header = [auth[@"header"] isKindOfClass:[NSString class]]
            ? auth[@"header"] : nil;
        NSString *value = [auth[@"value"] isKindOfClass:[NSString class]]
            ? auth[@"value"] : nil;
        NSCharacterSet *invalidHeader = [[NSCharacterSet
            characterSetWithCharactersInString:
                @"!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"]
            invertedSet];
        if ((header.length && [header rangeOfCharacterFromSet:invalidHeader].location != NSNotFound) ||
            header.length > 128 || value.length > 4096) {
            if (done) done(NO, @"Cloud rotation auth override is invalid");
            return;
        }

        NSMutableDictionary *profile = RBXCloudLoadProfile(containerId, &profileError);
        if (!profile) {
            if (done) done(NO, profileError.localizedDescription);
            return;
        }
        NSDictionary *override = header.length && value.length ? @{@"header": header, @"value": value} : @{};
        BOOL written = RBXCloudCheck(context, &profileError) &&
            [RBXRotationSecrets saveOverride:override profile:containerId error:&profileError] &&
            RBXCloudWriteProfile(RBXProfileForTransport(profile), containerId, YES, &profileError);
        if (done) done(written, written ? nil : profileError.localizedDescription);
    });
}

- (void)reportProxyId:(NSString *)proxyId healthy:(BOOL)healthy message:(NSString *)message {
    BOOL owned = NO;
    RBXOperationContext *context = RBXCloudLegacyContext(&owned);
    [self reportProxyId:proxyId healthy:healthy message:message context:context];
    if (owned) [context finishWhenQuiescent];
}

- (void)reportProxyId:(NSString *)proxyId healthy:(BOOL)healthy message:(NSString *)message context:(RBXOperationContext *)context {
    if (!RBXCloudCheck(context, nil)) return;
    if (![proxyId isKindOfClass:NSString.class] || !proxyId.length || !self.paired) return;
    NSString *escaped = [proxyId stringByAddingPercentEncodingWithAllowedCharacters:
                         NSCharacterSet.alphanumericCharacterSet];
    NSString *url = [[self serverURL] stringByAppendingFormat:@"/api/proxies/%@/health", escaped];
    RBXCloudPostJSON(url,
                     @{@"healthy": @(healthy), @"message": message ?: @""},
                     self.deviceToken, context,
                     ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error || status < 200 || status >= 300) {
            NSLog(@"redditboxd: could not report proxy health (%@)",
                  error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)status]);
        }
    });
}

// ---------------------------------------------------------------------------
// Pairing

- (void)pairWithCode:(NSString *)pairingCode
          completion:(void (^)(BOOL ok, NSString *message))done {
    BOOL owned = NO;
    RBXOperationContext *context = RBXCloudLegacyContext(&owned);
    [self pairWithCode:pairingCode context:context completion:done];
    if (owned) [context finishWhenQuiescent];
}

- (void)pairWithCode:(NSString *)pairingCode context:(RBXOperationContext *)context
          completion:(void (^)(BOOL ok, NSString *message))done {
    done = RBXCloudCompletion(context, done);
    RBXCloudDispatch(context, _queue, done, ^{
        NSString *server = self.serverURL;
        RBXCloudPostJSON([server stringByAppendingString:@"/api/devices/claim"],
                          @{@"pairingCode": pairingCode ?: @""},
                          nil, context,
                          ^(NSData *data, NSURLResponse *resp, NSError *err) {
            RBXCloudDispatch(context, self->_queue, done, ^{
            NSString *message = nil;
            BOOL ok = NO;
            NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (err) {
                message = [NSString stringWithFormat:@"Pairing failed: %@", err.localizedDescription];
            } else if (![json isKindOfClass:[NSDictionary class]]) {
                message = @"Pairing failed: bad server response";
            } else if ([json[@"error"] isKindOfClass:[NSString class]]) {
                message = [NSString stringWithFormat:@"Pairing failed: %@", json[@"error"]];
            } else {
                NSString *tok = nil;
                if ([json[@"token"] isKindOfClass:[NSString class]] && [(NSString *)json[@"token"] length] > 0) {
                    tok = json[@"token"];
                } else if ([json[@"deviceToken"] isKindOfClass:[NSString class]] && [(NSString *)json[@"deviceToken"] length] > 0) {
                    tok = json[@"deviceToken"];
                }
                if (tok.length) {
                    NSMutableDictionary *d = RBXCloudReadPlist();
                    d[@"deviceId"] = [json[@"deviceId"] isKindOfClass:[NSString class]] ? json[@"deviceId"] : @"";
                    d[@"deviceToken"] = tok;
                    id name = json[@"name"] ?: json[@"deviceId"];
                    d[@"deviceName"] = [name isKindOfClass:[NSString class]] ? name : @"device";
                    if ([json[@"role"] isKindOfClass:[NSString class]]) d[@"deviceRole"] = json[@"role"];
                    ok = RBXCloudWritePlist(d);
                    message = ok ? [NSString stringWithFormat:@"Paired as %@ (%@)",
                        d[@"deviceName"], d[@"deviceId"]] :
                        @"Pairing response received, but its credentials could not be persisted.";
                    if (ok) NSLog(@"redditboxd: cloud Ă˘â‚¬â€ť claimed pairing as %@", d[@"deviceName"]);
                } else {
                    message = @"Pairing failed: server response has no token";
                }
            }
            if (done) done(ok, message);
            });
        });
    });
}

// ---------------------------------------------------------------------------
// Container location helpers

- (NSString *)_dataContainerForProfile:(NSDictionary *)profile {
    NSDictionary *descriptor = RBXAppDescriptorForProfile(profile);
    NSString *container = [profile isKindOfClass:NSDictionary.class] ? profile[@"containerId"] : nil;
    if (![RBXProfileIO isSafeContainerIdentifier:container] ||
        RBXAppProfileIdentityBlockReason(descriptor, profile, container)) return nil;
    NSString *bundleIdentifier = RBXCloudString(profile[@"app"], @"bundleIdentifier");
    return [bundleIdentifier isEqual:RBXAppBundleIdentifier(descriptor, container)]
        ? [[[RBXCloneManager alloc] initWithAppType:descriptor[@"appType"]
            operationContext:[RBXOperationContext currentContext]] dataContainerForBundleIdentifier:bundleIdentifier]
        : nil;
}

// Which container is active right now (binding file, same constant as
// RBXProcessController/RBXContainerManager).
- (NSString *)_activeContainerId {
    NSString *raw = [NSString stringWithContentsOfFile:kBindingFile
                                              encoding:NSUTF8StringEncoding error:nil];
    NSString *active = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return active.length ? active : nil;
}

- (NSDictionary *)_loadProfile:(NSString *)containerId error:(NSError **)error {
    return RBXCloudLoadProfile(containerId, error);
}

// ---------------------------------------------------------------------------
// Export

- (void)exportContainer:(NSString *)containerId
             completion:(void (^)(BOOL ok, NSString *message))done {
    BOOL owned = NO;
    RBXOperationContext *context = RBXCloudLegacyContext(&owned);
    [self exportContainer:containerId context:context completion:done];
    if (owned) [context finishWhenQuiescent];
}

- (void)exportContainer:(NSString *)containerId context:(RBXOperationContext *)context
             completion:(void (^)(BOOL ok, NSString *message))done {
    done = RBXCloudCompletion(context, done);
    RBXCloudDispatch(context, _queue, done, ^{
        NSString *message = nil;
        BOOL ok = [self _exportContainer:containerId context:context message:&message];
        if (done) done(ok, message);
    });
}

- (BOOL)_exportContainer:(NSString *)containerId context:(RBXOperationContext *)context message:(NSString **)message {
    if (!RBXCloudMessageCheck(context, message)) return NO;
    // Resolve target container: explicit id wins, else binding file, else
    // single-container fallback.
    if (containerId && ![containerId isKindOfClass:NSString.class]) {
        if (message) *message = @"Export failed: profile identifier must be a string";
        return NO;
    }
    NSString *container = containerId;
    if (![container length]) {
        container = [self _activeContainerId];
        if (![container length]) {
            NSError *inventoryError = nil;
            NSArray *ids = [[RBXContainerRegistry new] containerIdsWithError:&inventoryError];
            if (!ids) {
                if (message) *message = [NSString stringWithFormat:@"Export failed: %@", inventoryError.localizedDescription];
                return NO;
            }
            if (ids.count == 1) container = ids[0];
        }
    }
    if (![container length]) {
        if (message) *message = @"Export failed: no container id (launch a container first or set the id field)";
        NSLog(@"redditboxd: cloud Ă˘â‚¬â€ť export failed: no container id");
        return NO;
    }

    if (![self paired]) {
        if (message) *message = @"Export failed: device not paired (enter a pairing code first)";
        return NO;
    }
    NSString *passphrase = self.passphrase;
    if (passphrase.length < 16) {
        if (message) *message = @"Export failed: no passphrase on device";
        return NO;
    }

    NSError *profileError = nil;
    NSDictionary *profile = [self _loadProfile:container error:&profileError];
    if (!profile) {
        if (message) *message = [NSString stringWithFormat:@"Export failed: %@", profileError.localizedDescription];
        return NO;
    }
    NSDictionary *descriptor = RBXAppDescriptorForProfile(profile);
    if (!descriptor || ![descriptor[@"runnable"] boolValue]) {
        if (message) *message = @"Export blocked: this app is not enabled"; return NO;
    }
    NSString *containerDir = [self _dataContainerForProfile:profile];
    if (!RBXCloudIsDir(containerDir)) {
        if (message) *message = [NSString stringWithFormat:
                                 @"Export failed: no OS data container for %@", container];
        return NO;
    }

    NSError *closureError = nil;
    if (!RBXCloudQuiesce(context, &closureError)) {
        if (message) *message = closureError.localizedDescription; return NO;
    }

    // Stage under a stable archive name; never export MobileContainerManager
    // ownership metadata into another clone/device.
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"redditbox-export-%@", [NSUUID UUID].UUIDString]];
    NSError *stageError = nil;
    if (!RBXCloudPrepareStage(tmp, container, @"export", context, &stageError)) {
        if (message) *message = [NSString stringWithFormat:@"Export failed: %@; staging retained at %@",
            stageError.localizedDescription, tmp];
        return NO;
    }
    NSString *stagedData = [tmp stringByAppendingPathComponent:@"AppData"];
    if (!RBXCloudCheck(context, &stageError) ||
        ![RBXBackupSnapshot copyQuiescentTree:containerDir to:stagedData context:context error:&stageError]) {
        if (message) *message = [NSString stringWithFormat:
            @"Export failed: cannot stage OS data container (%@); recovery retained at %@",
            stageError.localizedDescription, tmp];
        return NO;
    }
    if (!RBXCloudCheck(context, &stageError)) {
        if (message) *message = [NSString stringWithFormat:@"%@; recovery retained at %@", stageError.localizedDescription, tmp];
        return NO;
    }
    [[NSFileManager defaultManager] removeItemAtPath:[stagedData
        stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]
        error:nil];
    // The sandbox may still contain a profile written by an older version.
    // Never upload it (or follow a symlink supplied by app data).
    NSString *stagedProfile = [stagedData stringByAppendingPathComponent:
        @"Library/Application Support/RedditBox/profile.json"];
    for (NSString *relative in @[@"Library", @"Library/Application Support", @"Library/Application Support/RedditBox"]) {
        struct stat info;
        NSString *path = [stagedData stringByAppendingPathComponent:relative];
        if (lstat(path.fileSystemRepresentation, &info) == 0 && !S_ISDIR(info.st_mode)) {
            if (message) *message = @"Export blocked: staged profile directory is not a real directory"; return NO;
        }
    }
    struct stat stagedInfo;
    if (lstat(stagedProfile.fileSystemRepresentation, &stagedInfo) == 0) {
        if (![NSFileManager.defaultManager removeItemAtPath:stagedProfile error:&stageError]) {
            if (message) *message = @"Export blocked: legacy clone-local profile could not be excluded"; return NO;
        }
    } else if (errno != ENOENT) {
        if (message) *message = @"Export blocked: cannot inspect staged clone-local profile"; return NO;
    }
    NSString *archivePath = [tmp stringByAppendingPathComponent:@"container.tar.gz"];
    if (!RBXCloudTarContainer(@"AppData", tmp, archivePath, context, &stageError)) {
        if (message) *message = [NSString stringWithFormat:@"Export failed: %@; recovery retained at %@",
            stageError.localizedDescription, tmp];
        return NO;
    }
    if (!RBXCloudCheck(context, &stageError)) {
        if (message) *message = [NSString stringWithFormat:@"%@; recovery retained at %@", stageError.localizedDescription, tmp];
        return NO;
    }
    NSData *archive = [NSData dataWithContentsOfFile:archivePath options:0 error:&stageError];
    if (!archive.length) {
        if (message) *message = @"Export failed: empty archive";
        return NO;
    }

    if (!RBXCloudMessageCheck(context, message)) return NO;
    // manifest.json — display name from profile/legacy metadata, username from
    // the central store, appVersion from the monitor, identity/proxy from profile.
    NSDictionary *storeDoc = [_store dictionary];
    NSDictionary *storedContainers = [storeDoc[@"containers"] isKindOfClass:NSDictionary.class]
        ? storeDoc[@"containers"] : nil;
    NSDictionary *cont = storedContainers[container];
    if (![cont isKindOfClass:[NSDictionary class]]) cont = @{};

    NSDictionary *profileSeed = @{
        @"productType": [profile[@"device"][@"productType"] isKindOfClass:[NSString class]] ? profile[@"device"][@"productType"] : @"",
        @"iosVersion": [profile[@"device"][@"iosVersion"] isKindOfClass:[NSString class]] ? profile[@"device"][@"iosVersion"] : @"",
        @"locale": [profile[@"device"][@"locale"] isKindOfClass:[NSString class]] ? profile[@"device"][@"locale"] : @"",
        @"timezone": [profile[@"device"][@"timezone"] isKindOfClass:[NSString class]] ? profile[@"device"][@"timezone"] : @"",
        @"location": [profile[@"device"][@"location"] isKindOfClass:[NSDictionary class]] ? profile[@"device"][@"location"] : @{},
        @"carrier": [profile[@"device"][@"carrier"] isKindOfClass:[NSDictionary class]] ? profile[@"device"][@"carrier"] : @{},
        @"deviceName": [profile[@"device"][@"deviceName"] isKindOfClass:[NSString class]] ? profile[@"device"][@"deviceName"] : @"",
        @"idfa": [profile[@"ids"][@"idfa"] isKindOfClass:[NSString class]] ? profile[@"ids"][@"idfa"] : @"",
        @"idfv": [profile[@"ids"][@"idfv"] isKindOfClass:[NSString class]] ? profile[@"ids"][@"idfv"] : @"",
        @"batteryOffset": [profile[@"timing"][@"batteryOffsetPercent"] isKindOfClass:[NSString class]] ? profile[@"timing"][@"batteryOffsetPercent"] : @"0",
        @"bootTimeOffset": [profile[@"timing"][@"bootTimeOffsetSeconds"] isKindOfClass:[NSString class]] ? profile[@"timing"][@"bootTimeOffsetSeconds"] : @"0",
        @"syntheticBootEpoch": [profile[@"timing"][@"syntheticBootEpoch"] isKindOfClass:[NSString class]] ? profile[@"timing"][@"syntheticBootEpoch"] : @"",
        @"installId": [profile[@"reddit"][@"installId"] isKindOfClass:[NSString class]] ? profile[@"reddit"][@"installId"] : @"",
        @"installTimestampMs": [profile[@"reddit"][@"installTimestampMs"] isKindOfClass:[NSString class]] ? profile[@"reddit"][@"installTimestampMs"] : @"",
        @"redditDeviceName": [profile[@"reddit"][@"deviceName"] isKindOfClass:[NSString class]] ? profile[@"reddit"][@"deviceName"] : @"",
        @"identityCustomization": [profile[@"identityCustomization"] isKindOfClass:[NSDictionary class]] ? profile[@"identityCustomization"] : @{},
        @"security": [profile[@"security"] isKindOfClass:[NSDictionary class]] ? profile[@"security"] : @{},
    };
    NSDictionary *proxy = @{
        @"url": [profile[@"proxy"][@"url"] isKindOfClass:[NSString class]] ? profile[@"proxy"][@"url"] : @"",
        @"country": [profile[@"proxy"][@"country"] isKindOfClass:[NSString class]] ? profile[@"proxy"][@"country"] : @"",
    };
    NSDictionary *attest = [cont[@"attest"] isKindOfClass:[NSDictionary class]] ? cont[@"attest"] : @{};
    NSArray *keyIds = [attest[@"keyIds"] isKindOfClass:[NSArray class]] ? attest[@"keyIds"] : @[];
    NSString *keyId = keyIds.count && [keyIds[0] isKindOfClass:[NSString class]] ? keyIds[0] : nil;
    BOOL attestEnabled = ![[_store effectiveAttestModeForContainer:container] isEqualToString:@"off"];

    NSISO8601DateFormatter *iso = [[NSISO8601DateFormatter alloc] init];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    NSString *exportedAt = [iso stringFromDate:[NSDate date]] ?: @"";

    // Specified envelope + archiveB64 (container data must travel for worker restore).
    NSMutableDictionary *envelope = [@{
        @"schemaVersion": @1,
        @"storageArchitecture": @"clonedApp-v2",
        @"snapshotPolicy": @"closed-stopped-verified-copy-v1",
        @"credentialTransfer": @{@"appData": @"included", @"keychain": @"not-exported",
            @"deviceBoundKeys": @"not-transferable", @"loginPreserved": @NO, @"requiresLoginVerification": @YES},
        @"containerId": container,
        @"profile": RBXProfileForTransport(profile),
        @"exportedAt": exportedAt,
        @"sourceDeviceModel": [profile[@"device"][@"productType"] isKindOfClass:[NSString class]] ?
            profile[@"device"][@"productType"] : @"",
        @"proxyHint": proxy,
        @"attest": @{
            @"attestEnabled": @(attestEnabled),
        },
        @"archiveB64": [archive base64EncodedStringWithOptions:0],
        @"nickname": RBXProfileDisplayName(profile, cont[@"nickname"], container),
        @"username": [cont[@"username"] isKindOfClass:[NSString class]] ? cont[@"username"] : @"",
        @"appVersion": [RBXAppVersionMonitor installedRedditVersion] ?: @"",
        @"profileSeed": profileSeed,
        @"proxy": proxy,
        @"pushEnabled": @NO,
    } mutableCopy];
    if (![descriptor[@"appType"] isEqual:@"reddit"]) {
        envelope[@"schemaVersion"] = @2;
        envelope[@"appType"] = descriptor[@"appType"];
        envelope[@"sourceBundleIdentifier"] = descriptor[@"sourceBundleIdentifier"];
        envelope[@"restorePolicy"] = @"same-logical-identity-new-local-container-v1";
        // Full profile is authoritative for app-specific state. Do not encode
        // unrelated Reddit seeds or claim the installed Reddit app version.
        envelope[@"profileSeed"] = @{@"appType":descriptor[@"appType"]};
        envelope[@"appVersion"] = profile[@"app"][@"sourceVersion"] ?: @"";
    }
    if (!RBXCloudValidateManifest(envelope, container, &stageError)) {
        if (message) *message = stageError.localizedDescription; return NO;
    }
    if (keyId.length) {
        NSMutableDictionary *att = [envelope[@"attest"] mutableCopy];
        att[@"keyId"] = keyId;
        envelope[@"attest"] = att;
    }

    NSData *plaintext = [NSJSONSerialization dataWithJSONObject:envelope
                                                       options:NSJSONWritingSortedKeys
                                                         error:nil];
    if (!plaintext) {
        if (message) *message = @"Export failed: cannot encode envelope";
        return NO;
    }

    if (!RBXCloudMessageCheck(context, message)) return NO;
    NSData *salt = RBXCloudRandom(kSaltLen);
    NSData *nonce = RBXCloudRandom(kNonceLen);
    if (!salt || !nonce) {
        if (message) *message = @"Export failed: SecRandomCopyBytes";
        return NO;
    }
    NSData *sealed = RBXCloudEncrypt(passphrase, plaintext, salt, nonce);
    if (!sealed) {
        if (message) *message = @"Export failed: encryption";
        return NO;
    }

    NSDictionary *body = @{
        @"containerId": container,
        @"iv": [nonce base64EncodedStringWithOptions:0],
        @"salt": [salt base64EncodedStringWithOptions:0],
        @"checksum": RBXCloudSHA256Hex(sealed),
        @"createdAt": exportedAt,
        @"attestKeyUsed": @(attestEnabled && keyId.length > 0),
    };

    NSError *err = nil;
    if (![self _uploadSealed:sealed metadata:body context:context error:&err]) {
        if (message) *message = [NSString stringWithFormat:@"Export failed: %@; recovery retained at %@",err.localizedDescription ?: @"upload not confirmed",tmp];
        return NO;
    }
    if (!RBXCloudLoadProfile(container, &profileError)) {
        if (message) *message = [NSString stringWithFormat:
            @"Backup uploaded, but local export state could not be updated: %@; recovery retained at %@",
            profileError.localizedDescription, tmp];
        return NO;
    }

    NSLog(@"redditboxd: cloud Ă˘â‚¬â€ť exported %@ (%lu bytes ciphertext)", container, (unsigned long)sealed.length);
    if (message) *message = [NSString stringWithFormat:@"Exported %@ (%lu KB). App files included; Keychain and device-bound credentials are not transferred. Login must be verified after restore.",
                             container, (unsigned long)(sealed.length / 1024)];
    [_store update:^(NSMutableDictionary *doc) {
        if (![doc[@"containers"] isKindOfClass:[NSMutableDictionary class]]) {
            doc[@"containers"] = [NSMutableDictionary dictionary];
        }
        NSMutableDictionary *c = [doc[@"containers"][container] isKindOfClass:[NSDictionary class]] ?
            [doc[@"containers"][container] mutableCopy] : [NSMutableDictionary dictionary];
        c[@"lastExportAt"] = @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]);
        doc[@"containers"][container] = c;
    }];
    if (!RBXCloudCheck(context, &profileError)) {
        if (message) *message = [NSString stringWithFormat:@"%@; recovery retained at %@", profileError.localizedDescription, tmp];
        return NO;
    }
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    return YES;
}

// ---------------------------------------------------------------------------
// Import

- (void)importNewestBackup:(void (^)(BOOL ok, NSString *message))done {
    BOOL owned = NO;
    RBXOperationContext *context = RBXCloudLegacyContext(&owned);
    [self importNewestBackupWithContext:context completion:done];
    if (owned) [context finishWhenQuiescent];
}

- (void)importNewestBackupWithContext:(RBXOperationContext *)context completion:(void (^)(BOOL ok, NSString *message))done {
    done = RBXCloudCompletion(context, done);
    RBXCloudDispatch(context, _queue, done, ^{
        NSString *message = nil;
        BOOL ok = [self _importWithBackupId:nil context:context message:&message];
        if (done) done(ok, message);
    });
}

- (void)importBackupWithId:(NSString *)backupId
               completion:(void (^)(BOOL ok, NSString *message))done {
    BOOL owned = NO;
    RBXOperationContext *context = RBXCloudLegacyContext(&owned);
    [self importBackupWithId:backupId context:context completion:done];
    if (owned) [context finishWhenQuiescent];
}

- (void)importBackupWithId:(NSString *)backupId context:(RBXOperationContext *)context
                completion:(void (^)(BOOL ok, NSString *message))done {
    done = RBXCloudCompletion(context, done);
    RBXCloudDispatch(context, _queue, done, ^{
        NSString *message = nil;
        BOOL ok = [self _importWithBackupId:backupId context:context message:&message];
        if (done) done(ok, message);
    });
}

// Core import. backupId nil = "newest" (respecting expireDays + freshness).
- (BOOL)_importWithBackupId:(NSString *)backupId context:(RBXOperationContext *)context message:(NSString **)message {
    return [self _importWithBackupId:backupId expectedAppType:nil context:context message:message];
}

- (BOOL)_importWithBackupId:(NSString *)backupId expectedAppType:(NSString *)expectedAppType context:(RBXOperationContext *)context message:(NSString **)message {
    if (expectedAppType && !RBXAppDescriptorForType(expectedAppType)) { if (message) *message = @"Unknown backup app type"; return NO; }
    if (!RBXCloudMessageCheck(context, message)) return NO;
    if (backupId && ![backupId isKindOfClass:NSString.class]) {
        if (message) *message = @"Import failed: backup identifier must be a string";
        return NO;
    }
    if (![self paired]) {
        if (message) *message = @"Import failed: device not paired";
        return NO;
    }
    NSString *passphrase = self.passphrase;
    if (passphrase.length < 16) {
        if (message) *message = @"Import failed: no passphrase on device";
        return NO;
    }

    // ---- list backups
    NSString *listUrl = [[self serverURL] stringByAppendingString:@"/api/backups"];
    if (expectedAppType) listUrl = [listUrl stringByAppendingFormat:@"?appType=%@", expectedAppType];
    NSMutableURLRequest *listReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:listUrl]];
    if (!listReq || !listReq.URL) {
        if (message) *message = @"Import failed: bad server URL";
        return NO;
    }
    listReq.timeoutInterval = kCloudHTTPTimeout;
    [listReq setValue:[NSString stringWithFormat:@"Bearer %@", self.deviceToken] forHTTPHeaderField:@"Authorization"];

    NSError *err = nil;
    NSData *listData = [self _performDataRequest:listReq context:context error:&err];
    if (!listData || err) {
        if (message) *message = [NSString stringWithFormat:@"Import failed: list (%@)",
                                 err.localizedDescription ?: @"no response"];
        return NO;
    }
    id listObj = [NSJSONSerialization JSONObjectWithData:listData options:0 error:nil];
    NSArray *backups = nil;
    if ([listObj isKindOfClass:[NSArray class]]) {
        backups = listObj;
    } else if ([listObj isKindOfClass:[NSDictionary class]] && [listObj[@"backups"] isKindOfClass:[NSArray class]]) {
        backups = listObj[@"backups"];
    }
    if (![backups isKindOfClass:[NSArray class]]) {
        if (message) *message = @"Import failed: bad backup list";
        return NO;
    }

    // Normalize entries (list shape: {backups:[{backupId|id, containerId, createdAt}]}).
    NSMutableArray *entries = [NSMutableArray array];
    for (id b in backups) {
        if (!RBXCloudMessageCheck(context, message)) return NO;
        if (![b isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *e = (NSDictionary *)b;
        NSString *bid = [e[@"backupId"] isKindOfClass:[NSString class]] ? e[@"backupId"] : nil;
        if (!bid.length && [e[@"id"] isKindOfClass:[NSString class]]) bid = e[@"id"];
        if (!bid.length) continue;
        NSTimeInterval exportedAt = RBXCloudParseTime(e[@"createdAt"]);
        if (exportedAt <= 0) exportedAt = RBXCloudParseTime(e[@"exportedAt"]);
        [entries addObject:@{
            @"id": bid,
            @"containerId": [e[@"containerId"] isKindOfClass:[NSString class]] ? e[@"containerId"] : @"",
            @"exportedAt": @(exportedAt),
        }];
    }
    if (entries.count == 0) {
        if (message) *message = @"Import failed: no backups on server";
        return NO;
    }

    NSDictionary *chosen = nil;
    if (backupId.length) {
        for (NSDictionary *e in entries) {
            if ([e[@"id"] isEqualToString:backupId]) { chosen = e; break; }
        }
        if (!chosen) {
            if (message) *message = [NSString stringWithFormat:@"Import failed: backup %@ not found", backupId];
            return NO;
        }
    } else {
        // newest, skipping blobs older than expireDays (default 7)
        NSMutableDictionary *cfg = RBXCloudReadPlist();
        NSInteger expireDays = 7;
        if ([cfg[@"expireDays"] isKindOfClass:[NSNumber class]]) {
            expireDays = [(NSNumber *)cfg[@"expireDays"] integerValue];
        }
        if (expireDays <= 0) expireDays = 7;
        NSTimeInterval cutoff = [[NSDate date] timeIntervalSince1970] - expireDays * 86400.0;

        NSArray *sorted = [entries sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            double ta = [a[@"exportedAt"] doubleValue];
            double tb = [b[@"exportedAt"] doubleValue];
            return ta > tb ? NSOrderedAscending : (ta < tb ? NSOrderedDescending : NSOrderedSame);
        }];
        for (NSDictionary *e in sorted) {
            double exportedAt = [e[@"exportedAt"] doubleValue];
            if (exportedAt <= 0) continue;
            if (exportedAt >= cutoff) { chosen = e; break; }
            NSLog(@"redditboxd: cloud Ă˘â‚¬â€ť skipping expired backup %@ (older than %ldd)",
                  e[@"id"], (long)expireDays);
        }
        if (!chosen) {
            [_store addAlertType:@"STALE BACKUP" containerId:@""
                         message:[NSString stringWithFormat:
                                   @"All backups are older than %ld days Ă˘â‚¬â€ť nothing to import.", (long)expireDays]];
            if (message) *message = @"Import failed: all backups expired";
            return NO;
        }
    }

    // ---- freshness (>72h refused unless allowStale; >24h warning)
    double exportedAt = [chosen[@"exportedAt"] doubleValue];
    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - exportedAt;
    BOOL allowStale = RBXCloudBool(RBXCloudReadPlist(), @"allowStale", NO);
    if (age > 72 * 3600.0 && !allowStale) {
        [_store addAlertType:@"STALE BACKUP" containerId:chosen[@"containerId"]
                     message:[NSString stringWithFormat:
                               @"Backup %@ is %.1f h old Ă˘â‚¬â€ť import refused (enable Allow Stale Imports to override).",
                               chosen[@"id"], age / 3600.0]];
        if (message) *message = [NSString stringWithFormat:@"Import refused: backup is %.1f h old (>72h)", age / 3600.0];
        return NO;
    }
    if (age > 24 * 3600.0) {
        [_store addAlertType:@"STALE BACKUP" containerId:chosen[@"containerId"]
                     message:[NSString stringWithFormat:
                               @"Backup %@ is %.1f h old Ă˘â‚¬â€ť imported anyway (within policy).", chosen[@"id"], age / 3600.0]];
    }

    // ---- fetch the backup JSON (specified contract)
    NSString *blobPath = [NSString stringWithFormat:@"/api/backups/%@?transfer=1",
                         [chosen[@"id"] stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet alphanumericCharacterSet]]];
    NSString *blobUrl = [self.serverURL stringByAppendingString:blobPath];
    NSMutableURLRequest *blobReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:blobUrl]];
    if (!blobReq || !blobReq.URL) {
        if (message) *message = @"Import failed: bad backup URL";
        return NO;
    }
    blobReq.timeoutInterval = kCloudHTTPTimeout;
    [blobReq setValue:[NSString stringWithFormat:@"Bearer %@", self.deviceToken] forHTTPHeaderField:@"Authorization"];
    [blobReq setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSData *respBody = [self _performDataRequest:blobReq context:context error:&err];
    if (!respBody.length || err) {
        if (message) *message = [NSString stringWithFormat:@"Import failed: download (%@)",
                                 err.localizedDescription ?: @"no data"];
        return NO;
    }

    if (!RBXCloudMessageCheck(context, message)) return NO;
    NSDictionary *manifest = nil;
    NSData *archive = nil;
    id decoded = [NSJSONSerialization JSONObjectWithData:respBody options:0 error:nil];
    if ([decoded isKindOfClass:[NSDictionary class]] &&
        ([decoded[@"ciphertext"] isKindOfClass:[NSString class]] || [decoded[@"transport"] isEqual:@"chunks-v1"])) {
        if (!RBXCloudOptionalStrings(decoded, @[@"ciphertext", @"iv", @"salt", @"checksum"], &err)) {
            if (message) *message = err.localizedDescription;
            return NO;
        }
        NSData *sealed = [decoded[@"transport"] isEqual:@"chunks-v1"]
            ? [self _downloadParts:decoded path:blobPath context:context error:&err]
            : [[NSData alloc] initWithBase64EncodedString:decoded[@"ciphertext"] options:0];
        if (!sealed) { if (message) *message=err.localizedDescription ?: @"Backup ciphertext is unavailable.";return NO; }
        NSData *iv = [[NSData alloc] initWithBase64EncodedString:decoded[@"iv"] ?: @"" options:0];
        NSData *salt = [[NSData alloc] initWithBase64EncodedString:decoded[@"salt"] ?: @"" options:0];
        if ([decoded[@"checksum"] isKindOfClass:[NSString class]] && sealed.length) {
            NSString *got = RBXCloudSHA256Hex(sealed);
            if (![got isEqualToString:[decoded[@"checksum"] lowercaseString]] &&
                ![got isEqualToString:decoded[@"checksum"]]) {
                if (message) *message = @"Import failed: checksum mismatch";
                return NO;
            }
        }
        NSData *payload = (iv.length == kNonceLen && salt.length == kSaltLen)
            ? RBXCloudDecryptParts(passphrase, sealed, salt, iv)
            : RBXCloudDecrypt(passphrase, sealed);
        if (!payload) {
            [_store addAlertType:@"WRONG PASSPHRASE" containerId:chosen[@"containerId"]
                         message:@"Backup could not be decrypted with this device's passphrase."];
            if (message) *message = @"Import failed: wrong passphrase (see WRONG PASSPHRASE alert)";
            return NO;
        }
        id env = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
        if ([env isKindOfClass:[NSDictionary class]] && env[@"schemaVersion"]) {
            manifest = env;
            if ([env[@"archiveB64"] isKindOfClass:[NSString class]]) {
                archive = [[NSData alloc] initWithBase64EncodedString:env[@"archiveB64"] options:0];
            }
        } else {
            archive = RBXCloudParsePayload(payload, &manifest);
        }
    } else {
        // Legacy packed blob (salt||nonce||ciphertext||tag)
        NSData *payload = RBXCloudDecrypt(passphrase, respBody);
        if (!payload) {
            [_store addAlertType:@"WRONG PASSPHRASE" containerId:chosen[@"containerId"]
                         message:@"Backup could not be decrypted with this device's passphrase."];
            if (message) *message = @"Import failed: wrong passphrase (see WRONG PASSPHRASE alert)";
            return NO;
        }
        archive = RBXCloudParsePayload(payload, &manifest);
    }
    if (![manifest isKindOfClass:[NSDictionary class]]) {
        if (message) *message = @"Import failed: bad payload";
        return NO;
    }

    // Public list metadata is not the authority for decrypted app ownership.
    if (expectedAppType && ![RBXCloudBackupDescriptor(manifest)[@"appType"] isEqual:expectedAppType]) {
        if (message) *message = @"Backup belongs to another app; no container was created."; return NO;
    }
    if (!RBXCloudCheck(context, &err) || !RBXCloudValidateManifest(manifest, chosen[@"containerId"], &err)) {
        if (message) *message = [NSString stringWithFormat:@"Import failed: %@", err.localizedDescription];
        return NO;
    }
    NSDictionary *descriptor = RBXCloudBackupDescriptor(manifest);
    NSString *origId = manifest[@"containerId"];
    if (![origId length]) {
        if (message) *message = @"Import failed: manifest has no containerId";
        return NO;
    }
    NSDictionary *proxyHint = [manifest[@"proxyHint"] isKindOfClass:[NSDictionary class]] ? manifest[@"proxyHint"] : nil;
    if (!proxyHint) proxyHint = [manifest[@"proxy"] isKindOfClass:[NSDictionary class]] ? manifest[@"proxy"] : @{};
    NSString *proxyURL = [proxyHint[@"url"] isKindOfClass:[NSString class]] ? proxyHint[@"url"] : @"";
    NSString *proxyCountry = [proxyHint[@"country"] isKindOfClass:[NSString class]] ? proxyHint[@"country"] : @"";
    NSDictionary *seed = [manifest[@"profileSeed"] isKindOfClass:[NSDictionary class]] ? manifest[@"profileSeed"] : @{};
    if ((![seed count] || ![descriptor[@"appType"] isEqual:@"reddit"]) &&
        [manifest[@"profile"] isKindOfClass:[NSDictionary class]]) {
        NSDictionary *full = manifest[@"profile"];
        seed = @{
            @"productType": full[@"device"][@"productType"] ?: @"",
            @"iosVersion": full[@"device"][@"iosVersion"] ?: @"",
            @"locale": full[@"device"][@"locale"] ?: @"",
            @"timezone": full[@"device"][@"timezone"] ?: @"",
            @"location": full[@"device"][@"location"] ?: @{},
            @"idfa": full[@"ids"][@"idfa"] ?: @"",
            @"idfv": full[@"ids"][@"idfv"] ?: @"",
        };
        if (![proxyURL length] && [full[@"proxy"][@"url"] isKindOfClass:[NSString class]]) {
            proxyURL = full[@"proxy"][@"url"];
        }
        if (![proxyCountry length] && [full[@"proxy"][@"country"] isKindOfClass:[NSString class]]) {
            proxyCountry = full[@"proxy"][@"country"];
        }
    }
    NSString *seedLocale = [seed[@"locale"] isKindOfClass:[NSString class]] ? seed[@"locale"] : @"";
    NSString *seedTz = [seed[@"timezone"] isKindOfClass:[NSString class]] ? seed[@"timezone"] : @"";

    // ---- proxy continuity (HARD FAIL; a person changing phones doesn't change
    // country the same day)
    if (![self _checkProxyContinuity:proxyURL
                        proxyCountry:proxyCountry
                          seedLocale:seedLocale
                        seedTimezone:seedTz error:&err]) {
        [_store addAlertType:@"PROXY MISMATCH" containerId:origId
                     message:[NSString stringWithFormat:
                               @"Import of %@ refused: the legacy proxy host (%@) is not usable/geo-consistent on this phone.",
                               origId, [NSURL URLWithString:proxyURL].host ?: @"none"]];
        if (message) *message = err.localizedDescription ?: @"Import refused: PROXY MISMATCH";
        return NO;
    }

    // A restore receives a canonical fresh local ID. It must still pass the
    // same uniqueness checks as launch before its identity can be committed.
    NSString *newId = [@"restored-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    if (!RBXCloudProfileAvailable(newId, &err)) {
        if (message) *message = err.localizedDescription; return NO;
    }

    NSString *tmpRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"redditbox-import-%@", [NSUUID UUID].UUIDString]];
    if (!RBXCloudPrepareStage(tmpRoot, newId, @"import", context, &err)) {
        if (message) *message = [NSString stringWithFormat:@"Import failed: %@; staging retained at %@", err.localizedDescription, tmpRoot];
        return NO;
    }
    BOOL ok = NO;
    BOOL profileCreated = NO;
    BOOL profileWriteAttempted = NO;
    NSString *extractedData = nil;
    NSString *failMsg = nil;
    @try {
        if (archive.length) {
            NSString *archivePath = [tmpRoot stringByAppendingPathComponent:@"container.tar.gz"];
            if (!RBXCloudCheck(context, &err) || ![archive writeToFile:archivePath atomically:YES]) {
                failMsg = @"Import failed: cannot write archive to temp";
            }
            if (!failMsg) {
                if (!RBXCloudUntar(archivePath, tmpRoot, origId, context, &err))
                    failMsg = [NSString stringWithFormat:@"Import failed: %@", err.localizedDescription];
            }
            if (!failMsg) {
                extractedData = [tmpRoot stringByAppendingPathComponent:@"AppData"];
                if (!RBXCloudIsDir(extractedData)) {
                    // Compatibility with pre-clone backups.
                    extractedData = [tmpRoot stringByAppendingPathComponent:origId];
                }
                if (!RBXCloudIsDir(extractedData)) {
                    failMsg = @"Import failed: archive has no AppData directory";
                }
            }
        } else {
            NSLog(@"redditboxd: cloud Ă˘â‚¬â€ť backup has no archive; restoring profile only");
        }

        if (!failMsg && extractedData && ![RBXBackupSnapshot validateDatabasesInTree:extractedData context:context error:&err])
            failMsg = err.localizedDescription;
        if (!failMsg && !RBXCloudQuiesce(context, &err)) failMsg = err.localizedDescription;
        if (!failMsg) {
            profileWriteAttempted = YES;
            failMsg = [self _writeWorkerProfileForOrigId:origId newId:newId
                                              proxyURL:proxyURL proxyCountry:proxyCountry
                                                manifest:manifest] ?: nil;
            profileCreated = failMsg == nil;
        }

        if (!failMsg && !RBXCloudCheck(context, &err)) failMsg = err.localizedDescription;
        if (!failMsg) {
            RBXContainerRegistry *registry = [RBXContainerRegistry new];
            NSError *cloneError = nil;
            if (![registry ensureAppCloneForContainer:newId error:&cloneError]) {
                failMsg = [NSString stringWithFormat:
                    @"Import failed: cannot install worker clone (%@)",
                    cloneError.localizedDescription];
            } else {
                NSDictionary *workerProfile = [self _loadProfile:newId error:&cloneError];
                if (!workerProfile || ![RBXAppDescriptorForProfile(workerProfile) isEqual:descriptor])
                    failMsg = @"Import failed: worker app ownership changed";
                NSString *workerData = [self _dataContainerForProfile:workerProfile];
                if (!failMsg && !workerData.length) {
                    failMsg = @"Import failed: worker OS data container is missing";
                } else if (!failMsg && extractedData.length) {
                    NSError *restoreError = nil;
                    if (!RBXCloudRestoreDataContents(extractedData, workerData, context,
                                                     &restoreError)) {
                        failMsg = [NSString stringWithFormat:
                            @"Import failed: cannot restore clone data (%@)",
                            restoreError.localizedDescription];
                    }
                }
                if (!failMsg &&
                    ![[[RBXCloneManager alloc] initWithAppType:descriptor[@"appType"] operationContext:context]
                        syncProfile:workerProfile error:&cloneError]) {
                    failMsg = [NSString stringWithFormat:
                        @"Import failed: cannot synchronize worker profile (%@)",
                        cloneError.localizedDescription];
                }
            }
        }

        if (!failMsg && (!RBXCloudCheck(context, &err) ||
            ![RBXAppDescriptorForProfile(RBXCloudLoadProfile(newId, &err)) isEqual:descriptor]))
            failMsg = @"Import failed: worker profile ownership could not be reverified";
        if (!failMsg) {
            // ---- register in central store
            NSMutableDictionary *cfg = RBXCloudReadPlist();
            NSString *attestPolicy = [cfg[@"workerAttestPolicy"] isKindOfClass:[NSString class]] ?
                                         cfg[@"workerAttestPolicy"] : @"re-attest";
            BOOL attestOff = [attestPolicy isEqualToString:@"off"];
            if (![descriptor[@"appType"] isEqual:@"reddit"] &&
                [manifest[@"profile"][@"security"][@"appAttest"] isEqual:@"blocked"])
                attestOff = YES;

            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            NSString *nickname = [manifest[@"nickname"] isKindOfClass:[NSString class]] && [manifest[@"nickname"] length] ?
                                     manifest[@"nickname"] : origId;
            NSDictionary *cont = @{
                @"nickname": [nickname stringByAppendingFormat:@" (worker)"],
                @"username": [manifest[@"username"] isKindOfClass:[NSString class]] ? manifest[@"username"] : @"",
                @"createdAt": @(now),
                @"importedAt": @(now),
                @"importedFrom": origId,
                // LIFE-019 / ID-010: restore continues an existing logical
                // identity, so it is frozen before its first local launch.
                // This is local lifecycle metadata, not a device identifier.
                @"identityFrozenAt": @(now),
                @"status": @"yellow",
                @"push": @{ @"enabled": @NO, @"token": [NSNull null] },
                // attest.origin worker-rekey: the worker's re-attest consumes
                // THIS phone's key budget Ă˘â‚¬â€ť dashboards can distinguish factory
                // vs worker consumption.
                @"attest": @{
                    @"mode": attestOff ? @"off" : @"auto",
                    @"origin": @"worker-rekey",
                    @"keyIds": @[],
                },
                @"lastCloudImport": chosen[@"id"],
                @"loginKnown": @NO, @"requiresLoginVerification": @YES,
                @"credentialTransfer": @"app-data-only; Keychain not transferred",
            };
            if (![descriptor[@"appType"] isEqual:@"reddit"]) {
                NSMutableDictionary *typed = [cont mutableCopy];
                typed[@"appType"] = descriptor[@"appType"];
                typed[@"restorePolicy"] = manifest[@"restorePolicy"];
                cont = typed;
            }
            BOOL registered = [_store update:^(NSMutableDictionary *doc) {
                if (![doc[@"containers"] isKindOfClass:[NSMutableDictionary class]]) {
                    doc[@"containers"] = [NSMutableDictionary dictionary];
                }
                doc[@"containers"][newId] = cont;
            } error:&err];

            NSLog(@"redditboxd: cloud Ă˘â‚¬â€ť imported %@ -> %@ (attest origin worker-rekey, policy %@)",
                  origId, newId, attestPolicy);
            ok = registered;
            if (!registered) failMsg = err.localizedDescription ?: @"Restore registry publication failed";
            if (message && registered) *message = [NSString stringWithFormat:@"Imported %@ as %@. %@; Keychain/device-bound credentials were not transferred. Open and verify login; sign in again if required.", origId, newId,
                archive.length ? @"App files restored" : @"Profile metadata only: this backup contained no app files"];
        }
    }
    @finally {
        // Expiry leaves staging and its prewritten target record for recovery.
        // The main controller owns cancellation/drain; an expired request must
        // never start a fresh destructive rollback budget.
    }

    if (!RBXCloudCheck(context, &err)) {
        if (message) *message = [NSString stringWithFormat:@"%@; recovery retained at %@", err.localizedDescription, tmpRoot];
        return NO;
    }
    if (profileWriteAttempted && !profileCreated) {
        // A writer can commit bytes and still fail durability/readback. Its
        // error is not proof that no profile exists. Retain the prewritten
        // recovery stage without adopting or deleting an uncertain candidate.
        if (message) *message = [NSString stringWithFormat:@"%@; profile publication uncertain; recovery retained at %@",
            failMsg ?: @"Import failed", tmpRoot];
        return NO;
    }
    if (!ok) {
        NSError *rollbackError = nil;
        // A changed candidate must be retained for review, not erased under
        // whatever app owner now occupies this local identifier.
        NSDictionary *rollbackProfile = profileCreated ? RBXCloudLoadProfile(newId, &rollbackError) : nil;
        BOOL owned = rollbackProfile && [RBXAppDescriptorForProfile(rollbackProfile) isEqual:descriptor];
        BOOL recovered = !profileCreated || (owned && [[RBXContainerRegistry new] deleteContainer:newId error:&rollbackError]);
        if (profileCreated && !owned && !rollbackError)
            rollbackError = RBXCloudInputError(@"Worker ownership changed; candidate retained for recovery");
        if (!recovered || !RBXCloudCheck(context, &err)) {
            if (message) *message = [NSString stringWithFormat:@"%@; rollback: %@; recovery retained at %@",
                failMsg ?: @"Import failed", rollbackError.localizedDescription ?: err.localizedDescription, tmpRoot];
            return NO;
        }
        [[NSFileManager defaultManager] removeItemAtPath:tmpRoot error:nil];
        if (message) *message = failMsg ?: @"Import failed";
        [_store addAlertType:@"CLOUD ERROR" containerId:origId message:failMsg ?: @"Import failed"];
        return NO;
    }
    [[NSFileManager defaultManager] removeItemAtPath:tmpRoot error:nil];
    return YES;
}

// Writes the new worker profile. Identity continuity is preserved (idfa/idfv/
// locale/tz/location + model facts when this phone matches the factory phone;
// only the attest key is new), and the profile stays a COMPLETE document so
// RBXConsistencyValidator still passes at launch. Returns an error message or nil.
- (NSString *)_writeWorkerProfileForOrigId:(NSString *)origId
                                    newId:(NSString *)newId
                               proxyURL:(NSString *)proxyURL
                            proxyCountry:(NSString *)proxyCountry
                               manifest:(NSDictionary *)manifest {
    // New envelopes carry the complete profile; legacy Reddit envelopes may
    // carry only profileSeed. Rebuild a complete worker profile so the daemon's
    // RBXConsistencyValidator still passes at launch (catalog facts like
    // ramBytes/screen/carrier must match the model). Strategy: start from a
    // freshly generated synthetic profile (catalog model/OS tuple,
    // geo-derived fields for the backup's proxy country Ă˘â‚¬â€ť the Ă‚Â§13.1 rules
    // hold), then overwrite the identity-critical fields with the backup's
    // seed for the selected app's same-logical-identity continuation
    // (idfa/idfv/locale/tz/location/model facts; only the attest key is new).
    NSError *profileError = nil;
    if (!RBXCloudCheck([RBXOperationContext currentContext], &profileError) ||
        !RBXCloudProfileAvailable(newId, &profileError) ||
        !RBXCloudValidateManifest(manifest, origId, &profileError)) return profileError.localizedDescription;
    NSDictionary *descriptor = RBXCloudBackupDescriptor(manifest);
    NSDictionary *fullProfile = [manifest[@"profile"] isKindOfClass:[NSDictionary class]] ? manifest[@"profile"] : nil;
    NSDictionary *seed = [manifest[@"profileSeed"] isKindOfClass:[NSDictionary class]] ? manifest[@"profileSeed"] : @{};
    if ((!fullProfile || fullProfile.count == 0) && seed.count == 0) {
        return @"Import failed: envelope has no profile";
    }

    NSString *(^seedStr)(NSString *) = ^NSString *(NSString *key) {
        id v = seed[key];
        return [v isKindOfClass:[NSString class]] ? v : @"";
    };
    NSDictionary *location = [seed[@"location"] isKindOfClass:[NSDictionary class]] ? seed[@"location"] : @{};

    NSString *country = proxyCountry.length ? proxyCountry : @"US";
    NSMutableDictionary *profile = [[RBXProfileGenerator generateProfileForContainerId:newId
                                              appType:descriptor[@"appType"]
                                              proxyCountry:country
                                           existingProfiles:@[]
                                                     error:&profileError] mutableCopy];
    if (!profile) {
        return [NSString stringWithFormat:@"Import failed: cannot generate a base profile for %@ (%@)",
            newId, profileError.localizedDescription ?: @"catalog unavailable"];
    }
    profile[@"containerId"] = newId;
    if (fullProfile.count) {
        if ([fullProfile[@"ids"] isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *ids = [(profile[@"ids"] ?: @{}) mutableCopy];
            [ids addEntriesFromDictionary:fullProfile[@"ids"]];
            profile[@"ids"] = ids;
        }
        if ([fullProfile[@"serials"] isKindOfClass:[NSDictionary class]]) {
            profile[@"serials"] = fullProfile[@"serials"];
        }
        if ([fullProfile[@"timing"] isKindOfClass:[NSDictionary class]]) {
            profile[@"timing"] = fullProfile[@"timing"];
        }
        NSString *appNamespace = descriptor[@"appType"];
        if ([fullProfile[appNamespace] isKindOfClass:NSDictionary.class]) {
            profile[appNamespace] = fullProfile[appNamespace];
        }
        if ([fullProfile[@"security"] isKindOfClass:[NSDictionary class]]) {
            profile[@"security"] = fullProfile[@"security"];
        }
        if ([fullProfile[@"identityCustomization"] isKindOfClass:[NSDictionary class]]) {
            profile[@"identityCustomization"] = fullProfile[@"identityCustomization"];
        }
    }

    // Preserve the complete synthetic tuple rather than comparing it to the host.
    NSDictionary *baseDevice = [profile[@"device"] isKindOfClass:[NSDictionary class]] ? profile[@"device"] : @{};
    NSMutableDictionary *device = [baseDevice mutableCopy];
    if ([fullProfile[@"device"] isKindOfClass:[NSDictionary class]]) {
        device = [fullProfile[@"device"] mutableCopy];
    } else if ([seedStr(@"productType") length]) {
        NSDictionary *model = [RBXDeviceCatalog modelForProductType:seedStr(@"productType")];
        if (!model || ![model[@"iosVersions"] containsObject:seedStr(@"iosVersion")])
            return @"Import failed: backup has an unsupported synthetic model/OS tuple";
        device[@"productType"] = seedStr(@"productType");
        device[@"marketingName"] = model[@"marketingName"];
        device[@"hwModelStr"] = model[@"hwModelStr"];
        device[@"regulatoryModel"] = model[@"regulatoryModel"];
        device[@"ramBytes"] = model[@"ramBytes"];
        device[@"screen"] = model[@"screen"];
        device[@"gpuName"] = [NSString stringWithFormat:@"Apple %@ GPU", model[@"chip"]];
        device[@"modelNumber"] = [NSString stringWithFormat:@"%@%@", model[@"modelBase"],
            [RBXDeviceCatalog regionSuffixForCountry:country]];
        device[@"iosVersion"] = seedStr(@"iosVersion");
        device[@"buildVersion"] = [RBXDeviceCatalog buildForIOS:seedStr(@"iosVersion")];
        device[@"darwinRelease"] = [RBXDeviceCatalog darwinForIOS:seedStr(@"iosVersion")];
    }
    if ([seedStr(@"locale") length]) device[@"locale"] = seedStr(@"locale");
    if ([seedStr(@"timezone") length]) device[@"timezone"] = seedStr(@"timezone");
    if ([(NSDictionary *)location count] > 0) device[@"location"] = location;
    if ([seedStr(@"deviceName") length]) device[@"deviceName"] = seedStr(@"deviceName");
    NSDictionary *seedCarrier = [seed[@"carrier"] isKindOfClass:[NSDictionary class]]
        ? seed[@"carrier"] : @{};
    for (NSDictionary *candidate in [RBXDeviceCatalog carriersForCountry:country]) {
        if ([[NSString stringWithFormat:@"%@", candidate[@"mcc"]]
                isEqualToString:[NSString stringWithFormat:@"%@", seedCarrier[@"mcc"]]] &&
            [[NSString stringWithFormat:@"%@", candidate[@"mnc"]]
                isEqualToString:[NSString stringWithFormat:@"%@", seedCarrier[@"mnc"]]]) {
            device[@"carrier"] = candidate;
            break;
        }
    }
    profile[@"device"] = device;

    NSMutableDictionary *ids = [(profile[@"ids"] ?: @{}) mutableCopy];
    if ([seedStr(@"idfa") length]) ids[@"idfa"] = seedStr(@"idfa");
    if ([seedStr(@"idfv") length]) ids[@"idfv"] = seedStr(@"idfv");
    profile[@"ids"] = ids;

    if ([descriptor[@"appType"] isEqual:@"reddit"]) {
        NSMutableDictionary *reddit = [(profile[@"reddit"] ?: @{}) mutableCopy];
        if ([seedStr(@"installId") length]) reddit[@"installId"] = seedStr(@"installId");
        if ([seedStr(@"installTimestampMs") length]) reddit[@"installTimestampMs"] = seedStr(@"installTimestampMs");
        if ([seedStr(@"redditDeviceName") length]) reddit[@"deviceName"] = seedStr(@"redditDeviceName");
        profile[@"reddit"] = reddit;
    }

    NSMutableDictionary *timing = [(profile[@"timing"] ?: @{}) mutableCopy];
    if ([seedStr(@"batteryOffset") length]) timing[@"batteryOffsetPercent"] = seedStr(@"batteryOffset");
    if ([seedStr(@"bootTimeOffset") length]) timing[@"bootTimeOffsetSeconds"] = seedStr(@"bootTimeOffset");
    if ([seedStr(@"syntheticBootEpoch") length]) timing[@"syntheticBootEpoch"] = seedStr(@"syntheticBootEpoch");
    profile[@"timing"] = timing;
    if ([seed[@"security"] isKindOfClass:[NSDictionary class]]) {
        profile[@"security"] = seed[@"security"];
    }
    if ([seed[@"identityCustomization"] isKindOfClass:[NSDictionary class]]) {
        profile[@"identityCustomization"] = seed[@"identityCustomization"];
    }

    NSMutableDictionary *proxySec = [profile[@"proxy"] isKindOfClass:[NSDictionary class]] ?
        [profile[@"proxy"] mutableCopy] : [NSMutableDictionary dictionary];
    if (proxyURL.length) proxySec[@"url"] = proxyURL;
    if (proxyCountry.length) proxySec[@"country"] = proxyCountry;
    profile[@"proxy"] = proxySec;

    profile[@"validation"] = @{ @"proxyCountry": proxyCountry ?: @"", @"geoConsistent": @YES };
    profile[@"mgOverrides"] = RBXBuildMGOverrides(profile);

    NSDictionary *validated = [[RBXContainerRegistry new] validatedImportedProfile:profile error:&profileError];
    if (!validated) return [NSString stringWithFormat:@"Import refused before profile publication: %@", profileError.localizedDescription];
    profile = [validated mutableCopy];
    if (!RBXCloudCheck([RBXOperationContext currentContext], &profileError) ||
        ![[NSFileManager defaultManager] createDirectoryAtPath:kProfilesDir
        withIntermediateDirectories:YES attributes:nil error:&profileError] ||
        !RBXCloudWriteProfile(profile, newId, NO, &profileError)) {
        return [NSString stringWithFormat:@"Import failed: %@", profileError.localizedDescription];
    }
    return nil;
}

// Proxy continuity: the SAME upstream must be usable from this phone and its
// country must be geo-consistent with the seed (locale/timezone country Ă˘â‚¬â€ť the
// RBXConsistencyValidator Ă‚Â§13.1 checks, reused informally via the catalog).
- (BOOL)_checkProxyContinuity:(NSString *)proxyURL
                  proxyCountry:(NSString *)proxyCountry
                    seedLocale:(NSString *)seedLocale
                   seedTimezone:(NSString *)seedTz error:(NSError **)error {
    if (![proxyURL length]) return NO;         // no proxy in the backup
    if (![proxyCountry length]) return NO;     // no country in the backup

    NSURL *u = [NSURL URLWithString:proxyURL];
    if (!u || ![u.host length]) return NO;    // malformed upstream

    NSString *localeCountry = [RBXDeviceCatalog countryForLocale:seedLocale];
    if (localeCountry.length && ![localeCountry isEqualToString:proxyCountry]) return NO;

    NSString *tzCountry = [RBXDeviceCatalog countryForTimezone:seedTz];
    if (tzCountry.length && ![tzCountry isEqualToString:proxyCountry]) return NO;

    // This phone must be able to use the SAME upstream. If the proxy pool has
    // no global rotating gateway ("*") and doesn't already contain this URL,
    // register it so RBXProxyManager can activate it for the imported
    // container (activation + exit-IP validation re-runs at launch).
    if (!RBXCloudCheck([RBXOperationContext currentContext], error)) return NO;
    NSMutableDictionary *poolMut = [RBXProxyManager readPool:error];
    if (!poolMut) return NO;
    NSArray *star = poolMut[@"*"];
    if ([star isKindOfClass:[NSArray class]] && star.count > 0) return YES;   // global gateway covers it

    BOOL present = NO;
    for (NSString *cid in poolMut) {
        NSArray *l = poolMut[cid];
        if ([l isKindOfClass:[NSArray class]] && [l containsObject:proxyURL]) { present = YES; break; }
    }
    if (!present) {
        NSMutableArray *entry = [NSMutableArray array];
        if ([poolMut[@"__socialbox__"] isKindOfClass:[NSArray class]]) {
            [entry addObjectsFromArray:poolMut[@"__socialbox__"]];
        }
        if (![entry containsObject:proxyURL]) [entry addObject:proxyURL];
        poolMut[@"__socialbox__"] = entry;
        if (![RBXProxyManager writePool:poolMut error:error]) return NO;
        NSURL *redactedURL = [NSURL URLWithString:proxyURL];
        NSLog(@"redditboxd: cloud Ă˘â‚¬â€ť registered legacy backup upstream host %@",
              redactedURL.host ?: @"invalid");
    }
    return YES;
}

// ---------------------------------------------------------------------------

// Each request stays below the hosting payload limit. The final ciphertext
// checksum and AEAD tag still bind the complete archive before any restore.
- (NSDictionary *)_transferJSON:(NSString *)path body:(NSDictionary *)body context:(RBXOperationContext *)context error:(NSError **)error {
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:[self.serverURL stringByAppendingString:path]]];
    request.HTTPMethod=body?@"POST":@"GET";
    [request setValue:[NSString stringWithFormat:@"Bearer %@",self.deviceToken] forHTTPHeaderField:@"Authorization"];
    if(body){[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];request.HTTPBody=[NSJSONSerialization dataWithJSONObject:body options:0 error:error];if(!request.HTTPBody)return nil;}
    NSData *data=[self _performDataRequest:request context:context error:error];
    id json=data&&data.length<=65536?[NSJSONSerialization JSONObjectWithData:data options:0 error:error]:nil;
    if(![json isKindOfClass:NSDictionary.class]){if(error&&!*error)*error=RBXCloudInputError(@"Cloud transfer returned invalid metadata. Update the server and retry.");return nil;}
    return json;
}
- (BOOL)_uploadSealed:(NSData *)sealed metadata:(NSDictionary *)metadata context:(RBXOperationContext *)context error:(NSError **)error {
    const NSUInteger partBytes=1024*1024;
    if(!sealed.length || sealed.length>200*partBytes){if(error)*error=RBXCloudInputError(@"Encrypted backup exceeds the 200 MiB limit.");return NO;}
    NSMutableArray *hashes=[NSMutableArray array];
    for(NSUInteger offset=0;offset<sealed.length;offset+=partBytes){
        if(!RBXCloudCheck(context,error))return NO;
        [hashes addObject:RBXCloudSHA256Hex([sealed subdataWithRange:NSMakeRange(offset,MIN(partBytes,sealed.length-offset))])];
    }
    NSMutableDictionary *body=[metadata mutableCopy];body[@"size"]=@(sealed.length);body[@"parts"]=hashes;
    NSDictionary *start=[self _transferJSON:@"/api/backups/transfer" body:body context:context error:error];
    NSString *identifier=RBXCloudString(start,@"uploadId");
    if(identifier.length!=32 || [identifier rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location!=NSNotFound || ![start[@"partBytes"] isKindOfClass:NSNumber.class] || [start[@"partBytes"] unsignedLongLongValue]!=partBytes){if(error&&!*error)*error=RBXCloudInputError(@"Cloud upload could not start. Update the server and retry.");return NO;}
    for(NSUInteger index=0,offset=0;offset<sealed.length;index++,offset+=partBytes){
        if(!RBXCloudCheck(context,error))return NO;
        NSString *path=[NSString stringWithFormat:@"/api/backups/transfer?id=%@&part=%lu",identifier,(unsigned long)index];
        NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:[self.serverURL stringByAppendingString:path]]];
        request.HTTPMethod=@"PUT";request.HTTPBody=[sealed subdataWithRange:NSMakeRange(offset,MIN(partBytes,sealed.length-offset))];
        [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@",self.deviceToken] forHTTPHeaderField:@"Authorization"];
        NSData *reply=[self _performDataRequest:request context:context error:error];
        id result=reply&&reply.length<=65536?[NSJSONSerialization JSONObjectWithData:reply options:0 error:error]:nil;
        if(![result isKindOfClass:NSDictionary.class] || ![result[@"ok"] isEqual:@YES]){if(error&&!*error)*error=RBXCloudInputError(@"A backup part was not acknowledged. No complete backup was published.");return NO;}
    }
    NSDictionary *done=[self _transferJSON:@"/api/backups/transfer" body:@{@"complete":identifier} context:context error:error];
    if(![done[@"backupId"] isEqual:identifier]){if(error&&!*error)*error=RBXCloudInputError(@"Backup publication was not confirmed. Refresh Cloud before retrying.");return NO;}
    return YES;
}
- (NSData *)_downloadParts:(NSDictionary *)manifest path:(NSString *)path context:(RBXOperationContext *)context error:(NSError **)error {
    const NSUInteger partBytes=1024*1024;
    NSNumber *length=manifest[@"size"];NSArray *parts=manifest[@"parts"];
    unsigned long long size=[length isKindOfClass:NSNumber.class]?length.unsignedLongLongValue:0;
    if(!size || size>200*partBytes || length.doubleValue!=(double)size || ![parts isKindOfClass:NSArray.class] || parts.count!=(size+partBytes-1)/partBytes){if(error)*error=RBXCloudInputError(@"Invalid backup part manifest.");return nil;}
    NSMutableData *sealed=[NSMutableData dataWithCapacity:(NSUInteger)size];
    for(NSUInteger index=0;index<parts.count;index++){
        if(!RBXCloudCheck(context,error))return nil;
        NSDictionary *part=[parts[index] isKindOfClass:NSDictionary.class]?parts[index]:nil;
        NSString *checksum=RBXCloudString(part,@"checksum");NSUInteger expected=MIN(partBytes,(NSUInteger)size-index*partBytes);
        if(![part[@"size"] isKindOfClass:NSNumber.class] || [part[@"size"] unsignedLongLongValue]!=expected || checksum.length!=64){if(error)*error=RBXCloudInputError(@"Invalid backup part size or checksum.");return nil;}
        NSString *endpoint=[path stringByAppendingFormat:@"&part=%lu",(unsigned long)index];
        NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:[self.serverURL stringByAppendingString:endpoint]]];
        [request setValue:[NSString stringWithFormat:@"Bearer %@",self.deviceToken] forHTTPHeaderField:@"Authorization"];
        NSData *bytes=[self _performDataRequest:request context:context error:error];
        if(bytes.length!=expected || ![RBXCloudSHA256Hex(bytes) isEqual:checksum]){if(error&&!*error)*error=RBXCloudInputError(@"Backup part is missing or damaged. Restore stopped before creating a container.");return nil;}
        [sealed appendData:bytes];
    }
    if(![RBXCloudSHA256Hex(sealed) isEqual:manifest[@"checksum"]]){if(error)*error=RBXCloudInputError(@"Complete backup checksum mismatch.");return nil;}
    return sealed;
}

// Private launcher bridge. Secrets and backup metadata travel through expiring
// Keychain records; durable/public IPC receipts contain only a generic result.
- (NSArray *)_vaultBackupsForApp:(NSString *)appType context:(RBXOperationContext *)context error:(NSError **)error {
    NSString *url = [self.serverURL stringByAppendingFormat:@"/api/backups?appType=%@",appType];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [request setValue:[NSString stringWithFormat:@"Bearer %@",self.deviceToken] forHTTPHeaderField:@"Authorization"];
    request.timeoutInterval = kCloudHTTPTimeout;
    NSData *data = [self _performDataRequest:request context:context error:error];
    id document = data && data.length <= 2 * 1024 * 1024 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
    NSArray *rows = [document isKindOfClass:NSDictionary.class] ? document[@"backups"] : nil;
    if (![rows isKindOfClass:NSArray.class] || rows.count > 1000) {
        if (error && !*error) *error = RBXCloudInputError(@"Cloud backup list is unavailable or too large."); return nil;
    }
    NSMutableArray *safe = [NSMutableArray array];
    for (id row in rows) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *owner = RBXAppDescriptorForType(row[@"appType"] ?: @"reddit");
        if (![owner[@"appType"] isEqual:appType]) continue;
        NSString *identifier = RBXCloudString(row,@"backupId") ?: RBXCloudString(row,@"id");
        if (!identifier.length || identifier.length > 128 || [identifier rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet.invertedSet].location != NSNotFound) continue;
        NSMutableDictionary *entry = [@{@"id":identifier,@"appType":appType} mutableCopy];
        for (NSString *key in @[@"name",@"containerId",@"createdAt",@"deviceName",@"transferScope",@"credentialPolicy"])
            if ([row[key] isKindOfClass:NSString.class] && [row[key] length] <= 256) entry[key] = row[key];
        if ([row[@"size"] isKindOfClass:NSNumber.class] && isfinite([row[@"size"] doubleValue]) && [row[@"size"] doubleValue] >= 0) entry[@"size"] = row[@"size"];
        [safe addObject:entry];
    }
    return safe;
}

- (BOOL)_handleVaultRequest:(NSDictionary *)request context:(RBXOperationContext *)context message:(NSString **)message {
    NSString *action = RBXCloudString(request,@"action"), *appType = RBXCloudString(request,@"appType");
    if (!RBXCloudMessageCheck(context,message) || !RBXAppDescriptorForType(appType)) return NO;
    if (!RBXLicenseGuard.sharedGuard.isUnlocked || !self.paired) {
        if (message) *message = @"Activate this phone on the existing cloud before using backups."; return NO;
    }
    NSError *error = nil;
    NSMutableDictionary *payload = [@{@"appType":appType,@"serverURL":self.serverURL,@"hasPassphrase":@(self.passphrase.length >= 16)} mutableCopy];
    if ([action isEqual:@"cloudVaultKey"]) {
        if (self.passphrase.length < 16) { if (message) *message = @"No encryption key is available yet."; return NO; }
        payload[@"passphrase"] = self.passphrase;
    } else if ([action isEqual:@"cloudVaultSetKey"]) {
        NSString *identifier = RBXCloudString(request,@"vaultInputId");
        NSDictionary *input = [RBXSecureConfig cloudVaultPayloadForIdentifier:identifier response:NO error:&error];
        NSString *phrase = RBXCloudString(input,@"passphrase");
        if (![input[@"appType"] isEqual:appType] || phrase.length < 16 || phrase.length > 256) {
            if (message) *message = @"Encryption key is missing, expired or invalid. Enter 16–256 characters."; return NO;
        }
        if (!RBXCloudMessageCheck(context,message)) return NO;
        NSMutableDictionary *settings = RBXCloudReadPlist(); settings[@"passphrase"] = phrase;
        BOOL saved = RBXCloudWritePlist(settings);
        [RBXSecureConfig clearCloudVaultPayloadForIdentifier:identifier response:NO];
        if (message) *message = saved ? @"Encryption key saved on this phone. Existing backups still need the key used to create them." : @"Key persistence could not be verified. Keep both keys and retry; do not discard the previous key.";
        return saved;
    } else if ([action isEqual:@"cloudVaultRestore"]) {
        NSString *identifier = RBXCloudString(request,@"backupId");
        if (!identifier.length) { if (message) *message = @"Select a backup first."; return NO; }
        return [self _importWithBackupId:identifier expectedAppType:appType context:context message:message];
    } else {
        NSArray *rows = [self _vaultBackupsForApp:appType context:context error:&error];
        if (!rows) { if (message) *message = error.localizedDescription ?: @"Cloud backup list unavailable."; return NO; }
        if ([action isEqual:@"cloudVaultDelete"]) {
            NSString *identifier = RBXCloudString(request,@"backupId");
            BOOL found = NO; for (NSDictionary *row in rows) if ([row[@"id"] isEqual:identifier]) found = YES;
            if (!found) { if (message) *message = @"This backup is unavailable in the selected app and license."; return NO; }
            NSMutableURLRequest *deletion = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[self.serverURL stringByAppendingFormat:@"/api/backups/%@",identifier]]];
            deletion.HTTPMethod = @"DELETE"; deletion.timeoutInterval = kCloudHTTPTimeout;
            [deletion setValue:[NSString stringWithFormat:@"Bearer %@",self.deviceToken] forHTTPHeaderField:@"Authorization"];
            BOOL ok = [self _performDataRequest:deletion context:context error:&error] != nil;
            if (message) *message = ok ? @"Cloud backup deleted. Local containers were kept." : (error.localizedDescription ?: @"Cloud deletion failed.");
            return ok;
        }
        if (![action isEqual:@"cloudVaultList"]) { if (message) *message = @"Unsupported cloud operation."; return NO; }
        payload[@"backups"] = rows;
    }
    if (!RBXCloudMessageCheck(context,message)) return NO;
    BOOL saved = [RBXSecureConfig saveCloudVaultPayload:payload identifier:context.requestID response:YES error:&error];
    if (message) *message = saved ? @"Private cloud details are ready." : (error.localizedDescription ?: @"Private cloud details could not be delivered.");
    return saved;
}

// Explicit records owned by main's serialized request controller.

- (void)handleQueuedAction:(NSDictionary *)request
                completion:(void (^)(BOOL, NSString *))done {
    BOOL owned = NO;
    RBXOperationContext *context = RBXCloudLegacyContext(&owned);
    [self handleQueuedAction:request context:context completion:done];
    if (owned) [context finishWhenQuiescent];
}

- (void)handleQueuedAction:(NSDictionary *)request context:(RBXOperationContext *)context
                completion:(void (^)(BOOL, NSString *))done {
    done = RBXCloudCompletion(context, done);
    NSDictionary *input = [request isKindOfClass:NSDictionary.class]
        ? [[NSDictionary alloc] initWithDictionary:request copyItems:YES] : nil;
    NSObject *completionLock = [NSObject new];
    __block BOOL completed = NO;
    void (^finish)(BOOL, NSString *) = ^(BOOL ok, NSString *message) {
        @synchronized (completionLock) {
            if (completed) return;
            completed = YES;
        }
        if (done) done(ok, message ?: (ok ? @"Cloud action finished." : @"Cloud action failed."));
    };
    RBXCloudDispatch(context, _queue, done, ^{
        NSString *action = RBXCloudString(input, @"action");
        if (!action.length) {
            finish(NO, @"Cloud request has no valid action.");
            return;
        }
        for (NSString *key in @[@"pairingCode", @"backupId", @"containerId"]) {
            id value = input[key];
            if (value && (![value isKindOfClass:NSString.class] || [value length] > 4096)) {
                finish(NO, [NSString stringWithFormat:@"Cloud request has an invalid %@ field.", key]);
                return;
            }
        }
        NSString *pairingCode = [RBXCloudString(input, @"pairingCode")
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *backupId = [RBXCloudString(input, @"backupId")
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *containerOverride = RBXCloudString(input, @"containerId");
        if ([@[@"cloudVaultList",@"cloudVaultKey",@"cloudVaultSetKey",@"cloudVaultRestore",@"cloudVaultDelete"] containsObject:action]) {
            NSString *message = nil;
            BOOL ok = [self _handleVaultRequest:input context:context message:&message];
            finish(ok,message);
        } else if ([action isEqualToString:@"pair"]) {
            if (!pairingCode.length) {
                finish(NO, @"Pairing requires a pairing code.");
                return;
            }
            [self pairWithCode:pairingCode context:context completion:finish];
        } else if ([action isEqualToString:@"export"]) {
            [self exportContainer:containerOverride ?: @"" context:context completion:finish];
        } else if ([action isEqualToString:@"importNewest"]) {
            [self importNewestBackupWithContext:context completion:finish];
        } else if ([action isEqualToString:@"importById"]) {
            if (!backupId.length) {
                finish(NO, @"Import requires a backup ID.");
                return;
            }
            [self importBackupWithId:backupId context:context completion:finish];
        } else if ([action isEqualToString:@"regeneratePassphrase"]) {
            [self _regeneratePassphraseWithContext:context completion:finish];
        } else {
            finish(NO, @"Unsupported cloud action.");
        }
    });
}

@end
