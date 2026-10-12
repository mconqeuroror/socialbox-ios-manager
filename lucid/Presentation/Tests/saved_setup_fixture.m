#import <UIKit/UIKit.h>
#import "SBSavedContainerSetup.h"
#import "SBActivationView.h"
#import "SBDesign.h"
#import "../../Containers/LBXContainerConfiguration.h"
#import "../../Containers/LBXContainerRootMutationCoordinator.h"
#import "activation_transport_fixture.h"
#import "saved_setup_transport_fixture.h"
#import <objc/runtime.h>
#include <math.h>
#include <stdlib.h>

// Fixture-only ABI stand-in. This owned flow must never register a recovered
// substrate hook; production resolves the jailbreak's own implementation.
void MSHookMessageEx(Class cls,SEL selector,IMP replacement,IMP *original) {
    (void)cls;(void)selector;(void)replacement;(void)original;abort();
}

static NSMutableDictionary *Results;
static NSUInteger Checks,Failures,LegacyCalls;
static UIWindow *Window;
static UIViewController *Host;
static UINavigationController *Navigation;
static UITableViewController *Browser;
static NSDictionary *Original,*Unknown,*UncertainUpdate,*Conflict;
static NSString *OriginalIdentifier;
static BOOL Finished;
static void Check(BOOL value,NSString *label) {
    Checks++;if(!value)Failures++;Results[[NSString stringWithFormat:@"%04lu %@",(unsigned long)Checks,label]]=value?@"PASS":@"FAIL";
    NSLog(@"%@: %@",value?@"PASS":@"FAIL",label);
}
static UIView *ViewID(UIView *root,NSString *identifier) {
    if([root.accessibilityIdentifier isEqual:identifier])return root;
    for(UIView *view in root.subviews){UIView *found=ViewID(view,identifier);if(found)return found;}return nil;
}
static BOOL Text(UIView *root,NSString *value) {
    if([root isKindOfClass:UILabel.class]&&[((UILabel *)root).text containsString:value])return YES;
    for(UIView *view in root.subviews)if(Text(view,value))return YES;return NO;
}
static UIButton *Button(UIView *root,NSString *identifier){return (UIButton *)ViewID(root,identifier);}
static void Tap(UIView *root,NSString *identifier){[Button(root,identifier) sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];}
static UITextField *Field(NSString *identifier){return (UITextField *)ViewID(Navigation.topViewController.view,identifier);}
static LBXContainerRootMutationCoordinator *Coordinator(void){return [Browser valueForKey:@"coordinator"];}
static NSDictionary *Pending(void){return [Coordinator() pendingMutation:nil];}
static BOOL VerifiedEmpty(void){LBXContainerRootMutationCoordinator *coordinator=Coordinator();NSError *error=nil;
    NSDictionary *pending=[coordinator pendingMutation:&error];return coordinator&&!error&&[coordinator.safeStatus[@"stateAvailable"] boolValue]&&!pending;}
static void Finish(void) {
    if(Finished)return;Finished=YES;
    Check(LegacyCalls==0,@"new setup and own verification never invoke legacy creation, switching or admission");
    for(NSString *operation in @[@"prepare",@"create",@"update",@"read",@"list"])
        Check(SBTestSavedSetupCount([@"legacy." stringByAppendingString:operation])==0,@"root UI never calls retired numeric/raw source writer or journal client");
    Check(SBTestSavedSetupCount(@"fixture-initialize")==1,@"only external fixture establishes synthetic root namespace once");
    Check(SBTestSavedSetupRemoveSyntheticRoot(),@"only in-memory synthetic root namespace is removed; no owner files were observed");
    NSDictionary *result=@{@"ok":Failures==0?@YES:@NO,@"checks":@(Checks),@"failures":@(Failures),@"results":Results,
        @"transport":@"synthetic typed root-protocol replies; no live service",@"runtimeAccepted":@NO,@"ownerDeviceAcceptance":@"NOT_RUN",@"legacyCalls":@(LegacyCalls),
        @"rootStorageAcceptance":@"NOT_RUN",@"firstInstallAcceptance":@"NOT_RUN"};
    NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/presentation-result.json"];
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];[bytes writeToFile:path atomically:YES];
}
static void After(double seconds,void (^action)(void)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if(Finished)return;@try{action();}@catch(__unused NSException *exception){Check(NO,@"synthetic UIKit action completes without exception");Finish();}
    });
}
static BOOL Require(BOOL value,NSString *label){Check(value,label);if(!value)Finish();return value;}
static void AwaitUntil(BOOL (^ready)(void),NSString *label,void (^action)(void),NSTimeInterval deadline) {
    if(Finished)return;
    if(ready()){Check(YES,label);action();return;}
    if(NSProcessInfo.processInfo.systemUptime>=deadline){Check(NO,label);Finish();return;}
    After(.05,^{AwaitUntil(ready,label,action,deadline);});
}
static void Await(BOOL (^ready)(void),NSString *label,void (^action)(void)) {
    AwaitUntil(ready,label,action,NSProcessInfo.processInfo.systemUptime+6);
}
static void Capture(NSString *name) {
    [Window layoutIfNeeded];UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:Window.bounds];
    UIImage *image=[renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context){[Window drawViewHierarchyInRect:Window.bounds afterScreenUpdates:YES];}];
    [UIImagePNGRepresentation(image) writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:[@"Documents" stringByAppendingPathComponent:name]] atomically:YES];
}
static void Open(void){SBPresentSavedContainerSetups(Host);Navigation=(UINavigationController *)Host.presentedViewController;Browser=(UITableViewController *)Navigation.viewControllers.firstObject;}
static void Back(void){[Navigation popToViewController:Browser animated:NO];}
static BOOL NavigationReady(void){return Navigation&&Host.presentedViewController==Navigation&&Navigation.viewIfLoaded.window&&
    !Navigation.isBeingPresented&&!Navigation.isBeingDismissed&&!Navigation.transitionCoordinator;}
