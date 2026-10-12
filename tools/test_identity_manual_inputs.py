#!/usr/bin/env python3
"""Native manual-input checks through actual registry candidate/validator code.

Only profile loading and sibling inventory are inert. No device, clone, network
or production profile is touched; identifiers are synthetic and not printed.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
registry = (ROOT / 'daemon/RBXContainerRegistry.m').read_text()


def extract(signature):
    start = registry.index(signature)
    return registry[start:registry.index('\n}\n', start) + 3]


fixture = r'''
#import <Foundation/Foundation.h>
#import "RBXProfileGenerator.h"
#import "RBXConsistencyValidator.h"
#import "RBXProfileIO.h"
#import "RBXAppRegistry.h"
#import "RBXMGOverrides.h"
#define RBX_CATALOG_TESTING 1
#include "RBXDeviceCatalog.m"
static NSUInteger checks, failures;
static void Check(BOOL ok, NSString *message) {
    checks++; if (!ok) { failures++; fprintf(stderr,"FAIL manual identity input: %s\n",message.UTF8String); }
}
static NSError *RBXDeletionError(NSString *message) {
    return [NSError errorWithDomain:@"fixture" code:400 userInfo:@{NSLocalizedDescriptionKey:message}];
}
__VALUE__
@interface ChoiceRegistry : NSObject
@property(nonatomic,copy) NSDictionary *original;
@end
@implementation ChoiceRegistry
- (NSDictionary *)_load:(NSString *)identifier error:(NSError **)error { return self.original; }
- (NSArray *)_otherProfilesExcluding:(NSString *)identifier error:(NSError **)error { return @[]; }
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
    RBXCatalogTestPaths=@[[NSString stringWithUTF8String:argv[1]]];
    ChoiceRegistry *registry=[ChoiceRegistry new];
    NSDictionary *paths=@{@"serialNumber":@"serials.serialNumber",@"udid":@"serials.udid",
        @"wifiMac":@"serials.wifiMac",@"btMac":@"serials.btMac",@"platformUUID":@"serials.platformUUID",
        @"idfv":@"ids.idfv",@"installId":@"reddit.installId",@"externalInstallationId":@"reddit.externalInstallationId"};
    for (NSString *app in @[@"reddit",@"facebook"]) {
        NSDictionary *original=[RBXProfileGenerator generateProfileForContainerId:@"manual-input-fixture"
            appType:app proxyCountry:@"US" existingProfiles:@[] productType:@"iPhone18,1" iosVersion:@"26.6.2" error:nil];
        Check(original!=nil,@"actual generator supplies an accepted source");
        if (!original) continue;
        registry.original=original;
        for (NSString *key in paths) {
            for (id value in @[@"",@" \t\n ",@3,@YES,[NSNull null],@[],@{}]) {
                NSMutableDictionary *choice=Choices(original); choice[key]=value;
                NSError *error=nil;
                Check(![registry _checkIdentityChoices:choice error:&error] && error && [error.localizedDescription containsString:key],@"explicit blank/non-string manual identifier must identify its field and fail input validation");
                Check(![registry _identityCandidateForContainer:@"manual-input-fixture" choices:choice error:nil],@"blank-looking Check must not pass by keeping an old identifier");
                Check([RBXRegistryValue(registry.original,paths[key]) length]>0,@"rejected manual input leaves saved identifiers present");
            }
            NSMutableDictionary *choice=Choices(original);
            choice[key]=[NSString stringWithFormat:@"  %@\n",RBXRegistryValue(original,paths[key])];
            NSDictionary *edited=[registry _identityCandidateForContainer:@"manual-input-fixture" choices:choice error:nil];
            Check(edited && [RBXRegistryValue(edited,paths[key]) isEqual:RBXRegistryValue(original,paths[key])],@"valid manual identifier retains existing trimming and validator behavior");
        }
        NSDictionary *extra=@{@"mlb":@"FEED1",@"uniqueChipId":@"18446744073709551615",
            @"syntheticBootEpoch":@"1700000000",@"bootTimeOffsetSeconds":@"1200",@"installTimestampMs":@"1600000000000"};
        for (NSString *key in extra) {
            NSMutableDictionary *choice=Choices(original); choice[key]=extra[key];
            NSDictionary *edited=[registry _identityCandidateForContainer:@"manual-input-fixture" choices:choice error:nil];
            Check(edited!=nil,@"additional manually reviewed field is accepted");
            NSMutableDictionary *reload=[NSMutableDictionary dictionary]; RBXAddAdditionalIdentityFields(reload,edited);
            Check([reload[key] isEqual:extra[key]],[@"additional field round-trips exactly: " stringByAppendingString:key]);
        }
        NSDictionary *badExtras=@{@"mlb":@[@"",@"not-mlb",@1,@"FFFFZ"],
            @"uniqueChipId":@[@"0",@"-1",@"18446744073709551616",@"1e12",@YES],
            @"syntheticBootEpoch":@[@"0",@"9999999999",@"NaN",@"1700000000.5"],
            @"bootTimeOffsetSeconds":@[@"-1",@"1209601",@"oops"],
            @"installTimestampMs":@[@"0",@"9999999999999",@"yesterday"],
            @"latitude":@[@"91",@"NaN",@"1suffix",@[]],@"longitude":@[@"181",@"Infinity",@{}]};
        for (NSString *key in badExtras) for (id value in badExtras[key]) {
            NSMutableDictionary *choice=Choices(original); choice[key]=value;
            NSError *error=nil;
            Check(![registry _identityCandidateForContainer:@"manual-input-fixture" choices:choice error:&error] && error,
                [@"invalid additional identity value fails before mutation: " stringByAppendingString:key]);
        }
        NSMutableDictionary *coordinates=Choices(original);
        coordinates[@"latitude"]=original[@"device"][@"location"][@"lat"];
        Check(![registry _identityCandidateForContainer:@"manual-input-fixture" choices:coordinates error:nil],@"a partial coordinate pair is rejected");
        coordinates[@"longitude"]=original[@"device"][@"location"][@"lon"];
        NSDictionary *located=[registry _identityCandidateForContainer:@"manual-input-fixture" choices:coordinates error:nil];
        Check([located[@"device"][@"location"] isEqual:original[@"device"][@"location"]],@"exact reviewed coordinates persist");
        coordinates[@"latitude"]=@"0"; coordinates[@"longitude"]=@"0";
        Check(![registry _identityCandidateForContainer:@"manual-input-fixture" choices:coordinates error:nil],@"valid numeric coordinates in a different city are rejected");
        NSMutableDictionary *omitted=Choices(original);
        [omitted removeObjectForKey:@"mode"];
        NSDictionary *retained=[registry _identityCandidateForContainer:@"manual-input-fixture" choices:omitted error:nil];
        Check(retained && [retained[@"serials"] isEqual:original[@"serials"]] && [retained[@"ids"] isEqual:original[@"ids"]],@"legacy partial API omission retains current identity");
        omitted[@"udid"]=@"";
        Check(![registry _checkIdentityChoices:omitted error:nil],@"missing mode still follows existing manual semantics for supplied fields");
        NSMutableDictionary *secure=Choices(original); secure[@"securityOnly"]=@YES;
        for (NSString *key in paths) secure[key]=@"";
        secure[@"idfa"]=@"";
        NSDictionary *securityOnly=[registry _identityCandidateForContainer:@"manual-input-fixture" choices:secure error:nil];
        Check(securityOnly && [securityOnly[@"serials"] isEqual:original[@"serials"]] && [securityOnly[@"ids"] isEqual:original[@"ids"]] && [securityOnly[@"reddit"] isEqual:original[@"reddit"]],@"security-only ignores blank identity controls and preserves the saved identity");
        NSMutableDictionary *random=Choices(original); random[@"mode"]=@"random";
        for (NSString *key in paths) random[key]=@"";
        random[@"idfa"]=@"";
        Check([registry _identityCandidateForContainer:@"manual-input-fixture" choices:random error:nil]!=nil,@"random-generation mode does not validate unused manual controls");
        for (NSString *posture in @[@"random",@"zeroWithATTDenied"]) {
            for (id value in @[@"",@" \t\n ",@3,[NSNull null],@[],@{}]) {
                NSMutableDictionary *choice=Choices(original); choice[@"idfaPosture"]=posture; choice[@"idfa"]=value;
                BOOL derived=[posture isEqual:@"zeroWithATTDenied"] && [value isKindOfClass:NSString.class];
                NSError *error=nil;
                BOOL valid=[registry _checkIdentityChoices:choice error:&error];
                Check(valid==derived && (valid || [error.localizedDescription containsString:@"idfa"]),@"blank IDFA only permits an explicitly derived denied-ATT value; wrong types are rejected");
                NSDictionary *edited=[registry _identityCandidateForContainer:@"manual-input-fixture" choices:choice error:nil];
                Check(derived ? (edited && [edited[@"ids"][@"idfa"] isEqual:@"00000000-0000-0000-0000-000000000000"]) : edited==nil,@"actual candidate either derives the zero IDFA or rejects blank random IDFA");
            }
        }
        NSMutableDictionary *explicitIDFA=Choices(original); explicitIDFA[@"idfaPosture"]=@"random";
        explicitIDFA[@"idfa"]=@"11111111-1111-4111-8111-111111111111";
        NSDictionary *idfaEdit=[registry _identityCandidateForContainer:@"manual-input-fixture" choices:explicitIDFA error:nil];
        Check(idfaEdit && [idfaEdit[@"ids"][@"idfa"] isEqual:explicitIDFA[@"idfa"]],@"valid explicit random IDFA remains accepted");
        explicitIDFA[@"idfa"]=@"not-a-uuid";
        Check([registry _checkIdentityChoices:explicitIDFA error:nil] && ![registry _identityCandidateForContainer:@"manual-input-fixture" choices:explicitIDFA error:nil],@"format validation remains authoritative in the existing validator");
        NSMutableDictionary *imei=Choices(original); imei[@"imei1"]=@"";
        NSDictionary *generic=[registry _identityCandidateForContainer:@"manual-input-fixture" choices:imei error:nil];
        Check(generic && [generic[@"serials"][@"imei1"] isEqual:@""],@"generic model without an evidenced TAC may retain an empty IMEI");
    }
    Check(![registry _checkIdentityChoices:(id)@[] error:nil],@"wrong choice root still fails closed");
    Check(![registry _checkIdentityChoices:@{@"securityOnly":@"yes",@"udid":@""} error:nil],@"wrong security-only type cannot bypass validation");
    Check(![registry _checkIdentityChoices:@{@"mode":@3,@"udid":@""} error:nil],@"wrong mode type cannot bypass validation");
    printf("%lu actual manual-input/candidate checks, %lu failures\n",(unsigned long)checks,(unsigned long)failures);
    return failures ? 1 : 0;
}}
'''
fixture = fixture.replace('__VALUE__', extract('static NSString *RBXRegistryValue('))
fixture = fixture.replace('__METHODS__', '\n'.join(extract(signature) for signature in (
    '- (BOOL)_checkIdentityChoices:', '- (NSDictionary *)_validatedIdentityCandidate:',
    '- (NSDictionary *)_identityCandidateForContainer:', '- (NSDictionary *)_identityCandidateForProfile:')))
with tempfile.TemporaryDirectory(prefix='rbx-identity-manual-inputs-') as temp:
    folder = Path(temp)
    source = folder / 'fixture.m'
    source.write_text(fixture)
    executable = folder / 'test'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wno-incompatible-pointer-types',
                    '-I' + str(ROOT / 'daemon'), '-I' + str(ROOT / 'shared'), '-framework', 'Foundation',
                    str(source), str(ROOT / 'daemon/RBXProfileGenerator.m'),
                    str(ROOT / 'daemon/RBXConsistencyValidator.m'), str(ROOT / 'daemon/RBXProfileIO.m'),
                    str(ROOT / 'shared/RBXMGOverrides.m'), '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(ROOT / 'profiles/catalog.json')], check=True)
