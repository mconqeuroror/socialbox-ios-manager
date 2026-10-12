#import "RBXPFKernelPolicy.h"
#import <arpa/inet.h>
#import <CommonCrypto/CommonDigest.h>
#import <errno.h>
#import <math.h>

static BOOL Fail(NSError **error,NSString *code) {
    if(error)*error=[NSError errorWithDomain:@"SocialBox.PFReadback" code:1 userInfo:@{NSLocalizedDescriptionKey:code}];
    return NO;
}
static NSString *Digest(NSData *data) {
    unsigned char h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,h);
    NSMutableString *s=[NSMutableString string]; for(unsigned i=0;i<sizeof(h);i++)[s appendFormat:@"%02x",h[i]];
    return [s copy];
}
static NSArray *Compile(NSArray<NSDictionary *> *rules) {
    NSMutableArray *images=[NSMutableArray array]; NSUInteger index=0;
    for(NSDictionary *rule in rules) {
        RBXPFRuleImage image={0}; uint8_t *b=image.bytes;
        NSData *label=[rule[@"label"] dataUsingEncoding:NSASCIIStringEncoding];
        if(!label.length||label.length>=64)return nil;
        memcpy(b+RBXPFRuleLabel,label.bytes,label.length); memcpy(b+RBXPFRuleOwner,"com.socialbox.pf",16);
        b[RBXPFRuleQuick]=1; RBXPFPut32(b,RBXPFRuleNumber,(uint32_t)index++);
        if([rule[@"action"] isEqual:@"block"]) { b[RBXPFRuleAction]=RBXPFDrop; }
        else {
            b[RBXPFRuleDirection]=RBXPFOut; b[RBXPFRuleKeepState]=RBXPFKeepState; b[RBXPFRuleFamily]=AF_INET; b[RBXPFRuleProtocol]=IPPROTO_TCP;
            b[RBXPFRuleTCPFlags]=RBXPFTcpSyn; b[RBXPFRuleTCPFlagMask]=RBXPFTcpSyn|RBXPFTcpAck; b[RBXPFRulePoolFamily]=AF_INET;
            NSString *ip=[rule[@"destination"] stringByDeletingLastPathComponent];
            if(inet_pton(AF_INET,ip.UTF8String,b+RBXPFRuleDestination)!=1)return nil;
            memset(b+RBXPFRuleDestinationMask,0xff,4);
            uint16_t port=htons([rule[@"destinationPort"] unsignedShortValue]);
            memcpy(b+RBXPFRuleDestinationPortLow,&port,2); memcpy(b+RBXPFRuleDestinationPortHigh,&port,2); b[RBXPFRuleDestinationPortOp]=RBXPFEqual;
        }
        [images addObject:[NSData dataWithBytes:&image length:sizeof(image)]];
    }
    return [images copy];
}
@interface RBXPFKernelPolicy () {
    BOOL _constructed;
}
- (instancetype)initWithCheckedPlan:(RBXPFPolicyPlan *)plan;
- (BOOL)isConstructed;
@end
@implementation RBXPFKernelPolicy
+ (BOOL)accessInstanceVariablesDirectly { return NO; }
- (BOOL)isConstructed { return _constructed; }
- (instancetype)initWithCheckedPlan:(RBXPFPolicyPlan *)plan {
    if((self=[super init])) {
        _closedRuleImages=Compile(plan.closedRules); _proxyRuleImages=Compile(plan.proxyRules);
        if(!_closedRuleImages||!_proxyRuleImages)return nil;
        _closedDigest=[plan.closedDigest copy]; _proxyDigest=[plan.proxyDigest copy]; _constructed=YES;
    }
    return self;
}
+ (instancetype)policyWithPlan:(RBXPFPolicyPlan *)plan error:(NSError **)error {
    if([plan class]!=RBXPFPolicyPlan.class) { Fail(error,@"PF_PLAN_INVALID"); return nil; }
    RBXPFPolicyPlan *checked=[RBXPFPolicyPlan planWithRequest:plan.binding error:error];
    if(!checked||![plan.closedRules isEqual:checked.closedRules]||![plan.proxyRules isEqual:checked.proxyRules]||
       ![plan.closedDigest isEqual:checked.closedDigest]||![plan.proxyDigest isEqual:checked.proxyDigest]) {
        Fail(error,@"PF_PLAN_CHANGED"); return nil;
    }
    RBXPFKernelPolicy *p=[[self alloc] initWithCheckedPlan:checked];
    if(!p)Fail(error,@"PF_RULE_COMPILE_FAILED");
    return p;
}
- (BOOL)matchesImages:(NSArray<NSData *> *)images mode:(RBXPFKernelMode)mode creatorPID:(pid_t)pid {
    if(!_constructed||pid<=0||(mode!=RBXPFKernelClosed&&mode!=RBXPFKernelProxy)||![images isKindOfClass:NSArray.class])return NO;
    NSArray *expected=mode==RBXPFKernelClosed?self.closedRuleImages:self.proxyRuleImages;
    if(images.count!=expected.count)return NO;
    for(NSUInteger i=0;i<expected.count;i++) {
        if(![images[i] isKindOfClass:NSData.class]||[images[i] length]!=sizeof(RBXPFRuleImage))return NO;
        RBXPFRuleImage actual,want; [images[i] getBytes:&actual length:sizeof(actual)]; [expected[i] getBytes:&want length:sizeof(want)];
        RBXPFPut32(want.bytes,RBXPFRuleCreatorPID,(uint32_t)pid);
        // Exactly the kernel-computed skip array and traffic/ref counters vary.
        // Creator uid/pid, rule number, pool family, ownership, all predicates,
        // route/tag/timeout/limit fields and all reserved bytes must still match.
        const size_t dynamic[][2]={{RBXPFRuleSkip,64},{RBXPFRuleCounters,40},{RBXPFRuleStates,4},{RBXPFRuleSourceNodes,4}};
        for(NSUInteger j=0;j<sizeof(dynamic)/sizeof(dynamic[0]);j++)memset(actual.bytes+dynamic[j][0],0,dynamic[j][1]);
        if(memcmp(&actual,&want,sizeof(actual)))return NO;
    }
    return YES;
}
@end

