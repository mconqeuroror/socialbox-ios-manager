#import "RBXPFPolicyPlan.h"
#import <CommonCrypto/CommonDigest.h>
#import <arpa/inet.h>
#import <math.h>

static BOOL RBXPFFail(NSError **error,NSString *message) {
    if(error)*error=[NSError errorWithDomain:@"SocialBox.ExperimentalPF" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static BOOL RBXPFBoolean(id n,BOOL expected) {
    return [n isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)n)==CFBooleanGetTypeID()&&[n boolValue]==expected;
}
static BOOL RBXPFNumber(id n,double low,double high) {
    return [n isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)n)!=CFBooleanGetTypeID()&&
        isfinite([n doubleValue])&&[n doubleValue]>=low&&[n doubleValue]<=high&&floor([n doubleValue])==[n doubleValue];
}
static id RBXPFFreeze(id object) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:NULL];
    return data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
}
static NSString *RBXPFDigest(id object) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:NULL];
    if(!data||data.length>UINT32_MAX)return nil;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,hash);
    NSMutableString *result=[NSMutableString stringWithCapacity:64];
    for(unsigned i=0;i<sizeof(hash);i++)[result appendFormat:@"%02x",hash[i]];
    return [result copy];
}
BOOL RBXPFMutationMatchesFence(NSDictionary *mutation,NSDictionary *fence) {
    if(![mutation isKindOfClass:NSDictionary.class]||![fence isKindOfClass:NSDictionary.class]||
       ![@[@"install-closed",@"install-proxy"] containsObject:mutation[@"action"]]||
       !RBXPFNumber(mutation[@"sequence"],1,64)||!RBXPFNumber(fence[@"fencedThroughSequence"],0,64)||
       !RBXPFNumber(fence[@"lastCommittedSequence"],0,64)||
       [fence[@"lastCommittedSequence"] unsignedIntegerValue]<[fence[@"fencedThroughSequence"] unsignedIntegerValue]||
       [mutation[@"sequence"] unsignedIntegerValue]<=[fence[@"lastCommittedSequence"] unsignedIntegerValue])return NO;
    for(NSString *key in @[@"bootEpoch",@"generation",@"containerId",@"mutationFence"])
        if(![mutation[key] isKindOfClass:NSString.class]||![mutation[key] length]||![mutation[key] isEqual:fence[key]])return NO;
    return [[NSUUID alloc] initWithUUIDString:mutation[@"mutationFence"]]!=nil;
}
static NSString *RBXPFPublicIPv4(id value) {
    if(![value isKindOfClass:NSString.class]||[value length]>15)return nil;
    struct in_addr addr={0}; if(inet_pton(AF_INET,[value UTF8String],&addr)!=1)return nil;
    uint32_t n=ntohl(addr.s_addr); unsigned a=n>>24,b=(n>>16)&255,c=(n>>8)&255;
    // V1 is intentionally external IPv4 only. IPv6, DNS resolution, local LAN,
    // multicast and interface-scoped/bootstrap exceptions need separate design.
    if(a==0||a==10||a==127||a>=224||(a==100&&b>=64&&b<=127)||
       (a==169&&b==254)||(a==172&&b>=16&&b<=31)||(a==192&&b==168)||
       (a==192&&b==0&&(c==0||c==2))||(a==198&&(b==18||b==19))||
       (a==198&&b==51&&c==100)||(a==203&&b==0&&c==113))return nil;
    char canonical[INET_ADDRSTRLEN]; if(!inet_ntop(AF_INET,&addr,canonical,sizeof(canonical)))return nil;
    return @(canonical);
}

