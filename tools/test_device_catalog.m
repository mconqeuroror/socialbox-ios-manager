// Actual catalog/JSON loader/generator/validator tests using temporary fixtures.
// No production path is read or written; no Security or iOS service is called.
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>
#import "RBXProfileIO.h"
#import "RBXProfileGenerator.h"
#import "RBXConsistencyValidator.h"
#import "RBXMGOverrides.h"
#define RBX_CATALOG_TESTING 1
#include "../daemon/RBXDeviceCatalog.m"

static NSString *TestRoot, *Rootless, *Rootful;
static NSDictionary *Fixture;

static void Check(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"CatalogTestFailure" reason:message userInfo:nil];
}

static NSData *JSON(id object) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    Check(data != nil, error.localizedDescription ?: @"fixture JSON encoding");
    return data;
}

static void Write(NSString *path, NSData *bytes) {
    NSError *error = nil;
    Check([bytes writeToFile:path options:NSDataWritingAtomic error:&error], error.localizedDescription ?: @"write fixture");
}

static void Reset(void) {
    [NSFileManager.defaultManager removeItemAtPath:Rootless error:nil];
    [NSFileManager.defaultManager removeItemAtPath:Rootful error:nil];
    RBXCatalogTestPaths = @[Rootless, Rootful];
    Write(Rootful, JSON(Fixture));
}

static void ExpectCatalogFailure(NSString *field) {
    NSError *error = nil;
    Check(![RBXDeviceCatalog validateAvailability:&error] && error != nil, @"invalid catalog must report an error");
    Check([error.domain isEqual:@"com.redditbox.catalog"] &&
        [error.localizedDescription containsString:field], @"catalog error identifies the broken field");
    Check([RBXDeviceCatalog allModels].count == 0 && [RBXDeviceCatalog appleOUIs].count == 0,
        @"invalid catalog must not expose partially valid pools");
    NSError *generationError = nil;
    Check([RBXProfileGenerator generateProfileForContainerId:@"alpha" proxyCountry:@"US"
        existingProfiles:@[] error:&generationError] == nil && [generationError.domain isEqual:error.domain],
        @"generator propagates catalog failure before indexing");
    NSError *validationError = nil;
    Check([RBXConsistencyValidator validatedProfile:@{} error:&validationError] == nil &&
        [validationError.domain isEqual:error.domain], @"validator propagates catalog failure");
}

static void TestFileFailures(void) {
    Reset();
    NSError *error = nil;
    Check([RBXDeviceCatalog validateAvailability:&error], @"missing rootless falls through to valid rootful catalog");
    Check([RBXDeviceCatalog validateCountry:@"US" error:&error], @"shipped US country tuple is available");
    [NSFileManager.defaultManager removeItemAtPath:Rootful error:nil];
    Check(![RBXDeviceCatalog validateAvailability:&error] && error.code == RBXProfileIOMissing,
        @"both missing paths preserve missing-file error");
    for (NSDictionary *fixture in @[
        @{@"bytes": [NSData data], @"code": @(RBXProfileIOEmpty)},
        @{@"bytes": [@"{" dataUsingEncoding:NSUTF8StringEncoding], @"code": @(RBXProfileIOParse)},
        @{@"bytes": JSON(@[]), @"code": @(RBXProfileIORoot)}]) {
        Reset(); Write(Rootless, fixture[@"bytes"]); error = nil;
        Check(![RBXDeviceCatalog validateAvailability:&error] &&
            [error.domain isEqual:RBXProfileIOErrorDomain] && error.code == [fixture[@"code"] integerValue],
            @"existing broken rootless catalog must not use a valid rootful replacement");
    }
    Reset(); Write(Rootless, [@"null" dataUsingEncoding:NSUTF8StringEncoding]); error = nil;
    Check(![RBXDeviceCatalog validateAvailability:&error] && [error.domain isEqual:RBXProfileIOErrorDomain],
        @"JSON null root cannot fall through");
    Reset();
    Check([NSFileManager.defaultManager createDirectoryAtPath:Rootless withIntermediateDirectories:NO
        attributes:nil error:&error], @"non-file fixture");
    Check(![RBXDeviceCatalog validateAvailability:&error] && error.code == RBXProfileIORead,
        @"non-file read error cannot fall through");
    if (geteuid() != 0) {
        Reset(); Write(Rootless, JSON(Fixture));
        Check(chmod(Rootless.fileSystemRepresentation, 0000) == 0, @"make unreadable fixture");
        BOOL available = [RBXDeviceCatalog validateAvailability:&error];
        chmod(Rootless.fileSystemRepresentation, 0600);
        Check(!available && error.code == RBXProfileIORead, @"permission failure cannot fall through");
    }
    puts("PASS catalog missing-only fallback and explicit empty/parse/root/read failures");
}

