#import "LBXNativeFamilyStorageLayout.h"
#import "LBXNativeStorageLayout.h"

static BOOL Fail(NSError **error,NSInteger code){
    if(error)*error=[NSError errorWithDomain:@"com.socialbox.native-family-storage-layout" code:code userInfo:@{NSLocalizedDescriptionKey:
        code==3?@"Instagram and Facebook do not share an admissible container":@"Family storage layout refused"}];
    return NO;
}
static NSDictionary *Immutable(id value){if(![NSJSONSerialization isValidJSONObject:value])return nil;NSData *bytes=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];return bytes.length&&bytes.length<=8*1024*1024?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;}
static BOOL Official(NSString *bundleID){return [bundleID isEqual:@"com.burbn.instagram"]||[bundleID isEqual:@"com.facebook.Facebook"];}
static BOOL CID(NSString *value){return [value isKindOfClass:NSString.class]&&value.length&&value.length<=19&&value.longLongValue>=0&&[value isEqual:[NSString stringWithFormat:@"%lld",value.longLongValue]];}
@interface LBXNativeFamilyStorageLayout ()
- (instancetype)initPrivate:(NSDictionary *)snapshot;
@end
@implementation LBXNativeFamilyStorageLayout {NSDictionary *_snapshot;}
- (instancetype)initPrivate:(NSDictionary *)snapshot {if((self=[super init]))_snapshot=snapshot;return self;}
+ (instancetype)layoutWithInstagram:(LBXNativeStorageLayout *)instagram facebook:(LBXNativeStorageLayout *)facebook error:(NSError **)error {
    if(error)*error=nil;
    if(![instagram isKindOfClass:LBXNativeStorageLayout.class]||![facebook isKindOfClass:LBXNativeStorageLayout.class]){Fail(error,1);return nil;}
    NSDictionary *ig=instagram.privateDictionary,*fb=facebook.privateDictionary;
    if(![ig[@"bundleIdentifier"] isEqual:@"com.burbn.instagram"]||![fb[@"bundleIdentifier"] isEqual:@"com.facebook.Facebook"]){Fail(error,1);return nil;}
    if(!Official(ig[@"bundleIdentifier"])||!Official(fb[@"bundleIdentifier"])){Fail(error,1);return nil;}
    if([ig[@"runtimeAccepted"] isEqual:@YES]||[fb[@"runtimeAccepted"] isEqual:@YES]||[ig[@"brokerIsolationVerified"] isEqual:@YES]||[fb[@"brokerIsolationVerified"] isEqual:@YES]){Fail(error,1);return nil;}
    NSArray *igIDs=ig[@"observedContainerIDs"],*fbIDs=fb[@"observedContainerIDs"];
    if(![igIDs isKindOfClass:NSArray.class]||![fbIDs isKindOfClass:NSArray.class]||!igIDs.count||!fbIDs.count){Fail(error,1);return nil;}
    NSMutableSet *allowed=[NSMutableSet set];
    for(NSString *cid in igIDs)if(CID(cid)&&[fbIDs containsObject:cid])[allowed addObject:cid];
    if(!allowed.count){Fail(error,3);return nil;}
    NSMutableSet *igPaths=[NSMutableSet set],*fbPaths=[NSMutableSet set];
    for(NSDictionary *row in ig[@"protectedNodes"])if([row[@"storagePath"] isKindOfClass:NSString.class])[igPaths addObject:row[@"storagePath"]];
    for(NSDictionary *row in fb[@"protectedNodes"])if([row[@"storagePath"] isKindOfClass:NSString.class])[fbPaths addObject:row[@"storagePath"]];
    NSMutableSet *shared=[igPaths mutableCopy];[shared intersectSet:fbPaths];
    NSArray *ids=[[allowed allObjects] sortedArrayUsingSelector:@selector(compare:)];
    NSDictionary *snapshot=Immutable(@{@"formatVersion":@1,@"kind":@"native-family-storage-layout",@"applications":@[@"com.burbn.instagram",@"com.facebook.Facebook"],
        @"allowedContainerIDs":ids,@"sharedStoragePathCount":@(shared.count),@"runtimeAccepted":@NO,@"brokerIsolationVerified":@NO,@"isolationVerified":@NO});
    if(!snapshot){Fail(error,1);return nil;}
    return [[self alloc] initPrivate:snapshot];
}
- (BOOL)allowsContainerID:(NSString *)containerID error:(NSError **)error {
    if(error)*error=nil;if(!CID(containerID))return Fail(error,1);
    return [_snapshot[@"allowedContainerIDs"] containsObject:containerID]?YES:Fail(error,3);
}
- (NSDictionary *)safeStatus {
    return Immutable(@{@"kind":@"native-family-storage-layout",@"allowedContainerCount":@([_snapshot[@"allowedContainerIDs"] count]),@"sharedStoragePathCount":_snapshot[@"sharedStoragePathCount"],@"runtimeAccepted":@NO,@"brokerIsolationVerified":@NO,@"isolationVerified":@NO})?:@{};
}
- (NSString *)description{return @"<LBXNativeFamilyStorageLayout>";}
- (NSString *)debugDescription{return self.description;}
@end
