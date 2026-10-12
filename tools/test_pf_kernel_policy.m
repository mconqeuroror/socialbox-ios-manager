#import "RBXPFKernelPolicy.h"
#import <arpa/inet.h>
#import <errno.h>
#import <math.h>
static unsigned checks;
#define CHECK(x) do { checks++; if(!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); exit(1); } } while(0)
static RBXPFPolicyPlan *Plan(void) {
    return [RBXPFPolicyPlan planWithRequest:@{@"bootEpoch":@"11000000-0000-4000-8000-000000000001",
        @"generation":@"22000000-0000-4000-8000-000000000002",@"containerId":@"fixture",
        @"scope":@"device-wide-proxy-only",@"transport":@"http",@"proxyIPs":@[@"9.9.9.9",@"8.8.8.8"],
        @"proxyPort":@3128,@"recoveryMode":@"out-of-band"} error:NULL];
}
static NSMutableArray *Readback(NSArray<NSData *> *images) {
    NSMutableArray *result=[NSMutableArray array];
    for(NSData *image in images) {
        NSMutableData *data=[image mutableCopy]; uint8_t *b=data.mutableBytes;
        RBXPFPut32(b,960,42); memset(b+128,0xa5,64); memset(b+648,0x5a,40);
        RBXPFPut32(b,904,77); RBXPFPut32(b,912,88);
        [result addObject:data];
    }
    return result;
}
@interface KernelFixture : NSObject
@property(nonatomic) RBXPFKernelMode mode;
@property(nonatomic,copy) NSString *fault;
@property(nonatomic,strong) NSArray<NSData *> *images;
@property(nonatomic) NSUInteger calls, statusCalls, ruleQueries, interfaceQueries;
@property(nonatomic) double now;
@end
@implementation KernelFixture
- (int)io:(unsigned long)command arg:(void *)arg {
    self.calls++; if([self.fault isEqual:@"io-failure"]) { errno=EIO; return -1; }
    if([self.fault isEqual:@"slow-io"])self.now+=6;
    if(command==RBXPF_GET_STATUS) {
        self.statusCalls++; uint8_t *b=arg;
        RBXPFPut32(b,376,self.mode==RBXPFKernelEmpty?0:1);
        if([self.fault isEqual:@"disabled"])RBXPFPut32(b,376,0);
        if([self.fault isEqual:@"running-invalid"])RBXPFPut32(b,376,2);
        if([self.fault isEqual:@"status-states"])RBXPFPut32(b,380,1);
        if([self.fault isEqual:@"source-nodes"])RBXPFPut32(b,384,1);
        if([self.fault isEqual:@"checksum-race"]&&self.statusCalls>1)b[424]=1;
        if([self.fault isEqual:@"between-snapshots"]&&self.statusCalls>2)b[424]=2;
    } else if(command==RBXPF_GET_ANCHORS) {
        RBXPFPut32(arg,0,[self.fault isEqual:@"foreign-anchor"]?1:0);
    } else if(command==RBXPF_GET_INTERFACES) {
        self.interfaceQueries++; RBXPFInterfaceRequest *q=arg;
        CHECK(q->elementSize==168&&q->count==256&&q->name[0]==0&&q->buffer);
        RBXPFInterfaceImage *items=q->buffer; q->count=2;
        memcpy(items[0].bytes,"en0",4); memcpy(items[1].bytes,"lo0",4);
        if([self.fault isEqual:@"skip-interface"])RBXPFPut32(items[0].bytes,152,0x100);
        if([self.fault isEqual:@"unknown-interface-flag"])RBXPFPut32(items[0].bytes,152,1);
        if([self.fault isEqual:@"interface-name-invalid"])memset(items[0].bytes,'x',16);
        if([self.fault isEqual:@"interface-duplicate"])memcpy(items[1].bytes,"en0",4);
        if([self.fault isEqual:@"interface-race"]&&self.interfaceQueries>1)memcpy(items[0].bytes,"en1",4);
        if([self.fault isEqual:@"interface-empty"])q->count=0;
        if([self.fault isEqual:@"interface-truncated"])q->count=256;
        if([self.fault isEqual:@"interface-negative"])q->count=-1;
    } else if(command==RBXPF_GET_RULES) {
        self.ruleQueries++; uint8_t *b=arg; unsigned action=b[RBXPF_RULE_OFFSET+1004];
        RBXPFPut32(b,4,10+action); RBXPFPut32(b,12,action==0?(uint32_t)self.images.count:0);
        if([self.fault isEqual:@"foreign-nat"]&&action==4)RBXPFPut32(b,12,1);
        if([self.fault isEqual:@"extra-rule"]&&action==0)RBXPFPut32(b,12,(uint32_t)self.images.count+1);
        if([self.fault isEqual:@"ticket-race"]&&self.ruleQueries==4)RBXPFPut32(b,4,11);
    } else if(command==RBXPF_GET_RULE) {
        uint8_t *b=arg; CHECK(RBXPFU32(b,0)==0&&RBXPFU32(b,4)==10&&b[16]==0);
        uint32_t index=RBXPFU32(b,12); CHECK(index<self.images.count);
        memcpy(b+RBXPF_RULE_OFFSET,[self.images[index] bytes],1040);
        if([self.fault isEqual:@"owner-mismatch"])b[RBXPF_RULE_OFFSET+696]='X';
        if([self.fault isEqual:@"predicate-mismatch"])b[RBXPF_RULE_OFFSET+1008]=0;
        if([self.fault isEqual:@"anchor-call"])b[1040]='X';
        if([self.fault isEqual:@"rule-ticket-mismatch"])RBXPFPut32(b,4,11);
        if([self.fault isEqual:@"rule-number-mismatch"])RBXPFPut32(b,12,index+1);
    } else if(command==RBXPF_GET_POOL) {
        CHECK(RBXPFU32(arg,4)==10); RBXPFPut32(arg,8,[self.fault isEqual:@"hidden-pool"]?1:0);
    } else if(command==RBXPF_GET_STATES) {
        RBXPFStatesRequest *q=arg; CHECK(q->length==0&&q->buffer==NULL);
        if([self.fault isEqual:@"retained-states"])q->length=297;
        if([self.fault isEqual:@"bad-state-size"])q->length=1;
        if([self.fault isEqual:@"negative-state-size"])q->length=-1;
        if([self.fault isEqual:@"too-many-states"])q->length=297*16385;
    } else { CHECK(NO); errno=EPERM; return -1; }
    return 0;
}
- (NSDictionary *)run:(RBXPFKernelPolicy *)policy error:(NSError **)error {
    RBXPFKernelReader *reader=[[RBXPFKernelReader alloc] initWithIO:^int(unsigned long cmd,void *arg) {
        return [self io:cmd arg:arg];
    } clock:^double { if([self.fault isEqual:@"reverse-clock"])self.now-=0.01; return self.now; }];
    return [reader verifyPolicy:policy mode:self.mode creatorPID:42 requireNoStates:YES error:error];
}
@end
int main(void) { @autoreleasepool {
    RBXPFPolicyPlan *plan=Plan(); CHECK(plan!=nil);
    NSError *error=nil; RBXPFKernelPolicy *policy=[RBXPFKernelPolicy policyWithPlan:plan error:&error];
    CHECK(policy!=nil&&error==nil); CHECK(policy.closedRuleImages.count==1&&policy.proxyRuleImages.count==3);
    const uint8_t *rule=[policy.proxyRuleImages[0] bytes]; struct in_addr address; inet_pton(AF_INET,"8.8.8.8",&address);
    CHECK(!memcmp(rule+64,&address,4)); CHECK(rule[80]==255&&rule[83]==255&&rule[84]==0);
    uint16_t port; memcpy(&port,rule+112,2); CHECK(ntohs(port)==3128&&rule[116]==2);
    CHECK(rule[1005]==2&&rule[1013]==AF_INET&&rule[1014]==IPPROTO_TCP&&rule[1017]==2&&rule[1018]==0x12);
    CHECK(rule[1008]==1&&rule[1012]==1&&rule[642]==AF_INET);
    CHECK(!strcmp((const char *)rule+696,"com.socialbox.pf"));
    NSMutableArray *images=Readback(policy.proxyRuleImages);
    CHECK([policy matchesImages:images mode:RBXPFKernelProxy creatorPID:42]);
    CHECK(![policy matchesImages:images mode:RBXPFKernelProxy creatorPID:43]);
    CHECK(![policy matchesImages:images mode:RBXPFKernelProxy creatorPID:0]);
    CHECK(![policy matchesImages:images mode:RBXPFKernelClosed creatorPID:42]);
    CHECK(![policy matchesImages:@[[NSData data]] mode:RBXPFKernelClosed creatorPID:42]);
    BOOL mutationRejected=NO;
    @try { [policy setValue:@[] forKey:@"closedRuleImages"]; }
    @catch(NSException *exception) { mutationRejected=[exception.name isEqual:NSUndefinedKeyException]; }
    CHECK(mutationRejected&&policy.closedRuleImages.count==1);
    RBXPFKernelPolicy *unconstructed=[RBXPFKernelPolicy new];
    CHECK(![unconstructed matchesImages:@[] mode:RBXPFKernelClosed creatorPID:42]);
    KernelFixture *invalid=[KernelFixture new]; invalid.mode=RBXPFKernelClosed; invalid.now=100; invalid.images=@[];
    CHECK(![invalid run:unconstructed error:&error]&&error&&invalid.calls==0);
    // Every byte outside the four reviewed dynamic ranges is significant.
    for(NSUInteger offset=0;offset<1040;offset++) {
        NSMutableArray *changed=Readback(policy.proxyRuleImages); uint8_t *b=[changed[0] mutableBytes]; b[offset]^=1;
        BOOL dynamic=(offset>=128&&offset<192)||(offset>=648&&offset<688)||
            (offset>=904&&offset<908)||(offset>=912&&offset<916);
        CHECK([policy matchesImages:changed mode:RBXPFKernelProxy creatorPID:42]==dynamic);
    }
    NSMutableArray *swapped=[images mutableCopy]; [swapped exchangeObjectAtIndex:0 withObjectAtIndex:1];
    CHECK(![policy matchesImages:swapped mode:RBXPFKernelProxy creatorPID:42]);
    [plan setValue:@[] forKey:@"proxyRules"];
    CHECK(![RBXPFKernelPolicy policyWithPlan:plan error:&error]&&error);
    for(NSUInteger mode=0;mode<3;mode++) {
        KernelFixture *f=[KernelFixture new]; f.mode=mode; f.now=100;
        f.images=mode==0?@[]:Readback(mode==1?policy.closedRuleImages:policy.proxyRuleImages);
        error=nil; NSDictionary *result=[f run:policy error:&error]; CHECK(result&&!error);
        CHECK([result[@"kernelReadbackMatches"] boolValue]); CHECK(![result[@"applicationAdmissionAllowed"] boolValue]);
        CHECK(![result[@"enforcementVerified"] boolValue]&&![result[@"atomicSnapshot"] boolValue]);
        CHECK(f.calls<256&&f.interfaceQueries==2);
        NSString *json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL] encoding:NSUTF8StringEncoding];
        CHECK([json rangeOfString:@"a5a5"].location==NSNotFound&&[json rangeOfString:@"8.8.8.8"].location==NSNotFound);
    }
    for(NSString *fault in @[@"io-failure",@"slow-io",@"disabled",@"running-invalid",@"status-states",@"source-nodes",
        @"checksum-race",@"between-snapshots",@"foreign-anchor",@"skip-interface",@"unknown-interface-flag",
        @"interface-name-invalid",@"interface-duplicate",@"interface-race",@"interface-empty",@"interface-truncated",
        @"interface-negative",@"foreign-nat",@"extra-rule",@"ticket-race",@"owner-mismatch",@"predicate-mismatch",
        @"anchor-call",@"rule-ticket-mismatch",@"rule-number-mismatch",@"hidden-pool",@"retained-states",@"bad-state-size",
        @"negative-state-size",@"too-many-states",@"reverse-clock"]) {
        KernelFixture *f=[KernelFixture new]; f.mode=RBXPFKernelProxy; f.images=images; f.now=100; f.fault=fault;
        error=nil; CHECK([f run:policy error:&error]==nil&&error!=nil); CHECK(f.calls<256);
    }
    for(NSNumber *time in @[@(NAN),@(INFINITY),@(-1),@(1e13)]) {
        KernelFixture *f=[KernelFixture new]; f.mode=RBXPFKernelProxy; f.images=images; f.now=time.doubleValue;
        error=nil; CHECK(![f run:policy error:&error]&&error); CHECK(f.calls==0);
    }
    printf("PASS: %u PF compiler/readback assertions (inert ioctl, ASan/UBSan; no kernel writes)\n",checks);
} return 0; }
