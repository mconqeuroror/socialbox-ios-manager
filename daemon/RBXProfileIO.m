#import "RBXProfileIO.h"
#import "RBXAppProfileIdentity.h"
#import "RBXDataSchema.h"
#import "RBXAppRegistry.h"
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

NSString * const RBXProfileIOErrorDomain = @"com.redditbox.profile-io";
static NSString * const RBXProfilesDirectory = @"/var/mobile/Library/Preferences/com.redditbox.profiles";

static NSError *RBXProfileError(RBXProfileIOErrorCode code, NSString *message, NSError *underlying) {
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: message} mutableCopy];
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:RBXProfileIOErrorDomain code:code userInfo:info];
}

static NSData *RBXReadProfileData(NSString *path, BOOL requireProfileDirectory, NSError **error) {
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath || !path.length) {
        if (error) *error = RBXProfileError(RBXProfileIORead, @"JSON file path must be an absolute path", nil);
        return nil;
    }
    int directory = AT_FDCWD;
    if (requireProfileDirectory) {
        directory = open(RBXProfilesDirectory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (directory < 0) {
            int saved = errno;
            if (error) *error = RBXProfileError(saved == ENOENT ? RBXProfileIOMissing : RBXProfileIORead,
                saved == ENOENT ? @"Profile directory is missing" : @"Profile directory cannot be opened safely",
                [NSError errorWithDomain:NSPOSIXErrorDomain code:saved userInfo:nil]);
            return nil;
        }
    }
    int fd = openat(directory, (requireProfileDirectory ? path.lastPathComponent : path).fileSystemRepresentation,
        O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    int openError = errno;
    if (directory != AT_FDCWD) close(directory);
    if (fd < 0) {
        int saved = openError;
        RBXProfileIOErrorCode code = saved == ENOENT ? RBXProfileIOMissing : RBXProfileIORead;
        NSString *message = [NSString stringWithFormat:@"%@ JSON file %@", code == RBXProfileIOMissing ? @"Missing" : @"Cannot read", path.lastPathComponent];
        if (error) *error = RBXProfileError(code, message, [NSError errorWithDomain:NSPOSIXErrorDomain code:saved userInfo:nil]);
        return nil;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0 || st.st_size > 32 * 1024 * 1024) {
        close(fd);
        if (error) *error = RBXProfileError(RBXProfileIORead, @"JSON file is not a readable regular file within the 32 MiB limit", nil);
        return nil;
    }
    NSMutableData *data = [NSMutableData data];
    unsigned char bytes[16384];
    for (;;) {
        ssize_t count = read(fd, bytes, sizeof(bytes));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 || data.length + (NSUInteger)MAX(count, 0) > 32 * 1024 * 1024) {
            int saved = count < 0 ? errno : EFBIG;
            close(fd);
            if (error) *error = RBXProfileError(RBXProfileIORead, @"Cannot read complete JSON file", [NSError errorWithDomain:NSPOSIXErrorDomain code:saved userInfo:nil]);
            return nil;
        }
        if (!count) break;
        [data appendBytes:bytes length:(NSUInteger)count];
    }
    close(fd);
    return data;
}

static NSDictionary *RBXDecodeProfileDictionary(NSData *data, NSError **error) {
    if (![data isKindOfClass:NSData.class]) {
        if (error) *error = RBXProfileError(RBXProfileIORead, @"JSON data is unavailable", nil);
        return nil;
    }
    if (!data.length) {
        if (error) *error = RBXProfileError(RBXProfileIOEmpty, @"JSON file is empty", nil);
        return nil;
    }
    NSError *parseError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:&parseError];
    if (!root) {
        if (error) *error = RBXProfileError(RBXProfileIOParse, @"JSON file is malformed", parseError);
        return nil;
    }
    if (![root isKindOfClass:NSDictionary.class]) {
        if (error) *error = RBXProfileError(RBXProfileIORoot, @"JSON root must be an object", nil);
        return nil;
    }
    return root;
}