static BOOL BrowserReady(void){return NavigationReady()&&Navigation.topViewController==Browser&&![[Browser valueForKey:@"busy"] boolValue];}
static BOOL EditorReady(void){return NavigationReady()&&[Navigation.topViewController.view.accessibilityIdentifier isEqual:@"socialbox.savedsetup.editor"]&&
    Field(@"socialbox.savedsetup.name")&&Button(Navigation.topViewController.view,@"socialbox.savedsetup.save");}
static BOOL EditorIdle(void){return EditorReady()&&![[Browser valueForKey:@"busy"] boolValue];}
static BOOL Model(NSDictionary *value){return [LBXContainerConfiguration fromDictionary:value error:nil]!=nil;}
static BOOL PendingMatches(NSDictionary *value){return Model(value)&&[Pending()[@"configuration"] isEqual:value];}
static void BackReady(void (^action)(void)){Back();Await(^BOOL{return BrowserReady();},@"navigation returns to ready saved browser",action);}
static void OpenReady(void (^action)(void)){Open();Await(^BOOL{return BrowserReady();},@"modal presentation reaches ready saved browser",action);}
static void Select(NSString *identifier,void (^action)(void)) {
    NSArray *entries=[Browser valueForKey:@"entries"];NSUInteger index=0;for(NSDictionary *entry in entries){if([entry[@"identifier"] isEqual:identifier])break;index++;}
    if(!Require(identifier.length&&BrowserReady()&&index<entries.count,@"saved stable UUID resolves an actual listed row"))return;
    [Browser.tableView.delegate tableView:Browser.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)index inSection:0]];
    Await(^BOOL{return EditorReady();},@"full record read reaches ready editor",action);
}
static void LayoutForm(void) {
    UIView *view=Navigation.topViewController.view;[view layoutIfNeeded];UIScrollView *scroll=nil;
    for(UIView *child in view.subviews)if([child isKindOfClass:UIScrollView.class])scroll=(UIScrollView *)child;
    Check(scroll&&fabs(view.bounds.size.width-320)<1,@"saved setup form uses actual UIKit 320-point viewport");
    Check(scroll.contentSize.height>scroll.bounds.size.height,@"all setup fields and actions remain in scrollable content");
    for(NSString *key in @[@"serialNumber",@"udid",@"idfa",@"idfv",@"platformUUID",@"wifiMac",@"bluetoothMac",@"imei",@"meid",@"iccid"]){
        UIView *field=ViewID(view,[@"socialbox.savedsetup.identifier." stringByAppendingString:key]);CGRect rect=[field convertRect:field.bounds toView:scroll];
        Check(field&&isfinite(rect.origin.x)&&rect.size.width>0&&CGRectGetMinX(rect)>=0&&CGRectGetMaxX(rect)<=scroll.bounds.size.width+1,@"identifier field stays within narrow scroll viewport");
    }
    UIButton *save=Button(view,@"socialbox.savedsetup.save");[scroll scrollRectToVisible:[save convertRect:save.bounds toView:scroll] animated:NO];[view layoutIfNeeded];
    CGRect visible=[save convertRect:save.bounds toView:view];Check(CGRectGetMaxY(visible)<=CGRectGetMaxY(view.bounds)+1,@"scroll reaches complete save action on narrow screen");Capture(@"saved-setup-form-320.png");
}
static void FillNew(NSString *name,void (^action)(void)) {
    if(!Require(BrowserReady()&&Button(Browser.view,@"socialbox.savedsetups.new").enabled,@"new setup action exists and is ready"))return;
    Tap(Browser.view,@"socialbox.savedsetups.new");Await(^BOOL{return EditorReady();},@"new setup navigation reaches ready editor",^{Field(@"socialbox.savedsetup.name").text=name;action();});
}
static void ConflictReview(void);
static void UncertainUpdateReview(void);
static void UnknownRetry(void);
static void ManualCreation(void);
static void UnknownStageMissing(void);
static void UnknownStagePublished(void);
static void EditSaved(void);

