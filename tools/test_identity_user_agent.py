#!/usr/bin/env python3
"""Native identity-edit / emitted-UA regression; no device or network access.

Runs production candidate methods, profile readers, catalog and validator plus
the production Reddit UA/header functions. Only storage and the installed app's
version/build are inert fixtures. No production profile is read or written.
"""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
registry = (ROOT / "daemon/RBXContainerRegistry.m").read_text()
wire = (ROOT / "tweak/Network/RBXRedditAPIHooks.xm").read_text()


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
#import "RBXProfile.h"
#define RBX_CATALOG_TESTING 1
#include "RBXDeviceCatalog.m"
static NSUInteger checks, failures;
static void Check(BOOL ok, NSString *message) {
    checks++; if (!ok) { failures++; fprintf(stderr,"FAIL: %s\n",message.UTF8String); }
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
static RBXDeviceProfile *FixtureProfile;
static RBXDeviceProfile *rbxProfile(void) { return FixtureProfile; }
// The fixture has no installed Reddit bundle. These are app metadata, not an
// alternate UA implementation; the actual builder and header writers follow.
static NSString *RBXRealRedditVersion(void) { return @"2026.37.0"; }
static NSString *RBXRealRedditBuild(void) { return @"999999"; }
__WIRE__
static NSMutableDictionary *Choices(NSDictionary *profile) {
    NSDictionary *d=profile[@"device"], *c=d[@"carrier"];
    return [@{@"mode":@"manual", @"country":d[@"regionCode"],
        @"productType":d[@"productType"], @"iosVersion":d[@"iosVersion"],
        @"locale":d[@"locale"], @"timezone":d[@"timezone"], @"city":d[@"location"][@"city"],
        @"carrierCode":[NSString stringWithFormat:@"%@-%@",c[@"mcc"],c[@"mnc"]],
        @"idfaPosture":profile[@"ids"][@"posture"],
        @"batteryOffsetPercent":profile[@"timing"][@"batteryOffsetPercent"]} mutableCopy];
}
static NSDictionary *WithOverride(NSDictionary *profile, NSString *override) {
    NSMutableDictionary *copy=[profile mutableCopy], *reddit=[profile[@"reddit"] mutableCopy];
    if (override) reddit[@"userAgent"]=override; else [reddit removeObjectForKey:@"userAgent"];
    copy[@"reddit"]=reddit; return copy;
}
static NSString *BuiltUA(NSDictionary *profile) {
    RBXDeviceProfile *p=[[RBXDeviceProfile alloc] initWithDictionary:profile error:nil];
    return RBXBuiltUserAgent(p);
}
static void CheckHeaders(NSDictionary *profile, NSString *expected) {
    FixtureProfile=[[RBXDeviceProfile alloc] initWithDictionary:profile error:nil];
    Check([RBXBuiltUserAgent(FixtureProfile) isEqual:expected],@"actual UA builder uses the expected identity");
    Check([RBXForcedHeaderValue(@"USER_AGENT",FixtureProfile) isEqual:expected],@"actual forced-header builder uses the same UA");
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://oauth.reddit.com/fixture"]];
    [request setValue:@"original-request-UA" forHTTPHeaderField:@"User-Agent"];
    RBXApplyRedditHeaders(request); // In memory only: no session/task is created.
    Check([[request valueForHTTPHeaderField:@"User-Agent"] isEqual:expected],@"actual request header writer emits the expected UA");
}
static void CheckStable(NSDictionary *original, NSDictionary *edited) {
    Check([original[@"serials"] isEqual:edited[@"serials"]] && [original[@"ids"] isEqual:edited[@"ids"]],@"tuple edit preserves stable device identifiers");
    for (NSString *key in @[@"installId",@"externalInstallationId",@"installTimestampMs"])
        Check([original[@"reddit"][key] isEqual:edited[@"reddit"][key]],@"tuple edit preserves install identity and timestamp");
}
int main(int argc, char **argv) { @autoreleasepool {
    RBXCatalogTestPaths = @[[NSString stringWithUTF8String:argv[1]]];
    ChoiceRegistry *registry=[ChoiceRegistry new];
    for (NSString *ownership in @[@"reddit",@"legacy-reddit"]) {
        NSMutableDictionary *base=[[RBXProfileGenerator generateProfileForContainerId:@"ua-fixture"
            appType:@"reddit" proxyCountry:@"US" existingProfiles:@[] productType:@"iPhone18,1"
            iosVersion:@"26.6.2" error:nil] mutableCopy];
        Check(base!=nil,@"actual generator supplies source profile");
        if (!base) continue;
        if ([ownership isEqual:@"legacy-reddit"]) [base removeObjectForKey:@"appType"];
        NSString *oldUA=BuiltUA(base);
        NSDictionary *original=WithOverride(base,oldUA);
        NSData *json=[NSJSONSerialization dataWithJSONObject:original options:0 error:nil];
        Check([RBXProfileIO profileDictionaryFromData:json containerId:@"ua-fixture" error:nil]!=nil &&
            [RBXConsistencyValidator validatedProfile:original error:nil]!=nil,@"explicit legacy UA is an accepted source profile");
        registry.original=original;
        for (NSDictionary *selection in @[
            @{@"productType":@"iPhone18,1",@"iosVersion":@"26.6"},
            @{@"productType":@"iPhone18,3",@"iosVersion":@"26.6.2"},
            @{@"productType":@"iPhone18,3",@"iosVersion":@"26.6"}]) {
            NSMutableDictionary *choice=Choices(original); [choice addEntriesFromDictionary:selection];
            NSError *error=nil;
            NSDictionary *edited=[registry _identityCandidateForContainer:@"ua-fixture" choices:choice error:&error];
            Check(edited!=nil,[NSString stringWithFormat:@"valid tuple edit succeeds: %@",error.localizedDescription]);
            if (!edited) continue;
            Check(edited[@"reddit"][@"userAgent"]==nil,@"changed tuple invalidates the explicit UA override");
            NSString *expected=[NSString stringWithFormat:@"Reddit/2026.37.0/999999 (iPhone; iOS %@; Scale/3.00; %@)",selection[@"iosVersion"],selection[@"productType"]];
            CheckHeaders(edited,expected); CheckStable(original,edited);
            Check([original[@"reddit"][@"userAgent"] isEqual:oldUA],@"candidate construction never mutates the original override");
            NSData *data=[NSJSONSerialization dataWithJSONObject:edited options:0 error:nil];
            Check([[RBXProfileIO profileDictionaryFromData:data containerId:@"ua-fixture" error:nil] isEqual:edited],@"edited profile survives actual persistence decoding");
        }
        // Unknown custom syntax remains an opaque, supported override until a
        // field actually consumed by the UA builder changes.
        NSString *custom=@"Custom-UA/opaque; iOS 26.6.2; preserve exact bytes";
        original=WithOverride(base,custom); registry.original=original;
        for (NSDictionary *change in @[@{}, @{@"fontSize":@"19"}, @{@"deviceName":@"edited name"},
            @{@"idfv":@"11111111-1111-4111-8111-111111111111"},
            @{@"securityOnly":@YES,@"iosVersion":@"26.6",@"security":@{@"sensorAccess":@NO}}]) {
            NSMutableDictionary *choice=Choices(original); [choice addEntriesFromDictionary:change];
            NSDictionary *edited=[registry _identityCandidateForContainer:@"ua-fixture" choices:choice error:nil];
            Check(edited!=nil && [edited[@"reddit"][@"userAgent"] isEqual:custom],@"unchanged tuple or security-only edit preserves custom UA bytes");
            if (edited) CheckHeaders(edited,custom);
        }
        for (id override in @[[NSNull null],@""]) {
            original=WithOverride(base,override==[NSNull null] ? nil : override); registry.original=original;
            NSMutableDictionary *choice=Choices(original); choice[@"iosVersion"]=@"26.6";
            NSDictionary *edited=[registry _identityCandidateForContainer:@"ua-fixture" choices:choice error:nil];
            Check(edited!=nil,@"profile without an effective override still edits normally");
            if (edited) CheckHeaders(edited,@"Reddit/2026.37.0/999999 (iPhone; iOS 26.6; Scale/3.00; iPhone18,1)");
        }
        original=WithOverride(base,custom); registry.original=original;
        NSMutableDictionary *changed=Choices(original); changed[@"iosVersion"]=@"26.6";
        NSDictionary *updated=[registry _identityCandidateForContainer:@"ua-fixture" choices:changed error:nil];
        Check(updated!=nil && updated[@"reddit"][@"userAgent"]==nil,@"opaque custom syntax is invalidated without guessing how to rewrite it");
        if (updated) CheckHeaders(updated,@"Reddit/2026.37.0/999999 (iPhone; iOS 26.6; Scale/3.00; iPhone18,1)");
        NSMutableDictionary *bad=Choices(original); bad[@"iosVersion"]=@"99.0";
        Check([registry _identityCandidateForContainer:@"ua-fixture" choices:bad error:nil]==nil &&
            [original[@"reddit"][@"userAgent"] isEqual:custom],@"failed edit preserves the accepted original override");
        NSMutableDictionary *random=Choices(original); random[@"mode"]=@"random";
        NSDictionary *randomized=[registry _identityCandidateForContainer:@"ua-fixture" choices:random error:nil];
        Check(randomized!=nil && randomized[@"reddit"][@"userAgent"]==nil,@"random identity retains existing generated-UA policy");
    }
    NSDictionary *facebook=[RBXProfileGenerator generateProfileForContainerId:@"ua-fixture"
        appType:@"facebook" proxyCountry:@"US" existingProfiles:@[] productType:@"iPhone18,1"
        iosVersion:@"26.6.2" error:nil];
    NSDictionary *foreign=WithOverride(facebook,@"foreign retained metadata"); registry.original=foreign;
    NSMutableDictionary *choice=Choices(foreign); choice[@"iosVersion"]=@"26.6"; choice[@"productType"]=@"iPhone18,3";
    NSDictionary *edited=[registry _identityCandidateForContainer:@"ua-fixture" choices:choice error:nil];
    Check(edited!=nil && [edited[@"reddit"][@"userAgent"] isEqual:@"foreign retained metadata"],@"Reddit UA invalidation does not rewrite another app's metadata");
    // All shipped models currently use scale 3. This isolated test catalog
    // exercises the scale dependency after a template refresh; it is not a
    // claim that this physical model has scale 2.
    RBXCatalogTestPaths=@[[NSString stringWithUTF8String:argv[2]]];
    NSDictionary *oldScale=[RBXProfileGenerator generateProfileForContainerId:@"ua-fixture"
        proxyCountry:@"US" existingProfiles:@[] productType:@"iPhone18,1" iosVersion:@"26.6.2" error:nil];
    oldScale=WithOverride(oldScale,BuiltUA(oldScale));
    Check([RBXConsistencyValidator validatedProfile:oldScale error:nil]!=nil,@"scale-transition source matches its isolated original catalog");
    RBXCatalogTestPaths=@[[NSString stringWithUTF8String:argv[1]]]; registry.original=oldScale;
    NSDictionary *newScale=[registry _identityCandidateForContainer:@"ua-fixture" choices:Choices(oldScale) error:nil];
    Check(newScale!=nil && newScale[@"reddit"][@"userAgent"]==nil,@"scale-only refresh invalidates the stored UA");
    if (newScale) { CheckHeaders(newScale,@"Reddit/2026.37.0/999999 (iPhone; iOS 26.6.2; Scale/3.00; iPhone18,1)"); CheckStable(oldScale,newScale); }
    printf("%lu identity/actual-UA checks, %lu failures\n",(unsigned long)checks,(unsigned long)failures);
    return failures ? 1 : 0;
}}
'''
fixture = fixture.replace("__VALUE__", extract("static NSString *RBXRegistryValue("))
fixture = fixture.replace("__METHODS__", "\n".join(extract(x) for x in (
    "- (BOOL)_checkIdentityChoices:", "- (NSDictionary *)_validatedIdentityCandidate:",
    "- (NSDictionary *)_identityCandidateForContainer:", "- (NSDictionary *)_identityCandidateForProfile:")))
fixture = fixture.replace("__WIRE__", wire[wire.index("static NSString *RBXBuiltUserAgent("):
                                           wire.index("static BOOL RBXIsPassThroughKey(")])
with tempfile.TemporaryDirectory(prefix="rbx-identity-user-agent-") as temp:
    folder = Path(temp)
    source = folder / "fixture.m"
    source.write_text(fixture)
    scale_catalog = json.loads((ROOT / "profiles/catalog.json").read_text())
    scale_catalog["models"]["iPhone18,1"]["screen"]["scale"] = "2"
    scale_path = folder / "isolated-scale-fixture.json"
    scale_path.write_text(json.dumps(scale_catalog))
    executable = folder / "test"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wno-incompatible-pointer-types",
                    "-I" + str(ROOT / "daemon"), "-I" + str(ROOT / "shared"),
                    "-I" + str(ROOT / "tweak/Common"), "-framework", "Foundation",
                    str(source), str(ROOT / "daemon/RBXProfileGenerator.m"),
                    str(ROOT / "daemon/RBXConsistencyValidator.m"), str(ROOT / "daemon/RBXProfileIO.m"),
                    str(ROOT / "shared/RBXMGOverrides.m"), str(ROOT / "tweak/Common/RBXProfile.m"),
                    "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(ROOT / "profiles/catalog.json"), str(scale_path)], check=True)