static void TestSchema(void) {
    for (NSString *section in Fixture) {
        for (id invalid in @[[NSNull null], @[], @"bad"]) {
            Reset(); NSMutableDictionary *broken = [Fixture mutableCopy]; broken[section] = invalid;
            Write(Rootless, JSON(broken)); ExpectCatalogFailure(section);
        }
    }
    NSArray *changes = @[
        @{@"path": @[@"models", @"iPhone14,2"], @"value": [NSNull null]},
        @{@"path": @[@"models", @"iPhone14,2", @"chip"], @"value": @[]},
        @{@"path": @[@"models", @"iPhone14,2", @"screen"], @"value": @[]},
        @{@"path": @[@"models", @"iPhone14,2", @"screen", @"w"], @"value": @1170},
        @{@"path": @[@"models", @"iPhone14,2", @"iosVersions"], @"value": @[]},
        @{@"path": @[@"models", @"iPhone14,2", @"iosVersions"], @"value": @[[NSNull null]]},
        @{@"path": @[@"models", @"iPhone14,2", @"iosVersions"], @"value": @[@"99.1"]},
        @{@"path": @[@"carriers", @"US"], @"value": @[[NSNull null]]},
        @{@"path": @[@"carriers", @"US"], @"value": @[@{@"name": @"Test", @"mcc": @310, @"mnc": @"01"}]},
        @{@"path": @[@"countryCities", @"US"], @"value": @[@[]]},
        @{@"path": @[@"countryCities", @"US"], @"value": @[@{@"city": @"Test", @"lat": @"nonsense", @"lon": @"0"}]},
        @{@"path": @[@"countryLocales", @"US"], @"value": [NSNull null]},
        @{@"path": @[@"models", @"iPhone18,1", @"minimumIOS"], @"value": @"27.0"},
        @{@"path": @[@"models", @"iPhone18,1", @"tac"], @"value": @"12345678"},
        @{@"path": @[@"appleOUIs"], @"value": @{}}
    ];
    for (NSDictionary *change in changes) {
        Reset();
        NSMutableDictionary *broken = [NSJSONSerialization JSONObjectWithData:JSON(Fixture)
            options:NSJSONReadingMutableContainers error:nil];
        NSArray *path = change[@"path"];
        NSMutableDictionary *parent = broken;
        for (NSUInteger index = 0; index + 1 < path.count; index++) parent = parent[path[index]];
        parent[path.lastObject] = change[@"value"];
        Write(Rootless, JSON(broken)); ExpectCatalogFailure(path.firstObject);
    }
    puts("PASS complete typed schema rejects malformed model, screen, version, carrier, city and map entries");
}

