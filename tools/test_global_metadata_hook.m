#import "../lucid/HelperSafety/LBXGlobalMetadata.h"
#include <stdlib.h>
#include <limits.h>
static unsigned Checks,Failures,Legacy,Writes,Mutations;
static NSString *PathValue,*ReceivedPath;
static id ReceivedMetadata;
static BOOL NoRoot,WriterResult;
static void Check(BOOL pass,const char *why){Checks++;if(!pass){Failures++;fprintf(stderr,"FAIL %s\n",why);}}
BOOL LBXWriteGlobalMetadata(NSString *path,NSDictionary *metadata){Writes++;ReceivedPath=path;ReceivedMetadata=metadata;return path&&WriterResult;}
BOOL LBXMutateGlobalMetadata(NSString *path,void (^mutation)(NSMutableDictionary *)){
    Mutations++;ReceivedPath=path;if(path&&mutation){NSMutableDictionary *m=[NSMutableDictionary dictionary];mutation(m);ReceivedMetadata=m;}return path&&mutation&&WriterResult;
}
static char *TestRoot(const char *path,char *resolved){Check(!strcmp(path,"/var/jb"),"only jailbreak alias is resolved");if(NoRoot)return NULL;strlcpy(resolved,"/private/preboot/test/procursus",PATH_MAX);return resolved;}
#define realpath TestRoot
#import "../lucid/HelperSafety/LBXGlobalMetadataHook.m"
#undef realpath
@interface MetadataFixture : NSObject
- (NSString *)globalMetadataPath;
- (BOOL)writeGlobalMetadata:(NSDictionary *)metadata;
- (BOOL)mutateGlobalMetadataLocked:(void (^)(NSMutableDictionary *))mutation;
@end
@implementation MetadataFixture
- (NSString *)globalMetadataPath{return PathValue;}
- (BOOL)writeGlobalMetadata:(NSDictionary *)metadata{(void)metadata;Legacy++;return YES;}
- (BOOL)mutateGlobalMetadataLocked:(void (^)(NSMutableDictionary *))mutation{(void)mutation;Legacy++;return YES;}
@end
@interface MetadataChild : MetadataFixture @end
@implementation MetadataChild @end
@interface BadMetadata : NSObject
- (void)writeGlobalMetadata:(id)metadata;
@end
@implementation BadMetadata
- (void)writeGlobalMetadata:(id)metadata{(void)metadata;}
@end
static uintptr_t Address(Class cls,NSString *name){void *imp=(void *)class_getMethodImplementation(cls,NSSelectorFromString(name));
#if __has_feature(ptrauth_calls)
    imp=ptrauth_strip(imp,ptrauth_key_function_pointer);
#endif
    return (uintptr_t)imp;
}
int main(void){@autoreleasepool{
    uintptr_t getter=Address(MetadataFixture.class,@"globalMetadataPath"),writer=Address(MetadataFixture.class,@"writeGlobalMetadata:"),mutator=Address(MetadataFixture.class,@"mutateGlobalMetadataLocked:");
    Check(!LBXInstallGlobalMetadata(BadMetadata.class,getter,writer,mutator),"wrong method ABI refused");
    Check(!LBXInstallGlobalMetadata(MetadataChild.class,getter,writer,mutator),"inherited methods refused");
    Check(!LBXInstallGlobalMetadata(MetadataFixture.class,getter+4,writer,mutator),"changed path getter refused");
    Check(!LBXInstallGlobalMetadata(MetadataFixture.class,getter,writer+4,mutator),"changed writer refused");
    Check(!LBXInstallGlobalMetadata(MetadataFixture.class,getter,writer,mutator+4),"changed mutator refused");
    Check(LBXInstallGlobalMetadata(MetadataFixture.class,getter,writer,mutator),"actual metadata methods replaced");
    MetadataFixture *owner=[MetadataFixture new];WriterResult=YES;
    PathValue=@"/var/jb/var/mobile/Library/SocialBox/Containers/global_metadata.plist";
    NSDictionary *original=@{@"version":@2,@"activeContainer":@5};
    Check([owner writeGlobalMetadata:original]&&ReceivedMetadata==original&&[ReceivedPath isEqual:@"/private/preboot/test/procursus/var/mobile/Library/SocialBox/Containers/global_metadata.plist"],"original metadata and exact rebased path reach checked writer");
    WriterResult=NO;Check(![owner writeGlobalMetadata:original]&&Legacy==0,"checked write error propagated without fallback");WriterResult=YES;
    Check([owner mutateGlobalMetadataLocked:^(NSMutableDictionary *m){m[@"changed"]=@YES;}]&&[ReceivedMetadata[@"changed"] boolValue],"same mutation block reaches checked transaction");
    WriterResult=NO;Check(![owner mutateGlobalMetadataLocked:^(NSMutableDictionary *m){(void)m;}]&&Legacy==0,"checked mutation error propagated");WriterResult=YES;
    for(id invalid in @[@"/tmp/global_metadata.plist",@"/var/jb/var/mobile/Library/SocialBox/Containers/../Containers/global_metadata.plist",@"/var/jb/var/mobile/Library/SocialBox/Containers/other.plist",@42]){
        PathValue=invalid;Check(![owner writeGlobalMetadata:original]&&!ReceivedPath&&Legacy==0,"foreign path is not an alternate writable destination");
    }
    NoRoot=YES;PathValue=@"/var/jb/var/mobile/Library/SocialBox/Containers/global_metadata.plist";
    Check(![owner writeGlobalMetadata:original]&&!ReceivedPath,"missing jailbreak alias refused");
    PathValue=@"/var/mobile/Library/SocialBox/Containers/global_metadata.plist";
    Check([owner writeGlobalMetadata:original]&&[ReceivedPath isEqual:@"/private/var/mobile/Library/SocialBox/Containers/global_metadata.plist"],"rootful path retains original location");
    unsigned requests=Writes+Mutations;
    Check([[MetadataChild new] writeGlobalMetadata:original]&&Legacy==1&&Writes+Mutations==requests,"unrelated subclass retains its inherited original flow");
    Check(!LBXInstallGlobalMetadata(MetadataFixture.class,getter,writer,mutator),"double install cannot overwrite prior IMP");
    printf("%s metadata hook: %u checks, %u failures; actual Objective-C methods, mocked storage/alias\n",Failures?"FAIL":"PASS",Checks,Failures);return Failures?1:0;
}}
