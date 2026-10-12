#import <Foundation/Foundation.h>
#import "../lucid/HelperSafety/LBXDrainClient.h"
#include <dlfcn.h>
#include <unistd.h>
// A private root acceptance executable. It MUST be rejected by the production
// service because it is not SocialBoxHelper. No target process is passed/stopped.
int main(void){@autoreleasepool{
    if(getuid()!=0||geteuid()!=0)return 77;
    NSArray *symbols=@[@"xpc_connection_create_mach_service",@"xpc_dictionary_get_audit_token",@"proc_pidpath_audittoken"];
    NSMutableDictionary *available=[NSMutableDictionary dictionary];BOOL all=YES;
    for(NSString *symbol in symbols){BOOL yes=dlsym(RTLD_DEFAULT,symbol.UTF8String)!=NULL;available[symbol]=@(yes);all&=yes;}
    double start=LBXDrainClock();dispatch_semaphore_t done=dispatch_semaphore_create(0);__block BOOL result=YES;
    LBXRequestApplicationDrain(@"com.burbn.instagram",^(BOOL value){result=value;dispatch_semaphore_signal(done);});
    BOOL completed=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0;
    NSDictionary *receipt=@{@"symbols":available,@"unrelatedRootCallerRefused":@(completed&&!result),@"completed":@(completed),@"elapsedSeconds":@(LBXDrainClock()-start),@"targetAppStopTest":@"NOT_RUN",@"originalHelperInjection":@"NOT_RUN"};
    NSData *data=[NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingSortedKeys error:nil];fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);return all&&completed&&!result?0:1;
}}
