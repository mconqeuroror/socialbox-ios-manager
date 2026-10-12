#import "../Containers/LBXContainerPendingMutation.h"
#import "../Containers/LBXContainerConfiguration.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/acl.h>
#include <membership.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>

static NSUInteger checks,failures;
static void Check(BOOL good,NSString *reason){checks++;if(!good){failures++;fprintf(stderr,"FAIL: %s\n",reason.UTF8String);}}
static NSString *State(NSString *home){return [home stringByAppendingPathComponent:@"Library/Application Support/SocialBoxPendingMutations/state.json"];}
static NSString *Lock(NSString *home){return [home stringByAppendingPathComponent:@"Library/Application Support/SocialBoxPendingMutations/pending.lock"];}
static NSString *Leaf(NSString *home){return [State(home) stringByDeletingLastPathComponent];}
static NSString *EstablishmentMarker(NSString *home){return [home stringByAppendingPathComponent:@"Library/Application Support/.socialbox-pending-v1.json"];}
static NSData *Bytes(NSString *path){return [NSData dataWithContentsOfFile:path];}
static NSDictionary *Read(NSString *path){NSData *bytes=Bytes(path);return bytes?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;}
static void Write(NSString *path,id object){NSData *data=[object isKindOfClass:NSData.class]?object:[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:nil];Check(data&&[data writeToFile:path atomically:NO]&&!chmod(path.fileSystemRepresentation,0600),@"fixture writes its own exact private state bytes");}
static BOOL SetACL(NSString *path,BOOL populated){
    acl_t acl=acl_init(populated?1:0);BOOL okay=acl!=NULL;
    if(populated){uuid_t subject;acl_entry_t entry;acl_permset_t permissions;okay=okay&&!mbr_uid_to_uuid(geteuid(),subject)&&!acl_create_entry(&acl,&entry)&&!acl_set_tag_type(entry,ACL_EXTENDED_ALLOW)&&!acl_set_qualifier(entry,subject)&&!acl_get_permset(entry,&permissions)&&!acl_add_perm(permissions,ACL_READ_DATA);}
    if(okay)okay=acl_set_file(path.fileSystemRepresentation,ACL_TYPE_EXTENDED,acl)==0;
    if(acl)acl_free(acl);return okay;
}
static NSString *FreshHome(NSString *base,NSString *name){
    NSString *home=[base stringByAppendingPathComponent:name];Check(!mkdir(home.fileSystemRepresentation,0700),@"real owner-private fixture home created");
    NSString *library=[home stringByAppendingPathComponent:@"Library"],*support=[library stringByAppendingPathComponent:@"Application Support"];
    Check(!mkdir(library.fileSystemRepresentation,0700)&&!mkdir(support.fileSystemRepresentation,0700),@"real app-support fixture chain created");
    NSString *client=[home stringByAppendingPathComponent:@"client"];
    Check([[@"private fixture executable bytes" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:client atomically:NO]&&!chmod(client.fileSystemRepresentation,0700),@"test context observes actual private client file");
    [LBXContainerPendingMutation testUseHomeDirectory:home clientExecutable:client];return home;
}
static LBXContainerPendingMutation *Open(BOOL create){NSError *error=nil;LBXContainerPendingMutation *journal=[LBXContainerPendingMutation openWithCreate:create error:&error];Check(journal&&!error,@"safe real filesystem pending journal opens");return journal;}
static LBXContainerConfiguration *Configuration(void){LBXContainerConfiguration *configuration=[LBXContainerConfiguration createWithName:@"Private pending fixture" applications:@[@"com.burbn.instagram"] manualIdentifiers:nil proxyReference:@"" error:nil];Check(configuration!=nil,@"valid complete private candidate generated once for fixture");return configuration;}
static NSDictionary *Stage(LBXContainerPendingMutation *journal,LBXContainerConfiguration *configuration,LBXContainerConfiguration *expected){NSError *error=nil;NSDictionary *slot=[journal stageConfiguration:configuration replacing:expected error:&error];Check(slot&&!error,@"complete candidate and expected stage durably");return slot;}
static BOOL UUID(id value){return [value isKindOfClass:NSString.class]&&[value length]==36&&[[[NSUUID alloc] initWithUUIDString:value].UUIDString.lowercaseString isEqual:value];}
static void Empty(LBXContainerPendingMutation *journal){NSError *error=nil;Check(![journal pendingMutation:&error]&&!error,@"verified empty journal differs from unavailable storage");}
static void Status(LBXContainerPendingMutation *journal,BOOL available,NSNumber *hasPending){NSDictionary *status=journal.safeStatus;Check([[NSSet setWithArray:status.allKeys] isEqual:[NSSet setWithArray:@[@"available",@"hasPending",@"runtimeAccepted"]]],@"journal safe status has only fixed Boolean fields");for(NSString *key in @[@"available",@"hasPending",@"runtimeAccepted"])Check([status[key] isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)status[key])==CFBooleanGetTypeID(),@"journal safe status never boxes Boolean flags as integer zero or one");Check([status[@"available"] boolValue]==available&&![status[@"runtimeAccepted"] boolValue]&&(!hasPending||[status[@"hasPending"] boolValue]==hasPending.boolValue),@"journal typed status distinguishes verified empty pending and unavailable contexts");}
static void DenyExisting(NSString *home,NSData *prior){NSError *error=nil;LBXContainerPendingMutation *opened=[LBXContainerPendingMutation openWithCreate:YES error:&error];Check(!opened&&error&&[Bytes(State(home)) isEqual:prior],@"unsafe established journal is rejected without resetting or changing bytes");}

