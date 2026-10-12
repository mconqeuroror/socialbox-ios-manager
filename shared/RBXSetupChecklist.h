#pragma once
#import "RBXLicensePresentation.h"

static inline NSDictionary *RBXSetupDictionary(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
static inline BOOL RBXSetupFresh(id timestamp, NSTimeInterval now, NSTimeInterval limit) {
    return RBXLicensePresentationNumber(timestamp) && [timestamp doubleValue] > 0 &&
        isfinite(now) && now >= [timestamp doubleValue] && now-[timestamp doubleValue] <= limit;
}
static inline NSDictionary *RBXLatestProxyTest(id published, id receipt) {
    NSDictionary *current=RBXSetupDictionary(published), *local=RBXSetupDictionary(receipt);
    // Receipt completion time also covers queue timeout/cancellation, which may
    // have no testedAt field. A newer pending publication invalidates old success.
    double currentTime=RBXLicensePresentationNumber(current[@"testedAt"]) ? [current[@"testedAt"] doubleValue] : 0;
    double receiptTime=RBXLicensePresentationNumber(local[@"updatedAt"]) ? [local[@"updatedAt"] doubleValue] : 0;
    return receiptTime>0 && receiptTime>=currentTime ? local : current;
}
static inline BOOL RBXProxyTestCurrent(NSDictionary *state, NSDictionary *test, NSTimeInterval now) {
    NSDictionary *config=RBXSetupDictionary(state[@"configuration"]);
    return RBXSetupFresh(state[@"updatedAt"],now,10) && [config[@"configured"] isEqual:@YES] &&
        [config[@"readable"] isEqual:@YES] && ![config[@"disabled"] isEqual:@YES] &&
        RBXSetupFresh(test[@"testedAt"],now,300) && RBXLicensePresentationNumber(config[@"updatedAt"]) &&
        [config[@"updatedAt"] doubleValue] > 0 && [test[@"configurationUpdatedAt"] isEqual:config[@"updatedAt"]] &&
        [test[@"testedAt"] doubleValue] >= [config[@"updatedAt"] doubleValue];
}
// Read-only, bounded claims. Configuration alone cannot turn transport or A/B
// acceptance green. Red includes missing, stale and unverified prerequisites.
static inline NSArray<NSDictionary *> *RBXSetupChecklist(NSDictionary *state, NSTimeInterval now) {
    state=RBXSetupDictionary(state);
    BOOL fresh=RBXSetupFresh(state[@"updatedAt"],now,10);
    NSMutableArray *rows=[NSMutableArray array];
    void (^add)(NSString *,NSString *,BOOL,NSString *,NSString *,NSString *) = ^(NSString *identifier,NSString *title,BOOL passed,NSString *yes,NSString *no,NSString *action) {
        [rows addObject:@{@"id":identifier,@"title":title,@"status":fresh && passed ? @"PASS" : @"NOT_RUN",
            @"detail":!fresh ? @"Waiting for current device status. Refresh or open Diagnostics." : (passed ? yes : no),@"action":action}];
    };
    add(@"service",@"Device service",fresh,@"Current daemon status received.",@"Open Diagnostics to inspect the daemon.",@"diagnostics");
    BOOL recovery=[state[@"operationRecovery"] isKindOfClass:NSDictionary.class] && ![state[@"operationRecovery"] count] &&
        [state[@"profileWarning"] isKindOfClass:NSString.class] && ![state[@"profileWarning"] length] &&
        [state[@"deletionWarning"] isKindOfClass:NSString.class] && ![state[@"deletionWarning"] length];
    add(@"recovery",@"Data and recovery",recovery,@"No pending recovery fence or profile inventory warning.",@"Review Diagnostics. Keep existing profiles and recovery records.",@"diagnostics");
    add(@"license",@"License",[RBXLicensePresentationState(state,now)[@"unlocked"] boolValue],@"Signed activation is currently valid.",@"Open Account & license and activate this device.",@"license");
    add(@"source",@"Decrypted Reddit IPA",[RBXSetupDictionary(state[@"source"])[@"decrypted"] isEqual:@YES],@"A validated private source is available for new containers.",@"Import your decrypted Reddit IPA below.",@"source");
    NSDictionary *config=RBXSetupDictionary(state[@"configuration"]);
    add(@"proxy",@"Proxy saved",[config[@"configured"] isEqual:@YES] && [config[@"readable"] isEqual:@YES] && ![config[@"disabled"] isEqual:@YES],@"A proxy is selected. Saving alone does not verify its connection.",@"In Proxies, tap +, save an HTTP proxy and select it.",@"proxies");
    NSDictionary *test=RBXSetupDictionary(state[@"configurationTest"]);
    BOOL tested=RBXProxyTestCurrent(state,test,now) && [test[@"ok"] isEqual:@YES];
    add(@"proxy-test",@"Proxy connection",tested,@"The selected configuration passed its network test within five minutes. Every Open tests again.",@"In Proxies choose Use and test. A changed proxy or an old test must be tested again.",@"proxies");
    add(@"vpn",@"Managed VPN provider",[RBXSetupDictionary(state[@"firewallSetup"])[@"ready"] isEqual:@YES],@"The per-app provider is running. This alone does not prove each clone's routing.",@"Enroll through your MDM service, deploy the setup files, then Open Firewall Setup.",@"firewall");
    NSArray *containers=[state[@"containers"] isKindOfClass:NSArray.class] ? state[@"containers"] : @[];
    BOOL managed=containers.count>0, clear=containers.count>0;
    for (id item in containers) {
        NSDictionary *row=RBXSetupDictionary(item), *installation=RBXSetupDictionary(row[@"managedInstallation"]);
        managed &= [installation[@"verified"] isEqual:@YES] && RBXSetupFresh(installation[@"checkedAt"],now,10);
        clear &= [row[@"launchBlockReason"] isKindOfClass:NSString.class] && ![row[@"launchBlockReason"] length] &&
            ![RBXSetupDictionary(row[@"isolationSentinel"])[@"alert"] isEqual:@YES];
    }
    add(@"mdm-clones",@"MDM installation of containers",managed,@"All listed clones are reported as MDM-managed installations. Verify their exact VPN assignment separately.",containers.count ? @"Export each clone IPA to MDM, install/adopt it and assign the per-app VPN. Recheck after any rebuild." : @"Create an offline container first, then export its IPA for MDM installation and VPN assignment.",@"mdm");
    add(@"alerts",@"Isolation alerts",clear,@"No retained isolation alert. This is not proof that every data surface is isolated.",containers.count ? @"A container is blocked or its safety state is missing. Open Diagnostics; disabling the sentinel does not clear a finding." : @"Available after you create a container.",@"diagnostics");
    add(@"acceptance",@"VPN routing and A/B isolation",NO,@"",@"Not verified automatically. Device acceptance must test actual routing, VPN failure and cross-container access; setup flags alone cannot prove these.",@"diagnostics");
    return rows;
}