static void TestConsumers(void) {
    Reset(); NSError *error = nil;
    Check([RBXDeviceCatalog modelForProductType:(id)NSNull.null] == nil &&
        [RBXDeviceCatalog buildForIOS:(id)@[]] == nil &&
        [RBXDeviceCatalog carriersForCountry:(id)NSNull.null].count == 0 &&
        ![RBXDeviceCatalog isAppleMAC:(id)@{}], @"typed accessors safely reject wrong input types");
    Check(![RBXDeviceCatalog validateCountry:@"ZZ" error:&error], @"unknown country has no fallback identity");
    Check([RBXProfileGenerator generateProfileForContainerId:@"alpha" proxyCountry:@"ZZ"
        existingProfiles:@[] error:&error] == nil, @"generator refuses unknown country");
    Check([RBXProfileGenerator generateProfileForContainerId:@"alpha" proxyCountry:@"US"
        existingProfiles:@[@{@"device": NSNull.null}] error:&error] == nil,
        @"generator refuses malformed existing identity instead of ignoring diversity evidence");
    NSDictionary *profile = [RBXProfileGenerator generateProfileForContainerId:@"alpha" proxyCountry:@"US"
        existingProfiles:@[] error:&error];
    Check(profile != nil, error.localizedDescription ?: @"valid catalog can generate a profile");
    NSDictionary *decoded = [RBXProfileIO profileDictionaryFromData:JSON(profile)
        containerId:@"alpha" error:&error];
    Check([decoded isEqualToDictionary:profile],
        error.localizedDescription ?: @"shared loader accepts the serialized generated profile without altering its fields");
    Check([RBXConsistencyValidator validatedProfile:profile error:&error] != nil,
        error.localizedDescription ?: @"generated tuple is consistent");
    for (id policy in @[@"unchanged", @"local-only", @"enabled", @YES, @{}, NSNull.null]) {
        NSMutableDictionary *candidate = [NSJSONSerialization JSONObjectWithData:JSON(profile)
            options:NSJSONReadingMutableContainers error:nil];
        candidate[@"security"][@"keychainSync"] = policy;
        BOOL valid = [policy isEqual:@"unchanged"] || [policy isEqual:@"local-only"];
        Check(([RBXConsistencyValidator validatedProfile:candidate error:&error] != nil) == valid,
            @"OS-011 actual profile validator accepts only documented optional sync policies");
    }
    for (NSString *section in @[@"device", @"serials", @"reddit", @"validation"]) {
        NSMutableDictionary *malformed = [profile mutableCopy];
        malformed[section] = NSNull.null;
        Check([RBXConsistencyValidator validatedProfile:malformed error:&error] == nil,
            @"direct validator refuses malformed sections without nested-selector exceptions");
        Check([RBXConsistencyValidator warningsForProfile:malformed] != nil,
            @"warning traversal is safe for malformed sections");
    }
    Check([RBXProfileGenerator autofixProfile:(id)NSNull.null proxyCountry:@"US"] == nil,
        @"autofix refuses malformed profile root");
    for (NSDictionary *selection in @[
        @{@"product":@"iPhone18,1", @"os":@"26.6.2", @"valid":@YES},
        @{@"product":@"iPhone17,1", @"os":@"18.6.2", @"valid":@YES},
        @{@"product":@"iPhone18,1", @"os":@"17.5.1", @"valid":@NO},
        @{@"product":@"iPhone17,5", @"os":@"17.5.1", @"valid":@NO},
        @{@"product":@"iPhone99,1", @"os":@"26.6.2", @"valid":@NO},
        @{@"product":NSNull.null, @"os":@"26.6.2", @"valid":@NO}]) {
        error = nil;
        NSDictionary *selected = [RBXProfileGenerator generateProfileForContainerId:@"selection-fixture" proxyCountry:@"US"
            existingProfiles:@[] productType:selection[@"product"] iosVersion:selection[@"os"] error:&error];
        Check((selected != nil) == [selection[@"valid"] boolValue], @"explicit selection must not silently choose another tuple");
        if (selected) {
            Check([selected[@"device"][@"productType"] isEqual:selection[@"product"]] &&
                [selected[@"device"][@"iosVersion"] isEqual:selection[@"os"]], @"Random fill preserves selected model and OS");
            Check([selected[@"serials"][@"imei1"] isEqual:@""] && [selected[@"device"][@"modelNumber"] isEqual:@""], @"unverified manufacturer values are omitted");
            NSMutableDictionary *stale = [selected mutableCopy];
            stale[@"mgOverrides"] = @{@"InternationalMobileEquipmentIdentity":@"old-value", @"ModelNumber":@"old-model"};
            NSDictionary *overrides = RBXBuildMGOverrides(stale);
            Check([overrides[@"InternationalMobileEquipmentIdentity"] isEqual:@""] && [overrides[@"ModelNumber"] isEqual:@""], @"unavailable values override stale MG values and stay explicit");
        } else Check(error != nil, @"invalid selection explains its failure");
    }
    puts("PASS actual generator/validator, selected draft tuple and explicit unavailable identifiers");
}

