#import "RBXAppScope.h"
#import "RBXWorkspaceSelection.h"
#import "RBXCreationDefaults.h"
#import "RBXLauncherViewController.h"
#import "RBXPasscodeStore.h"
#import "RBXLauncherIPC.h"
#import "RBXSettingsViewController.h"
#import "RBXDiagnosticsViewController.h"
#import "RBXIsolationViewController.h"
#import "RBXProxiesViewController.h"
#import "RBXCloudVaultViewController.h"
#import "RBXSecureConfig.h"
#import "RBXMDMExporter.h"
#import "RBXSetupChecklist.h"
#import "RBXIdentityViewController.h"
#import "RBXAppearance.h"
#import "RBXPhoneArtwork.h"
#import "RBXWorkspacePresentation.h"
#import "RBXWorkspaceNavigation.h"
#import "RBXProfileMetadata.h"
#import "RBXAccountStatusViewController.h"
#import "RBXLicensePresentation.h"
#import "RBXOperatorWording.h"
#import "RBXAcceptanceChecks.h"
#import "RBXSimpleWizardViewController.h"
#include <math.h>
#include <stdlib.h>
#include <sys/stat.h>

static NSString *const RBXLauncherStatePath =
    @"/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist";

static NSDictionary *RBXPendingReplacementForRow(NSDictionary *row) {
    id journal = row[@"replacementState"];
    return [journal isKindOfClass:NSDictionary.class] && [journal count] &&
        ![journal[@"phase"] isEqual:@"committed"] ? journal : nil;
}

// Only launcher-owned export directories under its sandbox tmp are eligible.
static BOOL RBXRemoveShareDirectory(NSString *path, NSError **error) {
    NSString *root = NSTemporaryDirectory().stringByStandardizingPath;
    if (![path.stringByDeletingLastPathComponent.stringByStandardizingPath isEqual:root] ||
        ![path.lastPathComponent hasPrefix:@"rbx-share-"]) return NO;
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0) return errno == ENOENT;
    if (!S_ISDIR(info.st_mode) || S_ISLNK(info.st_mode)) return NO;
    return [NSFileManager.defaultManager removeItemAtPath:path error:error];
}

@interface RBXProfileCell : UITableViewCell
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *identityLabel;
@property(nonatomic, strong) UILabel *metadataLabel;
@property(nonatomic, strong) UILabel *roleLabel;
@property(nonatomic, strong) UIStackView *card;
@end

@implementation RBXProfileCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if ((self = [super initWithStyle:style reuseIdentifier:identifier])) {
        self.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.accessibilityHint = @"Shows available profile actions.";
        _nameLabel = RBXLabel(@"", UIFontTextStyleHeadline, NO);
        _statusLabel = RBXLabel(@"", UIFontTextStyleCaption1, YES);
        _identityLabel = RBXLabel(@"", UIFontTextStyleSubheadline, YES);
        _metadataLabel = RBXLabel(@"", UIFontTextStyleFootnote, YES);
        _roleLabel = RBXLabel(@"", UIFontTextStyleCaption1, NO);

        UIImageView *avatar = [[UIImageView alloc] initWithImage:RBXPhoneArtwork()];
        avatar.tintColor = RBXAccentColor();
        avatar.backgroundColor = [RBXAccentColor() colorWithAlphaComponent:0.10];
        avatar.contentMode = UIViewContentModeScaleAspectFit;
        avatar.layer.cornerRadius = 14;
        [avatar.widthAnchor constraintEqualToConstant:48].active = YES;
        [avatar.heightAnchor constraintEqualToConstant:48].active = YES;
        UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        chevron.tintColor = UIColor.tertiaryLabelColor;
        chevron.contentMode = UIViewContentModeScaleAspectFit;
        [chevron.widthAnchor constraintEqualToConstant:10].active = YES;
        UIStackView *names = RBXVerticalStack(@[_nameLabel, _statusLabel, _roleLabel], 4);
        UIStackView *heading = [[UIStackView alloc] initWithArrangedSubviews:@[avatar, names, chevron]];
        heading.spacing = 12;
        heading.alignment = UIStackViewAlignmentCenter;
        UIStackView *card = RBXVerticalStack(@[heading, _identityLabel, _metadataLabel], 12);
        card.layoutMarginsRelativeArrangement = YES;
        card.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(18, 18, 18, 18);
        RBXStyleCard(card);
        self.card = card;
        card.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:card];
        [NSLayoutConstraint activateConstraints:@[
            [card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
            [card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
            [card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
            [card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],
        ]];
    }
    return self;
}
@end

@interface RBXLauncherViewController () <UISearchResultsUpdating>
@property(nonatomic, copy) NSDictionary *appDescriptor;
@property(nonatomic, copy) NSArray<NSDictionary *> *containers;
@property(nonatomic, copy) NSArray<NSDictionary *> *allContainers;
@property(nonatomic, strong) UISearchController *containerSearch;
@property(nonatomic) NSInteger sortOrder;
@property(nonatomic, strong) UIStackView *selectedCard;
@property(nonatomic, strong) UILabel *selectedName;
@property(nonatomic, strong) UILabel *selectedDevice;
@property(nonatomic, strong) UILabel *selectedStatus;
@property(nonatomic, strong) UILabel *selectedDetail;
@property(nonatomic, strong) UIButton *selectedOpen;
@property(nonatomic, strong) UIButton *selectedEdit;
@property(nonatomic, strong) UILabel *locationDetail;
@property(nonatomic, strong) UIStackView *identityOverview;
@property(nonatomic, strong) NSMutableDictionary<NSString *, UILabel *> *identityOverviewValues;
@property(nonatomic, copy) NSDictionary *launcherState;
@property(nonatomic, strong) UIRefreshControl *stateRefreshControl;
@property(nonatomic, strong) UIVisualEffectView *lockOverlay;
@property(nonatomic) BOOL unlocked;
@property(nonatomic) BOOL offeredFirstRun;
@property(nonatomic, copy) NSString *shareCleanupError;
@property(nonatomic, strong) UILabel *summaryTitle;
@property(nonatomic, strong) UILabel *summaryDetail;
@property(nonatomic, strong) UIStackView *emptyState;
@property(nonatomic, strong) UIStackView *overviewStack;
@property(nonatomic, strong) UIButton *firstProfileButton;
@property(nonatomic, strong) UILabel *emptyTitle;
@property(nonatomic, strong) UILabel *emptyDetail;
@property(nonatomic, strong) UISegmentedControl *roleFilter;
@property(nonatomic, strong) UISwitch *roleGrouping;
@property(nonatomic, strong) NSTimer *licenseDisplayTimer;
@property(nonatomic) BOOL advancedMode;
@property(nonatomic, strong) UILabel *daemonCard;
@property(nonatomic, strong) UILabel *vpnCard;
@property(nonatomic, strong) UILabel *licenseCard;
- (void)loadState;
- (void)offerFirstRunIfNeeded;
- (void)confirmOpenContainer:(NSDictionary *)row;
- (void)confirmDeleteContainer:(NSDictionary *)row;
- (void)confirmReplaceContainer:(NSDictionary *)row;
- (BOOL)licensed;
@end

static void RBXLauncherStateChanged(CFNotificationCenterRef center, void *observer,
                                    CFStringRef name, const void *object,
                                    CFDictionaryRef userInfo) {
    RBXLauncherViewController *controller =
        (__bridge RBXLauncherViewController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller loadState];
    });
}

@implementation RBXLauncherViewController

