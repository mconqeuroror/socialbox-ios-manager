#import <Foundation/Foundation.h>
#import "LBXNativeStorageInventory.h"
#import "LBXDarwinDrainBackend.h"
#import "LBXSocialBoxProduct.h"
#import "../../shared/RBXStorageGate.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <string.h>

// Private read-only enumeration. No terminate, gate, chmod or launch calls.
// Installed registrations are not a complete inventory of system brokers.
static BOOL Name(id x){return [x isKindOfClass:NSString.class]&&[x length]&&[x lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<256&&![x containsString:@"/"]&&![x containsString:@"\\"]&&![x isEqual:@"."]&&![x isEqual:@".."]&&[x rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound;}
static NSString *Path(id x){if(![x isKindOfClass:NSString.class])return nil;NSString *p=[x hasPrefix:@"/var/"]?[@"/private" stringByAppendingString:x]:x;if(![p hasPrefix:@"/"]||p.length>=4096)return nil;NSArray *parts=[p componentsSeparatedByString:@"/"];for(NSUInteger i=1;i<parts.count;i++)if(!Name(parts[i]))return nil;return p;}
static NSString *URLPath(id x){return [x isKindOfClass:NSURL.class]&&[x isFileURL]?Path([x path]):nil;}
static id Get(id receiver,NSString *name,BOOL *available){SEL selector=NSSelectorFromString(name);Method method=receiver?class_getInstanceMethod(object_getClass(receiver),selector):NULL;const char *encoding=method?method_getTypeEncoding(method):NULL;
    BOOL valid=encoding&&!strcmp(encoding,"@16@0:8")&&method_getNumberOfArguments(method)==2&&[receiver respondsToSelector:selector];if(available)*available=valid;return valid?((id(*)(id,SEL))objc_msgSend)(receiver,selector):nil;}
static NSDictionary *Freeze(id x){if(![NSJSONSerialization isValidJSONObject:x])return nil;NSData *d=[NSJSONSerialization dataWithJSONObject:x options:NSJSONWritingSortedKeys error:nil];return d.length&&d.length<=8*1024*1024?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:nil;}
// A registered subgroup is recognized only when the exact node was captured by
// the physical native inventory. Prefix matching cannot create a profile alias.
// A second full inventory below must reproduce these nodes before completeness.
static NSDictionary *ProfileAliases(NSDictionary *snapshot){
    NSDictionary *targets=snapshot[@"groupRegistrations"],*storage=snapshot[@"storage"];
    if(![targets isKindOfClass:NSDictionary.class]||!targets.count||![storage isKindOfClass:NSDictionary.class])return nil;
    NSMutableDictionary *aliases=[NSMutableDictionary dictionary];
    for(NSString *group in targets){NSString *base=targets[group];NSDictionary *row=storage[base],*root=row[@"root"];NSArray *stores=row[@"profileStores"];
        if(!Name(group)||!Path(base)||![root isKindOfClass:NSDictionary.class]||![root[@"path"] isEqual:base]||![root[@"type"] isEqual:@"directory"]||![stores isKindOfClass:NSArray.class]||stores.count>1||![row[@"layoutIssues"] isKindOfClass:NSArray.class]||[row[@"layoutIssues"] count])return nil;
        NSMutableDictionary *paths=[NSMutableDictionary dictionary];
        for(NSDictionary *store in stores){NSDictionary *node=store[@"root"];NSString *path=node[@"path"];NSArray *profiles=store[@"profiles"],*other=store[@"otherEntries"];
            if(![node isKindOfClass:NSDictionary.class]||![node[@"type"] isEqual:@"directory"]||![node[@"name"] isEqual:@LBX_SOCIALBOX_PROFILE_STORE]||!([path isEqual:[base stringByAppendingPathComponent:@"Library/" LBX_SOCIALBOX_PROFILE_STORE]]||[path isEqual:[base stringByAppendingPathComponent:@LBX_SOCIALBOX_PROFILE_STORE]])||![profiles isKindOfClass:NSArray.class]||![other isKindOfClass:NSArray.class]||other.count)return nil;
            for(NSDictionary *profile in profiles){NSString *cid=profile[@"name"],*profilePath=profile[@"path"];
                if(![profile isKindOfClass:NSDictionary.class]||![cid isKindOfClass:NSString.class]||!cid.length||cid.length>19||[cid hasPrefix:@"0"]||[cid rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location!=NSNotFound||![profile[@"type"] isEqual:@"directory"]||![profilePath isEqual:[path stringByAppendingPathComponent:cid]]||paths[profilePath])return nil;
                paths[profilePath]=@{@"kind":@"OBSERVED_NATIVE_PROFILE_ROOT",@"containerID":cid,@"physicalGroupRoot":base,@"profileNode":profile,@"storeNode":node,@"launchAuthority":@NO};
            }
        }aliases[group]=paths;
    }return Freeze(aliases);
}
static NSDictionary *Owner(id proxy,NSString *parent,NSString *parentPath,NSDictionary *targets,NSDictionary *aliases){
    BOOL identityOK=NO,bundleOK=NO,groupsOK=NO,entitlementsOK=NO;
    id identifier=Get(proxy,@"bundleIdentifier",&identityOK);NSString *bundle=URLPath(Get(proxy,@"bundleURL",&bundleOK));
    if(!identityOK||!Name(identifier)||!bundleOK||!bundle)return @{@"issues":@[@"OWNER_IDENTITY_OR_BUNDLE_UNAVAILABLE"],@"applicationID":parent?:@"UNAVAILABLE"};
    NSMutableArray *issues=[NSMutableArray array];BOOL systemExtensions=parent&&[parent hasPrefix:@"com.apple."]&&[identifier hasPrefix:[parent stringByAppendingString:@"."]]&&[bundle.stringByDeletingLastPathComponent isEqual:[parentPath stringByAppendingPathComponent:@"Extensions"]]&&[bundle.pathExtension isEqual:@"appex"];
    if(parent&&!systemExtensions&&(![identifier hasPrefix:[parent stringByAppendingString:@"."]]||![bundle.stringByDeletingLastPathComponent isEqual:[parentPath stringByAppendingPathComponent:@"PlugIns"]]||![bundle.pathExtension isEqual:@"appex"]))[issues addObject:@"EXTENSION_PARENT_BINDING_MISMATCH"];
    id groups=Get(proxy,@"groupContainerURLs",&groupsOK),entitlements=Get(proxy,@"entitlements",&entitlementsOK);
    NSMutableDictionary *overlap=[NSMutableDictionary dictionary],*resolutions=[NSMutableDictionary dictionary];NSMutableArray *declaredOverlap=[NSMutableArray array];
    if(!groupsOK||![groups isKindOfClass:NSDictionary.class]||[groups count]>256)[issues addObject:@"GROUP_REGISTRATION_UNAVAILABLE"];
    else for(id key in groups){NSString *path=URLPath(groups[key]);if(!Name(key)||!path){[issues addObject:@"GROUP_REGISTRATION_MALFORMED"];break;}if(targets[key]){overlap[key]=path;if([targets[key] isEqual:path])resolutions[key]=@{@"kind":@"PHYSICAL_REGISTERED_ROOT",@"physicalGroupRoot":targets[key],@"launchAuthority":@NO};else if(aliases[key][path])resolutions[key]=aliases[key][path];else [issues addObject:@"TARGET_GROUP_PATH_MISMATCH"];}}
    if(!entitlementsOK||![entitlements isKindOfClass:NSDictionary.class])[issues addObject:@"GROUP_DECLARATIONS_UNAVAILABLE"];
    else {id declared=entitlements[@"com.apple.security.application-groups"]?:@[];
        if(![declared isKindOfClass:NSArray.class]||[declared count]>256)[issues addObject:@"GROUP_DECLARATIONS_MALFORMED"];
        else {NSMutableSet *seen=[NSMutableSet set];for(id group in declared){if(!Name(group)||[seen containsObject:group]){[issues addObject:@"GROUP_DECLARATIONS_MALFORMED"];break;}[seen addObject:group];if(targets[group])[declaredOverlap addObject:group];}}}
    [declaredOverlap sortUsingSelector:@selector(compare:)];if(![[NSSet setWithArray:overlap.allKeys] isEqual:[NSSet setWithArray:declaredOverlap]])[issues addObject:@"TARGET_DECLARED_REGISTERED_GROUPS_MISMATCH"];
    // Extensions/ is observed for three Apple system apps. This exception proves
    // only explicit non-overlap; it never supplies executable/gating authority.
    if(systemExtensions&&(issues.count||overlap.count||declaredOverlap.count))[issues addObject:@"SYSTEM_EXTENSIONS_TARGET_SCOPE_UNRESOLVED"];
    return @{@"bundleIdentifier":identifier,@"bundlePath":bundle,@"applicationID":parent?:identifier,@"kind":parent?@"extension":@"application",@"targetGroups":overlap,@"targetGroupResolutions":resolutions,@"declaredTargetGroups":declaredOverlap,@"extensionLayout":systemExtensions?@"SYSTEM_EXTENSIONS_NONOVERLAP_ONLY":(parent?@"EMBEDDED_PLUGINS":@"APPLICATION"),@"issues":issues};
}
static NSDictionary *Enumerate(NSDictionary *targets,NSDictionary *aliases){
    BOOL available=NO;id workspace=Get(NSClassFromString(@"LSApplicationWorkspace"),@"defaultWorkspace",&available);if(!available||!workspace)return @{@"status":@"REJECTED",@"stage":@"WORKSPACE_ABI_UNAVAILABLE"};
    NSString *selector=@"allInstalledApplications";id raw=Get(workspace,selector,&available);if(!available){selector=@"allApplications";raw=Get(workspace,selector,&available);}
    if(!available||![raw isKindOfClass:NSArray.class]||![raw count]||[raw count]>2048)return @{@"status":@"REJECTED",@"stage":@"COMPLETE_APPLICATION_ENUMERATION_UNAVAILABLE",@"selector":selector};
    NSMutableArray *records=[NSMutableArray array],*issues=[NSMutableArray array];NSMutableSet *apps=[NSMutableSet set],*owners=[NSMutableSet set];NSUInteger extensionCount=0;NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+30;
    for(id proxy in raw){if(NSProcessInfo.processInfo.systemUptime>=deadline)return @{@"status":@"REJECTED",@"stage":@"ENUMERATION_DEADLINE"};
        NSDictionary *main=Owner(proxy,nil,nil,targets,aliases);NSString *identifier=main[@"bundleIdentifier"],*bundle=main[@"bundlePath"];
        if(!identifier||!bundle){[issues addObject:main];continue;}if([apps containsObject:identifier]){[issues addObject:@{@"applicationID":identifier,@"issues":@[@"DUPLICATE_APPLICATION"]}];continue;}[apps addObject:identifier];[owners addObject:identifier];[records addObject:main];
        BOOL pluginABI=NO;id plugins=Get(proxy,@"plugInKitPlugins",&pluginABI);NSArray *list=[plugins isKindOfClass:NSSet.class]?[plugins allObjects]:([plugins isKindOfClass:NSArray.class]?plugins:nil);
        if(!pluginABI||!list||list.count>128){[issues addObject:@{@"applicationID":identifier,@"issues":@[@"EXTENSION_ENUMERATION_UNAVAILABLE"]}];continue;}
        for(id plugin in list){if(++extensionCount>16384)return @{@"status":@"REJECTED",@"stage":@"EXTENSION_ENUMERATION_LIMIT"};NSDictionary *entry=Owner(plugin,identifier,bundle,targets,aliases);NSString *extension=entry[@"bundleIdentifier"];
            if(!extension||[owners containsObject:extension]){[issues addObject:@{@"applicationID":identifier,@"issues":@[@"EXTENSION_IDENTITY_UNAVAILABLE_OR_DUPLICATE"]}];continue;}[owners addObject:extension];[records addObject:entry];}
    }
    if(![apps containsObject:@"com.burbn.instagram"])[issues addObject:@{@"issues":@[@"TARGET_APPLICATION_MISSING_FROM_COMPLETE_ENUMERATION"]}];
    if(![apps containsObject:@"com.facebook.Facebook"])[issues addObject:@{@"issues":@[@"FACEBOOK_APPLICATION_MISSING_FROM_COMPLETE_ENUMERATION"]}];
    [records sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"bundleIdentifier"] compare:b[@"bundleIdentifier"]];}];
    [issues sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [(a[@"applicationID"]?:@"") compare:(b[@"applicationID"]?:@"")];}];
    return Freeze(@{@"status":@"OBSERVED",@"selector":selector,@"applicationCount":@([raw count]),@"registeredExtensionCount":@(extensionCount),@"records":records,@"enumerationIssues":issues});
}
static NSDictionary *CodeBinding(NSString *identifier,NSString *bundle){
    if(!LBXDrainSupportedApplication(identifier))return @{@"status":@"UNSUPPORTED_STOP_OWNER",@"applicationID":identifier};
    LBXDrainTarget *target=[[[LBXDarwinDrainBackend alloc] init] resolve:identifier error:nil];if(!target||![target.bundleID isEqual:identifier]||![target.bundlePath isEqual:bundle]||!target.executables.count||target.executables.count>129)return @{@"status":@"CODE_BINDING_UNAVAILABLE",@"applicationID":identifier};
    NSMutableArray *nodes=[NSMutableArray array];for(NSString *path in target.executables){struct stat s;if(!Path(path)||lstat(path.fileSystemRepresentation,&s)||!S_ISREG(s.st_mode)||s.st_nlink!=1)return @{@"status":@"CODE_NODE_UNAVAILABLE",@"applicationID":identifier};
        [nodes addObject:@{@"path":path,@"device":@(s.st_dev),@"inode":@(s.st_ino),@"uid":@(s.st_uid),@"gid":@(s.st_gid),@"mode":@(s.st_mode&07777),@"flags":@(s.st_flags),@"size":@(s.st_size)}];}
    return @{@"status":@"OBSERVED",@"applicationID":identifier,@"bundlePath":bundle,@"registrationFingerprint":target.fingerprint,@"executables":nodes,@"publisherVerified":@NO,@"launchAuthority":@NO};
}
static NSDictionary *IntersectGroups(NSDictionary *instagramGroups,NSDictionary *facebookGroups,NSString **stage){
    if(![instagramGroups isKindOfClass:NSDictionary.class]||!instagramGroups.count||instagramGroups.count>64){if(stage)*stage=@"INSTAGRAM_GROUPS_UNAVAILABLE";return nil;}
    if(![facebookGroups isKindOfClass:NSDictionary.class]||!facebookGroups.count||facebookGroups.count>64){if(stage)*stage=@"FACEBOOK_GROUPS_UNAVAILABLE";return nil;}
    NSMutableDictionary *out=[NSMutableDictionary dictionary];
    for(NSString *group in instagramGroups){id path=instagramGroups[group];if(!Name(group)||!Path(path)){if(stage)*stage=@"INSTAGRAM_GROUPS_MALFORMED";return nil;}
        id facebook=facebookGroups[group];if(!facebook)continue;if(![facebook isEqual:path]){if(stage)*stage=@"FAMILY_GROUP_PATH_MISMATCH";return nil;}out[group]=path;}
    if(!out.count){if(stage)*stage=@"FAMILY_SHARED_GROUP_UNAVAILABLE";return nil;}
    return Freeze(out);
}
static NSDictionary *MergeStorage(NSDictionary *instagram,NSDictionary *facebook,NSString **stage){
    NSDictionary *a=instagram[@"storage"],*b=facebook[@"storage"];
    if(![a isKindOfClass:NSDictionary.class]||![b isKindOfClass:NSDictionary.class]){if(stage)*stage=@"FAMILY_STORAGE_UNAVAILABLE";return nil;}
    NSMutableDictionary *out=[a mutableCopy];
    for(NSString *path in b){if(out[path]&&![Freeze(out[path]) isEqual:Freeze(b[path])]){if(stage)*stage=@"FAMILY_STORAGE_NODE_MISMATCH";return nil;}out[path]=b[path];}
    return Freeze(out);
}
static NSDictionary *Observe(void){
    NSError *instagramError=nil,*facebookError=nil;
    LBXNativeStorageInventory *instagram=[LBXNativeStorageInventory observeOfficialInstagram:&instagramError];
    if(!instagram)return @{@"status":@"REJECTED",@"stage":@"INSTAGRAM_STORAGE_INVENTORY_UNAVAILABLE",@"targetErrorCode":@(instagramError.code),@"targetStage":instagramError.userInfo[@"stage"]?:@"UNAVAILABLE"};
    LBXNativeStorageInventory *facebook=[LBXNativeStorageInventory observeOfficialFacebook:&facebookError];
    if(!facebook)return @{@"status":@"REJECTED",@"stage":@"FACEBOOK_STORAGE_INVENTORY_UNAVAILABLE",@"targetErrorCode":@(facebookError.code),@"targetStage":facebookError.userInfo[@"stage"]?:@"UNAVAILABLE"};
    NSString *stage=nil;NSDictionary *targets=IntersectGroups(instagram.privateDictionary[@"groupRegistrations"],facebook.privateDictionary[@"groupRegistrations"],&stage);
    if(!targets)return @{@"status":@"REJECTED",@"stage":stage?:@"FAMILY_SHARED_GROUP_UNAVAILABLE"};
    NSDictionary *storage=MergeStorage(instagram.privateDictionary,facebook.privateDictionary,&stage);
    if(!storage)return @{@"status":@"REJECTED",@"stage":stage?:@"FAMILY_STORAGE_UNAVAILABLE"};
    NSDictionary *snapshot=@{@"groupRegistrations":targets,@"storage":storage};NSDictionary *aliases=ProfileAliases(snapshot);
    if(!aliases)return @{@"status":@"REJECTED",@"stage":@"TARGET_NATIVE_GROUP_LAYOUT_UNRESOLVED"};
    NSDictionary *before=Enumerate(targets,aliases);if(![before[@"status"] isEqual:@"OBSERVED"])return before;
    NSMutableArray *writers=[NSMutableArray array],*unknown=[before[@"enumerationIssues"] mutableCopy];NSMutableDictionary *applications=[NSMutableDictionary dictionary],*bindings=[NSMutableDictionary dictionary];
    for(NSDictionary *entry in before[@"records"]){if([entry[@"issues"] count])[unknown addObject:entry];if([entry[@"kind"] isEqual:@"application"])applications[entry[@"applicationID"]]=entry;
        if([entry[@"targetGroups"] count]||[entry[@"declaredTargetGroups"] count])[writers addObject:entry];}
    for(NSDictionary *writer in writers){NSString *identifier=writer[@"applicationID"];if(!bindings[identifier])bindings[identifier]=CodeBinding(identifier,applications[identifier][@"bundlePath"]);}
    BOOL codeComplete=YES;for(NSString *identifier in bindings){NSDictionary *bound=bindings[identifier];if(![bound[@"status"] isEqual:@"OBSERVED"]){codeComplete=NO;continue;}if(![bound isEqual:CodeBinding(identifier,bound[@"bundlePath"])])codeComplete=NO;}
    NSDictionary *after=Enumerate(targets,aliases);
    BOOL stable=[before isEqual:after]&&[instagram matchesCurrentRegistration:nil]&&[facebook matchesCurrentRegistration:nil]&&getuid()==0&&geteuid()==0;
    LBXNativeStorageInventory *instagramAgain=[LBXNativeStorageInventory observeOfficialInstagram:nil];
    LBXNativeStorageInventory *facebookAgain=[LBXNativeStorageInventory observeOfficialFacebook:nil];
    BOOL storageStable=instagramAgain&&facebookAgain&&[instagram.privateDictionary isEqual:instagramAgain.privateDictionary]&&[facebook.privateDictionary isEqual:facebookAgain.privateDictionary];
    BOOL complete=stable&&storageStable&&!unknown.count&&codeComplete;
    return Freeze(@{@"formatVersion":@1,@"kind":@"native-family-shared-group-writers",@"status":complete?@"OBSERVED":@"REJECTED",@"scope":@"Installed Instagram and Facebook group owners; system brokers not covered",
        @"applicationCount":before[@"applicationCount"],@"registeredExtensionCount":before[@"registeredExtensionCount"],@"workspaceSelector":before[@"selector"],@"registrationStable":@(stable),
        @"targetGroups":targets,@"instagramInventory":instagram.privateDictionary,@"facebookInventory":facebook.privateDictionary,@"nativeGroupAliases":aliases,@"nativeStorageStable":@(storageStable),@"writers":writers,@"codeBindings":bindings,@"unknownOwners":unknown,
        @"familySharedGroupCount":@(targets.count),@"installedAppWriterInventoryComplete":@(complete),@"completeSharedWriters":@NO,@"systemBrokerCoverage":@"NOT_RUN",@"accountFileContentsRead":@NO,@"runtimeAccepted":@NO,@"isolationVerified":@NO,@"safeToGate":@NO});
}
static int Output(const char *raw){NSString *path=raw?[[NSString alloc] initWithUTF8String:raw]:nil;if(!Path(path)||![Path(path) isEqual:path])return -1;int fd=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);NSArray *parts=[path componentsSeparatedByString:@"/"];
    for(NSUInteger i=1;i<parts.count;i++){int next=fd>=0?openat(fd,[parts[i] fileSystemRepresentation],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):-1;if(fd>=0)close(fd);fd=next;struct stat s;if(fd<0||fstat(fd,&s)||s.st_uid!=0||(s.st_mode&0022)||!RBXStorageGateNoACL(fd)||(i==parts.count-1&&(s.st_mode&07777)!=0700)){if(fd>=0)close(fd);return -1;}}return fd;}
