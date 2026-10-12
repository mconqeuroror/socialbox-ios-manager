#import <Foundation/Foundation.h>
#import "../lucid/Switching/LBXNativeStorageLayout.h"
#import "../lucid/Switching/LBXNativeStorageInventory.h"
// No device API or permission mutation in this layout fixture.
@implementation LBXNativeStorageInventory
+ (instancetype)recoverFromJournal:(LBXNativeIsolationJournal *)journal error:(NSError **)error {(void)journal;(void)error;return nil;}
- (BOOL)matchesCurrentRegistration:(NSError **)error {(void)error;return NO;}
+ (instancetype)observeOfficialInstagram:(NSError **)error {(void)error;return nil;}
+ (instancetype)observeOfficialFacebook:(NSError **)error {(void)error;return nil;}
- (NSDictionary *)privateDictionary {return @{};}
- (NSDictionary *)safeStatus {return @{};}
@end
static NSUInteger checks;
#define CHECK(...) do {checks++;if(!(__VA_ARGS__)){fprintf(stderr,"FAIL line %d\n",__LINE__);exit(1);}}while(0)
static NSMutableDictionary *Node(NSString *parent,NSString *name,NSString *type,NSUInteger inode) {
    return [@{@"name":name,@"path":[parent stringByAppendingPathComponent:name],@"type":type,@"device":@1,
        @"inode":@(inode),@"uid":@501,@"gid":@501,@"mode":@0755,@"flags":@0,@"linkCount":@1} mutableCopy];
}
static NSMutableDictionary *Fixture(void) {
    NSString *path=@"/private/test/A", *lib=[path stringByAppendingPathComponent:@"Library"],*store=[lib stringByAppendingPathComponent:@"___SocialBox_Containers"];
    NSDictionary *root=Node(@"/private/test",@"A",@"directory",1), *library=Node(path,@"Library",@"directory",2),
        *storeNode=Node(lib,@"___SocialBox_Containers",@"directory",3),*a=Node(store,@"108",@"directory",4),*b=Node(store,@"109",@"directory",5);
    return [@{@"bundleIdentifier":@"com.burbn.instagram",@"layoutStatus":@"OBSERVED",
        @"owners":@[@{@"dataPath":path,@"groups":@{}}],
        @"storage":@{path:@{@"root":root,@"rootEntries":@[library,Node(path,@"Documents",@"directory",6),Node(path,@"state",@"regular",7)],
            @"libraryEntries":@[storeNode,Node(lib,@"Preferences",@"directory",8)],
            @"profileStores":@[@{@"root":storeNode,@"profiles":@[a,b],@"otherEntries":@[]}],@"layoutIssues":@[]}}} mutableCopy];
}
static NSMutableDictionary *Copy(id value) {NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];}
static id Layout(id value) {return [LBXNativeStorageLayout testLayoutForSnapshot:value error:nil];}
int main(void) {@autoreleasepool {
    NSMutableDictionary *base=Fixture();LBXNativeStorageLayout *layout=Layout(base);CHECK(layout);
    CHECK([layout.safeStatus[@"protectedNodeCount"] isEqual:@5]);CHECK([layout.safeStatus[@"regularFileCount"] isEqual:@1]);
    CHECK([layout.safeStatus[@"namespaceCount"] isEqual:@3]);CHECK([layout.safeStatus[@"defaultEntriesIncluded"] boolValue]);
    CHECK(![layout.safeStatus[@"runtimeAccepted"] boolValue]);CHECK(![layout.safeStatus[@"brokerIsolationVerified"] boolValue]);
    NSDictionary *snapshot=layout.privateDictionary;CHECK([snapshot[@"observedContainerIDs"] isEqual:@[@"0",@"108",@"109"]]);
    NSMutableSet *paths=[NSMutableSet set];NSUInteger zero=0;
    for(NSDictionary *entry in snapshot[@"protectedNodes"]){[paths addObject:entry[@"node"][@"path"]];zero += [entry[@"containerID"] isEqual:@"0"];}
    CHECK(zero==3);CHECK(paths.count==5);CHECK(![paths containsObject:@"/private/test/A/Library"]);
    // The result is an immutable snapshot; changing input cannot change policy.
    base[@"layoutStatus"]=@"REJECTED";CHECK([layout.safeStatus[@"protectedNodeCount"] isEqual:@5]);CHECK(!Layout(base));
    for(NSString *bad in @[@"0",@"01",@"-1",@"1x",@"9223372036854775808",@"",@"../1"]){
        NSMutableDictionary *x=Copy(Fixture());NSMutableDictionary *scope=x[@"storage"][@"/private/test/A"],*store=scope[@"profileStores"][0],*node=store[@"profiles"][0];
        node[@"name"]=bad;node[@"path"]=[store[@"root"][@"path"] stringByAppendingPathComponent:bad];CHECK(!Layout(x));
    }
    for(NSString *type in @[@"symlink",@"other"]){NSMutableDictionary *x=Copy(Fixture());x[@"storage"][@"/private/test/A"][@"rootEntries"][1][@"type"]=type;CHECK(!Layout(x));}
    NSMutableDictionary *x=Copy(Fixture());x[@"storage"][@"/private/test/A"][@"rootEntries"][2][@"linkCount"]=@2;CHECK(!Layout(x));
    x=Copy(Fixture());x[@"storage"][@"/private/test/A"][@"rootEntries"][2][@"inode"]=@6;CHECK(!Layout(x));
    x=Copy(Fixture());x[@"storage"][@"/private/test/A"][@"rootEntries"][2][@"mode"]=@YES;CHECK(!Layout(x));
    x=Copy(Fixture());x[@"storage"][@"/private/test/A"][@"rootEntries"][2][@"path"]=@"/private/test/B/state";CHECK(!Layout(x));
    x=Copy(Fixture());x[@"storage"][@"/private/test/A"][@"profileStores"][0][@"otherEntries"]=@[@{}];CHECK(!Layout(x));
    x=Copy(Fixture());x[@"owners"][0][@"groups"]=@{@"group.example":@"/private/test/unknown"};CHECK(!Layout(x));
    // An extension/group with no numbered store stays explicit default-only;
    // it must never be silently assigned to the selected nonzero container.
    x=Copy(Fixture());NSMutableDictionary *scope=x[@"storage"][@"/private/test/A"];
    scope[@"profileStores"]=@[];scope[@"libraryEntries"]=@[scope[@"libraryEntries"][1]];
    layout=Layout(x);CHECK(layout);CHECK([layout.safeStatus[@"defaultOnlyStorageCount"] isEqual:@1]);
    CHECK([layout.privateDictionary[@"observedContainerIDs"] isEqual:@[@"0"]]);
    printf("PASS %lu native storage layout checks\n",(unsigned long)checks);return 0;
}}
