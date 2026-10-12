#import <Foundation/Foundation.h>
#import "RBXAcceptanceChecks.h"
static NSDictionary *find(NSArray *checks, NSString *key) {
    for (NSDictionary *check in checks) if ([check[@"id"] isEqual:key]) return check;
    abort();
}
static void expect(NSArray *checks, NSString *key, NSString *status) {
    if (![find(checks,key)[@"status"] isEqual:status]) { NSLog(@"FAIL %@ expected %@",key,status); abort(); }
}
int main(void) { @autoreleasepool {
    NSArray *empty = RBXAcceptanceChecks(@{},1000);
    for (NSDictionary *check in empty) NSCAssert([check[@"status"] isEqual:@"NOT_RUN"],@"missing evidence cannot pass");
    NSMutableDictionary *state = [@{@"updatedAt":@999, @"networkState":@"open", @"license":@{@"unlocked":@YES,@"expiresAt":@2000},
        @"source":@{@"decrypted":@YES}, @"configuration":@{@"configured":@YES,@"readable":@YES},
        @"diagnostics":@{@"generatedAt":@990,@"checks":@[@{@"id":@"hooks",@"status":@"pass",@"detail":@"SECRET-do-not-publish"},
            @{@"id":@"lease",@"status":@"fail"}, @{@"id":@"heartbeat",@"status":@"info"}]}} mutableCopy];
    NSArray *checks = RBXAcceptanceChecks(state,1000);
    expect(checks,@"publication",@"PASS"); expect(checks,@"license",@"PASS"); expect(checks,@"reported-hooks",@"PASS");
    expect(checks,@"reported-lease",@"FAIL"); expect(checks,@"reported-heartbeat",@"NOT_RUN");
    expect(checks,@"keychain-canary",@"NOT_RUN"); expect(checks,@"packet-routing",@"NOT_RUN");
    // ACCEPT-001/UI-001: readiness must not outlive the actual launcher license gate.
    state[@"license"]=@{@"unlocked":@YES,@"expiresAt":@999};
    expect(RBXAcceptanceChecks(state,1000),@"license",@"FAIL");
    state[@"license"]=@{@"unlocked":@YES};
    expect(RBXAcceptanceChecks(state,1000),@"license",@"FAIL");
    state[@"license"]=@{@"unlocked":@YES,@"expiresAt":@1000};
    expect(RBXAcceptanceChecks(state,1000),@"license",@"FAIL");
    state[@"license"]=@{@"unlocked":@YES,@"expiresAt":@YES};
    expect(RBXAcceptanceChecks(state,1000),@"license",@"FAIL");
    state[@"license"]=@{@"unlocked":@YES,@"expiresAt":@2000};
    expect(RBXAcceptanceChecks(state,1000),@"license",@"PASS");
    NSCAssert(![checks.description containsString:@"SECRET"],@"no unfiltered details");
    expect(RBXAcceptanceChecks(state,1200),@"reported-hooks",@"NOT_RUN");
    expect(RBXAcceptanceChecks(state,900),@"publication",@"NOT_RUN");
    expect(RBXAcceptanceChecks(state,NAN),@"publication",@"NOT_RUN");
    state[@"diagnostics"]=@{@"generatedAt":@999,@"checks":@[@1,@{@"id":@"hooks",@"status":@"unexpected"}]};
    expect(RBXAcceptanceChecks(state,1000),@"reported-hooks",@"NOT_RUN");
    state[@"license"]=@[]; expect(RBXAcceptanceChecks(state,1000),@"license",@"NOT_RUN");
    NSMutableSet *ids=[NSMutableSet set];
    for (NSDictionary *check in checks) { NSCAssert(![ids containsObject:check[@"id"]],@"duplicate check"); [ids addObject:check[@"id"]];
        NSCAssert([check[@"rows"] count]>0 && [check[@"detail"] length]>0,@"evidence mapping required"); }
    puts("PASS: shared acceptance evaluator fresh/stale/malformed/privacy/manual fixtures");
} }