static void ConflictReview(void) {
    Select(OriginalIdentifier,^{Field(@"socialbox.savedsetup.name").text=@"Conflicting synthetic update";SBTestSavedSetupSetMutationBehavior(@"conflict");Tap(Navigation.topViewController.view,@"socialbox.savedsetup.save");
        Await(^BOOL{return EditorIdle()&&PendingMatches(SBTestSavedSetupLastCandidate());},@"conflicting save completes with retained root-slot model",^{
            Conflict=SBTestSavedSetupLastCandidate();NSDictionary *expected=SBTestSavedSetupLastExpected();
            if(!Require(Model(expected)&&PendingMatches(Conflict)&&[Pending()[@"expected"] isEqual:expected],@"conflicting mutation retains full candidate and expected record"))return;
            Check(!Button(Navigation.topViewController.view,@"socialbox.savedsetup.save").enabled,@"conflicting form cannot replace its pending candidate");
            BackReady(^{NSUInteger count=SBTestSavedSetupCount(@"stage-update");Tap(Browser.view,@"socialbox.savedsetups.reconcile");
                Await(^BOOL{return BrowserReady()&&Text(Browser.view,@"cannot be changed");},@"conflict reconciliation finishes in ready browser",^{
                    Check(PendingMatches(Conflict),@"exact reconciliation of other durable state reports conflict without clearing");NSUInteger reads=SBTestSavedSetupCount(@"execute");Tap(Browser.view,@"socialbox.savedsetups.retry");
                    Await(^BOOL{return BrowserReady()&&SBTestSavedSetupCount(@"execute")==reads+1;},@"conflict retry completes exact slot check",^{
                        Check(SBTestSavedSetupCount(@"stage-update")==count&&PendingMatches(Conflict),@"conflict retry rechecks exact durable state and sends no replacement update");
                        if(!Require(Button(Browser.view,@"socialbox.savedsetups.review").enabled,@"pending review action exists and is enabled"))return;
                        Tap(Browser.view,@"socialbox.savedsetups.review");Await(^BOOL{return EditorReady();},@"pending review reaches ready editor",^{
                            Check([Field(@"socialbox.savedsetup.name").text isEqual:Conflict[@"name"]]&&!Field(@"socialbox.savedsetup.name").enabled&&!Button(Navigation.topViewController.view,@"socialbox.savedsetup.save").enabled,@"pending review displays exact read-only candidate");
                            Check(!ViewID(Navigation.topViewController.view,@"socialbox.container.detail.switch")&&!ViewID(Navigation.topViewController.view,@"socialbox.container.detail.delete"),@"saved setup review exposes no runtime switch or removal");
                            BackReady(^{Capture(@"saved-setups-pending-320.png");[Navigation dismissViewControllerAnimated:NO completion:^{Check(PendingMatches(Conflict),@"dismissed conflicted flow preserves in-memory rendering and synthetic root pending state");Finish();}];});
                        });
                    });
                });
            });
        });
    });
}
static void UncertainUpdateReview(void) {
    Select(OriginalIdentifier,^{Field(@"socialbox.savedsetup.name").text=@"Saved uncertain synthetic update";SBTestSavedSetupSetMutationBehavior(@"unconfirmed_saved");Tap(Navigation.topViewController.view,@"socialbox.savedsetup.save");
        Await(^BOOL{return EditorIdle()&&PendingMatches(SBTestSavedSetupLastCandidate());},@"uncertain update completes with retained root-slot model",^{
            UncertainUpdate=SBTestSavedSetupLastCandidate();if(!Require(PendingMatches(UncertainUpdate)&&[SBTestSavedSetupRecordSnapshot()[OriginalIdentifier] isEqual:UncertainUpdate],@"lost save reply keeps exact candidate despite durable service publication"))return;
            BackReady(^{NSUInteger count=SBTestSavedSetupCount(@"stage-update");Tap(Browser.view,@"socialbox.savedsetups.reconcile");
                Await(^BOOL{return BrowserReady()&&VerifiedEmpty()&&Button(Browser.view,@"socialbox.savedsetups.new").enabled;},@"exact durable publication reconciles to verified empty",^{
                    Check(SBTestSavedSetupCount(@"stage-update")==count,@"exact durable candidate reconciles and clears pending without resending update");ConflictReview();
                });
            });
        });
    });
}
static BOOL UnknownIntent(NSDictionary *value) {
    NSDictionary *pending=Pending();return pending&&pending[@"configuration"]==NSNull.null&&!pending[@"token"]&&
        [pending[@"stageRequestID"] isEqual:value[@"stageRequestID"]]&&[pending[@"expectedEmptyEpoch"] isEqual:value[@"expectedEmptyEpoch"]]&&[pending[@"input"] isEqual:value];
}
static void UnknownStagePublished(void) {
    FillNew(@"Published uncertain stage",^{NSUInteger stages=SBTestSavedSetupCount(@"stage-create"),generated=SBTestSavedSetupCount(@"candidate-generation"),executions=SBTestSavedSetupCount(@"execute");
        SBTestSavedSetupSetMutationBehavior(@"unknown_stage_published");Tap(Navigation.topViewController.view,@"socialbox.savedsetup.save");
        Await(^BOOL{return EditorIdle()&&SBTestSavedSetupCount(@"stage-create")==stages+1&&UnknownIntent(SBTestSavedSetupLastStageArguments());},@"lost first stage reply retains only exact unconfirmed input",^{
            NSDictionary *input=SBTestSavedSetupLastStageArguments(),*rootSlot=SBTestSavedSetupRootState()[@"pending"],*candidate=rootSlot[@"configuration"];
            if(!Require(Model(candidate)&&SBTestSavedSetupCount(@"candidate-generation")==generated+1&&SBTestSavedSetupCount(@"execute")==executions,@"synthetic root published one complete slot but unknown client never executed it"))return;
            LBXContainerRootMutationCoordinator *restarted=[LBXContainerRootMutationCoordinator coordinator];NSError *error=nil;
            Check(![restarted pendingMutation:&error]&&error!=nil,@"fresh process coordinator begins unknown without a local journal or cached grant");
            [restarted refreshWithCompletion:^(NSDictionary *reply){
                if(!Require([reply[@"result"] isEqual:@"status"]&&[reply[@"stateAvailable"] isEqual:@YES]&&[reply[@"pending"] isEqual:@YES]&&
                    [reply[@"runtimeAccepted"] isEqual:@NO]&&[[restarted pendingMutation:nil] isEqual:rootSlot],@"fresh async status reconstructs exact root durable slot with runtime acceptance false"))return;
                Check(SBTestSavedSetupCount(@"execute")==executions&&SBTestSavedSetupCount(@"stage-create")==stages+1,@"restart observation never stages or executes automatically");
                [Navigation dismissViewControllerAnimated:NO completion:^{OpenReady(^{
                    if(!Require(PendingMatches(candidate)&&[Pending()[@"token"] isEqual:rootSlot[@"token"]]&&!Button(Browser.view,@"socialbox.savedsetups.new").enabled,@"reopened real browser observes exact root token and blocks replacement"))return;
                    Check([SBTestSavedSetupLastStageArguments() isEqual:input],@"dismissal never changed first-stage request ID or input");Tap(Browser.view,@"socialbox.savedsetups.retry");
                    Await(^BOOL{return BrowserReady()&&VerifiedEmpty()&&SBTestSavedSetupCount(@"execute")==executions+1;},@"explicit retry executes authenticated retained root slot",^{
                        Check([SBTestSavedSetupRecordSnapshot()[candidate[@"identifier"]] isEqual:candidate]&&SBTestSavedSetupCount(@"stage-create")==stages+1&&SBTestSavedSetupCount(@"candidate-generation")==generated+1,@"lost stage recovery preserves exact root UUID and identifiers without another stage");UnknownRetry();
                    });
                });}];
            }];
        });
    });
}
static void UnknownStageMissing(void) {
    FillNew(@"Unpublished uncertain stage",^{NSUInteger stages=SBTestSavedSetupCount(@"stage-create"),generated=SBTestSavedSetupCount(@"candidate-generation"),executions=SBTestSavedSetupCount(@"execute");
        SBTestSavedSetupSetMutationBehavior(@"unknown_stage_missing");Tap(Navigation.topViewController.view,@"socialbox.savedsetup.save");
        Await(^BOOL{return EditorIdle()&&SBTestSavedSetupCount(@"stage-create")==stages+1&&UnknownIntent(SBTestSavedSetupLastStageArguments());},@"unknown unpublished stage preserves stable input without invented candidate",^{
            NSDictionary *input=SBTestSavedSetupLastStageArguments();
            if(!Require(SBTestSavedSetupRootState()[@"pending"]==NSNull.null&&SBTestSavedSetupCount(@"candidate-generation")==generated&&SBTestSavedSetupCount(@"execute")==executions,@"unpublished stage has no root candidate and no execution"))return;
            Check(!Button(Navigation.topViewController.view,@"socialbox.savedsetup.save").enabled,@"unknown first stage disables form replacement");
            [Navigation dismissViewControllerAnimated:NO completion:^{OpenReady(^{
                if(!Require(UnknownIntent(input)&&!Button(Browser.view,@"socialbox.savedsetups.new").enabled&&Button(Browser.view,@"socialbox.savedsetups.review").hidden&&Button(Browser.view,@"socialbox.savedsetups.reconcile").enabled,@"dismiss/reopen retains exact unknown input, hides invented review and permits verification"))return;
                NSUInteger status=SBTestSavedSetupCount(@"status");Tap(Browser.view,@"socialbox.savedsetups.reconcile");
                Await(^BOOL{return BrowserReady()&&SBTestSavedSetupCount(@"status")==status+1&&Text(Browser.view,@"same request");},@"fresh empty-epoch reconciliation returns same retry requirement",^{
                    Check(UnknownIntent(input)&&SBTestSavedSetupCount(@"stage-create")==stages+1&&SBTestSavedSetupCount(@"candidate-generation")==generated,@"same empty epoch never discards uncertain input or stages automatically");Tap(Browser.view,@"socialbox.savedsetups.retry");
                    Await(^BOOL{return BrowserReady()&&VerifiedEmpty()&&SBTestSavedSetupCount(@"stage-create")==stages+2;},@"explicit retry sends retained first-stage input",^{
                        NSDictionary *candidate=SBTestSavedSetupLastCandidate();Check(Model(candidate)&&[SBTestSavedSetupLastStageArguments() isEqual:input]&&SBTestSavedSetupCount(@"candidate-generation")==generated+1&&SBTestSavedSetupCount(@"execute")==executions+1,@"same stage request ID and exact input generate one root candidate only when accepted");UnknownStagePublished();
                    });
                });
            });}];
        });
    });
}
static void UnknownRetry(void) {
    FillNew(@"Interrupted synthetic setup",^{SBTestSavedSetupSetMutationBehavior(@"unconfirmed_missing");Tap(Navigation.topViewController.view,@"socialbox.savedsetup.save");
        Await(^BOOL{return EditorIdle()&&PendingMatches(SBTestSavedSetupLastCandidate());},@"unknown execution completes with retained root-slot model",^{
            Unknown=SBTestSavedSetupLastCandidate();SBTestSavedSetupReplayDeferred();if(!Require(PendingMatches(Unknown)&&!SBTestSavedSetupRecordSnapshot()[Unknown[@"identifier"]],@"unknown execute outcome keeps full root-staged candidate when service record is missing"))return;
            Check(!Button(Navigation.topViewController.view,@"socialbox.savedsetup.save").enabled,@"unknown result locks form and preserves the same root slot");Check(SBTestSavedSetupCount(@"fixture-replay")==1,@"late prior callback is delivered while a newer pending slot remains visible");NSUInteger prepares=SBTestSavedSetupCount(@"candidate-generation"),creates=SBTestSavedSetupCount(@"stage-create"),executes=SBTestSavedSetupCount(@"execute");
            [Navigation dismissViewControllerAnimated:NO completion:^{if(!Require(PendingMatches(Unknown),@"dismissal retains exact staged candidate in the process coordinator"))return;
                OpenReady(^{Check(!Button(Browser.view,@"socialbox.savedsetups.new").enabled&&!Button(Browser.view,@"socialbox.savedsetups.reconcile").hidden,@"reopened browser exposes pending recovery and blocks another setup");
                    NSUInteger reads=SBTestSavedSetupCount(@"reconcile");Tap(Browser.view,@"socialbox.savedsetups.reconcile");
                    Await(^BOOL{return BrowserReady()&&SBTestSavedSetupCount(@"reconcile")==reads+1;},@"missing pending slot reconciliation completes without mutation",^{
                        Check(PendingMatches(Unknown)&&SBTestSavedSetupCount(@"candidate-generation")==prepares&&SBTestSavedSetupCount(@"stage-create")==creates,@"reconciliation of missing record retains same root slot without staging again");
                        SBTestSavedSetupSetLicenseResult(@"expired");NSUInteger validations=SBTestSavedSetupValidateCount();Tap(Browser.view,@"socialbox.savedsetups.retry");
                        Await(^BOOL{return BrowserReady()&&SBTestSavedSetupValidateCount()>validations&&Text(Browser.view,@"Verify your license");},@"expired validation completes in ready browser",^{
                            Check(PendingMatches(Unknown)&&SBTestSavedSetupCount(@"stage-create")==creates,@"expired source validation denies retry while preserving candidate");
                            SBTestSavedSetupSetLicenseResult(@"active");Tap(Browser.view,@"socialbox.savedsetups.retry");
                            Await(^BOOL{return BrowserReady()&&VerifiedEmpty()&&SBTestSavedSetupCount(@"execute")==executes+1;},@"same slot execution retry completes to verified empty",^{
                                Check([SBTestSavedSetupLastCandidate() isEqual:Unknown]&&SBTestSavedSetupCount(@"candidate-generation")==prepares&&SBTestSavedSetupCount(@"stage-create")==creates,@"explicit execution retry uses identical root slot and identifiers without another stage");UncertainUpdateReview();
                            });
                        });
                    });
                });
            }];
        });
    });
}
static void ManualCreation(void) {
    FillNew(@"Manual synthetic setup",^{UISegmentedControl *mode=(UISegmentedControl *)ViewID(Navigation.topViewController.view,@"socialbox.savedsetup.identifierMode");
        if(!Require(mode&&Model(Original),@"manual form has selector and complete retained model"))return;
        mode.selectedSegmentIndex=1;[mode sendActionsForControlEvents:UIControlEventValueChanged];
        NSMutableDictionary *manual=[Original[@"identifiers"] mutableCopy];manual[@"serialNumber"]=@"MANUAL12345";manual[@"idfa"]=NSUUID.UUID.UUIDString;manual[@"idfv"]=NSUUID.UUID.UUIDString;
        for(NSString *key in manual){UITextField *field=Field([@"socialbox.savedsetup.identifier." stringByAppendingString:key]);if(!Require(field&&field.enabled,@"all ten manual identifier fields become editable"))return;field.text=manual[key];}
        NSUInteger count=SBTestSavedSetupCount(@"stage-create");
        UITextField *name=Field(@"socialbox.savedsetup.name");name.text=@"   ";Tap(Navigation.topViewController.view,@"socialbox.savedsetup.save");
        Check(SBTestSavedSetupCount(@"stage-create")==count&&name.isFirstResponder&&Text(Navigation.topViewController.view,@"1–80 characters"),@"invalid name is focused with precise length guidance before staging");
        Check([name.text isEqual:@"   "],@"name failure preserves exact whitespace rather than silently trimming");name.text=@"Manual synthetic setup";
        NSArray *ordered=@[@"serialNumber",@"udid",@"idfa",@"idfv",@"platformUUID",@"wifiMac",@"bluetoothMac",@"imei",@"meid",@"iccid"];
        for(NSString *key in ordered) {
            UITextField *bad=Field([@"socialbox.savedsetup.identifier." stringByAppendingString:key]);bad.text=@"invalid";
            Tap(Navigation.topViewController.view,@"socialbox.savedsetup.save");
            Check(SBTestSavedSetupCount(@"stage-create")==count&&bad.isFirstResponder&&[bad.text isEqual:@"invalid"],@"each invalid identifier is focused without staging or replacing input");
            Check(Text(Navigation.topViewController.view,bad.accessibilityLabel),@"error identifies the visible field without repeating its private value");
            for(NSString *other in ordered)if(![other isEqual:key])Check([Field([@"socialbox.savedsetup.identifier." stringByAppendingString:other]).text isEqual:manual[other]],@"other complete manual values survive field error");
            bad.text=manual[key];
        }
        Field(@"socialbox.savedsetup.identifier.idfa").text=@"invalid";Field(@"socialbox.savedsetup.identifier.iccid").text=@"";
        Tap(Navigation.topViewController.view,@"socialbox.savedsetup.save");
        Check(Field(@"socialbox.savedsetup.identifier.idfa").isFirstResponder&&[Field(@"socialbox.savedsetup.identifier.iccid").text isEqual:@""],@"first invalid field follows form order even if a later field is empty");
        Field(@"socialbox.savedsetup.identifier.iccid").text=manual[@"iccid"];
        if(!Require(SBTestSavedSetupCount(@"stage-create")==count&&Text(Navigation.topViewController.view,@"Advertising identifier: UUID"),@"precise manual error remains before any root staging"))return;
        Field(@"socialbox.savedsetup.identifier.idfa").text=manual[@"idfa"];Tap(Navigation.topViewController.view,@"socialbox.savedsetup.save");
        Await(^BOOL{return BrowserReady()&&VerifiedEmpty()&&SBTestSavedSetupRecordSnapshot().count==2;},@"manual save confirms and returns to ready browser",^{
            NSDictionary *candidate=SBTestSavedSetupLastCandidate();if(!Require(Model(candidate)&&[candidate[@"identifierMode"] isEqual:@"manual"]&&[candidate[@"identifiers"] isEqual:manual]&&[candidate[@"proxyReference"] isEqual:@""],@"manual creation saves all exact chosen values with empty proxy reference"))return;
            Check(VerifiedEmpty(),@"manual saved reply confirms exact synthetic root-slot candidate");UnknownStageMissing();
        });
    });
}
static void EditSaved(void) {
    Select(OriginalIdentifier,^{
        Check([Field(@"socialbox.savedsetup.identifier.idfa").text isEqual:Original[@"identifiers"][@"idfa"]],@"full saved record reload displays retained random identifiers");
        Field(@"socialbox.savedsetup.name").text=@"Edited synthetic setup";
        UISwitch *facebook=(UISwitch *)ViewID(Navigation.topViewController.view,@"socialbox.savedsetup.app.com.facebook.Facebook");
        UISwitch *twitter=(UISwitch *)ViewID(Navigation.topViewController.view,@"socialbox.savedsetup.app.com.atebits.Tweetie2");
        if(!Require(facebook&&twitter&&facebook.enabled&&twitter.enabled,@"requested membership switches exist and permit edit"))return;
        facebook.on=YES;twitter.on=YES;
        NSUInteger count=SBTestSavedSetupCount(@"candidate-generation");Tap(Navigation.topViewController.view,@"socialbox.savedsetup.save");
        Await(^BOOL{return BrowserReady()&&VerifiedEmpty()&&[SBTestSavedSetupLastCandidate()[@"revision"] isEqual:@2];},@"edited save confirms and returns to ready browser",^{
            NSDictionary *candidate=SBTestSavedSetupLastCandidate();if(!Require(Model(candidate)&&[candidate[@"identifiers"] isEqual:Original[@"identifiers"]]&&[candidate[@"identifier"] isEqual:OriginalIdentifier]&&[candidate[@"revision"] isEqual:@2]&&[candidate[@"applications"] count]==3,@"edit retains UUID and identifiers while changing requested membership and revision"))return;
            Check([SBTestSavedSetupLastExpected() isEqual:Original]&&SBTestSavedSetupCount(@"candidate-generation")==count,@"edit sends exact full prior document without random preparation");ManualCreation();
        });
    });
}
static void RandomCreation(void) {
    FillNew(@"Random synthetic setup",^{Check(Text(Navigation.topViewController.view,@"Proxy unavailable")&&Text(Navigation.topViewController.view,@"Requested apps"),@"creation describes requested membership and unavailable proxy honestly");LayoutForm();
    if(Failures){Finish();return;}SBTestSavedSetupSetMutationBehavior(@"defer");Tap(Navigation.topViewController.view,@"socialbox.savedsetup.save");
    Await(^BOOL{return Model(SBTestSavedSetupLastCandidate())&&SBTestSavedSetupCount(@"stage-create")==1&&SBTestSavedSetupCount(@"execute")==1;},@"deferred execution retains complete staged model",^{
        Original=SBTestSavedSetupLastCandidate();OriginalIdentifier=Original[@"identifier"];
        if(!Require(SBTestSavedSetupCount(@"candidate-generation")==1&&SBTestSavedSetupCount(@"stage-create")==1&&[Original[@"identifierMode"] isEqual:@"random"]&&[Original[@"identifiers"] count]==10,@"one explicit random save stages one root-generated complete candidate"))return;
        if(!Require(PendingMatches(Original)&&!Button(Navigation.topViewController.view,@"socialbox.savedsetup.save").enabled&&Navigation.modalInPresentation&&Navigation.topViewController.navigationItem.hidesBackButton,@"authenticated root-slot candidate precedes deferred execution and busy UI blocks duplicate save and dismissal"))return;
        Tap(Navigation.topViewController.view,@"socialbox.savedsetup.save");Check(SBTestSavedSetupCount(@"candidate-generation")==1&&SBTestSavedSetupCount(@"stage-create")==1&&SBTestSavedSetupCount(@"execute")==1,@"duplicate submit during pending execution sends no new stage or candidate generation");
        SBTestSavedSetupCompleteDeferred(@"saved",YES);
        Await(^BOOL{return BrowserReady()&&VerifiedEmpty()&&[Browser.tableView numberOfRowsInSection:0]==1;},@"deferred save confirms and displays ready saved row",^{
            if(!Require([SBTestSavedSetupRecordSnapshot()[OriginalIdentifier] isEqual:Original],@"saved response confirms exact staged candidate and displays one saved row"))return;EditSaved();
        });
    });
    });
}
static void Initialized(void) {
    SBTestSavedSetupInitializeRoot();
    Check(SBTestSavedSetupRootState()[@"pending"]==NSNull.null&&[SBTestSavedSetupRootState()[@"epoch"] isEqual:@"1"],@"external fixture establishes pristine in-memory root state explicitly");
    OpenReady(^{if(!Require(VerifiedEmpty()&&Button(Browser.view,@"socialbox.savedsetups.new").enabled&&Text(Browser.view,@"No saved setups yet"),@"fresh authenticated-shaped root status exposes empty setup browser"))return;RandomCreation();});
}
static void ActivationEntry(void) {
    SBActivationView *activation=[SBActivationView new];activation.translatesAutoresizingMaskIntoConstraints=NO;[Host.view addSubview:activation];
    [NSLayoutConstraint activateConstraints:@[[activation.leadingAnchor constraintEqualToAnchor:Host.view.leadingAnchor constant:20],
        [activation.trailingAnchor constraintEqualToAnchor:Host.view.trailingAnchor constant:-20],
        [activation.topAnchor constraintEqualToAnchor:Host.view.safeAreaLayoutGuide.topAnchor constant:20]]];
    UIButton *entry=Button(activation,@"socialbox.activation.savedsetups");UITextField *key=(UITextField *)ViewID(activation,@"socialbox.activation.key");
    if(!Require(entry&&key&&Button(activation,@"socialbox.control.license.button"),@"own activation controls exist before reply tests"))return;
    Check(entry.hidden,@"saved setup activation entry starts hidden without verified reply");key.text=@"AAAA-BBBB-CCCC-DDDD";Tap(activation,@"socialbox.control.license.button");SBTestLicenseComplete(@"invalid");
    Await(^BOOL{return ![[activation valueForKey:@"pending"] boolValue];},@"denied activation callback completes",^{Check(entry.hidden&&!Host.presentedViewController,@"denied own source reply never offers admitted setup entry");key.text=@"AAAA-BBBB-CCCC-DDDD";Tap(activation,@"socialbox.control.license.button");SBTestLicenseComplete(@"active");
        Await(^BOOL{return ![[activation valueForKey:@"pending"] boolValue];},@"active code with missing setup service completes",^{
            Check(entry.hidden&&[key.text isEqual:@"AAAA-BBBB-CCCC-DDDD"]&&Text(activation,@"Saved setups are unavailable")&&LegacyCalls==0,@"verified license alone keeps code and blocks unavailable saved-setup handoff");
            Check(!Host.presentedViewController&&!SBTestSavedSetupRootState()&&SBTestSavedSetupCount(@"candidate-generation")==0,@"activation readiness check does not initialize, generate or mutate missing metadata");
            [activation removeFromSuperview];Initialized();
        });
    });
}
@interface SavedSetupFixtureHost:UIViewController
- (void)tapValidate;
- (void)selectAppToSpoof;
- (void)switchContainer:(id)identifier;
@end
@implementation SavedSetupFixtureHost
- (void)tapValidate{LegacyCalls++;}
- (void)selectAppToSpoof{LegacyCalls++;}
- (void)switchContainer:(id)identifier{(void)identifier;LegacyCalls++;}
@end
@interface SavedSetupFixtureApp:NSObject<UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation SavedSetupFixtureApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;(void)options;Results=[NSMutableDictionary dictionary];SBTestSavedSetupReset();
    Check(!SBTestSavedSetupRootState(),@"fixture begins unavailable without local journal, home or process-role override");
    Window=[[UIWindow alloc] initWithFrame:CGRectMake(0,0,320,568)];self.window=Window;
    Host=[SavedSetupFixtureHost new];Host.view.backgroundColor=SBInk();Window.rootViewController=Host;[Window makeKeyAndVisible];
    After(.15,^{ActivationEntry();});return YES;
}
@end
int main(int argc,char *argv[]){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(SavedSetupFixtureApp.class));}}
