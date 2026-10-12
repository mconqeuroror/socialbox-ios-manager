#import "RBXAppScope.h"
#import "RBXCreationDefaults.h"
#import "RBXProfileMetadata.h"
#import "RBXSimpleWizardViewController.h"
#import "RBXAppearance.h"
#import "RBXLauncherIPC.h"
#import "RBXLauncherViewController.h"
#import "RBXSettingsViewController.h"
#import "RBXProxiesViewController.h"
#import "RBXIdentityViewController.h"
#import "RBXOperatorWording.h"
#import "RBXWizardDraft.h"
#import "RBXSecureConfig.h"

static NSString *const RBXWizardDraftKey = @"RBXSimpleWizardDraft";
static NSString *const RBXWizardOwner = @"simple-wizard";

@interface RBXSimpleWizardViewController ()
@property(nonatomic, copy) NSDictionary *appDescriptor;
@property(nonatomic, strong) UITextField *nameField;
@property(nonatomic, strong) UITextField *countryField;
@property(nonatomic, strong) UISegmentedControl *roleControl;
@property(nonatomic, strong) UILabel *proxyLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *reviewLabel;
@property(nonatomic, strong) UIButton *generateButton;
@property(nonatomic, strong) UIButton *createButton;
@property(nonatomic, strong) UIButton *discardButton;
@property(nonatomic, strong) UIButton *reviewButton;
@property(nonatomic, strong) UIButton *proxyButton;
@property(nonatomic, strong) UIButton *resetButton;
@property(nonatomic, strong) UIButton *detailsButton;
@property(nonatomic, strong) UIStackView *detailsStack;
@property(nonatomic, strong) UILabel *defaultsLabel;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) NSDictionary *draft;
@property(nonatomic, copy) NSDictionary *createdRow;
@property(nonatomic, copy) NSString *pendingRequestId;
@property(nonatomic) BOOL proxySelected;
@property(nonatomic, copy) NSDictionary *selectedProxyConfiguration;
@end

@implementation RBXSimpleWizardViewController
- (instancetype)init { return [self initWithAppType:@"reddit"]; }
- (instancetype)initWithAppType:(NSString *)appType {
    NSDictionary *descriptor = [appType isKindOfClass:NSString.class] ? RBXAppDescriptorForType(appType) : nil;
    if (!descriptor) return nil;
    if ((self = [super initWithNibName:nil bundle:nil])) _appDescriptor = descriptor;
    return self;
}
- (NSString *)draftKey { return RBXAppScopedPreferenceKey(RBXWizardDraftKey, self.appDescriptor); }
- (NSString *)requestOwner { return RBXAppScopedPreferenceKey(RBXWizardOwner, self.appDescriptor); }


- (UIButton *)button:(NSString *)title action:(SEL)action primary:(BOOL)primary {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    RBXStyleButton(button, primary);
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UITextField *)field:(NSString *)placeholder text:(NSString *)text {
    UITextField *field = [UITextField new];
    field.placeholder = placeholder;
    field.text = text;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    RBXStyleField(field);
    return field;
}

