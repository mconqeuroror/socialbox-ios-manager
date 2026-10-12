#import "RBXCloudVaultViewController.h"
#import "RBXAppScope.h"
#import "RBXAppearance.h"
#import "RBXLauncherIPC.h"
#import "RBXSecureConfig.h"
#import "RBXLicensePresentation.h"
#import "RBXWorkspacePresentation.h"

// Build links from the active, registered app and the configured production
// origin. Never route a Facebook backup to the Reddit console.
static NSURL *RBXCloudConsoleURL(NSString *origin, NSDictionary *descriptor) {
    if (!RBXAppDescriptorIsRegistered(descriptor) || ![origin isKindOfClass:NSString.class]) return nil;
    NSURLComponents *url = [NSURLComponents componentsWithString:origin];
    if (![url.scheme.lowercaseString isEqual:@"https"] || !url.host.length || url.user.length || url.password.length) return nil;
    url.path = [@"/apps/" stringByAppendingString:descriptor[@"appType"]];
    url.query = nil;
    url.fragment = @"cloud-backups";
    return url.URL;
}

// A regular searchable list stays usable with dozens of containers.
@interface RBXCloudContainerPicker : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, copy) NSArray<NSDictionary *> *containers;
@property(nonatomic, copy) NSArray<NSDictionary *> *visibleContainers;
@property(nonatomic, copy) void (^selection)(NSDictionary *);
@property(nonatomic, strong) UISearchController *search;
@end
@implementation RBXCloudContainerPicker
- (void)viewDidLoad {
    [super viewDidLoad]; self.title=@"Back up a container";
    self.search=[[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater=self; self.search.obscuresBackgroundDuringPresentation=NO;
    self.search.searchBar.placeholder=@"Search containers";
    self.navigationItem.searchController=self.search; self.definesPresentationContext=YES;
    self.tableView.rowHeight=UITableViewAutomaticDimension; self.tableView.estimatedRowHeight=60;
    [self updateSearchResultsForSearchController:self.search];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)search {
    self.visibleContainers=RBXWorkspaceRows(self.containers,search.searchBar.text ?: @"",1);
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.visibleContainers.count; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.visibleContainers.count ? @"Choose a container, then confirm its encrypted backup." : @"No matching containers. Create a container or change your search.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    NSDictionary *row=self.visibleContainers[path.row];
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text=RBXWorkspaceText(row[@"name"]).length ? row[@"name"] : row[@"id"];
    cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.textLabel.numberOfLines=0;
    cell.detailTextLabel.text=RBXWorkspaceText(row[@"identity"]);cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    NSDictionary *row=self.visibleContainers[path.row];
    [self.navigationController popViewControllerAnimated:NO];
    if(self.selection) self.selection(row);
}
@end

@interface RBXCloudVaultViewController () <UISearchResultsUpdating>
@property(nonatomic, copy) NSDictionary *appDescriptor;
@property(nonatomic, copy) NSArray<NSDictionary *> *backups;
@property(nonatomic, copy) NSArray<NSDictionary *> *visibleBackups;
@property(nonatomic, copy) NSString *serverURL;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) BOOL requestedList;
@end
@implementation RBXCloudVaultViewController
- (instancetype)initWithAppType:(NSString *)appType {
    NSDictionary *descriptor = RBXAppDescriptorForType(appType);
    if (!descriptor) return nil;
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _appDescriptor = descriptor;
    return self;
}
- (NSString *)requestOwner { return RBXAppScopedPreferenceKey(@"cloud-vault",self.appDescriptor); }
- (NSDictionary *)deviceState {
    return RBXAppScopedLauncherState([NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist"],self.appDescriptor);
}
- (BOOL)available {
    return [self.appDescriptor[@"runnable"] boolValue] && [RBXLicensePresentationState(self.deviceState,NSDate.date.timeIntervalSince1970)[@"unlocked"] boolValue];
}
- (BOOL)busy { return [RBXLauncherIPC pendingRequestsForOwner:self.requestOwner].count != 0; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"Cloud";
    self.tableView.backgroundColor = RBXCanvasColor();
    self.tableView.backgroundView = RBXWorkspaceBackgroundView(self.traitCollection);
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 105;
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(chooseBackupContainer)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshBackups)]];
    self.navigationItem.rightBarButtonItems.firstObject.accessibilityLabel = @"Back up a container";
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self; self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"Search backups or source phones";
    self.navigationItem.searchController = self.search; self.definesPresentationContext = YES;
    UIView *header = [UIView new]; UIStackView *page = RBXVerticalStack(@[],12);
    page.translatesAutoresizingMaskIntoConstraints = NO; [header addSubview:page];
    [NSLayoutConstraint activateConstraints:@[
        [page.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [page.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [page.topAnchor constraintEqualToAnchor:header.topAnchor constant:12],
        [page.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-12]]];
    UIStackView *card = RBXFormSection(page,@"Your encrypted backups",@"Back up here, then restore on another phone activated with the same license and encryption key.");
    self.statusLabel = RBXLabel(@"Refresh to load backups.",UIFontTextStyleSubheadline,YES);
    [card addArrangedSubview:self.statusLabel];
    [card addArrangedSubview:RBXLabel(@"Transfers app files and logical identity. Keychain and hardware-bound credentials stay on the source phone; signing in again may be required.",UIFontTextStyleFootnote,YES)];
    for (NSArray *item in @[@[@"Encryption key",NSStringFromSelector(@selector(encryptionKeyMenu))],@[@"Open web console",NSStringFromSelector(@selector(openWeb))]]) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:item[0] forState:UIControlStateNormal]; RBXStyleButton(button,NO);
        [button addTarget:self action:NSSelectorFromString(item[1]) forControlEvents:UIControlEventTouchUpInside];
        [card addArrangedSubview:button];
    }
    self.tableView.tableHeaderView = header;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(hidePrivateKey) name:UIApplicationDidEnterBackgroundNotification object:nil];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews]; UIView *header = self.tableView.tableHeaderView;
    CGFloat width = self.tableView.bounds.size.width;
    CGFloat height = [header systemLayoutSizeFittingSize:CGSizeMake(width,UILayoutFittingCompressedSize.height) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    if (fabs(header.frame.size.height-height) > .5 || header.frame.size.width != width) { header.frame=CGRectMake(0,0,width,height);self.tableView.tableHeaderView=header; }
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection])
        self.tableView.backgroundView = RBXWorkspaceBackgroundView(self.traitCollection);
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.tableView.backgroundView = RBXWorkspaceBackgroundView(self.tableView.traitCollection);
    [self poll];
    if (!self.requestedList && !self.busy && self.available) [self refreshBackups];
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer){[weakSelf poll];}];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated];[self.timer invalidate];self.timer=nil; }
- (void)dealloc { [self.timer invalidate];[NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)hidePrivateKey {
    if ([self.presentedViewController isKindOfClass:UIAlertController.class]) {
        for (UITextField *field in [(UIAlertController *)self.presentedViewController textFields]) field.text=@"";
        [self.presentedViewController dismissViewControllerAnimated:NO completion:nil];
    }
}
- (void)message:(NSString *)title detail:(NSString *)detail {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:detail preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (BOOL)send:(NSString *)action values:(NSDictionary *)values {
    if (!self.available) { [self message:@"Activation required" detail:@"A current device license and daemon status are required. Open Settings to finish activation."];return NO; }
    if (self.busy) { [self message:@"Cloud operation in progress" detail:@"Wait for the current operation to finish. Switching screens does not cancel it."];return NO; }
    NSString *identifier = [RBXLauncherIPC sendActionReturningRequestId:action values:values notification:CFSTR("com.redditbox.cloudAction") owner:self.requestOwner appType:self.appDescriptor[@"appType"]];
    self.statusLabel.text = identifier ? @"Cloud operation queued or running…" : @"The request could not be sent. Try again.";
    return identifier != nil;
}
- (void)refreshBackups { if ([self send:@"cloudVaultList" values:@{}]) self.requestedList=YES; }
- (void)poll {
    if (!self.view.window || self.navigationController.topViewController != self) return;
    if (!self.available) { [self hidePrivateKey]; self.serverURL=nil; self.backups=@[];self.statusLabel.text=@"Current activation or device status is missing. Finish setup in Settings.";[self filterBackups];return; }
    if (self.presentedViewController) return;
    for (NSDictionary *pending in [RBXLauncherIPC pendingRequestsForOwner:self.requestOwner]) {
        NSString *identifier = pending[@"requestId"];
        NSDictionary *result = [RBXLauncherIPC requestResultForId:identifier];
        if (!result) continue;
        NSString *action = result[@"action"];
        [RBXLauncherIPC finishObservingRequestId:identifier owner:self.requestOwner];
        if (![result[@"ok"] boolValue]) { self.statusLabel.text=result[@"message"] ?: @"Cloud operation failed.";[self message:@"Cloud needs attention" detail:self.statusLabel.text];return; }
        if ([@[@"cloudVaultList",@"cloudVaultKey"] containsObject:action]) {
            NSError *error=nil;
            NSDictionary *payload=[RBXSecureConfig cloudVaultPayloadForIdentifier:identifier response:YES error:&error];
            [RBXSecureConfig clearCloudVaultPayloadForIdentifier:identifier response:YES];
            if (![payload[@"appType"] isEqual:self.appDescriptor[@"appType"]]) {self.statusLabel.text=error.localizedDescription ?: @"Cloud details expired. Refresh to try again.";return;}
            self.serverURL=RBXWorkspaceText(payload[@"serverURL"]);
            if ([action isEqual:@"cloudVaultKey"]) { [self displayPrivateKey:RBXWorkspaceText(payload[@"passphrase"])];return; }
            self.backups=[payload[@"backups"] isKindOfClass:NSArray.class] ? payload[@"backups"] : @[];
            self.statusLabel.text=[NSString stringWithFormat:@"%lu %@ backups · refreshed %@",(unsigned long)self.backups.count,self.appDescriptor[@"displayName"],[NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle]];
            [self filterBackups];
        } else {
            self.statusLabel.text=result[@"message"] ?: @"Operation finished.";
            [self message:@"Cloud operation finished" detail:self.statusLabel.text];
            self.requestedList=NO; return;
        }
    }
    if (!self.requestedList && !self.busy && !self.presentedViewController) [self refreshBackups];
}
- (void)filterBackups {
    NSString *query=[self.search.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.visibleBackups=[self.backups filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings){
        NSString *text=[@[RBXWorkspaceText(row[@"name"]),RBXWorkspaceText(row[@"id"]),RBXWorkspaceText(row[@"deviceName"])] componentsJoinedByString:@" "];
        return !query.length || [text localizedCaseInsensitiveContainsString:query];
    }]];
    [self.tableView reloadData];[self.view setNeedsLayout];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {[self filterBackups];}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return self.visibleBackups.count;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return self.visibleBackups.count?@"Available backups":@"No matching backups · use + to back up a container";}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {return @"App files and logical identity are included. Keychain and hardware-bound credentials are not transferred. Restore creates a new local container; verify login and managed VPN setup before use.";}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row=self.visibleBackups[indexPath.row];
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text=RBXWorkspaceText(row[@"name"]).length?row[@"name"]:row[@"containerId"];
    cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];cell.textLabel.adjustsFontForContentSizeCategory=YES;
    cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ · %@\n%@ · %@",RBXWorkspaceText(row[@"deviceName"]),[NSByteCountFormatter stringFromByteCount:[row[@"size"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile],RBXWorkspaceText(row[@"createdAt"]),[row[@"transferScope"] isEqual:@"same-license"]?@"Same license":@"Original phone only"];
    cell.detailTextLabel.numberOfLines=0;cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    cell.imageView.image=[UIImage systemImageNamed:@"icloud.and.arrow.down"];cell.imageView.tintColor=RBXAccentColor();cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)confirm:(NSString *)title detail:(NSString *)detail action:(NSString *)action values:(NSDictionary *)values destructive:(BOOL)destructive {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:detail preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:title style:destructive?UIAlertActionStyleDestructive:UIAlertActionStyleDefault handler:^(UIAlertAction *choice){[self send:action values:values];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];NSDictionary *row=self.visibleBackups[indexPath.row];
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:row[@"name"] ?: @"Backup" message:@"Choose what to do with this encrypted backup." preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Restore as new container" style:UIAlertActionStyleDefault handler:^(UIAlertAction *choice){[self confirm:@"Restore backup" detail:@"Uses this phone’s encryption key. Existing containers are kept. Protected sessions close while restoring. Check login and MDM installation before opening the restored container." action:@"cloudVaultRestore" values:@{@"backupId":row[@"id"]} destructive:NO];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete from cloud" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *choice){[self confirm:@"Delete backup" detail:@"Permanently removes this cloud backup. Local containers are kept." action:@"cloudVaultDelete" values:@{@"backupId":row[@"id"]} destructive:YES];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView=[tableView cellForRowAtIndexPath:indexPath];sheet.popoverPresentationController.sourceRect=sheet.popoverPresentationController.sourceView.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)chooseBackupContainer {
    if (self.busy || !self.available) {[self message:@"Cloud unavailable" detail:@"Finish the current operation and check activation in Settings."];return;}
    NSMutableArray *eligible=[NSMutableArray array];
    for (NSDictionary *row in RBXWorkspaceRows(self.deviceState[@"containers"],@"",1))
        if (!row[@"deletionState"] && !row[@"profileError"]) [eligible addObject:row];
    RBXCloudContainerPicker *picker=[[RBXCloudContainerPicker alloc] initWithStyle:UITableViewStyleInsetGrouped];
    picker.containers=eligible; __weak typeof(self) weakSelf=self;
    picker.selection=^(NSDictionary *row){
        [weakSelf confirm:@"Create encrypted backup" detail:@"Protected sessions close for a consistent snapshot. Upload includes app files and logical identity, but not Keychain or hardware-bound credentials. The original container is kept." action:@"export" values:@{@"containerId":row[@"id"]} destructive:NO];
    };
    [self.navigationController pushViewController:picker animated:YES];
}
- (void)encryptionKeyMenu {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"Cloud encryption key" message:@"Use the same key on both phones. It stays on your devices; the web console cannot recover it." preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Show / copy current key" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self send:@"cloudVaultKey" values:@{}];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Use key from another phone" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self enterPrivateKey];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView=self.tableView.tableHeaderView;sheet.popoverPresentationController.sourceRect=sheet.popoverPresentationController.sourceView.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)enterPrivateKey {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Use an existing encryption key" message:@"Keep this phone’s previous key: backups made with it still need it. Paste the source phone’s key exactly (16–256 characters)." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.secureTextEntry=YES;field.placeholder=@"Encryption key";field.autocorrectionType=UITextAutocorrectionTypeNo;field.autocapitalizationType=UITextAutocapitalizationTypeNone;}];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save on this phone" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        NSString *phrase=alert.textFields.firstObject.text ?: @"";alert.textFields.firstObject.text=@"";
        if(phrase.length<16 || phrase.length>256 || self.busy || !self.available){[self message:@"Key not saved" detail:@"Enter 16–256 characters and finish any pending operation first."];return;}
        NSString *identifier=NSUUID.UUID.UUIDString;NSError *error=nil;
        if(![RBXSecureConfig saveCloudVaultPayload:@{@"appType":self.appDescriptor[@"appType"],@"passphrase":phrase} identifier:identifier response:NO error:&error]){[self message:@"Key not saved" detail:error.localizedDescription ?: @"Private storage unavailable."];return;}
        if(![self send:@"cloudVaultSetKey" values:@{@"vaultInputId":identifier}]) [RBXSecureConfig clearCloudVaultPayloadForIdentifier:identifier response:NO];
    }]];[self presentViewController:alert animated:YES completion:nil];
}
- (void)displayPrivateKey:(NSString *)phrase {
    if(phrase.length<16){[self message:@"Key unavailable" detail:@"Refresh and try again."];return;}
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Your encryption key" message:@"Keep it private. Copying makes it available on this phone’s clipboard for one minute." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=phrase;field.secureTextEntry=YES;field.userInteractionEnabled=NO;}];
    __weak UITextField *keyField=alert.textFields.firstObject;
    [alert addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){keyField.text=@"";}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy key" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        // A queued tap must not recover a captured key after backgrounding or
        // stale activation cleared the field. Recheck the live publication.
        NSString *displayed=keyField.text ?: @"";
        keyField.text=@"";
        if (!self.available || displayed.length<16 || displayed.length>256) return;
        [UIPasteboard.generalPasteboard setItems:@[@{@"public.utf8-plain-text":displayed}] options:@{UIPasteboardOptionLocalOnly:@YES,UIPasteboardOptionExpirationDate:[NSDate dateWithTimeIntervalSinceNow:60]}];
    }]];[self presentViewController:alert animated:YES completion:nil];
}
- (void)openWeb {
    NSURL *url = RBXCloudConsoleURL(self.serverURL,self.appDescriptor);
    if (!url) {[self message:@"Web console unavailable" detail:@"Refresh the cloud connection first."];return;}
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}
@end
