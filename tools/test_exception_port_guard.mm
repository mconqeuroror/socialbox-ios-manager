#define RBX_EXCEPTION_PORT_TESTING 1
#import "../tweak/Common/RBXExceptionPortGuard.mm"
#include <stdio.h>
#include <stdlib.h>
static unsigned checks,calls;static exception_mask_t observed;static task_t taskObserved;static mach_port_t portObserved;
static void Check(bool ok){checks++;if(!ok){fprintf(stderr,"FAIL exception dispatch %u\n",checks);exit(1);}}
static kern_return_t Set(task_t task,exception_mask_t mask,mach_port_t port,exception_behavior_t b,thread_state_flavor_t f){calls++;taskObserved=task;observed=mask;portObserved=port;return 123;}
static kern_return_t Swap(task_t task,exception_mask_t mask,mach_port_t port,exception_behavior_t b,thread_state_flavor_t f,exception_mask_array_t masks,mach_msg_type_number_t *count,exception_handler_array_t ports,exception_behavior_array_t bs,exception_flavor_array_t fs){Set(task,mask,port,b,f);*count=1;masks[0]=mask;ports[0]=999;bs[0]=b;fs[0]=f;return 124;}
int main(){rbxOriginalSet=Set;rbxOriginalSwap=Swap;rbxGuardedTask=515;rbxDispatcher=5635;
 unsigned crashes=EXC_MASK_BAD_ACCESS|EXC_MASK_BAD_INSTRUCTION|EXC_MASK_ARITHMETIC;
 Check(RBXSetExceptionPorts(515,crashes|EXC_MASK_BREAKPOINT,14595,EXCEPTION_DEFAULT,6)==123&&observed==crashes&&portObserved==14595);
 unsigned before=calls;Check(RBXSetExceptionPorts(515,EXC_MASK_BREAKPOINT,14595,EXCEPTION_DEFAULT,6)==KERN_PROTECTION_FAILURE&&calls==before);
 Check(RBXSetExceptionPorts(515,EXC_MASK_BREAKPOINT,5635,EXCEPTION_DEFAULT,6)==123&&observed==EXC_MASK_BREAKPOINT);
 Check(RBXSetExceptionPorts(999,crashes|EXC_MASK_BREAKPOINT,14595,EXCEPTION_DEFAULT,6)==123&&observed==(crashes|EXC_MASK_BREAKPOINT)&&taskObserved==999);
 Check(RBXSetExceptionPorts(515,crashes,0,EXCEPTION_DEFAULT,6)==123&&observed==crashes);
 exception_mask_t masks[EXC_TYPES_COUNT]={};mach_port_t ports[EXC_TYPES_COUNT]={};exception_behavior_t bs[EXC_TYPES_COUNT]={};thread_state_flavor_t fs[EXC_TYPES_COUNT]={};mach_msg_type_number_t count=EXC_TYPES_COUNT;
 Check(RBXSwapExceptionPorts(515,crashes|EXC_MASK_BREAKPOINT,14595,EXCEPTION_DEFAULT,6,masks,&count,ports,bs,fs)==124&&observed==crashes&&count==1&&masks[0]==crashes&&ports[0]==999);
 before=calls;count=EXC_TYPES_COUNT;Check(RBXSwapExceptionPorts(515,EXC_MASK_BREAKPOINT,0,EXCEPTION_DEFAULT,6,masks,&count,ports,bs,fs)==KERN_PROTECTION_FAILURE&&calls==before&&count==EXC_TYPES_COUNT);
 rbxDispatcher=MACH_PORT_NULL;Check(RBXSetExceptionPorts(515,crashes|EXC_MASK_BREAKPOINT,14595,EXCEPTION_DEFAULT,6)==123&&observed==(crashes|EXC_MASK_BREAKPOINT));
 printf("PASS %u actual exception-port wrapper assertions; reserved dispatcher, crash masks, swap outputs and foreign tasks\n",checks);return 0;}
