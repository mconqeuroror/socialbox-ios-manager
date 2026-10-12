#import <UIKit/UIKit.h>
#import "SBSavedContainerSetup.h"
#import "SBDesign.h"
#import "../../Containers/LBXContainerRootMutationCoordinator.h"
#import "../../Containers/LBXContainerMutationClient.h"
#import "saved_setup_transport_fixture.h"
#include <stdlib.h>

void MSHookMessageEx(Class c,SEL s,IMP r,IMP *o){(void)c;(void)s;(void)r;(void)o;abort();}
static UIWindow *Window;static UIViewController *Host;
static UINavigationController *Navigation;static UITableViewController *Browser;
static NSMutableDictionary *Results;static NSUInteger Checks,Failures;static BOOL Finished;
static NSDictionary *Original,*Input,*Slot;
static void Check(BOOL value,NSString *label){Checks++;if(!value)Failures++;Results[[NSString stringWithFormat:@"%04lu %@",(unsigned long)Checks,label]]=value?@"PASS":@"FAIL";NSLog(@"%@: %@",value?@"PASS":@"FAIL",label);}
static UIView *Find(UIView *view,NSString *identifier){if([view.accessibilityIdentifier isEqual:identifier])return view;for(UIView *child in view.subviews){UIView *found=Find(child,identifier);if(found)return found;}return nil;}
static UIButton *Button(NSString *identifier){return (id)Find(Navigation.topViewController.view,identifier);}
static void Tap(NSString *identifier){[Button(identifier) sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];}
static LBXContainerRootMutationCoordinator *Coordinator(void){return [Browser valueForKey:@"coordinator"];}
static NSDictionary *Pending(void){return [Coordinator() pendingMutation:nil];}
static BOOL Ready(void){return Navigation.viewIfLoaded.window&&!Navigation.transitionCoordinator&&!Navigation.isBeingPresented&&!Navigation.isBeingDismissed&&![[Browser valueForKey:@"busy"] boolValue];}
static BOOL BrowserReady(void){return Ready()&&Navigation.topViewController==Browser;}
static BOOL EditorReady(void){return Ready()&&[Navigation.topViewController.view.accessibilityIdentifier isEqual:@"socialbox.savedsetup.editor"]&&!Navigation.transitionCoordinator;}
static void Finish(void){if(Finished)return;Finished=YES;
    Check(SBTestSavedSetupCount(@"fixture-initialize")==1,@"only external synthetic fixture establishes root once");
    for(NSString *op in @[@"prepare",@"create",@"update",@"read",@"list"])Check(SBTestSavedSetupCount([@"legacy." stringByAppendingString:op])==0,@"no legacy raw/CID/runtime operation");
    Check(SBTestSavedSetupRemoveSyntheticRoot(),@"synthetic memory fixture removed without owner files");
    NSDictionary *report=@{@"ok":@(Failures==0),@"checks":@(Checks),@"failures":@(Failures),@"results":Results,
        @"transport":@"synthetic typed replies and in-memory retirement history; no native root files or live licensing",
        @"confirmation":@"source UIAlertAction handler after synthetic dismissal; no physical touch acceptance",
        @"ownerDeviceAcceptance":@"NOT_RUN",@"runtimeAccepted":@NO,@"firstInstallAcceptance":@"NOT_RUN"};
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [bytes writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/presentation-result.json"] atomically:YES];
}
static void After(double seconds,void (^action)(void)){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)),dispatch_get_main_queue(),^{if(Finished)return;@try{action();}@catch(__unused NSException *exception){Check(NO,@"fixture action completes without exception");Finish();}});}
static void AwaitUntil(BOOL (^ready)(void),NSString *label,void (^action)(void),double deadline){if(Finished)return;if(ready()){Check(YES,label);action();return;}if(NSProcessInfo.processInfo.systemUptime>=deadline){Check(NO,label);Finish();return;}After(.04,^{AwaitUntil(ready,label,action,deadline);});}
static void Await(BOOL (^ready)(void),NSString *label,void (^action)(void)){AwaitUntil(ready,label,action,NSProcessInfo.processInfo.systemUptime+7);}
static void Open(void (^done)(void)){SBPresentSavedContainerSetups(Host);Navigation=(id)Host.presentedViewController;Browser=(id)Navigation.viewControllers.firstObject;Await(^BOOL{return BrowserReady();},@"ready saved-settings browser",done);}
static void Back(void (^done)(void)){[Navigation popToViewController:Browser animated:NO];Await(^BOOL{return BrowserReady();},@"returns to browser",done);}
static void Create(NSString *name,void (^done)(void)){Tap(@"socialbox.savedsetups.new");Await(^BOOL{return EditorReady();},@"new settings form ready",^{
    Check(!Button(@"socialbox.savedsetup.remove"),@"unsaved draft has no removal action");
    ((UITextField *)Find(Navigation.topViewController.view,@"socialbox.savedsetup.name")).text=name;Tap(@"socialbox.savedsetup.save");
    Await(^BOOL{return BrowserReady()&&!Pending();},@"new settings saved without runtime grant",^{Original=SBTestSavedSetupLastCandidate();done();});
});}
static void Select(void (^done)(void)){NSArray *entries=[Browser valueForKey:@"entries"];NSUInteger index=0;while(index<entries.count&&![entries[index][@"identifier"] isEqual:Original[@"identifier"]])index++;
    if(index>=entries.count){Check(NO,@"original UUID listed");Finish();return;}
    NSUInteger reads=SBTestSavedSetupCount(@"read");[Browser.tableView.delegate tableView:Browser.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:index inSection:0]];
    Await(^BOOL{return EditorReady();},@"full read reaches original settings editor",^{Check(SBTestSavedSetupCount(@"read")==reads+1,@"selection makes authenticated-shaped full read");
        UIView *view=Navigation.topViewController.view;[view layoutIfNeeded];UIScrollView *scroll=nil;for(UIView *child in view.subviews)if([child isKindOfClass:UIScrollView.class])scroll=(id)child;
        UIButton *remove=Button(@"socialbox.savedsetup.remove");[scroll scrollRectToVisible:[remove convertRect:remove.bounds toView:scroll] animated:NO];[view layoutIfNeeded];CGRect rect=[remove convertRect:remove.bounds toView:view];
        Check(scroll&&rect.size.height>=44&&CGRectGetMinX(rect)>=0&&CGRectGetMaxX(rect)<=view.bounds.size.width+1&&CGRectGetMinY(rect)>=0&&CGRectGetMaxY(rect)<=view.bounds.size.height+1,@"320-point form scroll reaches full removal action within viewport");
        done();});}