static BOOL RBXCheckFields(NSDictionary *object, NSArray<NSString *> *keys, Class type, NSString *section, NSError **error) {
    for (NSString *key in keys) {
        id value = object[key];
        if (value && ![value isKindOfClass:type]) {
            NSString *path = section.length ? [NSString stringWithFormat:@"%@.%@", section, key] : key;
            if (error) *error = RBXProfileError(RBXProfileIOSection, [NSString stringWithFormat:@"Profile field %@ has an invalid type", path], nil);
            return NO;
        }
    }
    return YES;
}

static NSDictionary *RBXCheckProfile(NSDictionary *profile, NSString *containerId, NSError **error) {
    if (!RBXSchemaValidate(profile, RBXDataProfile, error)) return nil;
    if (!RBXAppDescriptorForProfile(profile)) {
        if (error) *error = RBXProfileError(RBXProfileIOSection, @"Profile appType is unknown or invalid", nil);
        return nil;
    }
    if (![profile[@"containerId"] isKindOfClass:NSString.class] || ![profile[@"containerId"] isEqualToString:containerId]) {
        if (error) *error = RBXProfileError(RBXProfileIOIdentityMismatch, @"Profile containerId does not match its filename", nil);
        return nil;
    }
    NSArray *sections = @[@"device", @"serials", @"ids", @"timing", @"security", @"proxy", @"reddit", @"facebook", @"validation", @"mgOverrides", @"app", @"identityCustomization"];
    if (!RBXCheckFields(profile, sections, NSDictionary.class, @"", error) ||
        !RBXCheckFields(profile, @[@"identityPolicy", @"installationTransaction"], NSString.class, @"", error) ||
        !RBXCheckFields(profile, @[@"profileVersion"], NSNumber.class, @"", error)) return nil;
    NSDictionary *stringFields = @{
        @"device": @[@"productType", @"marketingName", @"modelNumber", @"hwModelStr", @"regulatoryModel", @"iosVersion", @"buildVersion", @"darwinRelease", @"ramBytes", @"gpuName", @"deviceName", @"deviceClass", @"regionCode", @"simStatus", @"language", @"locale", @"timezone"],
        @"serials": @[@"serialNumber", @"udid", @"imei1", @"imei2", @"meid", @"iccid", @"wifiMac", @"btMac", @"platformUUID", @"mlb"],
        @"ids": @[@"posture", @"idfa", @"idfv"],
        @"timing": @[@"bootTimeOffsetSeconds", @"syntheticBootEpoch", @"batteryOffsetPercent"],
        @"security": @[@"appAttest", @"deviceCheck", @"localNetworking", @"sensorAccess", @"networkMetadata", @"thirdPartyNetwork", @"strictTiming", @"systemClipboard", @"keychainSync"],
        @"proxy": @[@"url", @"country", @"proxyId", @"rotationAuthHeader", @"rotationAuthValue", @"rotationURL"],
        @"reddit": @[@"installId", @"installTimestampMs", @"deviceName", @"externalInstallationId", @"screenWidth", @"screenHeight", @"fontSize", @"userAgent"],
        @"validation": @[@"proxyCountry", @"observedProxyCountry", @"exitIP", @"message"],
        @"app": @[@"architecture", @"sourceBundleIdentifier", @"bundleIdentifier", @"bundlePath", @"keychainAccessGroup", @"cloneState", @"sourceVersion", @"sourceBuild", @"ipaExportPath"],
        @"identityCustomization": @[@"mode"],
    };
    for (NSString *section in stringFields) {
        if (!RBXCheckFields(profile[section], stringFields[section], NSString.class, section, error)) return nil;
    }
    NSString *cloneIdentityError = RBXAppProfileIdentityBlockReason(RBXAppDescriptorForProfile(profile), profile, containerId);
    if (cloneIdentityError) {
        if (error) *error = RBXProfileError(RBXProfileIOIdentityMismatch, cloneIdentityError, nil);
        return nil;
    }
    NSDictionary *numberFields = @{@"serials": @[@"uniqueChipId"], @"validation": @[@"geoConsistent", @"proxyHealthy", @"checkedAt"], @"app": @[@"appAttestEntitled"], @"identityCustomization": @[@"updatedAt"]};
    for (NSString *section in numberFields) {
        if (!RBXCheckFields(profile[section], numberFields[section], NSNumber.class, section, error)) return nil;
    }
    NSDictionary *device = profile[@"device"];
    if (!RBXCheckFields(device, @[@"screen", @"carrier", @"location"], NSDictionary.class, @"device", error) ||
        !RBXCheckFields(device[@"screen"], @[@"w", @"h", @"fps", @"scale"], NSString.class, @"device.screen", error) ||
        !RBXCheckFields(device[@"carrier"], @[@"name", @"mcc", @"mnc", @"isoCountryCode"], NSString.class, @"device.carrier", error) ||
        !RBXCheckFields(device[@"location"], @[@"city", @"lat", @"lon"], NSString.class, @"device.location", error)) return nil;
    return profile;
}