- (instancetype)init { return [self initWithAdvancedMode:NO]; }
- (instancetype)initWithAdvancedMode:(BOOL)advancedMode {
    return [self initWithAppType:@"reddit" advancedMode:advancedMode];
}
- (instancetype)initWithAppType:(NSString *)appType advancedMode:(BOOL)advancedMode {
    NSDictionary *descriptor = [appType isKindOfClass:NSString.class] ? RBXAppDescriptorForType(appType) : nil;
    if (!descriptor) return nil;
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _advancedMode = advancedMode; _appDescriptor = descriptor;
    }
    return self;
}
- (NSString *)requestOwner {
    NSString *owner = self.workspacePage == RBXWorkspacePageHome ? @"dashboard" :
        (self.workspacePage == RBXWorkspacePageLocation ? @"location" : @"launcher");
    return RBXAppScopedPreferenceKey(owner, self.appDescriptor);
}
- (NSString *)appText:(NSString *)text { return [text stringByReplacingOccurrencesOfString:@"Reddit" withString:self.appDescriptor[@"displayName"]]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    // Clean interrupted shares on the next launcher start. Current shares are
    // not cleaned on foreground transitions while an activity still owns them.
    for (NSString *name in (self.workspacePage == RBXWorkspacePageContainers && !self.advancedMode ? [NSFileManager.defaultManager contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil] : @[])) {
        if (![name hasPrefix:@"rbx-share-"]) continue;
        NSError *error = nil;
        if (!RBXRemoveShareDirectory([NSTemporaryDirectory() stringByAppendingPathComponent:name], &error))
            self.shareCleanupError = error.localizedDescription ?: @"An interrupted IPA share could not be removed.";
    }
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(requestsDidBecomeActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    self.navigationItem.title = self.advancedMode ? @"Advanced profiles" :
        (self.workspacePage == RBXWorkspacePageHome ? @"Overview" :
         (self.workspacePage == RBXWorkspacePageLocation ? @"Location" : @"Containers"));
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.tableView.backgroundColor = RBXCanvasColor();
    self.tableView.backgroundView = RBXWorkspaceBackgroundView(self.traitCollection);
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 210;
    self.tableView.tableFooterView = [UIView new];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
            target:self action:@selector(createContainer)],
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
            style:UIBarButtonItemStylePlain target:self action:@selector(showSettings)],
    ];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self action:@selector(refreshFromCloud)];
    self.navigationItem.leftBarButtonItem.accessibilityLabel = @"Refresh profiles";
    if (self.advancedMode) self.navigationItem.leftBarButtonItem = nil; // Keep the native Back control.
    self.navigationItem.rightBarButtonItems.firstObject.accessibilityLabel = @"New container";
    self.navigationItem.rightBarButtonItems.lastObject.accessibilityLabel = @"More actions";
    if (!self.advancedMode) {
        self.navigationItem.rightBarButtonItems = @[self.navigationItem.rightBarButtonItems.firstObject];
        self.navigationItem.rightBarButtonItem.accessibilityLabel = @"Add container";
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Isolation" style:UIBarButtonItemStylePlain target:self action:@selector(showSimpleChecks)];
    }
    if (!self.advancedMode && self.workspacePage == RBXWorkspacePageContainers) {
        self.containerSearch = [[UISearchController alloc] initWithSearchResultsController:nil];
        self.containerSearch.obscuresBackgroundDuringPresentation = NO;
        self.containerSearch.searchResultsUpdater = self;
        self.containerSearch.searchBar.placeholder = @"Name, iPhone model or country";
        self.navigationItem.searchController = self.containerSearch;
        self.navigationItem.hidesSearchBarWhenScrolling = NO;
        self.definesPresentationContext = YES;
        self.sortOrder = [NSUserDefaults.standardUserDefaults integerForKey:RBXAppScopedPreferenceKey(@"RBXContainerSort", self.appDescriptor)];
        self.navigationItem.rightBarButtonItems = @[
            self.navigationItem.rightBarButtonItems.firstObject,
            [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis"] style:UIBarButtonItemStylePlain target:self action:@selector(showContainerTools)]];
        self.navigationItem.rightBarButtonItems.lastObject.accessibilityLabel = @"Container tools";
    }
    if (!self.advancedMode && self.workspacePage == RBXWorkspacePageHome) {
        self.navigationItem.leftBarButtonItem=nil; // Overview is a detail; retain Back.
        self.navigationItem.rightBarButtonItems = @[self.navigationItem.rightBarButtonItems.firstObject,
            [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"icloud"] style:UIBarButtonItemStylePlain target:self action:@selector(openCloudVault)]];
        self.navigationItem.rightBarButtonItems.lastObject.accessibilityLabel = @"Cloud backups";
    }
    [self buildOverview];

    self.stateRefreshControl = [UIRefreshControl new];
    [self.stateRefreshControl addTarget:self action:@selector(refreshFromCloud)
                       forControlEvents:UIControlEventValueChanged];
    self.refreshControl = self.stateRefreshControl;

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, RBXLauncherStateChanged,
        CFSTR("com.redditbox.launcherStateChanged"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    [self loadState];
    if ((!self.advancedMode && self.workspacePage == RBXWorkspacePageContainers) || !self.tabBarController)
        [self requestAction:@"refreshLauncher" values:@{} notification:CFSTR("com.redditbox.launcherAction")];
    __weak typeof(self) weakSelf = self;
    // A missing daemon cannot send a notification when its last grant becomes
    // stale. This timer reads local state only; it never retries a cloud request.
    self.licenseDisplayTimer = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer) {
        [weakSelf loadState];
    }];
}

- (void)buildOverview {
    UIView *header = [UIView new];
    UIStackView *page = RBXVerticalStack(@[], 16);
    self.overviewStack = page;
    page.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:page];
    [NSLayoutConstraint activateConstraints:@[
        [page.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [page.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [page.topAnchor constraintEqualToAnchor:header.topAnchor constant:12],
        [page.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-16],
    ]];
    if (!self.advancedMode) [self buildSelectedCard:page];
    UIStackView *summary = RBXFormSection(page, nil, nil);
    summary.backgroundColor = [RBXAccentColor() colorWithAlphaComponent:0.08];
    UILabel *eyebrow = RBXLabel(@"YOUR WORKSPACE", UIFontTextStyleCaption1, YES);
    eyebrow.textColor = RBXAccentColor();
    self.summaryTitle = RBXLabel(@"Waiting for status", self.workspacePage == RBXWorkspacePageContainers ? UIFontTextStyleHeadline : UIFontTextStyleTitle2, NO);
    self.summaryTitle.accessibilityTraits |= UIAccessibilityTraitHeader;
    self.summaryDetail = RBXLabel(@"", UIFontTextStyleSubheadline, YES);
    if (self.advancedMode) [summary addArrangedSubview:eyebrow];
    [summary addArrangedSubview:self.summaryTitle];
    [summary addArrangedSubview:self.summaryDetail];
    if (!self.advancedMode && self.workspacePage != RBXWorkspacePageContainers) {
        UIButton *setup = [self workspaceButton:@"Setup checklist" action:@selector(openWorkspaceSettings) primary:NO];
        [summary addArrangedSubview:setup];
    }
    if (!self.advancedMode && self.workspacePage == RBXWorkspacePageHome) [self buildIdentityOverview:page];
    if (self.advancedMode) {
    self.roleFilter = [[UISegmentedControl alloc] initWithItems:@[@"All", @"Signup", @"Warmup", @"Spam", @"Default"]];
    self.roleFilter.selectedSegmentIndex = 0;
    self.roleFilter.accessibilityLabel = @"Filter profiles by role";
    [self.roleFilter addTarget:self action:@selector(loadState) forControlEvents:UIControlEventValueChanged];
    [summary addArrangedSubview:self.roleFilter];
    self.roleGrouping = [UISwitch new];
    self.roleGrouping.on = [NSUserDefaults.standardUserDefaults boolForKey:RBXAppScopedPreferenceKey(@"RBXGroupByRole", self.appDescriptor)];
    self.roleGrouping.accessibilityLabel = @"Group profiles by role";
    [self.roleGrouping addTarget:self action:@selector(groupingChanged) forControlEvents:UIControlEventValueChanged];
    UIStackView *grouping = [[UIStackView alloc] initWithArrangedSubviews:@[
        RBXLabel(@"Group by role", UIFontTextStyleSubheadline, YES), self.roleGrouping]];
    grouping.distribution = UIStackViewDistributionEqualSpacing;
    [summary addArrangedSubview:grouping];
    }

    self.emptyState = RBXFormSection(page, nil, nil);
    self.emptyTitle = RBXLabel(@"A space for each profile", UIFontTextStyleTitle2, NO);
    self.emptyTitle.accessibilityTraits |= UIAccessibilityTraitHeader;
    self.emptyDetail = RBXLabel([self appText:@"Create your first container, then finish setup before opening Reddit."],
        UIFontTextStyleBody, YES);
    [self.emptyState addArrangedSubview:self.emptyTitle];
    [self.emptyState addArrangedSubview:self.emptyDetail];
    UIButton *create = [UIButton buttonWithType:UIButtonTypeSystem];
    self.firstProfileButton = create;
    [create setTitle:@"+ New container" forState:UIControlStateNormal];
    RBXStyleButton(create, YES);
    [create addTarget:self action:@selector(createContainer) forControlEvents:UIControlEventTouchUpInside];
    [self.emptyState addArrangedSubview:create];
    self.tableView.tableHeaderView = header;
}


- (UIButton *)workspaceButton:(NSString *)title action:(SEL)action primary:(BOOL)primary {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    RBXStyleButton(button, primary);
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)buildSelectedCard:(UIStackView *)page {
    UIStackView *card = RBXFormSection(page, nil, nil);
    BOOL compact = self.workspacePage == RBXWorkspacePageContainers;
    if (compact) {
        card.spacing = 7;
        card.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(14,18,14,18);
    }
    self.selectedCard = card;
    UILabel *eyebrow = RBXLabel(self.workspacePage == RBXWorkspacePageLocation ? @"SAVED LOCATION" : @"CURRENT SELECTION", UIFontTextStyleCaption1, YES);
    eyebrow.textColor = RBXAccentColor();
    [card addArrangedSubview:eyebrow];
    UIImageView *icon = [[UIImageView alloc] initWithImage:self.workspacePage == RBXWorkspacePageLocation ? [UIImage systemImageNamed:@"globe.europe.africa"] : RBXPhoneArtwork()];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = RBXAccentColor();
    [icon.heightAnchor constraintEqualToConstant:compact ? 40 : 80].active = YES;
    [icon.widthAnchor constraintEqualToConstant:compact ? 33 : 65].active = YES;
    self.selectedName = RBXLabel(@"No container selected", compact ? UIFontTextStyleHeadline : UIFontTextStyleTitle2, NO);
    self.selectedName.accessibilityTraits |= UIAccessibilityTraitHeader;
    self.selectedDevice = RBXLabel(@"", compact ? UIFontTextStyleCaption1 : UIFontTextStyleSubheadline, YES);
    self.selectedStatus = RBXLabel(@"", UIFontTextStyleHeadline, NO);
    self.selectedDetail = RBXLabel(@"", UIFontTextStyleSubheadline, YES);
    UIStackView *device = RBXVerticalStack(@[self.selectedName,self.selectedDevice],6);
    UIStackView *heading = [[UIStackView alloc] initWithArrangedSubviews:@[device,icon]];
    heading.spacing = 12; heading.alignment = UIStackViewAlignmentCenter;
    [card addArrangedSubview:heading];
    // The list already presents each row's complete status. Keep its current
    // selection summary compact enough for a real container to remain visible.
    if (!compact) {
        [card addArrangedSubview:self.selectedStatus];
        [card addArrangedSubview:self.selectedDetail];
    }
    if (self.workspacePage == RBXWorkspacePageHome) {
        self.selectedOpen = [self workspaceButton:@"Open container" action:@selector(openSelectedContainer) primary:YES];
        [card addArrangedSubview:self.selectedOpen];
        self.selectedEdit = [self workspaceButton:@"Configure identity" action:@selector(editSelectedContainer) primary:NO];
        UIButton *choose = [self workspaceButton:@"Choose container" action:@selector(openContainersPage) primary:NO];
        [self.selectedEdit setTitle:@"Configure" forState:UIControlStateNormal];
        [choose setTitle:@"Choose" forState:UIControlStateNormal];
        UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[self.selectedEdit,choose]];
        actions.spacing = 10; actions.distribution = UIStackViewDistributionFillEqually;
        actions.axis = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory) ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
        [card addArrangedSubview:actions];
    } else if (self.workspacePage == RBXWorkspacePageLocation) {
        self.locationDetail = RBXLabel(@"", UIFontTextStyleBody, NO);
        [card addArrangedSubview:self.locationDetail];
        self.selectedEdit = [self workspaceButton:@"Edit location · match proxy" action:@selector(editSelectedContainer) primary:YES];
        [card addArrangedSubview:self.selectedEdit];
        [card addArrangedSubview:RBXLabel(@"Review the saved region and carrier below. Proxy lookup offers a draft; you review and save it before anything changes.", UIFontTextStyleFootnote, YES)];
    }
}