static void Confirm(BOOL remove,void (^done)(void)){Tap(@"socialbox.savedsetup.remove");Await(^BOOL{return [Navigation.topViewController.presentedViewController isKindOfClass:UIAlertController.class]&&!Navigation.topViewController.presentedViewController.transitionCoordinator;},@"explicit removal confirmation is presented",^{
    UIViewController *editor=Navigation.topViewController;UIAlertController *alert=(id)editor.presentedViewController;
    Check([alert.title isEqual:@"Remove saved settings?"]&&[alert.message containsString:@"App data and accounts stay unchanged"]&&[alert.message containsString:@"Unsaved edits"],@"confirmation names permanent saved-settings scope and original input");
    Check(alert.actions.count==2&&alert.actions[0].style==UIAlertActionStyleCancel&&alert.actions[1].style==UIAlertActionStyleDestructive,@"cancel and explicit destructive action are separate");
    UIAlertAction *action=alert.actions[remove?1:0];void (^handler)(UIAlertAction *)=[action valueForKey:@"handler"];
    [editor dismissViewControllerAnimated:NO completion:^{if(remove&&handler)handler(action);done();}];
});}
static void RecoveryControls(void){
    Check([Pending()[@"operation"] isEqual:@"retire"],@"retained work has distinct retirement kind");
    Check(Button(@"socialbox.savedsetups.retry").hidden&&!Button(@"socialbox.savedsetups.retry").enabled&&Button(@"socialbox.savedsetups.reconcile").hidden,@"generic save recovery is hidden and disabled for removal");
    Check(Button(@"socialbox.savedsetups.retryRemoval").enabled&&Button(@"socialbox.savedsetups.reconcileRemoval").enabled&&!Button(@"socialbox.savedsetups.new").enabled,@"removal recovery is explicit and blocks replacement setup");
}
static void DelayedDismissal(void){Create(@"Delayed original removal",^{Select(^{
    SBTestSavedSetupSetMutationBehavior(@"defer");Confirm(YES,^{Await(^BOOL{return [[Browser valueForKey:@"busy"] boolValue]&&SBTestSavedSetupCount(@"execute-retire")==3;},@"actual UI waits for deferred typed removal reply",^{
        UITableViewController *old=Browser;NSString *message=[((UILabel *)Find(old.view,@"socialbox.savedsetups.status")).text copy];
        Check(Navigation.modalInPresentation&&!Button(@"socialbox.savedsetup.remove").enabled&&!Button(@"socialbox.savedsetup.save").enabled,@"busy removal blocks duplicate form actions and ordinary dismissal");
        Slot=Pending();[Navigation dismissViewControllerAnimated:NO completion:^{
            SBTestSavedSetupCompleteDeferred(@"retired",YES);
            After(.1,^{Check([((UILabel *)Find(old.view,@"socialbox.savedsetups.status")).text isEqual:message],@"externally dismissed browser suppresses its late result rendering");
                Open(^{Check(!Pending()&&[Browser.tableView numberOfRowsInSection:0]==0,@"new browser freshly observes completed removal after dismissed callback");
                    NSUInteger stages=SBTestSavedSetupCount(@"stage-retire"),executions=SBTestSavedSetupCount(@"execute-retire");SBTestSavedSetupReplayDeferred();After(.1,^{
                        Check(!Pending()&&SBTestSavedSetupCount(@"stage-retire")==stages&&SBTestSavedSetupCount(@"execute-retire")==executions,@"late duplicate completed reply cannot resurrect or repeat removal");
                        NSDictionary *completed=SBTestSavedSetupRootState()[@"completed"];
                        LBXSendContainerMutationRequest(@"reconcile-retire",@{@"token":NSUUID.UUID.UUIDString.lowercaseString,@"epoch":completed[@"epoch"]},^(NSDictionary *reply){
                            Check([reply[@"result"] isEqual:@"conflict"]&&!Pending(),@"synthetic completed retirement refuses wrong token and never confirms or changes rendering");Finish();
                        });
                    });
                });
            });
        }];
    });});
});});}
static void PublishedStage(void){Create(@"Published original removal",^{Select(^{
    SBTestSavedSetupSetMutationBehavior(@"unknown_stage_published");Confirm(YES,^{Await(^BOOL{return EditorReady()&&Pending()!=nil;},@"lost published stage keeps full original",^{
        Input=SBTestSavedSetupLastStageArguments();Slot=SBTestSavedSetupRootState()[@"pending"];
        Check([Pending()[@"configuration"] isEqual:Original]&&[Slot[@"configuration"] isEqual:Original]&&[Slot[@"expected"] isEqual:Original],@"unknown local input and published token retain exact original document");
        Back(^{RecoveryControls();NSUInteger stages=SBTestSavedSetupCount(@"stage-retire");Tap(@"socialbox.savedsetups.reconcileRemoval");
            Await(^BOOL{return BrowserReady()&&Pending()[@"token"]!=nil;},@"fresh retirement reconciliation requires same-slot retry",^{
                Check([Pending() isEqual:Slot]&&SBTestSavedSetupCount(@"stage-retire")==stages&&SBTestSavedSetupCount(@"execute-retire")==1,@"check neither executes nor regenerates published removal");
                SBTestSavedSetupSetMutationBehavior(@"unconfirmed_saved");Tap(@"socialbox.savedsetups.retryRemoval");
                Await(^BOOL{return BrowserReady()&&Pending()!=nil&&SBTestSavedSetupRecordSnapshot()[Original[@"identifier"]]==nil;},@"lost execution reply preserves work after synthetic retirement effect",^{
                    Check([Pending() isEqual:Slot],@"post-publication uncertainty retains same full token/epoch");
                    [Navigation dismissViewControllerAnimated:NO completion:^{Open(^{RecoveryControls();Tap(@"socialbox.savedsetups.reconcileRemoval");
                        Await(^BOOL{return BrowserReady()&&!Pending()&&[Browser.tableView numberOfRowsInSection:0]==0;},@"fresh exact completed retirement proof clears and reloads",^{
                            Check(SBTestSavedSetupCount(@"stage-retire")==stages&&SBTestSavedSetupCount(@"execute-retire")==2,@"completed check adds no stage or execution");DelayedDismissal();
                        });
                    });}];
                });
            });
        });
    });});
});});}
static void UnpublishedStage(void){Select(^{
    Check(Button(@"socialbox.savedsetup.remove").enabled,@"loaded full saved settings offer removal");
    ((UITextField *)Find(Navigation.topViewController.view,@"socialbox.savedsetup.name")).text=@"unsaved changes must not remove a different document";
    NSUInteger stages=SBTestSavedSetupCount(@"stage-retire");Confirm(NO,^{Check(SBTestSavedSetupCount(@"stage-retire")==stages&&!Pending(),@"cancel sends no retirement mutation");
        SBTestSavedSetupSetMutationBehavior(@"unknown_stage_missing");Confirm(YES,^{Await(^BOOL{return EditorReady()&&Pending()!=nil;},@"unpublished unknown removal keeps original input",^{
            Input=SBTestSavedSetupLastStageArguments();Check([Input[@"expected"] isEqual:Original]&&[Pending()[@"configuration"] isEqual:Original]&&!Pending()[@"token"],@"unsaved edits are excluded and original retained before stage reply");
            Check(!Button(@"socialbox.savedsetup.remove").enabled&&!Button(@"socialbox.savedsetup.save").enabled,@"uncertainty locks both form mutations");
            Back(^{RecoveryControls();NSUInteger executions=SBTestSavedSetupCount(@"execute-retire");
                [Coordinator() retryPendingWithCompletion:^(NSDictionary *reply){Check([reply[@"result"] isEqual:@"conflict"]&&SBTestSavedSetupCount(@"execute-retire")==executions,@"generic save retry cannot execute retained removal");
                    [Navigation dismissViewControllerAnimated:NO completion:^{Open(^{RecoveryControls();
                        Check([Pending()[@"input"] isEqual:Input],@"dismiss/reopen keeps identical input and stable request ID");Tap(@"socialbox.savedsetups.reconcileRemoval");
                        Await(^BOOL{return BrowserReady()&&Pending()!=nil;},@"unpublished removal check finishes without resend",^{
                            Check(SBTestSavedSetupCount(@"stage-retire")==stages+1&&SBTestSavedSetupCount(@"execute-retire")==0,@"same empty epoch does not discard or auto-resend");Tap(@"socialbox.savedsetups.review");
                            Await(^BOOL{return EditorReady();},@"retained original is reviewable",^{
                                Check([((UITextField *)Find(Navigation.topViewController.view,@"socialbox.savedsetup.name")).text isEqual:Original[@"name"]]&&!Button(@"socialbox.savedsetup.remove").enabled&&!Button(@"socialbox.savedsetup.save").enabled,@"review shows exact original with all mutations locked");
                                Back(^{Tap(@"socialbox.savedsetups.retryRemoval");Await(^BOOL{return BrowserReady()&&!Pending()&&[Browser.tableView numberOfRowsInSection:0]==0;},@"explicit same removal retry confirms and hides retired row",^{
                                    Check([SBTestSavedSetupLastStageArguments() isEqual:Input]&&SBTestSavedSetupCount(@"execute-retire")==1,@"retry preserves exact request ID/empty epoch/original values");PublishedStage();
                                });});
                            });
                        });
                    });}];
                }];
            });
        });});
    });
});}
@interface RetirementFixtureApp:NSObject<UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation RetirementFixtureApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;(void)options;Results=[NSMutableDictionary dictionary];SBTestSavedSetupReset();SBTestSavedSetupInitializeRoot();
    Window=[[UIWindow alloc] initWithFrame:CGRectMake(0,0,320,568)];self.window=Window;Host=[UIViewController new];Host.view.backgroundColor=SBInk();Window.rootViewController=Host;[Window makeKeyAndVisible];
    After(.15,^{Open(^{Create(@"Original removal settings",^{UnpublishedStage();});});});return YES;
}
@end
int main(int argc,char *argv[]){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(RetirementFixtureApp.class));}}
