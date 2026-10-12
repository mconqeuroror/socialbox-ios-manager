// The production form and coordinator, with typed synthetic service replies.
// No website/device/installer authority is represented by this fixture.
#import <UIKit/UIKit.h>
#import "SBActivationView.h"
#import "SBDesign.h"
#import "activation_transport_fixture.h"
#import "saved_setup_transport_fixture.h"
static NSUInteger Checks,Failures;
static NSMutableDictionary *Results;
static UIWindow *Window;
static UIViewController *Host;
static SBActivationView *Form;
static NSString *const Key=@"AAAA-BBBB-CCCC-DDDD";
void MSHookMessageEx(Class cls,SEL sel,IMP replacement,IMP *original){(void)cls;(void)sel;(void)replacement;(void)original;abort();}
static void Check(BOOL value,NSString *name){Checks++;if(!value)Failures++;Results[[NSString stringWithFormat:@"%04lu %@",(unsigned long)Checks,name]]=@(value);}
static UIView *Find(UIView *root,NSString *name){if([root.accessibilityIdentifier isEqual:name])return root;for(UIView *child in root.subviews){UIView *found=Find(child,name);if(found)return found;}return nil;}
static UITextField *Field(void){return (UITextField *)Find(Form,@"socialbox.activation.key");}
static UIButton *Submit(void){return (UIButton *)Find(Form,@"socialbox.control.license.button");}
static UIButton *Entry(void){return (UIButton *)Find(Form,@"socialbox.activation.savedsetups");}
static NSString *Status(void){return ((UILabel *)Find(Form,@"socialbox.activation.status")).text;}
static BOOL Pending(void){return [[Form valueForKey:@"pending"] boolValue];}
static void Finish(void){NSDictionary *report=@{@"ok":@(Failures==0),@"assertions":@(Checks),@"failures":@(Failures),@"results":Results,
    @"scope":@"Production activation form/coordinator; typed synthetic service replies only. Actual website/device/installer/runtime NOT_RUN"};
    NSString *directory=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES) firstObject];
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[directory stringByAppendingPathComponent:@"presentation-result.json"] atomically:YES];}
static void AwaitUntil(BOOL (^ready)(void),void (^action)(void),double deadline){if(ready()){action();return;}if(NSProcessInfo.processInfo.systemUptime>=deadline){Check(NO,@"bounded asynchronous form completion");Finish();return;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/50),dispatch_get_main_queue(),^{AwaitUntil(ready,action,deadline);});}
static void Await(BOOL (^ready)(void),void (^action)(void)){AwaitUntil(ready,action,NSProcessInfo.processInfo.systemUptime+4);}
static void Fresh(void){[Form removeFromSuperview];Form=[SBActivationView new];Form.translatesAutoresizingMaskIntoConstraints=NO;[Host.view addSubview:Form];
    [NSLayoutConstraint activateConstraints:@[[Form.leadingAnchor constraintEqualToAnchor:Host.view.leadingAnchor constant:20],
        [Form.trailingAnchor constraintEqualToAnchor:Host.view.trailingAnchor constant:-20],[Form.topAnchor constraintEqualToAnchor:Host.view.safeAreaLayoutGuide.topAnchor constant:20]]];}
static void Start(void){Field().text=Key;[Submit() sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];}
static void VerifyNoWrites(void){for(NSString *name in @[@"stage-create",@"stage-update",@"execute",@"reconcile",@"candidate-generation",@"legacy.create",@"legacy.update"])
    Check(SBTestSavedSetupCount(name)==0,[@"activation performs no metadata mutation: " stringByAppendingString:name]);}
