#import "LBXNativeManagerBridge.h"
#import "LBXNativeSwitchCoordinator.h"
#import "LBXNativeFamilyStorageLayout.h"
#import "LBXNativeInstalledManagerPin.h"

static NSDictionary *Reply(NSString *result,NSString *reason,uint64_t generation){
    return @{@"result":result,@"reason":reason,@"generation":@(generation),@"invokedOriginalSwitchWorker":@NO,@"isolationVerified":@NO,@"runtimeAccepted":@NO,@"installedSwitchConnected":@NO};
}
static BOOL CID(id value){if(![value isKindOfClass:NSString.class]||![value length]||[value length]>19)return NO;if([value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location!=NSNotFound)return NO;if([value length]>1&&[value hasPrefix:@"0"])return NO;return YES;}
static BOOL Nonce(id value){return [value isKindOfClass:NSString.class]&&[value length]==36&&[value isEqual:[value lowercaseString]]&&[[NSUUID alloc] initWithUUIDString:value]!=nil;}
static BOOL Identity(id value){
    if(![value isKindOfClass:NSDictionary.class]||[value count]!=2)return NO;
    id device=value[@"device"],inode=value[@"inode"];
    return [device isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)device)!=CFBooleanGetTypeID()&&!CFNumberIsFloatType((__bridge CFNumberRef)device)&&[device longLongValue]>=0&&
           [inode isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)inode)!=CFBooleanGetTypeID()&&!CFNumberIsFloatType((__bridge CFNumberRef)inode)&&[inode unsignedLongLongValue]>0;
}
static BOOL Apps(id value){
    if(![value isKindOfClass:NSArray.class]||[value count]!=2)return NO;
    NSSet *set=[NSSet setWithArray:value];
    return set.count==2&&[set containsObject:@"com.burbn.instagram"]&&[set containsObject:@"com.facebook.Facebook"];
}
static BOOL HonestPin(LBXNativeInstalledManagerPin *pin){
    NSDictionary *status=pin.safeStatus;NSArray *operations=status[@"requiredOperations"];
    return [pin isKindOfClass:LBXNativeInstalledManagerPin.class]&&[status isKindOfClass:NSDictionary.class]&&
        [status[@"kind"] isEqual:@"native-installed-manager-pin"]&&[status[@"digestMatched"] isEqual:@YES]&&
        [status[@"identityMatched"] isEqual:@YES]&&[status[@"hookInstalled"] isEqual:@NO]&&
        [status[@"invokedOriginalSwitchWorker"] isEqual:@NO]&&[status[@"installedSwitchConnected"] isEqual:@NO]&&
        [status[@"isolationVerified"] isEqual:@NO]&&[status[@"runtimeAccepted"] isEqual:@NO]&&
        [operations isKindOfClass:NSArray.class]&&operations.count==6;
}
@implementation LBXNativeManagerBridge {uint64_t _generation;BOOL _pinVerified;}
+ (instancetype)bridge {return [[self alloc] initPrivate];}
- (instancetype)initPrivate {return [super init];}
- (NSDictionary *)safeStatus {return @{@"kind":@"native-manager-bridge",@"generation":@(_generation),@"managerPinVerified":@(_pinVerified),@"invokedOriginalSwitchWorker":@NO,@"isolationVerified":@NO,@"installedSwitchConnected":@NO};}
- (NSString *)description{return @"<LBXNativeManagerBridge>";}
- (NSDictionary *)dispatchRequest:(NSDictionary *)request coordinator:(LBXNativeSwitchCoordinator *)coordinator familyLayout:(LBXNativeFamilyStorageLayout *)layout managerPin:(LBXNativeInstalledManagerPin *)pin beforeDeadline:(double)deadline {
    if(![request isKindOfClass:NSDictionary.class]||!coordinator||!layout)return Reply(@"refused",@"invalid-request",_generation);
    if(!HonestPin(pin))return Reply(@"refused",@"manager-pin-required",_generation);
    for(NSString *banned in @[@"path",@"pid",@"command",@"shell",@"executable"])if(request[banned])return Reply(@"refused",@"caller-supplied-capability",_generation);
    NSString *operation=request[@"operation"];
    if(![operation isEqual:@"switch"])return Reply(@"refused",@"unsupported-operation",_generation);
    id generation=request[@"generation"];
    if(![generation isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)generation)==CFBooleanGetTypeID()||CFNumberIsFloatType((__bridge CFNumberRef)generation)||[generation longLongValue]<1||[generation unsignedLongLongValue]!=_generation+1)return Reply(@"refused",@"stale-generation",_generation);
    if(!CID(request[@"containerID"])||!Nonce(request[@"nonce"])||!Identity(request[@"familyGroupIdentity"])||!Apps(request[@"applications"]))return Reply(@"refused",@"invalid-transaction",_generation);
    if(![layout allowsContainerID:request[@"containerID"] error:nil])return Reply(@"refused",@"family-container-not-admitted",_generation);
    NSError *error=nil;
    BOOL ok=[coordinator switchToContainerID:request[@"containerID"] applicationIDs:request[@"applications"] familyGroupIdentity:request[@"familyGroupIdentity"] nonce:request[@"nonce"] beforeDeadline:deadline authorization:^BOOL{return YES;} error:&error];
    if(!ok)return Reply(@"refused",error.domain?@"coordinator-refused":@"coordinator-refused",_generation);
    _generation=[generation unsignedLongLongValue];
    _pinVerified=YES;
    return Reply(@"committed",@"family-switch",_generation);
}
@end
