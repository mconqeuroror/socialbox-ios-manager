#import "LBXNativeIsolationJournal.h"
#import "../../shared/RBXStorageGate.h"
#include <dirent.h>
#include <fcntl.h>
#include <sys/file.h>
#include <string.h>

static const NSUInteger Limit=8*1024*1024;
static const uint64_t MaximumGeneration=9007199254740991ULL;
static BOOL Fail(NSError **error,NSInteger code){if(error){*error=[NSError errorWithDomain:@"com.socialbox.native-isolation-journal" code:code userInfo:@{NSLocalizedDescriptionKey:
    code==2?@"Root journal ownership required":code==3?@"Journal is busy":code==4?@"Journal contains unknown or invalid state":code==5?@"Previous journal record does not match":code==6?@"Journal record exceeds its bounds":@"Journal operation failed; reopen to reconcile"}];}return NO;}
static BOOL Root(BOOL testing){
#if LBX_NATIVE_ISOLATION_JOURNAL_TESTING
    if(testing)return YES;
#else
    (void)testing;
#endif
    return getuid()==0&&geteuid()==0;
}
static BOOL Name(NSString *s){return [s isKindOfClass:NSString.class]&&s.length&&[s lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<256&&![s isEqual:@"."]&&![s isEqual:@".."]&&![s containsString:@"/"]&&![s containsString:@"\\"]&&[s rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound;}
static BOOL Path(NSString *path){if(![path isKindOfClass:NSString.class]||![path hasPrefix:@"/"]||path.length>=4096)return NO;NSArray *parts=[path componentsSeparatedByString:@"/"];if(parts.count<3)return NO;for(NSUInteger i=1;i<parts.count;i++)if(!Name(parts[i]))return NO;return YES;}
static BOOL SameStat(struct stat a,struct stat b){return a.st_dev==b.st_dev&&a.st_ino==b.st_ino&&a.st_uid==b.st_uid&&a.st_gid==b.st_gid&&(a.st_mode&07777)==(b.st_mode&07777)&&a.st_flags==b.st_flags;}
static NSData *StatData(struct stat s){return [NSData dataWithBytes:&s length:sizeof(s)];}
static struct stat StatValue(NSData *data){struct stat s={0};if(data.length==sizeof(s))memcpy(&s,data.bytes,sizeof(s));return s;}
static BOOL Owner(struct stat s,BOOL testing){
#if LBX_NATIVE_ISOLATION_JOURNAL_TESTING
    if(testing)return s.st_uid==geteuid()&&s.st_gid==getegid();
#else
    (void)testing;
#endif
    return s.st_uid==0&&s.st_gid==0;
}
static BOOL Directory(int fd,BOOL leaf,BOOL testing){struct stat s;if(fd<0||fstat(fd,&s)||!S_ISDIR(s.st_mode)||!RBXStorageGateNoACL(fd))return NO;
    if(leaf)return Owner(s,testing)&&(s.st_mode&07777)==0700&&s.st_flags==0;
#if LBX_NATIVE_ISOLATION_JOURNAL_TESTING
    if(testing)return (s.st_uid==0||s.st_uid==geteuid())&&(!(s.st_mode&0022)||(s.st_uid==0&&(s.st_mode&S_ISVTX)));
#endif
    return s.st_uid==0&&!(s.st_mode&0022)&&s.st_flags==0;
}
static BOOL File(int fd,BOOL testing,BOOL lock){struct stat s;return fd>=0&&!fstat(fd,&s)&&S_ISREG(s.st_mode)&&Owner(s,testing)&&(s.st_mode&07777)==0600&&s.st_nlink==1&&s.st_flags==0&&RBXStorageGateNoACL(fd)&&(lock?s.st_size==0:(s.st_size>0&&(uint64_t)s.st_size<=Limit));}
static BOOL Bound(int parent,const char *name,int fd){struct stat a,b;return fd>=0&&!fstat(fd,&a)&&!fstatat(parent,name,&b,AT_SYMLINK_NOFOLLOW)&&SameStat(a,b)&&S_ISREG(b.st_mode);}
static BOOL Integer(id x,uint64_t maximum){return [x isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)x)!=CFBooleanGetTypeID()&&!CFNumberIsFloatType((__bridge CFNumberRef)x)&&[x longLongValue]>0&&[x unsignedLongLongValue]<=maximum;}
static NSData *Encode(NSDictionary *record){if(![record isKindOfClass:NSDictionary.class]||![NSJSONSerialization isValidJSONObject:record])return nil;NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];return data.length&&data.length<=Limit?data:nil;}
static BOOL Envelope(id value){return [value isKindOfClass:NSDictionary.class]&&[value count]==3&&Integer(value[@"formatVersion"],1)&&Integer(value[@"generation"],MaximumGeneration)&&[value[@"payload"] isKindOfClass:NSDictionary.class];}
static NSDictionary *Decode(NSData *bytes){id value=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];return Envelope(value)&&[Encode(value) isEqual:bytes]?value:nil;}
#if LBX_NATIVE_ISOLATION_JOURNAL_TESTING
static void(^Fault)(NSString *);
static void At(NSString *stage){void(^callback)(NSString *);@synchronized(LBXNativeIsolationJournal.class){callback=Fault;}if(callback)callback(stage);}
#else
static void At(__unused NSString *stage){}
#endif

