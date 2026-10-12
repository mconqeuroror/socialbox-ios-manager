#import "../Containers/LBXContainerIdentitySpecification.h"
#import "../Containers/LBXContainerConfiguration.h"
#include <unistd.h>
#include <limits.h>
static NSUInteger checks,failures;
static void Check(BOOL ok,NSString *message){checks++;if(!ok){failures++;fprintf(stderr,"FAIL: %s\n",message.UTF8String);}}
static NSDictionary *Manual(void) {
    return @{@"serialNumber":@"c02abc123xyz",@"udid":@"0123456789abcdef0123456789abcdef01234567",
        @"idfa":@"01234567-89ab-4cde-8f01-23456789abcd",@"idfv":@"23456789-abcd-4ef0-8123-456789abcdef",
        @"platformUUID":@"3456789a-bcde-4f01-8234-56789abcdef0",@"wifiMac":@"02:ab:cd:ef:12:34",
        @"bluetoothMac":@"04:12:34:56:78:9a",@"imei":@"490154203237518",@"meid":@"a1000000000001",@"iccid":@"8914800000000000014"};
}
static NSDictionary *Context(void) {
    return @{@"machine":@"iPhone10,6",@"model":@"D221AP",@"osBuild":@"20H392",@"osRelease":@"22.6.0",@"memoryBytes":@3119919104,
        @"osVersion":@{@"major":@16,@"minor":@7,@"patch":@16}};
}
static NSMutableDictionary *Replace(NSDictionary *value,NSString *key,id replacement) {
    NSMutableDictionary *copy=[value mutableCopy];if(replacement)copy[key]=replacement;else[copy removeObjectForKey:key];return copy;
}
static BOOL Reject(id value) {
    NSError *error=nil;id result=[LBXContainerIdentitySpecification fromDictionary:value error:&error];
    return !result&&error&&![error.description containsString:@"fixture/private"]&&![error.description containsString:@"c02abc123xyz"];
}
int main(void){@autoreleasepool{
    NSArray *apps=@[@"com.burbn.instagram",@"com.facebook.Facebook",@"com.atebits.Tweetie2"];
    LBXContainerConfiguration *generated=[LBXContainerConfiguration createWithName:@"fixture/private" applications:apps manualIdentifiers:Manual() proxyReference:@"" error:nil];
    LBXContainerConfiguration *configuration=[LBXContainerConfiguration fromDictionary:
        Replace(generated.privateDictionary,@"identifier",@"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa") error:nil];
    [LBXContainerIdentitySpecification testUsePhysicalContext:nil];NSError *error=nil;
    if(getuid()!=0||geteuid()!=0)
        Check(![LBXContainerIdentitySpecification createWithConfiguration:configuration error:&error]&&error.code==2,@"unprivileged real capture cannot manufacture a physical context");
    NSMutableDictionary *mutableContext=[Context() mutableCopy];NSMutableDictionary *mutableVersion=[mutableContext[@"osVersion"] mutableCopy];mutableContext[@"osVersion"]=mutableVersion;
    [LBXContainerIdentitySpecification testUsePhysicalContext:mutableContext];
    LBXContainerIdentitySpecification *spec=[LBXContainerIdentitySpecification createWithConfiguration:configuration error:&error];
    Check(spec&&!error,@"deterministic test provider exercises actual specification creation");
    mutableContext[@"machine"]=@"mutated";mutableVersion[@"major"]=@99;
    Check([spec.physicalContext isEqual:Context()],@"physical context is a deep immutable snapshot of all observed facts");
    Check([spec.configurationIdentifier isEqual:configuration.identifier]&&spec.configurationRevision==1,@"stable configuration identity and revision remain exact");
    Check([spec.configurationSHA256 isEqual:@"3c8d69e28533990694de90db91ae38fce21854e9a76186f22b4482b7bfe36e4f"],@"canonical SHA256 matches an independent Python sorted-JSON vector including literal slash");
    Check([spec.privateDictionary[@"configuration"] isEqual:configuration.privateDictionary],@"complete canonical configuration snapshot is retained");
    for(NSString *field in Manual())Check([spec.privateDictionary[@"configuration"][@"identifiers"][field] isEqual:Manual()[field]],@"all ten identifier strings retain accepted spelling and case exactly");
    Check(spec.reservationKeys.count==10&&[NSSet setWithArray:spec.reservationKeys.allValues].count==10,@"ten distinct normalized reservations are derived without persistence");
    Check([spec.reservationKeys[@"idfa"] isEqual:@"uuid:01234567-89ab-4cde-8f01-23456789abcd"]&&
        [spec.reservationKeys[@"idfv"] hasPrefix:@"uuid:"]&&[spec.reservationKeys[@"platformUUID"] hasPrefix:@"uuid:"],@"all three UUID fields share a reservation namespace");
    Check([spec.reservationKeys[@"wifiMac"] isEqual:@"mac:02:ab:cd:ef:12:34"]&&[spec.reservationKeys[@"bluetoothMac"] hasPrefix:@"mac:"],@"both MAC fields share lowercase reservation namespace");
    for(NSString *field in @[@"serialNumber",@"udid",@"imei",@"meid",@"iccid"])
        Check([spec.reservationKeys[field] hasSuffix:[Manual()[field] lowercaseString]],@"other reservation aliases normalize case without rewriting stored values");
    for(NSString *field in @[@"applicability",@"manufacturer",@"TAC",@"operator",@"advertising"])
        Check([spec.privateDictionary[@"relationships"][field] isEqual:@"UNVERIFIED"],@"physical observation does not establish manufactured identifier relationships");
    Check([spec.privateDictionary[@"runtimeAccepted"] isEqual:@NO]&&[spec.safeStatus[@"runtimeAccepted"] isEqual:@NO],@"specification is never an admission or runtime acceptance grant");
    NSString *description=spec.description,*debug=spec.debugDescription,*status=spec.safeStatus.description;
    for(NSString *sensitive in @[configuration.identifier,configuration.name,spec.configurationSHA256,@"iPhone10,6",@"D221AP",@"20H392",@"22.6.0"])
        Check(![description containsString:sensitive]&&![debug containsString:sensitive]&&![status containsString:sensitive],@"descriptions and status redact configuration hashes and observed device facts");
    for(NSString *sensitive in Manual().allValues)
        Check(![description containsString:sensitive]&&![status containsString:sensitive],@"description/status omit every private identifier");
    Check(spec.physicalContext.count==6&&!spec.physicalContext[@"serialNumber"]&&!spec.physicalContext[@"udid"]&&!spec.physicalContext[@"imei"]&&!spec.physicalContext[@"iccid"]&&!spec.physicalContext[@"ecid"],@"physical observation schema contains no real unique device identifier");
    NSData *encoded=[NSJSONSerialization dataWithJSONObject:spec.privateDictionary options:0 error:nil];
    NSDictionary *decoded=[NSJSONSerialization JSONObjectWithData:encoded options:0 error:nil];
    LBXContainerIdentitySpecification *loaded=[LBXContainerIdentitySpecification fromDictionary:decoded error:&error];
    Check(loaded&&!error&&[loaded.privateDictionary isEqual:spec.privateDictionary]&&[loaded.reservationKeys isEqual:spec.reservationKeys],@"strict JSON reload restores exact specification and derived reservations");
    LBXContainerIdentitySpecification *again=[LBXContainerIdentitySpecification createWithConfiguration:configuration error:nil];
    Check([again.privateDictionary isEqual:spec.privateDictionary],@"creation from the same configuration and physical facts has no UUID or random regeneration");
    for(NSString *field in spec.privateDictionary)
        Check(Reject(Replace(spec.privateDictionary,field,nil)),@"every specification schema field is required");
    Check(Reject(Replace(spec.privateDictionary,@"extra",@YES)),@"unknown specification fields reject");
    for(id malformed in @[NSNull.null,@YES,@1.0,@"1",@2])
        Check(Reject(Replace(spec.privateDictionary,@"formatVersion",malformed)),@"format version is exact non-Boolean integer one");
    for(id flag in @[@YES,@0,@1,@"false",NSNull.null])
        Check(Reject(Replace(spec.privateDictionary,@"runtimeAccepted",flag)),@"runtimeAccepted must be exact Boolean false");
    for(id digest in @[@"wrong",spec.configurationSHA256.uppercaseString,@42,NSNull.null])
        Check(Reject(Replace(spec.privateDictionary,@"configurationSHA256",digest)),@"configuration digest cannot be missing invalid non-string or case aliased");
    Check(Reject(Replace(spec.privateDictionary,@"configuration",Replace(configuration.privateDictionary,@"name",@"altered"))),@"digest rejects changes to full configuration content");
    Check(Reject(Replace(spec.privateDictionary,@"relationships",Replace(spec.privateDictionary[@"relationships"],@"manufacturer",@"VERIFIED"))),@"manufacturing verification cannot be invented by a saved document");
    Check(Reject(Replace(spec.privateDictionary,@"relationships",Replace(spec.privateDictionary[@"relationships"],@"secret",@YES))),@"relationship schema rejects unknown fields");
    for(NSString *field in Context())
        Check(Reject(Replace(spec.privateDictionary,@"physicalContext",Replace(Context(),field,nil))),@"all fixed physical-context facts are mandatory");
    for(NSString *field in @[@"machine",@"model",@"osBuild",@"osRelease"]) {
        for(id bad in @[NSNull.null,@YES,@42,@[],@{},@"",@"bad\nfact"])
            Check(Reject(Replace(spec.privateDictionary,@"physicalContext",Replace(Context(),field,bad))),@"physical text facts reject incompatible JSON types and unsafe characters");
    }
    for(id bad in @[NSNull.null,@YES,@1.0,@0,@(-1),@"123",@(ULLONG_MAX)])
        Check(Reject(Replace(spec.privateDictionary,@"physicalContext",Replace(Context(),@"memoryBytes",bad))),@"observed memory must be a positive bounded integer");
    for(NSString *field in @[@"major",@"minor",@"patch"]) {
        for(id bad in @[NSNull.null,@YES,@1.0,@(-1),@"16",@((uint64_t)INT_MAX+1)])
            Check(Reject(Replace(spec.privateDictionary,@"physicalContext",Replace(Context(),@"osVersion",Replace(Context()[@"osVersion"],field,bad)))),@"OS-version components reject coercion and out-of-range values");
    }
    Check(Reject(Replace(spec.privateDictionary,@"physicalContext",Replace(Context(),@"osVersion",Replace(Context()[@"osVersion"],@"major",@0)))),@"OS major version is positive");
    Check(Reject(Replace(spec.privateDictionary,@"physicalContext",Replace(Context(),@"ecid",@"invented"))),@"extra unique hardware facts cannot enter snapshot");
    NSDictionary *zeroMinor=Replace(Context(),@"osVersion",@{@"major":@16,@"minor":@0,@"patch":@0});
    Check([LBXContainerIdentitySpecification testCreateWithConfiguration:configuration physicalContext:zeroMinor error:nil]!=nil,@"observed zero minor/patch versions are valid integers");
    for(NSArray *pair in @[@[@"idfa",@"idfv"],@[@"idfa",@"platformUUID"],@[@"idfv",@"platformUUID"],@[@"wifiMac",@"bluetoothMac"]]) {
        NSMutableDictionary *aliases=[Manual() mutableCopy];aliases[pair[1]]=[aliases[pair[0]] uppercaseString];
        LBXContainerConfiguration *repeated=[configuration configurationByUpdatingName:nil applications:nil manualIdentifiers:aliases proxyReference:nil error:nil];
        Check(repeated!=nil,@"configuration syntax alone permits alias collision fixture");
        Check(![LBXContainerIdentitySpecification createWithConfiguration:repeated error:&error]&&error.code==3,@"spec rejects repeated UUID/MAC aliases across corresponding fields");
    }
    NSMutableDictionary *uppercase=[Manual() mutableCopy];
    for(NSString *field in @[@"serialNumber",@"udid",@"idfa",@"idfv",@"platformUUID",@"wifiMac",@"bluetoothMac",@"meid"])uppercase[field]=[uppercase[field] uppercaseString];
    LBXContainerConfiguration *uppercaseConfiguration=[configuration configurationByUpdatingName:nil applications:nil manualIdentifiers:uppercase proxyReference:nil error:nil];
    LBXContainerIdentitySpecification *uppercaseSpec=[LBXContainerIdentitySpecification createWithConfiguration:uppercaseConfiguration error:nil];
    Check([uppercaseSpec.reservationKeys isEqual:spec.reservationKeys],@"case aliases collide globally without changing the exact caller values");
    Check([uppercaseSpec.privateDictionary[@"configuration"][@"identifiers"] isEqual:uppercase]&&![uppercaseSpec.configurationSHA256 isEqual:spec.configurationSHA256],@"exact case and new revision remain visible to canonical content binding");
    NSDictionary *changedContext=Replace(Context(),@"osBuild",@"20H393");
    [LBXContainerIdentitySpecification testUsePhysicalContext:changedContext];
    LBXContainerIdentitySpecification *current=[LBXContainerIdentitySpecification createWithConfiguration:configuration error:nil];
    Check(![current.physicalContext isEqual:spec.physicalContext]&&[current.configurationSHA256 isEqual:spec.configurationSHA256],@"current context comparison detects observed OS changes without changing configuration identity");
    Check([spec.physicalContext isEqual:Context()],@"new observations never mutate an existing journal-bound snapshot");
    BOOL immutable=NO;@try{[(NSMutableDictionary *)spec.privateDictionary setObject:@2 forKey:@"formatVersion"];}@catch(__unused NSException *e){immutable=YES;}
    Check(immutable,@"private specification dictionary is immutable");
    immutable=NO;@try{[(NSMutableDictionary *)spec.physicalContext[@"osVersion"] setObject:@99 forKey:@"major"];}@catch(__unused NSException *e){immutable=YES;}
    Check(immutable,@"nested observed context is immutable");
    immutable=NO;@try{[(NSMutableDictionary *)spec.reservationKeys setObject:@"altered" forKey:@"idfa"];}@catch(__unused NSException *e){immutable=YES;}
    Check(immutable,@"derived reservation dictionary is immutable");
    for(id bad in @[NSNull.null,@YES,@42,@[],@"bad",@{}])Check(Reject(bad),@"incompatible top-level JSON types reject safely");
    [LBXContainerIdentitySpecification testUsePhysicalContext:nil];
    NSLog(@"%@: %lu identity specification assertions, %lu failures",failures?@"FAIL":@"PASS",(unsigned long)checks,(unsigned long)failures);return failures?1:0;
}}
