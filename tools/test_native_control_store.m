#import <Foundation/Foundation.h>
#import "../lucid/Switching/LBXNativeControlStore.h"
#import "../lucid/Switching/LBXNativeIsolationJournal.h"
#include <unistd.h>

static NSUInteger Checks;
static void Check(BOOL ok,NSString *label){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",label.UTF8String);exit(1);}}
static NSString *Join(NSString *a,NSString *b){return [a stringByAppendingPathComponent:b];}
static void Dir(NSString *p){Check([NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil],@"fixture directory");}
@interface Fixture:NSObject
@property NSString *base,*path;
@end
@implementation Fixture
- (instancetype)init {if((self=[super init])){NSString *raw=Join(NSTemporaryDirectory(),[@"socialbox-control-" stringByAppendingString:NSUUID.UUID.UUIDString]);Dir(raw);char *p=realpath(raw.fileSystemRepresentation,NULL);Check(p!=NULL,@"canonical fixture root");_base=@(p);free(p);_path=Join(_base,@"journal");}return self;}
- (void)dealloc{[NSFileManager.defaultManager removeItemAtPath:_base error:nil];}
@end
static NSDictionary *Group(long long device,unsigned long long inode){return @{@"device":@(device),@"inode":@(inode)};}
static LBXNativeControlStore *Open(Fixture *f,BOOL create){LBXNativeIsolationJournal *j=[LBXNativeIsolationJournal testOpenDirectory:f.path create:create error:nil];Check(j!=nil,@"control child journal");LBXNativeControlStore *store=[LBXNativeControlStore testOpenJournal:j error:nil];Check(store!=nil,@"open control store");return store;}
int main(void){@autoreleasepool{
    Fixture *f=[Fixture new];double deadline=LBXNativeControlClock()+30;NSDictionary *family=Group(1,42);
    LBXNativeControlStore *store=Open(f,YES);
    Check([store selectedContainerIDForApplication:@"com.burbn.instagram" error:nil]==nil,@"Instagram starts unselected");
    Check(![store commitContainerID:@"0" applicationID:@"com.atebits.Tweetie2" familyGroupIdentity:family beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"Twitter is outside this isolation unit");
    Check(![store commitContainerID:@"0" applicationID:@"com.burbn.instagram" familyGroupIdentity:@{@"device":@1} beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"incomplete family identity refused");
    Check(![store commitContainerID:@"0" applicationID:@"com.burbn.instagram" familyGroupIdentity:family beforeDeadline:deadline authorization:^BOOL{return NO;} error:nil],@"authorization failure leaves store empty");
    Check([store commitContainerID:@"0" applicationID:@"com.burbn.instagram" familyGroupIdentity:family beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"Instagram admits CID 0");
    Check([[store selectedContainerIDForApplication:@"com.burbn.instagram" error:nil] isEqual:@"0"],@"Instagram selection is 0");
    NSError *conflict=nil;Check(![store commitContainerID:@"109" applicationID:@"com.facebook.Facebook" familyGroupIdentity:family beforeDeadline:deadline authorization:^BOOL{return YES;} error:&conflict]&&conflict.code==3,@"Facebook cannot take a different CID on the same family group");
    Check([store selectedContainerIDForApplication:@"com.facebook.Facebook" error:nil]==nil,@"failed Facebook commit does not select 109");
    Check([store commitContainerID:@"0" applicationID:@"com.facebook.Facebook" familyGroupIdentity:family beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"Facebook may share Instagram CID 0 on the family group");
    Check([[store selectedContainerIDForApplication:@"com.facebook.Facebook" error:nil] isEqual:@"0"],@"Facebook selection matches Instagram");
    Check([store commitContainerID:@"109" applicationID:@"com.facebook.Facebook" familyGroupIdentity:Group(2,99) beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"distinct physical group may hold a different Facebook CID");
    Check([[store selectedContainerIDForApplication:@"com.facebook.Facebook" error:nil] isEqual:@"109"],@"Facebook moved only after leaving the shared group identity");
    Check(![store commitContainerID:@"01" applicationID:@"com.burbn.instagram" familyGroupIdentity:family beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"non-canonical CID refused");
    Check(![store.description containsString:@"109"]&&![store.safeStatus[@"isolationVerified"] boolValue],@"safe status never claims isolation or exports CIDs");
    Check([store.safeStatus[@"selectedApplicationCount"] isEqual:@2],@"two apps remain selected");
    store=nil;
    LBXNativeIsolationJournal *again=[LBXNativeIsolationJournal testOpenDirectory:f.path create:NO error:nil];
    LBXNativeControlStore *reopened=[LBXNativeControlStore testOpenJournal:again error:nil];
    Check([[reopened selectedContainerIDForApplication:@"com.burbn.instagram" error:nil] isEqual:@"0"]&&[[reopened selectedContainerIDForApplication:@"com.facebook.Facebook" error:nil] isEqual:@"109"],@"control selections survive reopen");
    Fixture *b=[Fixture new];LBXNativeControlStore *batch=Open(b,YES);
    Check([batch commitContainerID:@"0" applicationIDs:@[@"com.burbn.instagram",@"com.facebook.Facebook"] familyGroupIdentity:family beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"atomic family admit");
    Check(![batch commitContainerID:@"5" applicationID:@"com.burbn.instagram" familyGroupIdentity:family beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"Instagram-only switch cannot split Facebook on the same group");
    Check([[batch selectedContainerIDForApplication:@"com.burbn.instagram" error:nil] isEqual:@"0"]&&[[batch selectedContainerIDForApplication:@"com.facebook.Facebook" error:nil] isEqual:@"0"],@"refused split leaves both on 0");
    Check([batch commitContainerID:@"5" applicationIDs:@[@"com.facebook.Facebook",@"com.burbn.instagram"] familyGroupIdentity:family beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"one write moves Instagram and Facebook together");
    Check([[batch selectedContainerIDForApplication:@"com.burbn.instagram" error:nil] isEqual:@"5"]&&[[batch selectedContainerIDForApplication:@"com.facebook.Facebook" error:nil] isEqual:@"5"],@"family CID is 5 after atomic commit");
    Check(![batch commitContainerID:@"6" applicationIDs:@[@"com.burbn.instagram",@"com.burbn.instagram"] familyGroupIdentity:family beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"duplicate application list refused");
    printf("PASS: %lu native control-store assertions for Instagram/Facebook family isolation\n",(unsigned long)Checks);return 0;
}}
