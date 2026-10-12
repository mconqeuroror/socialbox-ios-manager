#import <UIKit/UIKit.h>
#import "SBSecondaryScreens.h"
#import "SBBackendAdapter.h"
#import "LBXDisplayCopy.h"

// Focused renderer fixture: the guarded adapter is tested separately. These
// synthetic objects carry no accounts, credentials, network or license state.
@interface SBSecondaryFixtureOwner : UIViewController <UITableViewDataSource,UITableViewDelegate>
@property(nonatomic) SBScreen role;
@property(nonatomic,strong) NSMutableDictionary *objects;
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) UILabel *sourceLabel;
@property(nonatomic,strong) UIButton *sourceButton;
@property(nonatomic) NSUInteger events;
@property(nonatomic,weak) id lastSender;
@property(nonatomic) NSInteger rowCount;
@end
SBScreen SBBackendScreen(id owner) { return [owner isKindOfClass:SBSecondaryFixtureOwner.class] ? ((SBSecondaryFixtureOwner *)owner).role : SBScreenUnknown; }
id SBBackendReadObject(id owner,NSString *key,NSString **reason) {
    (void)reason;
    if(![owner isKindOfClass:SBSecondaryFixtureOwner.class]) return nil;
    id object=((SBSecondaryFixtureOwner *)owner).objects[key];
    if([object isKindOfClass:UIView.class] && object!=((UIViewController *)owner).view && ![object isDescendantOfView:((UIViewController *)owner).view]) return nil;
    return object;
}
BOOL SBBackendActionAvailable(id owner,NSString *action,id sender,NSString **reason) { (void)owner;(void)action;(void)sender;(void)reason;return YES; }
BOOL SBBackendInvoke(id owner,NSString *action,id sender,NSString **reason) { (void)action;(void)sender;(void)reason;((SBSecondaryFixtureOwner *)owner).events++;return YES; }
@implementation SBSecondaryFixtureOwner
- (void)loadView { self.view=[[UIView alloc] initWithFrame:CGRectMake(0,0,375,667)]; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.objects=[NSMutableDictionary dictionary]; self.rowCount=60;
    self.table=[[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain]; self.table.rowHeight=112;
    self.table.dataSource=self;self.table.delegate=self;self.objects[@"surface"]=self.table;[self.view addSubview:self.table];
    UISearchBar *search=[UISearchBar new];self.objects[@"search"]=search;[self.view addSubview:search];
    UILabel *detail=[UILabel new];detail.text=@"60 synthetic items";self.objects[@"detail"]=detail;[self.view addSubview:detail];
}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {(void)table;(void)section;return self.rowCount;}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)index {
    UITableViewCell *cell=[table dequeueReusableCellWithIdentifier:@"row"];
    if(!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"row"];
    cell.textLabel.text=[NSString stringWithFormat:@"Saved item %ld",(long)index.row]; cell.detailTextLabel.text=@"Synthetic display data";
    cell.accessoryType=index.row==2 ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)index {(void)table;(void)index;self.events++;}
- (void)tapped:(id)sender {self.events++;self.lastSender=sender;}
@end