int main(void){@autoreleasepool{
    char temporary[]="/tmp/socialbox-pending-journal.XXXXXX",physical[PATH_MAX];Check(mkdtemp(temporary)&&realpath(temporary,physical),@"physical host fixture parent established");NSString *base=[NSString stringWithUTF8String:physical];Check(!chown(base.fileSystemRepresentation,geteuid(),getegid())&&!chmod(base.fileSystemRepresentation,0700),@"owned host fixture parent uses actual effective UID/GID for descendant files");
    NSString *home=FreshHome(base,@"lifecycle");NSError *error=nil;
    Check(![LBXContainerPendingMutation openWithCreate:NO error:&error]&&error,@"normal startup cannot establish missing pristine state");
    LBXContainerPendingMutation *journal=Open(YES);Empty(journal);Status(journal,YES,@NO);
    Check([Read(State(home))[@"pending"] isEqual:NSNull.null]&&Read(EstablishmentMarker(home)),@"explicit setup establishes durable empty state and external marker");
    for(NSString *file in @[State(home),Lock(home),EstablishmentMarker(home)]){struct stat node;Check(!lstat(file.fileSystemRepresentation,&node)&&S_ISREG(node.st_mode)&&node.st_uid==geteuid()&&(node.st_mode&07777)==0600&&node.st_nlink==1,@"all established journal files are actual private single-link files");}
    struct stat leaf;Check(!lstat(Leaf(home).fileSystemRepresentation,&leaf)&&S_ISDIR(leaf.st_mode)&&(leaf.st_mode&07777)==0700,@"pending leaf has exact owner-private permissions");
    LBXContainerConfiguration *candidate=Configuration();NSDictionary *slot=Stage(journal,candidate,nil);
    Check([[NSSet setWithArray:slot.allKeys] isEqual:[NSSet setWithArray:@[@"identifier",@"epoch",@"attempt",@"operation",@"configuration",@"expected"]]]&&UUID(slot[@"identifier"])&&[slot[@"operation"] isEqual:@"create"]&&slot[@"expected"]==NSNull.null&&[slot[@"configuration"] isEqual:candidate.privateDictionary],@"durable create slot contains exact candidate and local CAS token only");
    Check([Read(State(home))[@"pending"] isEqual:slot],@"stage completes only after exact slot is present on disk");
    Status(journal,YES,@YES);
    LBXContainerPendingMutation *peer=Open(NO);Check([[peer pendingMutation:&error] isEqual:slot],@"independent restart reloads exact complete candidate without regeneration");
    int competing=open(Lock(home).fileSystemRepresentation,O_RDWR|O_NOFOLLOW);Check(competing>=0&&!flock(competing,LOCK_EX|LOCK_NB),@"independent real file description owns established pending lock");NSData *beforeLock=Bytes(State(home));Check(![peer beginAttemptForMutation:slot error:&error]&&error&&[Bytes(State(home)) isEqual:beforeLock],@"cooperative lock contention refuses attempt without changing pending bytes");flock(competing,LOCK_UN);close(competing);
    NSDictionary *attempt=[peer beginAttemptForMutation:slot error:&error];Check(attempt&&[attempt[@"configuration"] isEqual:slot[@"configuration"]]&&[attempt[@"expected"] isEqual:slot[@"expected"]]&&[attempt[@"identifier"] isEqual:slot[@"identifier"]]&&[attempt[@"attempt"] unsignedLongLongValue]==[slot[@"attempt"] unsignedLongLongValue]+1&&[Read(State(home))[@"pending"] isEqual:attempt],@"attempt records durable exact candidate and increases its local attempt counter");
    NSData *attemptBytes=Bytes(State(home));Check(![journal clearConfirmedMutation:slot error:&error]&&error&&[Bytes(State(home)) isEqual:attemptBytes],@"stale attempt cannot clear a later durable token/full-slot state");
    LBXContainerConfiguration *other=Configuration();Check(![journal stageConfiguration:other replacing:nil error:&error]&&error&&[Bytes(State(home)) isEqual:attemptBytes],@"different candidate cannot replace existing pending work");
    Check([journal clearConfirmedMutation:attempt error:&error]&&!error,@"trusted exact current full-slot completion can clear metadata");Empty(peer);Status(peer,YES,@NO);
    LBXContainerConfiguration *updated=[candidate configurationByUpdatingName:@"Private edited fixture" applications:@[@"com.burbn.instagram",@"com.facebook.Facebook"] manualIdentifiers:nil proxyReference:nil error:nil];NSDictionary *update=Stage(journal,updated,candidate);
    Check([update[@"operation"] isEqual:@"update"]&&[update[@"configuration"] isEqual:updated.privateDictionary]&&[update[@"expected"] isEqual:candidate.privateDictionary]&&[update[@"epoch"] unsignedLongLongValue]>[slot[@"epoch"] unsignedLongLongValue],@"new update retains exact expected snapshot and advances durable mutation epoch");
    Check(![journal clearConfirmedMutation:attempt error:&error]&&error,@"old cleared mutation cannot clear a new epoch");
    for(NSString *secret in @[candidate.identifier,candidate.name,candidate.identifiers[@"idfa"],home])Check(![journal.description containsString:secret]&&![[journal.safeStatus description] containsString:secret],@"safe status and description redact private candidate/context values");
    Check(![update isKindOfClass:NSMutableDictionary.class]&&![update[@"configuration"] isKindOfClass:NSMutableDictionary.class]&&![update[@"configuration"][@"identifiers"] isKindOfClass:NSMutableDictionary.class],@"pending snapshots have no mutable nested aliases");
    Check([journal clearConfirmedMutation:update error:&error],@"fixture clears only its exact second pending slot");
    for(NSString *boundary in @[@"state_staged",@"state_renamed",@"state_synced"]){NSString *fixtureHome=FreshHome(base,boundary);LBXContainerPendingMutation *fixture=Open(YES);LBXContainerConfiguration *record=Configuration();NSData *before=Bytes(State(fixtureHome));[fixture testStopAfterBoundary:boundary];
        Check(![fixture stageConfiguration:record replacing:nil error:&error]&&error,@"failure-only publication boundary refuses success");
        LBXContainerPendingMutation *restarted=[LBXContainerPendingMutation openWithCreate:NO error:&error];NSDictionary *reloaded=[restarted pendingMutation:&error];
        if([boundary isEqual:@"state_staged"])Check(restarted&&!error&&!reloaded&&[Bytes(State(fixtureHome)) isEqual:before],@"pre-rename failure preserves verified empty state and original bytes");
        else Check(restarted&&!error&&[reloaded[@"configuration"] isEqual:record.privateDictionary],@"post-rename failure preserves exact pending candidate across independent restart");
    }
    NSString *clearHome=FreshHome(base,@"clear-failure");LBXContainerPendingMutation *clearJournal=Open(YES);NSDictionary *clearSlot=Stage(clearJournal,Configuration(),nil);NSData *clearBytes=Bytes(State(clearHome));[clearJournal testStopAfterBoundary:@"clear_before_publish"];
    Check(![clearJournal clearConfirmedMutation:clearSlot error:&error]&&error&&[Bytes(State(clearHome)) isEqual:clearBytes],@"clear failure retains exact durable candidate rather than reporting local completion");[clearJournal testStopAfterBoundary:nil];Check([clearJournal clearConfirmedMutation:clearSlot error:&error],@"exact clear can retry after explicit failure-only fixture removal");
    for(NSString *boundary in @[@"state_renamed",@"state_synced"]){NSString *clearHome=FreshHome(base,[@"clear-" stringByAppendingString:boundary]);LBXContainerPendingMutation *fixture=Open(YES);NSDictionary *knownConfirmed=Stage(fixture,Configuration(),nil);[fixture testStopAfterBoundary:boundary];Check(![fixture clearConfirmedMutation:knownConfirmed error:&error]&&error,@"post-publication clear failure reports no local success");LBXContainerPendingMutation *restart=Open(NO);Empty(restart);Check(Read(State(clearHome))[@"pending"]==NSNull.null,@"trusted clear may publish safe empty state before failure, without unbounded acknowledgement protocol");}
    NSString *corruptHome=FreshHome(base,@"corruption");LBXContainerPendingMutation *corruptJournal=Open(YES);NSDictionary *corruptSlot=Stage(corruptJournal,Configuration(),nil);NSDictionary *state=Read(State(corruptHome));NSData *stateBytes=Bytes(State(corruptHome));
    NSMutableArray *bad=[NSMutableArray array];
    for(NSString *key in state){NSMutableDictionary *value=[state mutableCopy];[value removeObjectForKey:key];[bad addObject:value];}
    NSMutableDictionary *extra=[state mutableCopy];extra[@"unknown"]=@YES;[bad addObject:extra];
    for(id invalid in @[@YES,@"1",NSNull.null,@[],@{},@0,@2]){NSMutableDictionary *value=[state mutableCopy];value[@"formatVersion"]=invalid;[bad addObject:value];}
    for(id invalid in @[@YES,@0,@(-1),@"1",NSNull.null,@[],@{}]){NSMutableDictionary *value=[state mutableCopy];value[@"epoch"]=invalid;[bad addObject:value];}
    for(NSString *key in corruptSlot){NSMutableDictionary *slotValue=[corruptSlot mutableCopy];[slotValue removeObjectForKey:key];NSMutableDictionary *value=[state mutableCopy];value[@"pending"]=slotValue;[bad addObject:value];}
    for(NSString *key in @[@"identifier",@"epoch",@"attempt",@"operation",@"configuration",@"expected"]){NSMutableDictionary *slotValue=[corruptSlot mutableCopy];slotValue[key]=[key isEqual:@"expected"]?(id)@{}:NSNull.null;NSMutableDictionary *value=[state mutableCopy];value[@"pending"]=slotValue;[bad addObject:value];}
    for(id value in bad){Write(State(corruptHome),value);NSData *malformed=Bytes(State(corruptHome));DenyExisting(corruptHome,malformed);Write(State(corruptHome),stateBytes);}
    NSString *decimalState=[[NSString alloc] initWithData:stateBytes encoding:NSUTF8StringEncoding];decimalState=[decimalState stringByReplacingOccurrencesOfString:@"\"formatVersion\":1" withString:@"\"formatVersion\":1.0"];Write(State(corruptHome),[decimalState dataUsingEncoding:NSUTF8StringEncoding]);DenyExisting(corruptHome,Bytes(State(corruptHome)));Write(State(corruptHome),stateBytes);
    for(NSString *target in @[State(corruptHome),Lock(corruptHome),EstablishmentMarker(corruptHome)]){
        NSString *held=[base stringByAppendingPathComponent:NSUUID.UUID.UUIDString];Check(!rename(target.fileSystemRepresentation,held.fileSystemRepresentation),@"fixture pins original existing journal node outside the tested inventory before substitution");
        Check(!symlink(held.fileSystemRepresentation,target.fileSystemRepresentation),@"real symlink substitution established");DenyExisting(corruptHome,Bytes(State(corruptHome)));Check(!unlink(target.fileSystemRepresentation)&&!rename(held.fileSystemRepresentation,target.fileSystemRepresentation),@"fixture restores its exact original node");
        NSString *hard=[base stringByAppendingPathComponent:NSUUID.UUID.UUIDString];Check(!link(target.fileSystemRepresentation,hard.fileSystemRepresentation),@"real journal hard-link counterexample established");DenyExisting(corruptHome,Bytes(State(corruptHome)));unlink(hard.fileSystemRepresentation);
        Check(!chmod(target.fileSystemRepresentation,0644),@"fixture makes one private journal node publicly readable");DenyExisting(corruptHome,Bytes(State(corruptHome)));chmod(target.fileSystemRepresentation,0600);
        Check(SetACL(target,YES),@"real Darwin ACL counterexample established");DenyExisting(corruptHome,Bytes(State(corruptHome)));Check(SetACL(target,NO),@"fixture removes only its added ACL");
    }
    NSString *heldLock=[base stringByAppendingPathComponent:@"held-pinned-lock"];Check(!rename(Lock(corruptHome).fileSystemRepresentation,heldLock.fileSystemRepresentation),@"fixture retains old pinned lock inode");Write(Lock(corruptHome),NSData.data);NSData *protectedState=Bytes(State(corruptHome));Check(![corruptJournal beginAttemptForMutation:corruptSlot error:&error]&&error&&[Bytes(State(corruptHome)) isEqual:protectedState],@"already-open journal refuses substituted pinned lock without publication");unlink(Lock(corruptHome).fileSystemRepresentation);rename(heldLock.fileSystemRepresentation,Lock(corruptHome).fileSystemRepresentation);
    for(NSString *target in @[State(corruptHome),Lock(corruptHome),EstablishmentMarker(corruptHome)]){NSString *held=[base stringByAppendingPathComponent:NSUUID.UUID.UUIDString];rename(target.fileSystemRepresentation,held.fileSystemRepresentation);Check(![LBXContainerPendingMutation openWithCreate:YES error:&error]&&error&&![NSFileManager.defaultManager fileExistsAtPath:target],@"missing established state/lock/marker is unavailable and is never recreated");rename(held.fileSystemRepresentation,target.fileSystemRepresentation);}
    NSString *heldLeaf=[base stringByAppendingPathComponent:@"held-established-leaf"];rename(Leaf(corruptHome).fileSystemRepresentation,heldLeaf.fileSystemRepresentation);Check(![LBXContainerPendingMutation openWithCreate:YES error:&error]&&error&&![NSFileManager.defaultManager fileExistsAtPath:Leaf(corruptHome)],@"external establishment marker prevents deleted whole leaf from resetting as pristine");rename(heldLeaf.fileSystemRepresentation,Leaf(corruptHome).fileSystemRepresentation);
    NSString *contextHome=FreshHome(base,@"context");LBXContainerPendingMutation *contextJournal=Open(YES);NSDictionary *contextSlot=Stage(contextJournal,Configuration(),nil);NSData *contextBytes=Bytes(State(contextHome));NSString *differentHome=FreshHome(base,@"foreign-context");
    Check(![contextJournal beginAttemptForMutation:contextSlot error:&error]&&error&&[Bytes(State(contextHome)) isEqual:contextBytes],@"already-open journal rejects actual home/client context change before effects");
    Status(contextJournal,NO,nil);
    // Restore only this fixture's captured bytes after a detected bad effect so
    // later context counterexamples remain independent of the first failure.
    if(![Bytes(State(contextHome)) isEqual:contextBytes])Write(State(contextHome),contextBytes);
    [LBXContainerPendingMutation testUseHomeDirectory:contextHome clientExecutable:[differentHome stringByAppendingPathComponent:@"client"]];Check(![LBXContainerPendingMutation openWithCreate:YES error:&error]&&error&&[Bytes(State(contextHome)) isEqual:contextBytes],@"same home with different observed client path cannot adopt an established context");
    [LBXContainerPendingMutation testUseHomeDirectory:contextHome clientExecutable:[contextHome stringByAppendingPathComponent:@"client"]];Write([contextHome stringByAppendingPathComponent:@"client"],[@"changed actual executable bytes" dataUsingEncoding:NSUTF8StringEncoding]);Check(![contextJournal beginAttemptForMutation:contextSlot error:&error]&&error&&[Bytes(State(contextHome)) isEqual:contextBytes],@"changed observed client bytes deny pending effects while preserving journal");
    [LBXContainerPendingMutation testUseHomeDirectory:nil clientExecutable:nil];Check(![LBXContainerPendingMutation openWithCreate:NO error:&error]&&error,@"production context cannot be invented by clearing host physical fixture provider");
    [NSFileManager.defaultManager removeItemAtPath:base error:nil];NSLog(@"%@: %lu pending mutation checks, %lu failures",failures?@"FAIL":@"PASS",(unsigned long)checks,(unsigned long)failures);return failures?1:0;
}}
