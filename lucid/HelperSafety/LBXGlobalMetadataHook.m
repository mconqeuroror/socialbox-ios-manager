#import "LBXGlobalMetadata.h"
#include <limits.h>
#include <stdlib.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

static Class LBXMetadataOwner;
static id (*LBXMetadataPath)(id,SEL);
static BOOL (*LBXOldWrite)(id,SEL,id);
static BOOL (*LBXOldMutate)(id,SEL,id);
static NSString *LBXCheckedMetadataPath(id receiver) {
    id raw=LBXMetadataPath(receiver,NSSelectorFromString(@"globalMetadataPath"));
    if(![raw isKindOfClass:NSString.class])return nil;
    // Resolve only the trusted jailbreak alias, never a potentially redirected
    // data directory. The descriptor-relative walk rejects every other symlink.
    char resolved[PATH_MAX];NSString *root=realpath("/var/jb",resolved)?@(resolved):nil;
    NSString *tail=@"var/mobile/Library/SocialBox/Containers/global_metadata.plist";
    NSString *rootless=[root stringByAppendingPathComponent:tail],*rootful=[@"/private" stringByAppendingPathComponent:tail];
    NSString *path=raw;
    if([path hasPrefix:@"/var/jb/"]){if(!root)return nil;path=[root stringByAppendingPathComponent:[path substringFromIndex:8]];}
    else if([path hasPrefix:@"/var/"])path=[@"/private" stringByAppendingString:path];
    return [path isEqual:rootless] || [path isEqual:rootful]?path:nil;
}
static BOOL LBXCheckedWrite(id receiver,SEL selector,id value) {
    if(object_getClass(receiver)!=LBXMetadataOwner)return LBXOldWrite(receiver,selector,value);
    return LBXWriteGlobalMetadata(LBXCheckedMetadataPath(receiver),value);
}
static BOOL LBXCheckedMutate(id receiver,SEL selector,id block) {
    if(object_getClass(receiver)!=LBXMetadataOwner)return LBXOldMutate(receiver,selector,block);
    return LBXMutateGlobalMetadata(LBXCheckedMetadataPath(receiver),block);
}
static Method LBXMetadataMethod(Class owner,NSString *name,const char *encoding,uintptr_t expected) {
    unsigned count=0;Method *list=class_copyMethodList(owner,&count),method=NULL;SEL selector=NSSelectorFromString(name);
    for(unsigned i=0;i<count;i++)if(method_getName(list[i])==selector){method=list[i];break;}free(list);
    if(!method || strcmp(method_getTypeEncoding(method),encoding))return NULL;
    void *imp=(void *)method_getImplementation(method);
#if __has_feature(ptrauth_calls)
    imp=ptrauth_strip(imp,ptrauth_key_function_pointer);
#endif
    return (uintptr_t)imp==expected?method:NULL;
}
BOOL LBXInstallGlobalMetadata(Class owner,uintptr_t getter,uintptr_t writer,uintptr_t mutator) {
    if(!owner || LBXMetadataOwner)return NO;
    Method path=LBXMetadataMethod(owner,@"globalMetadataPath","@16@0:8",getter);
    Method writeMethod=LBXMetadataMethod(owner,@"writeGlobalMetadata:","B24@0:8@16",writer);
    Method mutateMethod=LBXMetadataMethod(owner,@"mutateGlobalMetadataLocked:","B24@0:8@?16",mutator);
    if(!path || !writeMethod || !mutateMethod)return NO;
    LBXMetadataPath=(id(*)(id,SEL))method_getImplementation(path);
    LBXOldWrite=(BOOL(*)(id,SEL,id))method_getImplementation(writeMethod);
    LBXOldMutate=(BOOL(*)(id,SEL,id))method_getImplementation(mutateMethod);
    LBXMetadataOwner=owner;
    method_setImplementation(writeMethod,(IMP)LBXCheckedWrite);
    method_setImplementation(mutateMethod,(IMP)LBXCheckedMutate);
    return method_getImplementation(writeMethod)==(IMP)LBXCheckedWrite && method_getImplementation(mutateMethod)==(IMP)LBXCheckedMutate;
}
