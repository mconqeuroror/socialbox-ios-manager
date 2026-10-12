#import "LBXDrainClient.h"
#import "../Switching/LBXSocialBoxProduct.h"
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <os/log.h>

static BOOL LBXCompatible;
static void LBXKillApp(id receiver, SEL selector, id bundleID, void (^reply)(BOOL)) {
    (void)receiver; (void)selector;
    // The recovered XPC reply ABI is ONE BOOL. Do not invent an NSError
    // argument or let a rejected target fall back to killall by executable name.
    if (!reply) return;
    if (!LBXCompatible || !LBXDrainSupportedApplication(bundleID)) { reply(NO); return; }
    LBXRequestApplicationDrain(bundleID,[reply copy]);
}
static BOOL LBXOriginalHelper(void) {
    if (getuid()!=0 || geteuid()!=0) return NO;
    NSString *path=[NSBundle.mainBundle.executablePath stringByResolvingSymlinksInPath];
    if (![path isEqual:[@LBX_SOCIALBOX_HELPER_PATH stringByResolvingSymlinksInPath]]) return NO;
    if (LBX_SOCIALBOX_HELPER_SIZE<=0) return NO;
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    if (fd<0) return NO;
    struct stat before,after; BOOL valid=NO;
    if (!fstat(fd,&before) && S_ISREG(before.st_mode) && before.st_uid==0 && !(before.st_mode&0022) && (unsigned long long)before.st_size==LBX_SOCIALBOX_HELPER_SIZE) {
        CC_SHA256_CTX context; CC_SHA256_Init(&context); char buffer[16384]; ssize_t count; size_t total=0;
        while ((count=read(fd,buffer,sizeof(buffer)))>0) { total+=(size_t)count; CC_SHA256_Update(&context,buffer,(CC_LONG)count); }
        unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest,&context);
        NSMutableString *hex=[NSMutableString string];for(unsigned i=0;i<sizeof(digest);i++)[hex appendFormat:@"%02x",digest[i]];
        valid=count==0 && total==(size_t)LBX_SOCIALBOX_HELPER_SIZE && !fstat(fd,&after) && before.st_dev==after.st_dev && before.st_ino==after.st_ino &&
            before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec &&
            before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec &&
            [hex isEqual:@LBX_SOCIALBOX_HELPER_SHA256];
    }
    close(fd);return valid;
}
static BOOL LBXInstallHelperMethod(Class cls, NSString *expectedImage) {
    SEL selector=NSSelectorFromString(@"killApp:reply:");
    Method method=NULL; unsigned count=0; Method *methods=class_copyMethodList(cls,&count);
    for (unsigned i=0;i<count;i++) if (method_getName(methods[i])==selector) { method=methods[i]; break; }
    free(methods); Dl_info image={0};
    if (!method || strcmp(method_getTypeEncoding(method),"v32@0:8@16@?24") ||
        !dladdr((void *)method_getImplementation(method),&image) || !image.dli_fname ||
        ![[@(image.dli_fname) stringByResolvingSymlinksInPath] isEqual:expectedImage]) return NO;
    if (method_getImplementation(method)==(IMP)LBXKillApp) return LBXCompatible;
    IMP expected=method_getImplementation(method);
    IMP replaced=method_setImplementation(method,(IMP)LBXKillApp);
    LBXCompatible=replaced==expected && method_getImplementation(method)==(IMP)LBXKillApp;
    return LBXCompatible;
}
__attribute__((constructor)) static void LBXInstallHelperSafety(void) { @autoreleasepool {
    if (!LBXOriginalHelper()) { os_log_error(OS_LOG_DEFAULT,"LBX_HELPER_DRAIN unsupported executable; hook not installed"); return; }
    BOOL installed=LBXInstallHelperMethod(NSClassFromString(@"_Zw5h"),[NSBundle.mainBundle.executablePath stringByResolvingSymlinksInPath]);
    os_log(OS_LOG_DEFAULT,"LBX_HELPER_DRAIN installed=%{public}s",installed?"yes":"no");
    if(installed)LBXCheckDrainService(^(BOOL authenticated){
        os_log(OS_LOG_DEFAULT,"LBX_HELPER_DRAIN service_authenticated=%{public}s scope=read_only_round_trip",authenticated?"yes":"no");
    });
}}