- (void)buildIdentityOverview:(UIStackView *)page {
    UIStackView *section = RBXFormSection(page, @"Saved identity", @"These values belong to the selected container. Switching keeps its identity unchanged.");
    self.identityOverview = section;
    self.identityOverviewValues = [NSMutableDictionary dictionary];
    NSArray *fields = @[@[@"marketingName",@"MODEL"],@[@"iosVersion",@"IOS VERSION"],
        @[@"country",@"COUNTRY"],@[@"carrierName",@"CARRIER"],
        @[@"locale",@"LANGUAGE / REGION"],@[@"timezone",@"TIME ZONE"]];
    for (NSUInteger index=0; index<fields.count; index+=2) {
        UIStackView *pair = [UIStackView new];
        pair.spacing = 10; pair.distribution = UIStackViewDistributionFillEqually;
        pair.axis = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)
            ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
        for (NSUInteger item=index; item<MIN(index+2,fields.count); item++) {
            UILabel *label = RBXLabel(fields[item][1], UIFontTextStyleCaption2, YES);
            UILabel *value = RBXLabel(@"Not selected", UIFontTextStyleSubheadline, NO);
            value.accessibilityIdentifier = [@"socialbox.saved-identity." stringByAppendingString:fields[item][0]];
            UIStackView *tile = RBXVerticalStack(@[label,value],5);
            tile.layoutMarginsRelativeArrangement = YES;
            tile.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(12,12,12,12);
            tile.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.055];
            tile.layer.cornerRadius = 14;
            self.identityOverviewValues[fields[item][0]] = value;
            [pair addArrangedSubview:tile];
        }
        [section addArrangedSubview:pair];
    }
    [section addArrangedSubview:RBXLabel(@"Carrier is a profile choice, not a measured cellular connection. Open Configure to review private identifiers and detailed policies.", UIFontTextStyleFootnote, YES)];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection])
        self.tableView.backgroundView = RBXWorkspaceBackgroundView(self.traitCollection);
    if (![self.traitCollection.preferredContentSizeCategory isEqual:previousTraitCollection.preferredContentSizeCategory]) {
        for (UIView *view in self.identityOverview.arrangedSubviews)
            if ([view isKindOfClass:UIStackView.class]) ((UIStackView *)view).axis = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)
                ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    }
}

- (NSDictionary *)selectedContainer {
    NSString *identifier = RBXWorkspaceSelectedID(self.launcherState[@"workspaceSelection"], self.appDescriptor[@"appType"]);
    if (self.workspacePage == RBXWorkspacePageLocation) {
        NSString *preview = [NSUserDefaults.standardUserDefaults stringForKey:RBXAppScopedPreferenceKey(@"RBXSelectedContainer", self.appDescriptor)];
        return RBXWorkspaceSelectedRow(self.allContainers, preview ?: identifier);
    }
    for (NSDictionary *row in self.allContainers) if ([row[@"id"] isEqual:identifier]) return row;
    return nil;
}
- (void)updateSelectedCard {
    if (!self.selectedCard) return;
    NSDictionary *row = [self selectedContainer];
    self.selectedName.text = row ? RBXWorkspaceText(row[@"name"]) : @"Choose your container";
    self.selectedDevice.text = row ? RBXWorkspaceDeviceText(row) : @"Select one in Containers. Only one app session is active at a time.";
    NSDictionary *presentation = row ? RBXSimpleContainerPresentation(row, self.launcherState, NSDate.date.timeIntervalSince1970) : @{};
    self.selectedStatus.text = row ? presentation[@"title"] : @"Nothing selected";
    self.selectedDetail.text = row ? presentation[@"reason"] : @"Tap Choose, select a container, and wait for confirmation. Use + if you need a new one.";
    BOOL alert = [row[@"isolationSentinel"][@"alert"] boolValue];
    if (alert) { self.selectedStatus.text = @"Isolation alert"; self.selectedDetail.text = @"Review Isolation diagnostics before opening this container."; }
    self.selectedStatus.textColor = alert ? UIColor.systemRedColor :
        ([presentation[@"status"] isEqual:@"locked"] ? [UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1] : UIColor.secondaryLabelColor);
    BOOL editable = row && self.unlocked && self.licensed && !row[@"profileError"] && !row[@"deletionState"] && !RBXPendingReplacementForRow(row);
    self.selectedEdit.enabled = editable;
    // Open always routes through the existing confirmation and daemon gates.
    // A blocked row remains tappable so the operator can read the exact reason.
    self.selectedOpen.enabled = editable;
    self.selectedCard.layer.borderColor = row ? [UIColor.systemGreenColor colorWithAlphaComponent:0.28].CGColor
        : [UIColor colorWithWhite:0.6 alpha:0.2].CGColor;
    NSDictionary *identity = [row[@"identityEditor"] isKindOfClass:NSDictionary.class] ? row[@"identityEditor"] : @{};
    [self.identityOverviewValues enumerateKeysAndObjectsUsingBlock:^(NSString *key, UILabel *label, BOOL *stop) {
        NSString *text = RBXWorkspaceText(identity[key]);
        if ([key isEqual:@"country"] && text.length) text = RBXOperatorCountry(text);
        label.text = row ? (text.length ? text : @"Unavailable") : @"Not selected";
    }];
    NSString *(^value)(NSString *) = ^NSString *(NSString *key) { NSString *text = RBXWorkspaceText(identity[key]); return text.length ? text : @"Not set"; };
    self.locationDetail.text = [NSString stringWithFormat:@"City  %@\nCountry  %@\nTime zone  %@\nLanguage / region  %@\nCarrier  %@\n\nProxy country (configured)  %@\nLast observed proxy country  %@",value(@"city"),value(@"country"),value(@"timezone"),value(@"locale"),value(@"carrierName"),value(@"proxyCountry"),value(@"observedProxyCountry")];
    if (!row) self.locationDetail.text = @"Choose or create a container first. This page never reads this phone’s physical location.";
}

