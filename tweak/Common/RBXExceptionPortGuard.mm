#import "RBXExceptionPortGuard.h"
#include <mach/mach.h>
#ifndef RBX_EXCEPTION_PORT_TESTING
#import "RBXHookInstallation.h"
#include <dlfcn.h>
#endif

// Facebook's crash reporter replaces EXC_MASK_BREAKPOINT along with its crash
// masks. ElleKit uses that one mask to dispatch BRK-based C detours. Preserve
// the already-installed dispatcher; other exception classes remain untouched.
static mach_port_t rbxDispatcher = MACH_PORT_NULL;
static task_t rbxGuardedTask = MACH_PORT_NULL;
static kern_return_t (*rbxOriginalSet)(task_t, exception_mask_t, mach_port_t,
    exception_behavior_t, thread_state_flavor_t);
static kern_return_t (*rbxOriginalSwap)(task_t, exception_mask_t, mach_port_t,
    exception_behavior_t, thread_state_flavor_t, exception_mask_array_t,
    mach_msg_type_number_t *, exception_handler_array_t, exception_behavior_array_t,
    exception_flavor_array_t);
static exception_mask_t RBXPreservedMask(task_t task, exception_mask_t mask, mach_port_t port) {
    return rbxDispatcher != MACH_PORT_NULL && task == rbxGuardedTask && port != rbxDispatcher
        ? mask & ~EXC_MASK_BREAKPOINT : mask;
}
static kern_return_t RBXSetExceptionPorts(task_t task, exception_mask_t mask, mach_port_t port,
    exception_behavior_t behavior, thread_state_flavor_t flavor) {
    exception_mask_t allowed=RBXPreservedMask(task,mask,port);
    // A request solely for the reserved mask is explicitly refused. Mixed
    // registrations retain the reporter's actual crash exception handlers.
    if(mask && !allowed)return KERN_PROTECTION_FAILURE;
    return rbxOriginalSet(task,allowed,port,behavior,flavor);
}
static kern_return_t RBXSwapExceptionPorts(task_t task, exception_mask_t mask, mach_port_t port,
    exception_behavior_t behavior, thread_state_flavor_t flavor, exception_mask_array_t masks,
    mach_msg_type_number_t *count, exception_handler_array_t ports,
    exception_behavior_array_t behaviors, exception_flavor_array_t flavors) {
    exception_mask_t allowed=RBXPreservedMask(task,mask,port);
    if(mask && !allowed)return KERN_PROTECTION_FAILURE;
    return rbxOriginalSwap(task,allowed,port,behavior,flavor,masks,count,ports,behaviors,flavors);
}
#ifndef RBX_EXCEPTION_PORT_TESTING
BOOL RBXExceptionPortGuardVerified(void) {
    if(!rbxDispatcher || !RBXHookInstallationPassed())return NO;
    exception_mask_t masks[EXC_TYPES_COUNT]; mach_port_t ports[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT]; thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    mach_msg_type_number_t count=EXC_TYPES_COUNT;
    kern_return_t result=task_get_exception_ports(rbxGuardedTask,EXC_MASK_BREAKPOINT,masks,&count,ports,behaviors,flavors);
    if(result!=KERN_SUCCESS)return NO;
    BOOL found=NO;
    for(mach_msg_type_number_t i=0;i<count;i++){
        if((masks[i]&EXC_MASK_BREAKPOINT)&&ports[i]==rbxDispatcher)found=YES;
        if(MACH_PORT_VALID(ports[i]))mach_port_deallocate(mach_task_self(),ports[i]);
    }
    return found;
}
BOOL RBXInstallExceptionPortGuard(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // This compatibility policy is specific to the detected ElleKit ABI.
        if(!dlsym(RTLD_DEFAULT,"EKHookFunction"))return;
        exception_mask_t masks[EXC_TYPES_COUNT]; mach_port_t ports[EXC_TYPES_COUNT];
        exception_behavior_t behaviors[EXC_TYPES_COUNT]; thread_state_flavor_t flavors[EXC_TYPES_COUNT];
        mach_msg_type_number_t count=EXC_TYPES_COUNT;rbxGuardedTask=mach_task_self();
        if(task_get_exception_ports(rbxGuardedTask,EXC_MASK_BREAKPOINT,masks,&count,ports,behaviors,flavors)!=KERN_SUCCESS)return;
        for(mach_msg_type_number_t i=0;i<count;i++){
            if(!rbxDispatcher&&(masks[i]&EXC_MASK_BREAKPOINT)&&MACH_PORT_VALID(ports[i])&&behaviors[i]==EXCEPTION_DEFAULT){
                rbxDispatcher=ports[i]; // retain this send right for process lifetime
            }else if(MACH_PORT_VALID(ports[i]))mach_port_deallocate(mach_task_self(),ports[i]);
        }
        if(!rbxDispatcher)return;
        MSHookFunction((void *)task_set_exception_ports,(void *)RBXSetExceptionPorts,(void **)&rbxOriginalSet);
        MSHookFunction((void *)task_swap_exception_ports,(void *)RBXSwapExceptionPorts,(void **)&rbxOriginalSwap);
    });
    return RBXExceptionPortGuardVerified();
}
#endif
