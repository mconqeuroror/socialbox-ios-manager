#import "RBXAppScope.h"
#import "RBXDiagnosticsViewController.h"
#import "RBXLauncherIPC.h"
#import "RBXAppearance.h"
#import "RBXAcceptanceChecks.h"
#import "RBXOperatorWording.h"
#import "RBXIsolationSentinel.h"

static NSString *const RBXLauncherStatePath =
    @"/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist";

@interface RBXDiagnosticsViewController ()
@property(nonatomic, copy) NSDictionary *appDescriptor;
@property(nonatomic, copy) NSArray<NSDictionary *> *checks;
@property(nonatomic, copy) NSArray<NSDictionary *> *sentinelChecks;
@property(nonatomic, copy) NSDictionary *completedReport;
@property(nonatomic) BOOL advancedMode;
@property(nonatomic, strong) UIButton *advancedButton;
@property(nonatomic, strong) NSTimer *displayTimer;
- (void)loadReport;
@end

static void RBXDiagnosticsStateChanged(CFNotificationCenterRef center, void *observer,
                                       CFStringRef name, const void *object,
                                       CFDictionaryRef userInfo) {
    RBXDiagnosticsViewController *controller =
        (__bridge RBXDiagnosticsViewController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{ [controller loadReport]; });
}

@implementation RBXDiagnosticsViewController

- (instancetype)init { return [self initWithAppType:@"reddit"]; }
- (instancetype)initWithAppType:(NSString *)appType {
 NSDictionary *descriptor = [appType isKindOfClass:NSString.class] ? RBXAppDescriptorForType(appType) : nil;
 if (!descriptor) return nil;
 if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _appDescriptor = descriptor;
 return self;
}
- (NSString *)requestOwner { return RBXAppScopedPreferenceKey(@"diagnostics", self.appDescriptor); }

- (void)viewDidLoad {
    [super viewDidLoad];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(requestsDidBecomeActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    self.title = @"Diagnostics";
    self.tableView.backgroundColor = RBXCanvasColor();
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 70;
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Share Logs"
            style:UIBarButtonItemStylePlain target:self action:@selector(exportLogs)],
        [[UIBarButtonItem alloc] initWithTitle:RBXOperatorText(@"checks") style:UIBarButtonItemStylePlain
            target:self action:@selector(runDiagnostics)],
    ];
    self.advancedButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.advancedButton setTitle:RBXOperatorText(@"advanced") forState:UIControlStateNormal];
    self.advancedButton.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, 56);
    [self.advancedButton addTarget:self action:@selector(toggleAdvanced) forControlEvents:UIControlEventTouchUpInside];
    self.tableView.tableHeaderView = self.advancedButton;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, RBXDiagnosticsStateChanged,
        CFSTR("com.redditbox.launcherStateChanged"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    [self loadReport];
    if (![self hasPendingAction:@"runDiagnostics"]) [self runDiagnostics];
}

- (void)dealloc {
    [self.displayTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, NULL, NULL);
}

- (void)toggleAdvanced {
    self.advancedMode = !self.advancedMode;
    [self.advancedButton setTitle:self.advancedMode ? @"Show Simple results" : RBXOperatorText(@"advanced") forState:UIControlStateNormal];
    [self loadReport];
}

- (void)runDiagnostics {
    if ([self hasPendingAction:@"runDiagnostics"]) return;
    self.completedReport = nil;
    self.navigationItem.prompt = @"Waiting for diagnostics…";
    if (![RBXLauncherIPC sendActionReturningRequestId:@"runDiagnostics" values:@{}
        notification:CFSTR("com.redditbox.launcherAction") owner:self.requestOwner appType:self.appDescriptor[@"appType"]]) {
        self.navigationItem.prompt = @"Diagnostics request could not be sent";
    }
}

- (void)requestsDidBecomeActive:(NSNotification *)notification {
    [self loadReport];
}