- (void)showContainerSetupMessage:(NSString *)setupMessage {
    UIAlertController *setup = [UIAlertController alertControllerWithTitle:@"Container opening is blocked"
        message:setupMessage preferredStyle:UIAlertControllerStyleAlert];
    [setup addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    [setup addAction:[UIAlertAction actionWithTitle:@"Open Settings" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (RBXSelectWorkspaceTab(self, RBXWorkspaceTabSettings)) {
            UINavigationController *navigation = (UINavigationController *)self.tabBarController.selectedViewController;
            if ([navigation isKindOfClass:UINavigationController.class]) [navigation popToRootViewControllerAnimated:NO];
        } else {
            [self.navigationController pushViewController:[[RBXSettingsViewController alloc] initWithAppType:self.appDescriptor[@"appType"] proxyMode:NO] animated:YES];
        }
    }]];
    [self presentViewController:setup animated:YES completion:nil];
}
- (void)openFromSharedIcon {
    [self loadState];
    if (!self.unlocked || !self.licensed || self.presentedViewController ||
        self.navigationController.topViewController != self) return;
    for (NSDictionary *request in [RBXLauncherIPC pendingRequestsForOwner:self.requestOwner])
        if ([request[@"action"] isEqual:@"launchSelectedContainer"]) return;
    NSString *identifier = RBXWorkspaceSelectedID(self.launcherState[@"workspaceSelection"], self.appDescriptor[@"appType"]);
    if (!identifier) { [self showMessage:@"Choose a container" detail:@"Select a container and wait for switching to finish. Open from SocialBox always uses that confirmed selection."]; return; }
    NSDictionary *row = [self selectedContainer];
    NSString *blocked = [row[@"launchBlockReason"] isKindOfClass:NSString.class] && [row[@"launchBlockReason"] length]
        ? row[@"launchBlockReason"] : RBXContainerSetupMessage(self.launcherState);
    if (!row || blocked) { [self showContainerSetupMessage:blocked ?: @"Selected container is unavailable. Choose an available container again."]; return; }
    [self requestAction:@"launchSelectedContainer" values:@{} notification:CFSTR("com.redditbox.launchContainer")];
}
- (void)openSelectedContainer { [self openFromSharedIcon]; }
- (void)selectContainer:(NSDictionary *)row {
    if (!self.unlocked || !self.licensed) return;
    [self requestAction:@"selectContainer" values:@{@"container":row[@"id"] ?: @""} notification:CFSTR("com.redditbox.containerAction")];
    self.summaryDetail.text = @"Switching… waiting for the previous app to stop. Keep this screen open for confirmation.";
}
- (void)editSelectedContainer {
    NSDictionary *row = [self selectedContainer];
    if (!row || !self.unlocked || !self.licensed || row[@"profileError"] || row[@"deletionState"] || RBXPendingReplacementForRow(row)) return;
    RBXIdentityViewController *editor = [[RBXIdentityViewController alloc] initWithContainerRow:row];
    editor.focusRegionOnAppear = self.workspacePage == RBXWorkspacePageLocation;
    [self.navigationController pushViewController:editor animated:YES];
}
- (void)openCloudVault { if (self.unlocked) [self.navigationController pushViewController:[[RBXCloudVaultViewController alloc] initWithAppType:self.appDescriptor[@"appType"]] animated:YES]; }
- (void)showContainerTools {
    if(!self.unlocked)return;
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"Container tools" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:@"Overview" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self dismissViewControllerAnimated:YES completion:^{ RBXSelectWorkspaceTab(self,RBXWorkspaceTabHome); }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cloud backups" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self dismissViewControllerAnimated:YES completion:^{ [self openCloudVault]; }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Sort containers" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self dismissViewControllerAnimated:YES completion:^{ [self chooseSort]; }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Advanced tools" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self dismissViewControllerAnimated:YES completion:^{ [self showSettings]; }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.barButtonItem=self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)openWorkspaceSettings { if (self.unlocked) RBXSelectWorkspaceTab(self, RBXWorkspaceTabSettings); }
- (void)openContainersPage { if (self.unlocked) RBXSelectWorkspaceTab(self, RBXWorkspaceTabContainers); }
- (void)openLocationPage { if (self.unlocked) RBXSelectWorkspaceTab(self, RBXWorkspaceTabLocation); }
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController { [self loadState]; }
- (void)chooseSort {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Sort containers" message:@"Search also matches the device model and country. Recovery and isolation alerts remain visible." preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *titles = @[@"Recently active",@"Name",@"iPhone model"];
    for (NSUInteger index=0; index<titles.count; index++) {
        [sheet addAction:[UIAlertAction actionWithTitle:titles[index] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            self.sortOrder = index;
            [NSUserDefaults.standardUserDefaults setInteger:index forKey:RBXAppScopedPreferenceKey(@"RBXContainerSort", self.appDescriptor)];
            [self loadState];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = self.tableView.tableHeaderView;
    CGFloat width = self.tableView.bounds.size.width;
    CGFloat height = [header systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
        withHorizontalFittingPriority:UILayoutPriorityRequired
        verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    if (fabs(header.frame.size.height - height) > 0.5 || header.frame.size.width != width) {
        header.frame = CGRectMake(0, 0, width, height);
        self.tableView.tableHeaderView = header;
    }
}

- (void)dealloc {
    [self.licenseDisplayTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, NULL, NULL);
}

- (void)requestsDidBecomeActive:(NSNotification *)notification {
    [self loadState];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (![RBXPasscodeStore hasPasscode]) {
        self.unlocked = YES;
        [self setLocked:NO];
        [self offerFirstRunIfNeeded];
    } else if (!self.unlocked) {
        [self setLocked:YES];
        [self promptForPasscode];
    }
    [self loadState];
}

- (void)loadState {
    NSDictionary *state = RBXAppScopedLauncherState([NSDictionary dictionaryWithContentsOfFile:RBXLauncherStatePath], self.appDescriptor);
    self.launcherState = [state isKindOfClass:[NSDictionary class]] ? state : @{};
    BOOL currentPublication = NO;
    if (!self.advancedMode) {
        NSMutableDictionary *checks = [NSMutableDictionary dictionary];
        for (NSDictionary *check in RBXAcceptanceChecks(self.launcherState, NSDate.date.timeIntervalSince1970)) checks[check[@"id"]] = check;
        currentPublication = [checks[@"publication"][@"status"] isEqual:@"PASS"];
        self.daemonCard.text = [NSString stringWithFormat:@"Service · %@", RBXOperatorText(checks[@"publication"][@"status"])];
        self.vpnCard.text = [NSString stringWithFormat:@"VPN · %@", RBXOperatorText(checks[@"reported-vpn-scope"][@"status"])];
        self.licenseCard.text = [NSString stringWithFormat:@"License · %@", RBXOperatorText(checks[@"license"][@"status"])];
    }
    NSArray *rows = self.launcherState[@"containers"];
    self.allContainers = RBXWorkspaceRows(rows, @"", 0);
    self.containers = self.advancedMode ? self.allContainers : RBXWorkspaceRows(rows, self.containerSearch.searchBar.text, self.sortOrder);
    if (self.roleFilter.selectedSegmentIndex > 0) {
        NSString *role = RBXProfileRoles()[self.roleFilter.selectedSegmentIndex - 1];
        self.containers = [self.containers filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSDictionary *row, NSDictionary *bindings) {
                // Recovery rows must remain reachable through every filter.
                NSDictionary *sentinel = [row[@"isolationSentinel"] isKindOfClass:NSDictionary.class] ? row[@"isolationSentinel"] : @{};
                return row[@"deletionState"] || row[@"profileError"] || RBXPendingReplacementForRow(row) ||
                    [sentinel[@"alert"] isEqual:@YES] || [RBXProfileRole(row[@"role"]) isEqual:role];
            }]];
    }
    if (self.roleGrouping.on) self.containers = [self.containers sortedArrayUsingComparator:
        ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSUInteger left = [RBXProfileRoles() indexOfObject:RBXProfileRole(a[@"role"])];
            NSUInteger right = [RBXProfileRoles() indexOfObject:RBXProfileRole(b[@"role"])];
            if (left != right) return left < right ? NSOrderedAscending : NSOrderedDescending;
            return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        }];
    if (!self.licensed) { self.containers = @[]; self.allContainers = @[]; }
    self.navigationItem.rightBarButtonItems.firstObject.enabled = self.unlocked && self.licensed;
    NSString *network = self.launcherState[@"networkState"] ?: @"offline";
    BOOL setupReady = [self.launcherState[@"firewallSetup"][@"ready"] boolValue];
    self.navigationItem.prompt = nil;
    if (!self.launcherState.count) {
        self.summaryTitle.text = @"Waiting for device status";
        self.summaryDetail.text = @"Refresh to load profiles and the latest network state.";
    } else if (!setupReady) {
        self.summaryTitle.text = @"Finish your setup";
        self.summaryDetail.text = [self appText:@"Create profiles offline. Complete managed VPN setup in Settings before opening Reddit."];
    } else if ([network isEqualToString:@"open"]) {
        self.summaryTitle.text = @"Session in progress";
        self.summaryDetail.text = @"One profile at a time. Review Diagnostics for VPN and hook status.";
    } else if ([network isEqualToString:@"armed"]) {
        self.summaryTitle.text = @"Preparing your session";
        self.summaryDetail.text = @"Waiting for the selected profile's launch checks.";
    } else {
        self.summaryTitle.text = [network isEqualToString:@"closed"] ? @"Traffic is closed" : @"Status unavailable";
        self.summaryDetail.text = @"Choose a profile to begin, or review setup and diagnostics in Settings.";
    }
    NSString *inventoryWarning = [self.launcherState[@"profileWarning"] isKindOfClass:NSString.class]
        ? self.launcherState[@"profileWarning"] : nil;
    BOOL inventoryUnavailable = inventoryWarning.length > 0;
    self.emptyTitle.text = inventoryUnavailable ? @"Profiles need attention" : @"A space for each profile";
    self.emptyDetail.text = inventoryUnavailable ? (self.advancedMode ? inventoryWarning : RBXOperatorMessage(inventoryWarning)) :
        [self appText:@"Create your first container, then finish setup before opening Reddit."];
    if (!inventoryUnavailable && [rows count] && !self.containers.count) {
        self.emptyTitle.text = @"No matching containers";
        self.emptyDetail.text = @"Clear the search or choose All to see your other containers. Recovery and isolation alerts stay visible.";
    }
    // Detach unused stacks instead of hiding a stack whose buttons have minimum
    // heights; UISV-hiding would conflict with those constraints at height zero.
    if (self.containers.count) {
        [self.overviewStack removeArrangedSubview:self.emptyState];
        [self.emptyState removeFromSuperview];
    } else if (!self.emptyState.superview) {
        [self.overviewStack addArrangedSubview:self.emptyState];
    }
    if (inventoryUnavailable) {
        [self.emptyState removeArrangedSubview:self.firstProfileButton];
        [self.firstProfileButton removeFromSuperview];
    } else if (!self.firstProfileButton.superview) {
        [self.emptyState addArrangedSubview:self.firstProfileButton];
    }
    NSString *attention = inventoryWarning;
    NSDictionary *recovery = self.launcherState[@"operationRecovery"];
    if ([recovery isKindOfClass:NSDictionary.class] && [recovery[@"message"] isKindOfClass:NSString.class])
        attention = recovery[@"message"];
    NSDictionary *startup = self.launcherState[@"startupRecovery"];
    if (!attention.length && [startup isKindOfClass:NSDictionary.class] &&
        [startup[@"ok"] isEqual:@NO] && [startup[@"message"] isKindOfClass:NSString.class])
        attention = startup[@"message"];
    if (!attention.length && [self.launcherState[@"deletionWarning"] isKindOfClass:NSString.class])
        attention = self.launcherState[@"deletionWarning"];
    self.summaryTitle.textColor = attention.length ? [UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1] : UIColor.labelColor;
    if (!attention.length && ![@[@"open",@"armed"] containsObject:network]) {
        NSUInteger missing=0;
        for (NSDictionary *check in RBXSetupChecklist(self.launcherState,NSDate.date.timeIntervalSince1970))
            if (![check[@"status"] isEqual:@"PASS"]) missing++;
        if (missing) {
            self.summaryTitle.text=[NSString stringWithFormat:@"%lu setup checks need attention",(unsigned long)missing];
            self.summaryTitle.textColor=UIColor.systemRedColor;
            self.summaryDetail.text=@"Open Settings for the red/green checklist. Offline containers can be prepared for MDM; Open runs the protection checks again.";
        }
    }
    if (attention.length) {
        self.summaryTitle.text = @"Needs attention";
        self.summaryDetail.text = RBXOperatorMessage(attention);
    }
    if (!self.advancedMode && !currentPublication) {
        self.summaryTitle.text = @"Status not verified";
        self.summaryDetail.text = RBXOperatorText(@"unavailable");
    }
    if (!self.advancedMode && self.workspacePage == RBXWorkspacePageContainers && !attention.length && currentPublication)
        self.summaryDetail.text = @"Prepare containers here. Review missing setup in Settings before opening.";
    [self updateSelectedCard];
    [self.view setNeedsLayout];
    [self.tableView reloadData];
    // Replies stay durable while another controller or the passcode screen is
    // visible. Present at most one alert/share sheet per pass.
    if (!self.unlocked || !self.licensed || !self.view.window || self.presentedViewController ||
        self.navigationController.topViewController != self) return;
    if (self.shareCleanupError.length) {
        NSString *message = self.shareCleanupError; self.shareCleanupError = nil;
        [self showMessage:@"Export cleanup needs attention" detail:message]; return;
    }
    for (NSDictionary *request in [RBXLauncherIPC pendingRequestsForOwner:self.requestOwner]) {
        NSString *requestId = request[@"requestId"];
        NSDictionary *result = [RBXLauncherIPC requestResultForId:requestId];
        if (!result) continue;
        [RBXLauncherIPC finishObservingRequestId:requestId owner:self.requestOwner];
        if ([result[@"action"] isEqualToString:@"refreshLauncher"]) {
            [self.stateRefreshControl endRefreshing];
        }
        if (![result[@"ok"] boolValue]) {
            [self showMessage:@"RedditBox operation failed"
                detail:result[@"message"] ?: @"The daemon rejected the operation."];
            return;
        }
        if ([result[@"action"] isEqual:@"selectContainer"]) {
            [self showMessage:@"Container selected" detail:@"Open it from SocialBox Home. Setup and network checks still apply."]; return;
        }
        if ([result[@"action"] isEqualToString:@"exportCloneIPA"]) {
            NSDictionary *details = result[@"details"];
            [self shareCloneIPA:details[@"path"] profile:details[@"containerId"]];
            return;
        }
    }
}

- (void)requestAction:(NSString *)action
                values:(NSDictionary *)values
          notification:(CFStringRef)notification {
    if (![RBXLauncherIPC sendActionReturningRequestId:action values:values
        notification:notification owner:self.requestOwner appType:self.appDescriptor[@"appType"]]) {
        [self.stateRefreshControl endRefreshing];
        [self showMessage:@"Request failed"
                  detail:@"The launcher could not write the daemon request."];
        return;
    }
}

- (BOOL)licensed {
    return [RBXLicensePresentationState(self.launcherState, NSDate.date.timeIntervalSince1970)[@"unlocked"] boolValue];
}

- (NSString *)relativeDate:(NSNumber *)timestamp {
    if (timestamp.doubleValue <= 0) return @"never";
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:timestamp.doubleValue];
    NSDateComponentsFormatter *formatter = [NSDateComponentsFormatter new];
    formatter.allowedUnits = NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute;
    formatter.unitsStyle = NSDateComponentsFormatterUnitsStyleAbbreviated;
    formatter.maximumUnitCount = 1;
    NSString *value = [formatter stringFromTimeInterval:fabs(date.timeIntervalSinceNow)];
    return date.timeIntervalSinceNow > 0 ? @"soon" :
        [NSString stringWithFormat:@"%@ ago", value ?: @"recently"];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.workspacePage == RBXWorkspacePageHome ? 0 : self.containers.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.workspacePage == RBXWorkspacePageHome) return nil;
    if (self.workspacePage == RBXWorkspacePageLocation) return self.containers.count ? @"Choose a container" : nil;
    NSString *warning = self.launcherState[@"profileWarning"];
    if ([warning isKindOfClass:NSString.class] && warning.length) return @"Profile inventory unavailable";
    return self.containers.count ? [NSString stringWithFormat:@"Containers · %lu", (unsigned long)self.containers.count] : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!self.advancedMode) return nil;
    if (self.workspacePage == RBXWorkspacePageHome) return @"Status reflects the latest device checks. It is not a guarantee of complete isolation.";
    if (self.workspacePage == RBXWorkspacePageLocation) return @"Selection only changes this view. It never opens an app or changes a saved identity. Coordinates and proxy matching are available in Edit location.";
    if (!self.advancedMode) return @"Tap + to add a container. Tap a container to open, edit or delete it. Initial setup is in Settings.";
    NSString *instructions = self.containers.count ? [self appText:@"Tap a container to open Reddit or edit its identity. Swipe right to share an IPA. The daemon authorizes every launch."] :
        @"Setup and diagnostics are available from Settings.";
    NSMutableArray *messages = [NSMutableArray array];
    NSDictionary *recovery = self.launcherState[@"operationRecovery"];
    if ([recovery isKindOfClass:NSDictionary.class] && [recovery[@"message"] isKindOfClass:NSString.class])
        [messages addObject:[NSString stringWithFormat:@"Recovery required: %@ Diagnostics remain available.", recovery[@"message"]]];
    NSDictionary *startup = self.launcherState[@"startupRecovery"];
    if ([startup isKindOfClass:NSDictionary.class] && [startup[@"ok"] isEqual:@NO] &&
        [startup[@"message"] isKindOfClass:NSString.class]) [messages addObject:startup[@"message"]];
    for (NSString *key in @[@"profileWarning", @"deletionWarning"]) {
        NSString *warning = self.launcherState[key];
        if ([warning isKindOfClass:NSString.class] && warning.length) [messages addObject:warning];
    }
    [messages addObject:instructions];
    return [messages componentsJoinedByString:@"\n\n"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"container";
    RBXProfileCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[RBXProfileCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:identifier];
    }
    NSDictionary *row = self.containers[indexPath.row];
    cell.nameLabel.text = row[@"name"] ?: row[@"id"] ?: @"Container";
    cell.nameLabel.textColor = UIColor.labelColor;
    RBXStyleCard(cell.card);
    cell.statusLabel.textColor = UIColor.secondaryLabelColor;
    NSString *role = RBXProfileRole(row[@"role"]);
    cell.roleLabel.text = [NSString stringWithFormat:@"  %@  ", role.uppercaseString];
    cell.roleLabel.textColor = @{@"signup": UIColor.systemBlueColor, @"warmup": [UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1],
        @"spam": UIColor.systemPurpleColor, @"default": UIColor.secondaryLabelColor}[role];
    cell.roleLabel.backgroundColor = [cell.roleLabel.textColor colorWithAlphaComponent:0.08];
    cell.roleLabel.layer.cornerRadius = 6;
    cell.roleLabel.clipsToBounds = YES;
    if (!self.advancedMode) {
        NSDictionary *presentation = RBXSimpleContainerPresentation(row,self.launcherState,NSDate.date.timeIntervalSince1970);
        cell.statusLabel.text = presentation[@"title"];
        if ([row[@"isolationSentinel"][@"alert"] boolValue]) cell.statusLabel.text = @"Isolation alert";
        cell.statusLabel.textColor = [presentation[@"status"] isEqual:@"locked"] ? [UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1] :
            ([presentation[@"status"] isEqual:@"ready"] ? UIColor.systemGreenColor : UIColor.secondaryLabelColor);
        cell.roleLabel.text = [self.appDescriptor[@"displayName"] stringByAppendingString:([row[@"id"] isEqual:RBXWorkspaceSelectedID(self.launcherState[@"workspaceSelection"], self.appDescriptor[@"appType"])] ? @" · SELECTED" : @"")];
        cell.roleLabel.textColor = RBXAccentColor();
        BOOL selected = [row[@"id"] isEqual:RBXWorkspaceSelectedID(self.launcherState[@"workspaceSelection"], self.appDescriptor[@"appType"])];
        if (selected) {
            cell.nameLabel.textColor = UIColor.systemGreenColor;
            cell.card.layer.borderColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.35].CGColor;
            cell.card.layer.borderWidth = 1;
        }
        cell.identityLabel.text = [NSString stringWithFormat:@"%@ · %@", RBXWorkspaceDeviceText(row), RBXOperatorCountry(row[@"country"])];
        cell.metadataLabel.text = presentation[@"reason"];
        cell.metadataLabel.numberOfLines = 2;
        if ([row[@"isolationSentinel"][@"alert"] boolValue]) { cell.statusLabel.textColor = UIColor.systemRedColor; cell.metadataLabel.text = @"Opening blocked · review Diagnostics"; }
        cell.accessibilityLabel = [@[cell.nameLabel.text,cell.roleLabel.text,cell.statusLabel.text,cell.identityLabel.text,cell.metadataLabel.text] componentsJoinedByString:@". "];
        cell.accessibilityHint = self.workspacePage == RBXWorkspacePageLocation ? @"Selects this container for location review without opening it." : @"Shows Select, Rename, Configure, Cloud backups and Delete actions. Opening this menu does not switch containers.";
        return cell;
    }
    NSDictionary *deletion = row[@"deletionState"];
    NSDictionary *profileError = row[@"profileError"];
    if ([profileError isKindOfClass:NSDictionary.class]) {
        cell.statusLabel.text = @"PROFILE UNAVAILABLE";
        cell.statusLabel.textColor = [UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1];
        cell.identityLabel.text = profileError[@"message"] ?: @"The profile could not be read.";
        cell.metadataLabel.text = @"Tap for recovery options.";
        cell.accessibilityLabel = [@[cell.nameLabel.text, cell.statusLabel.text, cell.identityLabel.text,
            cell.metadataLabel.text] componentsJoinedByString:@". "];
        return cell;
    }
    if ([deletion isKindOfClass:NSDictionary.class]) {
        cell.statusLabel.text = @"CLEANUP NEEDED";
        cell.statusLabel.textColor = [UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1];
        cell.identityLabel.text = deletion[@"message"] ?: @"This profile is unavailable until cleanup finishes.";
        cell.metadataLabel.text = @"Tap to retry cleanup.";
        cell.accessibilityLabel = [@[cell.nameLabel.text, cell.statusLabel.text, cell.identityLabel.text,
            cell.metadataLabel.text] componentsJoinedByString:@". "];
        return cell;
    }
    cell.metadataLabel.numberOfLines = 0;
    BOOL active = [row[@"isActive"] boolValue];
    cell.statusLabel.text = active ? @"ACTIVE PROFILE" :
        ([row[@"launchState"] isEqualToString:@"switching"] ? @"OPENING…" : @"INACTIVE");
    cell.statusLabel.textColor = active ? RBXAccentColor() : UIColor.secondaryLabelColor;
    NSString *vpn = [row[@"vpnArmed"] boolValue] ? @"VPN ready" : @"VPN idle";
    NSString *hooks = [row[@"hooksReady"] boolValue] ? @"hooks ready" : @"hooks idle";
    NSString *login = [row[@"loginKnown"] boolValue]
        ? ([row[@"lastLoginAt"] doubleValue] > 0
            ? [NSString stringWithFormat:@"Authenticated: %@",
                [self relativeDate:row[@"lastLoginAt"]]]
            : @"Account: present")
        : ([row[@"lastLoginAt"] doubleValue] > 0
            ? [NSString stringWithFormat:@"Authenticated: %@",
                [self relativeDate:row[@"lastLoginAt"]]]
            : @"Account: unknown");
    if ([row[@"requiresLoginVerification"] boolValue]) login = @"Restored files: verify login in app";
    NSDictionary *replacement = row[@"replacementState"];
    if ([replacement isKindOfClass:NSDictionary.class] && replacement.count &&
        ![replacement[@"phase"] isEqual:@"committed"]) {
        cell.statusLabel.text = [NSString stringWithFormat:@"REPLACE: %@", replacement[@"phase"] ?: @"needs recovery"];
        cell.statusLabel.textColor = [UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1];
    }
    cell.identityLabel.text = [NSString stringWithFormat:@"%@ · %@\n%@",
        row[@"country"] ?: @"—", row[@"identity"] ?: @"—", row[@"locale"] ?: @"—"];
    cell.metadataLabel.text = [NSString stringWithFormat:
        @"Proxy %@ · %@ · %@\nHealth %@ · %@\nLast active %@\n%@%@",
        row[@"proxyStatus"] ?: @"unknown", vpn, hooks,
        row[@"health"] ?: @"unknown", login, [self relativeDate:row[@"lastActiveAt"]],
        row[@"notes"] ?: @"", [row[@"metadataDirty"] boolValue] ? @"\nMetadata awaiting cloud sync" : @""];
    if ([row[@"isolationSentinel"][@"alert"] boolValue]) {
        cell.statusLabel.text = @"Isolation alert"; cell.statusLabel.textColor = UIColor.systemRedColor;
        cell.metadataLabel.text = [@"Opening blocked · review Diagnostics\n" stringByAppendingString:cell.metadataLabel.text ?: @""];
    }
    cell.accessibilityLabel = [@[cell.nameLabel.text, cell.statusLabel.text, cell.identityLabel.text,
        cell.metadataLabel.text] componentsJoinedByString:@". "];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!self.unlocked) return;
    NSDictionary *row = self.containers[indexPath.row];
    [NSUserDefaults.standardUserDefaults setObject:row[@"id"] forKey:RBXAppScopedPreferenceKey(@"RBXSelectedContainer", self.appDescriptor)];
    [self updateSelectedCard];
    if (self.workspacePage == RBXWorkspacePageLocation) { [self.tableView reloadData]; return; }
    NSDictionary *pendingReplacement = RBXPendingReplacementForRow(row);
    if (pendingReplacement &&
        (!self.advancedMode || [pendingReplacement[@"newId"] isEqual:row[@"id"]] ||
         [pendingReplacement[@"phase"] isEqual:@"deleting"] || row[@"deletionState"] || row[@"profileError"])) {
        [self confirmReplaceContainer:row]; return;
    }
    if ([row[@"deletionState"] isKindOfClass:NSDictionary.class]) {
        [self confirmDeleteContainer:row];
        return;
    }
    NSDictionary *profileError = row[@"profileError"];
    if ([profileError isKindOfClass:NSDictionary.class]) {
        UIAlertController *recovery = [UIAlertController alertControllerWithTitle:@"Profile unavailable"
            message:[NSString stringWithFormat:@"%@\n\nKeep this profile for recovery, or delete its verified local data.",
                profileError[@"message"] ?: @"The profile could not be read."]
            preferredStyle:UIAlertControllerStyleAlert];
        [recovery addAction:[UIAlertAction actionWithTitle:@"Keep profile"
            style:UIAlertActionStyleCancel handler:nil]];
        [recovery addAction:[UIAlertAction actionWithTitle:@"Diagnostics"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                [self.navigationController pushViewController:[[RBXDiagnosticsViewController alloc] initWithAppType:self.appDescriptor[@"appType"]] animated:YES];
            }]];
        [recovery addAction:[UIAlertAction actionWithTitle:@"Delete profile"
            style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
                [self confirmDeleteContainer:row];
            }]];
        [self presentViewController:recovery animated:YES completion:nil];
        return;
    }
    if (!self.advancedMode) {
        UIAlertController *actions = [UIAlertController alertControllerWithTitle:row[@"name"] ?: @"Container" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        [actions addAction:[UIAlertAction actionWithTitle:@"Use this container" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self selectContainer:row]; }]];
        [actions addAction:[UIAlertAction actionWithTitle:@"Configure identity" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self.navigationController pushViewController:[[RBXIdentityViewController alloc] initWithContainerRow:row] animated:YES]; }]];
        [actions addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self renameContainer:row]; }]];
        [actions addAction:[UIAlertAction actionWithTitle:@"Role & notes" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self editMetadata:row]; }]];
        [actions addAction:[UIAlertAction actionWithTitle:@"Cloud backups" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self openCloudVault]; }]];
        [actions addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { [self confirmDeleteContainer:row]; }]];
        [actions addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        actions.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
        actions.popoverPresentationController.sourceRect = actions.popoverPresentationController.sourceView.bounds;
        [self presentViewController:actions animated:YES completion:nil];
        return;
    }
    UIAlertController *actions = [UIAlertController alertControllerWithTitle:
        row[@"name"] ?: row[@"id"] message:
        [self appText:@"Open Reddit or configure this container's stable identity."]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [actions addAction:[UIAlertAction actionWithTitle:[self appText:@"Open Reddit"]
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self confirmOpenContainer:row];
        }]];
    [actions addAction:[UIAlertAction actionWithTitle:@"Identity & Cloaking"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self.navigationController pushViewController:
                [[RBXIdentityViewController alloc] initWithContainerRow:row]
                animated:YES];
        }]];
    [actions addAction:[UIAlertAction actionWithTitle:@"Rename"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self renameContainer:row]; }]];
    [actions addAction:[UIAlertAction actionWithTitle:@"Role & notes"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self editMetadata:row];
        }]];
    if ([self.appDescriptor[@"appType"] isEqual:@"reddit"]) [actions addAction:[UIAlertAction actionWithTitle:@"Check account status"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self.navigationController pushViewController:
                [[RBXAccountStatusViewController alloc] initWithUsername:row[@"username"]] animated:YES];
        }]];
    UIAlertAction *replace = [UIAlertAction actionWithTitle:pendingReplacement ? @"Resume Replace" : @"Replace with new"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { [self confirmReplaceContainer:row]; }];
    replace.enabled = ![row[@"isActive"] boolValue];
    [actions addAction:replace];
    if (!pendingReplacement) [actions addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) { [self confirmDeleteContainer:row]; }]];
    if ([row[@"metadataDirty"] boolValue]) [actions addAction:[UIAlertAction actionWithTitle:@"Use cloud name, role & notes"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self confirmUseCloudMetadata:row];
        }]];
    [actions addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    actions.popoverPresentationController.sourceView = cell;
    actions.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:actions animated:YES completion:nil];
}

