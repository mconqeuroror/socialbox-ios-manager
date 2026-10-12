#import "SBProxyViewController.h"
#import "SBProxyStore.h"
#import "SBDesign.h"
#import "SBInterfaceCopy.h"

@interface SBProxyViewController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) SBProxyStore *store;
@property(nonatomic, copy) NSArray<SBProxyRecord *> *rows;
@property(nonatomic, copy) NSString *selectedId;
@end

@implementation SBProxyViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = SBUIText(@"nav.proxy");
    self.view.backgroundColor = SBInk();
    self.view.tintColor = SBAccent();
    self.view.accessibilityIdentifier = @"socialbox.proxy";
    self.store = [SBProxyStore new];
    self.rows = @[];
    self.selectedId = @"";

    UILabel *title = SBLabel(SBUIText(@"nav.proxy"), 32, UIFontWeightBold);
    title.accessibilityIdentifier = @"socialbox.proxy.title";
    self.detailLabel = SBLabel(SBUIText(@"proxies.detail"), 15, UIFontWeightRegular);
    self.detailLabel.textColor = SBMuted();
    self.detailLabel.accessibilityIdentifier = @"socialbox.proxy.detail";
    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[ title, self.detailLabel ]];
    head.axis = UILayoutConstraintAxisVertical;
    head.spacing = 8;
    head.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *header = [UIView new];
    header.backgroundColor = SBInk();
    [header addSubview:head];
    [NSLayoutConstraint activateConstraints:@[
        [head.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:8],
        [head.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-8],
        [head.topAnchor constraintEqualToAnchor:header.topAnchor constant:16],
        [head.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-12],
    ]];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = SBInk();
    self.tableView.separatorColor = [SBMuted() colorWithAlphaComponent:0.15];
    self.tableView.rowHeight = 64;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.tableHeaderView = header;
    self.tableView.accessibilityIdentifier = @"socialbox.proxy.table";
    [self.view addSubview:self.tableView];

    __weak typeof(self) weakSelf = self;
    UIButton *add = SBButton(SBUIText(@"proxies.add"), @"plus", YES, ^{ [weakSelf addTapped]; });
    add.accessibilityIdentifier = @"socialbox.proxy.add";
    add.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *paste = SBButton(SBUIText(@"proxyImport.title"), @"import", NO, ^{ [weakSelf pasteTapped]; });
    paste.configuration = ({
        UIButtonConfiguration *c = UIButtonConfiguration.plainButtonConfiguration;
        c.title = SBUIText(@"proxyImport.title");
        c.baseForegroundColor = UIColor.whiteColor;
        c.contentInsets = NSDirectionalEdgeInsetsMake(10, 8, 10, 8);
        c;
    });
    paste.accessibilityIdentifier = @"socialbox.proxy.paste";
    paste.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:add];
    [self.view addSubview:paste];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:paste.topAnchor constant:-8],
        [paste.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [paste.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [paste.bottomAnchor constraintEqualToAnchor:add.topAnchor constant:-8],
        [add.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [add.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [add.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [add.heightAnchor constraintGreaterThanOrEqualToConstant:48],
    ]];

    header.frame = CGRectMake(0, 0, 320, 120);
    self.tableView.tableHeaderView = header;
    [self reload];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = self.tableView.tableHeaderView;
    CGFloat width = self.tableView.bounds.size.width;
    if (!header || width <= 0) return;
    CGSize size = [header systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                       withHorizontalFittingPriority:UILayoutPriorityRequired
                             verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGRect frame = CGRectMake(0, 0, width, ceil(size.height));
    if (!CGRectEqualToRect(header.frame, frame)) {
        header.frame = frame;
        self.tableView.tableHeaderView = header;
    }
}

- (void)reload {
    NSError *error = nil;
    self.rows = [self.store entries:&error] ?: @[];
    self.selectedId = [self.store selectedIdentifier:nil] ?: @"";
    [self.tableView reloadData];
}

- (void)showError:(NSError *)error {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:SBUIText(@"nav.proxy")
                                                                   message:error.localizedDescription ?: SBUIText(@"common.unavailable")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)addTapped {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:SBUIText(@"proxies.add")
                                            message:@"host:port or host:port:user:password\nhttp:// and socks5:// are accepted."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Name (optional)";
        field.accessibilityIdentifier = @"socialbox.proxy.nameField";
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"host:port";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.accessibilityIdentifier = @"socialbox.proxy.lineField";
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        NSString *name = [alert.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *line = alert.textFields[1].text;
        SBProxyRecord *record = [weakSelf.store parseLine:line];
        if (!record) {
            [weakSelf showError:[NSError errorWithDomain:@"com.socialbox.proxy" code:3
                                                userInfo:@{NSLocalizedDescriptionKey : @"Enter host:port or a proxy URL."}]];
            return;
        }
        if (name.length) record.name = name;
        NSError *error = nil;
        if (![weakSelf.store saveRecord:record error:&error]) [weakSelf showError:error];
        [weakSelf reload];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)pasteTapped {
    UIViewController *sheet = [UIViewController new];
    sheet.view.backgroundColor = SBInk();
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    UILabel *title = SBLabel(SBUIText(@"proxyImport.title"), 22, UIFontWeightBold);
    UILabel *detail = SBLabel(SBUIText(@"proxyImport.detail"), 14, UIFontWeightRegular);
    detail.textColor = SBMuted();
    UITextView *text = [UITextView new];
    text.backgroundColor = SBPanel();
    text.textColor = UIColor.whiteColor;
    text.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    text.layer.cornerRadius = 10;
    text.accessibilityIdentifier = @"socialbox.proxy.pasteField";
    text.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    title.translatesAutoresizingMaskIntoConstraints = NO;
    detail.translatesAutoresizingMaskIntoConstraints = NO;
    text.translatesAutoresizingMaskIntoConstraints = NO;
    [sheet.view addSubview:title];
    [sheet.view addSubview:detail];
    [sheet.view addSubview:text];
    __weak typeof(self) weakSelf = self;
    UIButton *import = SBButton(SBUIText(@"proxyImport.title"), @"import", YES, ^{
        NSArray<NSString *> *issues = @[];
        NSArray<SBProxyRecord *> *records = [weakSelf.store recordsFromPastedText:text.text issues:&issues];
        if (!records.count) {
            [weakSelf showError:[NSError errorWithDomain:@"com.socialbox.proxy" code:6
                                                userInfo:@{NSLocalizedDescriptionKey : issues.firstObject ?: SBUIText(@"common.unavailable")}]];
            return;
        }
        NSError *error = nil;
        for (SBProxyRecord *record in records) {
            if (![weakSelf.store saveRecord:record error:&error]) {
                [weakSelf showError:error];
                break;
            }
        }
        [weakSelf dismissViewControllerAnimated:YES completion:^{ [weakSelf reload]; }];
    });
    import.translatesAutoresizingMaskIntoConstraints = NO;
    import.accessibilityIdentifier = @"socialbox.proxy.importConfirm";
    [sheet.view addSubview:import];
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:sheet.view.leadingAnchor constant:20],
        [title.trailingAnchor constraintEqualToAnchor:sheet.view.trailingAnchor constant:-20],
        [title.topAnchor constraintEqualToAnchor:sheet.view.safeAreaLayoutGuide.topAnchor constant:20],
        [detail.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [detail.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [text.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [text.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [text.topAnchor constraintEqualToAnchor:detail.bottomAnchor constant:16],
        [text.bottomAnchor constraintEqualToAnchor:import.topAnchor constant:-16],
        [import.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [import.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [import.bottomAnchor constraintEqualToAnchor:sheet.view.safeAreaLayoutGuide.bottomAnchor constant:-16],
        [import.heightAnchor constraintGreaterThanOrEqualToConstant:48],
    ]];
    [self presentViewController:sheet animated:YES completion:^{ [text becomeFirstResponder]; }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.rows.count ? (NSInteger)self.rows.count : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"proxy"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"proxy"];
        cell.backgroundColor = SBPanel();
        cell.textLabel.textColor = UIColor.whiteColor;
        cell.detailTextLabel.textColor = SBMuted();
        cell.tintColor = SBAccent();
        cell.selectedBackgroundView = [UIView new];
        cell.selectedBackgroundView.backgroundColor = [SBAccent() colorWithAlphaComponent:0.18];
    }
    if (!self.rows.count) {
        cell.textLabel.text = SBUIText(@"proxies.emptyDetail");
        cell.detailTextLabel.text = @"";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.accessibilityIdentifier = @"socialbox.proxy.row.empty";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    SBProxyRecord *row = self.rows[(NSUInteger)indexPath.row];
    cell.textLabel.text = row.name.length ? row.name : row.displayHost;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", row.protocol.uppercaseString, row.displayHost];
    cell.accessoryType = [row.identifier isEqual:self.selectedId] ? UITableViewCellAccessoryCheckmark
                                                                  : UITableViewCellAccessoryNone;
    cell.accessibilityIdentifier = @"socialbox.proxy.row.data";
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!self.rows.count) return;
    SBProxyRecord *row = self.rows[(NSUInteger)indexPath.row];
    NSError *error = nil;
    if (![self.store selectIdentifier:row.identifier error:&error]) [self showError:error];
    [self reload];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (!self.rows.count) return nil;
    SBProxyRecord *row = self.rows[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *del = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:SBUIText(@"container.delete")
                          handler:^(UIContextualAction *a, UIView *s, void (^done)(BOOL)) {
                              (void)a;
                              (void)s;
                              NSError *error = nil;
                              if (![weakSelf.store deleteIdentifier:row.identifier error:&error]) [weakSelf showError:error];
                              [weakSelf reload];
                              done(YES);
                          }];
    return [UISwipeActionsConfiguration configurationWithActions:@[ del ]];
}

@end
