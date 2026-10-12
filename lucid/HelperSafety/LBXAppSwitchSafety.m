#import "LBXDrainClient.h"
#import "LBXGlobalMetadata.h"
#import "../Switching/LBXSocialBoxProduct.h"
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/loader.h>
#include <sys/stat.h>
#include <unistd.h>
#include <os/log.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

// ADOPT-003: only the per-app worker has a proved pre-write timeout/unlock
// branch. Global/batch workers ignore their wait result and MUST NOT use this
// adaptation. The original programs and their authorization remain unchanged.
typedef struct {
    uintptr_t getter, entry, returnPC, worker, workerSize, stub, failure;
    const char *workerHash, *stubHash, *failureHash;
    size_t failureSize;
} LBXSwitchSite;
static const LBXSwitchSite LBXArm64Site={
    0x227fd0,0x2296ec,0x229c44,0x229834,4200,0x34ca40,0x22aa1c,
    "4b7f501b979a2004ee01bc1c0fc70d5c9e17ae5e65d298ce499a4707930cf60c",
    "62dcae6756923d9e788d70f2d5cfa180a50b767cf152d50d97c14eed50547469",
    "61ff6241735f7b1b0af28a6fc897f8b72f5404421ce59ab143bb206610863b20",24};
static const LBXSwitchSite LBXArm64eSite={
    0x22d754,0x22eeec,0x22f4c8,0x22f050,4384,0x34fd40,0x23032c,
    "46854af5b5e7d7e65766a2c971631ea6b845f495bbbe53f3a79661e18042e6ed",
    "de0a91101388ef1bc13902200870347cd515693bdff9a784cfd8e715d576dd6e",
    "f0b5f455a6e10a869222a43da8875e5cacca57ae41fea9ad8f28e21b29a4a5c5",28};

static id (*LBXOriginalHelperProxy)(id,SEL);
static Class LBXSwitchOwner;
static uintptr_t LBXSwitchReturnPC;

// Deliberately not a general forwarding proxy. The pinned callsite uses only
// killApp:reply:. We do not obtain or trust the old helper's boolean at all.
@interface LBXCheckedSwitchStop : NSObject
- (void)killApp:(NSString *)bundleID reply:(void (^)(BOOL))reply;
@end
@implementation LBXCheckedSwitchStop
- (void)killApp:(NSString *)bundleID reply:(void (^)(BOOL))reply {
    if (!reply) return;
    LBXRequestApplicationDrain(bundleID,^(BOOL success) {
        if (success) { reply(YES); return; }
        // Calling reply(NO) wakes this old worker and allows writes. Silence
        // deliberately selects its existing five-second failure cleanup. The
        // client bounds work to 3.5 seconds and rejects late/duplicate receipts.
        os_log_error(OS_LOG_DEFAULT,"LBX_SWITCH_STOP failed; per-app switch will take pre-write timeout cleanup");
    });
}
@end

__attribute__((noinline)) static id LBXCheckedHelperProxy(id receiver,SEL selector) {
    void *returnPC=__builtin_return_address(0);
#if __has_feature(ptrauth_calls)
    returnPC=ptrauth_strip(returnPC,ptrauth_key_return_address);
#endif
    if ((uintptr_t)returnPC==LBXSwitchReturnPC && object_getClass(receiver)==LBXSwitchOwner)
        return [LBXCheckedSwitchStop new];
    return LBXOriginalHelperProxy(receiver,selector);
}

static uintptr_t LBXIMPAddress(IMP implementation) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)implementation,ptrauth_key_function_pointer);
#else
    return (uintptr_t)implementation;