- (void)confirmOpenContainer:(NSDictionary *)row {
    if (!self.licensed) return;
    if ([row[@"deletionState"] isKindOfClass:NSDictionary.class] ||
        [row[@"profileError"] isKindOfClass:NSDictionary.class]) return;
    NSString *container = row[@"id"];
    if (!container.length) return;
    [self loadState];
    for (NSDictionary *current in self.launcherState[@"containers"])
        if ([current[@"id"] isEqual:container]) { row=current; break; }
    NSString *setupMessage = [row[@"launchBlockReason"] isKindOfClass:NSString.class] && [row[@"launchBlockReason"] length]
        ? row[@"launchBlockReason"] : RBXContainerSetupMessage(self.launcherState);
    if (setupMessage) {
        [self showContainerSetupMessage:setupMessage];
        return;
    }
    UIAlertController *confirmation = [UIAlertController alertControllerWithTitle:
        [NSString stringWithFormat:@"Open %@?", row[@"name"] ?: container]
        message:@"RedditBox will close the current session, check this container's assigned proxy and VPN protection, then open it."
        preferredStyle:UIAlertControllerStyleAlert];
    [confirmation addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    [confirmation addAction:[UIAlertAction actionWithTitle:@"Open"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self requestAction:@"launchContainer" values:@{@"container": container}
                notification:CFSTR("com.redditbox.launchContainer")];
        }]];
    [self presentViewController:confirmation animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!self.unlocked || !self.advancedMode) return nil;
    NSDictionary *row = self.containers[indexPath.row];
    if (RBXPendingReplacementForRow(row)) {
        UIContextualAction *resume = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
            title:@"Resume Replace" handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^completion)(BOOL)) {
                [self confirmReplaceContainer:row]; completion(NO);
            }];
        resume.backgroundColor = [UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1];
        UISwipeActionsConfiguration *pending = [UISwipeActionsConfiguration configurationWithActions:@[resume]];
        pending.performsFirstActionWithFullSwipe = NO;
        return pending;
    }
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:
        UIContextualActionStyleDestructive title:
            ([row[@"deletionState"] isKindOfClass:NSDictionary.class] ? @"Retry Delete" : @"Delete")
        handler:^(__unused UIContextualAction *action, __unused UIView *view,
                  void (^completionHandler)(BOOL)) {
        [self confirmDeleteContainer:row];
        completionHandler(NO);
    }];
    UISwipeActionsConfiguration *configuration =
        [UISwipeActionsConfiguration configurationWithActions:@[remove]];
    if (![row[@"isActive"] boolValue] && !row[@"profileError"]) {
        UIContextualAction *replace = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
            title:@"Replace" handler:^(UIContextualAction *action, UIView *view, void (^completion)(BOOL)) {
                [self confirmReplaceContainer:row]; completion(NO);
            }];
        replace.backgroundColor = [UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1];
        configuration = [UISwipeActionsConfiguration configurationWithActions:@[remove, replace]];
    }
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}