static void ReadyAndLostAdmission(void){SBTestSavedSetupInitializeRoot();Fresh();Start();SBTestLicenseComplete(@"active");
    Await(^BOOL{return !Pending();},^{
        Check(!Entry().hidden&&Field().text.length==0&&Submit().enabled&&Field().enabled,@"ready authenticated state reveals entry and clears code");
        Check([Status() containsString:@"Saved setups are available below"]&&[Status() containsString:@"Opening protected apps requires"],@"ready copy distinguishes saved settings from protected app support");
        NSUInteger reads=SBTestSavedSetupCount(@"status"),validations=SBTestSavedSetupValidateCount();SBTestLicenseReplay();
        dispatch_async(dispatch_get_main_queue(),^{
            Check(!Pending()&&SBTestSavedSetupCount(@"status")==reads&&SBTestSavedSetupValidateCount()==validations&&!Entry().hidden,@"duplicate completed activation cannot recheck state or change readiness");
            Start();SBTestLicenseReplay(); // A late prior attempt arrives during this new request.
            dispatch_async(dispatch_get_main_queue(),^{
                Check(Pending()&&Entry().hidden&&[Field().text isEqual:Key]&&SBTestSavedSetupCount(@"status")==reads,@"late old activation cannot complete or authorize a new attempt");
                SBTestSavedSetupSetLicenseResult(@"revoked");SBTestLicenseComplete(@"active");
                Await(^BOOL{return !Pending();},^{
                    Check(Entry().hidden&&[Field().text isEqual:Key]&&[Status() containsString:@"could not be verified"],@"revocation between code check and readiness keeps code and blocks entry");
                    Check(SBTestSavedSetupCount(@"status")==reads,@"denied fresh validation never asks for authenticated setup status");
                    SBTestSavedSetupSetLicenseResult(@"active");Start();SBTestLicenseComplete(@"active");
                    Await(^BOOL{return !Pending();},^{Check(!Entry().hidden&&Field().text.length==0,@"fresh explicit retry can confirm existing ready namespace");
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/3),dispatch_get_main_queue(),^{
                        [Window layoutIfNeeded];UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:Window.bounds];
                        NSData *image=[renderer PNGDataWithActions:^(__unused UIGraphicsImageRendererContext *context){[Window drawViewHierarchyInRect:Window.bounds afterScreenUpdates:YES];}];
                        NSString *directory=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES) firstObject];[image writeToFile:[directory stringByAppendingPathComponent:@"activation-ready.png"] atomically:YES];
                        VerifyNoWrites();Finish();});
                    });
                });
            });
        });
    });
}
static void MissingSetup(void){SBTestSavedSetupReset();Fresh();Start();SBTestLicenseComplete(@"active");
    Await(^BOOL{return !Pending();},^{
        Check(Entry().hidden&&[Field().text isEqual:Key]&&Submit().enabled&&Field().enabled,@"successful code with unavailable metadata keeps exact entry and permits retry");
        Check([Status() containsString:@"Saved setups are unavailable"]&&[Status() containsString:@"Tap Verify license"],@"missing setup has separate actionable support copy");
        Check(!SBTestSavedSetupRootState()&&SBTestSavedSetupValidateCount()==1&&SBTestSavedSetupCount(@"status")==1,@"readiness observes existing state once without bootstrapping missing storage");
        VerifyNoWrites();ReadyAndLostAdmission();
    });
}
static void Denials(NSUInteger index){NSArray *cases=@[
    @[@{@"result":@"revoked"},@"has been revoked"],@[@{@"result":@"expired"},@"has expired"],@[@{@"result":@"invalid"},@"not valid"],
    @[@{@"result":@"busy"},@"in progress"],@[@{@"result":@"paired_key_mismatch"},@"different key"],@[@{@"result":@"recovery_required"},@"could not be paired"],
    @[@{@"result":@"storage_unavailable"},@"saved license"],@[@{@"result":@"verification_failed"},@"could not be verified"],@[@{@"result":@"service_unavailable"},@"service is unavailable"],
    @[@{@"result":@"foreign remote secret=private"},@"service is unavailable"],@[@{@"engineAuthorized":@YES},@"service is unavailable"],
    @[@{@"paired":@1},@"service is unavailable"],@[@{@"paired":@NO},@"service is unavailable"],@[@{@"requestID":@"broken"},@"service is unavailable"],
    @[@{@"extra":@"private"},@"service is unavailable"]];
    if(index==cases.count){MissingSetup();return;}Fresh();NSUInteger validations=SBTestSavedSetupValidateCount(),requests=SBTestLicenseRequestCount();Start();
    [Field().delegate textFieldShouldReturn:Field()];Check(Pending()&&!Submit().enabled&&!Field().enabled&&Entry().hidden&&SBTestLicenseRequestCount()==requests+1,@"one request disables duplicate form submissions");
    SBTestLicenseCompleteFields(cases[index][0]);Await(^BOOL{return !Pending();},^{
        Check(Entry().hidden&&[Field().text isEqual:Key]&&Submit().enabled&&Field().enabled,@"denial or malformed reply keeps exact code and closes entry");
        Check([Status() containsString:cases[index][1]]&&![Status() containsString:@"private"],@"form renders known support text without remote private text");
        Check(SBTestSavedSetupValidateCount()==validations,@"denied activation does not start readiness chain");Denials(index+1);
    });
}
@interface ActivationFixtureApp:NSObject<UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation ActivationFixtureApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options{(void)application;(void)options;Results=[NSMutableDictionary dictionary];SBTestSavedSetupReset();
    Window=[[UIWindow alloc] initWithFrame:CGRectMake(0,0,320,568)];self.window=Window;Host=[UIViewController new];Host.view.backgroundColor=SBInk();Window.rootViewController=Host;[Window makeKeyAndVisible];
    Fresh();NSUInteger requests=SBTestLicenseRequestCount();Check(!Pending()&&Entry().hidden&&requests==0&&SBTestSavedSetupValidateCount()==0,@"rendering form sends no requests and offers no saved-setup grant");
    Field().text=@"invalid";[Field().delegate textFieldShouldReturn:Field()];Check(SBTestLicenseRequestCount()==requests&&[Field().text isEqual:@"invalid"]&&[Status() containsString:@"complete license key"],@"invalid input stays local and retains text");
    dispatch_async(dispatch_get_main_queue(),^{Denials(0);});return YES;}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(ActivationFixtureApp.class));}}
