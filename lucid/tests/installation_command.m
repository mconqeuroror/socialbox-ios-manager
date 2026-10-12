#import "../Authorization/LBXLicenseInstallationEstablishment.h"
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <limits.h>
#include <string.h>

// Only this test translation unit substitutes identities and inert factories.
// The shipping entry and fixed source factory are not weakened or overridden.
static uid_t CommandRealUID,CommandEffectiveUID;
static gid_t CommandEffectiveGID;
static NSUInteger RealUIDCalls,EffectiveUIDCalls,EffectiveGIDCalls;
static uid_t CommandGetUID(void){RealUIDCalls++;return CommandRealUID;}
static uid_t CommandGetEffectiveUID(void){EffectiveUIDCalls++;return CommandEffectiveUID;}
static gid_t CommandGetEffectiveGID(void){EffectiveGIDCalls++;return CommandEffectiveGID;}
static NSUInteger PrepareCalls,OpenCalls,CurrentCalls,checks,failures,dispatches;
static NSInteger FactoryResult;
static NSString *PrivateDetails;

@interface CommandFixtureInstallation:NSObject
+ (instancetype)prepareFixedInstallation:(NSError **)error;
+ (instancetype)openFixedPreparedInstallation:(NSError **)error;
- (BOOL)preparedInstallationCurrent:(NSError **)error;
@end
static void PrivateError(NSError **error){if(error)*error=[NSError errorWithDomain:@"fixture.private.error" code:91
    userInfo:@{NSLocalizedDescriptionKey:PrivateDetails,@"privateSeed":@"fixture-private-seed"}];}
@implementation CommandFixtureInstallation
+ (instancetype)prepareFixedInstallation:(NSError **)error{PrepareCalls++;PrivateError(error);return FactoryResult==0?nil:[self new];}
+ (instancetype)openFixedPreparedInstallation:(NSError **)error{OpenCalls++;PrivateError(error);return FactoryResult==0?nil:[self new];}
- (BOOL)preparedInstallationCurrent:(NSError **)error{CurrentCalls++;PrivateError(error);return FactoryResult==1;}
@end

#define LBXLicenseInstallationEstablishment CommandFixtureInstallation
#define getuid CommandGetUID
#define geteuid CommandGetEffectiveUID
#define getegid CommandGetEffectiveGID
#define main CommandEntry
#import "../Authorization/InstallPreparation.m"
#undef main
#undef getegid
#undef geteuid
#undef getuid
#undef LBXLicenseInstallationEstablishment

