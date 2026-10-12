#import <Foundation/Foundation.h>
#import "../Containers/LBXContainerConfiguration.h"
#include <limits.h>

static NSUInteger checks,failures;
static void Check(BOOL ok, NSString *label) {
    checks++; if (!ok) { failures++; fprintf(stderr,"FAIL: %s\n",label.UTF8String); }
}
static NSDictionary *Manual(void) {
    return @{@"serialNumber":@"c02abc123xyz",@"udid":@"0123456789abcdef0123456789abcdef01234567",
        @"idfa":@"01234567-89ab-4cde-8f01-23456789abcd",@"idfv":@"23456789-abcd-4ef0-8123-456789abcdef",
        @"platformUUID":@"3456789a-bcde-4f01-8234-56789abcdef0",@"wifiMac":@"02:ab:cd:ef:12:34",
        @"bluetoothMac":@"04:12:34:56:78:9a",@"imei":@"490154203237518",@"meid":@"a1000000000001",
        @"iccid":@"8914800000000000014"};
}
static LBXContainerConfiguration *Create(id name,id applications,id identifiers,id proxy) {
    return [LBXContainerConfiguration createWithName:name applications:applications manualIdentifiers:identifiers proxyReference:proxy error:nil];
}
static BOOL Reject(id input) {
    NSError *error=nil;
    LBXContainerConfiguration *value=[LBXContainerConfiguration fromDictionary:input error:&error];
    return !value && error && ![error.localizedDescription containsString:@"private-name"] &&
        ![error.localizedDescription containsString:@"private-proxy"];
}
static NSMutableDictionary *Replace(NSDictionary *base,NSString *key,id value) {
    NSMutableDictionary *result=[base mutableCopy]; if (value) result[key]=value; else [result removeObjectForKey:key]; return result;
}
static BOOL IndependentLuhn(NSString *value) {
    NSUInteger sum=0;
    for (NSUInteger i=0;i<value.length;i++) {
        NSUInteger digit=[value characterAtIndex:i]-'0';
        if ((value.length-i)%2==0) { digit*=2; if (digit>9) digit-=9; }
        sum+=digit;
    }
    return sum%10==0;
}
int main(void) { @autoreleasepool {
    NSArray *apps=@[@"com.burbn.instagram",@"com.facebook.Facebook",@"com.atebits.Tweetie2"];
    NSDictionary *manual=Manual(); NSError *error=nil;
    NSString *proxy=@"abcdef01-2345-4678-9abc-def012345678";
    LBXContainerConfiguration *configuration=[LBXContainerConfiguration createWithName:@"private-name" applications:apps
        manualIdentifiers:manual proxyReference:proxy error:&error];
    Check(configuration && !error, @"complete manual configuration accepted");
    Check([configuration.identifiers isEqual:manual],@"all manual values preserved exactly, including case");
    Check(!LBXContainerConfigurationInvalidChoiceField(@"valid",apps,manual,proxy),@"valid choices have no invalid field key");
    Check([LBXContainerConfigurationInvalidChoiceField(@" ",apps,manual,proxy) isEqual:@"name"],@"name error takes precedence");
    Check([LBXContainerConfigurationInvalidChoiceField(@"valid",@[],manual,proxy) isEqual:@"applications"],@"empty selection has explicit field key");
    Check([LBXContainerConfigurationInvalidChoiceField(@"valid",apps,manual,@"private invalid proxy") isEqual:@"proxyReference"],@"proxy error never exposes supplied value");
    Check([LBXContainerConfigurationInvalidChoiceField(@"valid",apps,@{},proxy) isEqual:@"manualIdentifiers"],@"wrong manual dictionary shape stays refused");
    for(NSString *key in @[@"serialNumber",@"udid",@"idfa",@"idfv",@"platformUUID",@"wifiMac",@"bluetoothMac",@"imei",@"meid",@"iccid"]) {
        NSMutableDictionary *bad=[manual mutableCopy];bad[key]=@"invalid";
        Check([LBXContainerConfigurationInvalidChoiceField(@"valid",apps,bad,proxy) isEqual:key]&&!LBXContainerConfigurationValidateChoices(@"valid",apps,bad,proxy),@"detailed key and authoritative refusal agree for every identifier");
        bad[key]=@1;Check([LBXContainerConfigurationInvalidChoiceField(@"valid",apps,bad,proxy) isEqual:key]&&!LBXContainerConfigurationValidateChoices(@"valid",apps,bad,proxy),@"non-string identifier returns key without throwing");
        bad[key]=@"";Check([LBXContainerConfigurationInvalidChoiceField(@"valid",apps,bad,proxy) isEqual:key]&&!LBXContainerConfigurationValidateChoices(@"valid",apps,bad,proxy),@"empty identifier remains refused with precise key");
    }
    NSMutableDictionary *two=[manual mutableCopy];two[@"idfa"]=@"invalid";two[@"iccid"]=@"";
    Check([LBXContainerConfigurationInvalidChoiceField(@"valid",apps,two,proxy) isEqual:@"idfa"],@"first error follows field order across format and empty failures");
    Check(!LBXContainerConfigurationInvalidChoiceField(@"valid",apps,nil,nil)&&LBXContainerConfigurationValidateChoices(@"valid",apps,nil,nil),@"random choices remain valid without generating during diagnostics");

    Check(configuration.revision==1 && [configuration.identifierMode isEqual:@"manual"],@"first revision and explicit manual mode");
    Check(configuration.identifier.length==36 && [configuration.identifier isEqual:configuration.identifier.lowercaseString] &&
        [configuration.privateDictionary[@"formatVersion"] isEqual:@1],@"new source identifier is canonical lowercase with exact format version");
    Check(configuration.privateDictionary.count==8 && configuration.identifiers.count==10,@"exact document and identifier fields");
    NSDictionary *document=configuration.privateDictionary;
    NSData *serialized=[NSJSONSerialization dataWithJSONObject:document options:0 error:&error];
    NSDictionary *decoded=[NSJSONSerialization JSONObjectWithData:serialized options:0 error:&error];
    LBXContainerConfiguration *reloaded=[LBXContainerConfiguration fromDictionary:decoded error:&error];
    Check(reloaded && !error && [reloaded.privateDictionary isEqual:document],@"manual JSON reload retains full exact private state");
    NSString *safe=[configuration.safeStatus description],*description=configuration.description;
    Check(![safe containsString:configuration.name] && ![safe containsString:configuration.identifier] &&
        ![safe containsString:configuration.proxyReference],@"safe status excludes container name UUID and proxy reference");
    for (NSString *value in manual.allValues) Check(![safe containsString:value] && ![description containsString:value],@"summaries exclude every manual identifier");
    Check(![description containsString:@"private-name"] && ![description containsString:proxy] &&
        [configuration.safeStatus[@"runtimeAccepted"] isEqual:@NO],@"description redacts inputs and runtime support remains unaccepted");
    for (NSUInteger mask=1;mask<8;mask++) {
        NSMutableArray *requested=[NSMutableArray array],*canonical=[NSMutableArray array];
        for (NSUInteger i=0;i<3;i++) if (mask&(1u<<i)) [canonical addObject:apps[i]];
        for (NSUInteger i=3;i>0;i--) if (mask&(1u<<(i-1))) [requested addObject:apps[i-1]];
        LBXContainerConfiguration *subset=Create(@"selection",requested,manual,nil);
        Check(subset && [subset.applications isEqual:canonical],@"each of seven nonempty memberships canonicalizes in requested order");
        Check([subset.safeStatus[@"applicationCount"] unsignedIntegerValue]==canonical.count,@"selected app count is accurate");
    }
    for (id invalidApps in @[@[],@[apps[0],apps[0]],@[@"com.unknown.app"],@[NSNull.null],@[apps[0],@42],@42,
                             @[@"com.burbn.instagram\n"],@[apps[0],apps[1],apps[2],@"extra"]])
        Check(Reject(Replace(document,@"applications",invalidApps)),@"invalid membership rejects whole document");

    LBXContainerConfiguration *changed=[configuration configurationByUpdatingName:@"renamed" applications:@[apps[1]]
        manualIdentifiers:nil proxyReference:@"" error:&error];
    Check(changed && !error && changed.revision==2 && [changed.identifier isEqual:configuration.identifier],@"edit increments revision while retaining stable source ID");
    Check([changed.identifiers isEqual:manual] && [changed.identifierMode isEqual:@"manual"] && !changed.proxyReference.length,
        @"unrelated edit retains every saved manual ID and empty reference clears proxy");
    Check([configuration.name isEqual:@"private-name"] && [configuration.proxyReference isEqual:proxy] && configuration.revision==1,
        @"edit leaves original immutable revision untouched");
    LBXContainerConfiguration *retained=[changed configurationByUpdatingName:nil applications:nil manualIdentifiers:nil proxyReference:nil error:&error];
    Check(retained.revision==3 && [retained.name isEqual:changed.name] && [retained.applications isEqual:changed.applications] &&
        [retained.identifiers isEqual:changed.identifiers],@"nil edit arguments retain complete state and increment one revision");
    Check(![changed configurationByUpdatingName:@"" applications:nil manualIdentifiers:nil proxyReference:nil error:&error] && error,
        @"invalid edit does not produce a replacement revision");

    NSMutableString *mutableName=[@"before" mutableCopy],*mutableProxy=[proxy mutableCopy],*mutableUUID=[manual[@"idfv"] mutableCopy];
    NSMutableDictionary *mutableIDs=[manual mutableCopy]; mutableIDs[@"idfv"]=mutableUUID;
    NSMutableArray *mutableApps=[@[apps[0]] mutableCopy];
    LBXContainerConfiguration *aliased=Create(mutableName,mutableApps,mutableIDs,mutableProxy);
    [mutableName setString:@"after"]; [mutableProxy setString:@"not-a-reference"]; [mutableUUID setString:@"invalid"];
    mutableIDs[@"imei"]=@"invalid"; [mutableApps removeAllObjects];
    Check([aliased.name isEqual:@"before"] && [aliased.proxyReference isEqual:proxy] &&
        [aliased.identifiers isEqual:manual] && [aliased.applications isEqual:@[apps[0]]],@"mutable factory inputs cannot change stored values");
    NSMutableDictionary *mutableDocument=[document mutableCopy];
    NSMutableDictionary *nested=[manual mutableCopy]; mutableDocument[@"identifiers"]=nested;
    NSMutableString *nestedSerial=[manual[@"serialNumber"] mutableCopy]; nested[@"serialNumber"]=nestedSerial;
    LBXContainerConfiguration *snapshot=[LBXContainerConfiguration fromDictionary:mutableDocument error:nil];
    [nestedSerial setString:@"invalid"]; [nested removeAllObjects]; [mutableDocument removeAllObjects];
    Check([snapshot.privateDictionary isEqual:document],@"mutable reload document and nested leaves are copied");
    Check(![snapshot.privateDictionary isKindOfClass:NSMutableDictionary.class] && ![snapshot.identifiers isKindOfClass:NSMutableDictionary.class] &&
        ![snapshot.applications isKindOfClass:NSMutableArray.class],@"all published collections are immutable");
    Check(!Create((id)nil,apps,manual,nil) && !Create(@"name",(id)nil,manual,nil),@"missing creation requirements reject");

    for (NSString *key in document) Check(Reject(Replace(document,key,nil)),@"each required field is enforced");
    Check(Reject(Replace(document,@"unknown",@"extra")),@"unknown top-level key rejects");
    for (id invalid in @[NSNull.null,@42,@[],@"private-name"]) Check(Reject(invalid),@"non-dictionary document rejects");
    for (NSString *key in @[@"formatVersion",@"revision"]) {
        for (id value in @[@YES,@NO,@0,@(-1),@1.0,@1.5,@(ULLONG_MAX),@"1",NSNull.null])
            Check(Reject(Replace(document,key,value)),@"Boolean floating negative zero overflow and textual integers reject");
    }
    Check(Reject(Replace(document,@"formatVersion",@2)),@"unsupported integer format version rejects");
    LBXContainerConfiguration *maximum=[LBXContainerConfiguration fromDictionary:Replace(document,@"revision",@(LLONG_MAX)) error:&error];
    Check(maximum && maximum.revision==LLONG_MAX,@"largest exact positive revision reloads without coercion");
    Check(![maximum configurationByUpdatingName:nil applications:nil manualIdentifiers:nil proxyReference:nil error:&error] && error,
        @"edit cannot overflow revision");
    for (id value in @[@"",@"   ",@"private-name\n",@42,NSNull.null,[@"x" stringByPaddingToLength:81 withString:@"x" startingAtIndex:0]])
        Check(Reject(Replace(document,@"name",value)),@"empty control nontext and oversized name reject");
    for (id value in @[@"private-proxy\t",@42,NSNull.null,[@"x" stringByPaddingToLength:257 withString:@"x" startingAtIndex:0],
                      @"https://proxy.example:8080",@"user:password",@"   ",proxy.uppercaseString,
                      @"00000000-0000-0000-0000-000000000000",@"Abcdef01-2345-4678-9abc-def012345678"])
        Check(Reject(Replace(document,@"proxyReference",value)),@"malformed URLs credentials whitespace zero and case aliases cannot become proxy references");
    for (id value in @[@"automatic",@"manual\n",@42,NSNull.null]) Check(Reject(Replace(document,@"identifierMode",value)),@"unknown identifier mode rejects");
    for (id value in @[@"",@"00000000-0000-0000-0000-000000000000",@"not-uuid",@42,NSNull.null])
        Check(Reject(Replace(document,@"identifier",value)),@"malformed source UUID rejects");
    for (id value in @[@"ABCDEF01-2345-4678-9ABC-DEF012345678",@"Abcdef01-2345-4678-9abc-def012345678"])
        Check(Reject(Replace(document,@"identifier",value)),@"mixed or uppercase source UUID aliases reject");
    for (NSString *key in manual) {
        Check(Reject(Replace(document,@"identifiers",Replace(manual,key,nil))),@"partial manual dictionaries reject");
        for (id value in @[@42,NSNull.null,@"invalid\n",@[]])
            Check(Reject(Replace(document,@"identifiers",Replace(manual,key,value))),@"every identifier rejects wrong types and control characters");
    }
    Check(Reject(Replace(document,@"identifiers",Replace(manual,@"unknown",@"value"))),@"unknown manual identifier rejects");
    NSDictionary *invalidValues=@{@"serialNumber":@[@"short",@"1234567890123",@"ABCD_12345"],
        @"udid":@[@"0000000000000000000000000000000000000000",@"00000000-0000000000000000",@"01234567-abcdef",@"g123456789abcdef0123456789abcdef01234567"],
        @"idfa":@[@"00000000-0000-0000-0000-000000000000",@"{01234567-89ab-4cde-8f01-23456789abcd}"],
        @"idfv":@[@"0123456789ab4cde8f0123456789abcd"],@"platformUUID":@[@"01234567-89ab-4cde-8f01-23456789abcg"],
        @"wifiMac":@[@"01:12:34:56:78:90",@"00:00:00:00:00:00",@"ff:ff:ff:ff:ff:ff",@"02-12-34-56-78-90",@"02:12:34:56:78:9g"],
        @"bluetoothMac":@[@"03:12:34:56:78:90",@"02:12:34:56:78"],
        @"imei":@[@"490154203237519",@"000000000000000",@"49015420323751",@"４90154203237518"],
        @"meid":@[@"00000000000000",@"a100000000000g",@"a100000000001"],
        @"iccid":@[@"8914800000000000015",@"0000000000000000000",@"891480000000000001",@"891480000000000001400"]};
    for (NSString *key in invalidValues) for (id value in invalidValues[key])
        Check(Reject(Replace(document,@"identifiers",Replace(manual,key,value))),@"UUID length checksum hexadecimal and unicast checks reject malformed identity");
    NSDictionary *modern=Replace(manual,@"udid",@"00008110-001234567890abcd");
    Check(Create(@"modern",apps,modern,nil)!=nil,@"modern structured UDID syntax accepted without hardware claim");

    for (NSUInteger i=0;i<128;i++) {
        LBXContainerConfiguration *random=Create(@"random",@[apps[0]],nil,nil);
        Check(random && [random.identifierMode isEqual:@"random"] && !random.proxyReference.length,@"random creation emits a complete accepted syntactic identity");
        Check(IndependentLuhn(random.identifiers[@"imei"]) && IndependentLuhn(random.identifiers[@"iccid"]),@"random numeric identifiers pass independent checksum check");
        LBXContainerConfiguration *edit=[random configurationByUpdatingName:@"random-renamed" applications:apps manualIdentifiers:nil proxyReference:proxy error:nil];
        LBXContainerConfiguration *again=[LBXContainerConfiguration fromDictionary:edit.privateDictionary error:nil];
        Check([edit.identifiers isEqual:random.identifiers] && [again.identifiers isEqual:random.identifiers] &&
            [again.identifier isEqual:random.identifier] && [again.identifierMode isEqual:@"random"],@"random identifiers survive membership proxy name edit and reload exactly");
        LBXContainerConfiguration *manualEdit=[random configurationByUpdatingName:nil applications:nil manualIdentifiers:manual proxyReference:nil error:nil];
        Check([manualEdit.identifiers isEqual:manual] && [manualEdit.identifierMode isEqual:@"manual"] &&
            [manualEdit.identifier isEqual:random.identifier],@"complete manual edit persists all values and mode without reallocating container");
    }
    printf("%lu checks, %lu failures\n",(unsigned long)checks,(unsigned long)failures);
    return failures ? 1 : 0;
} }