- (void)confirmReplaceContainer:(NSDictionary *)row {
    if (!self.unlocked) return;
    NSDictionary *journal = RBXPendingReplacementForRow(row);
    BOOL retry = journal != nil;
    NSString *target = retry ? journal[@"oldId"] : row[@"id"];
    if ([row[@"isActive"] boolValue] || ![target isKindOfClass:NSString.class] || !target.length) {
        UIAlertController *blocked = [UIAlertController alertControllerWithTitle:@"Replacement needs attention"
            message:[row[@"isActive"] boolValue]
                ? @"Close this profile before resuming its replacement. Both profiles are retained; neither can be deleted while replacement is unfinished."
                : @"The replacement's original profile cannot be identified. Keep both profiles and open Diagnostics; deleting them would remove recovery data."
            preferredStyle:UIAlertControllerStyleAlert];
        [blocked addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:blocked animated:YES completion:nil]; return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:retry ? @"Resume replacement?" : @"Replace with a fresh container?"
        message:@"The original stays intact until the new identity is prepared and proxy rotation succeeds. Then its app data and credentials are deleted. The name and role are inherited; notes and login start empty. The new clone needs MDM adoption before Open. Failed steps keep a journal for retry."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:retry ? @"Resume Replace" : @"Replace"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self requestAction:@"replaceContainer" values:@{@"container": target ?: @""}
                notification:CFSTR("com.redditbox.containerAction")];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDeleteContainer:(NSDictionary *)row {
    if (!self.unlocked) return;
    if (RBXPendingReplacementForRow(row)) { [self confirmReplaceContainer:row]; return; }
    NSDictionary *deletion = row[@"deletionState"];
    BOOL retry = [deletion isKindOfClass:NSDictionary.class];
    NSString *message = retry
        ? [NSString stringWithFormat:@"%@\n\nRetry the remaining cleanup. This profile cannot be opened while deletion is incomplete.",
            deletion[@"message"] ?: @"Previous cleanup did not finish."]
        : @"Traffic will close and running clones will stop first. The selected clone, its app data, credentials and local recovery copies will be removed. This cannot be undone. Cleanup failures remain visible so you can retry.";
    UIAlertController *confirmation = [UIAlertController alertControllerWithTitle:
        [NSString stringWithFormat:@"Delete %@?", row[@"name"] ?: row[@"id"]]
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [confirmation addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    [confirmation addAction:[UIAlertAction actionWithTitle:retry ? @"Retry Delete" : @"Delete"
        style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *confirm) {
            [self requestAction:@"deleteContainer"
                values:@{@"container": row[@"id"] ?: @""}
                notification:CFSTR("com.redditbox.containerAction")];
        }]];
    [self presentViewController:confirmation animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = self.containers[indexPath.row];
    if (!self.unlocked || !self.advancedMode || [row[@"deletionState"] isKindOfClass:NSDictionary.class] ||
        [row[@"profileError"] isKindOfClass:NSDictionary.class]) return nil;
    UIContextualAction *export = [UIContextualAction contextualActionWithStyle:
        UIContextualActionStyleNormal title:@"Share IPA"
        handler:^(__unused UIContextualAction *action, __unused UIView *view,
                  void (^completionHandler)(BOOL)) {
        [self requestAction:@"exportCloneIPA"
            values:@{@"container": row[@"id"] ?: @""}
            notification:CFSTR("com.redditbox.launcherAction")];
        completionHandler(YES);
    }];
    export.backgroundColor = RBXAccentColor();
    return [UISwipeActionsConfiguration configurationWithActions:@[export]];
}

- (void)createContainer {
    if (!self.unlocked || !self.licensed) return;
    NSString *sourceError = [self.appDescriptor[@"appType"] isEqual:@"reddit"] ? nil : RBXAppSourceReadinessError(self.launcherState, self.appDescriptor);
    if (sourceError) { [self showMessage:@"Source not ready" detail:sourceError]; return; }
    if (!self.advancedMode) {
        [self.navigationController pushViewController:[[RBXSimpleWizardViewController alloc]
            initWithAppType:self.appDescriptor[@"appType"]] animated:YES];
        return;
    }
    NSDictionary *creationDefaults = RBXCreationDefaults(NSUserDefaults.standardUserDefaults, self.appDescriptor, nil);
    UIAlertController *form = [UIAlertController alertControllerWithTitle:@"New container"
        message:@"Region, language and a suggested carrier are filled from the selected proxy. The clone stays blocked until setup is complete."
        preferredStyle:UIAlertControllerStyleAlert];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Name";
        field.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Country (Auto from proxy)";
        field.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        field.text = creationDefaults[@"country"];
    }];
    if (self.advancedMode) [form addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Role: signup / warmup / spam / default";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.text = creationDefaults[@"role"];
    }];
    [form addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    [form addAction:[UIAlertAction actionWithTitle:@"Create"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *name = [form.textFields[0].text
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSString *country = [[form.textFields[1].text
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                uppercaseString];
            if (!name.length) name = [self appText:@"Reddit profile"];
            if (country.length && country.length != 2) {
                [self showMessage:@"Country" detail:@"Leave country empty for automatic detection, or enter a two-letter code such as US."]; return;
            }
            NSString *role = self.advancedMode ? [form.textFields[2].text lowercaseString] : creationDefaults[@"role"];
            if (![RBXProfileRoles() containsObject:role ?: @""]) {
                [self showMessage:@"Choose a role" detail:@"Use signup, warmup, spam or default."]; return;
            }
            NSString *container = [@"p-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
            [self requestAction:@"createContainer" values:@{
                @"container": container, @"nickname": name, @"country": country, @"role": role, @"autoRegion":@(country.length == 0)}
                notification:CFSTR("com.redditbox.containerAction")];
        }]];
    [self presentViewController:form animated:YES completion:nil];
}

- (void)groupingChanged {
    [NSUserDefaults.standardUserDefaults setBool:self.roleGrouping.on forKey:RBXAppScopedPreferenceKey(@"RBXGroupByRole", self.appDescriptor)];
    [self loadState];
}

- (void)renameContainer:(NSDictionary *)row {
    if (!self.unlocked || !self.licensed || ![row[@"id"] isKindOfClass:NSString.class]) return;
    UIAlertController *form = [UIAlertController alertControllerWithTitle:@"Rename container"
        message:@"Change the name shown in SocialBox and Cloud. The account, identity and app data stay the same."
        preferredStyle:UIAlertControllerStyleAlert];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Container name";
        field.text = row[@"name"] ?: @"";
        field.accessibilityIdentifier = @"socialbox.rename.name";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [form addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [form addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *name = [form.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!RBXProfileNicknameValid(name)) {
            [self showMessage:@"Name not saved" detail:@"Use 1–120 characters without line breaks or control characters."]; return;
        }
        if ([name isEqual:row[@"name"]]) return;
        [self requestAction:@"updateMetadata" values:@{@"container":row[@"id"], @"nickname":name}
            notification:CFSTR("com.redditbox.containerAction")];
    }]];
    [self presentViewController:form animated:YES completion:nil];
}

- (void)editMetadata:(NSDictionary *)row {
    UIAlertController *form = [UIAlertController alertControllerWithTitle:@"Role & notes"
        message:@"Organizational labels only. Notes: at most 200 characters. Refresh to sync with cloud."
        preferredStyle:UIAlertControllerStyleAlert];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"signup / warmup / spam / default";
        field.text = RBXProfileRole(row[@"role"]);
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Notes (200 characters)";
        field.text = row[@"notes"] ?: @"";
    }];
    [form addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [form addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *role = form.textFields[0].text.lowercaseString;
        NSString *notes = form.textFields[1].text ?: @"";
        if (![RBXProfileRoles() containsObject:role ?: @""] || !RBXProfileNotesValid(notes)) {
            [self showMessage:@"Metadata not saved" detail:@"Choose a listed role and at most 200 characters of notes."];
            return;
        }
        [self requestAction:@"updateMetadata" values:@{@"container": row[@"id"], @"role": role, @"notes": notes}
            notification:CFSTR("com.redditbox.containerAction")];
    }]];
    [self presentViewController:form animated:YES completion:nil];
}

