#import <Foundation/Foundation.h>
#import "LBXNativeStorageInventory.h"
#import "LBXNativeStorageLayout.h"
#import "LBXNativeApplicationGate.h"
#import "LBXNativeStorageFence.h"
#import "LBXNativeIsolationJournal.h"
#import "LBXNativeFamilyStorageLayout.h"
#import "../../shared/RBXStorageGate.h"
#include <dirent.h>
#include <fcntl.h>
#include <string.h>

// CAPTURE ONLY. No process stop, code/data permission effect, selection write or
// journal publication. The only created files are the private empty journal lock
// and an aggregate report in the separate, fresh probe session directory.
static NSString *const CaptureScope=@"/private/var/root/socialbox-native-storage-capture-probes";
static BOOL DirectoryArgument(NSString *path){
    if(![path isKindOfClass:NSString.class]||![path.stringByDeletingLastPathComponent isEqual:CaptureScope])return NO;
    NSUUID *uuid=[[NSUUID alloc] initWithUUIDString:path.lastPathComponent];
    return uuid&&[[CaptureScope stringByAppendingPathComponent:uuid.UUIDString.lowercaseString] isEqual:path];
}
static NSArray *Names(int fd){int copy=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *stream=copy>=0?fdopendir(copy):NULL;if(!stream){if(copy>=0)close(copy);return nil;}NSMutableArray *names=[NSMutableArray array];BOOL good=YES;
    for(;;){errno=0;struct dirent *entry=readdir(stream);if(!entry){if(errno)good=NO;break;}if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
        NSString *name=[[NSString alloc] initWithBytes:entry->d_name length:strlen(entry->d_name) encoding:NSUTF8StringEncoding];if(!name||names.count>=8){good=NO;break;}[names addObject:name];}
    closedir(stream);return good?[names sortedArrayUsingSelector:@selector(compare:)]:nil;
}
static int OpenSession(NSString *path,NSArray *expectedNames){
    if(!DirectoryArgument(path))return -1;NSArray *parts=[path componentsSeparatedByString:@"/"];int parent=-1;
    for(NSUInteger i=0;i<parts.count;i++){
        const char *name=i?[parts[i] fileSystemRepresentation]:"/";int fd=i?openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);struct stat a,b;
        BOOL requiresPrivate=i+2>=parts.count;
        BOOL good=fd>=0&&!fstat(fd,&a)&&a.st_uid==0&&a.st_gid==0&&!(a.st_mode&0022)&&a.st_flags==0&&RBXStorageGateNoACL(fd)&&(!requiresPrivate||(a.st_mode&07777)==0700)&&
            !(i?fstatat(parent,name,&b,AT_SYMLINK_NOFOLLOW):lstat("/",&b))&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino;
        if(parent>=0)close(parent);if(!good){if(fd>=0)close(fd);return -1;}parent=fd;
    }
    if(![Names(parent) isEqual:expectedNames]){close(parent);return -1;}return parent;
}
static BOOL SessionSame(NSString *path,int fd){int current=OpenSession(path,@[@"journal"]);struct stat a,b;BOOL same=current>=0&&!fstat(fd,&a)&&!fstat(current,&b)&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino;if(current>=0)close(current);return same;
}
static NSDictionary *Base(void){return @{@"formatVersion":@1,@"kind":@"native-storage-fence-capture-only",@"status":@"REFUSED",@"stage":@"UNSTARTED",@"errorCode":@0,@"errorComponent":@"none",
    @"processesTerminated":@0,@"codePermissionsChanged":@NO,@"storagePermissionsChanged":@NO,@"selectionChanged":@NO,@"accountFileContentsRead":@NO,@"accountNamesExported":@NO,
    @"journalRecordAbsent":@NO,@"journalClosed":@NO,@"inventoryUnchanged":@NO,@"facebookInventoryUnchanged":@NO,@"codeOriginalsUnchanged":@NO,@"facebookCodeOriginalsUnchanged":@NO,@"facebookInventoryCaptured":@NO,@"facebookCodeCaptured":@NO,@"facebookStorageFenceCaptured":@NO,@"familyLayoutAttached":@NO,@"familyAllowedContainerCount":@0,@"runtimeAccepted":@NO,@"safeToGate":@NO,@"brokerIsolationVerified":@NO,@"isolationVerified":@NO};}