@interface RBXPFPolicyPlan ()
@property(nonatomic,readwrite) NSDictionary *binding;
@property(nonatomic,readwrite) NSArray<NSDictionary *> *closedRules;
@property(nonatomic,readwrite) NSArray<NSDictionary *> *proxyRules;
@property(nonatomic,readwrite) NSString *closedDigest;
@property(nonatomic,readwrite) NSString *proxyDigest;
@property(nonatomic,readwrite) NSArray<NSString *> *externalObligations;
@end
@implementation RBXPFPolicyPlan
+ (instancetype)planWithRequest:(NSDictionary *)request error:(NSError **)error {
    if(![request isKindOfClass:NSDictionary.class]) { RBXPFFail(error,@"A dictionary request is required."); return nil; }
    NSSet *keys=[NSSet setWithArray:@[@"bootEpoch",@"generation",@"containerId",@"scope",@"transport",@"proxyIPs",@"proxyPort",@"recoveryMode"]];
    if(request.count!=keys.count||![[NSSet setWithArray:request.allKeys] isEqualToSet:keys]) {
        RBXPFFail(error,@"Unknown or missing fields; credentials, bypasses and custom rules are unsupported."); return nil;
    }
    if(![request[@"scope"] isEqual:@"device-wide-proxy-only"]||![request[@"transport"] isEqual:@"http"]||
       ![request[@"recoveryMode"] isEqual:@"out-of-band"]) {
        RBXPFFail(error,@"Only device-wide HTTP planning with out-of-band recovery is supported; no per-app claim or USB exception."); return nil;
    }
    NSString *epoch=request[@"bootEpoch"],*generation=request[@"generation"],*container=request[@"containerId"];
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    if(![epoch isKindOfClass:NSString.class]||![[NSUUID alloc] initWithUUIDString:epoch]||
       ![generation isKindOfClass:NSString.class]||![[NSUUID alloc] initWithUUIDString:generation]||
       ![container isKindOfClass:NSString.class]||container.length<1||container.length>128||
       [container rangeOfCharacterFromSet:allowed.invertedSet].location!=NSNotFound||
       [container isEqual:@"."]||[container isEqual:@".."]) {
        RBXPFFail(error,@"Invalid epoch, generation or container binding."); return nil;
    }
    NSArray *values=request[@"proxyIPs"];
    if(![values isKindOfClass:NSArray.class]||!values.count||values.count>16||!RBXPFNumber(request[@"proxyPort"],1,65535)) {
        RBXPFFail(error,@"A bounded numeric proxy endpoint is required."); return nil;
    }
    NSMutableArray *addresses=[NSMutableArray array];
    for(id item in values) {
        NSString *ip=RBXPFPublicIPv4(item);
        if(!ip||[addresses containsObject:ip]) { RBXPFFail(error,@"Proxy addresses must be unique external IPv4 literals; DNS, IPv6 and local exceptions are unsupported."); return nil; }
        [addresses addObject:ip];
    }
    [addresses sortUsingComparator:^NSComparisonResult(NSString *a,NSString *b) {
        struct in_addr av={0},bv={0}; inet_pton(AF_INET,a.UTF8String,&av); inet_pton(AF_INET,b.UTF8String,&bv);
        uint32_t x=ntohl(av.s_addr),y=ntohl(bv.s_addr); return x<y?NSOrderedAscending:x>y?NSOrderedDescending:NSOrderedSame;
    }];
    RBXPFPolicyPlan *plan=[self new];
    plan.binding=RBXPFFreeze(@{@"bootEpoch":[[NSUUID alloc] initWithUUIDString:epoch].UUIDString,
        @"generation":[[NSUUID alloc] initWithUUIDString:generation].UUIDString,@"containerId":container,
        @"scope":@"device-wide-proxy-only",@"transport":@"http",@"proxyIPs":addresses,
        @"proxyPort":request[@"proxyPort"],@"recoveryMode":@"out-of-band"});
    // The binding must affect kernel-representable rule labels, not merely an
    // external receipt: otherwise old rules could look current after a switch.
    NSString *bindingLabel=[RBXPFDigest(plan.binding) substringToIndex:52];
    NSDictionary *deny=@{@"action":@"block",@"direction":@"any",@"family":@"any",@"protocol":@"any",@"quick":@YES,
        @"label":[@"rbxpf.d." stringByAppendingString:bindingLabel]};
    plan.closedRules=RBXPFFreeze(@[deny]);
    NSMutableArray *rules=[NSMutableArray array];
    NSUInteger index=0;
    for(NSString *address in addresses)[rules addObject:@{@"action":@"pass",@"direction":@"out",@"family":@"inet",
        @"protocol":@"tcp",@"destination":[address stringByAppendingString:@"/32"],@"destinationPort":request[@"proxyPort"],
        @"tcpFlags":@"S",@"tcpFlagMask":@"SA",@"keepState":@YES,@"quick":@YES,
        @"label":[NSString stringWithFormat:@"rbxpf.p%02lu.%@",(unsigned long)index++,bindingLabel]}];
    [rules addObject:deny]; plan.proxyRules=RBXPFFreeze(rules);
    plan.closedDigest=RBXPFDigest(@{@"version":@1,@"binding":plan.binding,@"rules":plan.closedRules});
    plan.proxyDigest=RBXPFDigest(@{@"version":@1,@"binding":plan.binding,@"rules":plan.proxyRules});
    plan.externalObligations=@[
        @"A trusted adapter must prove kernel enforcement and atomic ownership/order; this AST is not an installable policy.",
        @"An external recovery path is required. IPv6 USB SSH and Neighbor Discovery exceptions are unsupported.",
        @"Ordinary apps share UID 501: this policy cannot identify a selected container or its brokered traffic.",
        @"Any process reaching the allowed proxy can use it; proxy credentials are not a per-container kernel boundary.",
        @"An independent revoker must install deny and purge states after daemon death/expiry; its own death remains an acceptance requirement.",
        @"PF retained states must be revoked before closure is acknowledged; rule replacement alone is insufficient.",
        @"Physical IPv4/IPv6, DNS/QUIC, process/broker, handoff, death and reboot captures remain required.",
        @"Generation and boot binding need a trusted fresh source; informational journal status must never be restored as evidence.",
        @"All writers must drain and honor a fresh mutation fence plus monotonic commit sequence under the kernel-commit lock; ACK rejection alone cannot prevent a late write.",
        @"Non-empty foreign policies, IPv6 proxy/bootstrap, DNS/cloud/rotation bypasses and general root/loopback exceptions are unsupported."
    ];
    return plan;
}
- (NSDictionary *)publicSummary {
    return @{@"modelVersion":@1,@"scope":@"device-wide-proxy-only",@"binding":self.binding?:@{},
        @"closedDigest":self.closedDigest?:@"",@"proxyDigest":self.proxyDigest?:@"",
        @"externalObligations":self.externalObligations?:@[],@"enforcementVerified":@NO,@"applicationAdmissionAllowed":@NO};
}
@end