@interface LBXNativeIsolationJournal ()
- (instancetype)initPrivateDirectory:(int)directory lock:(int)lock pins:(NSArray *)pins role:(BOOL)testing;
@end
@implementation LBXNativeIsolationJournal {
    int _directory,_lock;
    NSArray *_pins;
    NSDictionary *_record;
    BOOL _testing,_closed,_failed;
}
- (instancetype)initPrivateDirectory:(int)directory lock:(int)lock pins:(NSArray *)pins role:(BOOL)testing {if((self=[super init])){_directory=directory;_lock=lock;_pins=pins;_testing=testing;}return self;}
- (void)dealloc {[self close];}
- (void)close {@synchronized(self){if(_closed)return;_closed=YES;if(_lock>=0){flock(_lock,LOCK_UN);close(_lock);_lock=-1;}for(NSDictionary *pin in _pins)close([pin[@"fd"] intValue]);_pins=nil;_directory=-1;}}
- (BOOL)valid:(NSError **)error {
    if(_closed||_failed)return Fail(error,4);if(!Root(_testing))return Fail(error,2);
    for(NSDictionary *pin in _pins){int fd=[pin[@"fd"] intValue],parent=[pin[@"parent"] intValue];struct stat s,p;
        if(!Directory(fd,[pin[@"leaf"] boolValue],_testing)||fstat(fd,&s)||!SameStat(s,StatValue(pin[@"stat"]))||(parent<0?lstat("/",&p):fstatat(parent,[pin[@"name"] fileSystemRepresentation],&p,AT_SYMLINK_NOFOLLOW))||!SameStat(s,p)||!S_ISDIR(p.st_mode))return Fail(error,4);}
    return File(_lock,_testing,YES)&&Bound(_directory,"journal.lock",_lock)?YES:Fail(error,4);
}
- (BOOL)knownFiles:(NSError **)error {
    int copy=openat(_directory,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);DIR *stream=copy<0?NULL:fdopendir(copy);if(!stream){if(copy>=0)close(copy);return Fail(error,1);}BOOL good=YES;NSUInteger count=0;
    for(;;){errno=0;struct dirent *entry=readdir(stream);if(!entry){if(errno)good=NO;break;}if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
        if(++count>2||(strcmp(entry->d_name,"journal.lock")&&strcmp(entry->d_name,"record.json"))){good=NO;break;}}
    closedir(stream);return good?YES:Fail(error,4);
}
- (BOOL)readRecord:(NSDictionary **)out error:(NSError **)error {
    *out=nil;int fd=openat(_directory,"record.json",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);if(fd<0)return errno==ENOENT?YES:Fail(error,4);
    struct stat before,after;BOOL good=File(fd,_testing,NO)&&Bound(_directory,"record.json",fd)&&!fstat(fd,&before);NSMutableData *data=good?[NSMutableData dataWithLength:(NSUInteger)before.st_size]:nil;NSUInteger offset=0;unsigned interruptions=0;
    while(good&&offset<data.length){ssize_t n=read(fd,(char *)data.mutableBytes+offset,data.length-offset);if(n<0&&errno==EINTR&&++interruptions<=4)continue;if(n<=0){good=NO;break;}offset+=(NSUInteger)n;}
    char extra;if(good)good=read(fd,&extra,1)==0&&File(fd,_testing,NO)&&Bound(_directory,"record.json",fd)&&!fstat(fd,&after)&&SameStat(before,after)&&before.st_size==after.st_size&&before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec&&before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec&&before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec&&before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec;
    close(fd);NSDictionary *record=good?Decode(data):nil;if(!record)return Fail(error,4);*out=record;return YES;
}
- (NSDictionary *)currentRecord {@synchronized(self){return _record;}}
- (NSDictionary *)validatedCurrentRecord:(NSError **)error {@synchronized(self){
    if(error)*error=nil;if(![self valid:error]||![self knownFiles:error])return nil;NSDictionary *current=nil;
    if(![self readRecord:&current error:error])return nil;
    if((_record||current)&&![_record isEqual:current]){Fail(error,5);return nil;}return current;
}}
- (BOOL)compareRecord:(NSDictionary *)expected replaceWith:(NSDictionary *)payload error:(NSError **)error {@synchronized(self){
    if(error)*error=nil;int stageFD=-1;@try {
        if(![self valid:error]||![self knownFiles:error])return NO;NSDictionary *current=nil;if(![self readRecord:&current error:error])return NO;
        BOOL matches=(!expected&&!current)||(expected&&current&&[expected isEqual:current]);BOOL unchanged=(!_record&&!current)||(_record&&current&&[_record isEqual:current]);
        if(!matches||!unchanged)return Fail(error,5);uint64_t previous=[current[@"generation"] unsignedLongLongValue];if(previous>=MaximumGeneration||![payload isKindOfClass:NSDictionary.class])return Fail(error,6);
        NSDictionary *next=@{@"formatVersion":@1,@"generation":@(previous+1),@"payload":payload};NSData *data=Encode(next);NSDictionary *immutable=data?Decode(data):nil;if(!immutable)return Fail(error,6);
        NSString *stage=[NSString stringWithFormat:@".record-%@.stage",NSUUID.UUID.UUIDString.lowercaseString];int fd=openat(_directory,stage.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);stageFD=fd;
        // From this point any failure needs close/reopen; retained stage files
        // deliberately prevent a later writer from treating an interruption as clean.
        _failed=YES;struct stat s;BOOL good=fd>=0&&!fstat(fd,&s)&&S_ISREG(s.st_mode)&&Owner(s,_testing)&&(s.st_mode&07777)==0600&&s.st_nlink==1&&s.st_flags==0&&RBXStorageGateNoACL(fd)&&Bound(_directory,stage.fileSystemRepresentation,fd);
        if(good)At(@"stage-created");NSUInteger offset=0;unsigned interruptions=0;
        while(good&&offset<data.length){ssize_t n=write(fd,(const char *)data.bytes+offset,data.length-offset);if(n<0&&errno==EINTR&&++interruptions<=4)continue;if(n<=0){good=NO;break;}offset+=(NSUInteger)n;}
        if(good)good=!fsync(fd)&&File(fd,_testing,NO)&&Bound(_directory,stage.fileSystemRepresentation,fd);if(good)At(@"stage-synced");if(fd>=0&&close(fd))good=NO;stageFD=-1;
        _failed=NO;if(good)good=[self valid:error];_failed=YES;
        NSDictionary *check=nil;if(good)good=[self readRecord:&check error:error]&&((!current&&!check)||(current&&[current isEqual:check]));
        if(good)good=!renameat(_directory,stage.fileSystemRepresentation,_directory,"record.json");if(good)At(@"renamed");
        if(good)good=!fsync(_directory);if(good)At(@"parent-synced");
        _failed=NO;if(good)good=[self valid:error]&&[self knownFiles:error]&&[self readRecord:&check error:error]&&[check isEqual:immutable];
        if(!good){_failed=YES;return Fail(error,1);}_record=check;return YES;
    }@catch(__unused NSException *exception){if(stageFD>=0)close(stageFD);_failed=YES;return Fail(error,1);}
}}
- (NSString *)description{return [NSString stringWithFormat:@"<LBXNativeIsolationJournal closed=%d record=%d>",_closed,_record!=nil];}
- (NSString *)debugDescription{return self.description;}

