#import "RBXPFPolicyPlan.h"
#import <math.h>
static NSUInteger checks;
#define CHECK(x) do { if(!(x)){ fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); exit(1); } checks++; } while(0)
static NSMutableDictionary *request(void) {
    return [@{@"bootEpoch":@"11111111-1111-4111-8111-111111111111", @"generation":@"22222222-2222-4222-8222-222222222222", @"containerId":@"test.reddit.1", @"scope":@"device-wide-proxy-only", @"transport":@"http", @"proxyIPs":@[@"144.202.23.155",@"93.184.216.34"], @"proxyPort":@30232, @"recoveryMode":@"out-of-band"} mutableCopy];
}
static NSMutableDictionary *ack(RBXPFTransactionModel *m) {
    NSMutableDictionary *a=[m.requestedAction mutableCopy];
    [a addEntriesFromDictionary:@{@"success":@YES, @"externalRecoveryAvailable":@YES,
        @"baseline":@"empty-and-disabled", @"atomicCompareAndSwap":@YES,
        @"pfEnabled":@YES, @"orderingVerified":@YES, @"remainingStates":@0,
        @"remainingProcesses":@0, @"independentProcess":@YES,
        @"mutationsDrained":@YES,@"commitFenceEnforced":@YES,
        @"survivesDaemonDeath":@YES, @"statePurgeOnExpiry":@YES,
        @"expiresAt":@102.0}];
    return a;
}
static RBXPFTransactionModel *model(RBXPFPolicyPlan *p) { return [[RBXPFTransactionModel alloc] initWithPlan:p afterInterruption:NO now:100 error:NULL]; }
static BOOL mutationRejected(NSString *value) {
    @try { [(NSMutableString *)value appendString:@"tampered"]; return NO; }
    @catch(NSException *exception) { (void)exception; return YES; }
}
static void advanceAt(RBXPFTransactionModel *m,NSString *action,double now) {
    for(unsigned i=0;i<20;i++) {
        if([m.requestedAction[@"action"] isEqual:action])return;
        CHECK(m.requestedAction!=nil); CHECK([m acknowledge:ack(m) now:now error:NULL]);
    }
    CHECK(NO);
}
static void advanceTo(RBXPFTransactionModel *m,NSString *action) { advanceAt(m,action,100.1); }
int main(void) { @autoreleasepool {
    NSError *error=nil; RBXPFPolicyPlan *p=[RBXPFPolicyPlan planWithRequest:request() error:&error]; CHECK(p!=nil&&!error);
    CHECK(p.closedRules.count==1&&p.proxyRules.count==3);
    CHECK([p.closedRules.lastObject[@"action"] isEqual:@"block"]);
    CHECK([p.closedRules.lastObject[@"family"] isEqual:@"any"]);
    CHECK([p.proxyRules[0][@"destination"] isEqual:@"93.184.216.34/32"]);
    CHECK([p.proxyRules[0][@"protocol"] isEqual:@"tcp"]);
    CHECK([p.proxyRules[0][@"direction"] isEqual:@"out"]);
    CHECK(p.closedDigest.length==64&&p.proxyDigest.length==64&&![p.closedDigest isEqual:p.proxyDigest]);
    CHECK(mutationRejected(p.closedDigest)&&mutationRejected(p.proxyDigest));
    CHECK([p.publicSummary[@"applicationAdmissionAllowed"] isEqual:@NO]);
    CHECK([p.publicSummary[@"enforcementVerified"] isEqual:@NO]);
    CHECK(p.externalObligations.count>=6);
    RBXPFTransactionModel *pending=model(p); advanceTo(pending,@"install-proxy");
    NSDictionary *lateWrite=pending.requestedAction;
    NSMutableDictionary *fence=[lateWrite mutableCopy]; fence[@"fencedThroughSequence"]=@0; fence[@"lastCommittedSequence"]=@0;
    CHECK(RBXPFMutationMatchesFence(lateWrite,fence));
    CHECK(!pending.closedConfirmedInModel); // Write may happen before callback.
    [pending interruptAt:100.2];
    CHECK([pending.requestedAction[@"action"] isEqual:@"fence-mutations"]);
    CHECK([pending.requestedAction[@"expectedPriorPolicies"] containsObject:p.closedDigest]);
    CHECK([pending.requestedAction[@"expectedPriorPolicies"] containsObject:p.proxyDigest]);
    fence=[pending.requestedAction mutableCopy]; fence[@"mutationFence"]=fence[@"nextMutationFence"];
    fence[@"lastCommittedSequence"]=fence[@"fencedThroughSequence"];
    CHECK(!RBXPFMutationMatchesFence(lateWrite,fence));
    CHECK([pending acknowledge:ack(pending) now:100.2 error:NULL]);
    CHECK(RBXPFMutationMatchesFence(pending.requestedAction,fence));
    NSDictionary *currentWrite=pending.requestedAction;
    fence[@"lastCommittedSequence"]=currentWrite[@"sequence"];
    CHECK(!RBXPFMutationMatchesFence(currentWrite,fence));
    advanceAt(pending,@"stop-apps",100.2); CHECK([pending acknowledge:ack(pending) now:100.2 error:NULL]);
    CHECK(pending.closedConfirmedInModel&&!RBXPFMutationMatchesFence(lateWrite,fence));
    NSMutableDictionary *q=request(); q[@"proxyIPs"]=@[@"93.184.216.34",@"144.202.23.155"];
    CHECK([[RBXPFPolicyPlan planWithRequest:q error:NULL].proxyDigest isEqual:p.proxyDigest]);
    q=request(); q[@"generation"]=@"33333333-3333-4333-8333-333333333333";
    CHECK(![[RBXPFPolicyPlan planWithRequest:q error:NULL].proxyDigest isEqual:p.proxyDigest]);
    CHECK(![[RBXPFPolicyPlan planWithRequest:q error:NULL].proxyRules isEqual:p.proxyRules]);
    CHECK(![[RBXPFPolicyPlan planWithRequest:q error:NULL].closedRules isEqual:p.closedRules]);
    NSMutableArray *ips=[request()[@"proxyIPs"] mutableCopy]; q=request(); q[@"proxyIPs"]=ips;
    RBXPFPolicyPlan *immutable=[RBXPFPolicyPlan planWithRequest:q error:NULL]; NSString *oldDigest=immutable.proxyDigest;
    [ips removeAllObjects]; q[@"containerId"]=@"changed"; CHECK([immutable.proxyDigest isEqual:oldDigest]); CHECK([immutable.binding[@"containerId"] isEqual:@"test.reddit.1"]);
    NSArray *bad=@[@{@"scope":@"per-app"},@{@"transport":@"socks5"},@{@"transport":@"https"},
      @{@"proxyIPs":@[@"proxy.example.com"]},@{@"proxyIPs":@[@"http://1.2.3.4:80"]},@{@"proxyIPs":@[@"127.0.0.1"]},
      @{@"proxyIPs":@[@"10.1.2.3"]},@{@"proxyIPs":@[@"172.16.0.1"]},@{@"proxyIPs":@[@"192.168.1.1"]},
      @{@"proxyIPs":@[@"100.64.0.1"]},@{@"proxyIPs":@[@"169.254.1.1"]},@{@"proxyIPs":@[@"0.0.0.0"]},
      @{@"proxyIPs":@[@"224.0.0.1"]},@{@"proxyIPs":@[@"255.255.255.255"]},@{@"proxyIPs":@[@"1.2.3.4/24"]},
      @{@"proxyIPs":@[@"::ffff:1.2.3.4"]},@{@"proxyIPs":@[@"2001:4860::1"]},@{@"proxyIPs":@[]},
      @{@"proxyIPs":@[@"1.2.3.4",@"1.2.3.4"]},@{@"proxyPort":@0},@{@"proxyPort":@65536},@{@"proxyPort":@1.5},
      @{@"proxyPort":@YES},@{@"proxyPort":@"80"},@{@"generation":@""},@{@"bootEpoch":@"not-uuid"},
      @{@"containerId":@"../profile"},@{@"proxyPassword":@"never-copy-me"},@{@"dnsExceptions":@[@"1.1.1.1"]},
      @{@"rootUIDBypass":@YES},@{@"recoveryMode":@"usb-linklocal-ssh"},@{@"cloudExceptions":@[@"example.com"]}];
    for(NSDictionary *change in bad) { q=request(); [q addEntriesFromDictionary:change]; error=nil; CHECK([RBXPFPolicyPlan planWithRequest:q error:&error]==nil); CHECK(error!=nil); CHECK(![error.localizedDescription containsString:@"never-copy-me"]); }
    q=request(); NSMutableArray *many=[NSMutableArray array]; for(int i=1;i<=17;i++)[many addObject:[NSString stringWithFormat:@"8.8.8.%d",i]]; q[@"proxyIPs"]=many; CHECK(![RBXPFPolicyPlan planWithRequest:q error:NULL]);
    RBXPFTransactionModel *m=model(p); CHECK(m!=nil&&!m.closedConfirmedInModel&&!m.proxyPolicyConfirmedInModel&&!m.applicationAdmissionAllowed);
    NSMutableDictionary *stale=ack(m); stale[@"challenge"]=@"old"; CHECK(![m acknowledge:stale now:100 error:NULL]); CHECK([m.requestedAction[@"action"] isEqual:@"verify-recovery-path"]);
    stale=ack(m); stale[@"generation"]=@"other"; CHECK(![m acknowledge:stale now:100 error:NULL]);
    NSMutableDictionary *first=ack(m); CHECK([m acknowledge:first now:100.1 error:NULL]); CHECK(![m acknowledge:first now:100.1 error:NULL]);
    advanceTo(m,@"purge-states"); CHECK(!m.closedConfirmedInModel);
    CHECK([m acknowledge:ack(m) now:100.1 error:NULL]); CHECK(!m.closedConfirmedInModel);
    CHECK([m acknowledge:ack(m) now:100.1 error:NULL]); CHECK(m.closedConfirmedInModel);
    advanceTo(m,@"verify-proxy"); CHECK(!m.applicationAdmissionAllowed&&!m.proxyPolicyConfirmedInModel);
    CHECK([m acknowledge:ack(m) now:100.2 error:NULL]); CHECK(m.proxyPolicyConfirmedInModel&&!m.closedConfirmedInModel&&!m.applicationAdmissionAllowed);
    CHECK(m.requestedAction==nil); [m tick:102.0]; CHECK(m.recovering&&!m.proxyPolicyConfirmedInModel); CHECK([m.requestedAction[@"action"] isEqual:@"fence-mutations"]);
    advanceAt(m,@"stop-apps",102.0); CHECK([m acknowledge:ack(m) now:102.0 error:NULL]); CHECK(m.closedConfirmedInModel&&m.recovering&&m.requestedAction==nil); CHECK(!m.applicationAdmissionAllowed);
    NSArray *failActions=@[@"verify-recovery-path",@"inspect-baseline",@"fence-mutations",@"install-closed",@"verify-closed",@"purge-states",@"stop-apps",@"arm-independent-revoker",@"install-proxy",@"verify-proxy"];
    for(NSString *action in failActions) {
        m=model(p); advanceTo(m,action); NSMutableDictionary *a=ack(m); a[@"success"]=@NO;
        CHECK(![m acknowledge:a now:100.2 error:NULL]); CHECK(m.recovering&&!m.applicationAdmissionAllowed&&!m.proxyPolicyConfirmedInModel&&!m.closedConfirmedInModel);
        CHECK(m.failureReason.length>0);
    }
    NSArray *badFacts=@[@[@"verify-recovery-path",@"externalRecoveryAvailable",@NO],
      @[@"inspect-baseline",@"baseline",@"nonempty"],@[@"install-closed",@"atomicCompareAndSwap",@NO],
      @[@"fence-mutations",@"mutationsDrained",@NO],@[@"fence-mutations",@"commitFenceEnforced",@NO],
      @[@"fence-mutations",@"fencedThroughSequence",@0],
      @[@"verify-closed",@"policyDigest",@"wrong"],@[@"verify-closed",@"pfEnabled",@NO],
      @[@"verify-closed",@"orderingVerified",@NO],@[@"purge-states",@"remainingStates",@1],
      @[@"stop-apps",@"remainingProcesses",@1],@[@"arm-independent-revoker",@"independentProcess",@NO],
      @[@"stop-apps",@"remainingStates",@1],@[@"stop-apps",@"policyDigest",@"foreign-policy"],
      @[@"install-proxy",@"expectedPriorPolicies",@[@"foreign-policy"]],
      @[@"arm-independent-revoker",@"survivesDaemonDeath",@NO],@[@"arm-independent-revoker",@"statePurgeOnExpiry",@NO],
      @[@"arm-independent-revoker",@"expiresAt",@(INFINITY)],@[@"arm-independent-revoker",@"expiresAt",@100],
      @[@"arm-independent-revoker",@"expiresAt",@200],@[@"verify-proxy",@"policyDigest",p.closedDigest]];
    for(NSArray *fact in badFacts) { m=model(p); advanceTo(m,fact[0]); NSMutableDictionary *a=ack(m); a[fact[1]]=fact[2]; CHECK(![m acknowledge:a now:100.2 error:NULL]); CHECK(m.recovering&&!m.applicationAdmissionAllowed); }
    for(NSNumber *invalid in @[@(NAN),@(INFINITY),@(-INFINITY),@(-1)])CHECK(![[RBXPFTransactionModel alloc] initWithPlan:p afterInterruption:NO now:invalid.doubleValue error:NULL]);
    CHECK(![[RBXPFTransactionModel alloc] initWithPlan:[RBXPFPolicyPlan new] afterInterruption:NO now:100 error:NULL]);
    m=model(p); NSMutableDictionary *booleanSequence=ack(m); booleanSequence[@"sequence"]=@YES; CHECK(![m acknowledge:booleanSequence now:100 error:NULL]);
    m=model(p); [m tick:NAN]; CHECK(m.recovering&&!m.closedConfirmedInModel&&!m.applicationAdmissionAllowed);
    m=model(p); [m tick:99]; CHECK(m.recovering&&!m.closedConfirmedInModel);
    m=model(p); [m tick:105]; CHECK(m.recovering&&!m.closedConfirmedInModel);
    m=model(p); advanceTo(m,@"install-proxy"); [m interruptAt:100.3]; CHECK(m.recovering&&!m.proxyPolicyConfirmedInModel&&[m.requestedAction[@"action"] isEqual:@"fence-mutations"]);
    NSMutableDictionary *failed=ack(m); failed[@"success"]=@NO; CHECK(![m acknowledge:failed now:100.3 error:NULL]); CHECK([m.requestedAction[@"action"] isEqual:@"emergency-stop-apps"]); CHECK([m acknowledge:ack(m) now:100.3 error:NULL]); CHECK([m.phase isEqual:@"operator-recovery-required"]&&!m.closedConfirmedInModel);
    m=[[RBXPFTransactionModel alloc] initWithPlan:p afterInterruption:YES now:100 error:NULL]; CHECK(m.recovering&&!m.closedConfirmedInModel&&!m.proxyPolicyConfirmedInModel); CHECK([m.requestedAction[@"action"] isEqual:@"verify-recovery-path"]);
    CHECK([m acknowledge:ack(m) now:100.1 error:NULL]); CHECK([m.requestedAction[@"action"] isEqual:@"inspect-owned-policy"]);
    NSMutableDictionary *owned=ack(m); owned[@"policyDigest"]=p.proxyDigest; CHECK([m acknowledge:owned now:100.1 error:NULL]); CHECK([m.requestedAction[@"action"] isEqual:@"fence-mutations"]);
    CHECK([m.journalSummary[@"applicationAdmissionAllowed"] isEqual:@NO]); CHECK([m.journalSummary[@"restorableAsVerifiedState"] isEqual:@NO]);
    printf("PASS: %lu offline PF policy/transaction checks; no kernel writes or readiness claims\n",(unsigned long)checks);
} return 0; }