static void TestAppScopedGeneration(void) {
    Reset(); NSError *error = nil;
    NSDictionary *reddit = [RBXProfileGenerator generateProfileForContainerId:@"reddit-owner" proxyCountry:@"US" existingProfiles:@[] error:&error];
    Check(reddit && !reddit[@"appType"], @"legacy generator retains untyped Reddit document shape");
    NSDictionary *explicitReddit = [RBXProfileGenerator generateProfileForContainerId:@"typed-reddit" appType:@"reddit" proxyCountry:@"US" existingProfiles:@[reddit] error:&error];
    Check(explicitReddit && !explicitReddit[@"appType"], @"explicit Reddit generator keeps legacy shape");
    NSMutableDictionary *unknownOwner = [reddit mutableCopy]; unknownOwner[@"appType"] = @"unknown";
    Check(![RBXProfileGenerator generateProfileForContainerId:@"unknown-existing" appType:@"facebook" proxyCountry:@"US" existingProfiles:@[unknownOwner] error:&error], @"malformed existing ownership is not ignored during diversity checks");
    NSMutableArray *existing = [@[reddit,explicitReddit] mutableCopy];
    NSMutableSet *timestamps = [NSMutableSet set];
    for (NSUInteger index = 0; index < 8; index++) {
        NSString *identifier = [NSString stringWithFormat:@"facebook-%lu", (unsigned long)index];
        NSDictionary *facebook = [RBXProfileGenerator generateProfileForContainerId:identifier appType:@"facebook" proxyCountry:@"US"
            existingProfiles:existing productType:@"iPhone18,1" iosVersion:@"26.6.2" error:&error];
        Check(facebook && [facebook[@"appType"] isEqual:@"facebook"], @"pure FB draft is typed even while runtime admission remains closed");
        Check([facebook[@"device"][@"productType"] isEqual:@"iPhone18,1"] && [facebook[@"device"][@"iosVersion"] isEqual:@"26.6.2"], @"FB selected model/OS use the shared catalog");
        Check([facebook[@"security"][@"appAttest"] isEqual:@"blocked"] && [facebook[@"security"][@"deviceCheck"] isEqual:@"blocked"], @"FB attestation/integrity defaults remain blocked");
        Check(!facebook[@"facebook"] && [facebook[@"reddit"] isKindOfClass:NSDictionary.class], @"no guessed FB identifier schema: legacy fields remain compatibility only");
        NSDictionary *decoded = [RBXProfileIO profileDictionaryFromData:JSON(facebook) containerId:identifier error:&error];
        Check([decoded isEqual:facebook] && [RBXConsistencyValidator validatedProfile:facebook error:&error], @"actual loader and validator preserve FB ownership");
        NSDictionary *fixed = [RBXProfileGenerator autofixProfile:facebook proxyCountry:@"US"];
        Check([fixed[@"appType"] isEqual:@"facebook"], @"region repair never changes app ownership");
        for (NSDictionary *other in existing) {
            Check(![other[@"serials"][@"udid"] isEqual:facebook[@"serials"][@"udid"]] &&
                ![other[@"ids"][@"idfv"] isEqual:facebook[@"ids"][@"idfv"]], @"shared generated identities remain distinct across apps");
        }
        double age = NSDate.date.timeIntervalSince1970 - [facebook[@"reddit"][@"installTimestampMs"] doubleValue] / 1000.0;
        Check(age >= 7 * 86400 && age <= 181 * 86400, @"legacy installation clock is staggered; no FB persistence coverage is claimed");
        [timestamps addObject:facebook[@"reddit"][@"installTimestampMs"]];
        [existing addObject:facebook];
    }
    Check(timestamps.count > 1, @"batch draft generation retains timestamp staggering");
    for (id appType in @[@"unknown", @"", NSNull.null]) {
        error = nil;
        Check(![RBXProfileGenerator generateProfileForContainerId:@"invalid-app" appType:appType proxyCountry:@"US" existingProfiles:@[] error:&error] && error.code == 13, @"unknown/malformed explicit app fails before generation");
    }
    error = nil;
    Check(![RBXProfileGenerator generateProfileForContainerId:@"invalid-app" appType:nil proxyCountry:@"US" existingProfiles:@[] error:&error] && error.code == 13, @"explicit app overload cannot silently default nil to Reddit");
    puts("PASS actual app-scoped generator, schema/ownership preservation, blocked integrity defaults and staggered timestamps");
}

