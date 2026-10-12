#import <Foundation/Foundation.h>
#import "RBXAppScope.h"
#import "RBXAppSetupStatus.h"

int main(void) {
    @autoreleasepool {
        NSDictionary *reddit = RBXRedditAppDescriptor();
        NSDictionary *facebook = RBXAppDescriptorForType(@"facebook");
        NSCAssert(RBXAppScopeMaySelect(@"reddit", YES, NO), @"unlocked Reddit workspace is reachable");
        NSCAssert(RBXAppScopeMaySelect(@"facebook", YES, NO), @"inactive app placeholder is reachable");
        for (NSString *app in @[@"reddit", @"facebook"]) {
            NSCAssert(!RBXAppScopeMaySelect(app, NO, NO), @"app selector cannot bypass passcode");
            NSCAssert(!RBXAppScopeMaySelect(app, YES, YES), @"picker / sheet must finish before app switch");
        }
        NSCAssert(!RBXAppScopeMaySelect(@"instagram", YES, NO), @"unregistered app is not reachable");
        NSCAssert(!RBXAppScopeMaySelect(nil, YES, NO), @"invalid selector input does not silently choose Reddit");
        NSCAssert(!RBXAppScopeMaySelect(NSNull.null, YES, NO), @"wrong type is denied");
        NSCAssert([RBXAppSourceImportRequestKey(reddit) isEqual:@"RBXSourceImportRequestId"], @"retain legacy receipt key");
        NSCAssert([RBXAppSourceImportRequestKey(facebook) isEqual:@"RBXSourceImportRequestId.facebook"], @"separate source receipt key");
        NSCAssert(!RBXAppSourceImportRequestKey(@{}), @"fabricated descriptor cannot choose receipt namespace");

        NSCAssert([RBXAppScopedPreferenceKey(@"simple-wizard", reddit) isEqual:@"simple-wizard"], @"legacy owner unchanged");
        NSCAssert([RBXAppScopedPreferenceKey(@"simple-wizard", facebook) isEqual:@"simple-wizard.facebook"], @"FB create receipts never consume Reddit receipts");
        NSCAssert([RBXAppScopedPreferenceKey(@"RBXSimpleWizardDraft", facebook) isEqual:@"RBXSimpleWizardDraft.facebook"], @"wizard drafts survive independently");
        NSCAssert(!RBXAppScopedPreferenceKey(@"draft", @{}), @"invalid namespace rejected");
        NSCAssert(([RBXAppScopedRequestValues(@{@"container":@"test"}, facebook) isEqual:@{@"container":@"test", @"appType":@"facebook"}]), @"FB request type cannot be omitted");
        NSCAssert(!RBXAppScopedRequestValues(@{@"appType":@"reddit"}, facebook), @"cross-app request rejected before queueing");
        NSCAssert(!RBXAppScopedRequestValues(@{@"appType":NSNull.null}, facebook), @"malformed request type rejected");
        NSCAssert(!RBXAppScopedRequestValues(@{}, @{}), @"unregistered app rejected before queueing");
        NSCAssert(!RBXAppScopedRequestValues((id)NSNull.null, reddit), @"invalid values rejected");
        NSCAssert([RBXAppSourceReadinessError(@{}, reddit) containsString:@"Reddit source not imported"], @"missing source fails closed clearly");
        NSCAssert(!RBXAppSourceReadinessError(@{@"source":@{@"decrypted":@YES}}, reddit), @"valid source keeps legacy create available");
        NSCAssert(RBXAppSourceReadinessError(@{@"source":@{@"decrypted":@NO}}, facebook) != nil, @"Facebook encrypted/missing source never allows create");

        NSDictionary *importedFB = @{@"sources":@{@"facebook":@{@"decrypted":@YES,@"version":@"578.1.0"}}, @"source":@{@"decrypted":@YES}};
        NSDictionary *status = RBXAppSetupStatus(importedFB, facebook);
        NSCAssert([status[@"sourceReady"] boolValue], @"FB imported source is visible even while execution is inactive");
        NSCAssert([status[@"sourceTitle"] containsString:@"578.1.0"], @"show actual imported version");
        NSCAssert([status[@"sourceAction"] isEqual:@"Source details"], @"do not ask to reimport a ready source");
        NSCAssert([status[@"importAction"] isEqual:@"Replace Facebook IPA from Files"], @"replacement is explicit");
        NSCAssert(![status[@"executionEnabled"] boolValue], @"import success never grants execution");
        NSCAssert(![status[@"networkReady"] boolValue], @"missing network evidence is not green");
        NSCAssert(![RBXAppSetupStatus(@{@"source":@{@"decrypted":@YES}},facebook)[@"sourceReady"] boolValue], @"no Reddit source fallback");
        for (id value in @[NSNull.null,@"yes",@NO]) {
            NSDictionary *bad=@{@"sources":@{@"facebook":@{@"decrypted":value}}};
            NSCAssert(![RBXAppSetupStatus(bad,facebook)[@"sourceReady"] boolValue], @"malformed source stays unverified");
        }
        NSCAssert(![RBXAppSetupStatus(NSNull.null,facebook)[@"sourceReady"] boolValue], @"invalid publication cannot claim import");
        NSCAssert([RBXAppSetupStatus(importedFB,@{})[@"sourceReady"] isEqual:@NO], @"unregistered descriptor remains unverified");
        NSDictionary *vpn=@{@"updatedAt":@(NSDate.date.timeIntervalSince1970),@"firewallSetup":@{@"ready":@YES},@"firewallScope":@"per-app"};
        NSCAssert([RBXAppSetupStatus(vpn,facebook)[@"networkReady"] boolValue], @"reflect device-reported per-app setup only");
        NSCAssert(![RBXAppSetupStatus(vpn,facebook)[@"executionEnabled"] boolValue], @"VPN setup does not admit inactive Facebook");
        NSCAssert(![RBXAppSetupStatus(@{@"firewallSetup":@{@"ready":@YES}},facebook)[@"networkReady"] boolValue], @"missing per-app scope is not proof");

        NSDictionary *legacyRow = @{@"id":@"legacy", @"name":@"Original", @"deletionState":@{@"pending":@YES}};
        NSDictionary *redditRow = @{@"id":@"rd", @"appType":@"reddit"};
        NSDictionary *facebookRow = @{@"id":@"fb", @"appType":@"facebook"};
        NSDictionary *legacy = @{@"containers":@[legacyRow], @"source":@{@"decrypted":@YES},
            @"sourceImport":@{@"message":@"old receipt"}, @"operation":@{@"containerId":@"legacy"},
            @"license":@{@"valid":@YES}, @"networkState":@"closed",
            @"operationRecovery":@{@"required":@YES}, @"diagnostics":@{@"failureCount":@1}};
        NSDictionary *unchanged = RBXAppScopedLauncherState(legacy, reddit);
        NSCAssert([unchanged isEqual:legacy], @"legacy Reddit state remains exactly equivalent");
        NSCAssert(unchanged[@"containers"][0] == legacyRow, @"retain complete recovery row object");
        NSMutableDictionary *mixed = [legacy mutableCopy];
        mixed[@"containers"] = @[legacyRow, redditRow, facebookRow, @{@"id":@"unknown", @"appType":@"unknown"}];
        mixed[@"operation"] = @{@"containerId":@"fb", @"message":@"FB operation"};
        mixed[@"identityResult"] = @{@"appType":@"facebook", @"message":@"FB result"};
        mixed[@"cloneExport"] = @{@"container":@"fb", @"path":@"foreign.ipa"};
        mixed[@"sources"] = @{@"facebook":@{@"decrypted":@NO}};
        mixed[@"sourceImports"] = @{@"facebook":@{@"message":@"FB receipt"}};
        NSDictionary *rdState = RBXAppScopedLauncherState(mixed, reddit);
        NSCAssert(([rdState[@"containers"] isEqual:@[legacyRow, redditRow]]), @"Reddit inventory includes only its own rows");
        for (NSString *key in @[@"operation", @"identityResult", @"cloneExport"])
            NSCAssert([rdState[key] count] == 0, @"foreign operation result cannot feed Reddit controls");
        for (NSString *key in @[@"license", @"networkState", @"operationRecovery", @"diagnostics"])
            NSCAssert([rdState[key] isEqual:legacy[key]], @"preserve global protection state and recovery fence");
        NSDictionary *fbState = RBXAppScopedLauncherState(mixed, facebook);
        NSCAssert([fbState[@"containers"] isEqual:@[facebookRow]], @"FB inventory excludes untyped Reddit rows");
        NSCAssert([fbState[@"source"] isEqual:@{@"decrypted":@NO}], @"FB never displays Reddit source status");
        NSCAssert([fbState[@"sourceImport"] isEqual:@{@"message":@"FB receipt"}], @"FB receipt is independently scoped");
        NSDictionary *unattributed = RBXAppScopedLauncherState(@{@"operation":@{@"message":@"Reddit operation"}, @"cloneExport":@{@"path":@"reddit.ipa"}}, facebook);
        NSCAssert([unattributed[@"operation"] count] == 0 && [unattributed[@"cloneExport"] count] == 0, @"FB hides untyped singleton output without an owned container");
        NSDictionary *scopedReport = @{@"checks":@[@{@"id":@"fb-check"}]};
        NSDictionary *diagnosed = RBXAppScopedLauncherState(@{@"diagnostics":@{@"failureCount":@3}, @"diagnosticsByApp":@{@"facebook":scopedReport}}, facebook);
        NSCAssert([diagnosed[@"diagnostics"] isEqual:scopedReport], @"explicit app report is preferred without changing global protection state");
        NSDictionary *fbMissing = RBXAppScopedLauncherState(legacy, facebook);
        NSCAssert([fbMissing[@"source"] count] == 0 && [fbMissing[@"sourceImport"] count] == 0,
            @"absent FB source cannot inherit a successful Reddit import");
        NSCAssert([RBXAppScopedLauncherState(mixed, @{}) count] == 0, @"unregistered descriptor cannot read workspace");
        NSCAssert([RBXAppScopedLauncherState(NSNull.null, reddit) count] == 0, @"invalid publication has no scoped state");
        puts("app scope native tests passed");
    }
    return 0;
}
