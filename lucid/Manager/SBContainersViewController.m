#import "SBContainersViewController.h"
#import "SBDesign.h"
#import "SBInterfaceCopy.h"
#import "../HelperClient/LBXHelperClient.h"
#import "../HelperClient/LBXContainerStore.h"
#import "../Switching/LBXSocialBoxProduct.h"

@interface SBContainersViewController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) UIView *header;
@property(nonatomic, strong) UILabel *headingTitle;
@property(nonatomic, strong) UILabel *selectedName;
@property(nonatomic, strong) UILabel *swipeHint;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *createButton;
@property(nonatomic, strong) LBXHelperClient *helper;
@property(nonatomic, strong) LBXContainerStore *store;
@property(nonatomic, copy) NSArray<NSString *> *apps;
@property(nonatomic, copy) NSArray<LBXContainerRecord *> *rows;
@property(nonatomic, copy) NSDictionary<NSString *, NSNumber *> *activeByApp;
@property(nonatomic) BOOL busy;
@end

@implementation SBContainersViewController

static NSString *SBAppTitle(NSString *bundleID) {
    return [bundleID isEqualToString:LBXContainerStoreInstagram] ? @"Instagram" : @"Facebook";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = SBUIText(@"brand.name");
    self.view.backgroundColor = SBInk();
    self.view.tintColor = SBAccent();
    self.view.accessibilityIdentifier = @"socialbox.containers";
    self.helper = [LBXHelperClient new];
    self.store = [LBXContainerStore new];
    self.apps = @[ LBXContainerStoreInstagram, LBXContainerStoreFacebook ];
    self.rows = @[];
    self.activeByApp = @{};

    self.navigationItem.leftBarButtonItems = @[];
    self.navigationItem.rightBarButtonItems = @[];
    UINavigationBarAppearance *bar = [UINavigationBarAppearance new];
    [bar configureWithOpaqueBackground];
    bar.backgroundColor = SBInk();
    bar.shadowColor = UIColor.clearColor;
    bar.titleTextAttributes = @{
        NSForegroundColorAttributeName : UIColor.whiteColor,
        NSFontAttributeName : [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold],
    };
    self.navigationItem.standardAppearance = bar;
    self.navigationItem.scrollEdgeAppearance = bar;
    self.navigationController.navigationBar.tintColor = SBAccent();

    self.headingTitle = SBLabel(SBUIText(@"nav.containers"), 32, UIFontWeightBold);
    self.headingTitle.accessibilityIdentifier = @"socialbox.containers.title";
    self.selectedName = SBLabel(@"", 17, UIFontWeightSemibold);
    self.selectedName.textColor = SBAccent();
    self.selectedName.accessibilityIdentifier = @"socialbox.containers.selectedName";
    self.selectedName.numberOfLines = 1;
    self.selectedName.lineBreakMode = NSLineBreakByTruncatingTail;
    self.swipeHint = SBLabel(SBUIText(@"containers.swipeHint"), 13, UIFontWeightRegular);
    self.swipeHint.textColor = SBMuted();
    self.swipeHint.numberOfLines = 2;
    self.swipeHint.accessibilityIdentifier = @"socialbox.containers.swipeHint";
    self.statusLabel = SBLabel(@"", 13, UIFontWeightRegular);
    self.statusLabel.textColor = SBMuted();
    self.statusLabel.accessibilityIdentifier = @"socialbox.containers.status";

    UIStackView *headings = [[UIStackView alloc]
        initWithArrangedSubviews:@[ self.headingTitle, self.selectedName, self.swipeHint, self.statusLabel ]];
    headings.axis = UILayoutConstraintAxisVertical;
    headings.spacing = 6;
    headings.translatesAutoresizingMaskIntoConstraints = NO;
    self.header = [UIView new];
    self.header.backgroundColor = SBInk();
    [self.header addSubview:headings];
    [NSLayoutConstraint activateConstraints:@[
        [headings.leadingAnchor constraintEqualToAnchor:self.header.leadingAnchor constant:8],
        [headings.trailingAnchor constraintEqualToAnchor:self.header.trailingAnchor constant:-8],
        [headings.topAnchor constraintEqualToAnchor:self.header.topAnchor constant:16],
        [headings.bottomAnchor constraintEqualToAnchor:self.header.bottomAnchor constant:-12],
    ]];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = SBInk();
    self.tableView.separatorColor = [SBMuted() colorWithAlphaComponent:0.15];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 82;
    self.tableView.sectionHeaderTopPadding = 8;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.tableHeaderView = self.header;
    self.tableView.accessibilityIdentifier = @"socialbox.containers.table";
    UIRefreshControl *refresh = [UIRefreshControl new];
    refresh.tintColor = SBAccent();
    [refresh addTarget:self action:@selector(refreshTapped) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = refresh;
    [self.view addSubview:self.tableView];

    __weak typeof(self) weakSelf = self;
    self.createButton = SBButton(SBUIText(@"containers.create"), @"plus", YES, ^{
        [weakSelf createTapped];
    });
    self.createButton.accessibilityIdentifier = @"socialbox.containers.create";
    self.createButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.createButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.createButton.topAnchor constant:-12],
        [self.createButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.createButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.createButton.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor
                                                       constant:-12],
        [self.createButton.heightAnchor constraintGreaterThanOrEqualToConstant:48],
    ]];

    [self reload];
    [self pingHelperStatus:@"Tap a container to switch Instagram and Facebook together."];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.tableView.bounds.size.width;
    if (width <= 0) return;
    CGSize size = [self.header systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                             withHorizontalFittingPriority:UILayoutPriorityRequired
                                   verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGRect frame = CGRectMake(0, 0, width, ceil(size.height));
    if (!CGRectEqualToRect(self.header.frame, frame)) {
        self.header.frame = frame;
        self.tableView.tableHeaderView = self.header;
    }
}

