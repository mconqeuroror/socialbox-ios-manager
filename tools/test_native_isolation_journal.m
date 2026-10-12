#import <Foundation/Foundation.h>
#import "../lucid/Switching/LBXNativeIsolationJournal.h"
#include <sys/acl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <membership.h>
#include <unistd.h>

static NSUInteger Checks;
static void Check(BOOL ok,NSString *label){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",label.UTF8String);exit(1);}}
static NSString *Join(NSString *a,NSString *b){return [a stringByAppendingPathComponent:b];}
static void Dir(NSString *p){Check([NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil],@"fixture directory");}
static void Bytes(NSString *p,NSData *data){Check([data writeToFile:p atomically:NO]&&!chmod(p.fileSystemRepresentation,0600),@"fixture bytes");}
static void JSON(NSString *p,id value){Bytes(p,[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil]);}
static BOOL ACL(NSString *path,BOOL populated){acl_t acl=acl_init(populated?1:0);BOOL good=acl!=NULL;if(populated){uuid_t subject;acl_entry_t entry;acl_permset_t permissions;good=good&&!mbr_uid_to_uuid(geteuid(),subject)&&!acl_create_entry(&acl,&entry)&&!acl_set_tag_type(entry,ACL_EXTENDED_ALLOW)&&!acl_set_qualifier(entry,subject)&&!acl_get_permset(entry,&permissions)&&!acl_add_perm(permissions,ACL_READ_DATA);}if(good)good=acl_set_file(path.fileSystemRepresentation,ACL_TYPE_EXTENDED,acl)==0;if(acl)acl_free(acl);return good;}
@interface Fixture:NSObject
@property NSString *base,*path;
@end
@implementation Fixture
- (instancetype)init {if((self=[super init])){NSString *raw=Join(NSTemporaryDirectory(),[@"socialbox-journal-" stringByAppendingString:NSUUID.UUID.UUIDString]);Dir(raw);char *p=realpath(raw.fileSystemRepresentation,NULL);Check(p!=NULL,@"canonical fixture root");_base=@(p);free(p);_path=Join(_base,@"journal");}return self;}
- (void)dealloc{[NSFileManager.defaultManager removeItemAtPath:_base error:nil];}
@end
static LBXNativeIsolationJournal *Open(Fixture *f,BOOL create){return [LBXNativeIsolationJournal testOpenDirectory:f.path create:create error:nil];}
static NSDictionary *Payload(NSString *phase){return @{@"phase":phase,@"originals":@[@{@"path":@"/private/fixture/profile",@"device":@1,@"inode":@42,@"uid":@501,@"gid":@501,@"mode":@0755,@"flags":@0}]};}
static void Seed(Fixture *f){LBXNativeIsolationJournal *j=Open(f,YES);Check(j&&[j compareRecord:nil replaceWith:Payload(@"before") error:nil],@"seed journal");[j close];}
static void Bad(NSString *label,void(^change)(Fixture *)){@autoreleasepool{Fixture *f=[Fixture new];Seed(f);change(f);Check(Open(f,NO)==nil,label);}}
int main(void){@autoreleasepool{
    Fixture *f=[Fixture new];Check(Open(f,NO)==nil,@"no-create refuses absent directory");LBXNativeIsolationJournal *j=Open(f,YES);Check(j&&j.currentRecord==nil,@"fresh private journal starts without record");
    Check(Open(f,YES)==nil,@"second handle cannot acquire lifetime exclusive lock");
    NSMutableDictionary *payload=[Payload(@"sealed") mutableCopy];Check([j compareRecord:nil replaceWith:payload error:nil],@"initial atomic record commit");NSDictionary *first=j.currentRecord;
    Check([first[@"generation"] isEqual:@1]&&[first[@"formatVersion"] isEqual:@1]&&[first[@"payload"] isEqual:payload],@"first envelope generation is one");
    Check([[j validatedCurrentRecord:nil] isEqual:first],@"validated current record rereads held lock and exact envelope");
    payload[@"phase"]=@"mutated caller";Check([first[@"payload"][@"phase"] isEqual:@"sealed"],@"caller mutation cannot alter immutable record");
    NSData *before=[NSData dataWithContentsOfFile:Join(f.path,@"record.json")];Check(![j compareRecord:nil replaceWith:Payload(@"wrong") error:nil],@"stale absent comparison refused");
    NSMutableDictionary *stale=[first mutableCopy];stale[@"payload"]=Payload(@"different");Check(![j compareRecord:stale replaceWith:Payload(@"wrong") error:nil],@"same generation different previous payload refused");
    Check([[NSData dataWithContentsOfFile:Join(f.path,@"record.json")] isEqual:before],@"failed compares leave exact record bytes unchanged");
    Check([j compareRecord:first replaceWith:Payload(@"opened") error:nil]&&[j.currentRecord[@"generation"] isEqual:@2],@"matching full record advances exactly one generation");
    NSDictionary *second=j.currentRecord;Check([first[@"generation"] isEqual:@1],@"prior envelope remains immutable");
    Check(![j.description containsString:@"/private/fixture"]&&j.description.length>0,@"description does not expose payload");
    [j close];NSError *closedError=nil;Check(![j validatedCurrentRecord:&closedError]&&closedError!=nil,@"closed validated read is explicitly refused");Check(![j compareRecord:second replaceWith:Payload(@"closed") error:nil],@"closed handle cannot write");j=Open(f,NO);Check(j&&[j.currentRecord isEqual:second],@"fresh locked read reconciles exact durable record");[j close];
    struct stat s;Check(!lstat(f.path.fileSystemRepresentation,&s)&&(s.st_mode&07777)==0700,@"journal directory private mode");for(NSString *name in @[@"record.json",@"journal.lock"]){Check(!lstat(Join(f.path,name).fileSystemRepresentation,&s)&&(s.st_mode&07777)==0600&&s.st_nlink==1,@"record and lock exact private regular files");}
    Bad(@"unknown file refuses journal",^(Fixture *x){Bytes(Join(x.path,@"unknown"),[@"x" dataUsingEncoding:NSUTF8StringEncoding]);});
    Bad(@"orphan stage refuses journal",^(Fixture *x){Bytes(Join(x.path,@".record-interrupted.stage"),[@"x" dataUsingEncoding:NSUTF8StringEncoding]);});
    Bad(@"directory symlink refused",^(Fixture *x){NSString *moved=Join(x.base,@"moved");Check(!rename(x.path.fileSystemRepresentation,moved.fileSystemRepresentation)&&!symlink(moved.fileSystemRepresentation,x.path.fileSystemRepresentation),@"create directory alias");});
    Bad(@"record symlink refused",^(Fixture *x){NSString *p=Join(x.path,@"record.json"),*moved=Join(x.base,@"record");Check(!rename(p.fileSystemRepresentation,moved.fileSystemRepresentation)&&!symlink(moved.fileSystemRepresentation,p.fileSystemRepresentation),@"create record alias");});
    Bad(@"lock symlink refused",^(Fixture *x){NSString *p=Join(x.path,@"journal.lock"),*moved=Join(x.base,@"lock");Check(!rename(p.fileSystemRepresentation,moved.fileSystemRepresentation)&&!symlink(moved.fileSystemRepresentation,p.fileSystemRepresentation),@"create lock alias");});
    Bad(@"record hardlink refused",^(Fixture *x){Check(!link(Join(x.path,@"record.json").fileSystemRepresentation,Join(x.base,@"linked").fileSystemRepresentation),@"hardlink fixture");});
    Bad(@"writable directory refused",^(Fixture *x){Check(!chmod(x.path.fileSystemRepresentation,0770),@"directory mode fixture");});
    Bad(@"public record refused",^(Fixture *x){Check(!chmod(Join(x.path,@"record.json").fileSystemRepresentation,0644),@"record mode fixture");});
    Bad(@"populated directory ACL refused",^(Fixture *x){Check(ACL(x.path,YES),@"directory ACL fixture");});
    Bad(@"populated record ACL refused",^(Fixture *x){Check(ACL(Join(x.path,@"record.json"),YES),@"record ACL fixture");});
    for(id generation in @[@0,@(-1),@YES,@1.5,@9007199254740992ULL,@"1",NSNull.null])Bad(@"malformed generation refused",^(Fixture *x){JSON(Join(x.path,@"record.json"),@{@"formatVersion":@1,@"generation":generation,@"payload":@{}});});
    Bad(@"unknown envelope fields refused",^(Fixture *x){JSON(Join(x.path,@"record.json"),@{@"formatVersion":@1,@"generation":@1,@"payload":@{},@"extra":@1});});
    Bad(@"non-dictionary payload refused",^(Fixture *x){JSON(Join(x.path,@"record.json"),@{@"formatVersion":@1,@"generation":@1,@"payload":@[]});});
    Bad(@"noncanonical duplicate fields refused",^(Fixture *x){Bytes(Join(x.path,@"record.json"),[@"{\"formatVersion\":1,\"generation\":1,\"generation\":2,\"payload\":{}}" dataUsingEncoding:NSUTF8StringEncoding]);});
    Bad(@"truncated record refused",^(Fixture *x){Bytes(Join(x.path,@"record.json"),[@"{" dataUsingEncoding:NSUTF8StringEncoding]);});
    @autoreleasepool{Fixture *x=[Fixture new];Seed(x);LBXNativeIsolationJournal *held=Open(x,NO);NSDictionary *old=held.currentRecord;JSON(Join(x.path,@"record.json"),@{@"formatVersion":@1,@"generation":@2,@"payload":Payload(@"external")});NSError *changed=nil;Check(![held validatedCurrentRecord:&changed]&&changed!=nil,@"validated read refuses external record change");Check(![held compareRecord:old replaceWith:Payload(@"next") error:nil],@"external writer change detected before staging");[held close];}
    @autoreleasepool{Fixture *x=[Fixture new];Seed(x);LBXNativeIsolationJournal *held=Open(x,NO);NSMutableString *large=[NSMutableString string];for(NSUInteger i=0;i<8*1024;i++)[large appendString:[@"x" stringByPaddingToLength:1024 withString:@"x" startingAtIndex:0]];Check(![held compareRecord:held.currentRecord replaceWith:@{@"oversize":large} error:nil],@"eight MiB payload plus envelope exceeds bound");[held close];Check(Open(x,NO)!=nil,@"bounds failure leaves usable previous record and no stage");}
    for(NSString *stage in @[@"stage-created",@"stage-synced",@"renamed",@"parent-synced"]){@autoreleasepool{Fixture *x=[Fixture new];Seed(x);pid_t child=fork();Check(child>=0,@"fork crash fixture");if(child==0){@autoreleasepool{LBXNativeIsolationJournal *held=Open(x,NO);if(!held)_exit(90);[LBXNativeIsolationJournal testSetFault:^(NSString *at){if([at isEqual:stage])_exit(71);}];[held compareRecord:held.currentRecord replaceWith:Payload(@"after") error:nil];_exit(91);}}
        int status=0;Check(waitpid(child,&status,0)==child&&WIFEXITED(status)&&WEXITSTATUS(status)==71,@"child really interrupted at requested durable phase");
        LBXNativeIsolationJournal *after=Open(x,NO);if([stage isEqual:@"stage-created"]||[stage isEqual:@"stage-synced"]){Check(after==nil,@"pre-rename orphan stage refuses recovery silently discarding nothing");NSDictionary *old=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:Join(x.path,@"record.json")] options:0 error:nil];Check([old[@"generation"] isEqual:@1]&&[old[@"payload"][@"phase"] isEqual:@"before"],@"pre-rename crash preserves exact old generation");}else{Check(after&&[after.currentRecord[@"generation"] isEqual:@2]&&[after.currentRecord[@"payload"][@"phase"] isEqual:@"after"],@"post-rename reopen reconciles complete new record");[after close];}
    }}
    printf("PASS: %lu native isolation journal assertions including real child-process crash phases\n",(unsigned long)Checks);return 0;
}}