@interface RBXPFTransactionModel ()
@property(nonatomic,readwrite) RBXPFPolicyPlan *plan;
@property(nonatomic,readwrite) NSString *phase;
@property(nonatomic,readwrite,nullable) NSDictionary *requestedAction;
@property(nonatomic,readwrite) BOOL closedConfirmedInModel;
@property(nonatomic,readwrite) BOOL proxyPolicyConfirmedInModel;
@property(nonatomic,readwrite) BOOL recovering;
@property(nonatomic,readwrite,nullable) NSString *failureReason;
@property(nonatomic) double lastTime;
@property(nonatomic) double actionDeadline;
@property(nonatomic) double revokerDeadline;
@property(nonatomic) NSUInteger sequence;
@property(nonatomic) BOOL ownershipConfirmed;
@property(nonatomic) NSArray<NSString *> *expectedKernelDigests;
@property(nonatomic) NSString *mutationFence;
@end
@implementation RBXPFTransactionModel
- (instancetype)initWithPlan:(RBXPFPolicyPlan *)plan afterInterruption:(BOOL)interrupted now:(double)now error:(NSError **)error {
    if(![plan isKindOfClass:RBXPFPolicyPlan.class]||plan.closedDigest.length!=64||plan.proxyDigest.length!=64||
       !isfinite(now)||now<0||now>1e12) { RBXPFFail(error,@"A valid plan and finite monotonic time are required."); return nil; }
    if((self=[super init])) {
        _plan=plan; _lastTime=now; _recovering=interrupted; _expectedKernelDigests=@[@"empty-and-disabled"]; _mutationFence=@"";
        [self issue:@"verify-recovery-path" now:now];
    }
    return self;
}
- (BOOL)applicationAdmissionAllowed { return NO; }
- (void)issue:(NSString *)action now:(double)now {
    if(++self.sequence>64) { self.phase=@"operator-recovery-required"; self.requestedAction=nil; self.closedConfirmedInModel=NO; return; }
    NSString *digest=([action isEqual:@"install-proxy"]||[action isEqual:@"verify-proxy"])?self.plan.proxyDigest:self.plan.closedDigest;
    NSMutableDictionary *request=[@{@"action":action,@"sequence":@(self.sequence),@"challenge":NSUUID.UUID.UUIDString,
        @"bootEpoch":self.plan.binding[@"bootEpoch"],@"generation":self.plan.binding[@"generation"],
        @"containerId":self.plan.binding[@"containerId"],@"policyDigest":digest,
        @"expectedPriorPolicies":self.expectedKernelDigests,@"mutationFence":self.mutationFence,@"modelOnly":@YES} mutableCopy];
    if([action isEqual:@"fence-mutations"]) {
        request[@"nextMutationFence"]=NSUUID.UUID.UUIDString;
        request[@"fencedThroughSequence"]=@(self.sequence-1);
    }
    self.requestedAction=RBXPFFreeze(request);
    if([action isEqual:@"install-proxy"]) {
        // The kernel write can commit before its asynchronous callback arrives.
        // Closure may then CAS either exact owned digest, never a foreign policy.
        self.closedConfirmedInModel=NO;
        self.expectedKernelDigests=@[self.plan.closedDigest,self.plan.proxyDigest];
    }
    self.phase=[@"pending-" stringByAppendingString:action]; self.actionDeadline=now+5.0;
}
- (void)fail:(NSString *)reason now:(double)now {
    BOOL alreadyRecovering=self.recovering;
    self.recovering=YES; self.closedConfirmedInModel=NO; self.proxyPolicyConfirmedInModel=NO; self.revokerDeadline=0;
    if(!self.failureReason)self.failureReason=reason;
    if(!self.ownershipConfirmed||alreadyRecovering) [self issue:@"emergency-stop-apps" now:now];
    else [self issue:@"fence-mutations" now:now];
}
- (BOOL)advanceClock:(double)now {
    if(!isfinite(now)||now<self.lastTime||now<0||now>1e12) { [self fail:@"Invalid or reversed monotonic clock." now:self.lastTime]; return NO; }
    self.lastTime=now;
    if(self.revokerDeadline>0&&now>=self.revokerDeadline) { [self fail:@"Independent revoker lease expired; closure must be re-established." now:now]; return NO; }
    if(self.requestedAction&&now>=self.actionDeadline) { [self fail:@"Adapter acknowledgement deadline expired." now:now]; return NO; }
    return YES;
}
- (void)tick:(double)now { [self advanceClock:now]; }
- (void)interruptAt:(double)now {
    if(![self advanceClock:now])return;
    [self fail:@"Operation interrupted; do not restore an OPEN status." now:now];
}
- (BOOL)acknowledge:(NSDictionary *)ack now:(double)now error:(NSError **)error {
    if(![self advanceClock:now])return RBXPFFail(error,@"Time or lease no longer permits this acknowledgement.");
    NSDictionary *request=self.requestedAction;
    if(!request||![ack isKindOfClass:NSDictionary.class])return RBXPFFail(error,@"No pending adapter request.");
    if(!RBXPFNumber(ack[@"sequence"],1,64))return RBXPFFail(error,@"Invalid acknowledgement sequence.");
    for(NSString *key in @[@"action",@"sequence",@"challenge",@"bootEpoch",@"generation",@"containerId",@"mutationFence"])
        if(![ack[key] isEqual:request[key]])return RBXPFFail(error,@"Stale or differently bound acknowledgement.");
    NSString *action=request[@"action"];
    if(!RBXPFBoolean(ack[@"success"],YES)) { [self fail:@"Adapter operation failed." now:now]; return RBXPFFail(error,@"Adapter operation failed."); }
    BOOL valid=YES;
    if([action isEqual:@"verify-recovery-path"])valid=RBXPFBoolean(ack[@"externalRecoveryAvailable"],YES);
    else if([action isEqual:@"inspect-baseline"])valid=[ack[@"baseline"] isEqual:@"empty-and-disabled"];
    else if([action isEqual:@"inspect-owned-policy"])valid=[ack[@"policyDigest"] isEqual:self.plan.closedDigest]||[ack[@"policyDigest"] isEqual:self.plan.proxyDigest];
    else if([action isEqual:@"fence-mutations"])
        valid=RBXPFBoolean(ack[@"mutationsDrained"],YES)&&RBXPFBoolean(ack[@"commitFenceEnforced"],YES)&&
            [ack[@"nextMutationFence"] isEqual:request[@"nextMutationFence"]]&&
            RBXPFNumber(ack[@"fencedThroughSequence"],0,64)&&[ack[@"fencedThroughSequence"] isEqual:request[@"fencedThroughSequence"]];
    else if([action isEqual:@"install-closed"]||[action isEqual:@"install-proxy"])
        valid=RBXPFBoolean(ack[@"atomicCompareAndSwap"],YES)&&[ack[@"expectedPriorPolicies"] isEqual:request[@"expectedPriorPolicies"]];
    else if([action isEqual:@"verify-closed"]||[action isEqual:@"verify-proxy"])
        valid=[ack[@"policyDigest"] isEqual:request[@"policyDigest"]]&&RBXPFBoolean(ack[@"pfEnabled"],YES)&&RBXPFBoolean(ack[@"orderingVerified"],YES);
    else if([action isEqual:@"purge-states"])
        valid=RBXPFNumber(ack[@"remainingStates"],0,0)&&[ack[@"policyDigest"] isEqual:self.plan.closedDigest];
    else if([action isEqual:@"stop-apps"])
        valid=RBXPFNumber(ack[@"remainingProcesses"],0,0)&&RBXPFNumber(ack[@"remainingStates"],0,0)&&
            [ack[@"policyDigest"] isEqual:self.plan.closedDigest]&&RBXPFBoolean(ack[@"pfEnabled"],YES)&&RBXPFBoolean(ack[@"orderingVerified"],YES);
    else if([action isEqual:@"emergency-stop-apps"])
        valid=RBXPFNumber(ack[@"remainingProcesses"],0,0);
    else if([action isEqual:@"arm-independent-revoker"]) {
        id expiry=ack[@"expiresAt"];
        valid=RBXPFBoolean(ack[@"independentProcess"],YES)&&RBXPFBoolean(ack[@"survivesDaemonDeath"],YES)&&
            RBXPFBoolean(ack[@"statePurgeOnExpiry"],YES)&&[ack[@"policyDigest"] isEqual:self.plan.closedDigest]&&
            [expiry isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)expiry)!=CFBooleanGetTypeID()&&
            isfinite([expiry doubleValue])&&[expiry doubleValue]>now&&[expiry doubleValue]<=now+2.5;
    } else valid=NO;
    if(!valid) {
        if([action hasPrefix:@"verify-"]||[action hasPrefix:@"inspect-"]||[action hasPrefix:@"install-"])self.ownershipConfirmed=NO;
        [self fail:@"Adapter evidence did not satisfy the current operation." now:now];
        return RBXPFFail(error,@"Required adapter evidence is missing or mismatched.");
    }
    if([action isEqual:@"verify-recovery-path"])[self issue:self.recovering?@"inspect-owned-policy":@"inspect-baseline" now:now];
    else if([action isEqual:@"inspect-baseline"])[self issue:@"fence-mutations" now:now];
    else if([action isEqual:@"inspect-owned-policy"]) {
        self.ownershipConfirmed=YES; self.expectedKernelDigests=@[[ack[@"policyDigest"] copy]]; [self issue:@"fence-mutations" now:now];
    } else if([action isEqual:@"fence-mutations"]) {
        self.mutationFence=[request[@"nextMutationFence"] copy]; [self issue:@"install-closed" now:now];
    } else if([action isEqual:@"install-closed"]) {
        self.closedConfirmedInModel=NO; self.proxyPolicyConfirmedInModel=NO; self.ownershipConfirmed=YES;
        self.expectedKernelDigests=@[self.plan.closedDigest]; [self issue:@"verify-closed" now:now];
    } else if([action isEqual:@"verify-closed"])[self issue:@"purge-states" now:now];
    else if([action isEqual:@"purge-states"])[self issue:@"stop-apps" now:now];
    else if([action isEqual:@"stop-apps"]) {
        self.closedConfirmedInModel=YES;
        if(self.recovering) { self.phase=@"recovered-closed-model"; self.requestedAction=nil; }
        else [self issue:@"arm-independent-revoker" now:now];
    } else if([action isEqual:@"arm-independent-revoker"]) {
        self.revokerDeadline=[ack[@"expiresAt"] doubleValue]; [self issue:@"install-proxy" now:now];
    } else if([action isEqual:@"install-proxy"]) {
        self.closedConfirmedInModel=NO; self.expectedKernelDigests=@[self.plan.proxyDigest]; [self issue:@"verify-proxy" now:now];
    } else if([action isEqual:@"verify-proxy"]) {
        self.proxyPolicyConfirmedInModel=YES; self.phase=@"proxy-policy-model-only"; self.requestedAction=nil;
    } else if([action isEqual:@"emergency-stop-apps"]) {
        self.closedConfirmedInModel=NO; self.phase=@"operator-recovery-required"; self.requestedAction=nil;
    }
    return YES;
}
- (NSDictionary *)journalSummary {
    return @{@"schema":@1,@"binding":self.plan.binding,@"phase":self.phase,@"sequence":@(self.sequence),
        @"recovering":@(self.recovering),@"closedConfirmedInModel":@(self.closedConfirmedInModel),
        @"proxyPolicyConfirmedInModel":@(self.proxyPolicyConfirmedInModel),@"applicationAdmissionAllowed":@NO,
        @"restorableAsVerifiedState":@NO,@"failureReason":self.failureReason?:@""};
}
@end