- (void)setStatus:(NSString *)text {
    self.statusLabel.text = text;
    [self.view setNeedsLayout];
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    self.view.userInteractionEnabled = !busy;
    self.createButton.enabled = !busy;
}

- (void)pingHelperStatus:(NSString *)readyText {
    LBXHelperClient *helper = self.helper;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL alive = [helper ping:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setStatus:alive ? readyText : @"SocialBox helper is not running."];
        });
    });
}

- (void)refreshTapped {
    [self reload];
    [self.tableView.refreshControl endRefreshing];
    [self pingHelperStatus:@"Up to date."];
}

- (long long)activePhoneID {
    long long ig = self.activeByApp[LBXContainerStoreInstagram].longLongValue;
    long long fb = self.activeByApp[LBXContainerStoreFacebook].longLongValue;
    if (ig > 0 && ig == fb) return ig;
    return ig > 0 ? ig : fb;
}

- (void)reload {
    NSError *error = nil;
    NSArray<LBXContainerRecord *> *all = [self.store listContainers:&error] ?: @[];
    NSMutableDictionary *active = [NSMutableDictionary dictionary];
    for (NSString *bundleID in self.apps) {
        active[bundleID] = @([self.store activeContainerIDForBundleID:bundleID error:nil]);
    }
    self.rows = all;
    self.activeByApp = active;
    long long phone = [self activePhoneID];
    NSString *selected = nil;
    for (LBXContainerRecord *record in all) {
        if (record.containerID == phone) {
            selected = record.name;
            break;
        }
    }
    self.selectedName.text = selected ? [NSString stringWithFormat:SBUIText(@"containers.selectedName"), selected]
                                      : nil;
    self.selectedName.hidden = selected == nil;
    self.swipeHint.hidden = all.count == 0;
    [self.tableView reloadData];
    if (!all.count) {
        UIView *footer = [UIView new];
        UILabel *label = SBLabel(SBUIText(@"containers.empty"), 16, UIFontWeightRegular);
        label.textColor = SBMuted();
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.accessibilityIdentifier = @"socialbox.containers.empty";
        [footer addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:8],
            [label.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-8],
            [label.topAnchor constraintEqualToAnchor:footer.topAnchor constant:20],
            [label.bottomAnchor constraintEqualToAnchor:footer.bottomAnchor constant:-20],
        ]];
        CGFloat width = self.tableView.bounds.size.width ?: self.view.bounds.size.width;
        footer.frame = CGRectMake(0, 0, width, 80);
        self.tableView.tableFooterView = footer;
    } else {
        self.tableView.tableFooterView = nil;
    }
}

#pragma mark - Create