- (void)exportLogs {
    if ([self hasPendingAction:@"exportSupportLog"]) return;
    self.navigationItem.prompt = @"Waiting for log export…";
    if (![RBXLauncherIPC sendActionReturningRequestId:@"exportSupportLog" values:@{}
        notification:CFSTR("com.redditbox.launcherAction") owner:self.requestOwner appType:self.appDescriptor[@"appType"]]) {
        self.navigationItem.prompt = @"Log export request could not be sent";
    }
}

- (BOOL)hasPendingAction:(NSString *)action {
    for (NSDictionary *request in [RBXLauncherIPC pendingRequestsForOwner:self.requestOwner]) {
        if ([request[@"action"] isEqualToString:action]) return YES;
    }
    return NO;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self loadReport];
    __weak typeof(self) weakSelf = self;
    [self.displayTimer invalidate];
    self.displayTimer = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer) { [weakSelf loadReport]; }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.displayTimer invalidate]; self.displayTimer = nil;
}

- (void)loadReport {
    NSDictionary *state = RBXAppScopedLauncherState([NSDictionary dictionaryWithContentsOfFile:RBXLauncherStatePath], self.appDescriptor) ?: @{};
    BOOL publicationFresh = RBXSentinelFresh(state[@"updatedAt"],NSDate.date.timeIntervalSince1970,5);
    NSMutableArray *sentinels = [NSMutableArray array];
    for (NSDictionary *container in state[@"containers"]) {
        NSDictionary *sentinel = container[@"isolationSentinel"];
        if (![sentinel isKindOfClass:NSDictionary.class]) continue;
        NSString *name = container[@"name"] ?: container[@"id"] ?: @"Container";
        NSTimeInterval timestamp = [sentinel[@"timestamp"] doubleValue];
        NSString *date = timestamp > 0 ? [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:timestamp]
            dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle] : @"Never / no current run";
        [sentinels addObject:@{@"title":name,@"status":[sentinel[@"alert"] boolValue] ? @"FAIL" : @"INFO",
            @"detail":[NSString stringWithFormat:@"%@\nLast run: %@",publicationFresh ? (sentinel[@"message"] ?: @"Not verified") : @"Daemon publication is stale; no current runtime coverage.",date]}];
        for (NSDictionary *probe in sentinel[@"rows"]) {
            [sentinels addObject:@{@"title":[NSString stringWithFormat:@"%@ · %@ · %@",name,probe[@"probe"] ?: @"Probe",probe[@"target"] ?: @""],
                @"status":[probe[@"status"] isEqual:@"LEAK"] ? @"FAIL" : (publicationFresh && [sentinel[@"current"] boolValue] ? probe[@"status"] ?: @"NOT_RUN" : @"NOT_RUN"),
                @"detail":[NSString stringWithFormat:@"%@ (code %@)",probe[@"detail"] ?: @"Not verified",probe[@"code"] ?: @0]}];
        }
    }
    self.sentinelChecks = sentinels.count ? sentinels : @[@{@"title":@"Isolation Sentinel",@"status":@"NOT_RUN",
        @"detail":@"Off by default. Enable per container in Edit → Advanced → Isolation Sentinel."}];
    NSDictionary *report = self.completedReport ?: state[@"diagnostics"];
    BOOL canPresent = self.view.window && !self.presentedViewController &&
        self.navigationController.topViewController == self;
    NSDictionary *exportResult = nil;
    if (canPresent) {
        for (NSDictionary *request in [RBXLauncherIPC pendingRequestsForOwner:self.requestOwner]) {
            NSString *requestId = request[@"requestId"];
            NSDictionary *result = [RBXLauncherIPC requestResultForId:requestId];
            if (!result) continue;
            NSDictionary *details = [result[@"details"] isKindOfClass:NSDictionary.class]
                ? result[@"details"] : @{};
            [RBXLauncherIPC finishObservingRequestId:requestId owner:self.requestOwner];
            if ([result[@"action"] isEqualToString:@"runDiagnostics"]) {
                report = [details[@"checks"] isKindOfClass:NSArray.class] ? details : @{
                    @"ok": @NO, @"failureCount": @1, @"checks": @[@{
                        @"id": @"request", @"title": @"Diagnostics request", @"status": @"fail",
                        @"detail": result[@"message"] ?: @"The diagnostic request failed.",
                    }],
                };
                self.completedReport = report;
            } else if ([result[@"action"] isEqualToString:@"exportSupportLog"]) {
                exportResult = result;
                break;
            }
        }
    }
    NSArray *checks = report[@"checks"];
    NSMutableDictionary *evaluatedState = [state mutableCopy];
    if ([report isKindOfClass:NSDictionary.class]) evaluatedState[@"diagnostics"] = report;
    self.checks = self.advancedMode ? ([checks isKindOfClass:NSArray.class] ? checks : @[]) :
        RBXAcceptanceChecks(evaluatedState, NSDate.date.timeIntervalSince1970);
    if ([self hasPendingAction:@"runDiagnostics"]) {
        self.navigationItem.prompt = @"Diagnostics queued or running…";
    } else if (report.count) {
        self.navigationItem.prompt = @"Review each result; device checks remain separate";
    }
    [self.tableView reloadData];

    if (exportResult) {
        if ([exportResult[@"ok"] boolValue]) {
            [self shareLogAtPath:exportResult[@"details"][@"path"]];
        } else {
            [self showMessage:@"Log export failed"
                detail:exportResult[@"message"] ?: @"No support log was generated."];
        }
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 1 ? self.sentinelChecks.count : self.checks.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 1 ? @"Isolation Sentinels" : @"On-device checks";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) return @"A FAIL from a sentinel means unexpected visibility. A retained finding blocks the next Open. The observer does not stop an active session. Missing/stale seeds are NOT RUN, and periodic probes pause while iOS suspends a clone.";
    return @"NOT VERIFIED means evidence is still missing. Run again after opening or switching a container. PASS describes the stated evidence only; login, A/B access denial and actual VPN routing need separate device tests.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"diagnostic";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSDictionary *check = indexPath.section == 1 ? self.sentinelChecks[indexPath.row] : self.checks[indexPath.row];
    NSString *status = check[@"status"] ?: @"fail";
    BOOL passed = [status.uppercaseString isEqualToString:@"PASS"];
    BOOL informational = [@[@"INFO", @"NOT_RUN"] containsObject:status.uppercaseString];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = check[@"title"] ?: @"Check";
    content.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    content.textProperties.numberOfLines = 0;
    NSArray *references = [check[@"rows"] isKindOfClass:NSArray.class] ? check[@"rows"] : @[];
    content.secondaryText = [NSString stringWithFormat:@"%@ · %@%@",
        RBXOperatorText(status), check[@"detail"] ?: RBXOperatorText(@"unavailable"),
        references.count ? [@"\n" stringByAppendingString:[references componentsJoinedByString:@", "]] : @""];
    content.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.secondaryTextProperties.numberOfLines = 0;
    content.image = [UIImage systemImageNamed:passed ? @"checkmark.circle.fill" :
        (informational ? @"info.circle.fill" : @"exclamationmark.circle.fill")];
    content.imageProperties.tintColor = passed ? UIColor.systemGreenColor :
        (informational ? RBXAccentColor() : UIColor.systemRedColor);
    content.imageProperties.preferredSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium];
    content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(18, 16, 18, 16);
    cell.contentConfiguration = content;
    return cell;
}

- (void)shareLogAtPath:(NSString *)path {
    NSData *data = path.length ? [NSData dataWithContentsOfFile:path] : nil;
    if (!data.length) {
        [self showMessage:@"Log unavailable"
            detail:@"The redacted log could not be read by the launcher."];
        return;
    }
    NSString *localPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"RedditBox-Support.txt"];
    if (![data writeToFile:localPath atomically:YES]) {
        [self showMessage:@"Log unavailable"
            detail:@"The support log could not be copied for sharing."];
        return;
    }
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:localPath]]
        applicationActivities:nil];
    share.popoverPresentationController.barButtonItem =
        self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)showMessage:(NSString *)title detail:(NSString *)detail {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:RBXOperatorMessage(detail) preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self dismissViewControllerAnimated:YES completion:^{ [self loadReport]; }];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
