#import "LBXContainerConfiguration.h"
#import <CoreFoundation/CoreFoundation.h>
#include <limits.h>

static NSString *const LBXConfigurationErrorDomain = @"com.socialbox.container-configuration";
static id LBXConfigurationFailure(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:LBXConfigurationErrorDomain code:422
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return nil;
}
static BOOL LBXExactKeys(id value, NSArray<NSString *> *keys) {
    return [value isKindOfClass:NSDictionary.class] && [value count] == keys.count &&
        [[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]];
}
static BOOL LBXInteger(id value, uint64_t *result) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
        CFNumberIsFloatType((__bridge CFNumberRef)value)) return NO;
    const char *type = [value objCType];
    if (!type || !strchr("cislqCISLQ",type[0]) || type[1]) return NO;
    // The schema uses positive signed-64-bit JSON integers, avoiding wraparound
    // and NSNumber coercion of negative/floating/Boolean revision fields.
    uint64_t number = [value unsignedLongLongValue];
    if ([value longLongValue] <= 0 || number > LLONG_MAX) return NO;
    if (result) *result = number;
    return YES;
}
static BOOL LBXText(id value, NSUInteger maximum, BOOL emptyAllowed) {
    return [value isKindOfClass:NSString.class] && [value length] <= maximum &&
        (emptyAllowed || [[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length]) &&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static BOOL LBXCharacters(NSString *text, NSString *alphabet, NSUInteger minimum, NSUInteger maximum) {
    return [text isKindOfClass:NSString.class] && text.length >= minimum && text.length <= maximum &&
        [text rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:alphabet] invertedSet]].location == NSNotFound;
}
static BOOL LBXNonzero(NSString *text) {
    return [[text stringByReplacingOccurrencesOfString:@"0" withString:@""] length] > 0;
}
static BOOL LBXUUID(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 36) return NO;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:value];
    return uuid && [uuid.UUIDString isEqual:[value uppercaseString]] &&
        ![uuid.UUIDString isEqual:@"00000000-0000-0000-0000-000000000000"];
}
static BOOL LBXCanonicalUUID(id value) {
    return LBXUUID(value) && [value isEqual:[value lowercaseString]];
}
static BOOL LBXLuhn(NSString *text) {
    NSUInteger sum = 0; BOOL doubleDigit = NO;
    for (NSUInteger i=text.length; i>0; i--) {
        NSUInteger digit = [text characterAtIndex:i-1] - '0';
        if (doubleDigit) { digit *= 2; if (digit > 9) digit -= 9; }
        sum += digit; doubleDigit = !doubleDigit;
    }
    return sum % 10 == 0;
}
static BOOL LBXMAC(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 17) return NO;
    NSArray *parts = [value componentsSeparatedByString:@":"];
    if (parts.count != 6) return NO;
    NSString *hex=@"0123456789abcdefABCDEF";
    for (NSString *part in parts) if (!LBXCharacters(part,hex,2,2)) return NO;
    unsigned first=(unsigned)strtoul([parts.firstObject UTF8String],NULL,16);
    return !(first & 1) && ![[parts componentsJoinedByString:@""] isEqual:@"000000000000"];
}
static NSArray<NSString *> *LBXIdentifierKeys(void) {
    return @[@"serialNumber",@"udid",@"idfa",@"idfv",@"platformUUID",@"wifiMac",@"bluetoothMac",@"imei",@"meid",@"iccid"];
}
static NSString *LBXInvalidIdentifierField(id value) {
    if (!LBXExactKeys(value,LBXIdentifierKeys())) return @"manualIdentifiers";
    NSString *hex=@"0123456789abcdefABCDEF", *digits=@"0123456789";
    if (!LBXCharacters(value[@"serialNumber"],@"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",10,12)) return @"serialNumber";
    NSString *udid=value[@"udid"];
    if (!LBXText(udid,64,NO)) return @"udid";
    BOOL oldUDID=LBXCharacters(udid,hex,40,40) && LBXNonzero(udid);
    NSArray *udidParts=[udid componentsSeparatedByString:@"-"];
    BOOL modernUDID=udidParts.count==2 && LBXCharacters(udidParts[0],hex,8,8) &&
        LBXCharacters(udidParts[1],hex,16,16) && LBXNonzero([udidParts componentsJoinedByString:@""]);
    if (!oldUDID && !modernUDID) return @"udid";
    for (NSString *key in @[@"idfa",@"idfv",@"platformUUID"]) if (!LBXUUID(value[key])) return key;
    if (!LBXMAC(value[@"wifiMac"])) return @"wifiMac";
    if (!LBXMAC(value[@"bluetoothMac"])) return @"bluetoothMac";
    if (!LBXCharacters(value[@"imei"],digits,15,15) || !LBXNonzero(value[@"imei"]) || !LBXLuhn(value[@"imei"])) return @"imei";
    if (!LBXCharacters(value[@"meid"],hex,14,14) || !LBXNonzero(value[@"meid"])) return @"meid";
    if (!LBXCharacters(value[@"iccid"],digits,19,20) || !LBXNonzero(value[@"iccid"]) || !LBXLuhn(value[@"iccid"])) return @"iccid";
    return nil;
}
static NSDictionary *LBXIdentifiers(id value) {
    if (LBXInvalidIdentifierField(value)) return nil;
    NSMutableDictionary *snapshot=[NSMutableDictionary dictionary];
    for (NSString *key in LBXIdentifierKeys()) snapshot[key]=[value[key] copy];
    return [snapshot copy];
}
static NSArray *LBXApplications(id value) {
    NSArray *allowed=@[@"com.burbn.instagram",@"com.facebook.Facebook",@"com.atebits.Tweetie2"];
    if (![value isKindOfClass:NSArray.class] || ![value count] || [value count]>allowed.count) return nil;
    NSMutableSet *selected=[NSMutableSet set];
    for (id member in value) {
        if (![member isKindOfClass:NSString.class] || ![allowed containsObject:member] || [selected containsObject:member]) return nil;
        [selected addObject:[member copy]];
    }
    NSMutableArray *canonical=[NSMutableArray array];
    for (NSString *member in allowed) if ([selected containsObject:member]) [canonical addObject:member];
    return [canonical copy];
}
BOOL LBXContainerConfigurationValidateChoices(id name,id applications,id manualIdentifiers,id proxyReference) {
    id proxy=proxyReference ?: @"";
    return LBXText(name,80,NO)&&LBXApplications(applications)&&
        (!manualIdentifiers||LBXIdentifiers(manualIdentifiers))&&
        [proxy isKindOfClass:NSString.class]&&(![proxy length]||LBXCanonicalUUID(proxy));
}
NSString *LBXContainerConfigurationInvalidChoiceField(id name,id applications,id manualIdentifiers,id proxyReference) {
    if (!LBXText(name,80,NO)) return @"name";
    if (!LBXApplications(applications)) return @"applications";
    NSString *invalid=manualIdentifiers?LBXInvalidIdentifierField(manualIdentifiers):nil;if(invalid)return invalid;
    id proxy=proxyReference ?: @"";
    if (![proxy isKindOfClass:NSString.class] || ([proxy length]&&!LBXCanonicalUUID(proxy))) return @"proxyReference";
    return nil;
}
static NSString *LBXRandomCharacters(NSString *alphabet, NSUInteger count) {
    NSMutableString *value=[NSMutableString string];
    for (NSUInteger i=0;i<count;i++) [value appendFormat:@"%C",[alphabet characterAtIndex:arc4random_uniform((uint32_t)alphabet.length)]];
    return [value copy];
}
static NSString *LBXRandomMAC(void) {
    uint8_t bytes[6]; arc4random_buf(bytes,sizeof(bytes)); bytes[0]=(bytes[0] | 2) & 0xfe;
    return [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5]];
}
static NSString *LBXCompleteLuhn(NSString *prefix) {
    for (NSUInteger digit=0;digit<10;digit++) {
        NSString *value=[prefix stringByAppendingFormat:@"%lu",(unsigned long)digit];
        if (LBXLuhn(value)) return value;
    }
    return nil;
}
static NSDictionary *LBXRandomIdentifiers(void) {
    return @{@"serialNumber":LBXRandomCharacters(@"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ",12),
        @"udid":[@"1" stringByAppendingString:LBXRandomCharacters(@"0123456789ABCDEF",39)],
        @"idfa":NSUUID.UUID.UUIDString,@"idfv":NSUUID.UUID.UUIDString,@"platformUUID":NSUUID.UUID.UUIDString,
        @"wifiMac":LBXRandomMAC(),@"bluetoothMac":LBXRandomMAC(),
        @"imei":LBXCompleteLuhn([@"35" stringByAppendingString:LBXRandomCharacters(@"0123456789",12)]),
        @"meid":[@"A" stringByAppendingString:LBXRandomCharacters(@"0123456789ABCDEF",13)],
        @"iccid":LBXCompleteLuhn([@"89" stringByAppendingString:LBXRandomCharacters(@"0123456789",16)])};
}

