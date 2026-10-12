#import "SBSavedContainerSetup.h"
#import "SBDesign.h"
#import "../Containers/LBXContainerConfiguration.h"
#import "../Containers/LBXContainerRootMutationCoordinator.h"
#include <math.h>

NSString *SBSavedContainerSetupEntryTitle(void) { return @"Saved setups"; }

// Keep an uncertain first-stage request in this app instance across dismissal.
// This memory is rendering/retry intent, never a root epoch or license grant.
// Process restart obtains durable pending state through authenticated refresh.
static LBXContainerRootMutationCoordinator *SetupCoordinator(void) {
    static LBXContainerRootMutationCoordinator *coordinator;static dispatch_once_t once;
    dispatch_once(&once,^{coordinator=[LBXContainerRootMutationCoordinator coordinator];});
    return coordinator;
}

static NSArray<NSString *> *SetupApplications(void) {
    return @[@"com.burbn.instagram",@"com.facebook.Facebook",@"com.atebits.Tweetie2"];
}
static NSString *SetupAppName(NSString *identifier) {
    return @{@"com.burbn.instagram":@"Instagram",@"com.facebook.Facebook":@"Facebook",@"com.atebits.Tweetie2":@"Twitter"}[identifier] ?: @"Requested app";
}
static NSArray<NSArray<NSString *> *> *SetupIdentifiers(void) {
    return @[@[@"serialNumber",@"Serial number",@"10–12 letters or digits"],
        @[@"udid",@"UDID",@"40 hex characters or XXXXXXXX-XXXXXXXXXXXXXXXX"],
        @[@"idfa",@"Advertising identifier",@"UUID"],@[@"idfv",@"Vendor identifier",@"UUID"],
        @[@"platformUUID",@"Platform identifier",@"UUID"],@[@"wifiMac",@"Wi-Fi address",@"AA:BB:CC:DD:EE:FF"],
        @[@"bluetoothMac",@"Bluetooth address",@"AA:BB:CC:DD:EE:FF"],
        @[@"imei",@"IMEI",@"15 digits with a valid check digit"],
        @[@"meid",@"MEID",@"14 hex characters"],@[@"iccid",@"ICCID",@"19–20 digits with a valid check digit"]];
}
static UIStackView *SetupStack(NSArray<UIView *> *views,CGFloat spacing) {
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:views];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=spacing;return stack;
}
static UIView *SetupPanel(UIView *body) {
    UIView *panel=[UIView new];panel.backgroundColor=SBPanel();panel.layer.cornerRadius=12;
    body.translatesAutoresizingMaskIntoConstraints=NO;[panel addSubview:body];
    [NSLayoutConstraint activateConstraints:@[[body.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:14],
        [body.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-14],
        [body.topAnchor constraintEqualToAnchor:panel.topAnchor constant:14],
        [body.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-14]]];return panel;
}
static UITextField *SetupField(NSString *title,NSString *identifier) {
    UITextField *field=[UITextField new];field.textColor=UIColor.whiteColor;field.backgroundColor=SBPanel();
    field.borderStyle=UITextBorderStyleRoundedRect;field.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    field.adjustsFontForContentSizeCategory=YES;field.autocorrectionType=UITextAutocorrectionTypeNo;
    field.spellCheckingType=UITextSpellCheckingTypeNo;field.autocapitalizationType=UITextAutocapitalizationTypeNone;
    field.smartQuotesType=UITextSmartQuotesTypeNo;field.smartDashesType=UITextSmartDashesTypeNo;field.smartInsertDeleteType=UITextSmartInsertDeleteTypeNo;
    field.keyboardType=UIKeyboardTypeASCIICapable;field.returnKeyType=UIReturnKeyNext;
    field.accessibilityLabel=title;field.accessibilityIdentifier=identifier;
    field.attributedPlaceholder=[[NSAttributedString alloc] initWithString:title attributes:@{NSForegroundColorAttributeName:SBMuted()}];
    [field.heightAnchor constraintGreaterThanOrEqualToConstant:48].active=YES;return field;
}