static LBXNativeIsolationJournal *Open(NSString *path,BOOL create,BOOL testing,NSError **error){
    if(error)*error=nil;if(!Root(testing)){Fail(error,2);return nil;}if(!Path(path)){Fail(error,4);return nil;}
    NSMutableArray *pins=[NSMutableArray array];NSArray *parts=[path componentsSeparatedByString:@"/"];int parent=-1,lock=-1;LBXNativeIsolationJournal *result=nil;
    @try {for(NSUInteger i=0;i<parts.count;i++){BOOL leaf=i==parts.count-1;NSString *part=i?parts[i]:@"/";int fd=i?openat(parent,part.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            if(fd<0&&errno==ENOENT&&leaf&&create&&!mkdirat(parent,part.fileSystemRepresentation,0700)){if(fsync(parent)){Fail(error,1);break;}fd=openat(parent,part.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);}
            struct stat s,p;if(fd<0||!Directory(fd,leaf,testing)||fstat(fd,&s)||(i?fstatat(parent,part.fileSystemRepresentation,&p,AT_SYMLINK_NOFOLLOW):lstat("/",&p))||!SameStat(s,p)){if(fd>=0)close(fd);Fail(error,4);break;}
            [pins addObject:@{@"fd":@(fd),@"parent":@(parent),@"name":part,@"stat":StatData(s),@"leaf":@(leaf)}];parent=fd;
            if(leaf){
                // Check names before creating our lock file in an existing directory.
                LBXNativeIsolationJournal *temporary=[[LBXNativeIsolationJournal alloc] initPrivateDirectory:fd lock:-1 pins:@[] role:testing];BOOL known=[temporary knownFiles:error];[temporary close];if(!known)break;
                lock=openat(fd,"journal.lock",O_RDWR|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC|(create?O_CREAT:0),0600);
                if(!File(lock,testing,YES)||!Bound(fd,"journal.lock",lock)){Fail(error,4);break;}
                if(flock(lock,LOCK_EX|LOCK_NB)){Fail(error,3);break;}if(fsync(lock)||fsync(fd)){Fail(error,1);break;}
                result=[[LBXNativeIsolationJournal alloc] initPrivateDirectory:fd lock:lock pins:[pins copy] role:testing];lock=-1;[pins removeAllObjects];NSDictionary *record=nil;
                if(![result valid:error]||![result knownFiles:error]||![result readRecord:&record error:error]){[result close];return nil;}result->_record=record;
            }
        }
    }@catch(__unused NSException *exception){[result close];result=nil;Fail(error,1);}
    if(lock>=0)close(lock);for(NSDictionary *pin in pins)close([pin[@"fd"] intValue]);return result;
}
+ (instancetype)openDirectory:(NSString *)directory create:(BOOL)create error:(NSError **)error {return Open(directory,create,NO,error);}
#if LBX_NATIVE_ISOLATION_JOURNAL_TESTING
+ (instancetype)testOpenDirectory:(NSString *)directory create:(BOOL)create error:(NSError **)error {return Open(directory,create,YES,error);}
+ (void)testSetFault:(void (^)(NSString *))fault {@synchronized(self){Fault=[fault copy];}}
#endif
@end