@interface LBXContainerConfiguration ()
- (instancetype)initWithPrivateDictionary:(NSDictionary *)dictionary;
@end
@implementation LBXContainerConfiguration {
    NSDictionary *_privateDictionary;
}
- (instancetype)initWithPrivateDictionary:(NSDictionary *)dictionary {
    if ((self=[super init])) _privateDictionary=[dictionary copy];
    return self;
}
+ (instancetype)fromDictionary:(id)dictionary error:(NSError **)error {
    if (error) *error=nil;
    NSArray *keys=@[@"formatVersion",@"identifier",@"revision",@"name",@"applications",@"identifiers",@"identifierMode",@"proxyReference"];
    if (!LBXExactKeys(dictionary,keys)) return LBXConfigurationFailure(error,@"Configuration fields are invalid");
    uint64_t version=0,revision=0;
    if (!LBXInteger(dictionary[@"formatVersion"],&version) || version!=1 || !LBXInteger(dictionary[@"revision"],&revision))
        return LBXConfigurationFailure(error,@"Configuration version or revision is invalid");
    id proxy=dictionary[@"proxyReference"];
    BOOL proxyValid=[proxy isKindOfClass:NSString.class] && (![proxy length] || LBXCanonicalUUID(proxy));
    if (!LBXCanonicalUUID(dictionary[@"identifier"]) || !LBXText(dictionary[@"name"],80,NO) || !proxyValid)
        return LBXConfigurationFailure(error,@"Configuration text fields are invalid");
    NSArray *applications=LBXApplications(dictionary[@"applications"]);
    NSDictionary *identifiers=LBXIdentifiers(dictionary[@"identifiers"]);
    id mode=dictionary[@"identifierMode"];
    if (!applications || !identifiers || ![mode isKindOfClass:NSString.class] || ![@[@"manual",@"random"] containsObject:mode])
        return LBXConfigurationFailure(error,@"Application selection or identifier fields are invalid");
    NSDictionary *snapshot=@{@"formatVersion":@1,@"identifier":[dictionary[@"identifier"] copy],@"revision":@(revision),
        @"name":[dictionary[@"name"] copy],@"applications":applications,@"identifiers":identifiers,
        @"identifierMode":[mode copy],@"proxyReference":[dictionary[@"proxyReference"] copy]};
    return [[self alloc] initWithPrivateDictionary:snapshot];
}
+ (instancetype)createWithName:(NSString *)name applications:(NSArray<NSString *> *)applications
             manualIdentifiers:(NSDictionary<NSString *,NSString *> *)manualIdentifiers
                proxyReference:(NSString *)proxyReference error:(NSError **)error {
    if (!LBXContainerConfigurationValidateChoices(name,applications,manualIdentifiers,proxyReference))
        return LBXConfigurationFailure(error,@"Creation choices are invalid");
    return [self fromDictionary:@{@"formatVersion":@1,@"identifier":NSUUID.UUID.UUIDString.lowercaseString,@"revision":@1,
        @"name":name,@"applications":applications,@"identifiers":manualIdentifiers ?: LBXRandomIdentifiers(),
        @"identifierMode":manualIdentifiers ? @"manual" : @"random",@"proxyReference":proxyReference ?: @""} error:error];
}
- (LBXContainerConfiguration *)configurationByUpdatingName:(NSString *)name applications:(NSArray<NSString *> *)applications
                                        manualIdentifiers:(NSDictionary<NSString *,NSString *> *)manualIdentifiers
                                           proxyReference:(NSString *)proxyReference error:(NSError **)error {
    if (self.revision >= LLONG_MAX) return LBXConfigurationFailure(error,@"Configuration revision cannot be incremented");
    NSMutableDictionary *draft=[self.privateDictionary mutableCopy]; draft[@"revision"]=@(self.revision+1);
    if (name) draft[@"name"]=name;
    if (applications) draft[@"applications"]=applications;
    if (manualIdentifiers) { draft[@"identifiers"]=manualIdentifiers; draft[@"identifierMode"]=@"manual"; }
    if (proxyReference) draft[@"proxyReference"]=proxyReference;
    return [self.class fromDictionary:draft error:error];
}
- (NSString *)identifier { return _privateDictionary[@"identifier"]; }
- (uint64_t)revision { return [_privateDictionary[@"revision"] unsignedLongLongValue]; }
- (NSString *)name { return _privateDictionary[@"name"]; }
- (NSArray<NSString *> *)applications { return _privateDictionary[@"applications"]; }
- (NSDictionary<NSString *,NSString *> *)identifiers { return _privateDictionary[@"identifiers"]; }
- (NSString *)identifierMode { return _privateDictionary[@"identifierMode"]; }
- (NSString *)proxyReference { return _privateDictionary[@"proxyReference"]; }
- (NSDictionary<NSString *,id> *)privateDictionary { return _privateDictionary; }
- (NSDictionary<NSString *,id> *)safeStatus {
    return @{@"formatVersion":@1,@"revision":@(self.revision),@"applicationCount":@(self.applications.count),
        @"identifierMode":self.identifierMode,@"proxyAssigned":@(self.proxyReference.length>0),
        @"runtimeAccepted":@NO};
}
- (NSString *)description { return [NSString stringWithFormat:@"<LBXContainerConfiguration %@>",self.safeStatus]; }
@end