static void Check(BOOL good,NSString *why){checks++;if(!good){failures++;fprintf(stderr,"FAIL: %s\n",why.UTF8String);}}
static NSDictionary *Snapshot(NSString *path){struct stat n;if(lstat(path.fileSystemRepresentation,&n))return nil;
    NSMutableDictionary *value=[@{@"device":@(n.st_dev),@"inode":@(n.st_ino),@"mode":@(n.st_mode),@"links":@(n.st_nlink),
        @"size":@(n.st_size),@"mtime":@(n.st_mtimespec.tv_sec),@"mtimeNS":@(n.st_mtimespec.tv_nsec),
        @"ctime":@(n.st_ctimespec.tv_sec),@"ctimeNS":@(n.st_ctimespec.tv_nsec)} mutableCopy];
    if(S_ISREG(n.st_mode))value[@"bytes"]=[NSData dataWithContentsOfFile:path]?:NSData.data;
    else if(S_ISLNK(n.st_mode)){char target[PATH_MAX];ssize_t count=readlink(path.fileSystemRepresentation,target,sizeof(target));
        if(count<0)return nil;value[@"target"]=[NSData dataWithBytes:target length:(NSUInteger)count];}
    else if(S_ISDIR(n.st_mode)){NSMutableDictionary *children=[NSMutableDictionary dictionary];
        for(NSString *leaf in [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil]){
            NSDictionary *child=Snapshot([path stringByAppendingPathComponent:leaf]);if(!child)return nil;children[leaf]=child;
        }value[@"children"]=children;}
    return value;
}
static NSData *Captured(FILE *stream){if(fflush(stream)||fseek(stream,0,SEEK_SET))return nil;NSMutableData *data=[NSMutableData data];char bytes[1024];size_t count;
    while((count=fread(bytes,1,sizeof(bytes),stream))>0){if(data.length+count>32768)return nil;[data appendBytes:bytes length:count];}
    return ferror(stream)?nil:data;
}
static NSDictionary *Invoke(NSArray<NSString *> *arguments,uid_t real,uid_t effective,gid_t group,NSInteger result,NSString *base){
    CommandRealUID=real;CommandEffectiveUID=effective;CommandEffectiveGID=group;FactoryResult=result;
    PrepareCalls=OpenCalls=CurrentCalls=RealUIDCalls=EffectiveUIDCalls=EffectiveGIDCalls=0;
    char *argv[16]={"socialbox-prepare-installation"};Check(arguments.count<15,@"bounded fixture argv");
    for(NSUInteger i=0;i<arguments.count;i++)argv[i+1]=(char *)arguments[i].UTF8String;
    NSDictionary *before=Snapshot(base);fflush(stdout);fflush(stderr);int out=dup(STDOUT_FILENO),err=dup(STDERR_FILENO);FILE *output=tmpfile(),*diagnostic=tmpfile();
    BOOL capture=out>=0&&err>=0&&output&&diagnostic;Check(capture,@"actual temporary stdout/stderr capture");
    if(!capture){if(out>=0)close(out);if(err>=0)close(err);if(output)fclose(output);if(diagnostic)fclose(diagnostic);return nil;}
    BOOL redirected=dup2(fileno(output),STDOUT_FILENO)>=0&&dup2(fileno(diagnostic),STDERR_FILENO)>=0;
    int status=redirected?CommandEntry((int)arguments.count+1,argv):-1;dispatches++;fflush(stdout);fflush(stderr);
    BOOL restored=dup2(out,STDOUT_FILENO)>=0&&dup2(err,STDERR_FILENO)>=0;close(out);close(err);
    NSData *publicBytes=Captured(output),*errorBytes=Captured(diagnostic);fclose(output);fclose(diagnostic);
    Check(redirected&&restored&&publicBytes&&errorBytes,@"entry output captured and restored");
    Check(before&&[before isEqual:Snapshot(base)],@"actual temporary sentinel nodes and bytes preserved");
    NSString *publicText=[[NSString alloc] initWithData:publicBytes encoding:NSUTF8StringEncoding],*errorText=[[NSString alloc] initWithData:errorBytes encoding:NSUTF8StringEncoding];
    Check(publicText&&errorText,@"public diagnostics remain UTF-8");
    for(NSString *secret in @[PrivateDetails,base,@"fixture-private-seed",@"fixture.private.error"])
        Check([publicText rangeOfString:secret].location==NSNotFound&&[errorText rangeOfString:secret].location==NSNotFound,@"no private NSError, path or seed disclosure");
    return @{@"exit":@(status),@"stdout":publicBytes?:NSData.data,@"stderr":errorBytes?:NSData.data};
}
static BOOL CommandBoolean(id value,BOOL expected){return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()&&[value boolValue]==expected;}
static void PublicStatus(NSDictionary *answer,BOOL current){NSData *bytes=answer[@"stdout"];id value=bytes.length?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;
    NSArray *keys=@[@"status",@"prepared",@"pairedPendingReady",@"runtimeAccepted",@"customerDeliveryReady"];
    Check([value isKindOfClass:NSDictionary.class]&&[value count]==keys.count&&[[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]],@"only exact public metadata fields are emitted");
    if(![value isKindOfClass:NSDictionary.class])return;
    Check([value[@"status"] isEqual:current?@"PASS":@"FAIL"]&&CommandBoolean(value[@"prepared"],current),@"public status matches current result");
    for(NSString *key in @[@"pairedPendingReady",@"runtimeAccepted",@"customerDeliveryReady"])Check(CommandBoolean(value[key],NO),@"public dispatch success carries no pending, runtime or delivery readiness");
    Check(bytes.length&&((const char *)bytes.bytes)[bytes.length-1]=='\n',@"public JSON has a complete newline-delimited record");
}
static void RefusalTests(NSString *base){NSArray *invalid=@[@[],@[@""],@[@"unknown"],@[@"Prepare"],@[@"PREPARE"],@[@"Check"],@[@"CHECK"],
    @[@"--help"],@[@"prepare",@"check"],@[@"check",@"prepare"],@[@"prepare",@""],@[@"check",@""],@[@"prepare",@"--force"],@[@"check",@"--force"]];
    for(NSArray *arguments in invalid){NSDictionary *answer=Invoke(arguments,0,0,0,1,base);
        Check([answer[@"exit"] intValue]==64,@"missing, unknown, empty, extra and case-variant commands refuse usage");
        Check(PrepareCalls==0&&OpenCalls==0&&CurrentCalls==0,@"invalid grammar never reaches a factory or current check");
        Check(RealUIDCalls==1&&EffectiveUIDCalls==1&&EffectiveGIDCalls==1,@"unchanged root role guard precedes grammar");
        Check([answer[@"stdout"] length]==0,@"usage refusal emits no prepared metadata");
    }
}
static void RoleTests(NSString *base){NSArray *roles=@[@[@501,@0,@0],@[@0,@501,@0],@[@0,@0,@501],@[@501,@501,@501]];
    for(NSArray *role in roles)for(NSArray *arguments in @[@[@"prepare"],@[@"check"],@[]]){
        NSDictionary *answer=Invoke(arguments,[role[0] unsignedIntValue],[role[1] unsignedIntValue],[role[2] unsignedIntValue],1,base);
        Check([answer[@"exit"] intValue]==77,@"real, effective or group role failure refuses including owner501/effective0");
        Check(PrepareCalls==0&&OpenCalls==0&&CurrentCalls==0,@"role failure never reaches either factory");
        Check([answer[@"stdout"] length]==0,@"role failure emits no prepared metadata");
    }
}
static void DispatchTests(NSString *base){for(NSString *command in @[@"prepare",@"check"]){for(NSInteger result=0;result<3;result++){
        NSDictionary *answer=Invoke(@[command],0,0,0,result,base);BOOL prepare=[command isEqual:@"prepare"],current=result==1;
        Check(PrepareCalls==(prepare?1U:0U)&&OpenCalls==(prepare?0U:1U),@"exact command invokes only its selected fixed factory once");
        Check(CurrentCalls==(result==0?0U:1U),@"current observation only follows a returned fixture object");
        Check([answer[@"exit"] intValue]==(current?0:1),@"selected factory/current failure returns failure without fallback");
        Check(RealUIDCalls==1&&EffectiveUIDCalls==1&&EffectiveGIDCalls==1,@"exact commands retain all three root role observations");
        PublicStatus(answer,current);
    }}
    for(NSUInteger i=0;i<3;i++){NSDictionary *answer=Invoke(@[@"check"],0,0,0,0,base);
        Check([answer[@"exit"] intValue]==1&&OpenCalls==1&&PrepareCalls==0&&CurrentCalls==0,@"repeated failing existing-only check never initializes or repairs");PublicStatus(answer,NO);}
}
int main(void){@autoreleasepool{char template[]="/tmp/socialbox-installation-command.XXXXXX";char *made=mkdtemp(template);Check(made!=NULL,@"new isolated command fixture");if(!made)return 1;
    NSString *base=[NSString stringWithUTF8String:made],*sentinel=[base stringByAppendingPathComponent:@"existing-state"],*link=[base stringByAppendingPathComponent:@"lost-state"];
    Check([@"fixture-private-seed" writeToFile:sentinel atomically:NO encoding:NSUTF8StringEncoding error:nil],@"existing synthetic state sentinel");
    Check(!symlink("absent-prior-anchor",link.fileSystemRepresentation),@"dangling synthetic established-state node");
    PrivateDetails=[NSString stringWithFormat:@"private NSError path=%@ seed=fixture-private-seed",base];
    RefusalTests(base);RoleTests(base);DispatchTests(base);
    Check([NSFileManager.defaultManager removeItemAtPath:base error:nil],@"remove only this fixture's temporary nodes");
    fprintf(stdout,"%s: %lu command boundary assertions, %lu failures, %lu inert entry dispatches\n",failures?"FAIL":"PASS",(unsigned long)checks,(unsigned long)failures,(unsigned long)dispatches);
    fprintf(stdout,"Scope: actual CLI routing with fixture-only identities and inert factories; no source provenance, native initialization, authority/history, device or customer readiness acceptance.\n");
    return failures?1:0;
}}
