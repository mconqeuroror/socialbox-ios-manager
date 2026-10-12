// Manual on-device acceptance probe, NOT an automated build test.
// Authorized execution stops app workloads and changes the selected container.
// Requires exactly two existing Reddit containers and CLOSED traffic; creates
// no profiles, opens no network lease and never logs account/profile IDs.
// Compile with shared/RBXRequestQueue.m and Foundation, sign with ldid, run as
// mobile from a private bootstrap temp directory, retain JSON and remove it.
#import <Foundation/Foundation.h>
#import "RBXRequestQueue.h"
static NSDictionary *State(void){return [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist"]?:@{};}
int main(void){@autoreleasepool{
 NSDictionary *initial=State();NSMutableArray *ids=[NSMutableArray array];
 for(NSDictionary *row in initial[@"containers"]) if(!row[@"profileError"] && !row[@"deletionState"] && (!row[@"appType"] || [row[@"appType"] isEqual:@"reddit"])) [ids addObject:row[@"id"]];
 if(ids.count!=2 || ![initial[@"networkState"] isEqual:@"closed"] || ![initial[@"license"][@"unlocked"] boolValue]) {puts("{\"ok\":false,\"stage\":\"preflight\"}");return 1;}
 NSMutableArray *results=[NSMutableArray array];RBXRequestQueue *q=RBXRequestQueue.defaultQueue;
 for(NSUInteger i=0;i<40;i++){
  NSString *cid=ids[i%2];NSError *e=nil;
  NSString *rid=[q enqueueAction:@"selectContainer" values:@{@"appType":@"reddit",@"container":cid} error:&e];
  if(!rid){[results addObject:@{@"ok":@NO,@"stage":@"enqueue"}];break;}
  CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CFSTR("com.redditbox.containerAction"),NULL,NULL,TRUE);
  NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:30];NSDictionary *receipt=nil;
  while(deadline.timeIntervalSinceNow>0 && !(receipt=[q resultForRequestID:rid error:nil]))[NSThread sleepForTimeInterval:.1];
  NSDictionary *state=State(),*selection=state[@"workspaceSelection"];
  // Receipts and the sanitized UI publication are separate durable records.
  // Wait for the matching publication instead of treating receipt arrival as a UI barrier.
  while([receipt[@"ok"] boolValue] && deadline.timeIntervalSinceNow>0 &&
        (! [selection[@"requestId"] isEqual:rid] || ![selection[@"phase"] isEqual:@"selected"])) {
   [NSThread sleepForTimeInterval:.1];state=State();selection=state[@"workspaceSelection"];
  }
  BOOL ok=[receipt[@"ok"] boolValue]&&[selection[@"containerId"] isEqual:cid]&&[selection[@"phase"] isEqual:@"selected"]&&[selection[@"requestId"] isEqual:rid]&&[state[@"networkState"] isEqual:@"closed"];
  [results addObject:@{@"ok":@(ok),@"receiptOK":@([receipt[@"ok"] boolValue]),@"selectionMatches":@([selection[@"containerId"] isEqual:cid]),@"closed":@([state[@"networkState"] isEqual:@"closed"]),@"message":receipt[@"message"]?:@"Missing receipt"}];
  if(!ok)break;
 }
 BOOL ok=results.count==40 && [results.lastObject[@"ok"] boolValue];
 NSDictionary *report=@{@"ok":@(ok),@"appType":@"reddit",@"existingContainers":@2,@"newContainers":@0,@"selections":results,@"networkLaunchAttempted":@NO,@"scope":@"Forty serialized offline selections across two existing Reddit containers; not forty Facebook clones."};
 NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];fwrite(data.bytes,1,data.length,stdout);putchar('\n');return ok?0:1;
}}
