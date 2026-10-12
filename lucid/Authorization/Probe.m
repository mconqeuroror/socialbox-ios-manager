#import "LBXLicenseTransport.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
#include <string.h>

// Acceptance executable, never injected into an app. Private input/output are
// handled by the operator. It cannot alter or admit the retained app/engine.
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=3||strcmp(argv[1],"--private-result")) {
        fprintf(stderr,"Usage: socialbox-license-probe --private-result NEW_PRIVATE_FILE < private-request.json\n");return 2;
    }
    int fd=open(argv[2],O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    struct stat info;
    if(fd<0||fstat(fd,&info)||!S_ISREG(info.st_mode)||info.st_uid!=geteuid()||info.st_nlink!=1||(info.st_mode&0077)) {
        if(fd>=0)close(fd);fprintf(stderr,"Private result file unavailable; no request sent\n");return 2;
    }
    NSData *input=[NSFileHandle.fileHandleWithStandardInput readDataOfLength:32769];
    id request=input.length<=32768?[NSJSONSerialization JSONObjectWithData:input options:0 error:nil]:nil;
    if(![request isKindOfClass:NSDictionary.class]||![request[@"configuration"] isKindOfClass:NSDictionary.class]||
       ![request[@"claim"] isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)request[@"claim"])!=CFBooleanGetTypeID()||
       ![request[@"configuration"][@"server"] isEqual:@"https://redditspoof.vercel.app"]) {
        close(fd);fprintf(stderr,"Invalid private input; no request sent\n");return 2;
    }
    NSDictionary *configuration=[request[@"configuration"] copy];
    dispatch_semaphore_t finished=dispatch_semaphore_create(0);
    __block NSDictionary *result=nil;
    NSError *startError=nil;
    LBXLicenseTransport *transport=[LBXLicenseTransport startWithConfiguration:configuration claim:[request[@"claim"] boolValue]
        currentConfiguration:^NSDictionary *{return configuration;}
        completion:^(NSDictionary *receipt,NSError *error){
            result=receipt?@{@"verifiedReceipt":receipt}:@{@"errorCode":@(error.code),@"error":error.localizedDescription?:@"License request failed"};
            dispatch_semaphore_signal(finished);
        } error:&startError];
    if(!transport)result=@{@"errorCode":@(startError.code),@"error":@"License configuration invalid"};
    else if(dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,25*NSEC_PER_SEC))) {
        [transport cancel];close(fd);fprintf(stderr,"License request timed out; check private recovery state\n");return 2;
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
    NSUInteger offset=0;
    while(offset<data.length) { ssize_t n=write(fd,(const char *)data.bytes+offset,data.length-offset);if(n<0&&errno==EINTR)continue;if(n<=0)break;offset+=(NSUInteger)n; }
    BOOL saved=data.length&&offset==data.length&&fsync(fd)==0;int closed=close(fd);
    if(!saved||closed) { fprintf(stderr,"Private result write failed; no token printed\n");return 2; }
    fprintf(stdout,"Private result saved; retained-engine authorization unchanged\n");return 0;
} }
