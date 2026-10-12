#import "LBXNativeControlStore.h"
#import "LBXNativeIsolationJournal.h"
#include <mach/mach_time.h>
#include <math.h>
#ifndef LBX_NATIVE_CONTROL_STORE_TESTING
#define LBX_NATIVE_CONTROL_STORE_TESTING 0
#endif

static NSString *const Instagram=@"com.burbn.instagram";
static NSString *const Facebook=@"com.facebook.Facebook";
double LBXNativeControlClock(void){mach_timebase_info_data_t scale;mach_timebase_info(&scale);return scale.denom?(double)mach_continuous_time()*scale.numer/scale.denom/1e9:NAN;}
static BOOL Fail(NSError **error,NSInteger code){
    if(error)*error=[NSError errorWithDomain:@"com.socialbox.native-control-store" code:code userInfo:@{NSLocalizedDescriptionKey:
        code==2?@"Root control journal is required":code==3?@"Shared family group already admits a different container":code==5?@"Control store deadline exceeded":@"Native control selection refused"}];
    return NO;
}
static BOOL Budget(double deadline){double now=LBXNativeControlClock();return isfinite(now)&&isfinite(deadline)&&deadline>now&&deadline-now<=120;}
static NSDictionary *Immutable(id value){if(![NSJSONSerialization isValidJSONObject:value])return nil;NSData *bytes=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];return bytes.length&&bytes.length<=8*1024*1024?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;}
static BOOL AppID(NSString *value){return [value isEqual:Instagram]||[value isEqual:Facebook];}
static BOOL CID(NSString *value){if(![value isKindOfClass:NSString.class]||!value.length||value.length>19)return NO;if([value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location!=NSNotFound)return NO;if(value.length>1&&[value hasPrefix:@"0"])return NO;return YES;}
static BOOL Identity(NSDictionary *value){
    if(![value isKindOfClass:NSDictionary.class]||value.count!=2)return NO;
    id device=value[@"device"],inode=value[@"inode"];
    return [device isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)device)!=CFBooleanGetTypeID()&&!CFNumberIsFloatType((__bridge CFNumberRef)device)&&[device longLongValue]>=0&&
           [inode isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)inode)!=CFBooleanGetTypeID()&&!CFNumberIsFloatType((__bridge CFNumberRef)inode)&&[inode unsignedLongLongValue]>0;
}
@interface LBXNativeControlStore ()
@property(nonatomic,strong)LBXNativeIsolationJournal *journal;
@property(nonatomic,copy)NSDictionary *envelope;
@property(nonatomic)BOOL testing;
@end
@implementation LBXNativeControlStore
- (instancetype)initPrivate{return [super init];}
- (NSDictionary *)payload{NSDictionary *body=_envelope[@"payload"];return [body isKindOfClass:NSDictionary.class]?body:nil;}
- (NSDictionary *)safeStatus{
    @synchronized(self){NSDictionary *apps=[self payload][@"applications"];NSUInteger selected=0;for(NSString *app in @[Instagram,Facebook])if([apps[app] isKindOfClass:NSDictionary.class]&&CID(apps[app][@"containerID"]))selected++;
        return Immutable(@{@"kind":@"native-control-store",@"selectedApplicationCount":@(selected),@"familyConflict":@NO,@"runtimeAccepted":@NO,@"isolationVerified":@NO})?:@{};}
}
- (NSString *)description{return @"<LBXNativeControlStore>";}
- (NSString *)debugDescription{return self.description;}
- (BOOL)writePayload:(NSDictionary *)payload error:(NSError **)error {
    NSDictionary *frozen=Immutable(payload);if(!frozen)return Fail(error,1);
    if(![_journal compareRecord:_envelope replaceWith:frozen error:error])return NO;
    _envelope=_journal.currentRecord;return _envelope!=nil;
}
static NSDictionary *EmptyApps(void){
    NSDictionary *blank=@{@"containerID":[NSNull null],@"familyGroupIdentity":[NSNull null]};
    return @{Instagram:blank,Facebook:blank};
}
static LBXNativeControlStore *Open(LBXNativeIsolationJournal *journal,BOOL testing,NSError **error){
    if(error)*error=nil;if(!journal){Fail(error,2);return nil;}NSError *readError=nil;NSDictionary *current=[journal validatedCurrentRecord:&readError];if(readError){if(error)*error=readError;return nil;}
    if(!current){
        NSDictionary *payload=Immutable(@{@"kind":@"native-control-store",@"formatVersion":@1,@"applications":EmptyApps()});
        if(!payload||![journal compareRecord:nil replaceWith:payload error:error])return nil;current=journal.currentRecord;
    }
    NSDictionary *body=current[@"payload"],*apps=body[@"applications"];
    if(![body[@"kind"] isEqual:@"native-control-store"]||![body[@"formatVersion"] isEqual:@1]||![apps isKindOfClass:NSDictionary.class]||apps.count!=2||!apps[Instagram]||!apps[Facebook]){Fail(error,1);return nil;}
    LBXNativeControlStore *store=[[LBXNativeControlStore alloc] initPrivate];store.journal=journal;store.envelope=current;store.testing=testing;return store;
}
+ (instancetype)openJournal:(LBXNativeIsolationJournal *)journal error:(NSError **)error {return Open(journal,NO,error);}
#if LBX_NATIVE_CONTROL_STORE_TESTING
+ (instancetype)testOpenJournal:(LBXNativeIsolationJournal *)journal error:(NSError **)error {return Open(journal,YES,error);}
#endif
- (NSString *)selectedContainerIDForApplication:(NSString *)applicationID error:(NSError **)error {
    @synchronized(self){if(error)*error=nil;if(!AppID(applicationID)){Fail(error,1);return nil;}id value=[self payload][@"applications"][applicationID][@"containerID"];return CID(value)?value:nil;}
}
- (BOOL)commitContainerID:(NSString *)containerID applicationID:(NSString *)applicationID familyGroupIdentity:(NSDictionary *)identity beforeDeadline:(double)deadline authorization:(BOOL (^)(void))authorization error:(NSError **)error {
    if(!AppID(applicationID))return Fail(error,1);
    return [self commitContainerID:containerID applicationIDs:@[applicationID] familyGroupIdentity:identity beforeDeadline:deadline authorization:authorization error:error];
}
- (BOOL)commitContainerID:(NSString *)containerID applicationIDs:(NSArray<NSString *> *)applicationIDs familyGroupIdentity:(NSDictionary *)identity beforeDeadline:(double)deadline authorization:(BOOL (^)(void))authorization error:(NSError **)error {
    @synchronized(self){
        if(error)*error=nil;if(!Budget(deadline))return Fail(error,5);if(!CID(containerID)||!Identity(identity)||![applicationIDs isKindOfClass:NSArray.class]||!applicationIDs.count||applicationIDs.count>2)return Fail(error,1);
        NSMutableSet *seen=[NSMutableSet set];for(NSString *app in applicationIDs){if(!AppID(app)||[seen containsObject:app])return Fail(error,1);[seen addObject:app];}
        NSDictionary *payload=[self payload];NSMutableDictionary *apps=[payload[@"applications"] mutableCopy];NSDictionary *group=Immutable(identity);
        for(NSString *app in @[Instagram,Facebook]){
            if([seen containsObject:app])continue;
            NSDictionary *peer=apps[app];id peerCID=peer[@"containerID"],peerGroup=peer[@"familyGroupIdentity"];
            if(CID(peerCID)&&[peerGroup isKindOfClass:NSDictionary.class]&&[Immutable(peerGroup) isEqual:group]&&![peerCID isEqual:containerID])return Fail(error,3);
        }
        if(!authorization||!authorization())return Fail(error,1);
        NSDictionary *row=Immutable(@{@"containerID":containerID,@"familyGroupIdentity":identity});if(!row)return Fail(error,1);
        for(NSString *app in seen)apps[app]=row;
        return [self writePayload:@{@"kind":@"native-control-store",@"formatVersion":@1,@"applications":apps} error:error];
    }
}
@end
