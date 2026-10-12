#import "SBInterfaceCopy.h"
#import "SBContainersView.h"
#import "SBBackendAdapter.h"
#import "SBWorkspaceCoordinator.h"
#import "SBDesign.h"
#include <math.h>

static void Failure(UIViewController *owner,NSString *reason) {
    (void)reason;if(!owner||owner.presentedViewController)return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:SBUIText(@"common.actionUnavailable")
        message:SBUIText(@"containers.tryAgain") preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:SBUIText(@"common.close") style:UIAlertActionStyleCancel handler:nil]];
    [owner presentViewController:alert animated:YES completion:nil];
}
static void SwitchContainer(UIViewController *owner,NSString *identifier) {
    if(!owner||owner.presentedViewController)return;
    if(owner.navigationController&&owner.navigationController.topViewController!=owner){Failure(owner,nil);return;}
    NSString *reason=nil;
    // The original endpoint resolves this stable ID again, owns confirmation and
    // completion, and alone changes the selected context. Dispatch is no proof.
    if(!SBBackendInvokeContainerAction(owner,@"container.switch",identifier,&reason))Failure(owner,reason);
}
static BOOL ContainerSourceCurrent(UIViewController *presenter) {
    if(!NSThread.isMainThread||!presenter.isViewLoaded||!presenter.view.window||SBBackendScreen(presenter)!=SBScreenContainers)return NO;
    UIViewController *entry=presenter.navigationController?:presenter;
    return presenter.tabBarController.selectedViewController==entry&&
        (!presenter.navigationController||presenter.navigationController.topViewController==presenter);
}
static BOOL CreationHomeCurrent(UIViewController *presenter,UIViewController *home,UIViewController *review) {
    return ContainerSourceCurrent(presenter)&&home&&SBWorkspaceHost(presenter,SBScreenHome)==home&&home.isViewLoaded&&
        (!home.presentedViewController||home.presentedViewController==review)&&
        (!home.navigationController||home.navigationController.topViewController==home);
}