- (NSDictionary *)state {
    return RBXAppScopedLauncherState([NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist"], self.appDescriptor) ?: @{};
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"New container";
    self.view.backgroundColor = RBXCanvasColor();
    self.view.tintColor = RBXAccentColor();
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Done"
        style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.draft = [NSUserDefaults.standardUserDefaults dictionaryForKey:self.draftKey] ?: @{};
    NSDictionary *creationDefaults = RBXCreationDefaults(NSUserDefaults.standardUserDefaults, self.appDescriptor, self.draft);
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    UIStackView *page = [UIStackView new];
    page.axis = UILayoutConstraintAxisVertical;
    page.spacing = 20;
    page.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:page];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [page.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [page.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [page.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [page.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [page.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
    ]];
    UIStackView *section = RBXFormSection(page, @"1 · Name", @"An organizational label for this container.");
    self.nameField = [self field:@"Container name" text:self.draft[@"nickname"] ?: @""];
    [self.nameField addTarget:self action:@selector(formDidChange) forControlEvents:UIControlEventEditingChanged];
    [section addArrangedSubview:self.nameField];
    self.roleControl = [[UISegmentedControl alloc] initWithItems:@[@"Default", @"Signup", @"Warmup", @"Spam"]];
    NSUInteger role = [@[@"default", @"signup", @"warmup", @"spam"] indexOfObject:creationDefaults[@"role"]];
    self.roleControl.selectedSegmentIndex = role == NSNotFound ? 0 : role;
    [self.roleControl addTarget:self action:@selector(formDidChange) forControlEvents:UIControlEventValueChanged];
    section = RBXFormSection(page, @"2 · Proxy setup", RBXOperatorText(@"proxy-assignment"));
    self.proxyLabel = RBXLabel(@"Select the configured device proxy or set it up first.", UIFontTextStyleBody, NO);
    [section addArrangedSubview:self.proxyLabel];
    self.proxyButton = [self button:@"Choose device proxy" action:@selector(chooseProxy) primary:NO];
    [section addArrangedSubview:self.proxyButton];
    self.defaultsLabel = RBXLabel(@"", UIFontTextStyleFootnote, YES);
    [section addArrangedSubview:self.defaultsLabel];
    self.detailsButton = [self button:@"Details · optional defaults" action:@selector(toggleDetails) primary:NO];
    [section addArrangedSubview:self.detailsButton];
    self.detailsStack = [UIStackView new];
    self.detailsStack.axis = UILayoutConstraintAxisVertical;
    self.detailsStack.spacing = 12;
    self.detailsStack.hidden = YES;
    [section addArrangedSubview:self.detailsStack];
    [self.detailsStack addArrangedSubview:RBXLabel(@"Country: leave empty for Auto from proxy. A fixed country must match the proxy. Carrier and language are suggestions you can review before Create.", UIFontTextStyleFootnote, YES)];
    self.countryField = [self field:@"Auto from proxy" text:creationDefaults[@"country"]];
    self.countryField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    [self.countryField addTarget:self action:@selector(formDidChange) forControlEvents:UIControlEventEditingChanged];
    [self.detailsStack addArrangedSubview:self.countryField];
    [self.detailsStack addArrangedSubview:RBXLabel(@"Role is only an organizational label; it does not change isolation.", UIFontTextStyleFootnote, YES)];
    [self.detailsStack addArrangedSubview:self.roleControl];
    [self updateDefaultsLabel];
    section = RBXFormSection(page, @"3 · Automatic identity", RBXOperatorText(@"generated"));
    [section addArrangedSubview:RBXLabel(@"Prepare a complete identity through your selected proxy. Review or edit every supported value before creating anything. The preview expires after five minutes or a daemon restart.", UIFontTextStyleFootnote, YES)];
    self.generateButton = [self button:@"Prepare preview" action:@selector(generate) primary:YES];
    [section addArrangedSubview:self.generateButton];
    self.statusLabel = RBXLabel(@"", UIFontTextStyleBody, YES);
    [section addArrangedSubview:self.statusLabel];
    self.resetButton = [self button:@"Reset failed create step" action:@selector(resetFailedDraft) primary:NO];
    self.resetButton.hidden = YES;
    [section addArrangedSubview:self.resetButton];
    section = RBXFormSection(page, @"4 · Review", @"The container stays closed. Opening later checks its cloud proxy assignment and managed VPN setup.");
    self.reviewLabel = RBXLabel(@"Prepare a preview to see the model, iOS, region, carrier and language.", UIFontTextStyleBody, NO);
    [section addArrangedSubview:self.reviewLabel];
    self.reviewButton = [self button:@"Review identity" action:@selector(review) primary:NO];
    self.reviewButton.enabled = NO;
    [section addArrangedSubview:self.reviewButton];
    self.createButton = [self button:@"Create container" action:@selector(commitCreation) primary:YES];
    self.createButton.accessibilityIdentifier = @"creation.commit";
    self.createButton.hidden = YES;
    [section addArrangedSubview:self.createButton];
    self.discardButton = [self button:@"Discard preview" action:@selector(discardPreview) primary:NO];
    self.discardButton.hidden = YES;
    [section addArrangedSubview:self.discardButton];
    [page addArrangedSubview:[self button:RBXOperatorText(@"advanced") action:@selector(openAdvanced) primary:NO]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.pendingRequestId = [RBXLauncherIPC pendingRequestsForOwner:self.requestOwner].firstObject[@"requestId"];
    if (!self.pendingRequestId.length && [self.draft[@"stage"] isEqual:@"preparing"]) {
        // UI-002: Prepare cannot provision a container. A crash before its
        // owner/receipt was saved may abandon only an expiring private preview.
        // Never apply this recovery to an ambiguous Create transaction.
        [self retainEditableDraft];
        self.statusLabel.text = @"Preparation was interrupted. Your name and options are kept; select a proxy and prepare again.";
    }
    if (!self.pendingRequestId.length && [self.draft[@"creationDraftToken"] length] &&
        ![self.draft[@"stage"] isEqual:@"committing"] && ![self.draft[@"stage"] isEqual:@"committed"]) {
        self.pendingRequestId = [RBXLauncherIPC sendActionReturningRequestId:@"reviewContainerDraft"
            values:self.draft notification:CFSTR("com.redditbox.launcherAction") owner:self.requestOwner appType:self.appDescriptor[@"appType"]];
    }
    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}
- (void)viewWillDisappear:(BOOL)animated {
    [self formDidChange];
    [super viewWillDisappear:animated]; [self.timer invalidate]; self.timer = nil;
}
- (void)dealloc { [self.timer invalidate]; }

- (NSString *)selectedRole {
    NSArray *roles = @[@"default", @"signup", @"warmup", @"spam"];
    NSInteger index = self.roleControl.selectedSegmentIndex;
    return index >= 0 && index < (NSInteger)roles.count ? roles[index] : @"default";
}
- (void)updateDefaultsLabel {
    NSString *country = [self.countryField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].uppercaseString;
    self.defaultsLabel.text = [NSString stringWithFormat:@"Country: %@ · Role: %@", country.length ? country : @"Auto from proxy", self.selectedRole.capitalizedString];
}
- (void)formDidChange {
    [self updateDefaultsLabel];
    if (self.pendingRequestId.length || [self.draft[@"container"] length]) return;
    // Editable form metadata only: no proxy credentials, generated identity,
    // request replay or changes to an existing container.
    self.draft = @{@"nickname":self.nameField.text ?: @"", @"country":self.countryField.text ?: @"", @"role":self.selectedRole};
    [self saveDraft];
}
- (void)toggleDetails {
    self.detailsStack.hidden = !self.detailsStack.hidden;
    [self.detailsButton setTitle:self.detailsStack.hidden ? @"Details · optional defaults" : @"Hide details" forState:UIControlStateNormal];
}
- (NSDictionary *)currentProxyChoice {
    // Read the device's secure configuration directly, not a potentially stale
    // daemon publication. Only the non-secret host and revision leave this call.
    NSDictionary *configuration = [RBXSecureConfig safeSummary];
    if (![configuration[@"configured"] isEqual:@YES] || ![configuration[@"readable"] isEqual:@YES] ||
        [configuration[@"disabled"] boolValue] || ![configuration[@"proxyHost"] isKindOfClass:NSString.class] ||
        ![configuration[@"proxyHost"] length] || ![configuration[@"updatedAt"] isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)configuration[@"updatedAt"]) == CFBooleanGetTypeID() ||
        !isfinite([configuration[@"updatedAt"] doubleValue]) || [configuration[@"updatedAt"] doubleValue] <= 0) return nil;
    return @{@"proxyHost":configuration[@"proxyHost"], @"updatedAt":configuration[@"updatedAt"]};
}
- (void)selectProxyChoice:(NSDictionary *)choice {
    self.selectedProxyConfiguration = choice;
    self.proxySelected = choice != nil;
    self.proxyLabel.text = [NSString stringWithFormat:@"Device configuration selected · %@\nContainer assignment is checked on Open.", choice[@"proxyHost"] ?: @"Host configured"];
}
- (void)refreshProxyChoice {
    if (self.proxySelected && ![self.selectedProxyConfiguration isEqual:[self currentProxyChoice]]) {
        self.proxySelected = NO;
        self.selectedProxyConfiguration = nil;
        self.proxyLabel.text = @"The device proxy changed or became unavailable. Choose its current configuration before preparing.";
    }
}

- (void)chooseProxy {
    if (self.pendingRequestId.length || [self.draft[@"container"] length]) return;
    NSDictionary *configuration = [self currentProxyChoice];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Device proxy configuration"
        message:@"This selects the device's existing configuration. Your cloud still assigns the container's own proxy before Open."
        preferredStyle:UIAlertControllerStyleActionSheet];
    if (configuration) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Use configured device proxy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSDictionary *current = [self currentProxyChoice];
            if (![configuration isEqual:current]) {
                self.proxySelected = NO; self.selectedProxyConfiguration = nil;
                self.proxyLabel.text = @"The proxy changed while choosing. Select its current configuration again.";
                return;
            }
            [self selectProxyChoice:current];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Manage saved proxies" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        RBXProxiesViewController *library = [[RBXProxiesViewController alloc] initWithAppType:self.appDescriptor[@"appType"]];
        __weak typeof(self) weakSelf = self;
        library.didSelectProxy = ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.pendingRequestId.length || [strongSelf.draft[@"container"] length]) return;
            NSDictionary *choice = [strongSelf currentProxyChoice];
            if (choice) [strongSelf selectProxyChoice:choice];
        };
        [self.navigationController pushViewController:library animated:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.proxyButton;
    sheet.popoverPresentationController.sourceRect = self.proxyButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)generate {
    NSString *sourceError = [self.appDescriptor[@"appType"] isEqual:@"reddit"] ? nil : RBXAppSourceReadinessError(self.state, self.appDescriptor);
    if (sourceError) { self.statusLabel.text = sourceError; return; }
    if (self.pendingRequestId.length || [self.draft[@"container"] length]) { [self refresh]; return; }
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *country = [self.countryField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].uppercaseString;
    if (!RBXProfileNicknameValid(name) || (country.length && [RBXOperatorCountry(country) isEqual:@"Country not verified"])) {
        self.statusLabel.text = @"Enter a name of 1–120 characters without control characters. Leave country empty for Auto from proxy, or enter a supported two-letter code."; return;
    }
    [self refreshProxyChoice];
    if (!self.proxySelected) {
        self.statusLabel.text = @"Choose the configured device proxy or finish proxy setup first."; return;
    }
    NSString *role = self.selectedRole;
    self.draft = @{@"container":[@"p-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString],
        @"nickname":name, @"country":country, @"role":role, @"autoRegion":@(country.length == 0), @"stage":@"preparing",
        @"proxyConfigurationUpdatedAt":self.selectedProxyConfiguration[@"updatedAt"]};
    // UI-002: metadata only. Existing IPC owns the durable request; never persist credentials.
    [NSUserDefaults.standardUserDefaults setObject:self.draft forKey:self.draftKey];
    self.pendingRequestId = [RBXLauncherIPC sendActionReturningRequestId:@"prepareContainer"
        values:self.draft notification:CFSTR("com.redditbox.containerAction") owner:self.requestOwner appType:self.appDescriptor[@"appType"]];
    if (!self.pendingRequestId.length) {
        // The durable queue returns an ID even after post-publication fsync
        // failure. nil therefore means no request was published: retain only
        // editable metadata and permit an explicit Generate retry.
        [self retainEditableDraft];
        self.statusLabel.text = @"The request was not sent. Check device status, then tap Prepare preview to retry.";
    } else {
        NSMutableDictionary *submitted = self.draft.mutableCopy;
        submitted[@"requestId"] = self.pendingRequestId;
        self.draft = submitted;
        [NSUserDefaults.standardUserDefaults setObject:self.draft forKey:self.draftKey];
    }
    [self refresh];
}

- (void)saveDraft { [NSUserDefaults.standardUserDefaults setObject:self.draft forKey:self.draftKey]; }

- (void)commitCreation {
    if (self.pendingRequestId.length || ![self.draft[@"stage"] isEqual:@"review"] ||
        ![self.draft[@"creationDraftToken"] length] || [self.draft[@"expiresAt"] doubleValue] <= NSDate.date.timeIntervalSince1970) return;
    NSMutableDictionary *submitted = self.draft.mutableCopy;
    submitted[@"stage"] = @"committing";
    self.draft = submitted; [self saveDraft];
    self.pendingRequestId = [RBXLauncherIPC sendActionReturningRequestId:@"createContainer"
        values:self.draft notification:CFSTR("com.redditbox.containerAction") owner:self.requestOwner appType:self.appDescriptor[@"appType"]];
    submitted[@"stage"] = self.pendingRequestId.length ? @"committing" : @"review";
    if (self.pendingRequestId.length) submitted[@"requestId"] = self.pendingRequestId;
    self.draft = submitted; [self saveDraft];
    self.statusLabel.text = self.pendingRequestId.length ? @"Creating your reviewed container…" : @"The request was not sent. The preview is kept; retry Create.";
    [self refresh];
}

- (void)discardPreview {
    // A queued/ambiguous Create can only reset using its exact failed receipt
    // and a fresh daemon inventory. Discard is exclusively an unsaved preview.
    if (self.pendingRequestId.length || self.createdRow ||
        [@[@"committing", @"committed"] containsObject:self.draft[@"stage"] ?: @""]) return;
    if ([self.draft[@"creationDraftToken"] length]) {
        self.pendingRequestId = [RBXLauncherIPC sendActionReturningRequestId:@"discardContainerDraft"
            values:self.draft notification:CFSTR("com.redditbox.launcherAction") owner:self.requestOwner appType:self.appDescriptor[@"appType"]];
        if (self.pendingRequestId.length) { [self refresh]; return; }
    }
    [self retainEditableDraft];
    self.statusLabel.text = @"Preview discarded. No container was created.";
    [self refresh];
}

- (void)refresh {
    [self refreshProxyChoice];
    NSDictionary *state = self.state;
    NSString *container = self.draft[@"container"];
    self.createdRow = nil;
    for (NSDictionary *row in state[@"containers"] ?: @[]) if ([row[@"id"] isEqual:container]) { self.createdRow = row; break; }
    if (self.pendingRequestId.length) {
        NSDictionary *result = [RBXLauncherIPC requestResultForId:self.pendingRequestId];
        if (result && self.view.window && self.navigationController.topViewController == self) {
            NSString *action = result[@"action"];
            BOOL ok = [result[@"ok"] isEqual:@YES];
            NSDictionary *details = [result[@"details"] isKindOfClass:NSDictionary.class] ? result[@"details"] : @{};
            if ([@[@"prepareContainer", @"reviewContainerDraft"] containsObject:action]) {
                if (ok && [details[@"containerId"] isEqual:container] &&
                    [details[@"appType"] isEqual:self.appDescriptor[@"appType"]] && [details[@"creationDraftToken"] length]) {
                    NSMutableDictionary *ready = self.draft.mutableCopy;
                    for (NSString *key in @[@"creationDraftToken", @"creationDraftRevision", @"expiresAt", @"review"])
                        if (details[key]) ready[key] = details[key];
                    ready[@"stage"] = @"review";
                    [ready removeObjectForKey:@"requestId"];
                    self.draft = ready; [self saveDraft];
                } else {
                    // These actions cannot create a container. Stale previews
                    // are safe to drop, without retrying any operation.
                    [self retainEditableDraft];
                }
            } else if ([action isEqual:@"discardContainerDraft"]) {
                [self retainEditableDraft]; // Expired/missing tokens are also safe to forget.
            } else if ([action isEqual:@"createContainer"] && [result[@"containerId"] isEqual:container]) {
                NSMutableDictionary *observed = self.draft.mutableCopy;
                observed[@"requestId"] = self.pendingRequestId;
                observed[@"stage"] = ok ? @"committed" : @"committing";
                self.draft = observed; [self saveDraft];
            }
            self.statusLabel.text = RBXOperatorMessage(result[@"message"] ?: @"Operation completed.");
            [RBXLauncherIPC finishObservingRequestId:self.pendingRequestId owner:self.requestOwner];
            self.pendingRequestId = nil;
        } else self.statusLabel.text = RBXOperatorText(@"waiting");
    }
    BOOL submitted = [self.draft[@"container"] length] > 0 || self.pendingRequestId.length > 0;
    BOOL prepared = [self.draft[@"stage"] isEqual:@"review"] && [self.draft[@"creationDraftToken"] length];
    BOOL expired = prepared && [self.draft[@"expiresAt"] doubleValue] <= NSDate.date.timeIntervalSince1970;
    BOOL available = self.createdRow && !self.createdRow[@"profileError"] && !self.createdRow[@"deletionState"];
    self.nameField.enabled = !submitted; self.countryField.enabled = !submitted;
    self.roleControl.enabled = !submitted; self.proxyButton.enabled = !submitted;
    self.generateButton.enabled = !submitted;
    self.generateButton.hidden = prepared || available;
    self.reviewButton.enabled = !self.pendingRequestId.length && (available || (prepared && !expired));
    self.createButton.hidden = !prepared || available;
    self.createButton.enabled = prepared && !expired && !self.pendingRequestId.length && !available;
    self.discardButton.hidden = available || !prepared;
    self.discardButton.enabled = !self.pendingRequestId.length;
    if (expired && !self.pendingRequestId.length) self.statusLabel.text = @"Preview expired. Discard it and prepare again; no container was created.";
    NSDictionary *identity = available ? self.createdRow[@"identityEditor"] : self.draft[@"review"];
    self.reviewLabel.text = identity ? [NSString stringWithFormat:@"%@\niOS %@\nRegion: %@\nCarrier: %@ (suggestion)\nLanguage: %@\nTime zone: %@\n\n%@",
        identity[@"marketingName"] ?: identity[@"productType"] ?: @"Model not verified",
        identity[@"iosVersion"] ?: @"Not verified", RBXOperatorCountry(identity[@"country"]),
        identity[@"carrierName"] ?: identity[@"carrierCode"] ?: @"Not verified", identity[@"locale"] ?: @"Not verified",
        identity[@"timezone"] ?: @"Not verified", available ? @"Created. Network readiness is checked separately before Open." : @"Preview only — nothing created. You can edit or discard it."] : @"Prepare a preview to see your generated values.";
    NSDictionary *terminal = [RBXLauncherIPC requestResultForId:self.draft[@"requestId"]];
    self.resetButton.hidden = !RBXWizardDraftCanReset(self.draft, terminal, state,
        self.pendingRequestId.length > 0 || [RBXLauncherIPC pendingRequestsForOwner:self.requestOwner].count > 0,
        NSDate.date.timeIntervalSince1970);
}

- (void)retainEditableDraft {
    NSMutableDictionary *editable = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"nickname", @"country", @"role"])
        if (self.draft[key]) editable[key] = self.draft[key];
    self.draft = editable;
    [NSUserDefaults.standardUserDefaults setObject:self.draft forKey:self.draftKey];
}

- (void)resetFailedDraft {
    NSDictionary *terminal = [RBXLauncherIPC requestResultForId:self.draft[@"requestId"]];
    if (!RBXWizardDraftCanReset(self.draft, terminal, self.state,
        self.pendingRequestId.length > 0 || [RBXLauncherIPC pendingRequestsForOwner:self.requestOwner].count > 0,
        NSDate.date.timeIntervalSince1970)) {
        self.statusLabel.text = @"This step still needs verification. Refresh or open advanced; no request was retried.";
        [self refresh]; return;
    }
    [self retainEditableDraft];
    self.createdRow = nil;
    self.statusLabel.text = @"Failed step reset. Review setup, then tap Prepare preview when ready.";
    self.reviewLabel.text = @"Prepare a preview to see the model, iOS, region, carrier and language.";
    [self refresh];
}

- (void)review {
    if (self.pendingRequestId.length) return;
    if (self.createdRow) [self.navigationController pushViewController:
        [[RBXIdentityViewController alloc] initWithContainerRow:self.createdRow simpleMode:YES] animated:YES];
    else if ([self.draft[@"creationDraftToken"] length]) {
        NSDictionary *row = @{@"id":self.draft[@"container"], @"nickname":self.draft[@"nickname"] ?: @"Preview",
            @"appType":self.appDescriptor[@"appType"], @"identityEditor":self.draft[@"review"] ?: @{}};
        RBXIdentityViewController *editor = [[RBXIdentityViewController alloc] initWithContainerRow:row simpleMode:YES];
        editor.creationDraftToken = self.draft[@"creationDraftToken"];
        editor.creationDraftRevision = self.draft[@"creationDraftRevision"];
        [self.navigationController pushViewController:editor animated:YES];
    }
}
- (void)done {
    if (!self.pendingRequestId.length && self.createdRow) [NSUserDefaults.standardUserDefaults removeObjectForKey:self.draftKey];
    [self.navigationController popViewControllerAnimated:YES];
}
- (void)openAdvanced {
    [self.navigationController pushViewController:[[RBXLauncherViewController alloc] initWithAppType:self.appDescriptor[@"appType"] advancedMode:YES] animated:YES];
}
@end