@implementation RBXProfileIO
+ (BOOL)isSafeContainerIdentifier:(id)value {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 180) return NO;
    NSMutableCharacterSet *allowed = [NSCharacterSet.alphanumericCharacterSet mutableCopy];
    [allowed addCharactersInString:@"-_"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}
+ (NSDictionary *)readProfileOwnershipForContainer:(NSString *)containerId error:(NSError **)error {
    if (![self isSafeContainerIdentifier:containerId]) {
        if (error) *error = RBXProfileError(RBXProfileIOInvalidIdentifier, @"Profile identifier is unsafe", nil);
        return nil;
    }
    NSString *path = [RBXProfilesDirectory stringByAppendingPathComponent:[containerId stringByAppendingPathExtension:@"json"]];
    NSData *data = RBXReadProfileData(path, YES, error);
    NSDictionary *raw = data ? RBXDecodeProfileDictionary(data, error) : nil;
    return raw ? (raw[@"appType"] ? @{@"appType":raw[@"appType"]} : @{}) : nil;
}
+ (NSDictionary *)loadProfileForContainer:(NSString *)containerId error:(NSError **)error {
    if (![self isSafeContainerIdentifier:containerId]) {
        if (error) *error = RBXProfileError(RBXProfileIOInvalidIdentifier, @"Profile identifier is unsafe", nil);
        return nil;
    }
    NSString *path = [RBXProfilesDirectory stringByAppendingPathComponent:[containerId stringByAppendingPathExtension:@"json"]];
    NSData *data = RBXReadProfileData(path, YES, error);
    return data ? [self profileDictionaryFromData:data containerId:containerId error:error] : nil;
}
+ (NSDictionary *)profileDictionaryFromData:(NSData *)data containerId:(NSString *)containerId error:(NSError **)error {
    if (![self isSafeContainerIdentifier:containerId]) {
        if (error) *error = RBXProfileError(RBXProfileIOInvalidIdentifier, @"Profile identifier is unsafe", nil);
        return nil;
    }
    NSDictionary *profile = RBXDecodeProfileDictionary(data, error);
    return profile ? RBXCheckProfile(profile, containerId, error) : nil;
}
+ (NSDictionary *)readJSONDictionaryAtPath:(NSString *)path error:(NSError **)error {
    NSData *data = RBXReadProfileData(path, NO, error);
    NSDictionary *document = data ? RBXDecodeProfileDictionary(data, error) : nil;
    if ([path.lastPathComponent isEqual:@"com.redditbox.store.json"] &&
        !RBXSchemaValidate(document, RBXDataStore, error)) return nil;
    return document;
}
+ (BOOL)writeProfile:(NSDictionary *)profile containerId:(NSString *)containerId toPath:(NSString *)path error:(NSError **)error {
    if (![self isSafeContainerIdentifier:containerId] || !path.isAbsolutePath ||
        !RBXCheckProfile(profile, containerId, error)) return NO;
    BOOL missing = NO;
    NSData *existing = RBXSchemaReadBytes(path, &missing, error);
    if (!missing && (!existing || ![self profileDictionaryFromData:existing containerId:containerId error:error])) return NO;
    return RBXSchemaWriteJSONCompared(profile, path, RBXDataProfile, existing, missing, error);
}
@end