- (void)createTapped {
    if (self.busy) return;
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"New container"
                                            message:@"Creates an empty phone for Instagram and Facebook, "
                                                    @"including their shared Meta folders."
                                     preferredStyle:UIAlertControllerStyleAlert];
    long long next = [self.store nextContainerID:nil];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Name";
        field.text = [NSString stringWithFormat:@"Container %lld", next];
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.textColor = UIColor.whiteColor;
        field.keyboardAppearance = UIKeyboardAppearanceDark;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Create"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                                (void)action;
                                                [weakSelf createNamed:alert.textFields.firstObject.text];
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)createNamed:(NSString *)name {
    NSError *error = nil;
    if (![self.helper ping:&error]) {
        [self setStatus:[NSString stringWithFormat:@"Create failed: %@", error.localizedDescription]];
        return;
    }
    long long cid = [self.store nextContainerID:&error];
    if (cid < 1) {
        [self setStatus:@"Create failed: could not allocate a container ID."];
        return;
    }
    for (NSString *bundleID in self.apps) {
        if (![self.helper bootstrapBundleID:bundleID containerID:cid error:&error]) {
            [self setStatus:[NSString stringWithFormat:@"Create failed for %@: %@", SBAppTitle(bundleID),
                                                       error.localizedDescription]];
            return;
        }
        [self.helper chownRecursiveToMobileAtPath:[self.store controlPathForBundleID:bundleID containerID:cid]
                                            error:nil];
    }
    [self.helper chownRecursiveToMobileAtPath:[self.store profilePathForContainerID:cid] error:nil];
    [self.helper chownRecursiveToMobileAtPath:self.store.controlRoot error:nil];

    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    LBXContainerRecord *record = [LBXContainerRecord new];
    record.containerID = cid;
    record.name = trimmed.length ? trimmed : [NSString stringWithFormat:@"Container %lld", cid];
    record.apps = self.apps;
    if (![self.store upsertContainer:record error:&error]) {
        [self setStatus:[NSString stringWithFormat:@"Create failed: %@", error.localizedDescription]];
        return;
    }
    [self reload];
    [self setStatus:[NSString stringWithFormat:@"Created “%@”. Tap it to switch this phone to it.", record.name]];
}

#pragma mark - Rename / Delete / Switch

- (void)renameRecord:(LBXContainerRecord *)record {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:SBUIText(@"container.rename")
                                                                   message:record.name
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = record.name;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.textColor = UIColor.whiteColor;
        field.keyboardAppearance = UIKeyboardAppearanceDark;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                                (void)action;
                                                NSError *error = nil;
                                                NSString *name = alert.textFields.firstObject.text;
                                                if (![weakSelf.store renameContainerID:record.containerID
                                                                                toName:name
                                                                                 error:&error]) {
                                                    [weakSelf setStatus:[NSString stringWithFormat:@"Rename failed: %@",
                                                                                                   error.localizedDescription]];
                                                    return;
                                                }
                                                [weakSelf reload];
                                                [weakSelf setStatus:@"Renamed."];
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)deleteRecord:(LBXContainerRecord *)record {
    if (record.containerID == [self activePhoneID]) {
        [self setStatus:@"Switch away from this container before deleting it."];
        return;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Delete container"
                         message:[NSString stringWithFormat:
                                               @"Delete “%@” and its parked Instagram, Facebook, "
                                               @"and shared Meta data? This cannot be undone.",
                                               record.name]
                  preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:SBUIText(@"container.delete")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
                                                (void)action;
                                                [weakSelf performDelete:record];
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performDelete:(LBXContainerRecord *)record {
    if (self.busy) return;
    self.busy = YES;
    [self setStatus:[NSString stringWithFormat:@"Deleting “%@”…", record.name]];
    LBXContainerStore *store = self.store;
    LBXHelperClient *helper = self.helper;
    long long cid = record.containerID;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = [store deleteContainerID:cid helper:helper error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            [self reload];
            [self setStatus:ok ? [NSString stringWithFormat:@"Deleted “%@”.", record.name]
                               : [NSString stringWithFormat:@"Delete failed: %@",
                                                            error.localizedDescription ?: @"unknown error"]];
        });
    });
}

