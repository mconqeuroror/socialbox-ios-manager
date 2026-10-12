#import <Foundation/Foundation.h>
#import "../lucid/Switching/LBXNativeFamilyStorageLayout.h"
#import "../lucid/Switching/LBXNativeStorageLayout.h"
#import "../lucid/Switching/LBXNativeStorageInventory.h"
@implementation LBXNativeStorageInventory
+ (instancetype)recoverFromJournal:(LBXNativeIsolationJournal *)journal error:(NSError **)error {(void)journal;(void)error;return nil;}
- (BOOL)matchesCurrentRegistration:(NSError **)error {(void)error;return NO;}
+ (instancetype)observeOfficialInstagram:(NSError **)error {(void)error;return nil;}
+ (instancetype)observeOfficialFacebook:(NSError **)error {(void)error;return nil;}
- (NSDictionary *)privateDictionary {return @{};}
- (NSDictionary *)safeStatus {return @{};}
@end
static NSUInteger Checks;
static void Check(BOOL ok,NSString *label){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",label.UTF8String);exit(1);}}
static NSMutableDictionary *Node(NSString *parent,NSString *name,NSString *type,NSUInteger inode) {
    return [@{@"name":name,@"path":[parent stringByAppendingPathComponent:name],@"type":type,@"device":@1,
        @"inode":@(inode),@"uid":@501,@"gid":@501,@"mode":@0755,@"flags":@0,@"linkCount":@1} mutableCopy];
}
static NSMutableDictionary *Snapshot(NSString *bundle,NSString *rootName,NSUInteger base,NSArray *cids) {
    NSString *path=[@"/private/test" stringByAppendingPathComponent:rootName];
    NSString *lib=[path stringByAppendingPathComponent:@"Library"];
    NSString *store=[lib stringByAppendingPathComponent:@"___SocialBox_Containers"];
    NSDictionary *root=Node(@"/private/test",rootName,@"directory",base);
    NSDictionary *library=Node(path,@"Library",@"directory",base+1);
    NSDictionary *storeNode=Node(lib,@"___SocialBox_Containers",@"directory",base+2);
    NSMutableArray *profiles=[NSMutableArray array];NSUInteger inode=base+10;
    for(NSString *cid in cids){[profiles addObject:Node(store,cid,@"directory",inode++)];}
    return [@{@"bundleIdentifier":bundle,@"layoutStatus":@"OBSERVED",
        @"owners":@[@{@"dataPath":path,@"groups":@{}}],
        @"storage":@{path:@{@"root":root,@"rootEntries":@[library],@"libraryEntries":@[storeNode],
            @"profileStores":@[@{@"root":storeNode,@"profiles":profiles,@"otherEntries":@[]}],@"layoutIssues":@[]}}} mutableCopy];
}
int main(void){@autoreleasepool{
    LBXNativeStorageLayout *ig=[LBXNativeStorageLayout testLayoutForSnapshot:Snapshot(@"com.burbn.instagram",@"IG",1,@[@"108",@"109"]) error:nil];
    LBXNativeStorageLayout *fb=[LBXNativeStorageLayout testLayoutForSnapshot:Snapshot(@"com.facebook.Facebook",@"FB",20,@[@"109"]) error:nil];
    Check(ig&&fb,@"official Instagram and Facebook layouts");
    Check(![LBXNativeStorageLayout testLayoutForSnapshot:Snapshot(@"com.atebits.Tweetie2",@"TW",40,@[@"1"]) error:nil],@"Twitter layout refused");
    LBXNativeFamilyStorageLayout *family=[LBXNativeFamilyStorageLayout layoutWithInstagram:ig facebook:fb error:nil];
    Check(family&&[family.safeStatus[@"allowedContainerCount"] isEqual:@2],@"family allows 0 and shared 109");
    Check([family allowsContainerID:@"0" error:nil]&&[family allowsContainerID:@"109" error:nil],@"default and shared 109 admitted");
    NSError *split=nil;Check(![family allowsContainerID:@"108" error:&split]&&split.code==3,@"Instagram-only 108 cannot be a family CID");
    Check(![family.safeStatus[@"isolationVerified"] boolValue]&&![family.safeStatus[@"runtimeAccepted"] boolValue],@"family layout never claims isolation");
    Check(![LBXNativeFamilyStorageLayout layoutWithInstagram:fb facebook:ig error:nil],@"swapped official roles refused");
    LBXNativeStorageLayout *otherFB=[LBXNativeStorageLayout testLayoutForSnapshot:Snapshot(@"com.facebook.Facebook",@"FB2",30,@[@"200"]) error:nil];
    LBXNativeFamilyStorageLayout *defaults=[LBXNativeFamilyStorageLayout layoutWithInstagram:ig facebook:otherFB error:nil];
    Check(defaults&&[defaults allowsContainerID:@"0" error:nil]&&![defaults allowsContainerID:@"109" error:nil]&&![defaults allowsContainerID:@"200" error:nil],@"disjoint profiles collapse to default-only family CID");
    printf("PASS: %lu native family storage layout assertions\n",(unsigned long)Checks);return 0;
}}