@interface SBSetupEditor : UIViewController<UITextFieldDelegate>
@property(nonatomic,strong) LBXContainerConfiguration *configuration;
@property(nonatomic,strong) UITextField *nameField;
@property(nonatomic,strong) NSDictionary<NSString *,UITextField *> *identifierFields;
@property(nonatomic,strong) NSDictionary<NSString *,UISwitch *> *appSwitches;
@property(nonatomic,strong) UISegmentedControl *identifierMode;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIScrollView *scroll;
@property(nonatomic,strong) UIButton *save,*remove;
@property(nonatomic) BOOL locked,busy;
@property(nonatomic,copy) void (^saveChoices)(NSString *,NSArray<NSString *> *,NSDictionary<NSString *,NSString *> *);
@property(nonatomic,copy) void (^removeSettings)(void);
- (void)setMessage:(NSString *)message busy:(BOOL)busy locked:(BOOL)locked;
@end

@interface SBSavedSetupBrowser : UITableViewController
@property(nonatomic,strong) LBXContainerRootMutationCoordinator *coordinator;
@property(nonatomic,strong) NSArray<NSDictionary *> *entries;
@property(nonatomic,copy) NSString *next;
@property(nonatomic,strong) NSDictionary *pending;
@property(nonatomic,strong) UIView *header;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIButton *reloadButton,*creationButton,*moreButton,*verifyButton,*reconcileButton,*retryButton,*reviewButton,*reconcileRemovalButton,*retryRemovalButton;
@property(nonatomic) BOOL busy,journalUnavailable;
@property(nonatomic) uint64_t actionGeneration;
@property(nonatomic,weak) SBSetupEditor *editor;
@end
@implementation SBSavedSetupBrowser
- (void)viewDidLoad {
    [super viewDidLoad];self.title=SBSavedContainerSetupEntryTitle();self.entries=@[];self.next=@"";
    self.view.accessibilityIdentifier=@"socialbox.savedsetups";self.view.backgroundColor=SBInk();self.tableView.backgroundColor=SBInk();
    self.tableView.separatorColor=[SBMuted() colorWithAlphaComponent:.15];self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=82;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Done" style:UIBarButtonItemStyleDone target:self action:@selector(close)];
    UILabel *title=SBLabel(@"Awaiting app support",13,UIFontWeightBold);title.textColor=SBAccent();
    UILabel *detail=SBLabel(@"These are saved choices. They cannot open or switch apps yet.",15,UIFontWeightRegular);detail.textColor=SBMuted();
    self.status=SBLabel(@"",15,UIFontWeightRegular);self.status.textColor=SBMuted();self.status.accessibilityIdentifier=@"socialbox.savedsetups.status";
    __weak typeof(self) weak=self;
    self.creationButton=SBButton(@"New saved setup",@"plus",YES,^{[weak newSetup];});self.creationButton.accessibilityIdentifier=@"socialbox.savedsetups.new";
    self.reloadButton=SBButton(@"Reload saved setups",@"containers",NO,^{[weak loadPageAfter:@""];});self.reloadButton.accessibilityIdentifier=@"socialbox.savedsetups.reload";
    self.moreButton=SBButton(@"Load more",@"containers",NO,^{[weak loadPageAfter:weak.next];});self.moreButton.accessibilityIdentifier=@"socialbox.savedsetups.more";
    self.verifyButton=SBButton(@"Verify saved license",@"settings",NO,^{[weak verify];});self.verifyButton.accessibilityIdentifier=@"socialbox.savedsetups.verify";
    self.reconcileButton=SBButton(@"Check unconfirmed save",@"containers",YES,^{[weak reconcile];});self.reconcileButton.accessibilityIdentifier=@"socialbox.savedsetups.reconcile";
    self.retryButton=SBButton(@"Retry the same save",@"containers",NO,^{[weak retry];});self.retryButton.accessibilityIdentifier=@"socialbox.savedsetups.retry";
    self.reconcileRemovalButton=SBButton(@"Check unconfirmed removal",@"containers",YES,^{[weak reconcileRemoval];});self.reconcileRemovalButton.accessibilityIdentifier=@"socialbox.savedsetups.reconcileRemoval";
    self.retryRemovalButton=SBButton(@"Retry the same removal",@"containers",NO,^{[weak retryRemoval];});self.retryRemovalButton.accessibilityIdentifier=@"socialbox.savedsetups.retryRemoval";
    self.reviewButton=SBButton(@"Review unconfirmed setup",@"containers",NO,^{[weak reviewPending];});self.reviewButton.accessibilityIdentifier=@"socialbox.savedsetups.review";
    UIStackView *stack=SetupStack(@[title,detail,self.status,self.reconcileButton,self.retryButton,self.reconcileRemovalButton,self.retryRemovalButton,self.reviewButton,self.creationButton,self.reloadButton,self.moreButton,self.verifyButton],10);
    self.header=[UIView new];stack.translatesAutoresizingMaskIntoConstraints=NO;[self.header addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:self.header.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:self.header.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:self.header.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:self.header.bottomAnchor constant:-20]]];self.tableView.tableHeaderView=self.header;
    // UI assembly reads no private files or local role and cannot initialize
    // missing service state. Until authenticated refresh, mutations stay closed.
    self.coordinator=SetupCoordinator();
    [self synchronizePending];[self updateControls];
    if(self.coordinator)[self refreshState];
    else[self setMessage:@"Saved setups are unavailable. Install a compatible update or contact support."];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];CGFloat width=self.tableView.bounds.size.width;if(width<=0)return;
    CGSize size=[self.header systemLayoutSizeFittingSize:CGSizeMake(width,UILayoutFittingCompressedSize.height)
        withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGRect frame=CGRectMake(0,0,width,ceil(size.height));if(!CGRectEqualToRect(self.header.frame,frame)){self.header.frame=frame;self.tableView.tableHeaderView=self.header;}
}
- (void)setMessage:(NSString *)message {
    self.status.text=message ?: @"";self.status.hidden=!message.length;[self.view setNeedsLayout];
    if(message.length)UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,message);
}
- (void)synchronizePending {
    NSError *error=nil;self.pending=self.coordinator?[self.coordinator pendingMutation:&error]:nil;
    self.journalUnavailable=!self.coordinator||error!=nil||![self.coordinator.safeStatus[@"stateAvailable"] boolValue];
}
- (void)updateControls {
    BOOL available=self.coordinator&&!self.busy;
    self.creationButton.enabled=available&&!self.journalUnavailable&&!self.pending;
    self.reloadButton.enabled=available;self.moreButton.enabled=available&&self.next.length;self.moreButton.hidden=!self.next.length;
    self.verifyButton.enabled=available;
    BOOL retirement=[self.pending[@"operation"] isEqual:@"retire"];
    for(UIButton *button in @[self.reconcileButton,self.retryButton]){button.hidden=!self.pending||retirement;button.enabled=available&&self.pending!=nil&&!retirement;}
    for(UIButton *button in @[self.reconcileRemovalButton,self.retryRemovalButton]){button.hidden=!retirement;button.enabled=available&&retirement;}
    BOOL reviewable=[LBXContainerConfiguration fromDictionary:self.pending[@"configuration"] error:nil]!=nil;
    self.reviewButton.hidden=!reviewable;self.reviewButton.enabled=available&&reviewable;
    self.navigationItem.rightBarButtonItem.enabled=!self.busy;self.navigationController.modalInPresentation=self.busy;
    self.tableView.allowsSelection=available&&!self.journalUnavailable;[self.view setNeedsLayout];
}
- (BOOL)beginWithMessage:(NSString *)message {
    if(self.busy||!self.coordinator||self.actionGeneration==UINT64_MAX)return NO;
    self.actionGeneration++;self.busy=YES;[self setMessage:message];[self updateControls];return YES;
}
- (BOOL)acceptGeneration:(uint64_t)generation {
    return self.busy&&generation==self.actionGeneration&&[self.navigationController.viewControllers containsObject:self]&&
        self.navigationController.presentingViewController&&self.navigationController.viewIfLoaded.window&&!self.navigationController.isBeingDismissed;
}
- (NSString *)messageForResult:(NSString *)result {
    if([result isEqual:@"saved"])return @"Setup saved. Awaiting app support.";
    if([result isEqual:@"listed"])return @"Saved choices only. Awaiting app support.";
    if([result isEqual:@"record"])return @"Saved setup loaded. Awaiting app support.";
    if([result isEqual:@"status"])return @"Saved setup state checked.";
    if([result isEqual:@"active"])return @"License verified.";
    if([result isEqual:@"retry_required"])return @"This save is not confirmed. The same request has been kept for retry.";
    if([result isEqual:@"retired"])return @"Saved settings removed. App data and accounts are unchanged.";
    if([result isEqual:@"retirement_retry_required"])return @"Removal is not confirmed. The original settings and same request have been kept for retry.";
    if([result isEqual:@"conflict"])return @"These settings differ or cannot be changed by this request. Any unconfirmed request has been kept for review.";
    if([result isEqual:@"authorization_required"])return @"Verify your license to continue. Any unconfirmed request has been kept.";
    if([result isEqual:@"state_unavailable"])return @"Saved setup state is unavailable. Verify or reload to check again; it has not been reset.";
    if([result isEqual:@"busy"])return @"Another setup request is in progress. Try again shortly.";
    if([result isEqual:@"invalid_request"])return @"Check the setup name, app selection and identifier formats.";
    if([result isEqual:@"no_pending"])return @"There is no unconfirmed request.";
    return @"This request could not be confirmed. Your saved choices have not been reset.";
}
- (void)completeReply:(NSDictionary *)reply {
    self.busy=NO;[self synchronizePending];[self updateControls];
    NSString *result=[reply[@"result"] isKindOfClass:NSString.class]?reply[@"result"]:@"unconfirmed";
    [self setMessage:[self messageForResult:result]];
}
- (void)refreshState {
    if(![self beginWithMessage:@"Checking saved setup state…"])return;uint64_t generation=self.actionGeneration;__weak typeof(self) weak=self;
    [self.coordinator refreshWithCompletion:^(NSDictionary *reply){dispatch_async(dispatch_get_main_queue(),^{
        SBSavedSetupBrowser *browser=weak;if(![browser acceptGeneration:generation])return;[browser completeReply:reply];
        if([reply[@"result"] isEqual:@"status"]&&[reply[@"stateAvailable"] boolValue])[browser loadPageAfter:@""];
    });}];
}
- (void)loadPageAfter:(NSString *)after {
    NSString *cursor=[after copy] ?: @"";if(![self beginWithMessage:@"Loading saved setups…"])return;
    uint64_t generation=self.actionGeneration;__weak typeof(self) weak=self;
    [self.coordinator listAfter:cursor completion:^(NSDictionary *reply){dispatch_async(dispatch_get_main_queue(),^{
        SBSavedSetupBrowser *browser=weak;if(![browser acceptGeneration:generation])return;[browser completeReply:reply];
        if([reply[@"result"] isEqual:@"listed"]){
            NSMutableArray *entries=cursor.length?[browser.entries mutableCopy]:[NSMutableArray array];
            NSMutableSet *identifiers=[NSMutableSet set];for(NSDictionary *entry in entries)[identifiers addObject:entry[@"identifier"]];
            for(NSDictionary *entry in reply[@"entries"])if(![identifiers containsObject:entry[@"identifier"]]){[entries addObject:entry];[identifiers addObject:entry[@"identifier"]];}
            browser.entries=[entries copy];browser.next=[reply[@"next"] copy];[browser.tableView reloadData];[browser updateControls];
            [browser setMessage:browser.pending?@"An earlier request needs checking before another setup can be changed.":browser.entries.count?@"Saved choices only. Awaiting app support.":@"No saved setups yet."];
        }
    });}];
}
- (void)showEditorForConfiguration:(LBXContainerConfiguration *)configuration locked:(BOOL)locked {
    if(self.busy)return;
    SBSetupEditor *editor=[SBSetupEditor new];editor.configuration=configuration;self.editor=editor;
    __weak typeof(self) weak=self;__weak SBSetupEditor *weakEditor=editor;
    editor.saveChoices=^(NSString *name,NSArray<NSString *> *applications,NSDictionary<NSString *,NSString *> *manual){
        SBSavedSetupBrowser *browser=weak;SBSetupEditor *form=weakEditor;if(!browser||!form||browser.editor!=form||browser.navigationController.topViewController!=form||browser.busy||browser.pending||browser.journalUnavailable)return;
        if(![browser beginWithMessage:@"Saving setup…"])return;[form setMessage:@"Saving setup…" busy:YES locked:NO];
        uint64_t generation=browser.actionGeneration;
        void (^completion)(NSDictionary *)=^(NSDictionary *reply){dispatch_async(dispatch_get_main_queue(),^{
            SBSavedSetupBrowser *current=weak;SBSetupEditor *view=weakEditor;if(![current acceptGeneration:generation]||current.editor!=view||current.navigationController.topViewController!=view)return;
            [current completeReply:reply];NSString *result=reply[@"result"];
            if([result isEqual:@"saved"]){
                [current.navigationController popToViewController:current animated:YES];current.editor=nil;
                [current loadPageAfter:@""];
            }else {
                [view setMessage:[current messageForResult:result] busy:NO locked:current.pending!=nil||current.journalUnavailable];
            }
        });};
        if(configuration)[browser.coordinator beginUpdateOfConfiguration:configuration name:name applications:applications manualIdentifiers:manual completion:completion];
        else[browser.coordinator beginCreationWithChoices:@{@"name":name,@"applications":applications,@"manualIdentifiers":manual ?: (id)NSNull.null,@"proxyReference":@""} completion:completion];
    };
    editor.removeSettings=^{
        SBSavedSetupBrowser *browser=weak;SBSetupEditor *form=weakEditor;
        [browser synchronizePending];[browser updateControls];
        if(!configuration||!form||browser.editor!=form||browser.navigationController.topViewController!=form||browser.busy||browser.pending||browser.journalUnavailable)return;
        if(![browser beginWithMessage:@"Checking and removing saved settings…"])return;
        uint64_t generation=browser.actionGeneration;[form setMessage:@"Checking and removing saved settings…" busy:YES locked:NO];
        [browser.coordinator beginRetirementOfConfiguration:configuration completion:^(NSDictionary *reply){dispatch_async(dispatch_get_main_queue(),^{
            SBSavedSetupBrowser *current=weak;SBSetupEditor *view=weakEditor;
            if(![current acceptGeneration:generation]||current.editor!=view||current.navigationController.topViewController!=view)return;
            [current completeReply:reply];
            if([reply[@"result"] isEqual:@"retired"]){[view setMessage:[current messageForResult:@"retired"] busy:NO locked:YES];
                [current.navigationController popToViewController:current animated:YES];current.editor=nil;[current loadPageAfter:@""];
            }else [view setMessage:[current messageForResult:reply[@"result"]] busy:NO locked:current.pending!=nil||current.journalUnavailable];
        });}];
    };
    [self.navigationController pushViewController:editor animated:YES];
    [editor setMessage:locked?([self.pending[@"operation"] isEqual:@"retire"]?@"These original settings belong to an unconfirmed removal. Check or retry the same removal from Saved setups.":@"This is the unconfirmed setup. Check or retry the same save from Saved setups."):@"" busy:NO locked:locked];
}
- (void)newSetup {
    [self synchronizePending];[self updateControls];if(self.pending||self.journalUnavailable||self.busy)return;[self showEditorForConfiguration:nil locked:NO];
}
- (void)reviewPending {
    [self synchronizePending];[self updateControls];if(self.busy||!self.pending)return;
    LBXContainerConfiguration *configuration=[LBXContainerConfiguration fromDictionary:self.pending[@"configuration"] error:nil];
    if(configuration)[self showEditorForConfiguration:configuration locked:YES];
    else[self setMessage:@"The same save request is kept. Check it before starting another setup."];
}
- (void)verify {
    if(![self beginWithMessage:@"Verifying saved license…"])return;uint64_t generation=self.actionGeneration;__weak typeof(self) weak=self;
    [self.coordinator validateWithCompletion:^(NSDictionary *reply){dispatch_async(dispatch_get_main_queue(),^{SBSavedSetupBrowser *browser=weak;if(![browser acceptGeneration:generation])return;[browser completeReply:reply];if([reply[@"result"] isEqual:@"active"])[browser setMessage:@"License verified. Reload saved setups or check the unconfirmed request."];});}];
}
- (void)reconcile {
    [self pendingAction:NO retirement:NO];
}
- (void)retry {
    [self pendingAction:YES retirement:NO];
}
- (void)reconcileRemoval {[self pendingAction:NO retirement:YES];}
- (void)retryRemoval {[self pendingAction:YES retirement:YES];}
- (void)pendingAction:(BOOL)retry retirement:(BOOL)retire {
    [self synchronizePending];[self updateControls];
    if(!self.pending||retire!=[self.pending[@"operation"] isEqual:@"retire"])return;
    if(![self beginWithMessage:retire?@"Checking the same removal…":@"Checking the same save…"])return;
    uint64_t generation=self.actionGeneration;__weak typeof(self) weak=self;
    void (^completion)(NSDictionary *)=^(NSDictionary *reply){dispatch_async(dispatch_get_main_queue(),^{
        SBSavedSetupBrowser *browser=weak;if(![browser acceptGeneration:generation])return;[browser completeReply:reply];
        if([reply[@"result"] isEqual:retire?@"retired":@"saved"])[browser loadPageAfter:@""];
    });};
    if(retire){if(retry)[self.coordinator retryRetirementWithCompletion:completion];else[self.coordinator reconcileRetirementWithCompletion:completion];}
    else {if(retry)[self.coordinator retryPendingWithCompletion:completion];else[self.coordinator reconcilePendingWithCompletion:completion];}
}
- (void)close {if(!self.busy){self.actionGeneration++;[self.navigationController dismissViewControllerAnimated:YES completion:nil];}}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {(void)table;(void)section;return self.entries.count;}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)index {
    UITableViewCell *cell=[table dequeueReusableCellWithIdentifier:@"SBSavedSetup"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"SBSavedSetup"];
    NSDictionary *record=self.entries[index.row];UIListContentConfiguration *content=UIListContentConfiguration.subtitleCellConfiguration;
    content.text=record[@"name"];NSMutableArray *apps=[NSMutableArray array];for(NSString *identifier in record[@"applications"])[apps addObject:SetupAppName(identifier)];
    content.secondaryText=[NSString stringWithFormat:@"Requested: %@\nAwaiting app support",[apps componentsJoinedByString:@", "]];
    content.textProperties.color=UIColor.whiteColor;content.secondaryTextProperties.color=SBMuted();content.textProperties.numberOfLines=0;content.secondaryTextProperties.numberOfLines=0;
    cell.contentConfiguration=content;cell.backgroundColor=SBInk();cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    cell.accessibilityIdentifier=[@"socialbox.savedsetups.row." stringByAppendingString:record[@"identifier"]];return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)index {
    [table deselectRowAtIndexPath:index animated:YES];if(self.busy||index.row>=(NSInteger)self.entries.count)return;
    NSString *identifier=[self.entries[index.row][@"identifier"] copy];if(![self beginWithMessage:@"Reading saved setup…"])return;uint64_t generation=self.actionGeneration;__weak typeof(self) weak=self;
    [self.coordinator readConfigurationWithIdentifier:identifier completion:^(NSDictionary *reply){dispatch_async(dispatch_get_main_queue(),^{
        SBSavedSetupBrowser *browser=weak;if(![browser acceptGeneration:generation])return;[browser completeReply:reply];
        if([reply[@"result"] isEqual:@"record"]){LBXContainerConfiguration *configuration=[LBXContainerConfiguration fromDictionary:reply[@"configuration"] error:nil];if(configuration)[browser showEditorForConfiguration:configuration locked:browser.pending!=nil||browser.journalUnavailable];}
    });}];
}
@end