- (void)switchToRecord:(LBXContainerRecord *)record {
    if (self.busy) return;
    if (record.containerID == [self activePhoneID]) return;
    self.busy = YES;
    [self setStatus:[NSString stringWithFormat:@"Closing Instagram and Facebook, switching to “%@”…",
                                               record.name]];
    LBXContainerStore *store = self.store;
    LBXHelperClient *helper = self.helper;
    long long cid = record.containerID;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = [store activateContainerID:cid
                                forBundleIDs:@[ LBXContainerStoreInstagram, LBXContainerStoreFacebook ]
                                      helper:helper
                                       error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            [self reload];
            [self setStatus:ok ? [NSString stringWithFormat:
                                               @"Instagram and Facebook are now using “%@”. Open the apps "
                                               @"to continue.",
                                               record.name]
                               : [NSString stringWithFormat:@"Switch failed: %@",
                                                            error.localizedDescription ?: @"unknown error"]];
        });
    });
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return (NSInteger)self.apps.count;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)tableView;
    UIView *view = [UIView new];
    view.backgroundColor = SBInk();
    UILabel *label = SBLabel(SBAppTitle(self.apps[(NSUInteger)section]), 13, UIFontWeightSemibold);
    label.textColor = SBMuted();
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:8],
        [label.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-8],
        [label.topAnchor constraintEqualToAnchor:view.topAnchor constant:12],
        [label.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-4],
    ]];
    return view;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 36;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SBContainer"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"SBContainer"];
    }
    NSString *bundleID = self.apps[(NSUInteger)indexPath.section];
    LBXContainerRecord *record = self.rows[(NSUInteger)indexPath.row];
    BOOL selected = record.containerID == self.activeByApp[bundleID].longLongValue;
    UIListContentConfiguration *content = UIListContentConfiguration.cellConfiguration;
    content.text = record.name;
    content.secondaryText = selected ? @"Active phone" : [NSString stringWithFormat:@"ID %lld", record.containerID];
    content.image = SBGlyph(@"containers");
    content.imageProperties.tintColor = selected ? SBAccent() : SBMuted();
    content.textProperties.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledFontForFont:[UIFont systemFontOfSize:17]
          maximumPointSize:26
        compatibleWithTraitCollection:self.traitCollection];
    content.textProperties.adjustsFontForContentSizeCategory = NO;
    content.textProperties.color = UIColor.whiteColor;
    content.textProperties.numberOfLines = 0;
    content.secondaryTextProperties.color = selected ? SBAccent() : SBMuted();
    content.secondaryTextProperties.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(16, 10, 16, 10);
    cell.contentConfiguration = content;
    cell.backgroundColor = selected ? SBPanel() : SBInk();
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessibilityIdentifier =
        [NSString stringWithFormat:@"socialbox.container.%@.%lld", bundleID, record.containerID];

    __weak typeof(self) weakSelf = self;
    UIButton *button = SBButton((selected ? SBUIText(@"containers.rowSelected") : SBUIText(@"container.switch")),
                                @"containers", !selected, ^{
                                    [weakSelf switchToRecord:record];
                                });
    UIButtonConfiguration *configuration = button.configuration;
    configuration.image = nil;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(12, 10, 12, 10);
    UIFont *actionFont = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledFontForFont:[UIFont systemFontOfSize:17]
          maximumPointSize:20
        compatibleWithTraitCollection:self.traitCollection];
    configuration.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *input) {
        NSMutableDictionary *values = [input mutableCopy];
        values[NSFontAttributeName] = actionFont;
        return values;
    };
    configuration.titleAlignment = UIButtonConfigurationTitleAlignmentCenter;
    button.configuration = configuration;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    button.accessibilityIdentifier =
        [NSString stringWithFormat:@"socialbox.container.switch.%lld", record.containerID];
    button.enabled = !selected && !self.busy;
    button.frame = CGRectMake(0, 0, 104, 48);
    cell.accessoryView = button;
    cell.selectionStyle = selected ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    UIView *selectedBg = [UIView new];
    selectedBg.backgroundColor = SBPanel();
    cell.selectedBackgroundView = selectedBg;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row < 0 || (NSUInteger)indexPath.row >= self.rows.count) return;
    LBXContainerRecord *row = self.rows[(NSUInteger)indexPath.row];
    BOOL active = row.containerID == [self activePhoneID];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:row.name
                                                                   message:@"Instagram + Facebook + shared folders"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    if (!active) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Switch this phone"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
                                                    (void)action;
                                                    [weakSelf switchToRecord:row];
                                                }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:SBUIText(@"container.rename")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                                (void)action;
                                                [weakSelf renameRecord:row];
                                            }]];
    if (!active) {
        [sheet addAction:[UIAlertAction actionWithTitle:SBUIText(@"container.delete")
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *action) {
                                                    (void)action;
                                                    [weakSelf deleteRecord:row];
                                                }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell ?: tableView;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectZero;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)swipeAtIndex:(NSIndexPath *)index
                                       action:(NSString *)action
                                        title:(NSString *)title
                                  destructive:(BOOL)destructive {
    if (index.row < 0 || (NSUInteger)index.row >= self.rows.count) return nil;
    LBXContainerRecord *record = self.rows[(NSUInteger)index.row];
    BOOL active = record.containerID == [self activePhoneID];
    if (destructive && active) return nil;
    __weak typeof(self) weakSelf = self;
    __block BOOL consumed = NO;
    UIContextualAction *entry = [UIContextualAction
        contextualActionWithStyle:destructive ? UIContextualActionStyleDestructive : UIContextualActionStyleNormal
                            title:title
                          handler:^(__unused UIContextualAction *sender, __unused UIView *view,
                                    void (^complete)(BOOL)) {
                              if (consumed) {
                                  complete(NO);
                                  return;
                              }
                              consumed = YES;
                              if ([action isEqualToString:@"delete"]) {
                                  [weakSelf deleteRecord:record];
                              } else {
                                  [weakSelf renameRecord:record];
                              }
                              complete(NO);
                          }];
    entry.backgroundColor = destructive ? UIColor.systemRedColor : SBAccent();
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[ entry ]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)table
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)index {
    (void)table;
    return [self swipeAtIndex:index action:@"delete" title:SBUIText(@"container.delete") destructive:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)table
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)index {
    (void)table;
    return [self swipeAtIndex:index action:@"rename" title:SBUIText(@"container.rename") destructive:NO];
}

@end
