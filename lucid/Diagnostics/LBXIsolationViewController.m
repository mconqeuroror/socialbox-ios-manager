#import "LBXIsolationViewController.h"
#import "LBXIsolationAssessment.h"
#import "LBXRecoveredContextAdapter.h"

@interface LBXIsolationViewController ()
@property(nonatomic, copy) NSDictionary *assessment;
@end

@implementation LBXIsolationViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Isolation checks";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor colorWithRed:0.035 green:0.055 blue:0.09 alpha:1];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 100;
    self.tableView.accessibilityIdentifier = @"socialbox.isolation.table";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)];
    [self refresh];
}
- (void)refresh {
    NSAssert(NSThread.isMainThread, @"Read recovered UI metadata on the main thread only");
    id existing = nil;
    // Only inspect the already-created tab/navigation roots. No loadView,
    // private singleton factory, loadData or recovered IPC is invoked here.
    for (UIViewController *tab in self.tabBarController.viewControllers) {
        NSArray *candidates = [tab isKindOfClass:UINavigationController.class] ? ((UINavigationController *)tab).viewControllers : @[tab];
        for (UIViewController *candidate in candidates) {
            if ([NSStringFromClass(candidate.class) isEqual:@"_Xc9m"] && candidate.isViewLoaded) existing = candidate;
        }
    }
    self.assessment = LBXIsolationAssessment(LBXRecoveredContextSnapshot(existing), NSDate.date);
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; return section == 2 ? [self.assessment[@"rows"] count] : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; return @[@"Current evidence", @"Selected workspace", @"Isolation Sentinels", @"Support report"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"Refresh reads management metadata only. It does not modify identities, containers, licensing, proxy settings or the network gate.";
    if (section == 2) return @"These requirements are retained from SocialBox. The earlier clone-based reports do not apply to this app-data-switching backend. No automatic all-clear or 100% isolation claim is made.";
    if (section == 3) return @"Export contains fixed check names, verdicts, timestamp and context count. Account names, container IDs, identity values, licence keys and proxy credentials are excluded.";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = [UIColor colorWithRed:0.08 green:0.10 blue:0.15 alpha:1];
    cell.textLabel.numberOfLines = cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.textLabel.adjustsFontForContentSizeCategory = cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (indexPath.section == 0) {
        cell.textLabel.text = @"Needs device verification";
        cell.textLabel.textColor = [UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1];
        cell.detailTextLabel.text = @"Last runtime probe: Not run\nThis screen does not read account data. It separates launcher observations from evidence collected inside the app.";
        cell.accessibilityIdentifier = @"socialbox.isolation.summary";
    } else if (indexPath.section == 1) {
        BOOL observed = [self.assessment[@"selectionStatus"] isEqual:@"OBSERVED_CACHED_UI"];
        cell.textLabel.text = observed ? @"Cached selection observed" : @"Selection not verified";
        NSString *at = [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[self.assessment[@"refreshedAt"] doubleValue]] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle];
        NSString *list = [self.assessment[@"metadataStatus"] isEqual:@"AVAILABLE"]
            ? [NSString stringWithFormat:@"%@ context(s) reported by the launcher.", self.assessment[@"contextCount"]]
            : @"Container list unavailable. Visit Containers, then refresh these checks.";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\nRefreshed %@.\nThis does not establish the active context inside a running app.", list, at];
    } else if (indexPath.section == 2) {
        NSDictionary *row = self.assessment[@"rows"][indexPath.row];
        cell.textLabel.text = [NSString stringWithFormat:@"Not run · %@", row[@"title"]];
        cell.detailTextLabel.text = row[@"detail"];
        cell.accessibilityIdentifier = [@"socialbox.isolation." stringByAppendingString:row[@"id"]];
    } else {
        cell.textLabel.text = @"Share diagnostic report";
        cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
        cell.tintColor = [UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1];
        cell.textLabel.textColor = cell.tintColor;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessibilityIdentifier = @"socialbox.isolation.export";
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 3) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:LBXIsolationPublicReport(self.assessment) options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    if (!data) return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]] applicationActivities:nil];
    share.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
    share.popoverPresentationController.sourceRect = [tableView cellForRowAtIndexPath:indexPath].bounds;
    [self presentViewController:share animated:YES completion:nil];
}
@end
