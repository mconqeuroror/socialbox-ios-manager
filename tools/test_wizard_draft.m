#import "../launcher/RBXWizardDraft.h"
static void Check(BOOL ok, NSString *message) {
    if (!ok) { fprintf(stderr, "FAIL UI-002: %s\n", message.UTF8String); exit(1); }
}
int main(void) { @autoreleasepool {
    NSDictionary *draft = @{@"container": @"p-fixture", @"requestId": @"request-fixture"};
    NSDictionary *failed = @{@"requestId": @"request-fixture", @"action": @"createContainer",
        @"containerId": @"p-fixture", @"ok": @NO, @"state": @"failed", @"updatedAt": @100};
    NSDictionary *fresh = @{@"containers": @[], @"updatedAt": @102, @"operationRecovery": @{}};
    Check(RBXWizardDraftCanReset(draft, failed, fresh, NO, 105), @"known failed create with newer fresh absence must be resettable");
    Check(!RBXWizardDraftCanReset(draft, failed, fresh, YES, 105), @"uncertain pending work cannot reset");
    Check(!RBXWizardDraftCanReset(draft, nil, fresh, NO, 105), @"missing receipt cannot reset");
    Check(!RBXWizardDraftCanReset(draft, failed, fresh, NO, 115), @"stale absence cannot reset");
    for (NSDictionary *change in @[@{@"requestId":@"other"}, @{@"containerId":@"other"},
        @{@"action":@"deleteContainer"}, @{@"ok":@YES}, @{@"state":@"interrupted"},
        @{@"updatedAt":@106}]) {
        NSMutableDictionary *receipt = failed.mutableCopy; [receipt addEntriesFromDictionary:change];
        Check(!RBXWizardDraftCanReset(draft, receipt, fresh, NO, 105), @"wrong, successful, interrupted or newer terminal record cannot reset");
    }
    for (NSDictionary *change in @[@{@"containers":@[@{@"id":@"p-fixture"}]},
        @{@"containers":@[@{@"id":@"p-fixture",@"profileError":@"read failure"}]},
        @{@"containers":@{}}, @{@"containers":@[@"bad row"]},
        @{@"operationRecovery":@{@"message":@"unfinished"}}, @{@"profileWarning":@"inventory unreadable"},
        @{@"deletionWarning":@"incomplete registry"}, @{@"updatedAt":@99}, @{@"updatedAt":@106}]) {
        NSMutableDictionary *state = fresh.mutableCopy; [state addEntriesFromDictionary:change];
        Check(!RBXWizardDraftCanReset(draft, failed, state, NO, 105), @"partial creation, recovery or corrupt/non-current snapshot cannot reset");
    }
    puts("PASS UI-002: failed draft reset requires exact terminal failure and newer fresh absence; pending and partial creation retained");
} return 0; }
