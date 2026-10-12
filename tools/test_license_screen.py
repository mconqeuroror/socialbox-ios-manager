#!/usr/bin/env python3
"""License-screen wiring and executed native activation/privacy regressions.
Actual visible hierarchy and root shielding are covered by the gate UIKit fixture.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "launcher/RBXLicenseViewController.m").read_text(encoding="utf-8")
header = (ROOT / "launcher/RBXLicenseViewController.h").read_text(encoding="utf-8")


def method(name: str) -> str:
    match = re.search(rf"^- \([^\n]+\){re.escape(name)}(?:[: {{]|$)", source, re.M)
    assert match, name
    end = re.search(r"^-(?: |\()", source[match.end():], re.M)
    return source[match.start():match.end() + end.start()] if end else source[match.start():]


assert "initWithLicenseState:" in header and "updateLicenseState:" in header
assert "activationOnly:(BOOL)activationOnly" in header
activation_view = method("buildActivationOnlyView")
assert activation_view.count("[UITextField new]") == 1
assert activation_view.count("buttonWithTitle:") == 1
assert 'buttonWithTitle:@"Activate" action:@selector(activateLicense)' in activation_view
assert 'self.keyField addTarget:self action:@selector(activateLicense)' in activation_view
assert 'forControlEvents:UIControlEventEditingDidEndOnExit' in activation_view
for forbidden in ("serverField", "validateButton", "openDiagnostics", "openSettings", "maintenance", "UISegmentedControl"):
    assert forbidden not in activation_view, forbidden
assert 'if (self.activationOnly)' in method("viewDidLoad")
activate = method("activateLicense")
assert activate.index("canSubmitRequest") < activate.index("saveAccessKey:key")
assert activate.index("saveAccessKey:key") < activate.index('submitAction:@"activateLicense"')
assert 'values:@{@"serverURL": server}' in activate
assert "uppercaseString" in activate and "stringByTrimmingCharactersInSet" in activate
assert "accessKey:&keyError" in activate
assert 'self.keyField.text = @""' in activate
validate = method("validateLicense")
assert 'submitAction:@"validateLicense" values:@{}' in validate
assert "saveAccessKey" not in validate and "clear" not in validate
assert "canSubmitRequest" in validate
assert "RBXLicenseRequestOwner = @\"license\"" in source
submit = method("submitAction")
assert "sendActionReturningRequestId" in submit and "owner:RBXLicenseRequestOwner" in submit
assert "finishObservingRequestId" in method("pollRequestReceipts")
assert "requestResultForId" in method("pollRequestReceipts")
assert "pendingRequestsForOwner" in method("pollRequestReceipts")

# These lifecycle paths may only observe local state or update text. Removing
# that separation would silently turn foregrounding/countdowns into retries.
for observer in ("updateLicenseState", "viewWillAppear", "didBecomeActive", "readLicensePublication",
                 "refreshDetailedLicenseState", "pollRequestReceipts", "renderStatus"):
    body = method(observer)
    for forbidden in ("submitAction:", "sendActionReturningRequestId:", "saveAccessKey:"):
        assert forbidden not in body, (observer, forbidden)
assert "[weakSelf renderStatus]" in method("viewWillAppear")
assert "[weakSelf refreshDetailedLicenseState]" in method("viewWillAppear")
assert "[self refreshDetailedLicenseState]" in method("viewWillAppear")
assert "[self refreshDetailedLicenseState]" in method("didBecomeActive")
assert "refreshDetailedLicenseState" not in method("updateLicenseState")
assert 'if (self.activationOnly) return;' in method("refreshDetailedLicenseState")
assert "RBXLicensePresentationState([self readLicensePublication]" in method("refreshDetailedLicenseState")
assert "dictionaryWithContentsOfFile:" in method("readLicensePublication")
assert 'com.redditbox.launcher-state.plist' in method("readLicensePublication")
assert "retryAt" in method("retryDelay") and "isfinite" in method("retryDelay")
assert "[self retryDelay] <= 0" in method("canSubmitRequest")
assert "!self.hasPendingRequest" in method("canSubmitRequest")
assert "self.activateButton.enabled = canRequest" in method("renderStatus")
assert "self.validateButton.enabled = canRequest" in method("renderStatus")
assert "RBXLicenseScreenDeadline(self.licenseState)" in method("renderStatus")
deadline = source.split("static NSString *RBXLicenseScreenDeadline(")[1].split("static NSString *RBXLicenseScreenServer(")[0]
assert '@"graceUntil"' in deadline and '@"expiresAt"' in deadline
assert "RBXLicensePresentationNumber(value)" in deadline and "[value doubleValue] > 0" in deadline
assert 'setLocalizedDateFormatFromTemplate:@"yMMMdjmmz"' in deadline
assert 'Signed access deadline:' in deadline
assert '@"unlocked"' not in deadline and 'submitAction:' not in deadline

for action in ("openDiagnostics", "openSettings", "showMaintenanceController"):
    body = method(action)
    assert 'if (self.activationOnly) return;' in body
    for gate in ("canSubmitRequest", "retryDelay", "unlocked", "hasPendingRequest"):
        assert gate not in body, (action, gate)
assert "RBXDiagnosticsViewController new" in method("openDiagnostics")
assert "initWithWizardMode:NO" in method("openSettings")
assert "No valid activation token" in source
assert "No request will be retried automatically" in source
assert "self.keyField.secureTextEntry = YES" in source
assert "url.user || url.password || url.query || url.fragment" in source
assert 'isEqualToString:@"https"' in source
assert source.count('https://') == 1 and 'return @"https://redditspoof.vercel.app";' in source
assert 'self.activationOnly ? RBXActivationOnlyServer(self.licenseState)' in activate
assert 'if (self.activationOnly) return;' in validate

for forbidden in ("NSURLSession", "NSURLConnection", "sharedSession", "loadRequest:", "NSUserDefaults",
                  "NSLog", "printf", '@"key":', '@"accessKey":', 'setObject:key',
                  'submitAction:@"launchContainer"', 'submitAction:@"createContainer"',
                  "dismissViewControllerAnimated", "popViewControllerAnimated"):
    assert forbidden not in source, forbidden

def function(signature: str) -> str:
    start = source.index(signature)
    return source[start:source.index('\n}\n', start) + 3]


functions = '\n'.join(function(signature) for signature in (
    'static BOOL RBXLicenseScreenFlag(', 'static NSString *RBXLicenseScreenServer(',
    'static NSString *RBXActivationOnlyServer('))
methods = '\n'.join(method(name) for name in ('retryDelay', 'canSubmitRequest', 'activateLicense', 'validateLicense',
                                             'refreshDetailedLicenseState'))
fixture = r'''
#import <Foundation/Foundation.h>
#import "RBXLicensePresentation.h"
#include <math.h>
__FUNCTIONS__
static NSString *savedKey;
static BOOL readFails,writeFails;
static NSUInteger checks;
static NSMutableArray *events;
@interface FixtureField : NSObject
@property NSString *text;
@end
@implementation FixtureField
@end
@interface FixtureView : NSObject
- (void)endEditing:(BOOL)force;
@end
@implementation FixtureView
- (void)endEditing:(BOOL)force {}
@end
@interface RBXSecureConfig : NSObject
+ (NSString *)accessKey:(NSError **)error;
+ (BOOL)saveAccessKey:(NSString *)key error:(NSError **)error;
@end
@implementation RBXSecureConfig
+ (NSString *)accessKey:(NSError **)error {if(readFails){if(error)*error=[NSError errorWithDomain:@"fixture" code:1 userInfo:nil];return nil;}return savedKey;}
+ (BOOL)saveAccessKey:(NSString *)key error:(NSError **)error {[events addObject:@"secure-write"];if(writeFails)return NO;savedKey=key;return YES;}
@end
@interface FixtureLicense : NSObject
@property BOOL activationOnly,hasPendingRequest;
@property NSDictionary *licenseState,*submittedValues,*publication;
@property NSUInteger publicationReadCount,stateUpdateCount;
@property NSString *submittedAction,*localError;
@property FixtureField *serverField,*keyField;
@property FixtureView *view;
- (void)pollRequestReceipts;
- (void)renderStatus;
- (void)showLocalError:(NSString *)message;
- (void)submitAction:(NSString *)action values:(NSDictionary *)values;
- (NSTimeInterval)retryDelay;
- (BOOL)canSubmitRequest;
- (void)activateLicense;
- (void)validateLicense;
- (NSDictionary *)readLicensePublication;
- (void)updateLicenseState:(NSDictionary *)state;
- (void)refreshDetailedLicenseState;
@end
@implementation FixtureLicense
- (void)pollRequestReceipts {}
- (void)renderStatus {}
- (void)showLocalError:(NSString *)message {self.localError=message;}
- (void)submitAction:(NSString *)action values:(NSDictionary *)values {
    [events addObject:@"queue"];self.submittedAction=action;self.submittedValues=values;
}
- (NSDictionary *)readLicensePublication {self.publicationReadCount++;return self.publication;}
- (void)updateLicenseState:(NSDictionary *)state {self.stateUpdateCount++;self.licenseState=state;}
__METHODS__
@end
static void Check(BOOL ok,NSString *message) {checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}}
static FixtureLicense *Fresh(NSDictionary *state) {
    FixtureLicense *view=[FixtureLicense new];view.activationOnly=YES;view.licenseState=state;
    view.keyField=[FixtureField new];view.keyField.text=@"  test-license-key  ";view.view=[FixtureView new];
    readFails=NO;writeFails=NO;events=[NSMutableArray array];savedKey=nil;return view;
}
int main(void) {@autoreleasepool {
    for(NSDictionary *state in @[@{},@{@"serverURL":@""},@{@"serverURL":@"  \n "}])
        Check([RBXActivationOnlyServer(state) isEqual:@"https://redditspoof.vercel.app"],@"Only absent/empty configuration uses established production origin");
    Check([RBXActivationOnlyServer(@{@"serverURL":@" https://configured.example/ "}) isEqual:@"https://configured.example"],@"Configured origin is preserved and normalized");
    for(id invalid in @[@"http://configured.example",@"https://name:secret@configured.example",@"https://configured.example/path",@"https://configured.example?x",@"https://configured.example#x",@"https://configured.example:0",NSNull.null,@42])
        Check(RBXActivationOnlyServer(@{@"serverURL":invalid})==nil,@"Invalid nonempty configuration cannot be replaced by production fallback");
    FixtureLicense *view=Fresh(@{});[view activateLicense];
    Check([view.submittedAction isEqual:@"activateLicense"]&&[view.submittedValues isEqual:@{@"serverURL":@"https://redditspoof.vercel.app"}],@"Activation-only request contains origin, never plaintext key");
    Check([savedKey isEqual:@"TEST-LICENSE-KEY"]&&[events isEqual:@[@"secure-write",@"queue"]],@"Trimmed key is stored securely before the request");
    Check(view.keyField.text.length==0&&view.serverField==nil,@"Hidden-server activation clears entered key");
    view=Fresh(@{@"serverURL":@"https://configured.example/"});[view activateLicense];
    Check([view.submittedValues[@"serverURL"] isEqual:@"https://configured.example"],@"Activation does not replace an existing configured server");
    view=Fresh(@{@"serverURL":@"http://invalid.example"});[view activateLicense];
    Check(!events.count&&view.localError.length,@"Invalid configured origin changes neither key nor queue");
    view=Fresh(@{});savedKey=@"EXISTING-SAVED-KEY";view.keyField.text=@"";[view activateLicense];
    Check([savedKey isEqual:@"EXISTING-SAVED-KEY"]&&view.submittedAction.length,@"Manual empty-field retry retains existing secure-key behavior");
    view=Fresh(@{});view.keyField.text=@"";readFails=YES;[view activateLicense];
    Check(!events.count&&view.localError.length,@"Unreadable saved key does not queue activation");
    view=Fresh(@{});writeFails=YES;[view activateLicense];
    Check([events isEqual:@[@"secure-write"]]&&!view.submittedAction&&view.keyField.text.length,@"Secure-store failure keeps draft and never queues");
    for(NSDictionary *state in @[@{@"unlocked":@YES},@{@"retryAt":@(NSDate.date.timeIntervalSince1970+300)}]){
        view=Fresh(state);[view activateLicense];Check(!events.count,@"Unlocked and retry-backoff states forbid activation mutation");
    }
    view=Fresh(@{});view.hasPendingRequest=YES;[view activateLicense];Check(!events.count,@"Pending activation cannot be duplicated");
    view=Fresh(@{@"paired":@YES});[view validateLicense];Check(!events.count&&!view.submittedAction,@"Activation-only mode exposes no alternate Validate action");
    view=Fresh(@{@"paired":@YES});view.activationOnly=NO;[view validateLicense];
    Check([view.submittedAction isEqual:@"validateLicense"]&&[view.submittedValues isEqual:@{}]&&[events isEqual:@[@"queue"]],@"Detailed license mode keeps key-free paired-device validation");
    view=Fresh(@{});view.activationOnly=NO;view.serverField=[FixtureField new];[view activateLicense];
    Check(!events.count&&view.localError.length,@"Detailed mode still requires an explicitly configured origin");
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    NSDictionary *grant=@{@"unlocked":@YES,@"paired":@YES,@"expiresAt":@(now+300),@"serverURL":@"https://configured.example"};
    view=Fresh(@{});view.activationOnly=NO;view.publication=@{@"updatedAt":@(now),@"license":grant};
    [view refreshDetailedLicenseState];
    Check([view.licenseState[@"unlocked"] boolValue]&&view.publicationReadCount==1&&view.stateUpdateCount==1&&events.count==0,
        @"Detailed Account reads full fresh publication without queuing requests or changing secure storage");
    for(NSDictionary *publication in @[@{@"updatedAt":@(now-20),@"license":grant},
        @{@"updatedAt":@(now+20),@"license":grant},@{},
        @{@"updatedAt":@(now),@"license":@{@"unlocked":@NO,@"status":@"revoked"}},
        @{@"updatedAt":@(now),@"license":@{@"unlocked":@YES,@"expiresAt":@(now-1)}}]) {
        view.publication=publication;[view refreshDetailedLicenseState];
        Check(![view.licenseState[@"unlocked"] boolValue]&&events.count==0,
            @"Detailed Account rejects stale, future, missing, revoked and expired local publications without auto requests");
    }
    view=Fresh(@{@"unlocked":@NO,@"reason":@"Root gate supplied state"});view.publication=@{@"updatedAt":@(now),@"license":grant};
    [view refreshDetailedLicenseState];
    Check(view.publicationReadCount==0&&view.stateUpdateCount==0&&[view.licenseState[@"reason"] isEqual:@"Root gate supplied state"],
        @"Activation-only mode never replaces the window gate's injected state");
    printf("PASS: %lu actual license activation/publication assertions; privacy/wiring contracts also pass\n",(unsigned long)checks);
}}
'''.replace('__FUNCTIONS__', functions).replace('__METHODS__', methods)
with tempfile.TemporaryDirectory(prefix='rbx-license-screen-') as directory:
    path=Path(directory);(path/'test.m').write_text(fixture)
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-framework','Foundation','-I',str(ROOT/'shared'),str(path/'test.m'),'-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test')],check=True)
