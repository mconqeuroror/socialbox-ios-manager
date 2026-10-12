#import "RBXAppScope.h"
#import "RBXIsolationViewController.h"
#import "RBXAcceptanceChecks.h"
#import "RBXLauncherIPC.h"
#import "RBXDiagnosticsViewController.h"
#import "RBXAppearance.h"
@interface RBXIsolationViewController ()
@property(nonatomic, copy) NSDictionary *appDescriptor;
@property NSArray *checks,*history;
@property NSTimer *timer;
@property NSString *feedback;
@end
@implementation RBXIsolationViewController
- (instancetype)init { return [self initWithAppType:@"reddit"]; }
- (instancetype)initWithAppType:(NSString *)appType {
 NSDictionary *descriptor = [appType isKindOfClass:NSString.class] ? RBXAppDescriptorForType(appType) : nil;
 if (!descriptor) return nil;
 if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _appDescriptor = descriptor;
 return self;
}
- (NSString *)requestOwner { return RBXAppScopedPreferenceKey(@"isolation-monitor", self.appDescriptor); }
- (void)viewDidLoad {
 [super viewDidLoad];self.title=@"Isolation checks";self.tableView.backgroundColor=RBXCanvasColor();self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=90;
 self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
 self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Run checks" style:UIBarButtonItemStylePlain target:self action:@selector(run)];
}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];[self reload];__weak typeof(self) weak=self;self.timer=[NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *t){[weak reload];}];}
- (void)viewWillDisappear:(BOOL)animated {[super viewWillDisappear:animated];[self.timer invalidate];self.timer=nil;}
- (void)run {
 if([RBXLauncherIPC pendingRequestsForOwner:self.requestOwner].count)return;
 self.feedback=[RBXLauncherIPC sendActionReturningRequestId:@"runDiagnostics" values:@{} notification:CFSTR("com.redditbox.launcherAction") owner:self.requestOwner appType:self.appDescriptor[@"appType"]]?@"Checking…":@"Could not request checks. Try again.";[self reload];
}
- (void)reload {
 NSDictionary *state=RBXAppScopedLauncherState([NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist"], self.appDescriptor)?:@{};
 for(NSDictionary *r in [RBXLauncherIPC pendingRequestsForOwner:self.requestOwner]) {
  NSDictionary *result=[RBXLauncherIPC requestResultForId:r[@"requestId"]];
  if(result){self.feedback=result[@"message"];[RBXLauncherIPC finishObservingRequestId:r[@"requestId"] owner:self.requestOwner];}
 }
 self.checks=RBXAcceptanceChecks(state,NSDate.date.timeIntervalSince1970);
 NSMutableDictionary *statuses=[NSMutableDictionary dictionary];NSUInteger fail=0,unknown=0;
 for(NSDictionary *c in self.checks){statuses[c[@"id"]]=c[@"status"];fail += [c[@"status"] isEqual:@"FAIL"];unknown += [c[@"status"] isEqual:@"NOT_RUN"];}
 // Local bounded change history contains check IDs/statuses only, no credentials
 // or raw profile identifiers. A historical result never becomes current proof.
 id stored=[NSUserDefaults.standardUserDefaults objectForKey:RBXAppScopedPreferenceKey(@"RBXIsolationCheckHistory", self.appDescriptor)];
 NSMutableArray *history=[NSMutableArray array];
 if([stored isKindOfClass:NSArray.class])for(id row in stored)if([row isKindOfClass:NSDictionary.class] && [row[@"statuses"] isKindOfClass:NSDictionary.class] && [row[@"at"] isKindOfClass:NSNumber.class] && [row[@"failed"] isKindOfClass:NSNumber.class] && [row[@"unverified"] isKindOfClass:NSNumber.class]){[history addObject:row];if(history.count==50)break;}
 if(![history.firstObject[@"statuses"] isEqual:statuses]) {
  [history insertObject:@{@"at":@(NSDate.date.timeIntervalSince1970),@"statuses":statuses,@"failed":@(fail),@"unverified":@(unknown)} atIndex:0];
  if(history.count>50)[history removeObjectsInRange:NSMakeRange(50,history.count-50)];
  [NSUserDefaults.standardUserDefaults setObject:history forKey:RBXAppScopedPreferenceKey(@"RBXIsolationCheckHistory", self.appDescriptor)];
 }
 self.history=history;self.navigationItem.prompt=[NSString stringWithFormat:@"%lu failed · %lu unverified",(unsigned long)fail,(unsigned long)unknown];
 self.navigationItem.rightBarButtonItem.enabled=![RBXLauncherIPC pendingRequestsForOwner:self.requestOwner].count;
 [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{return 4;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{return section==0?1:section==1?self.checks.count:section==2?MIN(self.history.count,10):1;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section{return @[@"What is verified",@"Current observations",@"Recent changes on this device",@"More detail"][section];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return section==0?self.feedback:nil; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
 UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
 if(indexPath.section==0){cell.textLabel.text=@"Isolation is not fully verified";cell.textLabel.textColor=[UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1];cell.detailTextLabel.text=@"Live status and recent diagnostic results are tracked here. Hook readiness alone cannot prove 100% isolation. A/B storage checks and packet captures need separate device evidence. Stale results become Unverified; history is not a current pass.";}
 else if(indexPath.section==1){NSDictionary *c=self.checks[indexPath.row];NSString *status=[c[@"status"] isEqual:@"PASS"]?@"Verified observation":[c[@"status"] isEqual:@"FAIL"]?@"Failed":@"Unverified";cell.textLabel.text=[NSString stringWithFormat:@"%@ · %@",status,c[@"title"]];cell.textLabel.textColor=[c[@"status"] isEqual:@"FAIL"]?UIColor.systemRedColor:[c[@"status"] isEqual:@"PASS"]?UIColor.labelColor:UIColor.secondaryLabelColor;cell.detailTextLabel.text=c[@"detail"];}
 else if(indexPath.section==2){NSDictionary *h=self.history[indexPath.row];cell.textLabel.text=[NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[h[@"at"] doubleValue]] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle];cell.detailTextLabel.text=[NSString stringWithFormat:@"Historical snapshot · %@ failed · %@ unverified",h[@"failed"],h[@"unverified"]];}
 else{cell.textLabel.text=@"Detailed diagnostics and support log";cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}
 return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {[tableView deselectRowAtIndexPath:indexPath animated:YES];if(indexPath.section==3)[self.navigationController pushViewController:[[RBXDiagnosticsViewController alloc] initWithAppType:self.appDescriptor[@"appType"]] animated:YES];}
@end
