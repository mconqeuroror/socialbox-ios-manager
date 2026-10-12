#import "LBXContainerIdentitySpecification.h"
#import "LBXContainerConfiguration.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <limits.h>
#include <string.h>

static id Failure(NSError **error,NSInteger code) {
    if(error)*error=[NSError errorWithDomain:@"com.socialbox.container-identity-specification" code:code
        userInfo:@{NSLocalizedDescriptionKey:code==2?@"Trusted physical context is unavailable":
            code==3?@"Identity reservation aliases repeat":@"Identity specification is invalid"}];
    return nil;
}
static BOOL Exact(id value,NSArray *keys) {
    if(![value isKindOfClass:NSDictionary.class]||[value count]!=keys.count)return NO;
    for(id key in value)if(![key isKindOfClass:NSString.class])return NO;
    return [[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]];
}
static BOOL Integer(id value,BOOL zeroAllowed) {
    if(![value isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()||
        CFNumberIsFloatType((__bridge CFNumberRef)value))return NO;
    const char *type=[value objCType];
    return type&&strchr("cislqCISLQ",type[0])&&!type[1]&&[value longLongValue]>=(zeroAllowed?0:1)&&
        [value unsignedLongLongValue]<=LLONG_MAX;
}
static NSData *CanonicalJSON(id value) {
    if(![NSJSONSerialization isValidJSONObject:value])return nil;
    return [NSJSONSerialization dataWithJSONObject:value
        options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:nil];
}
static id Snapshot(id value) {
    NSData *data=CanonicalJSON(value);if(!data.length||data.length>32768)return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}
static NSString *Digest(NSDictionary *configuration) {
    NSData *data=CanonicalJSON(configuration);if(!data.length||data.length>16384)return nil;
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);
    char hex[65];for(unsigned i=0;i<sizeof(bytes);i++)snprintf(hex+i*2,3,"%02x",bytes[i]);
    return [NSString stringWithUTF8String:hex];
}
static BOOL Fact(id value) {
    return [value isKindOfClass:NSString.class]&&[value length]>0&&[value length]<=128&&
        [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.,_-"] invertedSet]].location==NSNotFound;
}
static NSDictionary *Physical(id context) {
    if(!Exact(context,@[@"machine",@"model",@"osBuild",@"osRelease",@"memoryBytes",@"osVersion"]))return nil;
    for(NSString *key in @[@"machine",@"model",@"osBuild",@"osRelease"])if(!Fact(context[key]))return nil;
    if(!Integer(context[@"memoryBytes"],NO))return nil;
    id version=context[@"osVersion"];
    if(!Exact(version,@[@"major",@"minor",@"patch"])||!Integer(version[@"major"],NO)||
        !Integer(version[@"minor"],YES)||!Integer(version[@"patch"],YES))return nil;
    for(NSString *key in version)if([version[key] unsignedLongLongValue]>INT_MAX)return nil;
    return Snapshot(context);
}
static NSDictionary *Relationships(void) {
    return @{@"applicability":@"UNVERIFIED",@"manufacturer":@"UNVERIFIED",@"TAC":@"UNVERIFIED",
        @"operator":@"UNVERIFIED",@"advertising":@"UNVERIFIED"};
}
static NSDictionary *Reservations(NSDictionary *configuration) {
    NSDictionary *values=configuration[@"identifiers"];NSMutableDictionary *result=[NSMutableDictionary dictionary];
    NSDictionary *namespaces=@{@"serialNumber":@"serial",@"udid":@"udid",@"idfa":@"uuid",@"idfv":@"uuid",
        @"platformUUID":@"uuid",@"wifiMac":@"mac",@"bluetoothMac":@"mac",@"imei":@"imei",@"meid":@"meid",@"iccid":@"iccid"};
    NSMutableSet *seen=[NSMutableSet set];
    for(NSString *field in namespaces) {
        NSString *normalized=[values[field] lowercaseString];
        NSString *key=[NSString stringWithFormat:@"%@:%@",namespaces[field],normalized];
        if([seen containsObject:key])return nil;[seen addObject:key];result[field]=key;
    }
    return [result copy];
}
static NSString *ObserveString(const char *name) {
    char buffer[256]={0};size_t length=sizeof(buffer);
    if(sysctlbyname(name,buffer,&length,NULL,0)||!length||length>sizeof(buffer)||buffer[length-1]!=0||
        strnlen(buffer,length)!=length-1)return nil;
    return [[NSString alloc] initWithBytes:buffer length:length-1 encoding:NSUTF8StringEncoding];
}
static NSDictionary *ObservePhysicalContext(void) {
    if(getuid()!=0||geteuid()!=0)return nil;
    NSString *machine=ObserveString("hw.machine"),*model=ObserveString("hw.model");
    NSString *build=ObserveString("kern.osversion"),*release=ObserveString("kern.osrelease");
    uint64_t memory=0;size_t length=sizeof(memory);
    if(!machine||!model||!build||!release||sysctlbyname("hw.memsize",&memory,&length,NULL,0)||length!=sizeof(memory)||!memory||memory>LLONG_MAX)return nil;
    NSOperatingSystemVersion version=NSProcessInfo.processInfo.operatingSystemVersion;
    return Physical(@{@"machine":machine,@"model":model,@"osBuild":build,@"osRelease":release,@"memoryBytes":@(memory),
        @"osVersion":@{@"major":@(version.majorVersion),@"minor":@(version.minorVersion),@"patch":@(version.patchVersion)}});
}
#if LBX_CONTAINER_IDENTITY_SPECIFICATION_TESTING
static NSDictionary *TestPhysicalContext;
#endif
@interface LBXContainerIdentitySpecification ()
- (instancetype)initWithSnapshot:(NSDictionary *)snapshot reservations:(NSDictionary *)reservations;
+ (instancetype)specificationWithConfiguration:(LBXContainerConfiguration *)configuration physicalContext:(id)context error:(NSError **)error;
@end
@implementation LBXContainerIdentitySpecification {
    NSDictionary *_snapshot,*_reservations;
}
- (instancetype)initWithSnapshot:(NSDictionary *)snapshot reservations:(NSDictionary *)reservations {
    if((self=[super init])){_snapshot=snapshot;_reservations=[reservations copy];}return self;
}
+ (instancetype)specificationWithConfiguration:(LBXContainerConfiguration *)configuration physicalContext:(id)context error:(NSError **)error {
    if(error)*error=nil;
    if(![configuration isKindOfClass:LBXContainerConfiguration.class])return Failure(error,1);
    LBXContainerConfiguration *validated=[LBXContainerConfiguration fromDictionary:configuration.privateDictionary error:nil];
    if(!validated||![validated.privateDictionary isEqual:configuration.privateDictionary])return Failure(error,1);
    NSDictionary *physical=Physical(context);if(!physical)return Failure(error,2);
    NSString *digest=Digest(validated.privateDictionary);if(!digest)return Failure(error,1);
    return [self fromDictionary:@{@"formatVersion":@1,@"configuration":validated.privateDictionary,
        @"configurationSHA256":digest,@"physicalContext":physical,
        @"relationships":Relationships(),@"runtimeAccepted":@NO} error:error];
}
+ (instancetype)createWithConfiguration:(LBXContainerConfiguration *)configuration error:(NSError **)error {
    NSDictionary *physical=nil;
#if LBX_CONTAINER_IDENTITY_SPECIFICATION_TESTING
    @synchronized(self){physical=TestPhysicalContext;}
#endif
    if(!physical)physical=ObservePhysicalContext();
    if(!physical){if(error)*error=nil;return Failure(error,2);}
    return [self specificationWithConfiguration:configuration physicalContext:physical error:error];
}
+ (instancetype)fromDictionary:(id)dictionary error:(NSError **)error {
    if(error)*error=nil;
    if(!Exact(dictionary,@[@"formatVersion",@"configuration",@"configurationSHA256",@"physicalContext",@"relationships",@"runtimeAccepted"])||
        !Integer(dictionary[@"formatVersion"],NO)||![dictionary[@"formatVersion"] isEqual:@1]||
        ![dictionary[@"runtimeAccepted"] isKindOfClass:NSNumber.class]||
        CFGetTypeID((__bridge CFTypeRef)dictionary[@"runtimeAccepted"])!=CFBooleanGetTypeID()||[dictionary[@"runtimeAccepted"] boolValue]||
        ![dictionary[@"relationships"] isEqual:Relationships()])return Failure(error,1);
    LBXContainerConfiguration *configuration=[LBXContainerConfiguration fromDictionary:dictionary[@"configuration"] error:nil];
    if(!configuration||![configuration.privateDictionary isEqual:dictionary[@"configuration"]])return Failure(error,1);
    NSDictionary *physical=Physical(dictionary[@"physicalContext"]);if(!physical)return Failure(error,2);
    NSString *digest=Digest(configuration.privateDictionary);
    if(!digest||![dictionary[@"configurationSHA256"] isKindOfClass:NSString.class]||![dictionary[@"configurationSHA256"] isEqual:digest])return Failure(error,1);
    NSDictionary *reservations=Reservations(configuration.privateDictionary);if(!reservations)return Failure(error,3);
    NSDictionary *snapshot=Snapshot(dictionary);if(!snapshot)return Failure(error,1);
    return [[self alloc] initWithSnapshot:snapshot reservations:reservations];
}
- (NSDictionary *)privateDictionary {return _snapshot;}
- (NSString *)configurationIdentifier {return _snapshot[@"configuration"][@"identifier"];}
- (uint64_t)configurationRevision {return [_snapshot[@"configuration"][@"revision"] unsignedLongLongValue];}
- (NSString *)configurationSHA256 {return _snapshot[@"configurationSHA256"];}
- (NSDictionary *)reservationKeys {return _reservations;}
- (NSDictionary *)physicalContext {return _snapshot[@"physicalContext"];}
- (NSDictionary *)safeStatus {return @{@"formatVersion":@1,@"configurationRevision":@(self.configurationRevision),
    @"identifierCount":@10,@"physicalContextRecorded":@YES,@"relationships":@"UNVERIFIED",@"runtimeAccepted":@NO};}
- (NSString *)description {return [NSString stringWithFormat:@"<LBXContainerIdentitySpecification %@>",self.safeStatus];}
- (NSString *)debugDescription {return self.description;}
#if LBX_CONTAINER_IDENTITY_SPECIFICATION_TESTING
+ (void)testUsePhysicalContext:(NSDictionary *)context {@synchronized(self){TestPhysicalContext=context?Snapshot(context):nil;}}
+ (instancetype)testCreateWithConfiguration:(LBXContainerConfiguration *)configuration physicalContext:(id)context error:(NSError **)error {
    return [self specificationWithConfiguration:configuration physicalContext:context error:error];
}
#endif
@end
