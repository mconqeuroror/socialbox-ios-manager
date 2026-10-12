#import "LBXLicenseClient.h"
#import "../Containers/LBXContainerMutationClient.h"
#include <unistd.h>
// Acceptance caller exercises exactly the UI client API. It is not admitted
// by a production service unless that build explicitly pins this executable.
int main(void){@autoreleasepool{
    NSData *data=[NSFileHandle.fileHandleWithStandardInput readDataOfLength:16385];
    id input=data.length&&data.length<=16384?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    BOOL metadata=[input isKindOfClass:NSDictionary.class]&&[input[@"family"] isEqual:@"container-mutation"];
    NSSet *keys=[NSSet setWithArray:metadata?@[@"family",@"operation",@"arguments"]:@[@"operation",@"key"]];
    if(![input isKindOfClass:NSDictionary.class]||![input[@"operation"] isKindOfClass:NSString.class]||
       ![[NSSet setWithArray:[input allKeys]] isSubsetOfSet:keys]||
       (metadata&&(![input[@"arguments"] isKindOfClass:NSDictionary.class]||[input count]!=3))){
        fputs("Invalid private input\n",stderr);return 2;
    }
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSDictionary *result;
    void (^completion)(NSDictionary *)=^(NSDictionary *reply){result=reply;dispatch_semaphore_signal(done);};
    if(metadata)LBXSendContainerMutationRequest(input[@"operation"],input[@"arguments"],completion);
    else LBXSendLicenseRequest(input[@"operation"],input[@"key"],completion);
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,26*NSEC_PER_SEC))){fputs("Owner did not respond\n",stderr);return 2;}
    NSData *output=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
    if(!output.length)return 2;
    [NSFileHandle.fileHandleWithStandardOutput writeData:output];fputs("\n",stdout);return 0;
}}
