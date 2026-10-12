#define main SharedWriterProbeUnusedMain
#import "../lucid/Switching/SharedGroupWriterProbe.m"
#undef main
@interface WriterFixtureProxy:NSObject
@property NSString *bundleIdentifier;
@property NSURL *bundleURL;
@property NSDictionary *groupContainerURLs;
@property NSDictionary *entitlements;
@end
@implementation WriterFixtureProxy
@end
@interface WrongWriterFixture:NSObject
@property BOOL called;
- (NSInteger)entitlements;
@end
@implementation WrongWriterFixture
- (NSInteger)entitlements {self.called=YES;return 7;}
@end
static NSUInteger Checks;
static void Check(BOOL good,NSString *label){Checks++;if(!good){fprintf(stderr,"FAIL: %s\n",label.UTF8String);exit(1);}}
int main(void){@autoreleasepool{
    NSString *group=@"group.fixture.family",*root=@"/private/var/mobile/Containers/Shared/AppGroup/00000000-0000-0000-0000-000000000001";
    NSDictionary *targets=@{group:root};WriterFixtureProxy *p=[WriterFixtureProxy new];p.bundleIdentifier=@"com.fixture.app";p.bundleURL=[NSURL fileURLWithPath:@"/private/fixture/Application.app"];p.groupContainerURLs=@{group:[NSURL fileURLWithPath:root]};p.entitlements=@{@"com.apple.security.application-groups":@[group]};
    NSDictionary *owner=Owner(p,nil,nil,targets,@{});Check([owner[@"targetGroups"] count]==1&&[owner[@"issues"] count]==0,@"exact declared and registered target overlap captured");
    p.groupContainerURLs=@{};owner=Owner(p,nil,nil,targets,@{});Check([owner[@"declaredTargetGroups"] count]==1&&[owner[@"issues"] containsObject:@"TARGET_DECLARED_REGISTERED_GROUPS_MISMATCH"],@"declared writer missing registered root remains unresolved");
    p.groupContainerURLs=@{group:[NSURL fileURLWithPath:@"/private/other"]};Check([Owner(p,nil,nil,targets,@{})[@"issues"] containsObject:@"TARGET_GROUP_PATH_MISMATCH"],@"same group identifier different registered path refused");
    p.groupContainerURLs=nil;Check([Owner(p,nil,nil,targets,@{})[@"issues"] containsObject:@"GROUP_REGISTRATION_UNAVAILABLE"],@"nil registrations never become empty group proof");
    p.groupContainerURLs=@{};p.entitlements=nil;Check([Owner(p,nil,nil,targets,@{})[@"issues"] containsObject:@"GROUP_DECLARATIONS_UNAVAILABLE"],@"missing entitlement declaration remains unknown");
    p.entitlements=@{};Check([Owner(p,nil,nil,targets,@{})[@"issues"] count]==0&&[Owner(p,nil,nil,targets,@{})[@"targetGroups"] count]==0,@"valid explicit empty maps establish no registered target overlap");
    p.entitlements=@{@"com.apple.security.application-groups":@[group,group]};Check([Owner(p,nil,nil,targets,@{})[@"issues"] containsObject:@"GROUP_DECLARATIONS_MALFORMED"],@"duplicate declarations refused");
    p.entitlements=@{};p.bundleIdentifier=@"com.fixture.app.extension";p.bundleURL=[NSURL fileURLWithPath:@"/private/fixture/Application.app/PlugIns/Share.appex"];Check([Owner(p,@"com.fixture.app",@"/private/fixture/Application.app",targets,@{})[@"issues"] count]==0,@"extension binds exact containing app path");
    p.bundleURL=[NSURL fileURLWithPath:@"/private/other/Share.appex"];Check([Owner(p,@"com.fixture.app",@"/private/fixture/Application.app",targets,@{})[@"issues"] containsObject:@"EXTENSION_PARENT_BINDING_MISMATCH"],@"foreign extension cannot borrow app owner relationship");
    NSString *store=[root stringByAppendingPathComponent:@"Library/___SocialBox_Containers"],*profile=[store stringByAppendingPathComponent:@"109"];
    NSDictionary *rootNode=@{@"path":root,@"type":@"directory",@"device":@1,@"inode":@10},*storeNode=@{@"name":@"___SocialBox_Containers",@"path":store,@"type":@"directory",@"device":@1,@"inode":@11},*profileNode=@{@"name":@"109",@"path":profile,@"type":@"directory",@"device":@1,@"inode":@12};
    NSMutableDictionary *entry=[@{@"root":storeNode,@"profiles":@[profileNode],@"otherEntries":@[]} mutableCopy];NSMutableDictionary *row=[@{@"root":rootNode,@"profileStores":@[entry],@"layoutIssues":@[]} mutableCopy];
    NSDictionary *snapshot=@{@"groupRegistrations":targets,@"storage":@{root:row}},*aliases=ProfileAliases(snapshot);
    Check([aliases[group][profile][@"profileNode"] isEqual:profileNode]&&![aliases[group][profile][@"launchAuthority"] boolValue],@"only exact observed profile node becomes non-authorizing alias");
    p.bundleIdentifier=@"com.fixture.app";p.bundleURL=[NSURL fileURLWithPath:@"/private/fixture/Application.app"];p.entitlements=@{@"com.apple.security.application-groups":@[group]};p.groupContainerURLs=@{group:[NSURL fileURLWithPath:profile]};
    owner=Owner(p,nil,nil,targets,aliases);Check(![owner[@"issues"] count]&&[owner[@"targetGroups"][group] isEqual:profile]&&[owner[@"targetGroupResolutions"][group][@"containerID"] isEqual:@"109"],@"registered observed subgroup remains explicit writer with exact CID and raw registered path");
    p.groupContainerURLs=@{group:[NSURL fileURLWithPath:[store stringByAppendingPathComponent:@"110"]]};Check([Owner(p,nil,nil,targets,aliases)[@"issues"] containsObject:@"TARGET_GROUP_PATH_MISMATCH"],@"unobserved sibling cannot be accepted by prefix");
    p.groupContainerURLs=@{group:[NSURL fileURLWithPath:[profile stringByAppendingPathComponent:@"Documents"]]};Check([Owner(p,nil,nil,targets,aliases)[@"issues"] containsObject:@"TARGET_GROUP_PATH_MISMATCH"],@"descendant of observed profile is not profile alias");
    NSMutableDictionary *badNode=[profileNode mutableCopy];badNode[@"type"]=@"symlink";entry[@"profiles"]=@[badNode];Check(ProfileAliases(snapshot)==nil,@"symlink profile never classifies as observed directory");
    badNode=[profileNode mutableCopy];badNode[@"path"]=@"/private/foreign/109";entry[@"profiles"]=@[badNode];Check(ProfileAliases(snapshot)==nil,@"outside profile rejected even if CID matches");
    entry[@"profiles"]=@[profileNode,profileNode];Check(ProfileAliases(snapshot)==nil,@"duplicate profile alias rejected");
    entry[@"profiles"]=@[profileNode];entry[@"otherEntries"]=@[@{}];Check(ProfileAliases(snapshot)==nil,@"unknown native store nodes refuse alias classification");entry[@"otherEntries"]=@[];
    row[@"layoutIssues"]=@[@"UNKNOWN"];Check(ProfileAliases(snapshot)==nil,@"unresolved native layout refuses alias classification");row[@"layoutIssues"]=@[];
    p.bundleIdentifier=@"com.apple.fixture.extension";p.bundleURL=[NSURL fileURLWithPath:@"/Applications/Fixture.app/Extensions/Share.appex"];p.groupContainerURLs=@{};p.entitlements=@{};
    owner=Owner(p,@"com.apple.fixture",@"/Applications/Fixture.app",targets,aliases);Check(![owner[@"issues"] count]&&[owner[@"extensionLayout"] isEqual:@"SYSTEM_EXTENSIONS_NONOVERLAP_ONLY"],@"exact Apple Extensions owner with explicit non-overlap classified");
    p.entitlements=@{@"com.apple.security.application-groups":@[group]};p.groupContainerURLs=@{group:[NSURL fileURLWithPath:root]};Check([Owner(p,@"com.apple.fixture",@"/Applications/Fixture.app",targets,aliases)[@"issues"] containsObject:@"SYSTEM_EXTENSIONS_TARGET_SCOPE_UNRESOLVED"],@"Apple Extensions exception cannot grant target writer authority");
    p.groupContainerURLs=nil;p.entitlements=@{};Check([Owner(p,@"com.apple.fixture",@"/Applications/Fixture.app",targets,aliases)[@"issues"] containsObject:@"SYSTEM_EXTENSIONS_TARGET_SCOPE_UNRESOLVED"],@"unavailable Apple group map cannot become non-overlap");
    p.groupContainerURLs=@{};p.bundleIdentifier=@"com.fixture.app.extension";Check([Owner(p,@"com.fixture.app",@"/Applications/Fixture.app",targets,aliases)[@"issues"] containsObject:@"EXTENSION_PARENT_BINDING_MISMATCH"],@"third-party Extensions layout remains unverified");
    WrongWriterFixture *wrong=[WrongWriterFixture new];BOOL available=YES;Check(Get(wrong,@"entitlements",&available)==nil&&!available&&!wrong.called,@"wrong getter ABI is never invoked");
    Check(!URLPath([NSURL URLWithString:@"https://example.invalid"]),@"remote group URL refused");
    NSString *familyStage=nil;NSDictionary *family=IntersectGroups(targets,targets,&familyStage);
    Check(family&&[family[group] isEqual:root]&&!familyStage,@"identical Instagram and Facebook group roots become family targets");
    familyStage=nil;Check(IntersectGroups(targets,@{group:@"/private/other"},&familyStage)==nil&&[familyStage isEqual:@"FAMILY_GROUP_PATH_MISMATCH"],@"same family identifier on different physical roots refused");
    familyStage=nil;Check(IntersectGroups(targets,@{@"group.other.family":root},&familyStage)==nil&&[familyStage isEqual:@"FAMILY_SHARED_GROUP_UNAVAILABLE"],@"disjoint Instagram and Facebook groups refuse family writers");
    familyStage=nil;NSDictionary *merged=MergeStorage(@{@"storage":@{root:row}},@{@"storage":@{root:row}},&familyStage);
    Check(merged&&[merged[root] isEqual:row]&&!familyStage,@"matching family storage nodes merge");
    familyStage=nil;NSMutableDictionary *otherRow=[row mutableCopy];otherRow[@"layoutIssues"]=@[@"FOREIGN"];
    Check(MergeStorage(@{@"storage":@{root:row}},@{@"storage":@{root:otherRow}},&familyStage)==nil&&[familyStage isEqual:@"FAMILY_STORAGE_NODE_MISMATCH"],@"conflicting family storage nodes refuse merge");
    printf("PASS: %lu shared-group owner and exact getter ABI assertions\n",(unsigned long)Checks);return 0;
}}