#endif
}
static Method LBXOwnedMethod(Class cls,SEL selector,const char *encoding) {
    unsigned count=0; Method *methods=class_copyMethodList(cls,&count),found=NULL;
    for (unsigned i=0;i<count;i++) if (method_getName(methods[i])==selector) { found=methods[i];break; }
    free(methods);
    return found && !strcmp(method_getTypeEncoding(found),encoding)?found:NULL;
}
static BOOL LBXInstallSwitchSite(Class cls,uintptr_t getter,uintptr_t entry,uintptr_t returnPC) {
    if (!cls || !getter || !entry || !returnPC || LBXSwitchOwner) return NO;
    Method lookup=LBXOwnedMethod(cls,NSSelectorFromString(@"helperProxy"),"@16@0:8");
    Method operation=LBXOwnedMethod(cls,NSSelectorFromString(@"switchApp:toContainer:progress:completion:"),"v48@0:8@16q24@?32@?40");
    if (!lookup || !operation || LBXIMPAddress(method_getImplementation(lookup))!=getter ||
        LBXIMPAddress(method_getImplementation(operation))!=entry) return NO;
    LBXOriginalHelperProxy=(id(*)(id,SEL))method_getImplementation(lookup);
    LBXSwitchOwner=cls;LBXSwitchReturnPC=returnPC;
    IMP previous=method_setImplementation(lookup,(IMP)LBXCheckedHelperProxy);
    return LBXIMPAddress(previous)==getter && method_getImplementation(lookup)==(IMP)LBXCheckedHelperProxy;
}
static BOOL LBXDigestMatches(const void *bytes,size_t length,const char *expected) {
    if (!bytes || length>UINT32_MAX) return NO;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];char hex[65];
    CC_SHA256(bytes,(CC_LONG)length,digest);
    for(unsigned i=0;i<sizeof(digest);i++)snprintf(hex+i*2,3,"%02x",digest[i]);
    return !strcmp(hex,expected);
}
static BOOL LBXPinnedSwitchHost(NSString *path) {
    if (LBX_SOCIALBOX_MANAGER_SIZE<=0) return NO;
    NSString *expected=[@LBX_SOCIALBOX_MANAGER_PATH stringByResolvingSymlinksInPath];
    if (![path isEqual:expected]) return NO;
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    if (fd<0) return NO;
    struct stat a,b;BOOL valid=NO;
    if (!fstat(fd,&a) && S_ISREG(a.st_mode) && a.st_uid==0 && !(a.st_mode&0022) && (unsigned long long)a.st_size==LBX_SOCIALBOX_MANAGER_SIZE) {
        NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)a.st_size];size_t readBytes=0;ssize_t count=0;
        while(readBytes<data.length && (count=read(fd,(char *)data.mutableBytes+readBytes,data.length-readBytes))>0)readBytes+=(size_t)count;
        valid=readBytes==data.length && !fstat(fd,&b) && a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_size==b.st_size &&
            a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec &&
            LBXDigestMatches(data.bytes,data.length,LBX_SOCIALBOX_MANAGER_SHA256);
    }
    close(fd);return valid;
}
__attribute__((constructor)) static void LBXAppSwitchInitialize(void) { @autoreleasepool {
    NSString *path=[NSBundle.mainBundle.executablePath stringByResolvingSymlinksInPath];
    if (!LBXPinnedSwitchHost(path)) { os_log_error(OS_LOG_DEFAULT,"LBX_SWITCH_STOP unsupported host; guard not installed");return; }
    Class cls=NSClassFromString(@"_Xr4s");
    Method getter=LBXOwnedMethod(cls,NSSelectorFromString(@"helperProxy"),"@16@0:8");
    Dl_info image={0};
    if (!getter || !dladdr((void *)LBXIMPAddress(method_getImplementation(getter)),&image) || !image.dli_fbase ||
        !image.dli_fname || ![[@(image.dli_fname) stringByResolvingSymlinksInPath] isEqual:path]) return;
    const struct mach_header_64 *header=image.dli_fbase;
    if (header->magic!=MH_MAGIC_64 || header->cputype!=CPU_TYPE_ARM64) return;
    unsigned subtype=header->cpusubtype&0xffffff;
    const LBXSwitchSite *site=subtype==0?&LBXArm64Site:subtype==2?&LBXArm64eSite:NULL;
    if (!site) return;
    uintptr_t base=(uintptr_t)image.dli_fbase;
    if (!LBXDigestMatches((void *)(base+site->worker),site->workerSize,site->workerHash) ||
        !LBXDigestMatches((void *)(base+site->stub),32,site->stubHash) ||
        !LBXDigestMatches((void *)(base+site->failure),site->failureSize,site->failureHash)) {
        os_log_error(OS_LOG_DEFAULT,"LBX_SWITCH_STOP changed worker/stub; guard not installed");return;
    }
    BOOL installed=LBXInstallSwitchSite(cls,base+site->getter,base+site->entry,base+site->returnPC);
    os_log(OS_LOG_DEFAULT,"LBX_SWITCH_STOP per-app guard installed=%{public}s",installed?"yes":"no");
    BOOL metadata=LBXInstallGlobalMetadata(cls,base+(subtype==0?0x22ff3c:0x235bd8),
        base+(subtype==0?0x23023c:0x235eec),base+(subtype==0?0x23037c:0x236030));
    os_log(OS_LOG_DEFAULT,"LBX_METADATA checked writer installed=%{public}s",metadata?"yes":"no");
}}