static void Refuse(NSMutableDictionary *result,NSString *stage,NSError *error){result[@"status"]=@"REFUSED";result[@"stage"]=stage;result[@"errorCode"]=@(error.code);
    NSDictionary *components=@{@"com.socialbox.native-storage-inventory":@"inventory",@"com.socialbox.native-storage-layout":@"layout",@"com.socialbox.native-family-storage-layout":@"family-layout",@"com.socialbox.native-application-gate":@"application-gate",@"com.socialbox.native-storage-fence":@"storage-fence",@"com.socialbox.native-isolation-journal":@"journal"};
    result[@"errorComponent"]=error?(components[error.domain]?:@"other"):@"none";
}
static BOOL OriginalCode(NSDictionary *record){NSArray *entries=record[@"executables"];if(![entries isKindOfClass:NSArray.class]||!entries.count||entries.count>129)return NO;
    for(NSDictionary *entry in entries){if(![entry isKindOfClass:NSDictionary.class])return NO;NSString *path=entry[@"path"];NSDictionary *original=entry[@"metadata"];struct stat s;
        if(![path isKindOfClass:NSString.class]||![original isKindOfClass:NSDictionary.class]||lstat(path.fileSystemRepresentation,&s)||!S_ISREG(s.st_mode)||s.st_nlink!=1)return NO;
        NSDictionary *current=@{@"device":@(s.st_dev),@"inode":@(s.st_ino),@"owner":@(s.st_uid),@"group":@(s.st_gid),@"mode":@(s.st_mode&07777),@"flags":@(s.st_flags),@"size":@(s.st_size),@"linkCount":@(s.st_nlink),@"mtimeSeconds":@(s.st_mtimespec.tv_sec),@"mtimeNanoseconds":@(s.st_mtimespec.tv_nsec),@"ctimeSeconds":@(s.st_ctimespec.tv_sec),@"ctimeNanoseconds":@(s.st_ctimespec.tv_nsec)};
        if(![current isEqual:original])return NO;
    }return YES;
}
static NSMutableDictionary *Capture(NSString *session,int sessionFD){
    NSMutableDictionary *result=[Base() mutableCopy];LBXNativeIsolationJournal *journal=nil;NSString *stage=@"OPEN_EMPTY_JOURNAL";NSError *error=nil;
    @try{
        journal=[LBXNativeIsolationJournal openDirectory:[session stringByAppendingPathComponent:@"journal"] create:YES error:&error];
        if(!journal){Refuse(result,stage,error);return result;}
        if([journal validatedCurrentRecord:&error]||error){Refuse(result,@"JOURNAL_NOT_EMPTY",error);return result;}
        result[@"journalRecordAbsent"]=@YES;
        stage=@"INVENTORY_CAPTURE";LBXNativeStorageInventory *inventory=[LBXNativeStorageInventory observeOfficialInstagram:&error];if(!inventory){Refuse(result,stage,error);return result;}
        stage=@"LAYOUT_CAPTURE";LBXNativeStorageLayout *layout=[LBXNativeStorageLayout layoutForInventory:inventory error:&error];if(!layout){Refuse(result,stage,error);return result;}
        NSDictionary *counts=layout.safeStatus;for(NSString *key in @[@"protectedNodeCount",@"regularFileCount",@"namespaceCount",@"storageRootCount",@"defaultOnlyStorageCount",@"defaultEntriesIncluded"]){if(counts[key])result[key]=counts[key];}
        result[@"profileDirectoryCount"]=inventory.safeStatus[@"profileDirectoryCount"]?:@0;
        stage=@"FACEBOOK_INVENTORY_CAPTURE";LBXNativeStorageInventory *facebook=[LBXNativeStorageInventory observeOfficialFacebook:&error];if(!facebook){Refuse(result,stage,error);return result;}
        stage=@"FACEBOOK_LAYOUT_CAPTURE";LBXNativeStorageLayout *facebookLayout=[LBXNativeStorageLayout layoutForInventory:facebook error:&error];if(!facebookLayout){Refuse(result,stage,error);return result;}
        stage=@"FAMILY_LAYOUT_CAPTURE";LBXNativeFamilyStorageLayout *family=[LBXNativeFamilyStorageLayout layoutWithInstagram:layout facebook:facebookLayout error:&error];if(!family){Refuse(result,stage,error);return result;}
        result[@"facebookInventoryCaptured"]=@YES;result[@"familyLayoutAttached"]=@YES;result[@"familyAllowedContainerCount"]=family.safeStatus[@"allowedContainerCount"]?:@0;
        if([family.safeStatus[@"isolationVerified"] boolValue]||[family.safeStatus[@"runtimeAccepted"] boolValue]){Refuse(result,@"FAMILY_LAYOUT_ADMISSION_CLAIM",nil);return result;}
        stage=@"CODE_CAPTURE";LBXNativeApplicationGate *gate=[LBXNativeApplicationGate captureOfficialInstagramBeforeDeadline:LBXNativeApplicationGateClock()+90 error:&error];if(!gate){Refuse(result,stage,error);return result;}
        result[@"executableCount"]=gate.safeStatus[@"executableCount"]?:@0;
        stage=@"FACEBOOK_CODE_CAPTURE";LBXNativeApplicationGate *facebookGate=[LBXNativeApplicationGate captureOfficialFacebookBeforeDeadline:LBXNativeApplicationGateClock()+90 error:&error];if(!facebookGate){Refuse(result,stage,error);return result;}
        result[@"facebookCodeCaptured"]=@YES;result[@"facebookExecutableCount"]=facebookGate.safeStatus[@"executableCount"]?:@0;
        if([facebookGate.safeStatus[@"runtimeAccepted"] boolValue]){Refuse(result,@"FACEBOOK_CODE_ADMISSION_CLAIM",nil);return result;}
        stage=@"INVENTORY_CODE_BINDING";if(![inventory.privateDictionary[@"installation"] isEqual:gate.privateJournalRecord[@"binding"]]){Refuse(result,stage,nil);return result;}
        stage=@"FACEBOOK_INVENTORY_CODE_BINDING";if(![facebook.privateDictionary[@"installation"] isEqual:facebookGate.privateJournalRecord[@"binding"]]){Refuse(result,stage,nil);return result;}
        stage=@"STORAGE_FENCE_CAPTURE";LBXNativeStorageFence *fence=[LBXNativeStorageFence captureInventory:inventory applicationGate:gate journal:journal error:&error];if(!fence){Refuse(result,stage,error);return result;}
        if(![fence.safeStatus[@"phase"] isEqual:@"captured"]||[fence.safeStatus[@"lastDrainVerified"] boolValue]||[gate.safeStatus[@"closureAttempted"] boolValue]){Refuse(result,@"UNEXPECTED_CAPTURE_STATE",nil);return result;}
        stage=@"FACEBOOK_STORAGE_FENCE_CAPTURE";LBXNativeStorageFence *facebookFence=[LBXNativeStorageFence captureInventory:facebook applicationGate:facebookGate journal:journal error:&error];if(!facebookFence){Refuse(result,stage,error);return result;}
        if(![facebookFence.safeStatus[@"phase"] isEqual:@"captured"]||[facebookFence.safeStatus[@"lastDrainVerified"] boolValue]||[facebookFence.safeStatus[@"runtimeAccepted"] boolValue]||[facebookGate.safeStatus[@"closureAttempted"] boolValue]){Refuse(result,@"UNEXPECTED_FACEBOOK_CAPTURE_STATE",nil);return result;}
        result[@"facebookStorageFenceCaptured"]=@YES;
        stage=@"REOBSERVE_STORAGE_AND_CODE";LBXNativeStorageInventory *after=[LBXNativeStorageInventory observeOfficialInstagram:&error];
        LBXNativeStorageInventory *facebookAfter=[LBXNativeStorageInventory observeOfficialFacebook:&error];
        result[@"inventoryUnchanged"]=@(after&&[inventory.privateDictionary isEqual:after.privateDictionary]);
        result[@"facebookInventoryUnchanged"]=@(facebookAfter&&[facebook.privateDictionary isEqual:facebookAfter.privateDictionary]);
        result[@"codeOriginalsUnchanged"]=@(OriginalCode(gate.privateJournalRecord));
        result[@"facebookCodeOriginalsUnchanged"]=@(OriginalCode(facebookGate.privateJournalRecord));
        if(![result[@"inventoryUnchanged"] boolValue]||![result[@"facebookInventoryUnchanged"] boolValue]||![result[@"codeOriginalsUnchanged"] boolValue]||![result[@"facebookCodeOriginalsUnchanged"] boolValue]){Refuse(result,stage,error);return result;}
        stage=@"JOURNAL_STILL_EMPTY";result[@"journalRecordAbsent"]=@([journal validatedCurrentRecord:&error]==nil&&!error);
        if(![result[@"journalRecordAbsent"] boolValue]){Refuse(result,stage,error);return result;}
        stage=@"SESSION_NAMESPACE_UNCHANGED";if(!SessionSame(session,sessionFD)){Refuse(result,stage,nil);return result;}
        result[@"status"]=@"CAPTURED";result[@"stage"]=@"COMPLETE";
    }@catch(__unused NSException *exception){Refuse(result,stage,nil);result[@"observationException"]=@YES;}
    @finally{if(journal){[journal close];result[@"journalClosed"]=@YES;}}
    return result;
}
static BOOL Save(int fd,NSDictionary *result){NSData *data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];if(!data.length||data.length>32768)return NO;
    int output=openat(fd,"capture-status.json",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);struct stat s;BOOL good=output>=0&&!fstat(output,&s)&&S_ISREG(s.st_mode)&&s.st_uid==0&&s.st_gid==0&&(s.st_mode&07777)==0600&&s.st_nlink==1&&s.st_flags==0&&RBXStorageGateNoACL(output);NSUInteger offset=0;unsigned interrupts=0;
    while(good&&offset<data.length){ssize_t n=write(output,(const char *)data.bytes+offset,data.length-offset);if(n<0&&errno==EINTR&&++interrupts<=4)continue;if(n<=0){good=NO;break;}offset+=(NSUInteger)n;}if(good)good=!fsync(output)&&!fsync(fd);if(output>=0&&close(output))good=NO;return good;
}
static int Emit(NSDictionary *record,int code){NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];if(!data||fwrite(data.bytes,1,data.length,stdout)!=data.length||putchar('\n')==EOF)return 2;return code;}
int main(int argc,const char **argv){@autoreleasepool{
    NSMutableDictionary *result=[Base() mutableCopy];if(getuid()!=0||geteuid()!=0){Refuse(result,@"ROOT_REQUIRED",nil);return Emit(result,77);}if(argc!=2){Refuse(result,@"ARGUMENT_REQUIRED",nil);return Emit(result,2);}umask(077);
    NSString *session=[[NSString alloc] initWithUTF8String:argv[1]];if(!DirectoryArgument(session)){Refuse(result,@"SESSION_SCOPE",nil);return Emit(result,2);}int fd=OpenSession(session,@[]);
    if(fd<0){Refuse(result,@"SESSION_NOT_PRIVATE_EMPTY",nil);return Emit(result,2);}result=Capture(session,fd);
    if(!Save(fd,result)){Refuse(result,@"SAVE_STATUS",nil);close(fd);return Emit(result,2);}close(fd);return Emit(result,[result[@"status"] isEqual:@"CAPTURED"]?0:3);
}}