static BOOL Save(int root,NSDictionary *record){NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];if(!data.length||data.length>8*1024*1024)return NO;int fd=openat(root,"shared-group-writer-inventory.json",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);struct stat s;BOOL good=fd>=0&&!fstat(fd,&s)&&s.st_uid==0&&(s.st_mode&07777)==0600&&s.st_nlink==1;NSUInteger offset=0;while(good&&offset<data.length){ssize_t n=write(fd,(const char *)data.bytes+offset,data.length-offset);if(n<0&&errno==EINTR)continue;if(n<=0){good=NO;break;}offset+=(NSUInteger)n;}if(good)good=!fsync(fd)&&!fsync(root);if(fd>=0)close(fd);return good;}
int main(int argc,const char **argv){@autoreleasepool{if(argc!=2||getuid()!=0||geteuid()!=0){puts("{\"status\":\"REFUSED\",\"rootRequired\":true}");return 77;}umask(077);int output=Output(argv[1]);if(output<0){puts("{\"status\":\"REFUSED\",\"privateOutputRequired\":true}");return 2;}
    NSDictionary *record=nil;@try{record=Observe();}@catch(__unused NSException *exception){record=@{@"status":@"REJECTED",@"stage":@"OBSERVATION_EXCEPTION"};}
    if(!record||!Save(output,record)){close(output);puts("{\"status\":\"REFUSED\",\"privateOutputSaved\":false}");return 2;}close(output);
    NSDictionary *safe=@{@"kind":record[@"kind"]?:@"native-family-shared-group-writers",@"status":record[@"status"]?:@"REJECTED",@"stage":record[@"stage"]?:@"COMPLETE",@"applicationCount":record[@"applicationCount"]?:@0,@"registeredExtensionCount":record[@"registeredExtensionCount"]?:@0,@"writerCount":@([record[@"writers"] count]),@"writerApplicationCount":@([record[@"codeBindings"] count]),@"unknownOwnerCount":@([record[@"unknownOwners"] count]),@"familySharedGroupCount":record[@"familySharedGroupCount"]?:@0,@"nativeStorageStable":record[@"nativeStorageStable"]?:@NO,@"installedAppWriterInventoryComplete":record[@"installedAppWriterInventoryComplete"]?:@NO,@"completeSharedWriters":@NO,@"accountFileContentsRead":@NO,@"runtimeAccepted":@NO,@"isolationVerified":@NO,@"safeToGate":@NO};
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:safe options:NSJSONWritingSortedKeys error:nil];if(!bytes||fwrite(bytes.bytes,1,bytes.length,stdout)!=bytes.length||putchar('\n')==EOF)return 2;return [record[@"installedAppWriterInventoryComplete"] boolValue]?0:3;
}}
