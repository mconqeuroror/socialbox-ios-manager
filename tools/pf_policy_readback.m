// Experimental, read-only device diagnostic. Never linked into app admission.
#import "RBXPFKernelPolicy.h"
#include <fcntl.h>
#include <errno.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <time.h>
#include <TargetConditionals.h>

static int Report(NSString *code,NSDictionary *observation,int status) {
    NSMutableDictionary *report=[@{@"schemaVersion":@1,@"result":code,
        @"readOnly":@YES,@"enforcementVerified":@NO,@"applicationAdmissionAllowed":@NO} mutableCopy];
    if(observation)report[@"observation"]=observation;
    NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
    if(!data)return 70;
    fwrite(data.bytes,1,data.length,stdout); fputc('\n',stdout); return status;
}
static BOOL CreatorPID(const char *s,pid_t *pid) {
    if(!s||!*s||strlen(s)>10)return NO;
    unsigned long value=0;
    for(const unsigned char *p=(const unsigned char *)s;*p;p++) {
        if(*p<'0'||*p>'9')return NO;
        value=value*10+(*p-'0'); if(value>INT_MAX)return NO;
    }
    if(!value)return NO;
    *pid=(pid_t)value; return YES;
}
static NSDictionary *ReadPlan(const char *path) {
    // Bounded regular files only; a FIFO must not stall a diagnostic and a
    // symlink must not redirect it to another private file or device.
    int fd=open(path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
    if(fd<0)return nil;
    struct stat before={0},after={0}; uint8_t bytes[65537]; ssize_t length=-1;
    if(fstat(fd,&before)==0&&S_ISREG(before.st_mode)&&before.st_size>0&&before.st_size<=65536) {
        size_t used=0;
        while(used<sizeof(bytes)) {
            ssize_t n=read(fd,bytes+used,sizeof(bytes)-used);
            if(n<0&&errno==EINTR)continue;
            if(n<0)break;
            if(n==0) { length=(ssize_t)used; break; }
            used+=(size_t)n;
        }
    }
    BOOL unchanged=fstat(fd,&after)==0&&before.st_size==after.st_size&&
        before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec&&before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec&&
        before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec&&before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec;
    close(fd);
    if(!unchanged||length<=0||length!=before.st_size)return nil;
    id object=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:(NSUInteger)length]
                                             options:0 error:NULL];
    return [object isKindOfClass:NSDictionary.class]?object:nil;
}
static BOOL KnownDeviceKernel(void) {
#if TARGET_OS_IOS && !TARGET_OS_SIMULATOR && defined(__arm64__)
    struct utsname u={0};
    // The only previously measured phone kernel. A new OS/ABI requires a new
    // explicit review and receipt, not a best-effort ioctl on unknown layouts.
    if(uname(&u)||strcmp(u.sysname,"Darwin")||strcmp(u.release,"22.6.0")||strcmp(u.machine,"iPhone10,6"))return NO;
    const char *build=strstr(u.version,"xnu-8796.142.1.703.8");
    return build&&build[strlen("xnu-8796.142.1.703.8")]=='~'&&strstr(build,"/RELEASE_ARM64_T8015")!=NULL;
#else
    return NO;
#endif
}
int main(int argc,const char *argv[]) { @autoreleasepool {
    RBXPFKernelMode mode=RBXPFKernelEmpty; pid_t creator=0; RBXPFKernelPolicy *policy=nil;
    if(argc==2&&!strcmp(argv[1],"--empty")) { /* no rules or policy file */ }
    else if(argc==6&&(!strcmp(argv[1],"--closed")||!strcmp(argv[1],"--proxy"))&&
        !strcmp(argv[2],"--plan")&&!strcmp(argv[4],"--creator-pid")&&CreatorPID(argv[5],&creator)) {
        mode=!strcmp(argv[1],"--closed")?RBXPFKernelClosed:RBXPFKernelProxy;
        NSDictionary *input=ReadPlan(argv[3]);
        if(!input)return Report(@"PF_PLAN_FILE_INVALID",nil,2);
        RBXPFPolicyPlan *plan=[RBXPFPolicyPlan planWithRequest:input error:NULL];
        if(!plan||(policy=[RBXPFKernelPolicy policyWithPlan:plan error:NULL])==nil)
            return Report(@"PF_PLAN_INVALID",nil,2);
    } else return Report(@"PF_ARGUMENTS_INVALID",nil,2);
    if(!KnownDeviceKernel())return Report(@"PF_KERNEL_NOT_REVIEWED",nil,3);
    if(geteuid()!=0)return Report(@"PF_ROOT_REQUIRED",nil,3);
    int fd=open("/dev/pf",O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    if(fd<0)return Report(@"PF_DEVICE_UNAVAILABLE",nil,3);
    struct stat device={0};
    if(fstat(fd,&device)||!S_ISCHR(device.st_mode)) { close(fd); return Report(@"PF_DEVICE_INVALID",nil,3); }
    RBXPFKernelReader *reader=[[RBXPFKernelReader alloc] initWithIO:^int(unsigned long command,void *argument) {
        return ioctl(fd,command,argument);
    } clock:^double {
        struct timespec time={0};
        if(clock_gettime(CLOCK_MONOTONIC_RAW,&time))return -1;
        return (double)time.tv_sec+(double)time.tv_nsec/1e9;
    }];
    NSError *error=nil;
    NSDictionary *result=[reader verifyPolicy:policy mode:mode creatorPID:creator
                              requireNoStates:mode!=RBXPFKernelProxy error:&error];
    close(fd);
    return Report(result?@"PF_READBACK_MATCH":(error.localizedDescription?:@"PF_READBACK_FAILED"),result,result?0:4);
} }
