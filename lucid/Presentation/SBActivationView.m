#import "SBActivationView.h"
#import "SBInterfaceCopy.h"
#import "SBDesign.h"
#import "SBSavedContainerSetup.h"
#import "../Authorization/LBXLicenseClient.h"
#import "../Authorization/LBXLicenseIPC.h"
#import "../Containers/LBXContainerRootMutationCoordinator.h"
#include <stdint.h>
static BOOL StrictBoolean(id value){return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID();}

@interface SBActivationView () <UITextFieldDelegate>
@property(nonatomic,strong) UITextField *keyField;
@property(nonatomic,strong) UIButton *submit;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIButton *setups;
@property(nonatomic) BOOL pending,verified;
@property(nonatomic) uint64_t attempt;
@property(nonatomic) NSUInteger phase;
@property(nonatomic,strong) LBXContainerRootMutationCoordinator *readiness;
@end
@implementation SBActivationView
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])) {
        self.axis=UILayoutConstraintAxisVertical;self.spacing=14;
        self.accessibilityIdentifier=@"socialbox.activation";
        _keyField=[UITextField new];_keyField.delegate=self;_keyField.textColor=UIColor.whiteColor;
        _keyField.backgroundColor=[UIColor colorWithWhite:.11 alpha:1];_keyField.borderStyle=UITextBorderStyleRoundedRect;
        _keyField.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];_keyField.adjustsFontForContentSizeCategory=YES;
        _keyField.autocorrectionType=UITextAutocorrectionTypeNo;_keyField.spellCheckingType=UITextSpellCheckingTypeNo;
        _keyField.autocapitalizationType=UITextAutocapitalizationTypeAllCharacters;_keyField.returnKeyType=UIReturnKeyGo;
        _keyField.attributedPlaceholder=[[NSAttributedString alloc] initWithString:SBUIText(@"license.placeholder") attributes:@{NSForegroundColorAttributeName:UIColor.lightGrayColor}];
        _keyField.accessibilityLabel=SBUIText(@"license.placeholder");_keyField.accessibilityIdentifier=@"socialbox.activation.key";
        [_keyField.heightAnchor constraintGreaterThanOrEqualToConstant:52].active=YES;
        UIButtonConfiguration *configuration=UIButtonConfiguration.filledButtonConfiguration;
        configuration.title=SBUIText(@"license.activate");configuration.baseBackgroundColor=[UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1];
        configuration.baseForegroundColor=[UIColor colorWithWhite:.05 alpha:1];configuration.contentInsets=NSDirectionalEdgeInsetsMake(15,18,15,18);
        __weak typeof(self) weak=self;
        _submit=[UIButton buttonWithConfiguration:configuration primaryAction:[UIAction actionWithHandler:^(__unused UIAction *action){[weak activate];}]];
        _submit.accessibilityIdentifier=@"socialbox.control.license.button";
        _status=[UILabel new];_status.numberOfLines=0;_status.textColor=UIColor.lightGrayColor;
        _status.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];_status.adjustsFontForContentSizeCategory=YES;
        _status.accessibilityIdentifier=@"socialbox.activation.status";_status.hidden=YES;
        _setups=SBButton(SBSavedContainerSetupEntryTitle(),@"containers",NO,^{
            SBActivationView *view=weak;if(!view||view.pending||!view.verified)return;
            for(UIResponder *responder=view.nextResponder;responder;responder=responder.nextResponder)
                if([responder isKindOfClass:UIViewController.class]){SBPresentSavedContainerSetups((UIViewController *)responder);break;}
        });_setups.accessibilityIdentifier=@"socialbox.activation.savedsetups";_setups.hidden=YES;
        [self addArrangedSubview:_keyField];[self addArrangedSubview:_submit];[self addArrangedSubview:_status];[self addArrangedSubview:_setups];
    }return self;
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField {(void)textField;[self activate];return NO;}
- (void)finishWithText:(NSString *)text ready:(BOOL)ready {
    self.pending=NO;self.phase=0;self.readiness=nil;
    self.submit.enabled=YES;self.keyField.enabled=YES;
    self.status.text=text;self.verified=ready;self.setups.hidden=!ready;
    if(ready)self.keyField.text=@"";
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,self.status.text);
}
- (void)activate {
    if(self.pending)return;
    self.verified=NO;self.setups.hidden=YES;
    NSString *key=self.keyField.text?:@"";
    self.status.hidden=NO;
    NSDictionary *request=LBXLicenseIPCRequest(@"activate",key);
    if(!request){[self finishWithText:SBUIText(@"license.invalidFormat") ready:NO];return;}
    if(self.attempt==UINT64_MAX){[self finishWithText:SBUIText(@"license.serviceUnavailable") ready:NO];return;}
    uint64_t attempt=++self.attempt;self.phase=1;
    self.pending=YES;self.submit.enabled=NO;self.keyField.enabled=NO;[self.keyField resignFirstResponder];
    self.status.text=SBUIText(@"license.checking");
    __weak typeof(self) weak=self;
    LBXSendLicenseRequest(@"activate",key,^(NSDictionary *reply){
        dispatch_async(dispatch_get_main_queue(),^{
            SBActivationView *view=weak;if(!view||!view.pending||view.attempt!=attempt||view.phase!=1)return;
            view.phase=2;
            // The fixed production client authenticates the peer and request ID.
            // Recheck typed semantics without creating another transport/grant.
            NSMutableDictionary *shape=[request mutableCopy];
            shape[@"requestID"]=[reply isKindOfClass:NSDictionary.class]?reply[@"requestID"]?:@"":@"";
            NSString *result=LBXLicenseIPCValidateReply(reply,shape,LBXLicenseIPCClock())?reply[@"result"]:@"service_unavailable";
            NSDictionary *messages=@{@"revoked":SBUIText(@"license.revoked"),@"expired":SBUIText(@"license.expired"),@"invalid":SBUIText(@"license.invalid"),
                @"busy":SBUIText(@"license.busy"),@"paired_key_mismatch":SBUIText(@"license.pairedKeyMismatch"),@"recovery_required":SBUIText(@"license.recoveryRequired"),
                @"storage_unavailable":SBUIText(@"license.storageUnavailable"),@"verification_failed":SBUIText(@"license.verificationFailed")};
            if(![result isEqual:@"active"]){[view finishWithText:messages[result]?:SBUIText(@"license.serviceUnavailable") ready:NO];return;}
            view.status.text=SBUIText(@"license.checkingSetups");
            view.readiness=[LBXContainerRootMutationCoordinator coordinator];
            [view.readiness refreshWithCompletion:^(NSDictionary *state){
                SBActivationView *current=weak;if(!current||!current.pending||current.attempt!=attempt||current.phase!=2)return;
                // Readiness observes existing authenticated state only. Pending
                // metadata may be reviewed in the browser; it is never executed here.
                BOOL ready=[state[@"result"] isEqual:@"status"]&&
                    StrictBoolean(state[@"stateAvailable"])&&[state[@"stateAvailable"] boolValue]&&
                    StrictBoolean(state[@"runtimeAccepted"])&&![state[@"runtimeAccepted"] boolValue];
                NSString *message=ready?SBUIText(@"license.verifiedBuildBlocked"):
                    [state[@"result"] isEqual:@"authorization_required"]?SBUIText(@"license.verificationFailed"):SBUIText(@"license.setupsUnavailable");
                [current finishWithText:message ready:ready];
            }];
            // A verified cloud response does not implement retained-engine
            // admission. No original success callback/navigation is invoked.
        });
    });
}
@end