// Display existing labels only. These are current reported values, not a staged
// candidate, generated result, per-container settings or runtime acceptance.
@interface SBContainerCreationReview:UIViewController
@property(nonatomic,weak) UIViewController *source;
@property(nonatomic,weak) UIViewController *home;
@property(nonatomic) BOOL consumed;
- (void)proceed:(BOOL)create;
@end
@implementation SBContainerCreationReview
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=SBInk();self.view.accessibilityIdentifier=@"socialbox.creation.review";
    UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:scroll];
    UIStackView *stack=[UIStackView new];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=16;
    stack.translatesAutoresizingMaskIntoConstraints=NO;[scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]]];
    [stack addArrangedSubview:SBLabel(SBUIText(@"creation.reviewTitle"),28,UIFontWeightBold)];
    UILabel *detail=SBLabel(SBUIText(@"creation.reviewDetail"),16,UIFontWeightRegular);detail.textColor=SBMuted();[stack addArrangedSubview:detail];
    NSArray *fields=@[@[@"identity.modelName",@"creation.model"],@[@"identity.osVersion",@"creation.system"],
        @[@"identity.carrier",@"home.carrier"],@[@"identity.deviceName",@"creation.deviceName"],
        @[@"identity.modelNumber",@"home.modelNumber"],@[@"identity.serial",@"home.serial"],
        @[@"identity.mobileCodes",@"home.mobileCodes"],@[@"identity.wifi",@"home.wifi"],
        @[@"identity.bluetooth",@"home.bluetooth"],@[@"identity.ethernet",@"home.ethernet"],
        @[@"identity.imei",@"home.imei"],@[@"identity.meid",@"home.meid"],@[@"identity.iccid",@"home.iccid"],
        @[@"identity.advertisingID",@"home.advertisingID"],@[@"identity.vendorID",@"home.vendorID"],@[@"identity.deviceID",@"home.deviceID"]];
    for(NSArray *field in fields) {
        UILabel *original=SBBackendReadObject(self.home,field[0],NULL);
        NSString *value=[original.text copy];if(!value.length)value=SBUIText(@"common.unavailable");
        UILabel *label=SBLabel(SBUIText(field[1]),14,UIFontWeightSemibold);label.textColor=SBMuted();
        UILabel *reported=SBLabel(value,17,UIFontWeightRegular);reported.accessibilityIdentifier=[@"socialbox.creation.value." stringByAppendingString:field[0]];
        UIStackView *row=[[UIStackView alloc] initWithArrangedSubviews:@[label,reported]];row.axis=UILayoutConstraintAxisVertical;row.spacing=4;[stack addArrangedSubview:row];
    }
    __weak typeof(self) weak=self;
    UIButton *edit=SBButton(SBUIText(@"creation.settings"),@"settings",NO,^{[weak proceed:NO];});
    edit.accessibilityIdentifier=@"socialbox.creation.settings";edit.enabled=SBBackendActionAvailable(self.home,@"home.configureIdentity",nil,NULL);
    UILabel *hint=SBLabel(SBUIText(@"creation.settingsDetail"),15,UIFontWeightRegular);hint.textColor=SBMuted();
    UIButton *next=SBButton(SBUIText(@"creation.continue"),@"plus",YES,^{[weak proceed:YES];});next.accessibilityIdentifier=@"socialbox.creation.continue";
    UIButton *cancel=SBButton(SBUIText(@"creation.cancel"),@"close",NO,^{
        if(!weak||weak.consumed)return;weak.consumed=YES;[weak dismissViewControllerAnimated:YES completion:nil];
    });cancel.accessibilityIdentifier=@"socialbox.creation.cancel";
    for(UIView *view in @[edit,hint,next,cancel])[stack addArrangedSubview:view];
    for(UIButton *button in @[edit,next,cancel]){button.titleLabel.numberOfLines=0;[button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;}
}
- (void)proceed:(BOOL)create {
    if(self.consumed||!self.view.window||!CreationHomeCurrent(self.source,self.home,self)||self.source.presentedViewController!=self)return;
    self.consumed=YES;__weak UIViewController *source=self.source,*home=self.home;
    [self dismissViewControllerAnimated:YES completion:^{
        if(!CreationHomeCurrent(source,home,nil)||source.presentedViewController||source.tabBarController.presentedViewController)return;
        NSString *action=create?@"home.create":@"home.configureIdentity";
        if(!SBBackendActionAvailable(home,action,nil,NULL)){Failure(source,nil);return;}
        SBWorkspaceNavigate(source,SBScreenHome);UIViewController *entry=home.navigationController?:home;
        if(home.tabBarController.selectedViewController!=entry)return;
        // Existing reviewed user entry owns its controls, validation and effects.
        // Editing returns to the original screen and never queues creation.
        if(!SBBackendInvoke(home,action,nil,NULL))Failure(home,nil);
    }];
}
@end
static void CreateContainer(UIViewController *presenter) {
    if(!ContainerSourceCurrent(presenter)||presenter.presentedViewController||presenter.tabBarController.presentedViewController)return;
    UIViewController *home=SBWorkspaceHost(presenter,SBScreenHome);NSString *reason=nil;
    if(!home){Failure(presenter,nil);return;}[home loadViewIfNeeded];
    if(home.presentedViewController||(home.navigationController&&home.navigationController.topViewController!=home))return;
    if(!SBBackendActionAvailable(home,@"home.create",nil,&reason)){Failure(presenter,reason);return;}
    SBContainerCreationReview *review=[SBContainerCreationReview new];review.source=presenter;review.home=home;
    review.modalPresentationStyle=UIModalPresentationOverFullScreen;[presenter presentViewController:review animated:YES completion:nil];
}

@interface SBContainersView()<UITableViewDataSource,UITableViewDelegate>
@property(nonatomic,weak) UIViewController *owner;
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) UIView *header;
@property(nonatomic,strong) UILabel *headingTitle;
@property(nonatomic,strong) UILabel *selectedName,*swipeHint;
@property(nonatomic,strong) UIButton *create;
@property(nonatomic,strong) UIFont *createFont;
@property(nonatomic,strong) NSArray<SBContainerRecord *> *rows;
@property(nonatomic,copy) NSString *active;
@property(nonatomic,strong) NSArray *renderedSnapshot;
@end