static NSMutableArray *Failures;
static NSUInteger Checks;
static void Check(BOOL value,NSString *label) { Checks++; if(!value) [Failures addObject:label]; }
static NSArray *Views(UIView *root,Class kind) { NSMutableArray *result=[NSMutableArray array];if([root isKindOfClass:kind])[result addObject:root];for(UIView *view in root.subviews)[result addObjectsFromArray:Views(view,kind)];return result; }
static UIView *FindID(UIView *root,NSString *key) { for(UIView *view in Views(root,UIView.class))if([view.accessibilityIdentifier isEqual:key])return view;return nil; }
static BOOL HasText(UIView *root,NSString *value) { for(UILabel *label in Views(root,UILabel.class))if(label.alpha>0 && [label.text isEqual:value])return YES;return NO; }
static void SaveScreen(UIWindow *window,NSString *name) {
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds];
    UIImage *image=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context){(void)context;[window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];}];
    NSString *dir=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    [UIImagePNGRepresentation(image) writeToFile:[dir stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
}
@interface SBUnsupportedDecoration : UIView @end
@implementation SBUnsupportedDecoration @end
@interface SBSecondaryFixtureApp : UIResponder<UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation SBSecondaryFixtureApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;(void)options;Failures=[NSMutableArray array];self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    SBSecondaryFixtureOwner *owner=[SBSecondaryFixtureOwner new];owner.role=SBScreenBackups;
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:owner];self.window.rootViewController=nav;[self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.25*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self run:owner navigation:nav];});return YES;
}
- (void)run:(SBSecondaryFixtureOwner *)owner navigation:(UINavigationController *)nav {
    id source=owner.table.dataSource,delegate=owner.table.delegate; UITableView *table=owner.table;
    Check(SBSecondaryApply(owner),@"secondary-admitted");[self.window layoutIfNeeded];
    for(NSUInteger i=0;i<5;i++){SBSecondaryRefresh(owner);[self.window layoutIfNeeded];}
    Check(table.dataSource==source && table.delegate==delegate,@"data-source-and-delegate-preserved");
    Check(owner.events==0,@"render-has-no-actions");
    Check(FindID(owner.view,@"socialbox.secondary.surface")!=nil,@"own-surface-visible");
    Check(table.bounds.size.height>300 && table.visibleCells.count>0,@"table-has-usable-visible-height");
    Check(HasText(owner.view,@"Local backups"),@"source-owned-English-heading");
    Check(table.tableHeaderView.bounds.size.height>80 && table.tableHeaderView.bounds.size.height<420,@"bounded-own-header");
    SaveScreen(self.window,@"secondary-backups");
    NSIndexPath *row40=[NSIndexPath indexPathForRow:40 inSection:0];[table scrollToRowAtIndexPath:row40 atScrollPosition:UITableViewScrollPositionTop animated:NO];[self.window layoutIfNeeded];SBSecondaryRefresh(owner);
    Check([table.indexPathsForVisibleRows containsObject:row40],@"native-scroll-to-row40");
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text=@"Original row";cell.detailTextLabel.text=@"Mutable detail";cell.accessoryType=UITableViewCellAccessoryCheckmark;
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:@"Restore" forState:UIControlStateNormal];button.tag=37;[button addTarget:owner action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];[cell.contentView addSubview:button];
    SBSecondaryStyleTableCell(owner,table,cell,[NSIndexPath indexPathForRow:0 inSection:0]);
    UIView *ownRow=FindID(cell,@"socialbox.secondary.row");Check(ownRow!=nil,@"own-row-present");
    Check([button isDescendantOfView:ownRow] && button.tag==37,@"native-sender-moved-intact");
    Check(cell.accessoryType==UITableViewCellAccessoryCheckmark,@"selection-accessory-preserved");
    cell.textLabel.text=@"Updated user row";Check(HasText(ownRow,@"Updated user row"),@"async-public-label-update");
    SBSecondaryStyleTableCell(owner,table,cell,[NSIndexPath indexPathForRow:0 inSection:0]);Check(FindID(cell,@"socialbox.secondary.row")==ownRow,@"row-refresh-idempotent");
    Check(owner.events==0,@"row-render-has-no-actions");[button sendActionsForControlEvents:UIControlEventTouchUpInside];Check(owner.events==1 && owner.lastSender==button,@"native-action-sender-preserved");
    for(UIView *view in cell.contentView.subviews.copy)[view removeFromSuperview];
    UILabel *replacement=[UILabel new];replacement.text=@"Fresh reuse value";[cell.contentView addSubview:replacement];
    SBSecondaryStyleTableCell(owner,table,cell,[NSIndexPath indexPathForRow:1 inSection:0]);
    Check(HasText(FindID(cell,@"socialbox.secondary.row"),@"Fresh reuse value"),@"reuse-shape-rebinds");
    Check(![button isDescendantOfView:cell],@"reuse-does-not-resurrect-sender");
    [cell.contentView addSubview:[SBUnsupportedDecoration new]];SBSecondaryStyleTableCell(owner,table,cell,[NSIndexPath indexPathForRow:1 inSection:0]);
    Check(FindID(cell,@"socialbox.secondary.row-unavailable")!=nil,@"unknown-row-fails-to-owned-panel");
    UITableViewCell *backup=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"BackupCell"];
    NSMutableArray<UILabel *> *backupLabels=[NSMutableArray array];
    for(NSString *value in @[@"SocialBox",@"12 KB",@"Sep 28, 2026",@"SocialBox"]) {
        UILabel *label=[UILabel new];label.text=value;[backup.contentView addSubview:label];[backupLabels addObject:label];
    }
    UILabel *type=backupLabels[3];type.textAlignment=NSTextAlignmentCenter;type.font=[UIFont systemFontOfSize:10];type.layer.cornerRadius=4;type.layer.masksToBounds=YES;
    SBSecondaryStyleTableCell(owner,table,backup,[NSIndexPath indexPathForRow:0 inSection:0]);
    UIView *backupRow=FindID(backup,@"socialbox.secondary.row");
    Check(HasText(backupRow,@"SocialBox")&&HasText(backupRow,@"SocialBox"),@"only-exact-backup-type-slot-maps-user-filename-identical-remains");
    Check([type.text isEqual:@"SocialBox"]&&[backupLabels[0].text isEqual:@"SocialBox"],@"backup-original-labels-not-mutated");
    type.text=@"AZInfo";Check(HasText(backupRow,@"AZInfo"),@"type-binding-updates-original-compatible-format");
    type.text=@"SocialBox";backupLabels[0].text=@"my SocialBox archive";Check(HasText(backupRow,@"SocialBox")&&HasText(backupRow,@"my SocialBox archive"),@"badge-refresh-never-rewrites-filename");
    type.textAlignment=NSTextAlignmentLeft;SBSecondaryStyleTableCell(owner,table,backup,[NSIndexPath indexPathForRow:0 inSection:0]);
    Check(FindID(backup,@"socialbox.secondary.row-unavailable")!=nil&&!backup.userInteractionEnabled,@"unproven-backup-cell-shape-fails-to-owned-unavailable");
    NSString *command=@"Enter a passphrase, or run `socialbox cloud passphrase-set` first to save one globally.";
    UIAlertController *message=[UIAlertController alertControllerWithTitle:@"Passphrase Required" message:command preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *ok=[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];[message addAction:ok];
    LBXDisplayCopyAlert(message);
    Check([message.message isEqual:@"Enter a passphrase, or save one in Cloud passphrase settings before continuing."]&&message.actions.firstObject==ok,@"actual-mapper-removes-reviewed-command-guidance-preserves-action");
    Check([LBXDisplayText(command,LBXDisplayTextRoleUserData) isEqual:command],@"same-command-string-in-user-data-stays-exact");
    UIView *section=[[UIView alloc] initWithFrame:CGRectMake(0,0,340,44)];section.tag=7;
    UILabel *sectionLabel=[UILabel new];sectionLabel.text=@"SocialBox user's section";[section addSubview:sectionLabel];
    UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc] initWithTarget:owner action:@selector(tapped:)];[section addGestureRecognizer:tap];
    NSUInteger beforeHeader=owner.events;
    for(NSUInteger i=0;i<3;i++)SBSecondaryStyleTableHeader(owner,table,section);
    [section layoutIfNeeded];
    Check(section.gestureRecognizers.count==1&&section.gestureRecognizers.firstObject==tap&&tap.view==section&&section.tag==7&&section.userInteractionEnabled,@"section-header-keeps-exact-gesture-carrier-tag-and-interaction");
    Check(HasText(FindID(section,@"socialbox.secondary.row"),@"SocialBox user's section")&&owner.events==beforeHeader,@"section-header-preserves-user-label-without-triggering-selection");
    Check([section hitTest:CGPointMake(170,22) withEvent:nil]==section,@"own-header-drawing-does-not-intercept-original-root-gesture");
    sectionLabel.text=@"Fresh section name";Check(HasText(FindID(section,@"socialbox.secondary.row"),@"Fresh section name"),@"section-header-reflects-native-async-update");
    owner.rowCount=0;[table reloadData];SBSecondaryRefresh(owner);Check(!FindID(table,@"socialbox.secondary.empty").hidden,@"owned-empty-state");
    SBSecondaryFixtureOwner *bad=[SBSecondaryFixtureOwner new];bad.role=SBScreenCountry;[bad loadViewIfNeeded];bad.objects[@"surface"]=[UIView new];[bad.view addSubview:bad.objects[@"surface"]];
    [nav setViewControllers:@[bad] animated:NO];SBSecondaryApply(bad);[self.window layoutIfNeeded];Check(FindID(bad.view,@"socialbox.secondary.unavailable")!=nil,@"wrong-surface-fails-to-owned-panel");
    SBSecondaryFixtureOwner *bulk=[SBSecondaryFixtureOwner new];bulk.role=SBScreenBulkProxyImport;[bulk loadViewIfNeeded];
    UITextView *input=[UITextView new];input.text=@"example.test:8080";bulk.objects[@"input"]=input;[bulk.view addSubview:input];
    UISegmentedControl *mode=[[UISegmentedControl alloc] initWithItems:@[@"HTTP",@"SOCKS5"]];mode.selectedSegmentIndex=1;bulk.objects[@"mode"]=mode;[bulk.view addSubview:mode];
    UIButton *submit=[UIButton buttonWithType:UIButtonTypeSystem];[submit setTitle:@"Import" forState:UIControlStateNormal];[submit addTarget:bulk action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];bulk.objects[@"submit"]=submit;[bulk.view addSubview:submit];
    [nav setViewControllers:@[bulk] animated:NO];SBSecondaryApply(bulk);[self.window layoutIfNeeded];
    Check(input.text.length>0 && mode.selectedSegmentIndex==1 && bulk.events==0,@"bulk-input-and-mode-preserved");
    Check([submit isDescendantOfView:FindID(bulk.view,@"socialbox.secondary.surface")],@"bulk-submit-sender-preserved");SaveScreen(self.window,@"secondary-import");
    SBSecondaryFixtureOwner *picker=[SBSecondaryFixtureOwner new];picker.role=SBScreenModel;[picker loadViewIfNeeded];
    UITableView *pickerTable=picker.table;[pickerTable removeFromSuperview];picker.view=pickerTable;pickerTable.rowHeight=56;
    UIView *nativeHeader=[[UIView alloc] initWithFrame:CGRectMake(0,0,375,88)];UILabel *hint=[UILabel new];hint.text=@"Compatible device group";[nativeHeader addSubview:hint];
    UISwitch *nativeSwitch=[UISwitch new];nativeSwitch.on=YES;nativeSwitch.tag=19;[nativeHeader addSubview:nativeSwitch];pickerTable.tableHeaderView=nativeHeader;
    [nav setViewControllers:@[picker] animated:NO];Check(SBSecondaryApply(picker),@"root-table-admitted");[self.window layoutIfNeeded];
    Check(picker.view==pickerTable && pickerTable.dataSource==picker,@"root-table-identity-preserved");
    Check([nativeSwitch isDescendantOfView:pickerTable.tableHeaderView] && nativeSwitch.on && nativeSwitch.tag==19,@"header-control-preserved");
    Check(picker.events==0 && pickerTable.visibleCells.count>0,@"root-table-renders-without-actions");SaveScreen(self.window,@"secondary-picker");
    SBGuideViewController *guide=[SBGuideViewController new];[nav setViewControllers:@[guide] animated:NO];[self.window layoutIfNeeded];
    Check(FindID(guide.view,@"socialbox.guide.content")!=nil && HasText(guide.view,@"01 / CONTAINERS"),@"local-owned-English-guide");SaveScreen(self.window,@"secondary-guide");
    SBSecondaryFixtureOwner *unproven=[SBSecondaryFixtureOwner new];unproven.role=SBScreenSessionDestination;[unproven loadViewIfNeeded];[unproven.objects removeObjectForKey:@"search"];
    [nav setViewControllers:@[unproven] animated:NO];SBSecondaryApply(unproven);[self.window layoutIfNeeded];
    Check(FindID(unproven.view,@"socialbox.secondary.unavailable")!=nil&&unproven.events==0,@"destination-unproven-search-contract-is-owned-unavailable-without-actions");
    [self exerciseAddedRoutes:nav index:0];
}
- (void)exerciseAddedRoutes:(UINavigationController *)nav index:(NSUInteger)index {
    NSArray *roles=@[@(SBScreenSessions),@(SBScreenSessionImport),@(SBScreenBulkCloudPush),@(SBScreenSessionExport),@(SBScreenSessionDestination)];
    if(index==roles.count){[self finish];return;}
    SBSecondaryFixtureOwner *owner=[SBSecondaryFixtureOwner new];owner.role=[roles[index] integerValue];[owner loadViewIfNeeded];
    UIActivityIndicatorView *spinner=[UIActivityIndicatorView new];[spinner startAnimating];
    if(owner.role==SBScreenSessions){owner.objects[@"activity"]=spinner;[owner.view addSubview:spinner];}
    UITextField *label=[UITextField new],*passphrase=[UITextField new];
    label.text=@"SocialBox — user's archive";passphrase.text=@"SocialBox-secret-🗝️";passphrase.secureTextEntry=YES;passphrase.placeholder=@"(using saved passphrase)";
    label.delegate=(id)owner;passphrase.delegate=(id)owner;
    UIView *nativeHeader=[[UIView alloc] initWithFrame:CGRectMake(0,0,375,180)];
    if(owner.role==SBScreenBulkCloudPush){
        [nativeHeader addSubview:label];[nativeHeader addSubview:passphrase];owner.table.tableHeaderView=nativeHeader;
        owner.objects[@"label"]=label;owner.objects[@"passphrase"]=passphrase;
    }
    UIBarButtonItem *original=[[UIBarButtonItem alloc] initWithTitle:@"Confirm" style:UIBarButtonItemStyleDone target:owner action:@selector(tapped:)];
    owner.navigationItem.rightBarButtonItem=original;
    UISearchBar *search=owner.objects[@"search"];search.text=@"SocialBox user search";search.delegate=(id)owner;
    UIBarButtonItem *cancel=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:owner action:@selector(tapped:)];owner.navigationItem.leftBarButtonItem=cancel;
    [nav setViewControllers:@[owner] animated:NO];Check(SBSecondaryApply(owner),@"added-route-owned-presentation");
    for(NSUInteger i=0;i<4;i++)SBSecondaryRefresh(owner);
    Check(owner.events==0&&owner.table.dataSource==owner&&owner.table.delegate==owner,@"added-route-render-does-not-load-import-upload-or-change-selection");
    Check(owner.navigationItem.rightBarButtonItem==original&&original.target==owner&&original.enabled,@"added-route-original-confirmation-item-is-identical");
    if(owner.role==SBScreenSessions)Check([spinner isDescendantOfView:FindID(owner.view,@"socialbox.secondary.surface")]&&spinner.isAnimating,@"sessions-keeps-live-original-progress-indicator");
    if(owner.role==SBScreenSessionDestination){
        Check([search isDescendantOfView:FindID(owner.view,@"socialbox.secondary.surface")]&&[search.text isEqual:@"SocialBox user search"]&&search.delegate==(id)owner,@"destination-keeps-original-search-value-and-delegate");
        Check(owner.navigationItem.leftBarButtonItem==cancel&&cancel.target==owner,@"destination-keeps-original-cancel-completion-carrier");
    }
    if(owner.role==SBScreenBulkCloudPush){
        UIView *surface=FindID(owner.view,@"socialbox.secondary.surface");
        Check([label isDescendantOfView:surface]&&[passphrase isDescendantOfView:surface]&&label.delegate==(id)owner&&passphrase.delegate==(id)owner,@"cloud-batch-keeps-exact-fields-and-delegates");
        Check([label.text isEqual:@"SocialBox — user's archive"]&&[passphrase.text isEqual:@"SocialBox-secret-🗝️"]&&passphrase.secureTextEntry&&[passphrase.placeholder isEqual:@"(using saved passphrase)"],@"cloud-batch-keeps-name-credential-and-saved-passphrase-cue");
        Check([label.accessibilityLabel isEqual:@"Backup label"]&&[passphrase.accessibilityLabel isEqual:@"Passphrase"],@"cloud-batch-fields-have-owned-English-accessibility-labels");
        Check(owner.table.tableHeaderView!=nativeHeader&&![nativeHeader isDescendantOfView:owner.view],@"cloud-batch-native-header-is-not-visible");
    }
    UITableViewCell *row=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];row.textLabel.text=@"SocialBox user label";row.detailTextLabel.text=@"secret-🗝️";row.accessoryType=UITableViewCellAccessoryCheckmark;
    UIImageView *selection=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];row.accessoryView=selection;
    SBSecondaryStyleTableCell(owner,owner.table,row,[NSIndexPath indexPathForRow:0 inSection:0]);
    Check(row.accessoryView==selection,@"native-accessory-selection-object-preserved");
    Check(HasText(FindID(row,@"socialbox.secondary.row"),@"SocialBox user label")&&HasText(FindID(row,@"socialbox.secondary.row"),@"secret-🗝️")&&row.accessoryType==UITableViewCellAccessoryCheckmark,@"session-and-cloud-row-values-and-selection-remain-original");
    [UIApplication.sharedApplication sendAction:original.action to:original.target from:original forEvent:nil];
    Check(owner.events==1&&owner.lastSender==original,@"explicit-confirmation-only-dispatches-original-item-once");
    [self captureAddedRoute:owner navigation:nav index:index remaining:100 stable:0];
}
- (void)captureAddedRoute:(SBSecondaryFixtureOwner *)owner navigation:(UINavigationController *)nav index:(NSUInteger)index remaining:(NSUInteger)remaining stable:(NSUInteger)stable {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        [self.window layoutIfNeeded];BOOL visible=UIApplication.sharedApplication.applicationState==UIApplicationStateActive&&self.window.isKeyWindow&&nav.topViewController==owner&&owner.view.window==self.window&&!nav.transitionCoordinator&&owner.table.visibleCells.count>0;
        NSUInteger next=visible?stable+1:0;
        if(next>=3||remaining==0){
            Check(next>=3,@"added-route-capture-waits-for-visible-stable-content");
            SaveScreen(self.window,@[@"secondary-sessions",@"secondary-session-import",@"secondary-cloud-batch",@"secondary-session-export",@"secondary-session-destination"][index]);
            [self exerciseAddedRoutes:nav index:index+1];
        }else [self captureAddedRoute:owner navigation:nav index:index remaining:remaining-1 stable:next];
    });
}
- (void)finish {
    NSString *dir=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSDictionary *report=@{@"ok":@(Failures.count==0),@"failures":Failures,@"scope":@"synthetic UIKit renderer only",@"checks":@(Checks)};
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[dir stringByAppendingPathComponent:@"secondary-result.json"] atomically:YES];
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(SBSecondaryFixtureApp.class));}}