- (void)confirmUseCloudMetadata:(NSDictionary *)row {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Use cloud name, role & notes?"
        message:@"This discards pending local metadata edits on the next successful cloud refresh. Profile identity and data stay intact."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Use cloud" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self requestAction:@"discardMetadataChanges" values:@{@"container": row[@"id"]}
            notification:CFSTR("com.redditbox.containerAction")];
        [self refreshFromCloud];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)refreshFromCloud {
    if (!self.unlocked && [RBXPasscodeStore hasPasscode]) return;
    [self.stateRefreshControl beginRefreshing];
    [self requestAction:@"refreshLauncher" values:@{}
        notification:CFSTR("com.redditbox.launcherAction")];
}

- (void)showSettings {
    if (!self.unlocked) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Launcher settings"
        message:@"All normal setup and diagnostics are available here."
        preferredStyle:UIAlertControllerStyleActionSheet];
    if (!self.advancedMode) [sheet addAction:[UIAlertAction actionWithTitle:@"Advanced profiles"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self showAdvancedOverview]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Proxy settings"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self.navigationController pushViewController:
                [[RBXProxiesViewController alloc] initWithAppType:self.appDescriptor[@"appType"]] animated:YES];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Diagnostics"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self.navigationController pushViewController:
                [[RBXDiagnosticsViewController alloc] initWithAppType:self.appDescriptor[@"appType"]] animated:YES];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Refresh cloud profiles"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self refreshFromCloud];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Open firewall setup"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self requestAction:@"openFirewall" values:@{}
                notification:CFSTR("com.redditbox.launcherAction")];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Share MDM/VPN setup"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSError *error = nil;
            // Role filtering only changes the visible list, never VPN coverage.
            id inventory = self.launcherState[@"containers"];
            NSArray *allContainers = [inventory isKindOfClass:NSArray.class] ? inventory : @[];
            NSArray *available = [allContainers filteredArrayUsingPredicate:
                [NSPredicate predicateWithBlock:^BOOL(NSDictionary *row, NSDictionary *bindings) {
                    return ![row[@"deletionState"] isKindOfClass:NSDictionary.class] &&
                        ![row[@"profileError"] isKindOfClass:NSDictionary.class];
                }]];
            NSArray<NSURL *> *files = [RBXMDMExporter
                exportFilesForContainers:available appType:self.appDescriptor[@"appType"] error:&error];
            if (!files.count) {
                [self showMessage:@"MDM export failed"
                    detail:error.localizedDescription ?: @"No setup files were created."];
                return;
            }
            UIActivityViewController *share = [[UIActivityViewController alloc]
                initWithActivityItems:files applicationActivities:nil];
            share.popoverPresentationController.sourceView = self.view;
            share.popoverPresentationController.sourceRect =
                CGRectMake(CGRectGetMidX(self.view.bounds),
                    CGRectGetMidY(self.view.bounds), 1, 1);
            [self presentViewController:share animated:YES completion:nil];
        }]];
    // Source removal still uses the audited Reddit lifecycle; never offer it for another app.
    if ([self.appDescriptor[@"appType"] isEqual:@"reddit"]) [sheet addAction:[UIAlertAction actionWithTitle:[self appText:@"Hide source Reddit app"]
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            UIAlertController *confirm = [UIAlertController alertControllerWithTitle:
                @"Archive source app?"
                message:[NSString stringWithFormat:@"RedditBox will keep a private decrypted source for future clones, then uninstall the visible %@ app and its existing app data. Create or back up any needed profile first.", self.appDescriptor[@"displayName"]]
                preferredStyle:UIAlertControllerStyleAlert];
            [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                style:UIAlertActionStyleCancel handler:nil]];
            [confirm addAction:[UIAlertAction actionWithTitle:@"Archive and uninstall"
                style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *confirmAction) {
                    [self requestAction:@"archiveSource" values:@{}
                        notification:CFSTR("com.redditbox.launcherAction")];
                }]];
            [self presentViewController:confirm animated:YES completion:nil];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:
        ([RBXPasscodeStore hasPasscode] ? @"Change passcode" : @"Set passcode")
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self promptToSetPasscode];
        }]];
    if ([RBXPasscodeStore hasPasscode]) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Remove passcode"
            style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
                NSError *error = nil;
                if (![RBXPasscodeStore clearPasscode:&error]) {
                    [self showMessage:@"Passcode not removed"
                        detail:error.localizedDescription ?: @"Could not remove the passcode. Try again."];
                }
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showAdvancedOverview {
    if (!self.unlocked) return;
    RBXLauncherViewController *advanced = [[RBXLauncherViewController alloc] initWithAppType:self.appDescriptor[@"appType"] advancedMode:YES];
    advanced.unlocked = self.unlocked; advanced.offeredFirstRun = YES;
    [self.navigationController pushViewController:advanced animated:YES];
}