@implementation SBContainersView
- (instancetype)initWithOwner:(UIViewController *)owner {
    if((self=[super initWithFrame:CGRectZero])) {
        self.owner=owner;self.backgroundColor=SBInk();self.accessibilityIdentifier=@"socialbox.containers";
        self.headingTitle=SBLabel(SBUIText(@"nav.containers"),32,UIFontWeightBold);
        self.headingTitle.accessibilityIdentifier=@"socialbox.containers.title";
        self.selectedName=SBLabel(@"",17,UIFontWeightSemibold);self.selectedName.textColor=SBAccent();
        self.selectedName.accessibilityIdentifier=@"socialbox.containers.selectedName";
        self.selectedName.numberOfLines=1;self.selectedName.lineBreakMode=NSLineBreakByTruncatingTail;
        self.swipeHint=SBLabel(SBUIText(@"containers.swipeHint"),13,UIFontWeightRegular);self.swipeHint.textColor=SBMuted();
        self.swipeHint.numberOfLines=2;self.swipeHint.accessibilityIdentifier=@"socialbox.containers.swipeHint";
        UIStackView *headings=[[UIStackView alloc] initWithArrangedSubviews:@[self.headingTitle,self.selectedName,self.swipeHint]];
        headings.axis=UILayoutConstraintAxisVertical;headings.spacing=6;headings.translatesAutoresizingMaskIntoConstraints=NO;
        self.header=[UIView new];[self.header addSubview:headings];
        [NSLayoutConstraint activateConstraints:@[[headings.leadingAnchor constraintEqualToAnchor:self.header.leadingAnchor constant:8],
            [headings.trailingAnchor constraintEqualToAnchor:self.header.trailingAnchor constant:-8],
            [headings.topAnchor constraintEqualToAnchor:self.header.topAnchor constant:16],
            [headings.bottomAnchor constraintEqualToAnchor:self.header.bottomAnchor constant:-12]]];
        self.table=[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        self.table.dataSource=self;self.table.delegate=self;self.table.backgroundColor=SBInk();
        self.table.separatorColor=[SBMuted() colorWithAlphaComponent:.15];self.table.rowHeight=UITableViewAutomaticDimension;
        self.table.estimatedRowHeight=82;self.table.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:self.table];self.table.tableHeaderView=self.header;
        __weak typeof(self) weak=self;
        self.create=SBButton(SBUIText(@"containers.create"),@"plus",YES,^{CreateContainer(weak.owner);});
        self.create.accessibilityIdentifier=@"socialbox.containers.create";self.create.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:self.create];
        [NSLayoutConstraint activateConstraints:@[[self.table.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [self.table.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [self.table.topAnchor constraintEqualToAnchor:self.topAnchor],
            [self.table.bottomAnchor constraintEqualToAnchor:self.create.topAnchor constant:-12],
            [self.create.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:20],
            [self.create.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-20],
            [self.create.bottomAnchor constraintEqualToAnchor:self.keyboardLayoutGuide.topAnchor constant:-12]]];
        owner.navigationItem.title=SBUIText(@"brand.name");owner.navigationItem.leftBarButtonItems=@[];owner.navigationItem.rightBarButtonItems=@[];
        [self refresh];
    }return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    UIFont *title=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleLargeTitle] scaledFontForFont:[UIFont systemFontOfSize:32 weight:UIFontWeightBold]
        maximumPointSize:44 compatibleWithTraitCollection:self.traitCollection];self.headingTitle.font=title;
    self.selectedName.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]
        maximumPointSize:20 compatibleWithTraitCollection:self.traitCollection];
    self.swipeHint.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote] scaledFontForFont:[UIFont systemFontOfSize:13]
        maximumPointSize:16 compatibleWithTraitCollection:self.traitCollection];
    UIFont *font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:[UIFont systemFontOfSize:17 weight:UIFontWeightRegular]
        maximumPointSize:26 compatibleWithTraitCollection:self.traitCollection];
    if(![self.createFont isEqual:font]){UIButtonConfiguration *config=self.create.configuration;
        config.titleTextAttributesTransformer=^NSDictionary *(NSDictionary *input){NSMutableDictionary *values=[input mutableCopy];values[NSFontAttributeName]=font;return values;};
        self.create.configuration=config;self.createFont=font;}
    CGFloat width=self.table.bounds.size.width;if(width<=0)return;
    CGSize size=[self.header systemLayoutSizeFittingSize:CGSizeMake(width,UILayoutFittingCompressedSize.height)
        withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGRect frame=CGRectMake(0,0,width,ceil(size.height));
    if(!CGRectEqualToRect(self.header.frame,frame)){self.header.frame=frame;self.table.tableHeaderView=self.header;}
    UIView *footer=self.table.tableFooterView;if(footer){CGSize fit=[footer systemLayoutSizeFittingSize:CGSizeMake(width,UILayoutFittingCompressedSize.height)
        withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];footer.frame=CGRectMake(0,0,width,ceil(fit.height));}
}
- (void)showEmptyMessage:(NSString *)text {
    UIView *footer=[UIView new];UILabel *label=SBLabel(text,16,UIFontWeightRegular);label.textColor=SBMuted();label.translatesAutoresizingMaskIntoConstraints=NO;
    label.accessibilityIdentifier=@"socialbox.containers.empty";[footer addSubview:label];
    [NSLayoutConstraint activateConstraints:@[[label.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:8],
        [label.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-8],
        [label.topAnchor constraintEqualToAnchor:footer.topAnchor constant:20],
        [label.bottomAnchor constraintEqualToAnchor:footer.bottomAnchor constant:-20]]];self.table.tableFooterView=footer;
}
- (void)refresh {
    SBContainerSnapshot *snapshot=SBBackendContainers(self.owner);
    if(!snapshot.available){NSArray *signature=@[@"unavailable"];
        if([self.renderedSnapshot isEqual:signature])return;self.renderedSnapshot=signature;self.rows=@[];self.active=nil;
        self.selectedName.text=nil;self.selectedName.hidden=YES;self.swipeHint.hidden=YES;
        [self.table reloadData];[self showEmptyMessage:SBUIText(@"containers.loadFailed")];[self setNeedsLayout];return;}
    NSMutableArray *signature=[NSMutableArray arrayWithObject:snapshot.activeIdentifier?:@""];
    for(SBContainerRecord *record in snapshot.containers)[signature addObject:@[record.identifier,record.name]];
    if([self.renderedSnapshot isEqual:signature])return;self.renderedSnapshot=signature;self.active=snapshot.activeIdentifier;
    self.rows=[snapshot.containers sortedArrayUsingComparator:^NSComparisonResult(SBContainerRecord *a,SBContainerRecord *b){return [a.identifier compare:b.identifier options:NSNumericSearch];}];
    NSString *selected=nil;for(SBContainerRecord *record in self.rows)if([record.identifier isEqual:self.active]){selected=record.name;break;}
    self.selectedName.text=selected?[NSString stringWithFormat:SBUIText(@"containers.selectedName"),selected]:nil;
    self.selectedName.hidden=!selected;self.swipeHint.hidden=!self.rows.count;
    [self.table reloadData];self.table.tableFooterView=nil;
    if(!self.rows.count)[self showEmptyMessage:SBUIText(@"containers.empty")];[self setNeedsLayout];
}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {(void)table;(void)section;return self.rows.count;}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)index {
    UITableViewCell *cell=[table dequeueReusableCellWithIdentifier:@"SBContainer"]?:[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"SBContainer"];
    SBContainerRecord *record=self.rows[index.row];BOOL selected=[record.identifier isEqual:self.active];
    UIListContentConfiguration *content=UIListContentConfiguration.cellConfiguration;content.text=record.name;content.secondaryText=nil;
    content.image=SBGlyph(@"containers");content.imageProperties.tintColor=selected?SBAccent():SBMuted();
    content.textProperties.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:[UIFont systemFontOfSize:17]
        maximumPointSize:26 compatibleWithTraitCollection:self.traitCollection];content.textProperties.adjustsFontForContentSizeCategory=NO;
    content.textProperties.color=UIColor.whiteColor;content.textProperties.numberOfLines=0;content.directionalLayoutMargins=NSDirectionalEdgeInsetsMake(16,10,16,10);
    cell.contentConfiguration=content;cell.backgroundColor=selected?SBPanel():SBInk();cell.accessoryType=UITableViewCellAccessoryNone;
    cell.accessibilityIdentifier=[@"socialbox.container." stringByAppendingString:record.identifier];
    NSString *identifier=[record.identifier copy];__weak typeof(self) weak=self;
    UIButton *button=SBButton((selected?SBUIText(@"containers.rowSelected"):SBUIText(@"container.switch")),@"containers",!selected,^{SwitchContainer(weak.owner,identifier);});
    UIButtonConfiguration *configuration=button.configuration;configuration.image=nil;configuration.contentInsets=NSDirectionalEdgeInsetsMake(12,10,12,10);
    UIFont *actionFont=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:[UIFont systemFontOfSize:17]
        maximumPointSize:20 compatibleWithTraitCollection:self.traitCollection];
    configuration.titleTextAttributesTransformer=^NSDictionary *(NSDictionary *input){NSMutableDictionary *values=[input mutableCopy];values[NSFontAttributeName]=actionFont;return values;};
    configuration.titleAlignment=UIButtonConfigurationTitleAlignmentCenter;button.configuration=configuration;button.contentHorizontalAlignment=UIControlContentHorizontalAlignmentCenter;
    button.accessibilityIdentifier=[@"socialbox.container.switch." stringByAppendingString:identifier];
    button.enabled=!selected&&SBBackendContainerActionAvailable(self.owner,@"container.switch",identifier,NULL);
    button.frame=CGRectMake(0,0,104,48);cell.accessoryView=button;
    cell.selectionStyle=selected?UITableViewCellSelectionStyleNone:UITableViewCellSelectionStyleDefault;
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)index {
    [table deselectRowAtIndexPath:index animated:YES];if(index.row<0||(NSUInteger)index.row>=self.rows.count)return;
    NSString *identifier=[self.rows[index.row].identifier copy];if([identifier isEqual:self.active])return;
    SwitchContainer(self.owner,identifier);
}
- (UISwipeActionsConfiguration *)swipeAtIndex:(NSIndexPath *)index action:(NSString *)action title:(NSString *)title destructive:(BOOL)destructive {
    if(index.section!=0||index.row<0||(NSUInteger)index.row>=self.rows.count)return nil;
    NSString *identifier=[self.rows[index.row].identifier copy];
    if(!SBBackendContainerActionAvailable(self.owner,action,identifier,NULL))return nil;
    __weak typeof(self) weak=self;__block BOOL consumed=NO;
    UIContextualAction *entry=[UIContextualAction contextualActionWithStyle:destructive?UIContextualActionStyleDestructive:UIContextualActionStyleNormal
        title:title handler:^(__unused UIContextualAction *sender,__unused UIView *view,void (^complete)(BOOL)){
        // Native confirmation owns removal/rename and the eventual refresh.
        // Never delete a table row optimistically or retain the original model.
        if(consumed){complete(NO);return;}consumed=YES;
        UIViewController *owner=weak.owner;NSString *reason=nil;
        if(ContainerSourceCurrent(owner)&&!owner.presentedViewController&&!owner.tabBarController.presentedViewController&&
            !SBBackendInvokeContainerAction(owner,action,identifier,&reason))Failure(owner,reason);
        complete(NO);
    }];
    entry.backgroundColor=destructive?UIColor.systemRedColor:SBAccent();
    UISwipeActionsConfiguration *configuration=[UISwipeActionsConfiguration configurationWithActions:@[entry]];
    configuration.performsFirstActionWithFullSwipe=NO;return configuration;
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)table trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)index {
    (void)table;return [self swipeAtIndex:index action:@"container.delete" title:SBUIText(@"container.delete") destructive:YES];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)table leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)index {
    (void)table;return [self swipeAtIndex:index action:@"container.rename" title:SBUIText(@"container.rename") destructive:NO];
}
@end
