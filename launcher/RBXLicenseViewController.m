#import "RBXLicenseViewController.h"
#import "RBXAppScope.h"
#import "RBXAppearance.h"
#import "RBXDiagnosticsViewController.h"
#import "RBXSettingsViewController.h"
#import "RBXLauncherIPC.h"
#import "RBXSecureConfig.h"
#import "RBXLicensePresentation.h"
#import <math.h>

static NSString *const RBXLicenseRequestOwner = @"license";

static NSString *RBXLicenseScreenString(NSDictionary *state, NSString *key) {
    return [state[key] isKindOfClass:NSString.class] ? state[key] : @"";
}

static BOOL RBXLicenseScreenFlag(NSDictionary *state, NSString *key) {
    return [state[key] isKindOfClass:NSNumber.class] && [state[key] boolValue];
}

static NSString *RBXLicenseScreenDeadline(NSDictionary *state) {
    NSTimeInterval deadline = 0;
    for (NSString *key in @[@"graceUntil", @"expiresAt"]) {
        id value = state[key];
        if (RBXLicensePresentationNumber(value) && [value doubleValue] > 0)
            deadline = deadline > 0 ? MIN(deadline, [value doubleValue]) : [value doubleValue];
    }
    if (deadline <= 0) return @"";
    NSDateFormatter *formatter = [NSDateFormatter new];
    [formatter setLocalizedDateFormatFromTemplate:@"yMMMdjmmz"];
    NSString *date = [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:deadline]];
    // This cached deadline describes the signed grant; it never unlocks access
    // or replaces an expired/revoked/stale daemon reason above it.
    return date.length ? [NSString stringWithFormat:@"\nSigned access deadline: %@", date] : @"";
}

static NSString *RBXLicenseScreenServer(NSString *text) {
    NSString *value = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!value.length || value.length > 2048) return nil;
    NSURLComponents *url = [NSURLComponents componentsWithString:value];
    if (![url.scheme.lowercaseString isEqualToString:@"https"] || !url.host.length ||
        url.user || url.password || url.query || url.fragment ||
        (url.port && (url.port.integerValue < 1 || url.port.integerValue > 65535)) ||
        (url.path.length && ![url.path isEqualToString:@"/"])) return nil;
    url.scheme = @"https";
    url.path = @"";
    return url.URL.absoluteString;
}