void SBPresentSavedContainerSetups(UIViewController *presenter) {
    if(![presenter isKindOfClass:UIViewController.class]||!presenter.viewIfLoaded.window||presenter.presentedViewController)return;
    SBSavedSetupBrowser *browser=[SBSavedSetupBrowser new];UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:browser];
    navigation.navigationBar.tintColor=SBAccent();UINavigationBarAppearance *appearance=[UINavigationBarAppearance new];[appearance configureWithOpaqueBackground];
    appearance.backgroundColor=SBInk();appearance.titleTextAttributes=@{NSForegroundColorAttributeName:UIColor.whiteColor};
    navigation.navigationBar.standardAppearance=appearance;navigation.navigationBar.scrollEdgeAppearance=appearance;
    [presenter presentViewController:navigation animated:YES completion:nil];
}
@implementation SBSetupEditor
- (void)viewDidLoad {
    [super viewDidLoad];self.title=self.configuration?@"Edit saved setup":@"New saved setup";self.view.backgroundColor=SBInk();
    self.view.accessibilityIdentifier=@"socialbox.savedsetup.editor";
    UIScrollView *scroll=[UIScrollView new];self.scroll=scroll;scroll.translatesAutoresizingMaskIntoConstraints=NO;
    scroll.keyboardDismissMode=UIScrollViewKeyboardDismissModeInteractive;[self.view addSubview:scroll];
    UIStackView *body=SetupStack(@[],16);body.translatesAutoresizingMaskIntoConstraints=NO;[scroll addSubview:body];
    [NSLayoutConstraint activateConstraints:@[[scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [body.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [body.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [body.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [body.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [body.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]]];
    UILabel *state=SBLabel(@"Awaiting app support",12,UIFontWeightBold);state.textColor=SBAccent();
    UILabel *detail=SBLabel(@"Save your choices here. This setup cannot open or switch apps yet.",15,UIFontWeightRegular);detail.textColor=SBMuted();
    [body addArrangedSubview:SetupStack(@[state,detail],6)];
    self.nameField=SetupField(@"Setup name",@"socialbox.savedsetup.name");self.nameField.delegate=self;
    self.nameField.keyboardType=UIKeyboardTypeDefault;
    self.nameField.text=self.configuration.name ?: @"";[body addArrangedSubview:self.nameField];
    UILabel *appsTitle=SBLabel(@"Requested apps",18,UIFontWeightSemibold);
    UILabel *appsHint=SBLabel(@"Choose one or more. Selection does not enable app support.",13,UIFontWeightRegular);appsHint.textColor=SBMuted();
    UIStackView *apps=SetupStack(@[appsTitle,appsHint],12);NSMutableDictionary *appSwitches=[NSMutableDictionary dictionary];
    for(NSString *identifier in SetupApplications()) {
        UILabel *label=SBLabel(SetupAppName(identifier),16,UIFontWeightRegular);UISwitch *toggle=[UISwitch new];toggle.onTintColor=SBAccent();
        toggle.on=self.configuration?[self.configuration.applications containsObject:identifier]:[identifier isEqual:@"com.burbn.instagram"];
        toggle.accessibilityLabel=label.text;toggle.accessibilityIdentifier=[@"socialbox.savedsetup.app." stringByAppendingString:identifier];
        appSwitches[identifier]=toggle;
        UIStackView *row=[[UIStackView alloc] initWithArrangedSubviews:@[label,toggle]];row.axis=UILayoutConstraintAxisHorizontal;row.alignment=UIStackViewAlignmentCenter;
        [toggle setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];[apps addArrangedSubview:row];
    }
    self.appSwitches=[appSwitches copy];[body addArrangedSubview:SetupPanel(apps)];
    UILabel *identifiersTitle=SBLabel(@"Identifiers",18,UIFontWeightSemibold);
    self.identifierMode=[[UISegmentedControl alloc] initWithItems:self.configuration?@[@"Keep existing",@"Edit manually"]:@[@"Random",@"Manual"]];
    self.identifierMode.selectedSegmentIndex=0;self.identifierMode.selectedSegmentTintColor=SBAccent();
    self.identifierMode.accessibilityIdentifier=@"socialbox.savedsetup.identifierMode";
    [self.identifierMode setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.whiteColor} forState:UIControlStateNormal];
    [self.identifierMode setTitleTextAttributes:@{NSForegroundColorAttributeName:SBInk()} forState:UIControlStateSelected];
    [self.identifierMode addTarget:self action:@selector(updateFields) forControlEvents:UIControlEventValueChanged];
    UILabel *identifierHint=SBLabel(self.configuration?@"Keeping identifiers preserves the saved values. Enter all fields to change them manually.":@"Random values are chosen once when you save. Manual values must fill all ten fields.",13,UIFontWeightRegular);identifierHint.textColor=SBMuted();
    [body addArrangedSubview:SetupStack(@[identifiersTitle,self.identifierMode,identifierHint],8)];
    NSMutableDictionary *fields=[NSMutableDictionary dictionary];
    for(NSArray<NSString *> *entry in SetupIdentifiers()) {
        UILabel *label=SBLabel(entry[1],14,UIFontWeightMedium);
        UITextField *field=SetupField(entry[2],[@"socialbox.savedsetup.identifier." stringByAppendingString:entry[0]]);field.delegate=self;
        field.accessibilityLabel=entry[1];field.accessibilityHint=entry[2];
        field.text=self.configuration.identifiers[entry[0]] ?: @"";fields[entry[0]]=field;
        [body addArrangedSubview:SetupStack(@[label,field],6)];
    }
    self.identifierFields=[fields copy];
    UILabel *proxy=SBLabel(@"Proxy unavailable in this build",15,UIFontWeightMedium);proxy.textColor=SBMuted();
    [body addArrangedSubview:SetupPanel(proxy)];
    self.status=SBLabel(@"",15,UIFontWeightRegular);self.status.textColor=SBMuted();self.status.hidden=YES;
    self.status.accessibilityIdentifier=@"socialbox.savedsetup.status";[body addArrangedSubview:self.status];
    __weak typeof(self) weak=self;self.save=SBButton(@"Save setup",@"plus",YES,^{[weak submit];});
    self.save.accessibilityIdentifier=@"socialbox.savedsetup.save";[body addArrangedSubview:self.save];[self updateFields];
    if(self.configuration){self.remove=SBButton(@"Remove saved settings",@"containers",NO,^{[weak confirmRemoval];});
        self.remove.accessibilityIdentifier=@"socialbox.savedsetup.remove";[body addArrangedSubview:self.remove];
        UILabel *removal=SBLabel(@"This permanently removes these saved settings. App data and accounts stay unchanged.",13,UIFontWeightRegular);removal.textColor=SBMuted();[body addArrangedSubview:removal];[self updateFields];}
}
- (void)updateFields {
    BOOL canEdit=!self.locked&&!self.busy;self.nameField.enabled=canEdit;self.identifierMode.enabled=canEdit;
    for(UISwitch *toggle in self.appSwitches.allValues)toggle.enabled=canEdit;
    BOOL manual=self.identifierMode.selectedSegmentIndex==1;
    for(UITextField *field in self.identifierFields.allValues){field.enabled=canEdit&&manual;field.alpha=manual?1:.68;}
    self.save.enabled=canEdit;self.remove.enabled=canEdit;self.navigationItem.hidesBackButton=self.busy;
    self.navigationController.interactivePopGestureRecognizer.enabled=!self.busy;
}
- (void)setMessage:(NSString *)message busy:(BOOL)busy locked:(BOOL)locked {
    self.busy=busy;self.locked=locked;[self loadViewIfNeeded];self.status.text=message ?: @"";self.status.hidden=!message.length;[self updateFields];
    if(message.length)UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,message);
}
- (void)submit {
    if(self.locked||self.busy)return;NSMutableArray *apps=[NSMutableArray array];
    for(NSString *identifier in SetupApplications())if(self.appSwitches[identifier].on)[apps addObject:identifier];
    NSMutableDictionary *manual=nil;if(self.identifierMode.selectedSegmentIndex==1){manual=[NSMutableDictionary dictionary];for(NSString *key in self.identifierFields)manual[key]=self.identifierFields[key].text ?: @"";}
    NSString *name=self.nameField.text ?: @"";
    NSString *invalid=LBXContainerConfigurationInvalidChoiceField(name,apps,manual,@"");
    if(invalid) {
        UITextField *field=nil;NSString *message=@"Check the identifier fields.";
        if([invalid isEqual:@"name"]){field=self.nameField;message=@"Enter a setup name of 1–80 characters.";}
        else if([invalid isEqual:@"applications"])message=@"Choose at least one requested app.";
        else for(NSArray *entry in SetupIdentifiers())if([invalid isEqual:entry[0]]) {
            field=self.identifierFields[invalid];message=[NSString stringWithFormat:@"%@: %@.",entry[1],entry[2]];break;
        }
        [self setMessage:message busy:NO locked:NO];
        if(field&&field.enabled&&self.navigationController.topViewController==self&&self.viewIfLoaded.window) {
            [field becomeFirstResponder];[self.view layoutIfNeeded];
            [self.scroll scrollRectToVisible:CGRectInset([field convertRect:field.bounds toView:self.scroll],0,-12) animated:NO];
        }
        return;
    }
    [self.view endEditing:YES];if(self.saveChoices)self.saveChoices(name,[apps copy],[manual copy]);
}
- (void)confirmRemoval {
    if(self.locked||self.busy||!self.configuration||!self.removeSettings||self.presentedViewController)return;
    [self.view endEditing:YES];UIAlertController *confirmation=[UIAlertController alertControllerWithTitle:@"Remove saved settings?"
        message:@"The saved name, app choices and identifiers will be permanently retired. App data and accounts stay unchanged. Unsaved edits are not used."
        preferredStyle:UIAlertControllerStyleAlert];
    [confirmation addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weak=self;
    [confirmation addAction:[UIAlertAction actionWithTitle:@"Remove saved settings" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){
        SBSetupEditor *editor=weak;if(editor&&!editor.locked&&!editor.busy&&editor.navigationController.topViewController==editor&&editor.removeSettings)editor.removeSettings();
    }]];
    [self presentViewController:confirmation animated:YES completion:nil];
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    NSMutableArray<UITextField *> *fields=[NSMutableArray arrayWithObject:self.nameField];for(NSArray *entry in SetupIdentifiers())if(self.identifierFields[entry[0]].enabled)[fields addObject:self.identifierFields[entry[0]]];
    NSUInteger index=[fields indexOfObjectIdenticalTo:textField];if(index!=NSNotFound&&index+1<fields.count)[fields[index+1] becomeFirstResponder];else[textField resignFirstResponder];return NO;
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];if(self.isMovingFromParentViewController||self.navigationController.isBeingDismissed)self.navigationController.interactivePopGestureRecognizer.enabled=YES;
}
@end
