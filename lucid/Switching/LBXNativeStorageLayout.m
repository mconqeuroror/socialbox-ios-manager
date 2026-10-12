#import "LBXNativeStorageLayout.h"
#import "LBXNativeStorageInventory.h"
#import "LBXSocialBoxProduct.h"
#include <sys/stat.h>

static BOOL Refuse(NSError **error, NSInteger code) {
    if (error) *error = [NSError errorWithDomain:@"com.socialbox.native-storage-layout" code:code
        userInfo:@{NSLocalizedDescriptionKey:@"Native storage has an unsupported or inconsistent layout"}];
    return NO;
}
static NSDictionary *Immutable(NSDictionary *value) {
    if (![NSJSONSerialization isValidJSONObject:value]) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    return data.length && data.length <= 8*1024*1024 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}
static BOOL CID(NSString *value) {
    return [value isKindOfClass:NSString.class] && value.length && value.length<=19 && value.longLongValue>=0 &&
        [value isEqual:[NSString stringWithFormat:@"%lld",value.longLongValue]];
}
static BOOL Node(NSDictionary *node, NSString *parent, BOOL directoryOnly) {
    if (![node isKindOfClass:NSDictionary.class]) return NO;
    NSString *path=node[@"path"], *name=node[@"name"], *type=node[@"type"];
    if (![path isKindOfClass:NSString.class] || ![name isKindOfClass:NSString.class] || !name.length ||
        [name isEqual:@"."] || [name isEqual:@".."] || [name containsString:@"/"] || [name containsString:@"\\"] ||
        ![path isEqual:[parent stringByAppendingPathComponent:name]]) return NO;
    if (![type isEqual:@"directory"] && (directoryOnly || ![type isEqual:@"regular"])) return NO;
    for (NSString *key in @[@"device",@"inode",@"uid",@"gid",@"mode",@"flags"])
        if (![node[key] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)node[key])==CFBooleanGetTypeID()) return NO;
    return [node[@"inode"] unsignedLongLongValue] && [node[@"mode"] unsignedLongLongValue]<=07777 &&
        ([type isEqual:@"directory"] || ([node[@"linkCount"] isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)node[@"linkCount"])!=CFBooleanGetTypeID() && [node[@"linkCount"] unsignedLongLongValue]==1));
}
static BOOL Observed(NSDictionary *snapshot) {
    if([snapshot[@"layoutStatus"] isEqual:@"OBSERVED"])return ![snapshot[@"unresolvedOwners"] count];
    if(![snapshot[@"layoutStatus"] isEqual:@"OBSERVED_WITH_UNAVAILABLE_COMPONENT"] || [snapshot[@"unknownLayoutCount"] unsignedIntegerValue])return NO;
    NSArray *unavailable=snapshot[@"unavailableExecutables"],*missing=snapshot[@"unresolvedOwners"];
    if(![unavailable isKindOfClass:NSArray.class]||!unavailable.count||unavailable.count>128||![missing isKindOfClass:NSArray.class]||unavailable.count!=missing.count)return NO;
    NSMutableSet *identifiers=[NSMutableSet set];
    for(NSDictionary *entry in unavailable){NSString *identifier=entry[@"bundleIdentifier"];NSDictionary *exe=entry[@"executable"];id mode=exe[@"mode"];
        if(![identifier isKindOfClass:NSString.class]||[identifiers containsObject:identifier]||
            ![entry[@"reason"] isEqual:@"NEWER_OS_AND_ORIGINALLY_NONEXECUTABLE_WITH_NO_LS_PROXY"]||
            ![entry[@"mustRemainNonExecutable"] isEqual:@YES]||![mode isKindOfClass:NSNumber.class]||
            CFGetTypeID((__bridge CFTypeRef)mode)==CFBooleanGetTypeID()||CFNumberIsFloatType((__bridge CFNumberRef)mode)||
            [mode unsignedLongLongValue]>07777||([mode unsignedIntValue]&0111))return NO;
        BOOL bound=NO,unregistered=NO;
        for(NSDictionary *extension in snapshot[@"installation"][@"extensions"])
            if([extension[@"bundleIdentifier"] isEqual:identifier]&&[extension[@"bundlePath"] isEqual:entry[@"bundlePath"]]&&[extension[@"executable"] isEqual:exe])bound=YES;
        for(NSDictionary *owner in missing)if([owner[@"bundleIdentifier"] isEqual:identifier]&&[owner[@"bundlePath"] isEqual:entry[@"bundlePath"]])unregistered=YES;
        if(!bound||!unregistered)return NO;[identifiers addObject:identifier];
    }
    return YES;
}
static BOOL Add(NSMutableArray *nodes, NSMutableSet *identities, NSDictionary *node, NSString *cid,
                NSString *storagePath, NSString *category, NSError **error) {
    NSString *identity=[NSString stringWithFormat:@"%@:%@",node[@"device"],node[@"inode"]];
    if ([identities containsObject:identity]) return Refuse(error,4);
    [identities addObject:identity];
    [nodes addObject:@{@"node":node,@"containerID":cid,@"storagePath":storagePath,@"category":category}];
    return YES;
}
@interface LBXNativeStorageLayout ()
- (instancetype)initPrivate:(NSDictionary *)snapshot;
@end
@implementation LBXNativeStorageLayout { NSDictionary *_snapshot; }
- (instancetype)initPrivate:(NSDictionary *)snapshot { if ((self=[super init])) _snapshot=snapshot; return self; }
+ (instancetype)fromSnapshot:(NSDictionary *)snapshot error:(NSError **)error {
    if (error) *error=nil;
    NSDictionary *storage=snapshot[@"storage"]; NSArray *owners=snapshot[@"owners"];
    if (![snapshot[@"bundleIdentifier"] isEqual:@"com.burbn.instagram"] &&
        ![snapshot[@"bundleIdentifier"] isEqual:@"com.facebook.Facebook"]) {Refuse(error,1);return nil;}
    NSString *bundle=snapshot[@"bundleIdentifier"];
    if (!Observed(snapshot) || ![storage isKindOfClass:NSDictionary.class] ||
        !storage.count || storage.count>512 || ![owners isKindOfClass:NSArray.class] || !owners.count) {Refuse(error,1);return nil;}
    NSMutableSet *referenced=[NSMutableSet set];
    for (NSDictionary *owner in owners) {
        if (![owner isKindOfClass:NSDictionary.class] || ![owner[@"dataPath"] isKindOfClass:NSString.class] ||
            ![owner[@"groups"] isKindOfClass:NSDictionary.class]) {Refuse(error,1);return nil;}
        [referenced addObject:owner[@"dataPath"]];
        for (id path in [owner[@"groups"] allValues]) {if (![path isKindOfClass:NSString.class]) {Refuse(error,1);return nil;} [referenced addObject:path];}
    }
    if (![referenced isEqual:[NSSet setWithArray:storage.allKeys]]) {Refuse(error,1);return nil;}
    NSMutableArray *nodes=[NSMutableArray array], *namespaces=[NSMutableArray array], *defaultsOnly=[NSMutableArray array];
    NSMutableSet *identities=[NSMutableSet set], *containers=[NSMutableSet setWithObject:@"0"];
    NSUInteger files=0;
    for (NSString *path in [storage.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *scope=storage[path], *root=scope[@"root"];
        NSArray *top=scope[@"rootEntries"], *library=scope[@"libraryEntries"], *stores=scope[@"profileStores"];
        if (![root[@"path"] isEqual:path] || ![root[@"type"] isEqual:@"directory"] ||
            ![top isKindOfClass:NSArray.class] || ![library isKindOfClass:NSArray.class] ||
            ![stores isKindOfClass:NSArray.class] || stores.count>1 || [scope[@"layoutIssues"] count]) {Refuse(error,2);return nil;}
        NSString *libraryPath=[path stringByAppendingPathComponent:@"Library"];
        NSDictionary *libraryNode=nil, *store=stores.firstObject;
        NSMutableDictionary *topByName=[NSMutableDictionary dictionary], *libraryByName=[NSMutableDictionary dictionary];
        for (NSDictionary *node in top) {
            if (!Node(node,path,NO) || topByName[node[@"name"]]) {Refuse(error,2);return nil;}
            topByName[node[@"name"]]=node;
        }
        libraryNode=topByName[@"Library"];
        if ((libraryNode && ![libraryNode[@"type"] isEqual:@"directory"]) || (!libraryNode && library.count)) {Refuse(error,2);return nil;}
        for (NSDictionary *node in library) {
            if (!Node(node,libraryPath,NO) || libraryByName[node[@"name"]]) {Refuse(error,2);return nil;}
            libraryByName[node[@"name"]]=node;
        }
        NSDictionary *storeRoot=store[@"root"];
        NSString *storePath=storeRoot[@"path"];
        if (store) {
            if (![store[@"profiles"] isKindOfClass:NSArray.class] || [store[@"otherEntries"] count] ||
                ![storeRoot[@"name"] isEqual:@LBX_SOCIALBOX_PROFILE_STORE] ||
                (!([storeRoot isEqual:topByName[@LBX_SOCIALBOX_PROFILE_STORE]] && Node(storeRoot,path,YES)) &&
                 !([storeRoot isEqual:libraryByName[@LBX_SOCIALBOX_PROFILE_STORE]] && Node(storeRoot,libraryPath,YES)))) {Refuse(error,2);return nil;}
            NSMutableSet *seen=[NSMutableSet set];
            for (NSDictionary *node in store[@"profiles"]) {
                NSString *cid=node[@"name"];
                if (!Node(node,storePath,YES) || (!CID(cid) || [cid isEqual:@"0"]) || [seen containsObject:cid] ||
                    !Add(nodes,identities,node,cid,path,@"numbered-profile",error)) {Refuse(error,3);return nil;}
                [seen addObject:cid]; [containers addObject:cid];
            }
            [namespaces addObject:@{@"node":storeRoot,@"category":@"profile-store"}];
        } else [defaultsOnly addObject:path];
        // Keep only ancestors traversable. Every observed ordinary entry is
        // default state, including shared defaults which the old engine copies.
        // Symlinks and multi-link regular files were refused above.
        for (NSDictionary *node in top) {
            if ([node isEqual:libraryNode] || [node[@"path"] isEqual:storePath]) continue;
            if (!Add(nodes,identities,node,@"0",path,@"default-root-entry",error)) return nil;
            if ([node[@"type"] isEqual:@"regular"]) files++;
        }
        for (NSDictionary *node in library) {
            if ([node[@"path"] isEqual:storePath]) continue;
            if (!Add(nodes,identities,node,@"0",path,@"default-library-entry",error)) return nil;
            if ([node[@"type"] isEqual:@"regular"]) files++;
        }
        [namespaces addObject:@{@"node":root,@"category":@"registered-storage-root"}];
        if (libraryNode) [namespaces addObject:@{@"node":libraryNode,@"category":@"library-ancestor"}];
    }
    if (!nodes.count || nodes.count>4096) {Refuse(error,3);return nil;}
    NSDictionary *value=Immutable(@{@"formatVersion":@1,@"bundleIdentifier":bundle,
        @"protectedNodes":nodes,@"namespaces":namespaces,@"observedContainerIDs":[containers.allObjects sortedArrayUsingSelector:@selector(compare:)],
        @"defaultOnlyStoragePaths":defaultsOnly,@"unavailableExecutables":snapshot[@"unavailableExecutables"]?:@[],@"regularFileCount":@(files),@"storageRootCount":@(storage.count),
        @"defaultEntriesIncluded":@YES,@"namespaceMustBeSealed":@YES,
        @"processDrainRequired":@YES,@"brokerIsolationVerified":@NO,@"runtimeAccepted":@NO});
    if (!value) {Refuse(error,3);return nil;}
    return [[self alloc] initPrivate:value];
}
+ (instancetype)layoutForInventory:(LBXNativeStorageInventory *)inventory error:(NSError **)error {
    if (![inventory isMemberOfClass:LBXNativeStorageInventory.class]) {Refuse(error,1);return nil;}
    return [self fromSnapshot:inventory.privateDictionary error:error];
}
- (NSDictionary *)privateDictionary {return _snapshot;}
- (NSDictionary *)safeStatus {return @{@"protectedNodeCount":@([_snapshot[@"protectedNodes"] count]),
    @"regularFileCount":_snapshot[@"regularFileCount"],@"namespaceCount":@([_snapshot[@"namespaces"] count]),
    @"storageRootCount":_snapshot[@"storageRootCount"],@"defaultOnlyStorageCount":@([_snapshot[@"defaultOnlyStoragePaths"] count]),
    @"defaultEntriesIncluded":@YES,@"namespaceMustBeSealed":@YES,@"brokerIsolationVerified":@NO,@"runtimeAccepted":@NO};}
#if LBX_NATIVE_STORAGE_LAYOUT_TESTING
+ (instancetype)testLayoutForSnapshot:(NSDictionary *)snapshot error:(NSError **)error {return [self fromSnapshot:snapshot error:error];}
#endif
@end
