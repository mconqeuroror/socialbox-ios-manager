#import <Foundation/Foundation.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <spawn.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdatomic.h>
extern char **environ;
static unsigned Checks,Failures,SyncCount;
static int FailSync,CrashSync;
static BOOL FailRename,CrashRename,FailWrite,InterruptRead,InterruptWrite,ShortWrite;
static ssize_t CheckedRead(int fd,void *bytes,size_t count){if(InterruptRead){InterruptRead=NO;errno=EINTR;return -1;}return read(fd,bytes,count);}
static ssize_t CheckedWrite(int fd,const void *bytes,size_t count){if(InterruptWrite){InterruptWrite=NO;errno=EINTR;return -1;}if(FailWrite){errno=ENOSPC;return -1;}return write(fd,bytes,ShortWrite?MIN(count,7):count);}
static int CheckedSync(int fd){SyncCount++;if(CrashSync && SyncCount==(unsigned)CrashSync)_exit(78);if(FailSync && SyncCount==(unsigned)FailSync){errno=EIO;return -1;}return fsync(fd);}
static int CheckedRename(int a,const char *b,int c,const char *d){if(CrashRename)_exit(77);if(FailRename){errno=EIO;return -1;}return renameat(a,b,c,d);}
#define read CheckedRead
#define write CheckedWrite
#define fsync CheckedSync
#define renameat CheckedRename
#import "../lucid/HelperSafety/LBXGlobalMetadata.m"
#undef read
#undef write
#undef fsync
#undef renameat
static void Check(BOOL pass,const char *reason){Checks++;if(!pass){Failures++;fprintf(stderr,"FAIL %s\n",reason);}}
static NSData *Bytes(NSString *path){return [NSData dataWithContentsOfFile:path];}
static NSDictionary *Load(NSString *path){return [NSDictionary dictionaryWithContentsOfFile:path];}
static void Restore(NSString *path,NSData *data){Check([data writeToFile:path atomically:YES],"restore owned fixture");chmod(path.fileSystemRepresentation,0644);}
static BOOL LegacyWrite(NSString *path,NSDictionary *metadata){
    int fd=open([path stringByAppendingString:@".lock"].fileSystemRepresentation,O_RDWR|O_CREAT,0644);
    // Reconstructed original bug: open failure does not prevent publication.
    if(fd<0)return [metadata writeToFile:path atomically:YES];
    flock(fd,LOCK_EX);BOOL result=[metadata writeToFile:path atomically:YES];flock(fd,LOCK_UN);close(fd);return result;
}
static void CrashChild(const char *exe,NSString *path,const char *mode,int expected){
    pid_t pid=-1;char *args[]={(char *)exe,(char *)mode,(char *)path.fileSystemRepresentation,NULL};
    int status=0,spawned=posix_spawn(&pid,exe,NULL,NULL,args,environ);Check(spawned==0&&pid>1,"spawn owned crash-writer");if(spawned)return;
    pid_t result;do{result=waitpid(pid,&status,0);}while(result<0&&errno==EINTR);
    Check(result==pid&&WIFEXITED(status)&&WEXITSTATUS(status)==expected,"writer interrupted at actual commit boundary");
}
int main(int argc,char **argv){@autoreleasepool{
    if(argc==3){CrashRename=!strcmp(argv[1],"--crash-before");CrashSync=!strcmp(argv[1],"--crash-after")?2:0;
        return LBXWriteGlobalMetadata(@(argv[2]),@{@"marker":@"published-after-interruption"})?0:1;}
    char resolved[PATH_MAX];if(!realpath(NSTemporaryDirectory().fileSystemRepresentation,resolved))return 2;
    NSString *root=[@(resolved) stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    Check([[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:nil],"create private fixture root");
    NSString *path=[root stringByAppendingPathComponent:@"Containers/global_metadata.plist"];
    NSString *lock=[path stringByAppendingString:@".lock"];
    Check(LBXMutateGlobalMetadata(path,^(NSMutableDictionary *m){Check([m[@"version"] isEqual:@2]&&[m[@"nextContainerID"] isEqual:@1]&&[m[@"activeContainer"] isEqual:@0]&&[m[@"containers"] count]==0,"recovered version-2 missing-file defaults");m[@"marker"]=@"retained";}),"first mutation creates known schema");
    NSData *baseline=Bytes(path);Check(baseline.length>0,"metadata persisted");
    unlink(lock.fileSystemRepresentation);mkdir(lock.fileSystemRepresentation,0700);
    Check(LegacyWrite(path,@{@"marker":@"wrongly overwritten"})&&![Bytes(path) isEqual:baseline],"original lock-open failure reproduced: writes anyway");
    Restore(path,baseline);
    Check(!LBXWriteGlobalMetadata(path,@{@"marker":@"must not write"})&&[Bytes(path) isEqual:baseline],"lock-open error leaves original metadata intact");rmdir(lock.fileSystemRepresentation);
    NSString *foreign=[root stringByAppendingPathComponent:@"foreign"];
    Check([@"foreign marker" writeToFile:foreign atomically:YES encoding:NSUTF8StringEncoding error:nil],"create owned foreign fixture");
    symlink(foreign.fileSystemRepresentation,lock.fileSystemRepresentation);
    Check(!LBXWriteGlobalMetadata(path,@{})&&[Bytes(path) isEqual:baseline],"lock symlink refused without fallback");unlink(lock.fileSystemRepresentation);
    int held=open(lock.fileSystemRepresentation,O_CREAT|O_RDWR,0644);flock(held,LOCK_EX);
    double started=LBXMetadataClock();
    Check(!LBXWriteGlobalMetadata(path,@{})&&[Bytes(path) isEqual:baseline],"held lock refuses concurrent publication");
    Check(LBXMetadataClock()-started<1.5,"lock wait is bounded");flock(held,LOCK_UN);close(held);
    Check(!LBXMutateGlobalMetadata(path,^(NSMutableDictionary *m){m[@"marker"]=@"not committed";@throw [NSException exceptionWithName:@"fixture" reason:@"must not be logged" userInfo:nil];})&&[Bytes(path) isEqual:baseline],"exception leaves original file and releases lock");
    InterruptRead=YES;InterruptWrite=YES;ShortWrite=YES;
    Check(LBXWriteGlobalMetadata(path,Load(path)),"interrupted reads/writes and short writes complete");ShortWrite=NO;baseline=Bytes(path);
    for(unsigned phase=0;phase<3;phase++){
        SyncCount=0;FailWrite=phase==0;FailSync=phase==1?1:0;FailRename=phase==2;
        Check(!LBXWriteGlobalMetadata(path,@{@"marker":@"must not commit"})&&[Bytes(path) isEqual:baseline],"ENOSPC/file-sync/rename failure preserves old file");
        FailWrite=NO;FailSync=0;FailRename=NO;
    }
    SyncCount=0;FailSync=2;
    Check(!LBXWriteGlobalMetadata(path,@{@"marker":@"published but durability uncertain"})&&[Load(path)[@"marker"] isEqual:@"published but durability uncertain"],"post-rename directory-sync failure returns NO without claiming rollback");FailSync=0;
    Restore(path,baseline);
    Check(!LBXWriteGlobalMetadata(path,@{@"unsupported":[NSObject new]})&&[Bytes(path) isEqual:baseline],"non-plist value rejected");
    Check(!LBXWriteGlobalMetadata(path,@{@"large":[NSMutableData dataWithLength:17*1024*1024]})&&[Bytes(path) isEqual:baseline],"oversized output rejected");
    NSData *corrupt=[@"corrupt existing bytes" dataUsingEncoding:NSUTF8StringEncoding];Restore(path,corrupt);
    Check(!LBXMutateGlobalMetadata(path,^(NSMutableDictionary *m){m[@"marker"]=@"reset";})&&[Bytes(path) isEqual:corrupt],"corruption never silently resets account list");Restore(path,baseline);
    Check(!LBXMutateGlobalMetadata(path,^(NSMutableDictionary *m){m[@"marker"]=@"stale";[@{@"marker":@"external edit"} writeToFile:path atomically:YES];})&&[Load(path)[@"marker"] isEqual:@"external edit"],"non-cooperating replacement detected before rename");Restore(path,baseline);
    NSString *alias=[root stringByAppendingPathComponent:@"alias"];symlink(path.stringByDeletingLastPathComponent.fileSystemRepresentation,alias.fileSystemRepresentation);
    Check(!LBXWriteGlobalMetadata([alias stringByAppendingPathComponent:@"global_metadata.plist"],@{})&&[Bytes(path) isEqual:baseline],"symlink directory refused");
    NSString *saved=[root stringByAppendingPathComponent:@"saved"];
    rename(path.fileSystemRepresentation,saved.fileSystemRepresentation);mkfifo(path.fileSystemRepresentation,0600);
    started=LBXMetadataClock();Check(!LBXWriteGlobalMetadata(path,@{})&&LBXMetadataClock()-started<.5,"FIFO target refused without blocking");unlink(path.fileSystemRepresentation);rename(saved.fileSystemRepresentation,path.fileSystemRepresentation);
    link(path.fileSystemRepresentation,saved.fileSystemRepresentation);
    Check(!LBXWriteGlobalMetadata(path,@{})&&[Bytes(path) isEqual:baseline],"hardlinked metadata refused");unlink(saved.fileSystemRepresentation);
    Check(LBXWriteGlobalMetadata(path,@{@"counter":@0,@"containers":@[]}),"prepare concurrent updates");
    __block atomic_uint successes=0;dispatch_group_t group=dispatch_group_create();
    for(unsigned i=0;i<40;i++)dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{@autoreleasepool{
        BOOL ok=LBXMutateGlobalMetadata(path,^(NSMutableDictionary *m){unsigned value=[m[@"counter"] unsignedIntValue];m[@"counter"]=@(value+1);[m[@"containers"] addObject:@{ @"id":@(i),@"marker":@(i+1000)}];});
        if(ok)atomic_fetch_add(&successes,1);
    }});
    Check(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0,"concurrent mutations finish");
    unsigned count=atomic_load(&successes);NSDictionary *after=Load(path);
    Check(count==40&&[after[@"counter"] unsignedIntValue]==40&&[after[@"containers"] count]==40,"forty serialized mutations lose no update");
    NSMutableSet *ids=[NSMutableSet set];for(NSDictionary *row in after[@"containers"]){[ids addObject:row[@"id"]];Check([row[@"marker"] unsignedIntValue]==[row[@"id"] unsignedIntValue]+1000,"each container marker retained");}
    Check(ids.count==40,"all forty distinct IDs retained");
    baseline=Bytes(path);CrashChild(argv[0],path,"--crash-before",77);
    Check([Bytes(path) isEqual:baseline],"interruption before rename keeps original file");
    CrashChild(argv[0],path,"--crash-after",78);
    Check([Load(path)[@"marker"] isEqual:@"published-after-interruption"],"interruption after rename leaves complete new plist");
    Check(LBXWriteGlobalMetadata(path,@{@"marker":@"recovered"}),"process death released lock; next write works");
    Check([[NSFileManager defaultManager] removeItemAtPath:root error:nil],"remove only owned fixture root");
    printf("%s global metadata: %u checks, %u failures; real filesystem/concurrency/crash boundaries\n",Failures?"FAIL":"PASS",Checks,Failures);return Failures?1:0;
}}
