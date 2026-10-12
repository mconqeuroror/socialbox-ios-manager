#import "LBXLicenseInstallationEstablishment.h"
#include <unistd.h>
#include <string.h>
int main(int argc,char **argv){@autoreleasepool{
    if(getuid()!=0||geteuid()!=0||getegid()!=0)return 77;
    BOOL observe=argc==2&&!strcmp(argv[1],"check");
    BOOL prepare=argc==2&&!strcmp(argv[1],"prepare");
    // Explicit intent is required even for the trusted fixed root installer.
    // The command itself grants no authority/history: the unchanged factory
    // still enforces its process, image, path and exclusive-state contract.
    if(!observe&&!prepare)return 64;
    NSError *error=nil;LBXLicenseInstallationEstablishment *installation=observe?
        [LBXLicenseInstallationEstablishment openFixedPreparedInstallation:&error]:[LBXLicenseInstallationEstablishment prepareFixedInstallation:&error];
    BOOL current=installation&&[installation preparedInstallationCurrent:&error];
    // Never print private seed, credentials, paths, witnesses or raw NSError.
    NSDictionary *status=@{@"status":current?@"PASS":@"FAIL",@"prepared":current?@YES:@NO,
        @"pairedPendingReady":@NO,@"runtimeAccepted":@NO,@"customerDeliveryReady":@NO};
    NSData *data=[NSJSONSerialization dataWithJSONObject:status options:0 error:nil];fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);return current?0:1;
}}
