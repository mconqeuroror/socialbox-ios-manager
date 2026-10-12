#import <Foundation/Foundation.h>
#include <xpc/xpc.h>
#include <dlfcn.h>
// Mach-service creation is private on iOS. Use its actual runtime symbol; an
// absent API is an unsupported host, not a reason to use a TCP/socket fallback.
static inline xpc_connection_t LBXCreateMachService(const char *name, dispatch_queue_t queue, uint64_t flags) {
    typedef xpc_connection_t (*Factory)(const char *,dispatch_queue_t,uint64_t);
    Factory factory=(Factory)dlsym(RTLD_DEFAULT,"xpc_connection_create_mach_service");
    return factory?factory(name,queue,flags):NULL;
}
