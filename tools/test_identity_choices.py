#!/usr/bin/env python3
"""Execute shipped identity candidate methods with real catalog/generator/validator.

Only profile loading and sibling inventory use in-memory fixtures. No iOS service,
clone installation, network request or production profile is touched.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
registry = (ROOT / "daemon/RBXContainerRegistry.m").read_text()


def extract(signature):
    start = registry.index(signature)
    return registry[start:registry.index("\n}\n", start) + 3]


fixture = r'''
#import <Foundation/Foundation.h>
#import "RBXProfileGenerator.h"
#import "RBXConsistencyValidator.h"
#import "RBXProfileIO.h"
#import "RBXAppRegistry.h"
#import "RBXMGOverrides.h"
#define RBX_CATALOG_TESTING 1
#include "RBXDeviceCatalog.m"
static NSUInteger checks, failures, tuples;
static void Check(BOOL ok, NSString *message) {
    checks++; if (!ok) { failures++; fprintf(stderr,"FAIL: %s\n",message.UTF8String); }
}
static NSError *RBXDeletionError(NSString *message) {
    return [NSError errorWithDomain:@"fixture" code:400 userInfo:@{NSLocalizedDescriptionKey:message}];
}
__VALUE__
@interface ChoiceRegistry : NSObject
@property(nonatomic,copy) NSDictionary *original;
@property(nonatomic,copy) NSArray *siblings;
@end
@implementation ChoiceRegistry
- (NSDictionary *)_load:(NSString *)identifier error:(NSError **)error { return self.original; }
- (NSArray *)_otherProfilesExcluding:(NSString *)identifier error:(NSError **)error { return self.siblings ?: @[]; }
__METHODS__
@end
static NSMutableDictionary *Choices(NSDictionary *profile) {
    NSDictionary *d=profile[@"device"], *c=d[@"carrier"];
    return [@{@"mode":@"manual", @"country":d[@"regionCode"],
        @"productType":d[@"productType"], @"iosVersion":d[@"iosVersion"],
        @"locale":d[@"locale"], @"timezone":d[@"timezone"], @"city":d[@"location"][@"city"],
        @"carrierCode":[NSString stringWithFormat:@"%@-%@",c[@"mcc"],c[@"mnc"]],
        @"idfaPosture":profile[@"ids"][@"posture"],
        @"batteryOffsetPercent":profile[@"timing"][@"batteryOffsetPercent"]} mutableCopy];
}
int main(int argc, char **argv) { @autoreleasepool {
    RBXCatalogTestPaths = @[[NSString stringWithUTF8String:argv[1]]];
    ChoiceRegistry *registry = [ChoiceRegistry new];
    for (NSString *app in @[@"reddit",@"facebook"]) {
        for (NSString *product in [RBXDeviceCatalog allModels]) {
            NSDictionary *model=[RBXDeviceCatalog modelForProductType:product];
            NSDictionary *original=[RBXProfileGenerator generateProfileForContainerId:@"choice-fixture"
                appType:app proxyCountry:@"US" existingProfiles:@[] productType:product
                iosVersion:[model[@"iosVersions"] firstObject] error:nil];
            Check(original!=nil,@"catalog model generates a source draft");
            if (!original) continue;
            registry.original=original;
            for (NSString *version in model[@"iosVersions"]) {
                NSMutableDictionary *choice=Choices(original); choice[@"iosVersion"]=version;
                NSError *error=nil;
                NSDictionary *edited=[registry _identityCandidateForContainer:@"choice-fixture" choices:choice error:&error];
                Check(edited!=nil,[NSString stringWithFormat:@"%@ %@ %@: %@",app,product,version,error.localizedDescription]);
                if (!edited) continue;
                tuples++;
                Check([edited[@"device"][@"iosVersion"] isEqual:version] &&
                    [edited[@"device"][@"buildVersion"] isEqual:[RBXDeviceCatalog buildForIOS:version]] &&
                    [edited[@"device"][@"darwinRelease"] isEqual:[RBXDeviceCatalog darwinForIOS:version]],@"OS tuple follows selection");
                Check([edited[@"serials"] isEqual:original[@"serials"]] &&
                    [edited[@"ids"] isEqual:original[@"ids"]],@"iOS-only edits preserve stable identifiers");
                Check([edited[@"device"][@"location"] isEqual:original[@"device"][@"location"]],@"iOS-only edits preserve the unchanged city coordinates");
                Check([RBXAppDescriptorForProfile(edited)[@"appType"] isEqual:app],@"editing never changes app ownership");
                NSData *data=[NSJSONSerialization dataWithJSONObject:edited options:0 error:nil];
                Check([[RBXProfileIO profileDictionaryFromData:data containerId:@"choice-fixture" error:nil] isEqual:edited],@"edited draft survives production profile decoding");
            }
        }
    }
    NSMutableDictionary *original=[[RBXProfileGenerator generateProfileForContainerId:@"choice-fixture"
        proxyCountry:@"US" existingProfiles:@[] productType:@"iPhone18,1" iosVersion:@"26.6.2" error:nil] mutableCopy];
    original[@"role"]=@"warmup"; original[@"notes"]=@"operator note";
    original[@"metadataRevision"]=@42; original[@"metadataDirty"]=@YES;
    original[@"futureOperatorSetting"]=@{@"preserve":@YES};
    NSMutableDictionary *security=[original[@"security"] mutableCopy];
    security[@"keychainSync"]=@"local-only"; security[@"systemClipboard"]=@"enabled";
    original[@"security"]=security; registry.original=original;
    NSMutableDictionary *random=[Choices(original) mutableCopy]; random[@"mode"]=@"random";
    random[@"security"]=@{@"systemClipboard":@NO};
    NSDictionary *generated=[registry _identityCandidateForContainer:@"choice-fixture" choices:random error:nil];
    Check(generated!=nil,@"random identity candidate exists");
    for (NSString *key in @[@"role",@"notes",@"metadataRevision",@"metadataDirty",@"futureOperatorSetting"])
        Check([generated[key] isEqual:original[key]], [@"random identity preserves operator field " stringByAppendingString:key]);
    Check([generated[@"security"][@"keychainSync"] isEqual:@"local-only"],@"random identity preserves non-editor security policy");
    Check([generated[@"security"][@"systemClipboard"] isEqual:@"blocked"],@"explicit policy edit still applies");
    Check(![generated[@"ids"][@"idfv"] isEqual:original[@"ids"][@"idfv"]],@"random identity generates fresh identifiers");
    NSMutableDictionary *bad=Choices(original); bad[@"iosVersion"]=@"99.0";
    Check(![registry _identityCandidateForContainer:@"choice-fixture" choices:bad error:nil],@"unknown OS fails closed");
    bad=Choices(original); bad[@"appType"]=@"facebook";
    Check(![registry _identityCandidateForContainer:@"choice-fixture" choices:bad error:nil],@"foreign app edit fails closed");
    bad=Choices(original); bad[@"idfv"]=@"invalid";
    Check(![registry _identityCandidateForContainer:@"choice-fixture" choices:bad error:nil],@"invalid identifier fails closed");
    for (id value in @[@"oops", @"3oops", @"1.5", @1.5, @"9", @"-9", @"", @"99999999999999999999999999999999999"]) {
        bad=Choices(original); bad[@"batteryOffsetPercent"]=value;
        Check(![registry _identityCandidateForContainer:@"choice-fixture" choices:bad error:nil],@"malformed/fractional/out-of-range offset cannot silently become an integer");
    }
    for (id value in @[@"0", @"+8", @"-8", @3]) {
        bad=Choices(original); bad[@"batteryOffsetPercent"]=value;
        NSDictionary *accepted=[registry _identityCandidateForContainer:@"choice-fixture" choices:bad error:nil];
        Check(accepted && [accepted[@"timing"][@"batteryOffsetPercent"] integerValue]==[value integerValue],@"valid explicit battery offset is retained");
    }
    for (id value in @[@"", @" \n ", [@"x" stringByPaddingToLength:65 withString:@"x" startingAtIndex:0], @3, NSNull.null]) {
        bad=Choices(original); bad[@"deviceName"]=value;
        Check(![registry _identityCandidateForContainer:@"choice-fixture" choices:bad error:nil],@"invalid explicit device name must not silently retain the old value");
    }
    bad=Choices(original); bad[@"deviceName"]=@"My test iPhone";
    Check([[[registry _identityCandidateForContainer:@"choice-fixture" choices:bad error:nil] objectForKey:@"device"][@"deviceName"] isEqual:@"My test iPhone"],@"valid explicit name is retained");
    BOOL exercisedCityChange=NO;
    for (NSDictionary *city in [RBXDeviceCatalog citiesForCountry:@"US"]) {
        if ([city[@"city"] isEqual:original[@"device"][@"location"][@"city"]]) continue;
        bad=Choices(original); bad[@"city"]=city[@"city"]; bad[@"timezone"]=city[@"timezone"];
        NSDictionary *changed=[registry _identityCandidateForContainer:@"choice-fixture" choices:bad error:nil];
        NSDictionary *location=changed[@"device"][@"location"];
        Check(changed && [location[@"city"] isEqual:city[@"city"]] &&
            fabs([location[@"lat"] doubleValue]-[city[@"lat"] doubleValue])<=0.03001 &&
            fabs([location[@"lon"] doubleValue]-[city[@"lon"] doubleValue])<=0.03001,@"actual city change generates coordinates inside the selected city's jitter bounds");
        exercisedCityChange=YES; break;
    }
    Check(exercisedCityChange,@"fixture exercises a real catalog city transition");
    printf("%lu checks, %lu app/model/iOS tuples, %lu failures\n",(unsigned long)checks,(unsigned long)tuples,(unsigned long)failures);
    return failures ? 1 : 0;
}}
'''
fixture = fixture.replace("__VALUE__", extract("static NSString *RBXRegistryValue("))
fixture = fixture.replace("__METHODS__", "\n".join(extract(x) for x in (
    "- (BOOL)_checkIdentityChoices:", "- (NSDictionary *)_validatedIdentityCandidate:",
    "- (NSDictionary *)_identityCandidateForContainer:", "- (NSDictionary *)_identityCandidateForProfile:")))
with tempfile.TemporaryDirectory(prefix="rbx-identity-choices-") as temp:
    folder = Path(temp)
    source = folder / "fixture.m"
    source.write_text(fixture)
    executable = folder / "test"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wno-incompatible-pointer-types",
                    "-I" + str(ROOT / "daemon"), "-I" + str(ROOT / "shared"), "-framework", "Foundation",
                    str(source), str(ROOT / "daemon/RBXProfileGenerator.m"),
                    str(ROOT / "daemon/RBXConsistencyValidator.m"), str(ROOT / "daemon/RBXProfileIO.m"),
                    str(ROOT / "shared/RBXMGOverrides.m"), "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(ROOT / "profiles/catalog.json")], check=True)