- (void)showSimpleChecks {
    if (!self.unlocked) return;
    [self.navigationController pushViewController:[[RBXIsolationViewController alloc] initWithAppType:self.appDescriptor[@"appType"]] animated:YES];
}

- (void)promptToSetPasscode {
    UIAlertController *form = [UIAlertController alertControllerWithTitle:@"Set passcode"
        message:@"Use 4–32 characters." preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *placeholder in @[@"New passcode", @"Confirm passcode"]) {
        [form addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = placeholder;
            field.secureTextEntry = YES;
        }];
    }
    [form addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    [form addAction:[UIAlertAction actionWithTitle:@"Save"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *first = form.textFields[0].text ?: @"";
            NSString *second = form.textFields[1].text ?: @"";
            NSError *error = nil;
            if (![first isEqualToString:second] ||
                ![RBXPasscodeStore setPasscode:first error:&error]) {
                [self showMessage:@"Passcode not changed"
                    detail:error.localizedDescription ?: @"The passcodes do not match."];
            }
        }]];
    [self presentViewController:form animated:YES completion:nil];
}

- (BOOL)workspaceUnlocked { return self.unlocked && self.licensed; }
- (void)adoptWorkspaceUnlockFromController:(RBXLauncherViewController *)controller {
    self.unlocked = [controller workspaceUnlocked];
}

- (void)setLocked:(BOOL)locked {
    self.tabBarController.tabBar.userInteractionEnabled = !locked;
    self.tableView.accessibilityElementsHidden = locked;
    if (!locked) {
        [self.lockOverlay removeFromSuperview];
        self.lockOverlay = nil;
        self.tableView.userInteractionEnabled = YES;
        return;
    }
    self.tableView.userInteractionEnabled = NO;
    if (!self.lockOverlay) {
        self.lockOverlay = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
        self.lockOverlay.frame = self.view.bounds;
        self.lockOverlay.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.lockOverlay.accessibilityViewIsModal = YES;
        [self.view addSubview:self.lockOverlay];
    }
}

- (void)promptForPasscode {
    UIAlertController *form = [UIAlertController alertControllerWithTitle:@"RedditBox locked"
        message:@"Enter the launcher passcode." preferredStyle:UIAlertControllerStyleAlert];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.secureTextEntry = YES;
        field.keyboardType = UIKeyboardTypeASCIICapable;
    }];
    [form addAction:[UIAlertAction actionWithTitle:@"Unlock"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            if ([RBXPasscodeStore verifyPasscode:form.textFields.firstObject.text]) {
                self.unlocked = YES;
                [self setLocked:NO];
                [self loadState];
                [self offerFirstRunIfNeeded];
            } else {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self promptForPasscode];
                });
            }
        }]];
    [self presentViewController:form animated:YES completion:nil];
}

- (void)offerFirstRunIfNeeded {
    if (self.offeredFirstRun || !self.unlocked || !self.licensed) return;
    if (self.tabBarController) { self.offeredFirstRun = YES; return; }
    self.offeredFirstRun = YES;
    NSDictionary *configuration = [RBXSecureConfig rotationConfiguration:nil];
    if ([configuration[@"proxyURL"] length]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        RBXSettingsViewController *settings =
            [[RBXSettingsViewController alloc] initWithAppType:self.appDescriptor[@"appType"] wizardMode:YES];
        UINavigationController *navigation =
            [[UINavigationController alloc] initWithRootViewController:settings];
        RBXStyleNavigation(navigation);
        navigation.modalPresentationStyle = UIModalPresentationFormSheet;
        [self presentViewController:navigation animated:YES completion:nil];
    });
}

- (void)showMessage:(NSString *)title detail:(NSString *)detail {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:RBXOperatorMessage(detail) preferredStyle:UIAlertControllerStyleAlert];
    if (!self.advancedMode) [alert addAction:[UIAlertAction actionWithTitle:RBXOperatorText(@"advanced")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self showAdvancedOverview]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self dismissViewControllerAnimated:YES completion:^{ [self loadState]; }];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)shareCloneIPA:(NSString *)path profile:(NSString *)profile {
    NSData *data = path.length ? [NSData dataWithContentsOfFile:path] : nil;
    if (!data.length) {
        [self showMessage:@"Export unavailable"
            detail:@"The launcher could not read the daemon's temporary IPA."];
        return;
    }
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"rbx-share-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *localPath = [directory stringByAppendingPathComponent:@"RedditBox-Profile.ipa"];
    NSError *copyError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions: @0700} error:&copyError] ||
        ![data writeToFile:localPath options:NSDataWritingAtomic error:&copyError] ||
        chmod(localPath.fileSystemRepresentation, 0600) != 0) {
        NSError *cleanupError = nil;
        BOOL cleaned = RBXRemoveShareDirectory(directory, &cleanupError);
        [self showMessage:@"Export unavailable" detail:cleaned ?
            (copyError.localizedDescription ?: @"Could not secure the temporary IPA.") :
            @"Copy failed and the temporary IPA needs cleanup; retry after restarting the launcher."];
        return;
    }
    // The result must name the known daemon export, never an arbitrary path.
    if ([path isEqual:@"/var/mobile/Library/Preferences/com.redditbox.clone-export.ipa"] &&
        ![NSFileManager.defaultManager removeItemAtPath:path error:&copyError])
        self.shareCleanupError = @"The daemon export could not be removed. Delete the profile export after sharing.";
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:localPath]]
        applicationActivities:nil];
    __weak typeof(self) weakSelf = self;
    share.completionWithItemsHandler = ^(UIActivityType activity, BOOL completed, NSArray *items, NSError *activityError) {
        NSError *cleanupError = nil;
        BOOL cleaned = RBXRemoveShareDirectory(directory, &cleanupError);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!cleaned) weakSelf.shareCleanupError = cleanupError.localizedDescription ?:
                @"The temporary IPA could not be removed; restart the launcher to retry cleanup.";
            [weakSelf loadState];
        });
    };
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:share animated:YES completion:nil];
}

@end