static NSString *RBXActivationOnlyServer(NSDictionary *state) {
    id configured = state[@"serverURL"];
    // This is the existing production origin, used only before configuration.
    // Never replace an invalid nonempty configured server or any signing key.
    if (!configured || ([configured isKindOfClass:NSString.class] &&
        ![configured stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length))
        return @"https://redditspoof.vercel.app";
    return [configured isKindOfClass:NSString.class] ? RBXLicenseScreenServer(configured) : nil;
}

@interface RBXLicenseViewController ()
@property(nonatomic, copy) NSDictionary *appDescriptor;
@property(nonatomic, copy) NSDictionary *licenseState;
@property(nonatomic, strong) UILabel *stateLabel;
@property(nonatomic, strong) UILabel *reasonLabel;
@property(nonatomic, strong) UILabel *retryLabel;
@property(nonatomic, strong) UILabel *requestLabel;
@property(nonatomic, strong) UITextField *serverField;
@property(nonatomic, strong) UITextField *keyField;
@property(nonatomic, strong) UIButton *activateButton;
@property(nonatomic, strong) UIButton *validateButton;
@property(nonatomic, strong) NSTimer *displayTimer;
@property(nonatomic, copy) NSString *requestMessage;
@property(nonatomic) BOOL requestFailed;
@property(nonatomic) BOOL hasPendingRequest;
@property(nonatomic) BOOL serverWasEdited;
@property(nonatomic) BOOL activationOnly;
@end

@implementation RBXLicenseViewController

- (instancetype)initWithLicenseState:(NSDictionary *)licenseState {
    return [self initWithLicenseState:licenseState appType:@"reddit"];
}
- (instancetype)initWithLicenseState:(NSDictionary *)licenseState appType:(NSString *)appType {
    return [self initWithLicenseState:licenseState appType:appType activationOnly:NO];
}
- (instancetype)initWithLicenseState:(NSDictionary *)licenseState appType:(NSString *)appType activationOnly:(BOOL)activationOnly {
    NSDictionary *descriptor = [appType isKindOfClass:NSString.class] ? RBXAppDescriptorForType(appType) : nil;
    if (!descriptor) return nil;
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _appDescriptor = descriptor;
        _licenseState = [licenseState isKindOfClass:NSDictionary.class] ? [licenseState copy] : @{};
        _activationOnly = activationOnly;
        self.title = activationOnly ? @"SocialBox" : @"Account & license";
        self.modalInPresentation = YES;
        self.navigationItem.hidesBackButton = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = RBXCanvasColor();
    RBXStyleNavigation(self.navigationController);
    if (self.activationOnly) {
        [self buildActivationOnlyView];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(didBecomeActive:)
            name:UIApplicationDidBecomeActiveNotification object:nil];
        [self updateLicenseState:self.licenseState];
        return;
    }
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    UIStackView *page = RBXVerticalStack(@[], 16);
    page.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:page];
    UIStackView *status = RBXFormSection(page, @"Device access", nil);
    self.stateLabel = RBXLabel(@"Activation required", UIFontTextStyleTitle2, NO);
    self.reasonLabel = RBXLabel(@"No valid activation token is available on this device.", UIFontTextStyleBody, NO);
    self.retryLabel = RBXLabel(@"", UIFontTextStyleSubheadline, YES);
    [status addArrangedSubview:self.stateLabel];
    [status addArrangedSubview:self.reasonLabel];
    [status addArrangedSubview:self.retryLabel];

    UIStackView *activation = RBXFormSection(page, @"License key",
        @"Enter the HTTPS server supplied with your license and activate this device. "
         "Your key is saved in the device keychain. Leave it blank to retry the key already saved here.");
    self.serverField = [UITextField new];
    self.serverField.placeholder = @"HTTPS license server URL";
    self.serverField.keyboardType = UIKeyboardTypeURL;
    self.serverField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.serverField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.serverField.spellCheckingType = UITextSpellCheckingTypeNo;
    [self.serverField addTarget:self action:@selector(serverEdited) forControlEvents:UIControlEventEditingChanged];
    RBXStyleField(self.serverField);
    [activation addArrangedSubview:self.serverField];
    self.keyField = [UITextField new];
    self.keyField.placeholder = @"License key";
    self.keyField.secureTextEntry = YES;
    self.keyField.keyboardType = UIKeyboardTypeASCIICapable;
    self.keyField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    self.keyField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.keyField.spellCheckingType = UITextSpellCheckingTypeNo;
    RBXStyleField(self.keyField);
    [activation addArrangedSubview:self.keyField];
    self.activateButton = [self buttonWithTitle:@"Activate key" action:@selector(activateLicense) primary:YES];
    [activation addArrangedSubview:self.activateButton];
    self.validateButton = [self buttonWithTitle:@"Validate paired device" action:@selector(validateLicense) primary:NO];
    [activation addArrangedSubview:self.validateButton];
    [activation addArrangedSubview:RBXLabel(@"Already paired devices can check their current entitlement. "
        "This keeps the saved key and uses the device's existing server configuration.", UIFontTextStyleFootnote, YES)];
    self.requestLabel = RBXLabel(@"No activation request has been sent from this screen.", UIFontTextStyleSubheadline, YES);
    [activation addArrangedSubview:self.requestLabel];

    UIStackView *maintenance = RBXFormSection(page, @"Device tools",
        @"Diagnostics and setup are available while your license is active. "
         "Your containers and their data are retained if access expires.");
    [maintenance addArrangedSubview:[self buttonWithTitle:@"Diagnostics" action:@selector(openDiagnostics) primary:NO]];
    [maintenance addArrangedSubview:[self buttonWithTitle:@"Setup and maintenance" action:@selector(openSettings) primary:NO]];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [page.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [page.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [page.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16],
        [page.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [page.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32],
    ]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(didBecomeActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [self updateLicenseState:self.licenseState];
}

- (void)buildActivationOnlyView {
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    UIStackView *page = RBXVerticalStack(@[], 18);
    page.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:page];
    UIImageView *lock = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"lock.shield.fill"]];
    lock.contentMode = UIViewContentModeScaleAspectFit;
    lock.tintColor = RBXAccentColor();
    lock.accessibilityElementsHidden = YES;
    [lock.heightAnchor constraintEqualToConstant:64].active = YES;
    [page addArrangedSubview:lock];
    UILabel *brand = RBXLabel(@"SocialBox", UIFontTextStyleLargeTitle, NO);
    brand.textAlignment = NSTextAlignmentCenter;
    brand.accessibilityTraits |= UIAccessibilityTraitHeader;
    [page addArrangedSubview:brand];
    self.stateLabel = RBXLabel(@"Activation required", UIFontTextStyleHeadline, NO);
    self.stateLabel.textAlignment = NSTextAlignmentCenter;
    [page addArrangedSubview:self.stateLabel];
    self.reasonLabel = RBXLabel(@"Enter your license key to unlock SocialBox.", UIFontTextStyleBody, YES);
    self.reasonLabel.textAlignment = NSTextAlignmentCenter;
    [page addArrangedSubview:self.reasonLabel];
    self.keyField = [UITextField new];
    self.keyField.placeholder = @"License key";
    self.keyField.accessibilityIdentifier = @"socialbox.activation-key";
    self.keyField.secureTextEntry = YES;
    self.keyField.keyboardType = UIKeyboardTypeASCIICapable;
    self.keyField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    self.keyField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.keyField.spellCheckingType = UITextSpellCheckingTypeNo;
    self.keyField.returnKeyType = UIReturnKeyDone;
    [self.keyField addTarget:self action:@selector(activateLicense)
        forControlEvents:UIControlEventEditingDidEndOnExit];
    RBXStyleField(self.keyField);
    [page addArrangedSubview:self.keyField];
    self.activateButton = [self buttonWithTitle:@"Activate" action:@selector(activateLicense) primary:YES];
    self.activateButton.accessibilityIdentifier = @"socialbox.activate";
    [page addArrangedSubview:self.activateButton];
    self.requestLabel = RBXLabel(@"", UIFontTextStyleSubheadline, YES);
    self.requestLabel.textAlignment = NSTextAlignmentCenter;
    [page addArrangedSubview:self.requestLabel];
    self.retryLabel = RBXLabel(@"", UIFontTextStyleFootnote, YES);
    self.retryLabel.textAlignment = NSTextAlignmentCenter;
    [page addArrangedSubview:self.retryLabel];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [page.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:40],
        [page.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [page.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:28],
        [page.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-28],
        [page.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-56],
    ]];
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action primary:(BOOL)primary {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    RBXStyleButton(button, primary);
    return button;
}