@interface RBXPFKernelReader ()
@property(nonatomic,copy) RBXPFReadIO io;
@property(nonatomic,copy) RBXPFMonotonicClock clock;
@end
@implementation RBXPFKernelReader
- (instancetype)initWithIO:(RBXPFReadIO)io clock:(RBXPFMonotonicClock)clock {
    if(!io||!clock)return nil;
    if((self=[super init])) { _io=[io copy]; _clock=[clock copy]; } return self;
}
- (BOOL)query:(unsigned long)command arg:(void *)arg budget:(NSUInteger *)budget
         time:(double *)time deadline:(double)deadline error:(NSError **)error {
    BOOL permitted=command==RBXPF_GET_STATUS||command==RBXPF_GET_RULES||command==RBXPF_GET_RULE||
        command==RBXPF_GET_ANCHORS||command==RBXPF_GET_POOL||command==RBXPF_GET_INTERFACES||command==RBXPF_GET_STATES;
    if(!arg||!permitted||(command==RBXPF_GET_RULE&&RBXPFU32(arg,RBXPFRequestAction)!=0))return Fail(error,@"PF_WRITE_REJECTED");
    double now=self.clock();
    if(!isfinite(now)||now<*time||now>=deadline||!*budget)return Fail(error,@"PF_INSPECTION_EXPIRED");
    *time=now; (*budget)--;
    if(self.io(command,arg)!=0)return Fail(error,@"PF_KERNEL_QUERY_FAILED");
    now=self.clock();
    if(!isfinite(now)||now<*time||now>=deadline)return Fail(error,@"PF_INSPECTION_EXPIRED");
    *time=now; return YES;
}
- (NSDictionary *)observe:(RBXPFKernelPolicy *)policy mode:(RBXPFKernelMode)mode creatorPID:(pid_t)pid
          requireNoStates:(BOOL)requireNoStates budget:(NSUInteger *)budget time:(double *)time
                 deadline:(double)deadline error:(NSError **)error {
    // Keep the caller's autoreleasing error slot on this stack; a captured
    // out-parameter would escape its ARC write-back lifetime into a block.
#define query(command, argument) [self query:(command) arg:(argument) budget:budget time:time deadline:deadline error:error]
    RBXPFStatusRequest before={0},after={0};
    if(!query(RBXPF_GET_STATUS,&before))return nil;
    uint32_t running=RBXPFU32(before.bytes,RBXPFStatusRunning);
    if(running!=(mode==RBXPFKernelEmpty?0:1)) { Fail(error,@"PF_ENABLE_STATE_MISMATCH"); return nil; }
    RBXPFAnchorRequest anchors={0};
    if(!query(RBXPF_GET_ANCHORS,&anchors))return nil;
    if(RBXPFU32(anchors.bytes,0)) { Fail(error,@"PF_FOREIGN_ANCHORS"); return nil; }
    // Query the PF interface flags, not ordinary getifaddrs flags. A skip flag
    // bypasses filtering before any of our otherwise-correct rules can run.
    RBXPFInterfaceImage interfaces[RBXPF_MAX_INTERFACES]={0};
    RBXPFInterfaceRequest iface={0}; iface.buffer=interfaces; iface.elementSize=sizeof(interfaces[0]); iface.count=RBXPF_MAX_INTERFACES;
    if(!query(RBXPF_GET_INTERFACES,&iface))return nil;
    if(iface.count<=0||iface.count>=RBXPF_MAX_INTERFACES) { Fail(error,@"PF_INTERFACE_INVENTORY_INCOMPLETE"); return nil; }
    NSMutableArray<NSString *> *names=[NSMutableArray array];
    for(int i=0;i<iface.count;i++) {
        const uint8_t *b=interfaces[i].bytes;
        if(!memchr(b,0,16)||!b[0]||RBXPFU32(b,RBXPFInterfaceFlags)!=0) { Fail(error,@"PF_INTERFACE_BYPASS_OR_UNKNOWN_FLAGS"); return nil; }
        NSString *name=[[NSString alloc] initWithBytes:b length:strnlen((const char *)b,16) encoding:NSASCIIStringEncoding];
        if(!name||[names containsObject:name]) { Fail(error,@"PF_INTERFACE_INVENTORY_INVALID"); return nil; }
        [names addObject:name];
    }
    [names sortUsingSelector:@selector(compare:)];
    NSData *interfaceBytes=[NSJSONSerialization dataWithJSONObject:names options:0 error:NULL];
    NSMutableArray *tickets=[NSMutableArray array],*images=[NSMutableArray array];
    NSUInteger expectedCount=mode==RBXPFKernelEmpty?0:(mode==RBXPFKernelClosed?policy.closedRuleImages.count:policy.proxyRuleImages.count);
    const unsigned families[]={RBXPFScrub,RBXPFPass,RBXPFNat,RBXPFBinat,RBXPFRdr,RBXPFDummynet};
    for(NSUInteger family=0;family<6;family++) {
        RBXPFRuleRequest q={0}; q.bytes[RBXPF_RULE_OFFSET+RBXPFRuleAction]=families[family];
        if(!query(RBXPF_GET_RULES,&q))return nil;
        uint32_t count=RBXPFU32(q.bytes,RBXPFRequestNumber),ticket=RBXPFU32(q.bytes,RBXPFRequestTicket);
        if(count!=(family==1?expectedCount:0)) { Fail(error,@"PF_UNEXPECTED_RULE_COUNT"); return nil; }
        [tickets addObject:@(ticket)];
        for(uint32_t i=0;i<count;i++) {
            memset(&q,0,sizeof(q)); q.bytes[RBXPF_RULE_OFFSET+RBXPFRuleAction]=families[family];
            RBXPFPut32(q.bytes,RBXPFRequestTicket,ticket); RBXPFPut32(q.bytes,RBXPFRequestNumber,i);
            if(!query(RBXPF_GET_RULE,&q))return nil;
            if(q.bytes[RBXPFRequestAnchorCall]||RBXPFU32(q.bytes,RBXPFRequestTicket)!=ticket||RBXPFU32(q.bytes,RBXPFRequestNumber)!=i) { Fail(error,@"PF_RULE_OWNER_OR_TICKET_CHANGED"); return nil; }
            [images addObject:[NSData dataWithBytes:q.bytes+RBXPF_RULE_OFFSET length:sizeof(RBXPFRuleImage)]];
            RBXPFPoolRequest pool={0}; RBXPFPut32(pool.bytes,RBXPFPoolTicket,ticket); RBXPFPut32(pool.bytes,RBXPFPoolRuleNumber,i); pool.bytes[RBXPFPoolAction]=families[family];
            if(!query(RBXPF_GET_POOL,&pool))return nil;
            if(RBXPFU32(pool.bytes,RBXPFPoolCount)) { Fail(error,@"PF_UNEXPECTED_ADDRESS_POOL"); return nil; }
        }
        memset(&q,0,sizeof(q)); q.bytes[RBXPF_RULE_OFFSET+RBXPFRuleAction]=families[family];
        if(!query(RBXPF_GET_RULES,&q))return nil;
        if(RBXPFU32(q.bytes,RBXPFRequestTicket)!=ticket||RBXPFU32(q.bytes,RBXPFRequestNumber)!=count) { Fail(error,@"PF_RULESET_CHANGED"); return nil; }
    }
    if(mode!=RBXPFKernelEmpty&&![policy matchesImages:images mode:mode creatorPID:pid]) { Fail(error,@"PF_RULE_SEMANTICS_MISMATCH"); return nil; }
    RBXPFStatesRequest states={0};
    if(!query(RBXPF_GET_STATES,&states))return nil;
    if(states.length<0||states.length%RBXPFStateSize||states.length/RBXPFStateSize>16384) { Fail(error,@"PF_STATE_INVENTORY_INVALID"); return nil; }
    if(!query(RBXPF_GET_STATUS,&after))return nil;
    if(RBXPFU32(after.bytes,RBXPFStatusRunning)!=running||memcmp(before.bytes+RBXPFStatusChecksum,after.bytes+RBXPFStatusChecksum,16)) { Fail(error,@"PF_STATUS_CHANGED"); return nil; }
    if((requireNoStates||mode==RBXPFKernelEmpty)&&(states.length||RBXPFU32(before.bytes,RBXPFStatusStates)||RBXPFU32(after.bytes,RBXPFStatusStates)||
       RBXPFU32(before.bytes,RBXPFStatusSourceNodes)||RBXPFU32(after.bytes,RBXPFStatusSourceNodes))) { Fail(error,@"PF_RETAINED_STATE"); return nil; }
    NSData *checksum=[NSData dataWithBytes:after.bytes+RBXPFStatusChecksum length:16];
    return @{@"rootTickets":tickets,@"pfChecksum":[checksum base64EncodedStringWithOptions:0],
        @"interfacePolicyDigest":Digest(interfaceBytes),@"interfaceCount":@(iface.count),
        @"requireNoStates":@(requireNoStates||mode==RBXPFKernelEmpty),@"kernelReadbackMatches":@YES,
        @"mode":@(mode),@"scope":@"device-wide-proxy-only",@"enforcementVerified":@NO,
        @"applicationAdmissionAllowed":@NO,@"atomicSnapshot":@NO,
        @"policyDigest":mode==RBXPFKernelEmpty?@"empty-and-disabled":(mode==RBXPFKernelClosed?policy.closedDigest:policy.proxyDigest)};
#undef query
}
- (NSDictionary *)verifyPolicy:(RBXPFKernelPolicy *)policy mode:(RBXPFKernelMode)mode creatorPID:(pid_t)pid
               requireNoStates:(BOOL)requireNoStates error:(NSError **)error {
    if(error)*error=nil;
    if(mode>RBXPFKernelProxy||(mode!=RBXPFKernelEmpty&&([policy class]!=RBXPFKernelPolicy.class||![policy isConstructed]||pid<=0))) {
        Fail(error,@"PF_READBACK_REQUEST_INVALID"); return nil;
    }
    double now=self.clock();
    if(!isfinite(now)||now<0||now>1e12) { Fail(error,@"PF_CLOCK_INVALID"); return nil; }
    double deadline=now+5; NSUInteger budget=256;
    NSDictionary *first=[self observe:policy mode:mode creatorPID:pid requireNoStates:requireNoStates budget:&budget time:&now deadline:deadline error:error];
    if(!first)return nil;
    NSDictionary *second=[self observe:policy mode:mode creatorPID:pid requireNoStates:requireNoStates budget:&budget time:&now deadline:deadline error:error];
    if(!second)return nil;
    if(![first isEqual:second]) { Fail(error,@"PF_SNAPSHOT_CHANGED"); return nil; }
    return second;
}
@end