static void TestModernModelTuples(void) {
    Reset();
    Check([RBXDeviceCatalog modelForProductType:@"iPhone18,1"] != nil, @"iPhone 17 Pro must be selectable");
    Check([[RBXDeviceCatalog buildForIOS:@"26.6.2"] isEqual:@"23G90"], @"current stable iOS build must be selectable");
    NSUInteger count = 0;
    for (NSString *product in Fixture[@"models"]) {
        NSDictionary *model = Fixture[@"models"][product];
        for (NSString *version in model[@"iosVersions"]) {
            NSMutableDictionary *onlyModel = [model mutableCopy]; onlyModel[@"iosVersions"] = @[version];
            NSMutableDictionary *onlyCatalog = [Fixture mutableCopy]; onlyCatalog[@"models"] = @{product:onlyModel};
            Write(Rootless, JSON(onlyCatalog));
            NSError *error = nil;
            NSDictionary *profile = [RBXProfileGenerator generateProfileForContainerId:@"modern-fixture"
                proxyCountry:@"US" existingProfiles:@[] error:&error];
            Check(profile != nil, error.localizedDescription ?: @"every model / OS tuple generates");
            Check([profile[@"device"][@"productType"] isEqual:product] && [profile[@"device"][@"iosVersion"] isEqual:version], @"selected tuple is retained");
            Check([RBXConsistencyValidator validatedProfile:profile error:&error] != nil, error.localizedDescription ?: @"every tuple validates");
            NSDictionary *city = nil;
            for (NSDictionary *entry in [RBXDeviceCatalog citiesForCountry:@"US"])
                if ([entry[@"city"] isEqual:profile[@"device"][@"location"][@"city"]]) city = entry;
            Check([city[@"timezone"] isEqual:profile[@"device"][@"timezone"]], @"generated city and timezone must agree");
            count++;
        }
    }
    Reset();
    printf("PASS %lu shipped model / OS tuples generate and validate\n", (unsigned long)count);
}

static void TestProfileLoader(void) {
    NSError *error = nil;
    for (id identifier in @[@"../alpha", @"/alpha", @"alpha.json", @"", NSNull.null, @[]])
        Check(![RBXProfileIO isSafeContainerIdentifier:identifier], @"unsafe identifier is rejected before constructing a path");
    Check([RBXProfileIO profileDictionaryFromData:nil containerId:@"alpha" error:&error] == nil && error != nil,
        @"nil profile bytes are an explicit error, never a JSON exception");
    for (id value in @[@[], @{@"containerId": @"alpha", @"device": NSNull.null},
        @{@"containerId": @"alpha", @"serials": @[]}, @{@"containerId": @"other"}]) {
        error = nil;
        Check([RBXProfileIO profileDictionaryFromData:JSON(value) containerId:@"alpha" error:&error] == nil && error != nil,
            @"profile root/section/identity mismatch is rejected");
    }
    Check([RBXProfileIO profileDictionaryFromData:JSON(@{@"containerId": @"alpha", @"device": @{}})
        containerId:@"alpha" error:&error] != nil, @"well-typed partial profile is readable for later semantic validation");
    puts("PASS actual profile decoder handles nil, wrong roots/sections and unsafe identifiers");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int result = 0;
        @try {
            Check(argc == 2, @"provide shipped catalog fixture path");
            NSError *error = nil;
            Fixture = [RBXProfileIO readJSONDictionaryAtPath:[NSString stringWithUTF8String:argv[1]] error:&error];
            Check(Fixture != nil, error.localizedDescription ?: @"load shipped fixture");
            TestRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [@"rbx-catalog-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
            Check([NSFileManager.defaultManager createDirectoryAtPath:TestRoot withIntermediateDirectories:NO
                attributes:@{NSFilePosixPermissions: @0700} error:&error], @"create isolated temporary root");
            Rootless = [TestRoot stringByAppendingPathComponent:@"rootless.json"];
            Rootful = [TestRoot stringByAppendingPathComponent:@"rootful.json"];
            TestModernModelTuples(); TestFileFailures(); TestSchema(); TestConsumers(); TestAppScopedGeneration(); TestProfileLoader();
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL: %s\n", exception.reason.UTF8String); result = 1;
        } @finally {
            if (TestRoot) [NSFileManager.defaultManager removeItemAtPath:TestRoot error:nil];
        }
        return result;
    }
}