- (void)serverEdited { self.serverWasEdited = YES; }

- (void)updateLicenseState:(NSDictionary *)licenseState {
    NSDictionary *snapshot = [licenseState isKindOfClass:NSDictionary.class] ? [licenseState copy] : @{};
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf updateLicenseState:snapshot]; });
        return;
    }
    self.licenseState = snapshot;
    if (!self.isViewLoaded) return;
    if (!self.activationOnly && !self.serverWasEdited && !self.serverField.isFirstResponder) {
        NSString *server = RBXLicenseScreenServer(RBXLicenseScreenString(snapshot, @"serverURL"));
        if (server.length) self.serverField.text = server;
    }
    [self pollRequestReceipts];
    [self renderStatus];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshDetailedLicenseState];
    [self pollRequestReceipts];
    [self renderStatus];
    [self.displayTimer invalidate];
    __weak typeof(self) weakSelf = self;
    // Refresh only the local publication/countdown. Network validation is owned
    // by the daemon; lifecycle events never submit activation or validation.
    self.displayTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refreshDetailedLicenseState];
        [weakSelf renderStatus];
    }];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.displayTimer invalidate];
    self.displayTimer = nil;
    self.keyField.text = @"";
}

- (void)dealloc {
    [self.displayTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)didBecomeActive:(NSNotification *)notification {
    [self refreshDetailedLicenseState];
    [self pollRequestReceipts];
    [self renderStatus];
}

- (NSDictionary *)readLicensePublication {
    return [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist"];
}

- (void)refreshDetailedLicenseState {
    // The activation-only root receives the gate's already evaluated state.
    // Account & license instead observes the full publication, including its
    // freshness timestamp; a cached nested license can never extend access.
    if (self.activationOnly) return;
    NSDictionary *state = RBXLicensePresentationState([self readLicensePublication],
        NSDate.date.timeIntervalSince1970);
    [self updateLicenseState:state];
}

- (void)pollRequestReceipts {
    for (NSDictionary *request in [RBXLauncherIPC pendingRequestsForOwner:RBXLicenseRequestOwner]) {
        NSString *requestId = request[@"requestId"];
        NSDictionary *receipt = [RBXLauncherIPC requestResultForId:requestId];
        if (!receipt) continue;
        self.requestFailed = ![receipt[@"ok"] boolValue];
        NSString *message = RBXLicenseScreenString(receipt, @"message");
        self.requestMessage = message.length ? message : (self.requestFailed ?
            (self.activationOnly ? @"Activation failed. Please try again." : @"The daemon could not complete the request. Check diagnostics before retrying.") :
            (self.activationOnly ? @"Activation received. Checking access…" : @"The request completed. Access follows the daemon's current license state above."));
        [RBXLauncherIPC finishObservingRequestId:requestId owner:RBXLicenseRequestOwner];
    }
    self.hasPendingRequest = [RBXLauncherIPC pendingRequestsForOwner:RBXLicenseRequestOwner].count > 0;
}

- (NSTimeInterval)retryDelay {
    id value = self.licenseState[@"retryAt"];
    NSTimeInterval retryAt = [value isKindOfClass:NSNumber.class] ? [value doubleValue] : 0;
    if (!isfinite(retryAt) || retryAt <= 0) return 0;
    return MAX(0, retryAt - NSDate.date.timeIntervalSince1970);
}

- (void)renderStatus {
    BOOL unlocked = RBXLicenseScreenFlag(self.licenseState, @"unlocked");
    BOOL grace = RBXLicenseScreenFlag(self.licenseState, @"offlineGrace");
    NSString *status = RBXLicenseScreenString(self.licenseState, @"status");
    NSString *reason = RBXLicenseScreenString(self.licenseState, @"reason");
    self.stateLabel.text = unlocked ? (grace ? @"Offline grace is active" : @"Device access is active") : @"Activation required";
    self.stateLabel.textColor = unlocked ? RBXAccentColor() : UIColor.labelColor;
    NSString *defaultReason = unlocked ? @"The daemon reports a valid entitlement for this device." :
        @"No valid activation token is available on this device. Container access remains locked.";
    self.reasonLabel.text = [NSString stringWithFormat:@"%@%@%@%@", reason.length ? reason : defaultReason,
        status.length ? @"\nStatus: " : @"", status, RBXLicenseScreenDeadline(self.licenseState)];
    NSTimeInterval delay = [self retryDelay];
    self.retryLabel.hidden = delay <= 0;
    if (delay > 0) self.retryLabel.text = [NSString stringWithFormat:
        @"Retry available in %.0f seconds. No request will be retried automatically.", ceil(delay)];
    BOOL canRequest = !unlocked && !self.hasPendingRequest && delay <= 0;
    self.activateButton.enabled = canRequest;
    self.validateButton.enabled = canRequest && RBXLicenseScreenFlag(self.licenseState, @"paired");
    self.serverField.enabled = !self.hasPendingRequest;
    self.keyField.enabled = !self.hasPendingRequest;
    if (self.activationOnly) {
        self.stateLabel.text = unlocked ? @"Access verified" : @"Activation required";
        self.reasonLabel.text = unlocked ? @"Opening SocialBox…" :
            (reason.length ? reason : @"Enter your license key to unlock SocialBox.");
        if (!unlocked && [status isEqualToString:@"daemon-unavailable"])
            self.reasonLabel.text = @"Waiting for the device service. Please try again shortly.";
        else if (!unlocked && [status isEqualToString:@"clock-invalid"])
            self.reasonLabel.text = @"Check the device date and time, then try again.";
        else if (!unlocked && [status isEqualToString:@"invalid-status"])
            self.reasonLabel.text = @"Waiting for a valid license status. Please try again shortly.";
        else if (!unlocked && [status isEqualToString:@"expired"])
            self.reasonLabel.text = @"Your license has expired. Enter a valid key to activate.";
        if (delay > 0) self.retryLabel.text = [NSString stringWithFormat:@"Try again in %.0f seconds.", ceil(delay)];
        self.requestLabel.text = self.hasPendingRequest ? @"Activating…" : (self.requestMessage ?: @"");
        self.requestLabel.textColor = self.requestFailed ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
        self.requestLabel.hidden = self.requestLabel.text.length == 0;
        return;
    }
    if (self.hasPendingRequest) {
        self.requestLabel.text = @"Waiting for the device service to confirm the request. This request will not be duplicated.";
        self.requestLabel.textColor = UIColor.secondaryLabelColor;
    } else {
        self.requestLabel.text = self.requestMessage ?: @"No activation request has been sent from this screen.";
        self.requestLabel.textColor = self.requestFailed ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
    }
}

- (void)showLocalError:(NSString *)message {
    self.requestMessage = message;
    self.requestFailed = YES;
    [self renderStatus];
}

- (BOOL)canSubmitRequest {
    [self pollRequestReceipts];
    [self renderStatus];
    return !self.hasPendingRequest && [self retryDelay] <= 0 &&
        !RBXLicenseScreenFlag(self.licenseState, @"unlocked");
}

- (void)activateLicense {
    if (![self canSubmitRequest]) return;
    NSString *server = self.activationOnly ? RBXActivationOnlyServer(self.licenseState) : RBXLicenseScreenServer(self.serverField.text);
    if (!server.length) {
        [self showLocalError:self.activationOnly ? @"The configured license server is invalid. Contact your license provider." : @"Enter your HTTPS license server origin, without a path, login credentials, query or fragment. No request was sent."];
        return;
    }
    NSString *key = [[self.keyField.text ?: @"" stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    NSError *keyError = nil;
    if (!key.length) key = [RBXSecureConfig accessKey:&keyError];
    if (keyError || !key.length || key.length > 256 ||
        [key rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        [self showLocalError:keyError ? (self.activationOnly ? @"The saved key could not be read. Enter your license key again." : @"The saved key could not be read securely. Check device diagnostics and try again.") :
            @"Enter a license key of up to 256 characters. No request was sent."];
        return;
    }
    // Save before enqueueing. The durable IPC record contains the server URL
    // only; plaintext keys never enter IPC, preferences, receipts or logging.
    if (![RBXSecureConfig saveAccessKey:key error:&keyError]) {
        [self showLocalError:@"The key could not be saved securely. No activation request was sent."];
        return;
    }
    self.keyField.text = @"";
    [self.view endEditing:YES];
    [self submitAction:@"activateLicense" values:@{@"serverURL": server}];
}

- (void)validateLicense {
    if (self.activationOnly) return;
    if (![self canSubmitRequest] || !RBXLicenseScreenFlag(self.licenseState, @"paired")) return;
    [self.view endEditing:YES];
    [self submitAction:@"validateLicense" values:@{}];
}

- (void)submitAction:(NSString *)action values:(NSDictionary *)values {
    NSString *requestId = [RBXLauncherIPC sendActionReturningRequestId:action values:values
        notification:CFSTR("com.redditbox.launcherAction") owner:RBXLicenseRequestOwner];
    if (!requestId.length) {
        [self showLocalError:self.activationOnly ? @"Activation could not be queued. Please try again." : @"The request could not be queued. Any saved key remains in the keychain. Retry manually; diagnostics and setup are still available."];
        return;
    }
    self.requestMessage = nil;
    self.requestFailed = NO;
    [self pollRequestReceipts];
    [self renderStatus];
}

- (void)openDiagnostics {
    if (self.activationOnly) return;
    [self showMaintenanceController:[self.appDescriptor[@"appType"] isEqual:@"reddit"] ? [RBXDiagnosticsViewController new] : [[RBXDiagnosticsViewController alloc] initWithAppType:self.appDescriptor[@"appType"]]];
}

- (void)openSettings {
    if (self.activationOnly) return;
    [self showMaintenanceController:[self.appDescriptor[@"appType"] isEqual:@"reddit"] ? [[RBXSettingsViewController alloc] initWithWizardMode:NO] : [[RBXSettingsViewController alloc] initWithAppType:self.appDescriptor[@"appType"] proxyMode:NO]];
}

- (void)showMaintenanceController:(UIViewController *)controller {
    if (self.activationOnly) return;
    if (self.navigationController) [self.navigationController pushViewController:controller animated:YES];
    else {
        UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
        RBXStyleNavigation(navigation);
        [self presentViewController:navigation animated:YES completion:nil];
    }
}

@end
